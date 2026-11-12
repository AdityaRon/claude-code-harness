"""Tests for forge.py. Every archetype renders to a skill whose own tests pass
and which skill_lint passes with each engine check exercised; draft refuses
leftover placeholders, bad names and a folder that is not a draft; install is
a dry run without --apply, refuses the public harness and a skill the lint
fails, and records the question in inventory.md.

Mutations that must turn this file red:
  placeholders-left: forge.py: `    if left:` => `    if False:`
  helpers-not-vendored: forge.py: `shutil.copy2(BIN / v, out / "bin" / v)` => `pass`
  shared-tests-not-vendored: forge.py: `shutil.copy2(shared / t, out / "tests" / t)` => `pass`
  install-without-apply: forge.py: `    if not apply:` => `    if False:`
  harness-allowed: forge.py: `    if harness:` => `    if False:`
  any-forge-toml-is-a-draft: forge.py: `if "archetype" not in (read_toml(out / "forge.toml") if (out / "forge.toml").is_file() else {}):` => `if not (out / "forge.toml").is_file():`
  lint-skipped: forge.py: `    if failing:` => `    if False:`
  question-unrecorded: forge.py: `    record(name, m.get("question", "?"), m.get("archetype", "?"), dest)` => `    pass`
  non-draft-replaced: forge.py: `if not (out / "forge.toml").is_file():` => `if False:`
  bad-name-allowed: forge.py: `if not NAME.fullmatch(name):` => `if False:`
  yaml-unquoted: forge.py: `if ": " in text or " #" in text or` => `if False and`
  guards-dropped: forge.py: `f"guards = {toml_value(spec.get('guards', []))}",` => `"guards = []",`
  compare-apply-passed: forge.py: `if any("--apply" in a for a in (args_d or []) + (args_e or [])):` => `if False:`
  compare-headers-counted: forge.py: `if not ln.lstrip().startswith("#"))` => `if True)`
  compare-noise-counted: forge.py: `NUMBER.findall(NOT_A_VALUE.sub(" ", body))` => `NUMBER.findall(body)`
  compare-required-unreported: forge.py: `        if not e["guards"][g]:` => `        if False:`
  compare-template-guards-unreported: forge.py: `if ev and not d["guards"][g]:` => `if False:`
  compare-template-subs-unreported: forge.py: `only = sorted(e["subs"] - d["subs"])` => `only = []`
  compare-case-arms-unread: forge.py: `subs |= {a.strip() for a in arm.split("|")}` => `pass`
  compare-help-unguarded: forge.py: `    if not handles:` => `    if False:`
  compare-usage-subs-unread: forge.py: `subs |= named` => `pass`
  compare-flat-unread: forge.py: `draft_dir, existing = draft_dir.resolve(), existing.resolve()` => `pass`
  units-dropped: forge.py: `(?:[a-zA-Z%]{1,3})?(?![\\w.])")` => `(?![\\w.])")`
  precision-ignored: forge.py: `n = min(sig_digits(va), sig_digits(vb))` => `n = 6`
  failed-runs-compared: forge.py: `if rc_d in NOT_AN_ANSWER or rc_e in NOT_AN_ANSWER:` => `if False:`
"""
from __future__ import annotations

import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
sys.path.insert(0, str(SKILL / "bin"))
import forge  # noqa: E402
import mask  # noqa: E402
import skill_lint  # noqa: E402

ARCHETYPES = ["api-readonly", "cluster-probe", "job-run", "local-repro", "logs-fetch", "metrics-query", "runbook", "sql-readonly"]


class Tmp:
    def __enter__(self) -> Path:
        self.dir = Path(tempfile.mkdtemp(prefix="forge-test."))
        self.env = mock.patch.dict(os.environ, {"SKILL_FORGE_STATE": str(self.dir / "state"),
                                                "SKILL_FORGE_CONFIG": str(self.dir / "absent.toml"),
                                                "SKILL_FORGE_TEMPLATES": str(SKILL / "templates")})
        self.env.start()
        mask._MASKER = None
        return self.dir

    def __exit__(self, *exc):
        self.env.stop()
        mask._MASKER = None
        shutil.rmtree(self.dir, ignore_errors=True)


def quiet(fn, *a, **kw):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = fn(*a, **kw)
    return rc, out.getvalue(), err.getvalue()


class RenderTest(unittest.TestCase):
    def test_every_archetype_is_listed(self):
        self.assertEqual(sorted(forge.archetypes()), ARCHETYPES)

    def test_every_archetype_renders_tests_green_and_lint_clean(self):
        for arch in ARCHETYPES:
            with self.subTest(arch=arch), Tmp() as tmp:
                out = forge.draft(arch, f"demo-{arch}", "Why did the nightly export fail?", out=tmp / "d")
                p = subprocess.run([sys.executable, "-B", "tests/run.py"], cwd=out, capture_output=True, text=True,
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), timeout=600)
                self.assertEqual(p.returncode, 0, p.stdout[-2000:] + p.stderr[-2000:])
                self.assertRegex(p.stdout, r"--- Results: \d+ passed, 0 failed ---")
                res = skill_lint.lint(out)
                self.assertEqual({k for k, r in res.items() if r.status == "FAIL"}, set(), {k: r.detail for k, r in res.items()})
                for c in ("C3", "C5", "C6", "C7", "C8", "C9", "C10"):
                    self.assertEqual(res[c].status, "PASS", f"{arch} {c}: {res[c].detail}")
                self.assertEqual(sorted(p.name for p in (out / "tests").glob("test_*.py")),
                                 sorted(f"test_{p.name}" for p in (out / "bin").glob("*.py")))

    def test_the_manifest_carries_the_archetypes_guards(self):
        with Tmp() as tmp:
            out = forge.draft("metrics-query", "job-latency", "why is this job slow", out=tmp / "d")
            m = mask.read_toml(out / "forge.toml")
        self.assertEqual(m["guards"], forge.archetypes()["metrics-query"]["guards"])
        self.assertEqual((m["name"], m["question"], m["engines"]), ("job-latency", "why is this job slow", ["job_latency.py"]))

    def test_a_question_with_a_colon_still_parses_as_frontmatter(self):
        with Tmp() as tmp:
            out = forge.draft("sql-readonly", "export-status", "status: is the export done # today", out=tmp / "d")
            text = (out / "SKILL.md").read_text()
            front = skill_lint.frontmatter(text)
        self.assertIn('Use when asked "status: is the export done # today"', front["description"])
        # YAML reads `a: b: c` as an error and ` #` as a comment, so the line must be quoted.
        line = [ln for ln in text.splitlines() if ln.startswith("description:")][0]
        self.assertTrue(line.startswith('description: "Use when asked \\"status: is the export done # today\\"'), line)

    def test_a_leftover_placeholder_fails_the_draft(self):
        with Tmp() as tmp:
            tpl = tmp / "templates"
            shutil.copytree(SKILL / "templates", tpl)
            p = tpl / "runbook" / "SKILL.md.tmpl"
            p.write_text(p.read_text() + "\n{{owner}}\n")
            os.environ["SKILL_FORGE_TEMPLATES"] = str(tpl)
            with self.assertRaises(ValueError) as cm:
                forge.draft("runbook", "alert-triage", "what does this alert mean", out=tmp / "d")
        self.assertIn("{{owner}}", str(cm.exception))

    def test_bad_names_and_non_drafts_are_refused(self):
        with Tmp() as tmp:
            for bad in ("Has-Caps", "x", "../escape", "a b"):
                with self.assertRaises(ValueError, msg=bad):
                    forge.draft("runbook", bad, "q", out=tmp / "d")
            (tmp / "mine").mkdir()
            (tmp / "mine" / "notes.txt").write_text("keep me")
            with self.assertRaises(ValueError):
                forge.draft("runbook", "alert-triage", "q", out=tmp / "mine", force=True)
            self.assertTrue((tmp / "mine" / "notes.txt").exists())
            # A hand-written skill may hold a forge.toml for the lint (uses, [tests]):
            # without an archetype it is still not a draft.
            (tmp / "mine" / "forge.toml").write_text('uses = ["~/.claude/memory-verify.sh"]\n')
            with self.assertRaisesRegex(ValueError, "not a draft"):
                forge.draft("runbook", "alert-triage", "q", out=tmp / "mine", force=True)
            self.assertTrue((tmp / "mine" / "notes.txt").exists())
            forge.draft("runbook", "alert-triage", "q", out=tmp / "d2")
            forge.draft("runbook", "alert-triage", "q", out=tmp / "d2", force=True)   # a real draft is replaced

    def test_the_shared_copies_match_the_skills_own(self):
        for name in ("run.py", "test_mask.py", "test_sqlguard.py", "test_access.py"):
            self.assertEqual((SKILL / "templates" / "_shared" / "tests" / name).read_text(), (HERE / name).read_text(), name)


class InstallTest(unittest.TestCase):
    def draft(self, tmp: Path) -> Path:
        return forge.draft("metrics-query", "job-latency", "why is this job slow", out=tmp / "draft" / "job-latency")

    def test_install_is_a_dry_run_without_apply(self):
        with Tmp() as tmp:
            d = self.draft(tmp)
            rc, out, _ = quiet(forge.install, d, tmp / "skills" / "job-latency", False)
            self.assertEqual(rc, 0)
            self.assertIn("would copy bin/job_latency.py", out)
            self.assertIn("dry run: nothing written", out)
            self.assertFalse((tmp / "skills").exists())
            self.assertFalse((tmp / "state" / "inventory.md").exists())

    def test_install_with_apply_copies_and_records_the_question(self):
        with Tmp() as tmp:
            d = self.draft(tmp)
            rc, out, _ = quiet(forge.install, d, tmp / "skills" / "job-latency", True)
            self.assertEqual(rc, 0, out)
            self.assertTrue((tmp / "skills" / "job-latency" / "bin" / "job_latency.py").is_file())
            inv = (tmp / "state" / "inventory.md").read_text()
        self.assertIn("## Skills", inv)
        self.assertIn('`job-latency` answers "why is this job slow" · metrics-query', inv)

    def test_install_refuses_the_public_harness(self):
        with Tmp() as tmp:
            d = self.draft(tmp)
            clone = tmp / "harness"
            (clone / "skills" / "skill-forge").mkdir(parents=True)
            (clone / "skills" / "skill-forge" / "SKILL.md").write_text("x")
            subprocess.run(["git", "init", "-q", str(clone)], check=True)
            rc, _, err = quiet(forge.install, d, clone / "skills" / "job-latency", True)
            self.assertEqual(rc, 5)
            self.assertIn("public harness", err)
            self.assertFalse((clone / "skills" / "job-latency").exists())

    def test_install_refuses_a_skill_the_lint_fails(self):
        with Tmp() as tmp:
            d = self.draft(tmp)
            (d / "tests" / "test_job_latency.py").unlink()
            rc, _, err = quiet(forge.install, d, tmp / "skills" / "job-latency", True)
            self.assertEqual(rc, 5)
            self.assertRegex(err, r"skill_lint fails [C0-9, ]*C9")

    def test_golden_provenance_header_on_install(self):
        with Tmp() as tmp:
            d = self.draft(tmp)
            _, out, _ = quiet(forge.install, d, tmp / "skills" / "job-latency", False)
        lines = out.splitlines()
        self.assertEqual(lines[0], f"# target:  {tmp / 'skills' / 'job-latency'}")
        self.assertEqual(lines[1], "# window:  n/a: a copy of files as they are now")
        self.assertEqual(lines[4], "# partial: no")


class MaskTest(unittest.TestCase):
    def test_mask_planted_pattern_in_install_output(self):
        with Tmp() as tmp:
            (tmp / "absent.toml").write_text('[mask]\npatterns = ["\\\\bcust-[a-z]+"]\n')
            d = forge.draft("runbook", "cust-acme-alerts", "what does this alert mean", out=tmp / "d")
            _, out, _ = quiet(forge.install, d, tmp / "skills" / "x", False)
        self.assertNotIn("cust-acme", out)


class CompileTest(unittest.TestCase):
    def test_sources_and_every_draft_compile_without_escape_warnings(self):
        # Python 3.12+ prints these as SyntaxWarning; 3.11 raises DeprecationWarning. Either is an error here.
        with Tmp() as tmp:
            files = [*SKILL.glob("bin/*.py"), *SKILL.glob("tests/*.py"), *SKILL.glob("templates/_shared/tests/*.py")]
            for arch in ARCHETYPES:
                d = forge.draft(arch, f"demo-{arch}", "how many rows", out=tmp / arch)
                files += [*d.glob("bin/*.py"), *d.glob("tests/*.py")]
            bad = []
            for f in files:
                with warnings.catch_warnings():
                    warnings.simplefilter("error")
                    try:
                        compile(f.read_text(), str(f), "exec")
                    except (SyntaxError, SyntaxWarning, DeprecationWarning) as e:
                        bad.append(f"{f.name}: {e}")
        self.assertGreater(len(files), 40)
        self.assertEqual(bad, [])


HAND = HERE / "fixtures" / "compare" / "hand-metrics"
SERIES = [{"metric": {"job": "api"}, "value": [1762850000, "41.5"]}, {"metric": {"job": "db"}, "value": [1762850000, "3.25"]}]


class FakeProm:
    """A Prometheus-shaped API on localhost: every instant query answers two series."""

    def __enter__(self) -> str:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                data = {"/api/v1/query": {"resultType": "vector", "result": SERIES},
                        "/api/v1/status/buildinfo": {"version": "2.53.2"},
                        "/api/v1/series": [{"__name__": "up"}], "/api/v1/label/__name__/values": ["up"]}.get(self.path.split("?")[0])
                body = json.dumps({"status": "success", "data": data}).encode()
                self.send_response(200 if data is not None else 404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self.srv.server_address[1]}"

    def __exit__(self, *exc):
        self.srv.shutdown()
        self.srv.server_close()


class CompareTest(unittest.TestCase):
    def compare(self, tmp: Path, *extra, existing: Path = HAND):
        d = forge.draft("metrics-query", "demo-metrics", "request rate by job", out=tmp / "d")
        return quiet(forge.main, ["compare", str(d), str(existing), *extra])

    def test_compare_lists_guard_and_subcommand_differences(self):
        with Tmp() as tmp:
            rc, out, err = self.compare(tmp)
        self.assertEqual(rc, 0, out + err)
        self.assertTrue(out.startswith("# target:  draft "), out[:200])
        for want in ("for the existing skill: no absent guard, which metrics-query requires",
                     "for the existing skill: no partial guard, which metrics-query requires",
                     "for the existing skill: fails C6, which the draft passes",
                     "for the metrics-query template: the existing skill exposes top, which the draft does not",
                     "ab, instant, query, series, volume-step | query, top",
                     "expired_auth (required): test_guard_expired_auth, prints AUTH or a re-login, exit 4 | "
                     "test_guard_expired_auth, prints AUTH or a re-login, exit 4"):
            self.assertIn(want, out)

    def test_a_guard_only_the_existing_skill_has_is_a_template_finding(self):
        with Tmp() as tmp:
            probe = forge.draft("cluster-probe", "demo-probe", "is the queue draining", out=tmp / "probe")
            rc, out, _ = self.compare(tmp, existing=probe)
        self.assertIn("for the metrics-query template: the existing skill has the incomplete_capture guard "
                      "(test_guard_incomplete_capture, prints a terminal marker)", out)

    def test_subcommands_built_in_a_loop_come_from_the_usage_line(self):
        with Tmp() as tmp:
            logs = forge.draft("logs-fetch", "demo-logs", "why did the export fail", out=tmp / "logs")
            self.assertNotIn("add_parser(\"fetch\"", (logs / "bin" / "demo_logs.py").read_text())
            self.assertEqual(forge.profile(logs, [])["subs"], {"fetch", "streams"})

    def test_run_on_a_fixture_backend_gives_the_same_numbers(self):
        with Tmp() as tmp, FakeProm() as url, mock.patch.dict(os.environ, {"DEMO_METRICS_PROM_URL": url, "HAND_PROM_URL": url}):
            rc, out, err = self.compare(tmp, "--run", "instant 'rate(http_requests_total[5m])'",
                                        "--run-existing", "query 'rate(http_requests_total[5m])'")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("SAME: exit 0 and the same 2 numbers", out)

    def test_relative_folders_run_from_where_they_are(self):
        cwd = os.getcwd()
        with Tmp() as tmp, FakeProm() as url, mock.patch.dict(os.environ, {"DEMO_METRICS_PROM_URL": url, "HAND_PROM_URL": url}):
            d = forge.draft("metrics-query", "demo-metrics", "request rate by job", out=tmp / "d")
            os.chdir(HAND.parent)
            try:
                rc, out, err = quiet(forge.main, ["compare", os.path.relpath(d), "hand-metrics",
                                                  "--run", "instant x", "--run-existing", "query x"])
            finally:
                os.chdir(cwd)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("SAME: exit 0 and the same 2 numbers", out)

    def test_run_tells_different_numbers_apart(self):
        with Tmp() as tmp, FakeProm() as url, mock.patch.dict(os.environ, {"DEMO_METRICS_PROM_URL": url, "HAND_PROM_URL": url}):
            rc, out, err = self.compare(tmp, "--run", "instant x", "--run-existing", "top x --k 1")
        self.assertEqual(rc, mask.EXIT_PARTIAL, out + err)
        self.assertIn("DIFFERENT: exit 0 | 0; only the draft: 3.25; only the existing: -", out)

    def test_run_refuses_apply(self):
        with Tmp() as tmp:
            rc, out, err = self.compare(tmp, "--run", "instant x --apply")
        self.assertEqual(rc, mask.EXIT_REFUSED)
        self.assertIn("REFUSED", err)

    def test_archetype_back_test_drafts_compares_and_cleans_up(self):
        before = set(Path(tempfile.gettempdir()).glob("forge-compare.*"))
        with Tmp():
            rc, out, err = quiet(forge.main, ["compare", "--archetype", "metrics-query", str(HAND)])
        self.assertEqual(rc, 0, out + err)
        self.assertIn("back-test: drafted metrics-query as hand-metrics-draft", out)
        self.assertIn("$HAND_METRICS_DRAFT_* variables", out)
        self.assertEqual(set(Path(tempfile.gettempdir()).glob("forge-compare.*")), before)

    def test_numbers_leave_out_headers_quotes_times_and_masked_ids(self):
        out = '# rows:    5 series\n{instance="10.0.0.1:9090"}  41.5\nlast at 2026-11-11T10:00:00Z <masked-3> -7\n'
        self.assertEqual(forge.numbers(out), ["-7", "41.5"])

    def test_numbers_keep_units_and_compare_to_the_printed_precision(self):
        self.assertEqual(forge.numbers("latency 120ms\nrequests 1234567 v2 40%"), ["40%", "120ms", "1234567"])
        self.assertFalse(forge.same_numbers(forge.numbers("latency 120ms"), forge.numbers("latency 450ms")))
        self.assertFalse(forge.same_numbers(["1234567"], ["1234569"]))
        self.assertFalse(forge.same_numbers(["120ms"], ["120s"]))
        self.assertTrue(forge.same_numbers(["0.666667"], ["0.6666666667"]))

    def test_run_where_neither_engine_answers_is_not_same(self):
        with Tmp() as tmp, mock.patch.dict(os.environ, {"DEMO_METRICS_PROM_URL": "", "HAND_PROM_URL": ""}):
            rc, out, err = self.compare(tmp, "--run", "instant x", "--run-existing", "query x")
        self.assertEqual(rc, mask.EXIT_PARTIAL, out + err)
        self.assertIn("NOT COMPARED: exit 5 | ", out)
        self.assertNotIn("SAME", out)

    def test_a_shell_engines_subcommands_are_its_case_arms(self):
        with Tmp() as tmp:
            s = tmp / "sh-skill"
            s.mkdir()
            (s / "SKILL.md").write_text("---\nname: sh-skill\ndescription: Use when asked.\n---\n")
            (s / "tool.sh").write_text('case "$1" in\n  status|show) echo up ;;\n  restart) echo no ;;\n  -h|--help) echo usage ;;\nesac\n')
            self.assertEqual(forge.profile(s, [])["subs"], {"status", "show", "restart"})

    def test_help_runs_only_when_the_source_handles_it(self):
        with Tmp() as tmp:
            mark = tmp / "ran"
            s = tmp / "sh-skill"
            s.mkdir()
            (s / "tool.sh").write_text(f'touch "{mark}"\n')
            line, _ = forge.usage_line(s, "tool.sh", (s / "tool.sh").read_text())
            self.assertEqual(line, "(no --help in the source; not run)")
            self.assertFalse(mark.exists(), "a script that ignores --help would have run its default action")


if __name__ == "__main__":
    unittest.main()
