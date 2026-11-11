#!/usr/bin/env python3
"""Draft, verify and install one skill per recurring question.

  forge.py list                                  the archetypes, their guards and write verbs
  forge.py draft ARCHETYPE NAME --question Q [--not-for TEXT] [--out DIR] [--force]
                                                 render a template into DIR (default <state>/drafts/NAME)
  forge.py verify DIR [--no-mutate]              the skill's tests, each listed mutation, then skill_lint
  forge.py install DIR [--dest DIR] [--apply]    copy a verified skill to ~/.claude/skills/NAME or DEST;
                                                 without --apply, print what would change
  forge.py compare DRAFT EXISTING [--run 'ARGS'] [--run-existing 'ARGS']
  forge.py compare --archetype ARCH EXISTING [...]
                                                 lint both side by side, the guards and subcommands each
                                                 has, and with --run both engines' numbers on one question

compare reads a skill in either layout (scripts in bin/ or at the root). A
required guard the existing skill lacks is a finding for that skill; a guard
or subcommand only the existing skill has is a finding for the template.
Subcommands are read from the source; `--help` runs only for its usage line,
with stdin closed and a 10 s limit. --run gives both engines the same ARGS
(--run-existing overrides the existing one's) and compares the numbers in
their output bodies, headers, quoted strings, times and masked ids left out.
It refuses --apply. --archetype drafts ARCH into a temporary folder first:
the back-test of a template against a skill that already answers the question.
Exit 0 compared (with --run: the same numbers and exit status), 1 usage,
3 the two answers differ, 5 refused.

Templates come from $SKILL_FORGE_TEMPLATES, else templates/ beside bin/ (a
clone), else ${XDG_DATA_HOME:-~/.local/share}/skill-forge/templates, where
install.sh puts them so they never sit under ~/.claude/skills and trigger.
A draft carries its own copies of mask.py, python.sh, tests/run.py and
tests/test_mask.py (and sqlguard.py with its test where the archetype runs
SQL), so it installs one folder at a time. Rendering fails on any {{placeholder}}
left over. install refuses the public harness clone and any skill skill_lint
fails, and records the question the skill answers in <state>/inventory.md.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skill_lint  # noqa: E402
from mask import EXIT_OK, EXIT_PARTIAL, EXIT_REFUSED, EXIT_USAGE, emit, header, read_toml, state_dir  # noqa: E402

BIN = Path(__file__).resolve().parent
NAME = re.compile(r"[a-z][a-z0-9-]{2,40}")
PLACEHOLDER = re.compile(r"\{\{\s*\w+\s*\}\}")


def templates_dir() -> Path:
    env = os.environ.get("SKILL_FORGE_TEMPLATES")
    if env:
        return Path(env).expanduser()
    beside = BIN.parent / "templates"
    if beside.is_dir():
        return beside
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return Path(base) / "skill-forge" / "templates"


def archetypes() -> dict:
    root = templates_dir()
    return {p.parent.name: read_toml(p) for p in sorted(root.glob("*/guards.toml"))}


def yaml_scalar(text: str) -> str:
    text = " ".join(text.split())
    if ": " in text or " #" in text or text[:1] in "\"'&*!|>%@`[]{},?-:#":
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return text


def toml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(toml_value(x) for x in v) + "]"
    return json.dumps(str(v))


def render(text: str, values: dict, where: str) -> str:
    for k, v in values.items():
        text = text.replace("{{" + k + "}}", v)
    left = sorted(set(PLACEHOLDER.findall(text)))
    if left:
        raise ValueError(f"{where}: placeholders left after rendering: {', '.join(left)}")
    return text


def target_path(out: Path, tmpl: str, module: str) -> Path:
    base = tmpl[:-len(".tmpl")]
    if base == "engine.py":
        return out / "bin" / f"{module}.py"
    if base == "test_engine.py":
        return out / "tests" / f"test_{module}.py"
    return out / base


def draft(arch: str, name: str, question: str, out: Path | None = None, not_for: str | None = None, force: bool = False) -> Path:
    spec = archetypes().get(arch)
    if spec is None:
        raise ValueError(f"no archetype {arch!r}; forge.py list names them")
    if not NAME.fullmatch(name):
        raise ValueError(f"name {name!r}: lower case, digits and dashes, 3 to 41 characters, starting with a letter")
    question = " ".join(question.split()).rstrip("?").strip()
    if not question:
        raise ValueError("--question is the point of the skill; it cannot be empty")
    out = out or state_dir() / "drafts" / name
    if out.exists():
        if not force:
            raise ValueError(f"{out} exists; pass --force to replace an earlier draft")
        if not (out / "forge.toml").is_file():
            raise ValueError(f"{out} exists and holds no forge.toml, so it is not a draft; refusing to replace it")
        shutil.rmtree(out)
    module = name.replace("-", "_")
    not_for = not_for or spec.get("not_for", "changing anything")
    values = {
        "name": name,
        "module": module,
        "env_prefix": module.upper(),
        "question": question,
        "archetype": arch,
        "date": date.today().isoformat(),
        "description": yaml_scalar(f'Use when asked "{question}" or the same question in other words. {spec["summary"]} Not for {not_for}.'),
    }
    src = templates_dir() / arch
    (out / "bin").mkdir(parents=True)
    (out / "tests").mkdir()
    for t in sorted(src.glob("*.tmpl")):
        dst = target_path(out, t.name, module)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(render(t.read_text(), values, f"{arch}/{t.name}"))
    vendor = ["mask.py", "python.sh"] + list(spec.get("vendor", []))
    for v in vendor:
        shutil.copy2(BIN / v, out / "bin" / v)
    shared = templates_dir() / "_shared" / "tests"
    for t in ["run.py"] + [f"test_{v}" for v in vendor if v.endswith(".py")]:
        shutil.copy2(shared / t, out / "tests" / t)
    for p in (out / "bin").iterdir():
        p.chmod(0o755)
    manifest = [
        f"# skill-forge manifest; skill_lint reads it. Written by forge.py draft on {values['date']}.",
        f"name = {toml_value(name)}",
        f"question = {toml_value(question)}",
        f"archetype = {toml_value(arch)}",
        f"engines = {toml_value([module + '.py'])}",
        f"guards = {toml_value(spec.get('guards', []))}",
        f"write_verbs = {toml_value(spec.get('write_verbs', []))}",
        f"sql = {toml_value(bool(spec.get('sql', False)))}",
        f"audit_table = {toml_value(spec.get('audit_table', ''))}",
        "",
        "[deps]",
        "",
        "[mask]",
        "# Identifier shapes this skill's output carries, on top of ~/.config/skill-forge/config.toml.",
        "# A pattern can name a customer: keep it out of any repo others read.",
        "patterns = []",
        "",
    ]
    (out / "forge.toml").write_text("\n".join(manifest))
    return out


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


def record(name: str, question: str, arch: str, dest: Path) -> Path:
    inv = state_dir() / "inventory.md"
    inv.parent.mkdir(parents=True, exist_ok=True)
    text = inv.read_text() if inv.is_file() else "# skill-forge inventory\n"
    if "\n## Skills\n" not in "\n" + text:
        text = text.rstrip("\n") + "\n\n## Skills\n\n"
    line = f'- `{name}` answers "{question}" · {arch} · installed {date.today().isoformat()} to {dest} · by `forge.py install --apply`\n'
    inv.write_text(text + line)
    return inv


def install(d: Path, dest: Path | None, apply: bool) -> int:
    m = read_toml(d / "forge.toml")
    name = m.get("name") or d.name
    dest = dest or Path(os.path.expanduser("~/.claude/skills")) / name
    harness = find_harness(dest)
    if harness:
        emit(f"REFUSED: {dest} is inside the public harness clone ({harness}). Install to ~/.claude/skills or a work repo.", err=True)
        return EXIT_REFUSED
    res = skill_lint.lint(d)
    failing = {k: r.detail for k, r in res.items() if r.status == "FAIL"}
    if failing:
        emit(f"REFUSED: skill_lint fails {', '.join(failing)}; run forge.py verify {d}", err=True)
        return EXIT_REFUSED
    if dest.exists():
        emit(f"REFUSED: {dest} exists; remove it yourself or pass another --dest", err=True)
        return EXIT_REFUSED
    files = sorted(str(p.relative_to(d)) for p in d.rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    emit(header(target=str(dest), window="n/a: a copy of files as they are now", command=None, rows=len(files)))
    for f in files:
        emit(f"{'copy' if apply else 'would copy'} {f}")
    emit(f"{'record' if apply else 'would record'} in {state_dir() / 'inventory.md'}: `{name}` answers \"{m.get('question', '?')}\"")
    if not apply:
        emit("dry run: nothing written; pass --apply to install")
        return EXIT_OK
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(d, dest, ignore=shutil.ignore_patterns("__pycache__"))
    record(name, m.get("question", "?"), m.get("archetype", "?"), dest)
    emit(f"installed {name} to {dest}")
    return EXIT_OK


def verify(d: Path, mutate: bool) -> int:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    steps = [("tests", [sys.executable, "-B", "tests/run.py"])]
    if mutate:
        steps.append(("mutations", [sys.executable, "-B", "tests/run.py", "--mutate"]))
    emit(header(target=str(d), window="n/a: runs the skill as it is now", rows=len(steps) + 1))
    bad = 0
    for label, cmd in steps:
        p = subprocess.run(cmd, cwd=d, env=env, capture_output=True, text=True)
        tally = [ln for ln in p.stdout.splitlines() if ln.startswith("--- Results:")][-1:] or ["(no tally line)"]
        emit(f"{label}: exit {p.returncode} {tally[0]}")
        if p.returncode != 0:
            bad += 1
            for ln in (p.stdout + p.stderr).splitlines():
                if ln.startswith(("GREEN", "STALE", "NONE", "RED", "FAIL:", "ERROR:")):
                    emit("  " + ln)
    res = skill_lint.lint(d)
    nfail = [k for k, r in res.items() if r.status == "FAIL"]
    emit(f"skill_lint: {'FAIL ' + ', '.join(nfail) if nfail else 'PASS'}")
    for k in nfail:
        emit(f"  {k} {res[k].detail}")
    bad += bool(nfail)
    emit("verified offline. Before install, run the engine on the real target with the user present and inject each guard's fault (SKILL.md step 5)."
         if not bad else f"{bad} step(s) failed")
    return 1 if bad else EXIT_OK


# What a skill shows of each guard in the taxonomy: what it prints, and the exit status that marks it.
GUARD_SIGNS = {
    "absent": ("ABSENT", r"\bABSENT\b"),
    "partial": ("PARTIAL", r"\bPARTIAL\b"),
    "expired_auth": ("AUTH or a re-login", r"\bAUTH\b|(?i:re-?login)"),
    "wrong_target": ("a wrong-target check", r"(?i)wrong.target"),
    "window": ("the window", r"\bWINDOW\b|--window\b"),
    "incomplete_capture": ("a terminal marker", r"(?i)\bmarker\b|\bINCOMPLETE\b"),
    "leftover_probe": ("a leftover-probe check", r"(?i)leftover|ttlSecondsAfterFinished"),
}
GUARD_EXIT = {"absent": (2, "ABSENT"), "partial": (3, "PARTIAL"), "expired_auth": (4, "AUTH")}
SUBPARSER = re.compile(r"""add_parser\(\s*["']([\w-]+)["']""")
USAGE_SUBS = re.compile(r"\{([\w-]+(?:,[\w-]+)*)\} \.\.\.")   # argparse's subcommand group; option choices have no "..."
CASE_ARM = re.compile(r"^\s*([a-z][\w-]*(?:\s*\|\s*[a-z][\w-]*)*)\)", re.M)
NUMBER = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.])")
NOT_A_VALUE = re.compile(r'"[^"\n]*"|\'[^\'\n]*\'|<masked-\d+>|\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?')


def engine_cmd(root: Path, engine: str) -> list[str]:
    path = str(root / engine)
    return ["bash", path] if engine.endswith(".sh") else [sys.executable, "-B", path]


def usage_line(root: Path, engine: str, src: str) -> tuple[str, set]:
    """--help's first line, and the subcommands its usage names; run only when the source handles --help."""
    handles = "--help" in (skill_lint.shell_code(src) if engine.endswith(".sh") else src) or "argparse" in src
    if not handles:
        return "(no --help in the source; not run)", set()
    try:
        p = subprocess.run(engine_cmd(root, engine) + ["--help"], cwd=root, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return "(--help ran over 10 s)", set()
    text = p.stdout or p.stderr
    first = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
    if p.returncode != 0:
        return f"(--help exit {p.returncode}: {first[:120]})", set()
    usage = text.split("\n\n")[0]
    return first[:160], {s for m in USAGE_SUBS.findall(usage) for s in m.split(",")}


def profile(root: Path, required: list[str]) -> dict:
    sk = skill_lint.load(root.resolve())
    engines = sk.engines()
    text = "\n".join(sk.scripts[e] for e in engines)
    tests = sk.test_names()
    guards = {}
    for g in dict.fromkeys([*required, *GUARD_SIGNS]):
        ev = [f"test_guard_{g}"] if any(re.match(rf"test_guard_{re.escape(g)}(?:_|$)", t) for t in tests) else []
        label, rx = GUARD_SIGNS.get(g, ("", r"(?!)"))
        if re.search(rx, text):
            ev.append(f"prints {label}")
        code, name = GUARD_EXIT.get(g, (None, ""))
        if code and re.search(rf"\bEXIT_{name}\b|\b(?:exit|return)\s*\(?\s*{code}\b", text):
            ev.append(f"exit {code}")
        guards[g] = ev
    known = tuple(f"test_guard_{g}" for g in guards)
    other = sorted(t for t in tests if t.startswith("test_guard_") and not t.startswith(known))
    subs, usage = set(), {}
    for e in engines:
        src = sk.scripts[e]
        if e.endswith(".sh"):
            for arm in CASE_ARM.findall(skill_lint.shell_code(src)):
                subs |= {a.strip() for a in arm.split("|")}
        else:
            subs |= set(SUBPARSER.findall(src))
        usage[e], named = usage_line(sk.root, e, src)
        subs |= named
    return {"report": skill_lint.report(root), "engines": engines, "guards": guards, "other": other, "subs": subs, "usage": usage}


def numbers(out: str) -> list[str]:
    """The numbers in an output's body: header lines, quoted strings, times and masked ids left out."""
    body = "\n".join(ln for ln in out.splitlines() if not ln.lstrip().startswith("#"))
    return sorted(f"{float(x):.6g}" for x in NUMBER.findall(NOT_A_VALUE.sub(" ", body)))


def pick_engine(prof: dict, wanted: str | None, which: str) -> str:
    if wanted:
        hit = [e for e in prof["engines"] if e == wanted or Path(e).name == wanted]
        if not hit:
            raise ValueError(f"{which} has no engine {wanted!r}; it has {', '.join(prof['engines']) or 'none'}")
        return hit[0]
    if len(prof["engines"]) != 1:
        raise ValueError(f"{which} has {len(prof['engines'])} engines ({', '.join(prof['engines']) or 'none'}); name one with --{which}-engine")
    return prof["engines"][0]


def compare(draft_dir: Path, existing: Path, run: str | None = None, run_existing: str | None = None,
            draft_engine: str | None = None, existing_engine: str | None = None, timeout: int = 120, note: str = "") -> int:
    draft_dir, existing = draft_dir.resolve(), existing.resolve()
    m = read_toml(draft_dir / "forge.toml")
    arch, required = m.get("archetype", "?"), list(m.get("guards", []))
    args_d = shlex.split(run) if run is not None else None
    args_e = shlex.split(run_existing) if run_existing is not None else args_d
    if any("--apply" in a for a in (args_d or []) + (args_e or [])):
        emit("REFUSED: compare runs engines read-only; --apply is not passed through", err=True)
        return EXIT_REFUSED
    d, e = profile(draft_dir, required), profile(existing, required)
    emit(header(target=f"draft {draft_dir} ({arch}) vs existing {existing}", window="n/a: the two skills as they are now",
                rows=f"{len(e['report']['checks'])} checks, {len(d['guards'])} guards"))
    if note:
        emit(note)
    emit("\n== lint ==  draft | existing")
    rd, re_ = d["report"], e["report"]
    emit(f"verdict  {rd['verdict']} ({rd['na']} N/A) | {re_['verdict']} ({re_['na']} N/A)")
    for cid, r in rd["checks"].items():
        x = re_["checks"][cid]
        line = f"{cid:<4} {r.status:<7} | {x.status:<7}"
        if x.status in ("FAIL", "WAIVED") and r.status != x.status:
            line += f"  existing: {x.detail[:140]}"
        elif r.status in ("FAIL", "WAIVED") and r.status != x.status:
            line += f"  draft: {r.detail[:140]}"
        emit(line)
    emit("\n== guards ==  draft | existing")
    for g in d["guards"]:
        mark = " (required)" if g in required else ""
        emit(f"{g}{mark}: {', '.join(d['guards'][g]) or '-'} | {', '.join(e['guards'][g]) or '-'}")
    if e["other"]:
        emit(f"existing's other guard tests: {', '.join(e['other'])}")
    emit("\n== subcommands ==  draft | existing")
    emit(f"{', '.join(sorted(d['subs'])) or '-'} | {', '.join(sorted(e['subs'])) or '-'}")
    for side, prof in (("draft", d), ("existing", e)):
        for eng, u in prof["usage"].items():
            emit(f"{side} {eng} --help: {u}")
    emit("\n== findings ==")
    found = 0
    for g in required:
        if not e["guards"][g]:
            found += 1
            emit(f"for the existing skill: no {g} guard, which {arch} requires (no test_guard_{g}, prints nothing for it)")
    for cid, x in re_["checks"].items():
        if x.status == "FAIL" and rd["checks"][cid].status != "FAIL":
            found += 1
            emit(f"for the existing skill: fails {cid}, which the draft passes")
    for g, ev in e["guards"].items():
        if ev and not d["guards"][g]:
            found += 1
            emit(f"for the {arch} template: the existing skill has the {g} guard ({', '.join(ev)}) and the draft has none")
    for t in e["other"]:
        found += 1
        emit(f"for the {arch} template: the existing skill tests a guard the taxonomy does not name: {t}")
    only = sorted(e["subs"] - d["subs"])
    if only:
        found += 1
        emit(f"for the {arch} template: the existing skill exposes {', '.join(only)}, which the draft does not")
    if not found:
        emit("none")
    if args_d is None:
        return EXIT_OK
    try:
        engs = [pick_engine(d, draft_engine, "draft"), pick_engine(e, existing_engine, "existing")]
    except ValueError as err:
        emit(f"compare: {err}", err=True)
        return EXIT_USAGE
    emit("\n== the same question, both engines ==")
    got = []
    for side, root, eng, args in (("draft", draft_dir, engs[0], args_d), ("existing", existing, engs[1], args_e)):
        try:
            p = subprocess.run(engine_cmd(root, eng) + args, cwd=root, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=timeout)
            rc, out = p.returncode, p.stdout
        except subprocess.TimeoutExpired:
            rc, out = "timeout", ""
        nums = numbers(out)
        got.append((rc, nums))
        emit(f"{side}: {shlex.join([eng, *args])} -> exit {rc}, {len(nums)} numbers in the body")
    (rc_d, n_d), (rc_e, n_e) = got
    if rc_d == rc_e and n_d == n_e:
        emit(f"SAME: exit {rc_d} and the same {len(n_d)} numbers")
        return EXIT_OK
    only_d = [x for x in n_d if x not in n_e][:8]
    only_e = [x for x in n_e if x not in n_d][:8]
    emit(f"DIFFERENT: exit {rc_d} | {rc_e}; only the draft: {', '.join(only_d) or '-'}; only the existing: {', '.join(only_e) or '-'}")
    return EXIT_PARTIAL


def compare_archetype(arch: str, existing: Path, **kw) -> int:
    """Draft ARCH into a temporary folder and compare it with EXISTING: the template back-test."""
    sk = skill_lint.load(existing.resolve())
    name = re.sub(r"[^a-z0-9-]+", "-", f"{sk.name}-draft".lower()).strip("-")
    if not re.match(r"[a-z]", name):
        name = "x-" + name
    question = sk.front.get("description", "").split(".")[0] or f"what {sk.name} answers"
    name = name[:41]
    tmp = Path(tempfile.mkdtemp(prefix="forge-compare."))
    try:
        out = draft(arch, name, question, tmp / name)
        env = name.replace("-", "_").upper()
        return compare(out, existing, note=f"back-test: drafted {arch} as {name}, in a temporary folder; its engine reads ${env}_* variables", **kw)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    d = sub.add_parser("draft")
    d.add_argument("archetype")
    d.add_argument("name")
    d.add_argument("--question", required=True)
    d.add_argument("--not-for", dest="not_for")
    d.add_argument("--out", type=Path)
    d.add_argument("--force", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("dir", type=Path)
    v.add_argument("--no-mutate", action="store_true")
    i = sub.add_parser("install")
    i.add_argument("dir", type=Path)
    i.add_argument("--dest", type=Path)
    i.add_argument("--apply", action="store_true", help="copy and record; without it, print what would change")
    c = sub.add_parser("compare")
    c.add_argument("dirs", nargs="+", type=Path, metavar="DRAFT EXISTING")
    c.add_argument("--archetype", help="draft this archetype into a temporary folder and compare it with EXISTING")
    c.add_argument("--run", metavar="ARGS", help="run both engines with ARGS and compare the numbers they print")
    c.add_argument("--run-existing", metavar="ARGS", help="the existing engine's ARGS, when its command line differs")
    c.add_argument("--draft-engine")
    c.add_argument("--existing-engine")
    c.add_argument("--timeout", type=int, default=120)
    a = p.parse_args(argv)
    if a.cmd == "compare":
        want = 1 if a.archetype else 2
        if len(a.dirs) != want or not all(x.is_dir() for x in a.dirs):
            emit("forge: compare takes DRAFT EXISTING, or --archetype ARCH EXISTING, each a skill folder", err=True)
            return EXIT_USAGE
        kw = dict(run=a.run, run_existing=a.run_existing, draft_engine=a.draft_engine,
                  existing_engine=a.existing_engine, timeout=a.timeout)
        try:
            if a.archetype:
                return compare_archetype(a.archetype, a.dirs[0], **kw)
            return compare(a.dirs[0], a.dirs[1], **kw)
        except ValueError as e:
            emit(f"forge: {e}", err=True)
            return EXIT_USAGE
    if a.cmd == "list":
        arch = archetypes()
        emit(header(target=str(templates_dir()), window="n/a: templates as installed", rows=len(arch)))
        for k, s in arch.items():
            emit(f"{k:<14} {s.get('summary', '')}")
            emit(f"{'':<14} guards: {', '.join(s.get('guards', [])) or 'none'}; writes: {'yes, behind --apply' if s.get('write_verbs') else 'none'}")
        return EXIT_OK
    if a.cmd == "draft":
        try:
            out = draft(a.archetype, a.name, a.question, a.out, a.not_for, a.force)
        except ValueError as e:
            emit(f"forge: {e}", err=True)
            return EXIT_USAGE
        emit(f"drafted {a.name} ({a.archetype}) in {out}")
        emit(f"next: edit {out / 'SKILL.md'} and the engine for this job's systems, then forge.py verify {out}")
        return EXIT_OK
    if a.cmd == "verify":
        return verify(a.dir, not a.no_mutate)
    return install(a.dir, a.dest, a.apply)


if __name__ == "__main__":
    sys.exit(main())
