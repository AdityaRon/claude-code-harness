#!/usr/bin/env python3
"""Check a skill folder against skill-forge's ten conventions.

  skill_lint.py SKILL_DIR [SKILL_DIR ...]   one block per skill; exit 1 when any check FAILs
  skill_lint.py --json SKILL_DIR ...        the same, as JSON
  skill_lint.py --no-exec SKILL_DIR         do not run the skill's SQL --self-test (C2 is SKIP)
  skill_lint.py --budget N SKILL_DIR        SKILL.md line budget (default: line_budget in the
                                            skill-forge config, else 150)

It reads SKILL.md, forge.toml (the skill's manifest; optional), lint-waivers.toml,
bin/*.py and bin/*.sh, tests/*.py and the top-level *.toml. It does not descend
into tests/fixtures/ or templates/, which hold violations and placeholders on purpose.
C2 runs the skill's own `--self-test`, so lint only skills you would run.

forge.toml keys it reads (a hand-written skill needs none of them):
  engines      bin scripts the output rules (C6, C7) apply to; default every
               bin/*.py except the vendored mask.py and sqlguard.py
  guards       guard ids, each needing a test named test_guard_<id>...
  write_verbs  regexes that mark a write; default DEFAULT_WRITE_VERBS
  sql          true or false; default: look for a SQL client in bin/
  audit_table  the table a write's audit row goes to
  [deps]       other-skill = "ENV_VAR" for anything outside the folder

lint-waivers.toml holds `[C8]` tables with a `reason`. A waiver without a
reason fails, and so does one for a check that now passes.

Statuses: PASS, FAIL, N/A (does not apply), SKIP (--no-exec), WAIVED.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mask import config_path, emit, header, read_toml  # noqa: E402

VENDORED = {"mask.py", "sqlguard.py"}
DEFAULT_BUDGET = 150

DEFAULT_WRITE_VERBS = [
    r"""["'](?:POST|PUT|PATCH|DELETE)["']""",
    r"""\b(?:kubectl|helm|kube\w*)\b[^\n]*["'](?:apply|create|delete|patch|replace|scale|annotate|label|cordon|drain|rollout|install|upgrade|uninstall)["']""",
    r"""(?i)["']\s*(?:insert\s+into|update\s+[\w."]+\s+set|delete\s+from|truncate|drop\s+(?:table|schema)|alter\s+table)\b""",
]
SELF_TEST_OPT = re.compile(r"""add_argument\(\s*["']--self-test["']|["']--self-test["']\s+in\s+sys\.argv""")
SQL_CLIENT = re.compile(r"\b(?:psql|psycopg2?|pg8000|asyncpg|sqlite3\.connect|pymysql|mysql\.connector|snowflake\.connector|clickhouse_connect|trino\.dbapi)\b")
AUDIT_WRITE = re.compile(r"(?i)insert\s+into\s+[\w.\"]*audit")
SECRET_RULES = [
    ("a secret-named CLI flag", re.compile(r"""(?i)add_argument\(\s*["']--?[\w-]*(?:password|passwd|pwd|token|secret|api[-_]?key|credential)[\w-]*["']""")),
    ("a secret in argv", re.compile(r"""(?i)["']--(?:password|token|api-key|secret)(?:=|["'])|["']-p\{|\bf["'][^"'\n]*(?:bearer\s*\{|password=\{|token=\{)""")),
    ("a literal secret value", re.compile(r"""(?i)\b(?:password|passwd|secret|token|api_?key)\s*[:=]\s*["'][^"'\s${<]{6,}["']""")),
    ("an AWS key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("a GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36}\b")),
    ("a Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("an API key", re.compile(r"(?<![\w-])sk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}")),
    ("a private key", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")),
    ("a URL with a password", re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@'\"]+:(?!password@|\$|<|\*|x{3})[^/\s@'\"]{3,}@")),
]
CLIENT_CTORS = re.compile(
    r"\bboto3\.(?:client|resource|Session)\(|\bconfig\.load_(?:kube|incluster)_config\(|\bclient\.(?:CoreV1Api|AppsV1Api|BatchV1Api|ApiClient)\("
    r"|\bgoogle\.auth\.default\(|\b(?:storage|bigquery|logging|monitoring_v3|secretmanager)\.\w*Client\(|\bDefaultAzureCredential\("
    r"|\bhvac\.Client\(|\bdocker\.from_env\(")
MUTATION_LINE = re.compile(r"^\s*[\w-]+(?: \(may survive\))?: [\w./-]+: `", re.M)
SQL_TEXT = re.compile(r"(?is)\b(?:select|insert|update|delete)\b.*\b(?:from|into|set|where|limit)\b")
SHELL_TEXT = re.compile(r"(?:^|\s)(?:sh|bash|zsh)\s+-c\b")


@dataclass
class Result:
    status: str
    detail: str = ""


@dataclass
class Skill:
    root: Path
    md: str | None
    front: dict
    manifest: dict
    waivers: dict
    scripts: dict = field(default_factory=dict)   # bin/*.py name -> source
    shells: dict = field(default_factory=dict)    # bin/*.sh
    tests: dict = field(default_factory=dict)     # tests/*.py
    tomls: dict = field(default_factory=dict)     # top-level *.toml text

    @property
    def name(self) -> str:
        return self.front.get("name") or self.root.name

    def engines(self) -> list[str]:
        if "engines" in self.manifest:
            return [e for e in self.manifest["engines"] if e in self.scripts]
        return [n for n in self.scripts if n not in VENDORED]

    def own_scripts(self) -> dict:
        return {n: s for n, s in self.scripts.items() if n not in VENDORED}

    def test_names(self) -> list[str]:
        names = []
        for src in self.tests.values():
            names += re.findall(r"^\s*def (test_\w+)", src, re.M)
        return names


def frontmatter(md: str) -> dict:
    m = re.match(r"---\n(.*?)\n---\n", md, re.S)
    out = {}
    for line in (m.group(1).splitlines() if m else []):
        k, sep, v = line.partition(":")
        if sep and re.fullmatch(r"[\w-]+", k.strip()):
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1].replace('\\"', '"')
            out[k.strip()] = v
    return out


def load(root: Path) -> Skill:
    md_path = root / "SKILL.md"
    md = md_path.read_text() if md_path.is_file() else None
    sk = Skill(root, md, frontmatter(md or ""), read_toml(root / "forge.toml"), read_toml(root / "lint-waivers.toml"))
    for p in sorted((root / "bin").glob("*.py")):
        sk.scripts[p.name] = p.read_text()
    for p in sorted((root / "bin").glob("*.sh")):
        sk.shells[p.name] = p.read_text()
    for p in sorted((root / "tests").glob("*.py")):
        sk.tests[p.name] = p.read_text()
    for p in sorted(root.glob("*.toml")):
        sk.tomls[p.name] = p.read_text()
    return sk


def has_test(sk: Skill, rx: str) -> bool:
    return any(re.search(rx, n) for n in sk.test_names())


def calls(src: str):
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            yield node


def call_name(node: ast.Call) -> str:
    f = node.func
    if isinstance(f, ast.Name):
        return f.id
    if isinstance(f, ast.Attribute):
        base = f.value
        prefix = base.id + "." if isinstance(base, ast.Name) else (
            base.value.id + "." + base.attr + "." if isinstance(base, ast.Attribute) and isinstance(base.value, ast.Name) else "")
        return prefix + f.attr
    return ""


# ---- the checks ---------------------------------------------------------------

def check_readonly(sk: Skill, opts) -> Result:
    verbs = [re.compile(v) for v in sk.manifest.get("write_verbs", DEFAULT_WRITE_VERBS)]
    writers = {}
    for name, src in sk.own_scripts().items():
        for rx in verbs:
            m = rx.search(src)
            if m:
                writers[name] = m.group(0).strip()[:60]
                break
    if not writers:
        return Result("N/A", "no write verb in bin/")
    bad = [f"{n} writes ({w}) with no --apply" for n, w in writers.items() if '"--apply"' not in sk.scripts[n] and "'--apply'" not in sk.scripts[n]]
    if not has_test(sk, r"dry_run|without_apply|default_is_dry"):
        bad.append("no test of the default (dry-run) path: name one test_..._dry_run_...")
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f"--apply gates the writes in {', '.join(writers)}")


def check_sql_layers(sk: Skill, opts) -> Result:
    declared = sk.manifest.get("sql")
    if declared is False:
        return Result("N/A", "forge.toml says sql = false")
    users = [n for n, s in sk.own_scripts().items() if SQL_CLIENT.search(s)]
    if not (declared or sk.manifest.get("archetype") == "sql-readonly" or users):
        return Result("N/A", "no SQL client in bin/")
    selftest = [n for n, s in sk.own_scripts().items() if SELF_TEST_OPT.search(s)]
    if not selftest:
        return Result("FAIL", f"runs SQL ({', '.join(users) or 'forge.toml sql = true'}) but no script has --self-test")
    if opts.no_exec:
        return Result("SKIP", f"--no-exec: did not run {', '.join(selftest)} --self-test")
    bad = []
    for n in selftest:
        try:
            p = subprocess.run([sys.executable, "-B", str(sk.root / "bin" / n), "--self-test"], cwd=sk.root,
                               capture_output=True, text=True, timeout=120)
            rc, tail = p.returncode, (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]
        except subprocess.TimeoutExpired:
            rc, tail = "timeout", ["over 120 s"]
        if rc != 0:
            bad.append(f"{n} --self-test exit {rc}: {tail[0][:120]}")
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f"{', '.join(selftest)} --self-test passes")


def check_no_stored_credentials(sk: Skill, opts) -> Result:
    files = {f"bin/{n}": s for n, s in {**sk.scripts, **sk.shells}.items()}
    files.update({f"tests/{n}": s for n, s in sk.tests.items()})
    files.update({n: s for n, s in sk.tomls.items()})
    if sk.md is not None:
        files["SKILL.md"] = sk.md
    hits = []
    for path, src in files.items():
        for label, rx in SECRET_RULES:
            for m in rx.finditer(src):
                line = src.count("\n", 0, m.start()) + 1
                hits.append(f"{path}:{line} {label}")
    if hits:
        return Result("FAIL", "; ".join(hits[:8]) + (f" (+{len(hits) - 8} more)" if len(hits) > 8 else ""))
    return Result("PASS", f"no secret flag, argv secret or secret shape in {len(files)} files")


def check_audit_transaction(sk: Skill, opts) -> Result:
    table = sk.manifest.get("audit_table", "")
    writers = [n for n, s in sk.own_scripts().items() if AUDIT_WRITE.search(s)]
    if not table and not writers:
        return Result("N/A", "no audit table declared or written")
    if has_test(sk, r"audit\w*(?:transaction|atomic|txn)|(?:transaction|atomic|txn)\w*audit"):
        return Result("PASS", f"a test holds the write and its audit row ({table or ', '.join(writers)}) to one transaction")
    return Result("FAIL", f"writes an audit row ({table or ', '.join(writers)}) but no test_..._audit_..._transaction")


def check_guards(sk: Skill, opts) -> Result:
    guards = sk.manifest.get("guards")
    if guards is None:
        return Result("N/A", "no forge.toml guards list" if sk.engines() else "no engine")
    if not guards:
        return Result("N/A", "forge.toml declares no guards")
    missing = [g for g in guards if not has_test(sk, rf"^test_guard_{re.escape(g)}(?:_|$)")]
    if missing:
        return Result("FAIL", "no fault-injection test for " + ", ".join(f"test_guard_{g}" for g in missing))
    return Result("PASS", f"{len(guards)} guards, each with a test_guard_<id>")


def check_provenance(sk: Skill, opts) -> Result:
    engines = sk.engines()
    if not engines:
        return Result("N/A", "no engine")
    bad = [f"no header() call in {e}" for e in engines if not any(call_name(c).split(".")[-1] == "header" for c in calls(sk.scripts[e]))]
    if not has_test(sk, r"golden|provenance"):
        bad.append("no golden-output test (test_..._golden_... or ..._provenance_...)")
    if bad:
        return Result("FAIL", "; ".join(bad))
    return Result("PASS", f"{', '.join(engines)} open with header(); golden test present")


def check_masker(sk: Skill, opts) -> Result:
    engines = sk.engines()
    if not engines:
        return Result("N/A", "no engine")
    bad = []
    for e in engines:
        src = sk.scripts[e]
        raw = [c.lineno for c in calls(src) if call_name(c) in ("print", "sys.stdout.write", "sys.stderr.write", "stdout.write", "stderr.write")]
        if raw:
            bad.append(f"{e} prints around the masker (line {', '.join(map(str, raw[:5]))})")
        if not re.search(r"^\s*(?:from mask import|import mask\b)", src, re.M) or not any(call_name(c).split(".")[-1] == "emit" for c in calls(src)):
            bad.append(f"{e} does not print through mask.emit")
    if not has_test(sk, r"mask"):
        bad.append("no test with a planted pattern (test_..._mask_...)")
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f"{', '.join(engines)} print only through mask.emit")


def check_thin_skill_md(sk: Skill, opts) -> Result:
    if sk.md is None:
        return Result("FAIL", "no SKILL.md")
    bad = []
    desc = sk.front.get("description", "")
    if "Use when" not in desc:
        bad.append('the description has no literal "Use when"')
    budget = opts.budget or read_toml(config_path()).get("line_budget", DEFAULT_BUDGET)
    lines = sk.md.count("\n")
    if lines > budget:
        bad.append(f"SKILL.md is {lines} lines, over the {budget}-line budget")
    no_help = [n for n, s in sk.own_scripts().items() if "argparse" not in s and "--help" not in s]
    if no_help:
        bad.append("no --help in " + ", ".join(no_help))
    note = "" if re.search(r"(?i)\bnot for\b|does not cover", desc) else ' (note: the description names nothing it does not cover)'
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f'"Use when" present; {lines} lines (budget {budget}){note}')


def builds_shell_or_sql(src: str) -> str:
    for c in calls(src):
        if any(k.arg == "shell" and isinstance(k.value, ast.Constant) and k.value.value is True for k in c.keywords):
            return "shell=True"
        if call_name(c) in ("os.system", "os.popen"):
            return call_name(c)
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return ""
    for node in ast.walk(tree):
        text = ""
        if isinstance(node, ast.JoinedStr):
            text = "".join(v.value for v in node.values if isinstance(v, ast.Constant) and isinstance(v.value, str))
        elif isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Mod, ast.Add)) and isinstance(node.left, ast.Constant) and isinstance(node.left.value, str):
            text = node.left.value
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "format" and isinstance(node.func.value, ast.Constant) and isinstance(node.func.value.value, str):
            text = node.func.value.value
        if text and SQL_TEXT.search(text):
            return "SQL built from a template"
        if text and SHELL_TEXT.search(text):
            return "a shell command built from a template"
        if isinstance(node, (ast.List, ast.Tuple)):
            vals = [e.value for e in node.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
            if any(v in ("sh", "bash", "zsh") for v in vals) and "-c" in vals:
                return "a sh -c argv"
    return ""


def check_tests(sk: Skill, opts) -> Result:
    bad = []
    for n in sk.scripts:
        if f"test_{n}" not in sk.tests:
            bad.append(f"no tests/test_{n} for bin/{n}")
    for n, src in sk.tests.items():
        if not n.startswith("test_"):
            continue
        try:
            doc = ast.get_docstring(ast.parse(src)) or ""
        except SyntaxError:
            doc = ""
        if not MUTATION_LINE.search(doc):
            bad.append(f"tests/{n}'s docstring lists no mutations")
        for m in CLIENT_CTORS.finditer(src):
            bad.append(f"tests/{n}:{src.count(chr(10), 0, m.start()) + 1} constructs a real client ({m.group(0)})")
    builders = {n: why for n, s in sk.own_scripts().items() if (why := builds_shell_or_sql(s))}
    if builders and not has_test(sk, r"quot|escap|inject"):
        bad.append("builds shell or SQL (" + ", ".join(f"{n}: {w}" for n, w in builders.items()) + ") with no quoting test")
    if not sk.scripts:
        return Result("FAIL", "; ".join(bad)) if bad else Result("N/A", "no scripts")
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f"{len(sk.scripts)} scripts, each with a test file listing mutations")


CLIMB = re.compile(r"(?:^|/)\.\./\.\.(?:/|$)")
CLAUDE_SKILL = re.compile(r"\.claude/skills/([\w-]+)")
SIBLING = re.compile(r"^(?:\.\./)+skills/([\w-]+)")
PARENTS = re.compile(r"Path\(__file__\)(?:\.resolve\(\))?((?:\.parent)+)|\.parents\[(\d+)\]|((?:os\.path\.dirname\(){3,})")


def code_strings(src: str):
    """(line, value) for each string literal in code; docstrings are prose and skipped."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return
    docs = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
                docs.add(id(first.value))
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docs:
            yield node.lineno, node.value


def check_self_contained(sk: Skill, opts) -> Result:
    deps = set((sk.manifest.get("deps") or {}).values())
    bad = []
    files = {f"bin/{n}": s for n, s in sk.scripts.items()}
    files.update({f"tests/{n}": s for n, s in sk.tests.items()})
    for path, src in files.items():
        lines = src.splitlines()
        hits = set()
        for i, value in code_strings(src):
            names = [m.group(1) for m in CLAUDE_SKILL.finditer(value)] + [m.group(1) for m in SIBLING.finditer(value)]
            if CLIMB.search(value) or any(n not in (sk.name, sk.root.name) for n in names):
                hits.add(i)
        for i, line in enumerate(lines, 1):
            if line.lstrip().startswith("#"):
                continue
            for m in PARENTS.finditer(line):
                if (m.group(1) and m.group(1).count(".parent") > 2) or (m.group(2) and int(m.group(2)) > 1) or m.group(3):
                    hits.add(i)
        for i in sorted(hits):
            line = lines[i - 1] if i - 1 < len(lines) else ""
            if not any(re.search(rf"""(?:environ(?:\.get)?\(?\[?|getenv\()\s*["']{re.escape(d)}["']""", line) for d in deps):
                bad.append(f"{path}:{i} reaches outside the folder without a declared env var")
    if bad:
        return Result("FAIL", "; ".join(bad[:6]) + ("; declare it in forge.toml [deps] and read it from the environment" if deps == set() else ""))
    return Result("PASS", "nothing reaches outside the folder" + (f" except through {', '.join(sorted(deps))}" if deps else ""))


CHECKS = [
    ("C1", check_readonly),
    ("C2", check_sql_layers),
    ("C3", check_no_stored_credentials),
    ("C4", check_audit_transaction),
    ("C5", check_guards),
    ("C6", check_provenance),
    ("C7", check_masker),
    ("C8", check_thin_skill_md),
    ("C9", check_tests),
    ("C10", check_self_contained),
]


def lint(root: Path, budget: int | None = None, no_exec: bool = False) -> dict:
    opts = argparse.Namespace(budget=budget, no_exec=no_exec)
    sk = load(Path(root).resolve())
    results = {}
    for cid, fn in CHECKS:
        results[cid] = fn(sk, opts)
    for cid, w in sk.waivers.items():
        reason = (w or {}).get("reason", "").strip() if isinstance(w, dict) else ""
        r = results.get(cid)
        if r is None:
            results[cid] = Result("FAIL", f"lint-waivers.toml waives {cid}, which is not a check")
        elif not reason:
            results[cid] = Result("FAIL", f"the {cid} waiver gives no reason")
        elif r.status != "FAIL":
            results[cid] = Result("FAIL", f"stale waiver: {cid} is {r.status} now; delete it from lint-waivers.toml")
        else:
            results[cid] = Result("WAIVED", f"{reason} [finding: {r.detail}]")
    return results


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("skills", nargs="+", type=Path)
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-exec", action="store_true")
    p.add_argument("--budget", type=int)
    a = p.parse_args(argv)
    failed = 0
    report = {}
    for root in a.skills:
        res = lint(root, a.budget, a.no_exec)
        report[str(root)] = {k: vars(v) for k, v in res.items()}
        failed += any(r.status == "FAIL" for r in res.values())
    if a.json:
        emit(json.dumps(report, indent=2))
        return 1 if failed else 0
    emit(header(target=", ".join(map(str, a.skills)), window="n/a: reads files as they are now", rows=len(a.skills),
                partial="--no-exec skipped C2" if a.no_exec else None))
    for root, res in report.items():
        nfail = sum(r["status"] == "FAIL" for r in res.values())
        nwaive = sum(r["status"] == "WAIVED" for r in res.values())
        emit(f"\n{root}: {'FAIL' if nfail else 'PASS'} ({nfail} FAIL, {nwaive} WAIVED)")
        for cid, r in res.items():
            emit(f"  {cid:<4} {r['status']:<7} {r['detail']}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
