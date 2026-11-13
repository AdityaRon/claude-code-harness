#!/usr/bin/env python3
"""Check a skill folder against skill-forge's ten conventions.

  skill_lint.py SKILL_DIR [SKILL_DIR ...]   one block per skill; exit 1 when any check FAILs
  skill_lint.py --json SKILL_DIR ...        the same, as JSON
  skill_lint.py --no-exec SKILL_DIR         do not run the skill's SQL --self-test (C2 is SKIP)
  skill_lint.py --budget N SKILL_DIR        SKILL.md line budget (default: line_budget in the
                                            skill-forge config, else 150)

It reads SKILL.md, forge.toml (the skill's manifest; optional), lint-waivers.toml,
the top-level *.toml, and the scripts and tests in either layout: *.py and *.sh
at the skill root and in bin/ are scripts, test_*.py and *.test.sh there or in
tests/ are tests. It does not descend into tests/fixtures/ or templates/, which
hold violations and placeholders on purpose; any other code file is listed as
not read. C2 runs the skill's own `--self-test`, so lint only skills you would run.

forge.toml keys it reads (a hand-written skill needs none of them):
  engines      scripts the output rules (C6, C7) apply to; default every script
               except the vendored mask.py, sqlguard.py and python.sh
  guards       guard ids, each needing a test named test_guard_<id>...
  write_verbs  regexes that mark a write; default DEFAULT_WRITE_VERBS for
               Python, SHELL_WRITE_VERBS for shell
  sql          true or false; default: look for a SQL client in the scripts
  audit_table  the table a write's audit row goes to
  uses         the ~/.claude/ scripts SKILL.md runs that are not the skill's own;
               each must be declared, and in a harness clone install.sh must
               install it. An installed copy has no forge.toml (install.sh
               does not copy it); there each must be on this machine
  [deps]       other-skill = "ENV_VAR" for anything outside the folder
  [tests]      "bin/x.sh" = "path/to/its.test.sh", for a test kept outside the
               skill's own test locations; the path must exist

lint-waivers.toml holds `[C8]` tables with a `reason`. A waiver without a
reason fails, and so does one for a check that now passes.

Statuses: PASS, FAIL, N/A (does not apply), SKIP (--no-exec), WAIVED. Each skill
also gets a verdict: FAIL when a check fails, WARN when every engine check
(C1, C2, C4, C5, C6, C7, C9) is N/A, since then the lint saw nothing to judge,
else PASS. Only FAIL sets the exit status.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import posixpath
import re
import subprocess
import sys
import warnings
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mask import config_path, emit, header, read_toml  # noqa: E402

# Copied into a skill by forge.py draft, each with the test copied beside it (None: no test).
VENDORED = {"mask.py": "test_mask.py", "sqlguard.py": "test_sqlguard.py", "access.py": "test_access.py", "python.sh": None}
DEFAULT_BUDGET = 150
ENGINE_CHECKS = ("C1", "C2", "C4", "C5", "C6", "C7", "C9")
NOT_READ = {"fixtures", "templates", "node_modules", ".git", "__pycache__", ".venv", "venv"}

DEFAULT_WRITE_VERBS = [
    r"""["'](?:POST|PUT|PATCH|DELETE)["']""",
    r"""\b(?:kubectl|helm|kube\w*)\b[^\n]*["'](?:apply|create|delete|patch|replace|scale|annotate|label|cordon|drain|rollout|install|upgrade|uninstall)["']""",
    r"""(?i)["']\s*(?:insert\s+into|update\s+[\w."]+\s+set|delete\s+from|truncate|drop\s+(?:table|schema)|alter\s+table)\b""",
    r"""["']\s*mutation\b""",   # a GraphQL write
    r"""\b(?:requests|httpx)\.(?:post|put|patch|delete)\(""",
]
# Shell has no quotes around a verb, so these read the command line itself. The
# verb must be the subcommand, after any global flags: a flag that takes a value
# consumes it, so `-n label-studio get pods` is a read.
_VALUE_FLAGS = r"(?:n|namespace|context|kubeconfig|cluster|user|s|server|as|l|selector|o|output|kube-context)"
_KFLAGS = (r"(?:\s+(?:--?" + _VALUE_FLAGS + r"(?:=|\s+)\S+|--?(?!" + _VALUE_FLAGS + r"\b)[\w-]+(?:=\S+)?))*")
SHELL_WRITE_VERBS = [
    r"\bkubectl" + _KFLAGS + r"\s+(?:apply|create|delete|patch|replace|scale|annotate|label|taint|cordon|uncordon"
    r"|drain|edit|set|expose|run)(?![\w-])",
    r"\bkubectl" + _KFLAGS + r"\s+rollout\s+(?:restart|undo|pause|resume)\b",
    r"\bhelm" + _KFLAGS + r"\s+(?:install|upgrade|uninstall|rollback)(?![\w-])",
    r"""\b(?:curl|http|xh)\b[^\n|;&]*?(?:-X\s*|--request[ =])["']?(?:POST|PUT|PATCH|DELETE)\b""",
    # curl sends a body, so POSTs (or PUTs, with -T), unless -G makes the body a query.
    r"""\bcurl\b(?![^\n|;&]*\s(?:-G|--get)\b)[^\n|;&]*?\s(?:-d|-F|-T|--data(?:-raw|-binary|-urlencode|-ascii)?"""
    r"""|--json|--form(?:-string)?|--upload-file)(?=[\s=@'"]|$)""",
    r"""\bgh\s+api\b[^\n|;&]*?(?:-X\s*|--method[ =])(?:POST|PUT|PATCH|DELETE)\b""",
    # gh api sends fields as a POST unless the method is named GET.
    r"""\bgh\s+api\b(?![^\n|;&]*(?:-X\s*|--method[ =])GET\b)[^\n|;&]*?\s(?:-f|-F|--field|--raw-field|--input)(?=[\s=]|$)""",
    r"""(?i)\b(?:insert\s+into|update\s+[\w."]+\s+set|delete\s+from|truncate\s+table|drop\s+(?:table|schema)|alter\s+table)\b""",
]
SH_MASKED = re.compile(r"\bmask\.py\b[^\n]*--filter")
SH_SELF_TEST = re.compile(r"--self-test\b")
SCRIPT_REF = re.compile(r"(?<![\w.$-])((?:[\w.~${}<>-]*/)*[\w.-]+\.(?:py|sh))\b")
SELF_TEST_OPT = re.compile(r"""add_argument\(\s*["']--self-test["']|["']--self-test["']\s+in\s+sys\.argv""")
SQL_CLIENT = re.compile(r"\b(?:psql|psycopg2?|pg8000|asyncpg|sqlite3\.connect|pymysql|mysql\.connector|snowflake\.connector|clickhouse_connect|trino\.dbapi)\b")
AUDIT_WRITE = re.compile(r"(?i)insert\s+into\s+[\w.\"]*audit")
SECRET_RULES = [
    ("a secret-named CLI flag", re.compile(r"""(?i)add_argument\(\s*["']--?[\w-]*(?:password|passwd|pwd|token|secret|api[-_]?key|credential)[\w-]*["']""")),
    ("a secret in argv", re.compile(r"""(?i)["']--(?:password|token|api-key|secret)(?:=|["'])|["']-p\{|\bf["'][^"'\n]*(?:bearer\s*\{|password=\{|token=\{)""")),
    ("a literal secret value", re.compile(r"""(?i)\b(?:password|passwd|secret|token|api_?key)\s*[:=]\s*["'][^"'\s${<]{6,}["']""")),
    ("an AWS key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("a GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36}\b")),
    ("a Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}|\bxapp-\d+-[A-Za-z0-9-]{10,}")),
    ("a GitHub fine-grained token", re.compile(r"\bgithub_pat_\w{50,}")),
    ("a GitLab or npm token", re.compile(r"\bglpat-[\w-]{20,}|\bnpm_[A-Za-z0-9]{36}")),
    ("a Google API key", re.compile(r"\bAIza[\w-]{35}")),
    ("a Stripe key", re.compile(r"\bsk_(?:live|test)_[A-Za-z0-9]{24,}")),
    ("a JWT", re.compile(r"\beyJ[\w-]{10,}\.eyJ[\w-]{10,}\.[\w-]{10,}")),
    ("a Slack webhook", re.compile(r"hooks\.slack\.com/services/[\w/+-]{20,}")),
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
    scripts: dict = field(default_factory=dict)       # relative path -> source: *.py, *.sh at the root and in bin/
    tests: dict = field(default_factory=dict)         # test_*.py at the root, every *.py in tests/
    shell_tests: dict = field(default_factory=dict)   # *.test.sh, test_*.sh at the root and in tests/
    tomls: dict = field(default_factory=dict)         # top-level *.toml text
    unread: list = field(default_factory=list)        # code files under the folder the lint did not read

    @property
    def name(self) -> str:
        return self.front.get("name") or self.root.name

    def engines(self) -> list[str]:
        if "engines" in self.manifest:
            want = set(self.manifest["engines"])
            return [n for n in self.scripts if n in want or Path(n).name in want]
        return list(self.own_scripts())

    def own_scripts(self) -> dict:
        return {n: s for n, s in self.scripts.items() if Path(n).name not in VENDORED}

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


def is_shell(name: str) -> bool:
    return name.endswith(".sh")


def is_test(name: str) -> bool:
    return name.startswith("test_") or name.endswith(".test.sh") or name == "conftest.py"


def load(root: Path) -> Skill:
    md_path = root / "SKILL.md"
    md = md_path.read_text() if md_path.is_file() else None
    sk = Skill(root, md, frontmatter(md or ""), read_toml(root / "forge.toml"), read_toml(root / "lint-waivers.toml"))
    for d in (root, root / "bin", root / "tests"):
        for p in sorted(d.glob("*.py")) + sorted(d.glob("*.sh")):
            rel = p.relative_to(root).as_posix()
            if p.name == "__init__.py":
                continue
            if d == root / "tests" or is_test(p.name):
                (sk.shell_tests if is_shell(p.name) else sk.tests)[rel] = p.read_text()
            else:
                sk.scripts[rel] = p.read_text()
    for p in sorted(root.glob("*.toml")):
        sk.tomls[p.name] = p.read_text()
    read = {*sk.scripts, *sk.tests, *sk.shell_tests}
    # NOT_READ folders are pruned before the walk goes in: a skill that is its own
    # clone, or holds a .venv, would otherwise cost a stat per file on every lint.
    for top, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in NOT_READ)
        for f in sorted(files):
            rel = (Path(top) / f).relative_to(root)
            if rel.suffix in (".py", ".sh") and rel.as_posix() not in read and f != "__init__.py":
                sk.unread.append(rel.as_posix())
    sk.unread.sort()
    return sk


def parse(src: str) -> ast.Module:
    """ast.parse, quietly: a linted file's own invalid escapes would print as <unknown>:N warnings."""
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message=".*invalid escape sequence")
        return ast.parse(src)


HEREDOC = re.compile(r"""(?<!<)<<(?!<)-?\s*(['"]?)([A-Za-z_]\w*)\1""")


def shell_code(src: str) -> str:
    """The script with comment lines blanked, so line numbers still hold. A heredoc's
    body is data: a line in it that starts with # is printed, not a comment, so it stays."""
    out, ends = [], []
    for line in src.splitlines():
        if ends:
            out.append(line)
            if line.strip() == ends[0]:
                ends.pop(0)
            continue
        if line.lstrip().startswith("#"):
            out.append("")
            continue
        out.append(line)
        ends += [m.group(2) for m in HEREDOC.finditer(line)]
    return "\n".join(out)


def skill_md_refs(sk: Skill) -> tuple[list[str], list[str]]:
    """Scripts SKILL.md names: (the skill's own the lint did not read, those outside the folder)."""
    read = {Path(n).name for n in (*sk.scripts, *sk.tests, *sk.shell_tests)}
    unread = {Path(u).name for u in sk.unread}
    mine, outside = set(), set()
    for m in SCRIPT_REF.finditer(sk.md or ""):
        ref = m.group(1)
        base = ref.rsplit("/", 1)[-1]
        if base in read:
            continue
        own = base in unread or any(f"skills/{n}/" in ref for n in (sk.name, sk.root.name))
        (mine if own else outside).add(ref)
    return sorted(mine), sorted(outside)


def has_test(sk: Skill, rx: str) -> bool:
    return any(re.search(rx, n) for n in sk.test_names())


def calls(src: str):
    try:
        tree = parse(src)
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

def has_apply(name: str, src: str) -> bool:
    if is_shell(name):
        return "--apply" in shell_code(src)
    return '"--apply"' in src or "'--apply'" in src


def check_readonly(sk: Skill, opts) -> Result:
    custom = sk.manifest.get("write_verbs")
    writers = {}
    for name, src in sk.own_scripts().items():
        verbs = custom or (SHELL_WRITE_VERBS if is_shell(name) else DEFAULT_WRITE_VERBS)
        text = shell_code(src) if is_shell(name) else src
        for v in verbs:
            m = re.search(v, text)
            if m:
                writers[name] = m.group(0).strip()[:60]
                break
    if not writers:
        return Result("N/A", "no write verb in the scripts")
    bad = [f"{n} writes ({w}) with no --apply" for n, w in writers.items() if not has_apply(n, sk.scripts[n])]
    if not has_test(sk, r"dry_run|without_apply|default_is_dry"):
        bad.append("no test of the default (dry-run) path: name one test_..._dry_run_...")
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f"--apply gates the writes in {', '.join(writers)}")


def check_sql_layers(sk: Skill, opts) -> Result:
    declared = sk.manifest.get("sql")
    if declared is False:
        return Result("N/A", "forge.toml says sql = false")
    users = [n for n, s in sk.own_scripts().items() if SQL_CLIENT.search(s)]
    if not (declared or sk.manifest.get("archetype") == "sql-readonly" or users):
        return Result("N/A", "no SQL client in the scripts")
    selftest = [n for n, s in sk.own_scripts().items()
                if (SH_SELF_TEST.search(shell_code(s)) if is_shell(n) else SELF_TEST_OPT.search(s))]
    if not selftest:
        return Result("FAIL", f"runs SQL ({', '.join(users) or 'forge.toml sql = true'}) but no script has --self-test")
    if opts.no_exec:
        return Result("SKIP", f"--no-exec: did not run {', '.join(selftest)} --self-test")
    bad = []
    for n in selftest:
        try:
            run = ["bash"] if is_shell(n) else [sys.executable, "-B"]
            p = subprocess.run([*run, str(sk.root / n), "--self-test"], cwd=sk.root, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=120)
            rc, tail = p.returncode, (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]
        except subprocess.TimeoutExpired:
            rc, tail = "timeout", ["over 120 s"]
        if rc != 0:
            bad.append(f"{n} --self-test exit {rc}: {tail[0][:120]}")
    return Result("FAIL", "; ".join(bad)) if bad else Result("PASS", f"{', '.join(selftest)} --self-test passes")


def check_no_stored_credentials(sk: Skill, opts) -> Result:
    files = {**sk.scripts, **sk.tests, **sk.shell_tests}
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


def has_header(name: str, src: str) -> bool:
    if is_shell(name):
        return "# target:" in shell_code(src)
    return any(call_name(c).split(".")[-1] == "header" for c in calls(src))


def check_provenance(sk: Skill, opts) -> Result:
    engines = sk.engines()
    if not engines:
        return Result("N/A", "no engine")
    bad = [f"no header() call in {e}" for e in engines if not has_header(e, sk.scripts[e])]
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
        if is_shell(e):
            if not SH_MASKED.search(shell_code(src)):
                bad.append(f"{e} prints without the masker: no line pipes its output through the skill's mask.py --filter")
            continue
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
    no_help = [n for n, s in sk.own_scripts().items()
               if "--help" not in s and ("usage" not in s.lower() if is_shell(n) else "argparse" not in s)]
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
        tree = parse(src)
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


def tested(sk: Skill, n: str) -> bool:
    """A test file for script n: test_<stem>.py, or for shell also test_<stem>.sh or <stem>.test.sh,
    in either layout; or the one forge.toml [tests] declares for it, if that file exists."""
    stem = Path(n).stem
    want = {f"test_{stem}.py"} | ({f"test_{stem}.sh", f"{stem}.test.sh"} if is_shell(n) else set())
    if want & {Path(t).name for t in (*sk.tests, *sk.shell_tests)}:
        return True
    declared = (sk.manifest.get("tests") or {}).get(n)
    return bool(declared) and (sk.root / declared).is_file()


def check_tests(sk: Skill, opts) -> Result:
    bad = []
    needs = [n for n in sk.scripts if Path(n).name not in VENDORED or VENDORED[Path(n).name]]
    for n in needs:
        if not tested(sk, n):
            bad.append(f"no test_{Path(n).stem}.py for {n}")
    for n, src in sk.tests.items():
        if not Path(n).name.startswith("test_"):
            continue
        try:
            doc = ast.get_docstring(parse(src)) or ""
        except SyntaxError:
            doc = ""
        if not MUTATION_LINE.search(doc):
            bad.append(f"{n}'s docstring lists no mutations")
        for m in CLIENT_CTORS.finditer(src):
            bad.append(f"{n}:{src.count(chr(10), 0, m.start()) + 1} constructs a real client ({m.group(0)})")
    builders = {n: why for n, s in sk.own_scripts().items() if not is_shell(n) and (why := builds_shell_or_sql(s))}
    if builders and not has_test(sk, r"quot|escap|inject"):
        bad.append("builds shell or SQL (" + ", ".join(f"{n}: {w}" for n, w in builders.items()) + ") with no quoting test")
    if not sk.scripts:
        return Result("FAIL", "; ".join(bad)) if bad else Result("N/A", "no scripts")
    untested = len(sk.scripts) - len(needs)
    return Result("FAIL", "; ".join(bad)) if bad else Result(
        "PASS", f"{len(needs)} scripts, each with a test file listing mutations" + (f" ({untested} vendored with none)" if untested else ""))


CLIMB = re.compile(r"(?:^|/)\.\./\.\.(?:/|$)")
CLAUDE_SKILL = re.compile(r"\.claude/skills/([\w-]+)")
SIBLING = re.compile(r"^(?:\.\./)+skills/([\w-]+)")
PARENTS = re.compile(r"Path\(__file__\)(?:\.resolve\(\))?((?:\.parent)+)|\.parents\[(\d+)\]|((?:os\.path\.dirname\(){3,})")
# ~/.claude/<path>.sh|.py in any spelling of home: ~, $HOME, "$HOME", ${HOME}, /Users/<u>,
# /home/<u>. A period after it ends the sentence; .bak or -old after it is another name.
INSTALLED_REF = re.compile(r'(?<![\w.$/-])(?:~|\$HOME"?|\$\{HOME\}"?|/(?:Users|home)/[\w.-]+)(/\.claude/[\w./-]+\.(?:py|sh))(?![\w-]|\.\w)')


def home_ref(path: str) -> str:
    """~ + PATH with // and ./ collapsed; one whose .. leaves ~/.claude stays as written."""
    n = posixpath.normpath(path)
    return "~" + (n if n.startswith("/.claude/") else path)


def climbs(ref: str) -> bool:
    return ".." in ref.split("/")


def installed_ref(text: str) -> str | None:
    """TEXT as ~/.claude/<path> (home_ref) when it is one whole; else None."""
    m = INSTALLED_REF.fullmatch(text.strip())
    return home_ref(m.group(1)) if m else None


def is_own(sk: Skill, ref: str) -> bool:
    return ref.startswith(tuple(f"~/.claude/skills/{n}/" for n in (sk.name, sk.root.name))) and not climbs(ref)


def installed_refs(sk: Skill) -> set[str]:
    """The ~/.claude/ scripts SKILL.md names, less the skill's own folder."""
    refs = {home_ref(m.group(1)) for m in INSTALLED_REF.finditer(sk.md or "")}
    return {r for r in refs if not is_own(sk, r)}


def installed_copy(sk: Skill) -> bool:
    """A skill install.sh placed: under ~/.claude/skills, with no forge.toml (it is not installed)."""
    skills = Path(os.path.expanduser("~/.claude/skills")).resolve()
    return not (sk.root / "forge.toml").is_file() and sk.root.resolve().parent == skills


def find_harness(path: Path) -> Path | None:
    """The public harness clone that holds PATH, if any."""
    p = path
    while not p.exists() and p != p.parent:
        p = p.parent
    top = subprocess.run(["git", "-C", str(p), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode != 0:
        return None
    root = Path(top.stdout.strip())
    if (root / "skills" / "skill-forge" / "SKILL.md").is_file():
        return root
    url = subprocess.run(["git", "-C", str(root), "remote", "get-url", "origin"], capture_output=True, text=True).stdout
    return root if "claude-code-harness" in url else None


def installed_from(repo: Path, ref: str) -> Path | None:
    """Where in the clone install.sh copies ~/.claude/<path> from; None where it copies
    nothing: bin/ whole and flat, hooks/*.sh, and a skill's bin/, panel/hooks/, panel/types/."""
    parts = ref[len("~/.claude/"):].split("/")
    if len(parts) == 1:
        return repo / "bin" / parts[0]
    if parts[0] == "hooks" and parts[-1].endswith(".sh") and len(parts) == 2:
        return repo.joinpath(*parts)
    if parts[0] == "skills" and (len(parts) == 4 and parts[2] == "bin" or len(parts) == 5 and parts[2] == "panel" and parts[3] in ("hooks", "types")):
        return repo.joinpath(*parts)
    return None


def code_strings(src: str):
    """(line, value) for each string literal in code; docstrings are prose and skipped."""
    try:
        tree = parse(src)
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
    files = {**sk.scripts, **sk.tests, **sk.shell_tests}
    for path, src in files.items():
        lines = src.splitlines()
        hits = set()
        strings = enumerate(shell_code(src).splitlines(), 1) if is_shell(path) else code_strings(src)
        for i, value in strings:
            names = [m.group(1) for m in CLAUDE_SKILL.finditer(value)] + [m.group(1) for m in SIBLING.finditer(value)]
            if CLIMB.search(value) or any(n not in (sk.name, sk.root.name) for n in names):
                hits.add(i)
        for i, line in enumerate(lines, 1):
            if line.lstrip().startswith("#") or is_shell(path):
                continue
            for m in PARENTS.finditer(line):
                if (m.group(1) and m.group(1).count(".parent") > 2) or (m.group(2) and int(m.group(2)) > 1) or m.group(3):
                    hits.add(i)
        for i in sorted(hits):
            line = lines[i - 1] if i - 1 < len(lines) else ""
            if not any(re.search(rf"""(?:environ(?:\.get)?\(?\[?|getenv\()\s*["']{re.escape(d)}["']|\$\{{?{re.escape(d)}\b""", line) for d in deps):
                bad.append(f"{path}:{i} reaches outside the folder without a declared env var")
    if bad:
        bad[:] = bad[:6] + (["declare it in forge.toml [deps] and read it from the environment"] if deps == set() else [])
    mine, outside = skill_md_refs(sk)
    raw, named = sk.manifest.get("uses", []), installed_refs(sk)
    if not (isinstance(raw, list) and all(isinstance(u, str) for u in raw)):
        bad.append('forge.toml uses must be a list of strings, as uses = ["~/.claude/tool.sh"]')
        raw = []
    uses = {installed_ref(u) or u for u in raw}
    uses = {u for u in uses if not is_own(sk, u)}
    for ref in sorted(r for r in named if climbs(r)):
        bad.append(f"SKILL.md runs {ref}, which climbs out of ~/.claude")
    named = {r for r in named if not climbs(r)}
    if installed_copy(sk):
        uses = named   # nothing to declare it in: each must be on this machine
    for ref in sorted(named - uses):
        bad.append(f"SKILL.md runs {ref}, outside the folder; declare it in forge.toml uses")
    for ref in sorted(uses - named):
        bad.append(f"forge.toml uses {ref}, which SKILL.md does not name")
    if uses & named:
        repo = find_harness(sk.root)
        repo = repo if repo and sk.root.resolve().parent == (repo / "skills").resolve() else None
        for ref in sorted(uses & named):
            if repo:
                src = installed_from(repo, ref)
                if not (src and src.is_file()):
                    bad.append(f"SKILL.md runs {ref}, which install.sh in this clone does not install")
            elif not Path(os.path.expanduser(ref)).is_file():
                bad.append(f"SKILL.md runs {ref}, which is not on this machine")
    outside = [r for r in outside if installed_ref(r) not in named]
    for ref in mine:
        where = next((u for u in sk.unread if Path(u).name == ref.rsplit("/", 1)[-1]), "")
        bad.append(f"SKILL.md runs {ref}; lint found no engine" + (f" (it is at {where}, which the lint does not read)" if where else ""))
    if len(bad) > 8:
        bad[:] = bad[:8] + [f"and {len(bad) - 8} more"]
    if bad:
        return Result("FAIL", "; ".join(bad))
    also = f"; SKILL.md also names {', '.join(outside[:4])}{' and more' if len(outside) > 4 else ''} outside the folder" if outside else ""
    return Result("PASS", "nothing reaches outside the folder" + (f" except through {', '.join(sorted(deps))}" if deps else "") + also)


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
    """{check id: Result} for one skill folder."""
    return report(root, budget, no_exec)["checks"]


def report(root: Path, budget: int | None = None, no_exec: bool = False) -> dict:
    """The checks plus the skill's verdict (PASS, WARN or FAIL), its N/A count and a note for WARN."""
    sk = load(Path(root).resolve())
    results = run_checks(sk, argparse.Namespace(budget=budget, no_exec=no_exec))
    statuses = {k: r.status for k, r in results.items()}
    na = sum(s == "N/A" for s in statuses.values())
    verdict, note = ("FAIL" if "FAIL" in statuses.values() else "PASS"), ""
    if verdict == "PASS" and all(statuses.get(c) == "N/A" for c in ENGINE_CHECKS):
        verdict = "WARN"
        named = installed_refs(sk)   # C10 judges these
        outside = [r for r in skill_md_refs(sk)[1] if installed_ref(r) not in named]
        note = f"every engine check is N/A: the lint read {len(sk.scripts)} scripts and {len(sk.tests) + len(sk.shell_tests)} test files"
        if outside:
            note += f"; SKILL.md names {', '.join(outside[:5])} outside the folder, which the lint does not judge"
        if sk.unread:
            note += f"; not read: {', '.join(sk.unread[:5])}"
    return {"verdict": verdict, "na": na, "note": note, "checks": results}


def run_checks(sk: Skill, opts) -> dict:
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
    out = {}
    for root in a.skills:
        if not root.is_dir():
            emit(f"skill_lint: {root} is not a directory, skipped", err=True)
            continue
        r = report(root, a.budget, a.no_exec)
        out[str(root)] = {**r, "checks": {k: vars(v) for k, v in r["checks"].items()}}
    failed = sum(r["verdict"] == "FAIL" for r in out.values())
    if a.json:
        emit(json.dumps(out, indent=2))
        return 1 if failed else 0
    emit(header(target=", ".join(out) or "none", window="n/a: reads files as they are now", rows=len(out),
                partial="--no-exec skipped C2" if a.no_exec else None))
    for root, r in out.items():
        res = r["checks"]
        nfail = sum(c["status"] == "FAIL" for c in res.values())
        nwaive = sum(c["status"] == "WAIVED" for c in res.values())
        emit(f"\n{root}: {r['verdict']} ({nfail} FAIL, {nwaive} WAIVED, {r['na']} N/A)")
        if r["note"]:
            emit(f"  WARN {r['note']}")
        for cid, c in res.items():
            emit(f"  {cid:<4} {c['status']:<7} {c['detail']}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
