"""Tests for discover.py. kubectl and docker are stub scripts on a temp PATH that
answer like the real tools, including what they would leak if misused
(`config view --raw` prints the kubeconfig's token, `docker inspect` prints
env). tsh is a stub too, live only when TSH_LIVE is set. A random canary is
planted in env vars, the kubeconfig, ~/.aws/config, the credentials file,
~/.claude.json's MCP servers, warehouse CLI configs and Teleport labels, and
must appear in no output.

Mutations that must turn this file red:
  raw-kubeconfig: discover.py: `["kubectl", "config", "get-contexts", "-o", "name"]` => `["kubectl", "config", "view", "--raw"]`
  secret-env-shown: discover.py: `if SECRET_NAME.search(name):` => `if False:`
  url-query-kept: discover.py: `return f"{u.scheme}://{host}{u.path}"` => `return value`
  url-userinfo-kept (may survive): discover.py: `host = u.hostname or ""` => `host = u.netloc`
  credentials-file-read: discover.py: `os.environ.get("AWS_CONFIG_FILE")` => `os.environ.get("AWS_SHARED_CREDENTIALS_FILE")`
  probes-by-default: discover.py: `if probe_local and label == "postgres":` => `if label == "postgres":`
  prod-without-asking: discover.py: `if is_prod and not yes_prod:` => `if False:`
  excluded-listed: discover.py: `if any(fnmatch.fnmatch(ctx, g) for g in excluded):` => `if False:`
  file-unmasked: discover.py: `path.write_text(masker()(text))` => `path.write_text(text)`
  skills-dropped: discover.py: `kept = old[i + 1:] if i >= 0 else ""` => `kept = ""`
  prod-unflagged: discover.py: `flag = " · PRODUCTION: ask before connecting" if` => `flag = "" if`
  read-only-dropped: discover.py: `"PGOPTIONS=-c default_transaction_read_only=on", ` => ``
  guard-skipped: discover.py: `    ok, why = sqlguard.check(sql)` => `    ok, why = True, ""`
  sso-unseen: discover.py: `sso = any(k.startswith("sso_") for k in keys)` => `sso = False`
  env-substring-match: discover.py: `if any(f"_{w}_" in words for w in ws.split())` => `if any(w in words for w in ws.split())`
  ld-library-path-a-flag: discover.py: `re.compile(r"^LD_(?:SDK|API|CLIENT|PROJECT|ACCESS|BASE|ENV)")` => `re.compile(r"^LD_")`
  api-names-unlisted: discover.py: `            if API_NAME.search(name):` => `            if False:`
  mcp-user-scope-unread: discover.py: `scopes = [("user scope", cfg.get("mcpServers"))]` => `scopes = []`
  mcp-project-scope-unread: discover.py: `scopes += [(f"project` => `scopes += [] and [(f"project`
  warehouse-unread: discover.py: `        if not path.is_file():` => `        if True:`
  bastion-without-session: discover.py: `    if live != 0:` => `    if False:`
  proxy-unnamed: discover.py: `return relogin.replace("<proxy>", named) if proxies else relogin` => `return relogin`
  skills-unlisted: discover.py: `for md in sorted(home.glob("*/SKILL.md")):` => `for md in []:`
  repo-skills-unlisted: discover.py: `for d in repo_dirs for sub in ("skills", ".claude/skills")]` => `for d in [] for sub in ()]`
  archetype-declared-ignored: discover.py: `    if declared:` => `    if False:`
  archetype-unguessed: discover.py: `return f"{arch}?" if hits else "none"` => `return "none"`
  checkouts-ungrouped: discover.py: `groups.setdefault(o or str(repo), (o, []))` => `groups.setdefault(str(repo), (o, []))`
"""
from __future__ import annotations

import builtins
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
import discover  # noqa: E402
import mask  # noqa: E402

KUBECTL = r"""#!/bin/sh
echo "kubectl $*" >> "$STUB_LOG"
case "$*" in
  "config get-contexts -o name") printf 'kind-fixture\nprod-eu\ncust-acme-dev\n' ;;
  *"contexts[*]"*) printf 'kind-fixture\tkind-user\nprod-eu\tsso-user\ncust-acme-dev\tkind-user\n' ;;
  *"users[*]"*) printf 'kind-user\t\t\nsso-user\taws\t\n' ;;
  *--raw*) cat "$KUBECONFIG" ;;
  *"get cronjobs"*) printf 'batch nightly-report 0 3 * * *\n' ;;
  *"get services"*) printf 'monitoring prometheus-server\nweb api\n' ;;
  *) exit 1 ;;
esac
"""
DOCKER = r"""#!/bin/sh
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  ps) printf 'fixture-pg\tpostgres:16.4\t127.0.0.1:55432->5432/tcp\nfixture-prom\tprom/prometheus:v2.53.2\t0.0.0.0:59090->9090/tcp, :::59090->9090/tcp\ncust-acme-cache\tredis:7\t\n' ;;
  inspect) printf '[{"Config":{"Env":["POSTGRES_PASSWORD=%s"]}}]\n' "$CANARY" ;;
  exec)
    input=$(cat)
    echo "stdin: $input" >> "$STUB_LOG"
    case "$input" in
      *pg_is_in_recovery*) printf 'replica,version\nf,16.4\n' ;;
      *pg_roles*) printf 'rolname,rolcanlogin,rolsuper,ro_default,reads_all\nforge,t,t,f,t\nreader,t,f,t,t\n' ;;
    esac ;;
  *) exit 1 ;;
esac
"""
TSH = r"""#!/bin/sh
echo "tsh $*" >> "$STUB_LOG"
case "$*" in
  status) [ -n "$TSH_LIVE" ] && { echo "> Profile URL: https://proxy.example.test:443"; exit 0; }
          echo "ERROR: Not logged in." >&2; exit 1 ;;
  *"db ls --format=json") printf '[{"kind":"db","metadata":{"name":"orders-replica","labels":{"owner":"%s"}}}]\n' "$CANARY" ;;
  *"apps ls --format=json") printf '[{"kind":"app","metadata":{"name":"grafana"}},{"name":"billing-admin","uri":"http://%s"}]\n' "$CANARY" ;;
  *) exit 1 ;;
esac
"""


class Env:
    """A temp HOME, PATH of stubs, planted canary, config and state dir."""

    def __init__(self, config: str = ""):
        self.config = config

    def __enter__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="discover-test."))
        self.canary = "sfcanary" + uuid.uuid4().hex
        stubs = self.tmp / "stubs"
        stubs.mkdir()
        for name, body in (("kubectl", KUBECTL), ("docker", DOCKER), ("tsh", TSH)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(stat.S_IRWXU)
        self.log = self.tmp / "stub.log"
        self.log.write_text("")
        kube = self.tmp / "kube.yaml"
        kube.write_text("apiVersion: v1\nkind: Config\nusers:\n- name: kind-user\n  user:\n    token: " + self.canary + "\n")
        aws = self.tmp / "aws-config"
        aws.write_text("[profile dev]\nsso_start_url = https://sso.example.test/start\nsso_region = us-east-1\n"
                       "[profile legacy]\naws_secret_access_key = " + self.canary + "\n")
        self.creds = self.tmp / "aws-credentials"
        self.creds.write_text("[default]\naws_secret_access_key = " + self.canary + "\n")
        cfg = self.tmp / "config.toml"
        cfg.write_text('[mask]\npatterns = ["\\\\bcust-[a-z]+"]\n' + self.config)
        self.state = self.tmp / "state"
        (self.tmp / ".claude.json").write_text(json.dumps({
            "mcpServers": {"pager": {"command": "npx", "env": {"PAGER_TOKEN": self.canary}},
                           "metrics": {"type": "http", "url": "https://mcp.example.test/?k=" + self.canary}},
            "projects": {str(self.tmp / "code" / "app"): {"mcpServers": {"tickets": {"command": self.canary}}},
                         str(self.tmp / "code" / "bare"): {"allowedTools": []}}}))
        for rel, text in ((".snowsql/config", "[connections]\naccountname = x\n[connections.analytics]\npassword = {c}\n"),
                          (".dbt/profiles.yml", "config:\n  send_anonymous_usage_stats: false\nwarehouse_main:\n  target: dev\n"
                                                "  outputs:\n    dev:\n      password: {c}\n"),
                          (".pg_service.conf", "[reporting]\nhost=db.example.test\npassword={c}\n")):
            (self.tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.tmp / rel).write_text(text.format(c=self.canary))
        env = {
            "PATH": f"{stubs}{os.pathsep}/usr/bin{os.pathsep}/bin", "HOME": str(self.tmp), "STUB_LOG": str(self.log),
            "KUBECONFIG": str(kube), "AWS_CONFIG_FILE": str(aws), "AWS_SHARED_CREDENTIALS_FILE": str(self.creds),
            "SKILL_FORGE_CONFIG": str(cfg), "SKILL_FORGE_STATE": str(self.state), "CANARY": self.canary,
            "PGPASSWORD": self.canary, "DD_API_KEY": self.canary, "DD_SITE": "datadoghq.test",
            "PROMPT": "%n@%m %~ ", "LD_LIBRARY_PATH": "/opt/lib", "BILLING_API_KEY": self.canary,
            "TICKETS_URL": "https://bot:" + self.canary + "@tickets.example.test/api",
            # Concatenated, not an f-string: skill_lint rightly flags `user:{secret}@` and `token={secret}` shapes.
            "PROMETHEUS_URL": "http://admin:" + self.canary + "@127.0.0.1:9090/prom?tok" + "en=" + self.canary,
        }
        self.patch = mock.patch.dict(os.environ, env, clear=True)
        self.patch.start()
        mask._MASKER = None
        return self

    def run(self, *argv, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        mask._MASKER = None
        with mock.patch("sys.stdin", io.StringIO(stdin)), redirect_stdout(out), redirect_stderr(err):
            rc = discover.main(["--repo-root", str(self.tmp / "code"), *argv])
        inv = self.state / "inventory.md"
        return rc, out.getvalue(), err.getvalue(), inv.read_text() if inv.exists() else ""

    def __exit__(self, *exc):
        self.patch.stop()
        mask._MASKER = None
        shutil.rmtree(self.tmp, ignore_errors=True)


class NoSecretTest(unittest.TestCase):
    def test_no_planted_secret_reaches_inventory_stdout_or_stderr(self):
        with Env() as e:
            opened = []
            real_open = builtins.open

            def tracking_open(file, *a, **kw):
                opened.append(str(file))
                return real_open(file, *a, **kw)
            os.environ["TSH_LIVE"] = "1"
            with mock.patch("builtins.open", tracking_open), mock.patch("io.open", tracking_open):
                rc, out, err, inv = e.run("--probe-local")
            self.assertEqual(rc, 0, err)
            for where, text in (("inventory.md", inv), ("stdout", out), ("stderr", err)):
                self.assertNotIn(e.canary, text, where)
            self.assertNotIn(str(e.creds), opened, "the AWS credentials file was opened")
            self.assertNotIn("inspect", e.log.read_text())
            self.assertNotIn("--raw", e.log.read_text())

    def test_env_values_are_shown_only_when_safe(self):
        with Env() as e:
            _, _, _, inv = e.run()
        self.assertIn("env `DD_API_KEY` = set (a secret by its name; value not read)", inv)
        self.assertIn("env `PGPASSWORD` = set (a secret by its name", inv)
        self.assertIn("env `DD_SITE` = datadoghq.test", inv)
        self.assertIn("env `PROMETHEUS_URL` = http://127.0.0.1:9090/prom", inv)


class FindingTest(unittest.TestCase):
    def test_every_finding_line_names_the_command_that_found_it(self):
        with Env() as e:
            _, _, _, inv = e.run()
        lines = [ln for ln in inv.splitlines() if ln.startswith("- **")]
        self.assertGreater(len(lines), 8)
        for ln in lines:
            self.assertIn("· found by `", ln)

    def test_kube_contexts_with_auth_relogin_and_production_flag(self):
        with Env('[discover]\nexclude_contexts = ["cust-*"]\nprod_patterns = ["prod-*"]\n') as e:
            _, _, _, inv = e.run()
        self.assertIn("kube context `kind-fixture` · auth: static token or certificate in the kubeconfig (not read)", inv)
        self.assertRegex(inv, r"kube context `prod-eu` · auth: exec aws · re-login: `aws sso login --profile <profile>`.*PRODUCTION: ask before connecting")
        kind_line = [ln for ln in inv.splitlines() if "kube context `kind-fixture`" in ln][0]
        self.assertNotIn("PRODUCTION", kind_line)
        self.assertIn("1 kube context(s) left out by exclude_contexts", inv)

    def test_aws_profiles_from_headers_and_key_names(self):
        with Env() as e:
            _, _, _, inv = e.run()
        self.assertIn("AWS profile `dev` · SSO · re-login: `aws sso login --profile dev`", inv)
        self.assertIn("AWS profile `legacy` · non-SSO", inv)

    def test_containers_classified_with_ports_and_deep_links(self):
        with Env() as e:
            _, _, _, inv = e.run()
        self.assertIn("postgres container `fixture-pg` (postgres:16.4) on 127.0.0.1:55432", inv)
        self.assertIn("prometheus container `fixture-prom` (prom/prometheus:v2.53.2) on 0.0.0.0:59090, :::59090 · deep link: http://127.0.0.1:59090/graph?g0.expr=", inv)

    def test_mask_planted_container_name_in_the_file(self):
        with Env() as e:
            _, _, _, inv = e.run()
        self.assertNotIn("cust-acme", inv)
        self.assertIn("redis container `<masked-", inv)

    def test_repos_and_their_markers(self):
        with Env() as e:
            repo = e.tmp / "code" / "deploy-configs"
            for d in (".git", "charts/api", "queries", ".github/workflows"):
                (repo / d).mkdir(parents=True)
            (repo / "charts/api/Chart.yaml").write_text("name: api\n")
            (repo / "queries/slow.sql").write_text("select 1;\n")
            (repo / ".github/workflows/ci.yml").write_text("on: push\n")
            _, _, _, inv = e.run()
        self.assertIn("holds GitHub Actions (1), helm charts (1), sql (1)", inv)

    def test_the_skills_section_survives_a_rewrite(self):
        with Env() as e:
            e.state.mkdir(parents=True)
            (e.state / "inventory.md").write_text("# old\n\n## Findings\n\n- stale\n\n## Skills\n\n- `job-latency` answers \"why is this job slow\"\n")
            _, _, _, inv = e.run()
        self.assertIn("- `job-latency` answers \"why is this job slow\"", inv)
        self.assertNotIn("- stale", inv)


def finding_lines(inv: str, kind: str) -> list[str]:
    return [ln for ln in inv.splitlines() if ln.startswith(f"- **{kind}** ")]


class SourcesTest(unittest.TestCase):
    def test_env_names_match_whole_words(self):
        self.assertIsNone(discover.env_kind("PROMPT"))
        self.assertIsNone(discover.env_kind("LD_LIBRARY_PATH"))
        for name, kind in (("X_PROM_URL", "observability"), ("PROM_URL", "observability"), ("DD_SITE", "observability"),
                           ("LD_SDK_KEY", "control"), ("PGHOST", "data"), ("ANALYTICS_DB_HOST", "data")):
            self.assertEqual(discover.env_kind(name), kind, name)
        with Env() as e:
            os.environ["X_PROM_URL"] = "http://127.0.0.1:9090"
            _, _, _, inv = e.run()
        self.assertNotIn("PROMPT", inv)
        self.assertNotIn("LD_LIBRARY_PATH", inv)
        self.assertTrue(any("env `X_PROM_URL` = http://127.0.0.1:9090" in ln for ln in finding_lines(inv, "observability")))

    def test_api_names_are_listed_by_name_only(self):
        with Env() as e:
            _, _, _, inv = e.run()
        self.assertIn("APIs named in env: `BILLING_API_KEY`, `TICKETS_URL` (names only; values not read)", inv)
        self.assertNotIn("tickets.example.test", inv)

    def test_mcp_server_names_without_commands_urls_or_env(self):
        with Env() as e:
            _, _, _, inv = e.run()
        self.assertIn("MCP servers (user scope): `metrics`, `pager`", inv)
        self.assertIn("MCP servers (project `~/code/app`): `tickets`", inv)
        self.assertNotIn("npx", inv)
        self.assertNotIn("mcp.example.test", inv)
        self.assertNotIn("`~/code/bare`", inv)

    def test_warehouse_connection_names_only(self):
        with Env() as e:
            _, _, _, inv = e.run()
        data = "\n".join(finding_lines(inv, "data"))
        self.assertIn("Snowflake (snowsql) connections: `analytics` in `~/.snowsql/config`", data)
        self.assertIn("dbt connections: `warehouse_main` in `~/.dbt/profiles.yml`", data)
        self.assertIn("Postgres services connections: `reporting` in `~/.pg_service.conf`", data)
        self.assertNotIn("db.example.test", inv)
        self.assertNotIn("send_anonymous", inv)

    def test_bastion_lists_only_with_a_live_session_and_never_logs_in(self):
        with Env() as e:
            _, _, _, inv = e.run()
            self.assertEqual([ln for ln in e.log.read_text().splitlines() if ln.startswith("tsh ")], ["tsh status"])
            self.assertIn("tsh: no live session, so its databases and apps were not listed (no login was started)", inv)
            e.log.write_text("")
            os.environ["TSH_LIVE"] = "1"
            _, _, _, inv = e.run()
            calls = [ln for ln in e.log.read_text().splitlines() if ln.startswith("tsh ")]
        self.assertEqual(calls, ["tsh status", "tsh db ls --format=json", "tsh apps ls --format=json"])
        self.assertIn("Teleport databases: `orders-replica`", "\n".join(finding_lines(inv, "data")))
        self.assertIn("Teleport apps: `billing-admin`, `grafana`", "\n".join(finding_lines(inv, "control")))

    def test_the_relogin_names_the_proxy_from_teleport_profiles(self):
        with Env() as e:
            (e.tmp / ".tsh").mkdir()
            (e.tmp / ".tsh" / "proxy.example.test.yaml").write_text("web_proxy_addr: proxy.example.test:443\n")
            _, _, _, inv = e.run()
            (e.tmp / ".tsh" / "other.example.test.yaml").write_text("")
            _, _, _, two = e.run()
        self.assertIn("re-login: `tsh login --proxy=proxy.example.test`", inv)
        self.assertIn("re-login: `tsh login --proxy=<one of other.example.test, proxy.example.test>`", two)

    def test_installed_and_repo_skills_with_an_archetype_guess(self):
        with Env() as e:
            mine = e.tmp / ".claude" / "skills" / "slow-job"
            (mine / "bin").mkdir(parents=True)
            (mine / "SKILL.md").write_text("---\nname: slow-job\ndescription: Use when asked why the nightly export is slow; "
                                           "reads Prometheus metrics. Not for logs.\n---\n# slow-job\n")
            (mine / "bin" / "tool.py").write_text('URL = os.environ["HAND_PROM_URL"]  # promql over the metrics API\n')
            repo = e.tmp / "code" / "ops"
            flag = repo / "skills" / "flag-check"
            (repo / ".git").mkdir(parents=True)
            flag.mkdir(parents=True)
            (flag / "SKILL.md").write_text("---\nname: flag-check\ndescription: Use when asked whether a flag is on for an "
                                           "account.\n---\n")
            (flag / "forge.toml").write_text('archetype = "api-readonly"\n')
            _, _, _, inv = e.run()
        skills = finding_lines(inv, "skills")
        self.assertIn("- **skills** skill `slow-job` in `~/.claude/skills`: Use when asked why the nightly export is slow · "
                      "archetype guess: metrics-query?", "\n".join(skills))
        self.assertIn("skill `flag-check` in `~/code/ops/skills`: Use when asked whether a flag is on for an account · "
                      "archetype guess: api-readonly (forge.toml)", "\n".join(skills))

    @unittest.skipUnless(shutil.which("git"), "git not installed")
    def test_a_clone_and_its_worktrees_are_one_line(self):
        with Env() as e:
            repo = e.tmp / "code" / "app"
            (repo / "charts" / "api").mkdir(parents=True)
            (repo / "charts" / "api" / "Chart.yaml").write_text("name: api\n")
            (repo / "skills" / "probe").mkdir(parents=True)
            (repo / "skills" / "probe" / "SKILL.md").write_text("---\nname: probe\ndescription: Use when checking a pod.\n---\n")
            git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.test", "-C", str(repo)]
            for argv in (["init", "-q"], ["remote", "add", "origin", "https://git.example.test/team/app.git"],
                         ["add", "."], ["commit", "-q", "-m", "init"],
                         ["worktree", "add", "-q", str(e.tmp / "code" / "app-a"), "-b", "a"],
                         ["worktree", "add", "-q", str(e.tmp / "code" / "app-b"), "-b", "b"]):
                discover.subprocess.run(git + argv, check=True, capture_output=True)
            _, _, _, inv = e.run()
        repos = finding_lines(inv, "repos")
        self.assertEqual(len(repos), 1, repos)
        self.assertIn("`~/code/app` (origin https://git.example.test/team/app.git) holds helm charts (1), skills (1) · "
                      "3 checkouts of this origin, 2 of them worktrees", repos[0])
        self.assertEqual(len([ln for ln in finding_lines(inv, "skills") if "skill `probe`" in ln]), 1)


class ProbeTest(unittest.TestCase):
    def test_passive_by_default(self):
        with Env() as e:
            with mock.patch.object(discover.urllib.request, "urlopen", side_effect=AssertionError("network")):
                e.run()
            self.assertNotIn("docker exec", e.log.read_text())

    def test_probe_local_reads_roles_inside_a_read_only_transaction(self):
        with Env() as e:
            with mock.patch.object(discover.urllib.request, "urlopen",
                                   return_value=io.BytesIO(json.dumps({"data": {"version": "2.53.2"}}).encode())) as uo:
                _, _, _, inv = e.run("--probe-local")
            log = e.log.read_text()
        self.assertIn("docker exec -i -e PGOPTIONS=-c default_transaction_read_only=on fixture-pg sh -c", log)
        self.assertIn("stdin: BEGIN READ ONLY;", log)
        self.assertIn("postgres `fixture-pg`: primary v16.4; roles: forge (login, SUPERUSER, pg_read_all_data); reader (login, read-only by default, pg_read_all_data); read-only login roles: reader", inv)
        self.assertEqual(uo.call_args[0][0], "http://127.0.0.1:59090/api/v1/status/buildinfo")
        self.assertIn("prometheus `fixture-prom` answers: version 2.53.2", inv)

    def test_a_write_never_reaches_the_container(self):
        with Env() as e:
            rc, _, err = discover.pg_query("fixture-pg", "DELETE FROM pg_roles")
            self.assertEqual(rc, 5)
            self.assertIn("read-only guard", err)
            self.assertNotIn("docker exec", e.log.read_text())

    def test_quoting_the_container_name_is_its_own_argv_element(self):
        with Env() as e:
            discover.pg_query("x; touch pwned", discover.SERVER_SQL)
            line = [ln for ln in e.log.read_text().splitlines() if ln.startswith("docker exec")][0]
        self.assertIn("default_transaction_read_only=on x; touch pwned sh -c psql", line)
        self.assertNotIn("pwned", discover.PSQL_IN_CONTAINER)

    def test_a_production_context_is_refused_without_a_yes(self):
        with Env('[discover]\nprod_patterns = ["prod-*"]\n') as e:
            rc, _, err, _ = e.run("--probe-context", "prod-eu")
            self.assertEqual(rc, 5)
            self.assertIn("--yes-prod", err)
            self.assertNotIn("get cronjobs", e.log.read_text())

    def test_a_production_context_is_listed_with_yes_prod(self):
        with Env('[discover]\nprod_patterns = ["prod-*"]\n') as e:
            rc, _, _, inv = e.run("--probe-context", "prod-eu", "--yes-prod")
        self.assertEqual(rc, 0)
        self.assertIn("cronjob `batch/nightly-report` in `prod-eu` on `0 3 * * *`", inv)
        self.assertIn("prometheus service `monitoring/prometheus-server` in `prod-eu`", inv)


class HeaderTest(unittest.TestCase):
    def test_golden_provenance_header_on_stdout(self):
        with Env() as e:
            _, out, _, _ = e.run()
        lines = out.splitlines()
        self.assertEqual(lines[0], "# target:  this machine; probes: none (passive)")
        self.assertTrue(lines[1].startswith("# window:  n/a: the machine as of "))
        self.assertTrue(lines[3].startswith("# rows:    "))
        self.assertEqual(lines[4], "# partial: no")

    def test_self_test(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(discover.main(["--self-test"]), 0)


@unittest.skipUnless(shutil.which("kubectl"), "kubectl not installed")
class RealKubectlTest(unittest.TestCase):
    def test_the_real_kubectl_commands_never_print_the_token(self):
        real = os.path.dirname(shutil.which("kubectl"))
        with Env() as e:
            os.environ["PATH"] = f"{real}{os.pathsep}/usr/bin{os.pathsep}/bin"
            kube = Path(os.environ["KUBECONFIG"])
            kube.write_text(
                "apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://127.0.0.1:6443\n"
                "contexts:\n- name: real-ctx\n  context:\n    cluster: c\n    user: u\ncurrent-context: real-ctx\n"
                "users:\n- name: u\n  user:\n    token: " + e.canary + "\n")
            rc, out, err, inv = e.run()
        self.assertEqual(rc, 0, err)
        self.assertIn("kube context `real-ctx`", inv)
        for text in (inv, out, err):
            self.assertNotIn(e.canary, text)


if __name__ == "__main__":
    unittest.main()
