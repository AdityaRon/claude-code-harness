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
  graphql-write-unseen: skill_lint.py: `\\s*mutation\\b` => `\\s*NEVERmutation\\b`
  requests-write-unseen: skill_lint.py: `\\b(?:requests|httpx)` => `\\bNEVER(?:requests|httpx)`
  flat-root-unread: skill_lint.py: `for d in (root, root / "bin", root / "tests"):` => `for d in (root / "bin", root / "tests"):`
  shell-verbs-unseen: skill_lint.py: `(?:apply|create|delete|patch|replace|scale|annotate|label|taint|cordon|uncordon|drain|edit)` => `(?:NEVER)`
  shell-apply-unchecked: skill_lint.py: `return "--apply" in shell_code(src)` => `return True`
  shell-mask-unchecked: skill_lint.py: `if not SH_MASKED.search(shell_code(src)):` => `if False:`
  shell-header-unchecked: skill_lint.py: `return "# target:" in shell_code(src)` => `return True`
  shell-comments-read: skill_lint.py: `"" if line.lstrip().startswith("#") else line for line` => `line for line`
  shell-test-names-unseen: skill_lint.py: `({f"test_{stem}.sh", f"{stem}.test.sh"} if is_shell(n) else set())` => `set()`
  declared-test-unchecked: skill_lint.py: `return bool(declared) and (sk.root / declared).is_file()` => `return bool(declared)`
  python-sh-not-vendored: skill_lint.py: `"python.sh": None}` => `}`
  skill-md-engine-unseen: skill_lint.py: `(mine if own else outside).add(ref)` => `outside.add(ref)`
  unread-script-not-own: skill_lint.py: `own = base in unread or any(` => `own = any(`
  unread-unlisted: skill_lint.py: `sk.unread.append(rel.as_posix())` => `pass`
  warn-hidden: skill_lint.py: `if verdict == "PASS" and all(statuses.get(c) == "N/A" for c in ENGINE_CHECKS):` => `if False:`
  nondir-not-skipped: skill_lint.py: `if not root.is_dir():` => `if False:`
  parse-warnings-echoed: skill_lint.py: `warnings.filterwarnings("ignore", message=".*invalid escape sequence")` => `pass`
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import sys
import tempfile
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
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
    def __init__(self, fixture: str = "baseline", dest: str = "lint-baseline"):
        self.fixture, self.dest = fixture, dest

    def __enter__(self) -> Path:
        self.tmp = Path(tempfile.mkdtemp(prefix="lint-test."))
        dst = self.tmp / self.dest
        shutil.copytree(FIX / self.fixture, dst, ignore=shutil.ignore_patterns("__pycache__"))
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

    def test_a_graphql_mutation_is_a_write(self):
        with Workdir() as root:
            m = root / "forge.toml"
            m.write_text(m.read_text().replace("write_verbs = ['(?i)update\\s+flags\\s+set']\n", ""))
            (root / "bin" / "flip.py").write_text('"""flip.py --apply"""\nimport argparse\n'
                                                  'FLIP = """mutation Flip($id: ID!) { flip(id: $id) { ok } }"""\n'
                                                  'argparse.ArgumentParser().add_argument("--apply")\n')
            res = skill_lint.lint(root)
        self.assertIn("flip.py", res["C1"].detail)

    def test_a_requests_post_is_a_write(self):
        with Workdir() as root:
            m = root / "forge.toml"
            m.write_text(m.read_text().replace("write_verbs = ['(?i)update\\s+flags\\s+set']\n", ""))
            (root / "bin" / "push.py").write_text('"""push.py --help"""\nimport requests\n'
                                                  'requests.post("https://flags.example/api/push", json={})\n')
            res = skill_lint.lint(root)
        self.assertIn("bin/push.py writes (requests.post() with no --apply", res["C1"].detail)

    def test_a_script_with_no_help_fails_c8(self):
        with Workdir() as root:
            (root / "bin" / "extra.py").write_text('"""no options at all"""\nimport sys\n')
            res = skill_lint.lint(root)
        self.assertIn("no --help in bin/extra.py", res["C8"].detail)

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


def fails(res: dict) -> dict:
    return {k: r.detail for k, r in res.items() if r.status == "FAIL"}


class FlatLayoutTest(unittest.TestCase):
    def test_a_flat_python_skill_fails_c1_c6_c7_on_its_engine(self):
        with Workdir("flat", "flat-tool") as root:
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C1", "C6", "C7"}, fails(res))
        self.assertIn('tool.py writes ("POST") with no --apply', res["C1"].detail)
        self.assertIn("no header() call in tool.py", res["C6"].detail)
        self.assertIn("tool.py prints around the masker", res["C7"].detail)
        self.assertEqual((res["C9"].status, res["C10"].status), ("PASS", "PASS"), (res["C9"].detail, res["C10"].detail))

    def test_a_flat_shell_skill_fails_c1_c6_c7_on_its_engine(self):
        with Workdir("flat-sh", "flat-sh") as root:
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C1", "C6", "C7"}, fails(res))
        self.assertIn("tool.sh writes (kubectl -n apps apply) with no --apply", res["C1"].detail)
        self.assertIn("no header() call in tool.sh", res["C6"].detail)
        self.assertIn("tool.sh prints without the masker", res["C7"].detail)

    def test_a_shell_engine_with_apply_a_header_and_the_masker_passes(self):
        with Workdir("flat-sh", "flat-sh") as root:
            p = root / "tool.sh"
            p.write_text(p.read_text().replace(
                'echo "rolling $SERVICE"\nkubectl -n apps apply -f "configs/$SERVICE.yaml"\n',
                'HERE="$(cd "$(dirname "$0")" && pwd)"\n'
                '{\n'
                '  echo "# target: $SERVICE"\n'
                '  if [ "${2:-}" = "--apply" ]; then kubectl -n apps apply -f "configs/$SERVICE.yaml"\n'
                '  else kubectl -n apps diff -f "configs/$SERVICE.yaml"; fi\n'
                '} | python3 "$HERE/mask.py" --filter\n'))
            self.assertIn("--filter", p.read_text())
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), set(), fails(res))

    def test_a_commented_out_write_is_not_a_write(self):
        with Workdir("flat-sh", "flat-sh") as root:
            p = root / "tool.sh"
            p.write_text(p.read_text().replace("kubectl -n apps apply -f", "# kubectl -n apps apply -f"))
            res = skill_lint.lint(root)
        self.assertEqual(res["C1"].status, "N/A", res["C1"].detail)

    def test_shell_write_verbs(self):
        writes = ["kubectl -n x apply -f a.yaml", "kubectl rollout restart deploy/x", "helm upgrade x ./chart",
                  "curl -sf -X POST https://x/api", "gh api -X PATCH repos/o/r", "psql -c 'delete from t where id = 1'"]
        reads = ["kubectl get pods -l app=x", "kubectl describe pod x | grep delete", "kubectl get pods --show-labels",
                 "curl -sf https://x/api", "helm list -A", "gh api repos/o/r", "psql -c 'select 1'"]
        for line in writes:
            self.assertTrue(any(re.search(v, line) for v in skill_lint.SHELL_WRITE_VERBS), line)
        for line in reads:
            self.assertFalse(any(re.search(v, line) for v in skill_lint.SHELL_WRITE_VERBS), line)

    def test_a_shell_script_tested_by_a_dot_test_sh_passes_c9(self):
        with Workdir("flat-sh", "flat-sh") as root:
            (root / "test_tool.py").unlink()
            self.assertEqual(skill_lint.lint(root)["C9"].status, "FAIL")
            (root / "tool.test.sh").write_text("#!/usr/bin/env bash\nbash tool.sh --help\n")
            res = skill_lint.lint(root)
        self.assertEqual(res["C9"].status, "PASS", res["C9"].detail)

    def test_a_declared_test_counts_only_if_the_file_exists(self):
        with Workdir("flat-sh", "flat-sh") as root:
            (root / "test_tool.py").unlink()
            (root / "forge.toml").write_text('[tests]\n"tool.sh" = "../shared-tests/tool.test.sh"\n')
            self.assertEqual(skill_lint.lint(root)["C9"].status, "FAIL")
            (root.parent / "shared-tests").mkdir()
            (root.parent / "shared-tests" / "tool.test.sh").write_text("true\n")
            res = skill_lint.lint(root)
        self.assertEqual(res["C9"].status, "PASS", res["C9"].detail)


class SkillMdTest(unittest.TestCase):
    def test_skill_md_running_a_script_the_lint_did_not_read_fails_c10(self):
        with Workdir() as root:
            (root / "scripts").mkdir()
            (root / "scripts" / "report.py").write_text('"""report.py --help"""\n')
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\n`python3 scripts/report.py TENANT` prints a report.\n")
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C10"}, fails(res))
        self.assertIn("SKILL.md runs scripts/report.py; lint found no engine (it is at scripts/report.py", res["C10"].detail)

    def test_scripts_outside_the_folder_are_named_not_failed(self):
        with Workdir() as root:
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nThen `bash ~/.claude/memory-verify.sh --json` and `bash install.sh`.\n")
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)
        self.assertIn("SKILL.md also names install.sh, ~/.claude/memory-verify.sh outside the folder", res["C10"].detail)


class VerdictTest(unittest.TestCase):
    def test_a_skill_with_engines_is_pass_with_its_na_count(self):
        with Workdir() as root:
            r = skill_lint.report(root)
        self.assertEqual((r["verdict"], r["na"], r["note"]), ("PASS", 0, ""))

    def test_every_engine_check_na_is_warn_naming_what_it_did_not_read(self):
        with Workdir() as root:
            for d in ("bin", "tests"):
                shutil.rmtree(root / d)
            (root / "forge.toml").unlink()
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nRun `bash ~/.claude/flag-report.sh`.\n")
            (root / "scripts").mkdir()
            (root / "scripts" / "helper.sh").write_text("echo hi\n")
            r = skill_lint.report(root)
        self.assertEqual((r["verdict"], r["na"]), ("WARN", 7), r)
        self.assertIn("every engine check is N/A", r["note"])
        self.assertIn("~/.claude/flag-report.sh", r["note"])
        self.assertIn("not read: scripts/helper.sh", r["note"])


class CliTest(unittest.TestCase):
    def main(self, *argv) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = skill_lint.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_a_file_argument_is_skipped_with_one_line(self):
        with Workdir() as root:
            rc, out, err = self.main(str(root / "SKILL.md"), str(root))
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(err.strip().splitlines(), [f"skill_lint: {root / 'SKILL.md'} is not a directory, skipped"])
        self.assertIn(f"{root}: PASS (0 FAIL, 0 WAIVED, 0 N/A)", out)

    def test_json_carries_the_verdict_and_na_count(self):
        with Workdir() as root:
            rc, out, _ = self.main("--json", str(root))
        r = json.loads(out)[str(root)]
        self.assertEqual((rc, r["verdict"], r["na"], r["checks"]["C1"]["status"]), (0, "PASS", 0, "PASS"))


class ParseTest(unittest.TestCase):
    def test_a_linted_files_invalid_escape_prints_no_warning(self):
        with Workdir() as root:
            t = root / "tests" / "test_engine.py"
            t.write_text(t.read_text() + '\nPATTERN = "a\\.b"\n')
            with warnings.catch_warnings(record=True) as seen:
                warnings.simplefilter("always")
                skill_lint.lint(root)
        self.assertEqual([str(w.message) for w in seen if "escape" in str(w.message)], [])


if __name__ == "__main__":
    unittest.main()
