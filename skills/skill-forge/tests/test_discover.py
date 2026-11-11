"""Tests for discover.py. kubectl and docker are stub scripts on a temp PATH that
answer like the real tools, including what they would leak if misused
(`config view --raw` prints the kubeconfig's token, `docker inspect` prints
env). A random canary is planted in env vars, the kubeconfig, ~/.aws/config
and the credentials file, and must appear in no output.

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


class Env:
    """A temp HOME, PATH of stubs, planted canary, config and state dir."""

    def __init__(self, config: str = ""):
        self.config = config

    def __enter__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="discover-test."))
        self.canary = "sfcanary" + uuid.uuid4().hex
        stubs = self.tmp / "stubs"
        stubs.mkdir()
        for name, body in (("kubectl", KUBECTL), ("docker", DOCKER)):
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
        env = {
            "PATH": f"{stubs}{os.pathsep}/usr/bin{os.pathsep}/bin", "HOME": str(self.tmp), "STUB_LOG": str(self.log),
            "KUBECONFIG": str(kube), "AWS_CONFIG_FILE": str(aws), "AWS_SHARED_CREDENTIALS_FILE": str(self.creds),
            "SKILL_FORGE_CONFIG": str(cfg), "SKILL_FORGE_STATE": str(self.state), "CANARY": self.canary,
            "PGPASSWORD": self.canary, "DD_API_KEY": self.canary, "DD_SITE": "datadoghq.test",
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
