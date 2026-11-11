#!/usr/bin/env python3
"""Inventory, read-only, the systems on this machine that answer operational
questions. Writes <state>/inventory.md, one line per finding, each with the
command that found it, and keeps its `## Skills` section across runs.

  discover.py [--repo-root DIR ...] [--probe-local] [--probe-context CTX [--yes-prod]]
  discover.py --self-test      check the fixed probe queries with the read-only guard, offline

What it reads, names only:
  access         kube contexts (`kubectl config get-contexts -o name`, and a jsonpath
                 that selects each user's exec plugin), AWS profile names (the CLI, or
                 the [section] headers and key names of ~/.aws/config; it never opens
                 the credentials file), gcloud configurations, SSO, bastion and secret
                 manager CLIs on PATH; with each, the re-login command and what an
                 expired session looks like
  observability  metrics, log, trace and dashboard backends in `docker ps` and in env
                 var names, with the URL pattern for deep links
  data           database containers and env vars; with --probe-local, Postgres roles
                 and whether the server is a replica
  control        feature-flag services, schedulers, CI and deploy CLIs
  repos          git clones under the repo roots, and the charts, manifests, queries,
                 dashboards and CI they hold

It never reads a secret value: no `docker inspect` (it prints env), no `kubectl
config view --raw`, no value of an env var whose name looks secret, and a URL
keeps only scheme, host, port and path. It never runs a write or a port-forward.
--probe-local touches only containers on this machine (Prometheus buildinfo;
Postgres through `docker exec`, inside BEGIN READ ONLY). --probe-context lists
cronjobs and services in one kube context, and a context matching prod_patterns
needs --yes-prod or a yes typed at a terminal.
"""
from __future__ import annotations

import argparse
import csv
import fnmatch
import io
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sqlguard  # noqa: E402
from mask import EXIT_OK, EXIT_REFUSED, config_path, emit, header, iso, masker, read_toml, state_dir  # noqa: E402

KUBE_AUTH = {
    "aws": ("aws sso login --profile <profile>", '"ExpiredToken" or "The SSO session associated with this profile has expired"'),
    "aws-iam-authenticator": ("aws sso login --profile <profile>", '"ExpiredToken" or "Unauthorized"'),
    "gke-gcloud-auth-plugin": ("gcloud auth login", '"Reauthentication failed" or "invalid_grant"'),
    "kubelogin": ("kubelogin convert-kubeconfig -l azurecli, then az login", '"AADSTS700082" or "token is expired"'),
    "kubectl-oidc_login": ("any kubectl call re-opens the browser; else kubectl oidc-login setup", '"the server has asked for the client to provide credentials"'),
    "tsh": ("tsh login --proxy=<proxy>", '"certificate has expired" or "ssh: handshake failed"'),
    "az": ("az login", '"AADSTS700082" or "Please run \'az login\'"'),
}
TOOLS = {
    "tsh": ("access", "Teleport (SSO bastion)", "tsh login --proxy=<proxy>", '"certificate has expired"'),
    "boundary": ("access", "Boundary (bastion)", "boundary authenticate", '"Unauthenticated"'),
    "cloudflared": ("access", "Cloudflare Access", "cloudflared access login <url>", '"Unable to reach the origin" or a login page'),
    "session-manager-plugin": ("access", "AWS SSM sessions", "aws sso login --profile <profile>", '"ExpiredToken"'),
    "aws-vault": ("access", "aws-vault", "aws-vault login <profile>", '"ExpiredToken"'),
    "granted": ("access", "Granted (assume)", "assume <profile>", '"ExpiredToken"'),
    "vault": ("access", "HashiCorp Vault (secrets)", "vault login -method=oidc", '"permission denied" or "missing client token"'),
    "op": ("access", "1Password CLI (secrets)", "op signin", '"You are not currently signed in"'),
    "bw": ("access", "Bitwarden CLI (secrets)", "bw login", '"You are not logged in"'),
    "sops": ("access", "SOPS (secrets in files)", "re-login to the KMS it uses", '"Failed to get the data key"'),
    "doppler": ("access", "Doppler (secrets)", "doppler login", '"Unauthorized"'),
    "infisical": ("access", "Infisical (secrets)", "infisical login", '"unauthorized"'),
    "gh": ("control", "GitHub CLI (CI)", "gh auth login", '"HTTP 401: Bad credentials"'),
    "glab": ("control", "GitLab CLI (CI)", "glab auth login", '"401 Unauthorized"'),
    "circleci": ("control", "CircleCI CLI", "circleci setup", '"Unauthorized"'),
    "argocd": ("control", "Argo CD (deploys)", "argocd login <server> --sso", '"Unauthenticated"'),
    "argo": ("control", "Argo Workflows (jobs)", "re-login to the cluster", '"Unauthorized"'),
    "helm": ("control", "Helm (deploys)", "re-login to the cluster", '"Kubernetes cluster unreachable"'),
    "flux": ("control", "Flux (deploys)", "re-login to the cluster", '"Unauthorized"'),
    "terraform": ("control", "Terraform (infra)", "re-login to the cloud", '"ExpiredToken" or "invalid_grant"'),
    "tofu": ("control", "OpenTofu (infra)", "re-login to the cloud", '"ExpiredToken" or "invalid_grant"'),
    "pulumi": ("control", "Pulumi (infra)", "pulumi login", '"unauthorized"'),
    "temporal": ("control", "Temporal (workflows)", "temporal env set / re-login", '"Unauthenticated"'),
    "airflow": ("control", "Airflow (scheduler)", "re-login to the webserver", '"401"'),
    "ldcli": ("control", "LaunchDarkly CLI (flags)", "ldcli login", '"Unauthorized"'),
    "flipt": ("control", "Flipt (flags)", "re-login to Flipt", '"unauthenticated"'),
}
IMAGES = [
    ("data", "postgres", r"(?:^|/)(?:postgres|postgis|timescaledb)\b"),
    ("data", "mysql", r"(?:^|/)(?:mysql|mariadb|percona)\b"),
    ("data", "redis", r"(?:^|/)(?:redis|valkey)\b"),
    ("data", "mongodb", r"(?:^|/)mongo\b"),
    ("data", "clickhouse", r"(?:^|/)clickhouse"),
    ("data", "kafka", r"(?:^|/)(?:kafka|redpanda)"),
    ("observability", "prometheus", r"(?:^|/)prometheus\b|victoria-?metrics|(?:^|/)thanos|(?:^|/)mimir|(?:^|/)cortex"),
    ("observability", "grafana", r"(?:^|/)grafana\b"),
    ("observability", "loki", r"(?:^|/)loki\b"),
    ("observability", "tracing", r"(?:^|/)(?:tempo|jaeger|zipkin)"),
    ("observability", "otel collector", r"otel.*collector|opentelemetry-collector"),
    ("observability", "alertmanager", r"(?:^|/)alertmanager"),
    ("observability", "search/logs", r"(?:^|/)(?:elasticsearch|opensearch)"),
    ("control", "feature flags", r"(?:^|/)(?:unleash|flagsmith|flipt|growthbook)"),
    ("control", "scheduler", r"(?:^|/)(?:airflow|temporal|dagster|prefect)"),
]
DEEP_LINK = {
    "prometheus": "{base}/graph?g0.expr=<expr>&g0.range_input=<range>&g0.end_input=<end>",
    "grafana": "{base}/explore?left=<json: datasource, queries, range>",
    "loki": "query through Grafana Explore; API {base}/loki/api/v1/query_range",
    "tracing": "{base}/trace/<trace id>",
    "alertmanager": "{base}/#/alerts?filter=<matchers>",
}
ENV_KINDS = [
    ("observability", re.compile(r"PROM|GRAFANA|LOKI|TEMPO|JAEGER|OTEL|DATADOG|^DD_|NEW_?RELIC|SENTRY|ELASTIC|OPENSEARCH|SPLUNK|HONEYCOMB|SIGNOZ|VICTORIA|THANOS|MIMIR|ALERTMANAGER")),
    ("data", re.compile(r"DATABASE|^PG[A-Z]+$|POSTGRES|MYSQL|REDIS|MONGO|CLICKHOUSE|SNOWFLAKE|BIGQUERY|KAFKA")),
    ("control", re.compile(r"LAUNCHDARKLY|^LD_|UNLEASH|FLAGSMITH|SPLIT_?IO|GROWTHBOOK|FLIPT|STATSIG|CONFIGCAT|ARGOCD|AIRFLOW|TEMPORAL")),
]
SECRET_NAME = re.compile(r"PASS|SECRET|TOKEN|KEY|CRED|AUTH|COOKIE|SESSION|PRIVATE|DSN|CERT", re.I)
MARKERS = [
    ("helm charts", ["Chart.yaml"]),
    ("kustomize", ["kustomization.yaml", "kustomization.yml"]),
    ("terraform", ["*.tf"]),
    ("compose files", ["docker-compose*.yml", "docker-compose*.yaml", "compose.yml", "compose.yaml"]),
    ("sql", ["*.sql"]),
    ("dashboards", ["*dashboard*.json"]),
    ("alert or recording rules", ["*rules*.yml", "*rules*.yaml", "*alerts*.yml", "*alerts*.yaml"]),
    ("GitHub Actions", ["workflows"]),
    ("GitLab CI", [".gitlab-ci.yml"]),
    ("Jenkinsfile", ["Jenkinsfile"]),
]
SKIP_DIRS = {".git", "node_modules", "vendor", ".venv", "venv", "__pycache__", "dist", "build", "target", ".terraform"}
ROLES_SQL = ("SELECT r.rolname, r.rolcanlogin, r.rolsuper,"
             " coalesce((SELECT bool_or(c = 'default_transaction_read_only=on') FROM pg_db_role_setting s"
             " CROSS JOIN LATERAL unnest(s.setconfig) AS c WHERE s.setrole = r.oid), false) AS ro_default,"
             " pg_has_role(r.oid, 'pg_read_all_data', 'MEMBER') AS reads_all"
             " FROM pg_roles r WHERE r.rolname !~ '^pg_' ORDER BY 1")
SERVER_SQL = "SELECT pg_is_in_recovery() AS replica, current_setting('server_version') AS version"
PSQL_IN_CONTAINER = 'psql -X -q -v ON_ERROR_STOP=1 --csv -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"'
LOCAL_HOSTS = {"127.0.0.1", "0.0.0.0", "localhost", "::", "::1", "[::]"}


@dataclass
class Finding:
    kind: str
    text: str
    how: str

    def line(self) -> str:
        return f"- **{self.kind}** {self.text} · found by `{self.how}`"


def run(argv: list[str], stdin: str | None = None, timeout: float = 20) -> tuple[int, str, str]:
    if not shutil.which(argv[0]):
        return 127, "", f"{argv[0]}: not on PATH"
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", f"{argv[0]}: timed out after {timeout:g}s"
    return p.returncode, p.stdout, p.stderr


def tilde(p: Path | str) -> str:
    s, home = str(p), os.path.expanduser("~")
    return "~" + s[len(home):] if s == home or s.startswith(home + os.sep) else s


def sanitize_url(value: str) -> str:
    """Scheme, host, port and path; never the user:password, query or fragment."""
    from urllib.parse import urlsplit
    u = urlsplit(value)
    host = u.hostname or ""
    if u.port:
        host += f":{u.port}"
    return f"{u.scheme}://{host}{u.path}"


def first_line(text: str) -> str:
    return (text.strip().splitlines() or [""])[0][:160]


# ---- access ----------------------------------------------------------------

def kube(cfg: dict) -> list[Finding]:
    out = []
    excluded = cfg.get("exclude_contexts", [])
    prod = cfg.get("prod_patterns", ["*prod*", "*prd*", "*live*"])
    if not shutil.which("kubectl"):
        path = Path(os.environ.get("KUBECONFIG", "~/.kube/config").split(os.pathsep)[0]).expanduser()
        if path.exists():
            out.append(Finding("access", f"kubeconfig at `{tilde(path)}`; kubectl is not on PATH, so contexts were not listed", f"test -f {tilde(path)}"))
        return out
    how = "kubectl config get-contexts -o name"
    rc, names, err = run(["kubectl", "config", "get-contexts", "-o", "name"])
    if rc != 0:
        out.append(Finding("access", f"kubectl config get-contexts failed: {first_line(err)}", how))
        return out
    _, ctx_users, _ = run(["kubectl", "config", "view", "-o", 'jsonpath={range .contexts[*]}{.name}{"\\t"}{.context.user}{"\\n"}{end}'])
    _, user_auth, _ = run(["kubectl", "config", "view", "-o", 'jsonpath={range .users[*]}{.name}{"\\t"}{.user.exec.command}{"\\t"}{.user.auth-provider.name}{"\\n"}{end}'])
    user_of = dict(ln.split("\t", 1) for ln in ctx_users.splitlines() if "\t" in ln)
    auth_of = {}
    for ln in user_auth.splitlines():
        parts = ln.split("\t")
        if parts and parts[0]:
            auth_of[parts[0]] = os.path.basename(parts[1]) if len(parts) > 1 and parts[1] else (parts[2] if len(parts) > 2 else "")
    skipped = 0
    for ctx in names.split():
        if any(fnmatch.fnmatch(ctx, g) for g in excluded):
            skipped += 1
            continue
        plugin = auth_of.get(user_of.get(ctx, ""), "")
        relogin, expired = KUBE_AUTH.get(plugin, (f"re-run {plugin}" if plugin else "ask for a fresh kubeconfig",
                                                  '"You must be logged in to the server (Unauthorized)"'))
        auth = f"exec {plugin}" if plugin else "static token or certificate in the kubeconfig (not read)"
        flag = " · PRODUCTION: ask before connecting" if any(fnmatch.fnmatch(ctx, g) for g in prod) else ""
        out.append(Finding("access", f"kube context `{ctx}` · auth: {auth} · re-login: `{relogin}` · expired looks like: {expired}{flag}",
                           how + " (+ jsonpath over users[*].user.exec.command)"))
    if skipped:
        out.append(Finding("access", f"{skipped} kube context(s) left out by exclude_contexts", "the skill-forge config"))
    return out


def aws_profiles() -> list[Finding]:
    cfg = Path(os.environ.get("AWS_CONFIG_FILE") or "~/.aws/config").expanduser()
    sections, current = {}, None
    if cfg.is_file():
        for raw in cfg.read_text(errors="replace").splitlines():
            line = raw.strip()
            m = re.match(r"\[(?:profile\s+)?([^\]]+)\]$", line)
            if m:
                current = m.group(1).strip()
                sections.setdefault(current, set())
            elif current and "=" in line and not line.startswith(("#", ";")):
                sections[current].add(line.split("=", 1)[0].strip())   # the key's name; its value is dropped here
    how = f"[section] headers and key names of {tilde(cfg)}"
    if shutil.which("aws"):
        rc, out, _ = run(["aws", "configure", "list-profiles"])
        if rc == 0:
            for p in out.split():
                sections.setdefault(p, set())
            how = "aws configure list-profiles, and key names in " + tilde(cfg)
    found = []
    for name, keys in sorted(sections.items()):
        if name.startswith("sso-session "):
            continue
        sso = any(k.startswith("sso_") for k in keys)
        relogin = f"aws sso login --profile {name}" if sso else "static or role-chained keys: renew per your IAM process"
        found.append(Finding("access", f"AWS profile `{name}` · {'SSO' if sso else 'non-SSO'} · re-login: `{relogin}` · expired looks like: "
                             '"ExpiredToken" or "The SSO session associated with this profile has expired"', how))
    return found


def gcloud() -> list[Finding]:
    if not shutil.which("gcloud"):
        return []
    how = "gcloud config configurations list --format=value(name)"
    rc, out, err = run(["gcloud", "config", "configurations", "list", "--format=value(name)"])
    if rc != 0:
        return [Finding("access", f"gcloud on PATH; listing configurations failed: {first_line(err)}", how)]
    return [Finding("access", f"gcloud configuration `{n}` · re-login: `gcloud auth login` (and `gcloud auth application-default login` for libraries)"
                    ' · expired looks like: "Reauthentication failed" or "invalid_grant"', how) for n in out.split()]


def tools() -> list[Finding]:
    out = []
    for tool, (kind, what, relogin, expired) in TOOLS.items():
        if shutil.which(tool):
            out.append(Finding(kind, f"`{tool}` on PATH: {what} · re-login: `{relogin}` · expired looks like: {expired}", f"command -v {tool}"))
    return out


# ---- containers, env, repos ----------------------------------------------------

def ports(text: str) -> list[str]:
    return sorted({f"{h}:{p}" for h, p in re.findall(r"([\d.:\[\]a-f]*?):(\d+)->\d+/tcp", text)})


def containers(probe_local: bool) -> list[Finding]:
    if not shutil.which("docker"):
        return []
    how = "docker ps --format '{{.Names}}\\t{{.Image}}\\t{{.Ports}}'"
    rc, out, err = run(["docker", "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}"])
    if rc != 0:
        return [Finding("data", f"docker on PATH; the daemon did not answer ({first_line(err)})", how)]
    found = []
    for ln in out.splitlines():
        parts = ln.split("\t")
        if len(parts) < 2:
            continue
        name, image, portmap = parts[0], parts[1], parts[2] if len(parts) > 2 else ""
        for kind, label, rx in IMAGES:
            if re.search(rx, image):
                eps = ports(portmap)
                base = f"http://{eps[0].replace('0.0.0.0', '127.0.0.1')}" if eps else ""
                link = f" · deep link: {DEEP_LINK[label].format(base=base)}" if label in DEEP_LINK and base else ""
                text = f"{label} container `{name}` ({image}) on {', '.join(eps) or 'no published port'}{link}"
                found.append(Finding(kind, text, how))
                if probe_local and label == "prometheus" and eps:
                    found.append(prom_buildinfo(name, eps[0]))
                if probe_local and label == "postgres":
                    found += pg_roles(name)
                break
    return found


def prom_buildinfo(name: str, endpoint: str) -> Finding:
    host, _, port = endpoint.rpartition(":")
    how = f"GET http://127.0.0.1:{port}/api/v1/status/buildinfo"
    if host not in LOCAL_HOSTS:
        return Finding("observability", f"prometheus `{name}` is published on {host}, not this machine; not probed", how)
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/status/buildinfo", timeout=3) as r:
            v = json.load(r).get("data", {}).get("version", "?")
        return Finding("observability", f"prometheus `{name}` answers: version {v}", how)
    except (OSError, ValueError) as e:
        return Finding("observability", f"prometheus `{name}` did not answer buildinfo ({e})", how)


def pg_query(container: str, sql: str) -> tuple[int, list[list[str]], str]:
    ok, why = sqlguard.check(sql)
    if not ok:
        return 5, [], f"refused by the read-only guard: {why}"
    argv = ["docker", "exec", "-i", "-e", "PGOPTIONS=-c default_transaction_read_only=on", container, "sh", "-c", PSQL_IN_CONTAINER]
    rc, out, err = run(argv, stdin=f"BEGIN READ ONLY;\n{sql};\nROLLBACK;\n")
    return rc, [r for r in csv.reader(io.StringIO(out)) if r], err


def pg_roles(container: str) -> list[Finding]:
    how = f"docker exec -i {container} psql (the container's own user, inside BEGIN READ ONLY)"
    rc, server, err = pg_query(container, SERVER_SQL)
    if rc != 0:
        return [Finding("data", f"postgres `{container}`: probe failed: {first_line(err)}", how)]
    role = "replica" if server[1][0] == "t" else "primary"
    rc, rows, err = pg_query(container, ROLES_SQL)
    if rc != 0:
        return [Finding("data", f"postgres `{container}`: {role} v{server[1][1]}; roles not listed: {first_line(err)}", how)]
    desc = []
    for name, login, sup, ro, reads_all in rows[1:]:
        tags = (["login"] if login == "t" else []) + (["SUPERUSER"] if sup == "t" else []) + \
               (["read-only by default"] if ro == "t" else []) + (["pg_read_all_data"] if reads_all == "t" else [])
        desc.append(f"{name} ({', '.join(tags) or 'no login'})")
    ro_roles = [r[0] for r in rows[1:] if r[1] == "t" and r[2] != "t" and (r[3] == "t" or r[4] == "t")]
    return [Finding("data", f"postgres `{container}`: {role} v{server[1][1]}; roles: {'; '.join(desc)}; read-only login roles: "
                    f"{', '.join(ro_roles) or 'none, so create one before a sql-readonly skill'}", how)]


def env_vars() -> list[Finding]:
    found = []
    for name in sorted(os.environ):
        kind = next((k for k, rx in ENV_KINDS if rx.search(name)), None)
        if not kind:
            continue
        if SECRET_NAME.search(name):
            shown = "set (a secret by its name; value not read)"
        else:
            value = os.environ[name]
            shown = sanitize_url(value) if re.match(r"[a-z][a-z0-9+.-]*://", value) else value[:80]
        found.append(Finding(kind, f"env `{name}` = {shown}", "the environment's variable names"))
    return found


def markers(repo: Path, budget: int = 3000) -> dict:
    counts: dict = {}
    seen = 0
    for root, dirs, files in os.walk(repo):
        depth = len(Path(root).relative_to(repo).parts)
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and (d != ".github" or depth == 0)] if depth < 4 else []
        names = files + (["workflows"] if Path(root).name == ".github" and (Path(root) / "workflows").is_dir() else [])
        for label, globs in MARKERS:
            n = sum(1 for f in names if any(fnmatch.fnmatch(f, g) for g in globs))
            if n:
                counts[label] = counts.get(label, 0) + n
        seen += len(files) + len(dirs)
        if seen > budget:
            counts["(walk stopped at the entry budget)"] = 1
            break
    return counts


def repos(roots: list[str]) -> list[Finding]:
    found = []
    for r in roots:
        root = Path(r).expanduser()
        if not root.is_dir():
            continue
        cands = [p for p in sorted(root.iterdir()) if p.is_dir()] + [q for p in sorted(root.iterdir()) if p.is_dir() and not (p / ".git").exists()
                                                                   for q in sorted(p.iterdir()) if q.is_dir()]
        for repo in [c for c in cands if (c / ".git").exists()][:200]:
            m = markers(repo)
            if not m:
                continue
            _, origin, _ = run(["git", "-C", str(repo), "remote", "get-url", "origin"])
            o = origin.strip()
            o = sanitize_url(o) if "://" in o else o
            held = ", ".join(f"{k} ({v})" for k, v in sorted(m.items()))
            found.append(Finding("repos", f"`{tilde(repo)}`{' (origin ' + o + ')' if o else ''} holds {held}",
                                 f"find {tilde(repo)} -maxdepth 4 for Chart.yaml, *.tf, *.sql, dashboards, rules, CI"))
    return found


def probe_context(ctx: str, cfg: dict, yes_prod: bool) -> list[Finding]:
    prod = cfg.get("prod_patterns", ["*prod*", "*prd*", "*live*"])
    is_prod = any(fnmatch.fnmatch(ctx, g) for g in prod)
    if is_prod and not yes_prod:
        if sys.stdin.isatty():
            emit(f"`{ctx}` matches prod_patterns. List its cronjobs and services (read-only)? [y/N] ", err=True)
            if sys.stdin.readline().strip().lower() != "y":
                raise PermissionError(f"not connecting to production context {ctx}")
        else:
            raise PermissionError(f"{ctx} matches prod_patterns; pass --yes-prod to list it, or run at a terminal to be asked")
    found = []
    for what, cols in (("cronjobs", "NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule"),
                       ("services", "NS:.metadata.namespace,NAME:.metadata.name")):
        argv = ["kubectl", "--context", ctx, "get", what, "-A", "-o", f"custom-columns={cols}", "--no-headers"]
        rc, out, err = run(argv, timeout=30)
        how = " ".join(argv)
        if rc != 0:
            relogin = "the re-login command listed for this context above"
            found.append(Finding("access", f"`{ctx}`: listing {what} failed: {first_line(err)} (an auth error here means re-login: {relogin})", how))
            continue
        rows = [ln.split() for ln in out.splitlines() if ln.strip()]
        if what == "cronjobs":
            for r in rows[:100]:
                found.append(Finding("control", f"cronjob `{r[0]}/{r[1]}` in `{ctx}` on `{' '.join(r[2:])}`", how))
        else:
            for r in rows:
                for kind, label, rx in IMAGES:
                    if re.search(rx, r[1]):
                        found.append(Finding(kind, f"{label} service `{r[0]}/{r[1]}` in `{ctx}`", how))
                        break
    return found


# ---- inventory.md ----------------------------------------------------------------

def write_inventory(findings: list[Finding], path: Path) -> None:
    kept = ""
    if path.is_file():
        old = path.read_text()
        i = old.find("\n## Skills\n")
        kept = old[i + 1:] if i >= 0 else ""
    now = iso(datetime.now(timezone.utc))
    lines = ["# skill-forge inventory", "",
             f"Written by discover.py at {now}. Findings are rewritten each run; the Skills section is kept.", "", "## Findings", ""]
    for kind in ("access", "observability", "data", "control", "repos"):
        lines += [f.line() for f in findings if f.kind == kind]
    text = "\n".join(lines) + "\n\n" + (kept or "## Skills\n\n")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(masker()(text))


def self_test() -> int:
    bad = [q for q in (ROLES_SQL, SERVER_SQL) if not sqlguard.check(q)[0]]
    for q in bad:
        emit(f"MISS a fixed probe query fails the read-only guard: {q[:80]}", err=True)
    rc = sqlguard.self_test(io.StringIO())
    emit(f"self-test: {2 - len(bad)} of 2 probe queries pass the guard; guard corpus {'FAILED' if rc else 'passed'}")
    return 1 if bad or rc else EXIT_OK


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("--repo-root", action="append", default=None)
    p.add_argument("--probe-local", action="store_true")
    p.add_argument("--probe-context")
    p.add_argument("--yes-prod", action="store_true")
    p.add_argument("--self-test", action="store_true", help="check the fixed probe queries offline")
    a = p.parse_args(argv)
    if a.self_test:
        return self_test()
    cfg = read_toml(config_path()).get("discover", {})
    roots = a.repo_root or cfg.get("repo_roots", ["~/code", "~/src", "~/work"])
    findings = kube(cfg) + aws_profiles() + gcloud() + tools() + containers(a.probe_local) + env_vars() + repos(roots)
    if a.probe_context:
        try:
            findings += probe_context(a.probe_context, cfg, a.yes_prod)
        except PermissionError as e:
            emit(f"REFUSED: {e}", err=True)
            return EXIT_REFUSED
    inv = state_dir() / "inventory.md"
    write_inventory(findings, inv)
    probes = "docker exec and buildinfo on local containers" if a.probe_local else "none (passive)"
    emit(header(target=f"this machine; probes: {probes}" + (f"; kube context {a.probe_context}" if a.probe_context else ""),
                window=f"n/a: the machine as of {iso(datetime.now(timezone.utc))}", rows=len(findings)))
    for kind in ("access", "observability", "data", "control", "repos"):
        emit(f"{kind:<14} {sum(f.kind == kind for f in findings)}")
    emit(f"wrote {inv}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
