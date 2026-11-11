"""Tests for skill_lint.py. The baseline fixture passes all ten checks (none
N/A, so every check is exercised), and each fixture in violations.toml fails
exactly the check it targets and no other.

Mutations that must turn this file red (deleting any check must be seen):
  drop-c1: skill_lint.py: `("C1", check_readonly),` => ``
  drop-c2: skill_lint.py: `("C2", check_sql_layers),` => ``
  drop-c3: skill_lint.py: `("C3", check_no_stored_credentials),` => ``
  drop-c4: skill_lint.py: `("C4", check_audit_transaction),` => ``
  drop-c5: skill_lint.py: `("C5", check_guards),` => ``
  drop-c6: skill_lint.py: `("C6", check_provenance),` => ``
  drop-c7: skill_lint.py: `("C7", check_masker),` => ``
  drop-c8: skill_lint.py: `("C8", check_thin_skill_md),` => ``
  drop-c9: skill_lint.py: `("C9", check_tests),` => ``
  drop-c10: skill_lint.py: `("C10", check_self_contained),` => ``
  stale-waiver-kept: skill_lint.py: `elif r.status != "FAIL":` => `elif False:`
  reasonless-waiver-kept: skill_lint.py: `elif not reason:` => `elif False:`
  selftest-not-run: skill_lint.py: `if rc != 0:` => `if False:`
  budget-ignored: skill_lint.py: `if lines > budget:` => `if False:`
  url-password-missed: skill_lint.py: `{3,}@")),` => `{3,}@NEVER")),`
  own-skill-path-flagged: skill_lint.py: `n not in (sk.name, sk.root.name) for n in names` => `True for n in names`
  docstrings-scanned: skill_lint.py: `docs.add(id(first.value))` => `pass`
  no-help-missed: skill_lint.py: `if no_help:` => `if False:`
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
import skill_lint  # noqa: E402
from mask import read_toml  # noqa: E402

FIX = HERE / "fixtures" / "lint"
SKILLS = "~/.claude/" + "skills/"   # built, so this file does not reach outside its own folder
ALL = {f"C{i}" for i in range(1, 11)}


def failing(results: dict) -> set:
    return {k for k, r in results.items() if r.status == "FAIL"}


class Workdir:
    def __enter__(self) -> Path:
        self.tmp = Path(tempfile.mkdtemp(prefix="lint-test."))
        dst = self.tmp / "lint-baseline"
        shutil.copytree(FIX / "baseline", dst, ignore=shutil.ignore_patterns("__pycache__"))
        os.environ["SKILL_FORGE_CONFIG"] = str(self.tmp / "absent.toml")
        return dst

    def __exit__(self, *exc):
        shutil.rmtree(self.tmp, ignore_errors=True)


def apply(root: Path, v: dict) -> None:
    path = root / v["file"]
    if v.get("delete"):
        path.unlink()
        return
    text = path.read_text()
    n = text.count(v["old"])
    if n != 1:
        raise AssertionError(f"{v['check']} ({v['why']}): `old` occurs {n}x in {v['file']}")
    path.write_text(text.replace(v["old"], v["new"]))


class LintFixtureTest(unittest.TestCase):
    def test_baseline_passes_every_check_and_none_is_na(self):
        with Workdir() as root:
            res = skill_lint.lint(root)
        self.assertEqual({k for k, r in res.items() if r.status == "PASS"}, ALL,
                         {k: (r.status, r.detail) for k, r in res.items() if r.status != "PASS"})

    def test_each_violation_fails_exactly_its_check(self):
        violations = read_toml(FIX / "violations.toml")["violation"]
        self.assertEqual({v["check"] for v in violations}, ALL, "one fixture per convention at least")
        for v in violations:
            with self.subTest(check=v["check"], why=v["why"]), Workdir() as root:
                apply(root, v)
                res = skill_lint.lint(root)
                self.assertEqual(failing(res), {v["check"]},
                                 {k: r.detail for k, r in res.items() if r.status == "FAIL"})


class WaiverTest(unittest.TestCase):
    def test_a_waiver_with_a_reason_turns_fail_into_waived(self):
        with Workdir() as root:
            apply(root, {"check": "C8", "why": "", "file": "SKILL.md", "old": "Use when asked", "new": "For"})
            (root / "lint-waivers.toml").write_text('[C8]\nreason = "triggering phrase tuned by hand"\n')
            res = skill_lint.lint(root)
        self.assertEqual(res["C8"].status, "WAIVED")
        self.assertIn("tuned by hand", res["C8"].detail)
        self.assertEqual(failing(res), set())

    def test_a_waiver_without_a_reason_fails(self):
        with Workdir() as root:
            apply(root, {"check": "C8", "why": "", "file": "SKILL.md", "old": "Use when asked", "new": "For"})
            (root / "lint-waivers.toml").write_text('[C8]\nreason = ""\n')
            res = skill_lint.lint(root)
        self.assertEqual(res["C8"].status, "FAIL")
        self.assertIn("no reason", res["C8"].detail)

    def test_a_stale_waiver_fails(self):
        with Workdir() as root:
            (root / "lint-waivers.toml").write_text('[C8]\nreason = "was long once"\n')
            res = skill_lint.lint(root)
        self.assertEqual(res["C8"].status, "FAIL")
        self.assertIn("stale", res["C8"].detail)


class RuleTest(unittest.TestCase):
    def test_line_budget(self):
        with Workdir() as root:
            self.assertEqual(skill_lint.lint(root, budget=5)["C8"].status, "FAIL")
            self.assertEqual(skill_lint.lint(root, budget=500)["C8"].status, "PASS")

    def test_a_script_with_no_help_fails_c8(self):
        with Workdir() as root:
            (root / "bin" / "extra.py").write_text('"""no options at all"""\nimport sys\n')
            res = skill_lint.lint(root)
        self.assertIn("no --help in extra.py", res["C8"].detail)

    def test_a_url_with_a_password_fails_c3(self):
        with Workdir() as root:
            url = "postgres://app:" + "n0tre4l" + "@db:5432/x"
            (root / "SKILL.md").write_text((root / "SKILL.md").read_text() + f"\nConnect with {url}\n")
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C3"})

    def test_a_placeholder_password_in_a_url_passes_c3(self):
        with Workdir() as root:
            (root / "SKILL.md").write_text((root / "SKILL.md").read_text() + "\nConnect with postgres://app:$PGPASS@db/x\n")
            res = skill_lint.lint(root)
        self.assertEqual(res["C3"].status, "PASS")

    def test_the_skills_own_installed_path_is_not_outside(self):
        with Workdir() as root:
            p = root / "bin" / "engine.py"
            p.write_text(p.read_text().replace("BLOCK = (", f'DOC = "{SKILLS}lint-baseline/SKILL.md"\nBLOCK = ('))
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_a_docstring_naming_another_skill_is_prose_not_a_path(self):
        with Workdir() as root:
            p = root / "bin" / "engine.py"
            p.write_text(p.read_text().replace('"""lint-baseline:', f'"""See {SKILLS}flag-common/SKILL.md for the sibling.\nlint-baseline:', 1))
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_a_declared_env_var_lets_a_path_leave_the_folder(self):
        with Workdir() as root:
            p = root / "bin" / "engine.py"
            p.write_text(p.read_text().replace(
                "BLOCK = (", f'COMMON = os.environ.get("FLAG_COMMON_HOME", os.path.expanduser("{SKILLS}flag-common"))\nBLOCK = ('))
            self.assertEqual(skill_lint.lint(root)["C10"].status, "FAIL")
            m = root / "forge.toml"
            m.write_text(m.read_text().replace("[deps]", '[deps]\nflag-common = "FLAG_COMMON_HOME"'))
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_no_exec_skips_the_self_test(self):
        with Workdir() as root:
            self.assertEqual(skill_lint.lint(root, no_exec=True)["C2"].status, "SKIP")

    def test_a_prose_only_skill_is_na_not_fail(self):
        with Workdir() as root:
            for d in ("bin", "tests"):
                shutil.rmtree(root / d)
            (root / "forge.toml").unlink()
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), set(), {k: r.detail for k, r in res.items() if r.status == "FAIL"})
        for c in ("C1", "C2", "C4", "C5", "C6", "C7", "C9"):
            self.assertEqual(res[c].status, "N/A", c)


if __name__ == "__main__":
    unittest.main()
