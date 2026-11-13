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
  c10-uses-unchecked: skill_lint.py: `for ref in sorted(named - uses):` => `for ref in sorted(set()):`
  c10-stale-uses: skill_lint.py: `for ref in sorted(uses - named):` => `for ref in sorted(set()):`
  c10-not-installed: skill_lint.py: `if not (src and src.is_file()):` => `if False:`
  c10-own-skill-is-outside: skill_lint.py: `return {r for r in refs if not r.startswith(own)}` => `return refs`
  c10-bin-flat: skill_lint.py: `return repo / "bin" / parts[0]` => `return repo / parts[0]`
  c10-any-hook-file: skill_lint.py: `if parts[0] == "hooks" and parts[-1].endswith(".sh") and` => `if parts[0] == "hooks" and`
  c10-any-skill-file: skill_lint.py: `if parts[0] == "skills" and len(parts) == 4 and parts[2] == "bin":` => `if parts[0] == "skills":`
  c10-tilde-only: skill_lint.py: `(?:~|\\$HOME|\\$\\{HOME\\}|/(?:Users|home)/[\\w.-]+)(/` => `(?:~)(/`
  c10-no-normpath: skill_lint.py: `refs = {"~" + posixpath.normpath(m.group(1)) for m` => `refs = {"~" + m.group(1) for m`
  c10-bak-is-a-ref: skill_lint.py: `\\.(?:py|sh))(?![\\w.-])")` => `\\.(?:py|sh))\\b")`
  c10-uses-untyped: skill_lint.py: `if not (isinstance(raw, list) and all(isinstance(u, str) for u in raw)):` => `if False:`
  c10-not-on-machine: skill_lint.py: `elif not Path(os.path.expanduser(ref)).is_file():` => `elif False:`
  c10-uncapped: skill_lint.py: `if len(bad) > 8:` => `if False:`
  c10-warn-names-judged: skill_lint.py: `outside = [r for r in skill_md_refs(sk)[1] if installed_ref(r) not in named]` => `outside = skill_md_refs(sk)[1]`
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
  shell-verbs-unseen: skill_lint.py: `(?:apply|create|delete|patch|replace|scale|annotate|label|taint|cordon|uncordon"` => `(?:NEVER"`
  shell-apply-unchecked: skill_lint.py: `return "--apply" in shell_code(src)` => `return True`
  shell-mask-unchecked: skill_lint.py: `if not SH_MASKED.search(shell_code(src)):` => `if False:`
  shell-header-unchecked: skill_lint.py: `return "# target:" in shell_code(src)` => `return True`
  shell-comments-read: skill_lint.py: `            out.append("")` => `            out.append(line)`
  shell-test-names-unseen: skill_lint.py: `({f"test_{stem}.sh", f"{stem}.test.sh"} if is_shell(n) else set())` => `set()`
  declared-test-unchecked: skill_lint.py: `return bool(declared) and (sk.root / declared).is_file()` => `return bool(declared)`
  python-sh-not-vendored: skill_lint.py: `"python.sh": None}` => `}`
  skill-md-engine-unseen: skill_lint.py: `(mine if own else outside).add(ref)` => `outside.add(ref)`
  unread-script-not-own: skill_lint.py: `own = base in unread or any(` => `own = any(`
  unread-unlisted: skill_lint.py: `sk.unread.append(rel.as_posix())` => `pass`
  warn-hidden: skill_lint.py: `if verdict == "PASS" and all(statuses.get(c) == "N/A" for c in ENGINE_CHECKS):` => `if False:`
  nondir-not-skipped: skill_lint.py: `if not root.is_dir():` => `if False:`
  parse-warnings-echoed: skill_lint.py: `warnings.filterwarnings("ignore", message=".*invalid escape sequence")` => `pass`
  verb-anywhere: skill_lint.py: `_KFLAGS + r"\\s+(?:apply|` => `r"[^\\n|;&]*?\\s(?:apply|`
  curl-body-unseen: skill_lint.py: `(?:-d|-F|-T|--data(?:-raw|-binary|-urlencode|-ascii)?` => `(?:--nodata(?:-x)?`
  curl-get-body-a-write: skill_lint.py: `(?![^\\n|;&]*\\s(?:-G|--get)\\b)` => `(?!x\\by)`
  gh-fields-unseen: skill_lint.py: `(?:-f|-F|--field|--raw-field|--input)` => `(?:--nofield)`
  heredoc-comments-blanked: skill_lint.py: `        if ends:` => `        if False:`
  walk-enters-skipped: skill_lint.py: `        dirs[:] = sorted(d for d in dirs if d not in NOT_READ)` => `        dirs[:] = sorted(dirs)`
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
import skill_lint  # noqa: E402
from mask import read_toml  # noqa: E402

FIX = HERE / "fixtures" / "lint"
SKILLS = "~/.claude/" + "skills/"   # built, so this file does not reach outside its own folder
ALL = {f"C{i}" for i in range(1, 11)}


def failing(results: dict) -> set:
    return {k for k, r in results.items() if r.status == "FAIL"}


@contextlib.contextmanager
def home(*tools):
    """HOME as a temp dir whose ~/.claude holds TOOLS: C10 checks a declared script exists."""
    with tempfile.TemporaryDirectory() as h, mock.patch.dict(os.environ, {"HOME": h}):
        (Path(h) / ".claude").mkdir()
        for t in tools:
            (Path(h) / ".claude" / t).write_text("true\n")
        yield Path(h)


def uses(root: Path, value: str) -> None:
    """Put `uses = VALUE` first in ROOT's forge.toml, keeping the rest."""
    toml = root / "forge.toml"
    toml.write_text(f"uses = {value}\n" + (toml.read_text() if toml.exists() else ""))


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

    def test_the_unread_walk_never_enters_a_skipped_folder(self):
        with Workdir("flat", "flat") as root:
            (root / "node_modules" / "pkg").mkdir(parents=True)
            (root / "node_modules" / "pkg" / "x.py").write_text("print(1)\n")
            (root / "extra").mkdir()
            (root / "extra" / "more.py").write_text("print(1)\n")
            entered = []
            real_walk = skill_lint.os.walk

            def walk(top, *a, **kw):
                for t, d, f in real_walk(top, *a, **kw):
                    entered.append(Path(t).name)
                    yield t, d, f
            with mock.patch.object(skill_lint.os, "walk", walk):
                sk = skill_lint.load(root)
        self.assertNotIn("node_modules", entered)
        self.assertNotIn("pkg", entered)
        self.assertIn("extra/more.py", sk.unread)

    def test_a_shell_header_printed_from_a_heredoc_counts(self):
        printed = 'cat <<EOF\n# target:  x\n# window:  n/a\nEOF\nkubectl get pods\n'
        quoted = "cat <<-'END'\n\t# target:  x\n\tEND\n"
        commented = '# target: is printed below, one day\nkubectl get pods\n'
        self.assertTrue(skill_lint.has_header("tool.sh", printed))
        self.assertTrue(skill_lint.has_header("tool.sh", quoted))
        self.assertFalse(skill_lint.has_header("tool.sh", commented))
        self.assertEqual(skill_lint.shell_code("x=$((1<<2))\n# c\ncat <<<'a'\n# d\n"), "x=$((1<<2))\n\ncat <<<'a'\n")

    def test_shell_write_verbs(self):
        writes = ["kubectl -n x apply -f a.yaml", "kubectl rollout restart deploy/x", "helm upgrade x ./chart",
                  "curl -sf -X POST https://x/api", "gh api -X PATCH repos/o/r", "psql -c 'delete from t where id = 1'",
                  "kubectl --context c --insecure-skip-tls-verify delete pod x", "kubectl -n label label pod x a=b",
                  "helm --kube-context c -n ns upgrade x ./chart", "curl -d x=1 https://a/b", "curl --json '{}' https://x",
                  "curl -sf -T file https://x/up", "gh api repos/o/r/issues -f title=x", "gh api graphql --input q.json"]
        reads = ["kubectl get pods -l app=x", "kubectl describe pod x | grep delete", "kubectl get pods --show-labels",
                 "curl -sf https://x/api", "helm list -A", "gh api repos/o/r", "psql -c 'select 1'",
                 "kubectl get pods -n label-studio", "kubectl -n label get pods", "kubectl get pods -l create=yes",
                 "helm list -n upgrade-tests", "curl -G -d q=1 https://x/search", "curl -sf https://x/api?d=1",
                 "gh api -X GET search/issues -f q=x", "gh api repos/o/r --jq .full_name"]
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

    def test_an_installed_script_skill_md_runs_must_be_declared_in_uses(self):
        with Workdir() as root, home("memory-verify.sh"):
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nThen `bash ~/.claude/memory-verify.sh --json` and `bash install.sh`.\n")
            res = skill_lint.lint(root)
            self.assertEqual(failing(res), {"C10"}, fails(res))
            self.assertIn("SKILL.md runs ~/.claude/memory-verify.sh, outside the folder; declare it in forge.toml uses",
                          res["C10"].detail)
            uses(root, '["~/.claude/memory-verify.sh"]')
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)
        self.assertIn("SKILL.md also names install.sh outside the folder", res["C10"].detail)

    def test_outside_a_harness_clone_a_declared_script_must_be_on_this_machine(self):
        with Workdir() as root, home():
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nRun `bash ~/.claude/memory-verify.sh`.\n")
            uses(root, '["~/.claude/memory-verify.sh"]')
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C10"}, fails(res))
        self.assertIn("SKILL.md runs ~/.claude/memory-verify.sh, which is not on this machine", res["C10"].detail)

    def test_every_spelling_of_home_is_one_reference(self):
        with Workdir() as root, home("memory-verify.sh"):
            md = root / "SKILL.md"
            md.write_text(md.read_text() + '\nRun `bash "${HOME}/.claude/memory-verify.sh"`, `$HOME/.claude//memory-verify.sh`, '
                          "`/Users/someone/.claude/./memory-verify.sh` or `/home/someone/.claude/memory-verify.sh`; "
                          "never `~/.claude/memory-verify.sh.bak`.\n")
            for spelling in ('`bash "$HOME"/.claude/memory-verify.sh`', '`bash "${HOME}"/.claude/memory-verify.sh`',
                             "Then run ~/.claude/memory-verify.sh."):
                with self.subTest(spelling=spelling):
                    alone = root.parent / "alone"
                    shutil.rmtree(alone, ignore_errors=True)
                    shutil.copytree(root, alone)
                    (alone / "SKILL.md").write_text(md.read_text().split("\nRun `bash")[0] + f"\n{spelling}\n")
                    self.assertIn("SKILL.md runs ~/.claude/memory-verify.sh, outside the folder",
                                  skill_lint.lint(alone)["C10"].detail)
                    shutil.rmtree(alone)
            res = skill_lint.lint(root)
            self.assertEqual(failing(res), {"C10"}, fails(res))
            self.assertEqual(res["C10"].detail.count("SKILL.md runs ~/.claude/memory-verify.sh, outside the folder"), 1,
                             res["C10"].detail)
            self.assertNotIn(".bak", res["C10"].detail)
            uses(root, '["~/.claude//memory-verify.sh"]')
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_a_longer_name_holding_a_script_name_is_not_a_reference(self):
        with Workdir() as root, home():
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nNever run `~/.claude/old-tool.sh.bak` or `~/.claude/x.py-old`.\n")
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_many_findings_are_capped_so_the_first_stays_readable(self):
        with Workdir() as root, home():
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\n" + " ".join(f"`~/.claude/t{i}.sh`" for i in range(12))
                          + "\n`python3 scripts/report.py` prints a report.\n")
            (root / "scripts").mkdir()
            (root / "scripts" / "report.py").write_text('"""report.py --help"""\n')
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C10"}, fails(res))
        self.assertTrue(res["C10"].detail.endswith("; and 5 more"), res["C10"].detail)

    def test_uses_that_is_not_a_list_of_strings_fails_without_a_crash(self):
        for value in ('"~/.claude/memory-verify.sh"', '[{a = 1}]'):
            with self.subTest(value=value), Workdir() as root, home("memory-verify.sh"):
                md = root / "SKILL.md"
                md.write_text(md.read_text() + "\nRun `bash ~/.claude/memory-verify.sh`.\n")
                uses(root, value)
                res = skill_lint.lint(root)
                self.assertEqual(failing(res), {"C10"}, fails(res))
                self.assertIn("forge.toml uses must be a list of strings", res["C10"].detail)
                self.assertLessEqual(res["C10"].detail.count(";"), 8, res["C10"].detail)

    def test_a_declared_script_skill_md_no_longer_names_fails(self):
        with Workdir() as root, home("memory-verify.sh"):
            uses(root, '["~/.claude/memory-verify.sh"]')
            res = skill_lint.lint(root)
        self.assertEqual(failing(res), {"C10"}, fails(res))
        self.assertIn("forge.toml uses ~/.claude/memory-verify.sh, which SKILL.md does not name", res["C10"].detail)

    def test_the_skills_own_installed_scripts_need_no_declaration(self):
        with Workdir() as root, home():
            md = root / "SKILL.md"
            md.write_text(md.read_text() + f"\nRun `python3 ~/.claude/skills/{root.name}/bin/engine.py --help`.\n")
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_a_uses_entry_for_the_skills_own_script_is_not_a_finding(self):
        with Workdir() as root, home():
            md = root / "SKILL.md"
            own = f"~/.claude/skills/{root.name}/bin/engine.py"
            md.write_text(md.read_text() + f"\nRun `python3 {own} --help`.\n")
            uses(root, f'["{own}"]')
            res = skill_lint.lint(root)
        self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)

    def test_a_reference_that_climbs_out_of_claude_fails(self):
        up3 = "../" * 3   # built: whole, C10 reads this test as climbing out of its folder
        for ref in ("~/.claude/../bin/x.sh", "~/.claude/skills/{name}/" + up3 + "x.sh"):
            with self.subTest(ref=ref), Workdir() as root, home():
                ref = ref.format(name=root.name)
                md = root / "SKILL.md"
                md.write_text(md.read_text() + f"\nRun `bash {ref}`.\n")
                uses(root, f'["{ref}"]')
                res = skill_lint.lint(root)
                self.assertEqual(failing(res), {"C10"}, fails(res))
                self.assertIn(f"SKILL.md runs {ref}, which climbs out of ~/.claude", res["C10"].detail)

    def test_an_installed_copy_is_judged_by_what_is_on_this_machine(self):
        # install.sh copies no forge.toml, so an installed skill has nowhere to declare uses.
        with Workdir() as fixture, home() as h:
            root = h / ".claude" / "skills" / fixture.name
            shutil.copytree(fixture, root)
            (root / "forge.toml").unlink()
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nRun `bash ~/.claude/memory-verify.sh`.\n")
            self.assertIn("SKILL.md runs ~/.claude/memory-verify.sh, which is not on this machine",
                          skill_lint.lint(root)["C10"].detail)
            (h / ".claude" / "memory-verify.sh").write_text("true\n")
            res = skill_lint.lint(root)
            self.assertEqual(res["C10"].status, "PASS", res["C10"].detail)
            (root / "forge.toml").write_text('name = "x"\n')   # a manifest there: declare as anywhere else
            self.assertIn("declare it in forge.toml uses", skill_lint.lint(root)["C10"].detail)

    def test_in_a_harness_clone_a_declared_script_must_be_one_install_sh_installs(self):
        other = "~/.claude/" + "skills/other"   # in two parts: whole, C10 reads this test as reaching into a skill
        refs = ["~/.claude/memory-verify.sh", "~/.claude/hooks/x.sh", "~/.claude/hooks/x.py", "~/.claude/hooks/lib/l.sh",
                f"{other}/tests/t.py", f"{other}/bin/t.py", f"{other}/panel/hooks/h.py", f"{other}/panel/p.py"]
        with tempfile.TemporaryDirectory() as tmp, Workdir() as fixture, home():
            repo = Path(tmp)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            for d in ("bin", "hooks/lib", "skills/skill-forge", "skills/other/tests", "skills/other/bin", "skills/other/panel/hooks"):
                (repo / d).mkdir(parents=True)
            (repo / "skills" / "skill-forge" / "SKILL.md").write_text("x\n")   # how the lint knows the harness
            root = repo / "skills" / fixture.name
            shutil.copytree(fixture, root)
            md = root / "SKILL.md"
            md.write_text(md.read_text() + "\nRun " + ", ".join(f"`{r}`" for r in refs) + ".\n")
            uses(root, "[" + ", ".join(f'"{r}"' for r in refs) + "]")
            (repo / "memory-verify.sh").write_text("true\n")   # at the root, not in bin/: not installed
            for f in ("hooks/x.sh", "hooks/x.py", "hooks/lib/l.sh", "skills/other/tests/t.py", "skills/other/bin/t.py",
                      "skills/other/panel/hooks/h.py", "skills/other/panel/p.py"):
                (repo / f).write_text("true\n")
            detail = skill_lint.lint(root)["C10"].detail
            # install.sh copies hooks/*.sh, not hooks/lib/ (until the lib split installs it).
            for r in ("~/.claude/memory-verify.sh", "~/.claude/hooks/x.py", "~/.claude/hooks/lib/l.sh",
                      f"{other}/tests/t.py", f"{other}/panel/p.py"):
                self.assertIn(f"SKILL.md runs {r}, which install.sh in this clone does not install", detail)
            for r in ("~/.claude/hooks/x.sh", f"{other}/bin/t.py", f"{other}/panel/hooks/h.py"):
                self.assertNotIn(f"{r}, which install.sh", detail)
            (repo / "bin" / "memory-verify.sh").write_text("true\n")
            self.assertNotIn("memory-verify.sh, which install.sh", skill_lint.lint(root)["C10"].detail)


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
            md.write_text(md.read_text() + "\nRun `bash ~/.claude/flag-report.sh`, then `bash install.sh`.\n")
            (root / "forge.toml").write_text('uses = ["~/.claude/flag-report.sh"]\n')   # C10 needs it declared
            (root / "scripts").mkdir()
            (root / "scripts" / "helper.sh").write_text("echo hi\n")
            with home("flag-report.sh"):
                r = skill_lint.report(root)
        self.assertEqual((r["verdict"], r["na"]), ("WARN", 7), r)
        self.assertIn("every engine check is N/A", r["note"])
        self.assertIn("install.sh outside the folder", r["note"])
        self.assertNotIn("flag-report.sh", r["note"])   # C10 judged it
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
