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
  lint-skipped: forge.py: `    if failing:` => `    if False:`
  question-unrecorded: forge.py: `    record(name, m.get("question", "?"), m.get("archetype", "?"), dest)` => `    pass`
  non-draft-replaced: forge.py: `if not (out / "forge.toml").is_file():` => `if False:`
  bad-name-allowed: forge.py: `if not NAME.fullmatch(name):` => `if False:`
  yaml-unquoted: forge.py: `if ": " in text or " #" in text or` => `if False and`
  guards-dropped: forge.py: `f"guards = {toml_value(spec.get('guards', []))}",` => `"guards = []",`
"""
from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
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

    def test_the_shared_copies_match_the_skills_own(self):
        for name in ("run.py", "test_mask.py", "test_sqlguard.py"):
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


if __name__ == "__main__":
    unittest.main()
