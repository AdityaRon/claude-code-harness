#!/usr/bin/env python3
"""Run this skill's tests, or their mutations. skill-forge copies this file
into every skill it drafts, unchanged.

  run.py            every tests/test_*.py; ends with `--- Results: N passed, M failed ---`
  run.py --mutate   each mutation listed in a test file's docstring, applied to a
                    temp copy of the skill: the file must go red, or it cannot fail

A docstring mutation line reads
  name: script.py: `old text` => `new text`
where script.py is a file in bin/, or a path from the skill's root when it holds
a slash. `name (may survive): ...` marks one a reason in the line allows to stay
green. Either text may run on over the lines that follow. `old text` must occur
exactly once in the file, so a mutation cannot go stale.
Exit status is the failure count.
"""
from __future__ import annotations

import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
LINE = re.compile(r"^\s+([\w-]+)( \(may survive\))?: ([\w./-]+): `(.+?)` => `(.*?)`\s*$", re.S)
START = re.compile(r"^\s+([\w-]+)( \(may survive\))?: ([\w./-]+): `")


def run_tests() -> int:
    sys.path.insert(0, str(HERE))
    suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_*.py", top_level_dir=str(HERE))
    result = unittest.TextTestRunner(verbosity=1, stream=sys.stdout).run(suite)
    failed = len(result.failures) + len(result.errors)
    sys.stdout.write(f"--- Results: {result.testsRun - failed} passed, {failed} failed ---\n")
    return failed


def mutations(test_file: Path):
    """Each (name, may survive, target, old, new); old is None for a line that
    starts a mutation and never parses."""
    doc = ast.get_docstring(ast.parse(test_file.read_text())) or ""
    raw = doc.splitlines()
    lines = [ln if ln.startswith(" ") else "  " + ln for ln in raw]
    i = 0
    while i < len(lines):
        start = START.match(lines[i])
        if not start:
            i += 1
            continue
        text = lines[i]
        while not LINE.match(text) and i + 1 < len(lines) and not START.match(lines[i + 1]):
            i += 1
            text += "\n" + raw[i]
        m = LINE.match(text)
        yield (m.group(1), bool(m.group(2)), m.group(3), m.group(4), m.group(5)) if m \
            else (start.group(1), False, start.group(3), None, None)
        i += 1


def run_file(root: Path, test_file: str) -> int:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    p = subprocess.run([sys.executable, "-B", "-m", "unittest", test_file[:-3]], cwd=root / "tests",
                       env=env, capture_output=True, text=True, timeout=600)
    return p.returncode


def run_mutations(only: str | None = None) -> int:
    killed = survived = stale = 0
    for tf in sorted(HERE.glob("test_*.py")):
        if only and tf.name != only:
            continue
        listed = list(mutations(tf))
        if not listed:
            sys.stdout.write(f"NONE {tf.name}: no mutations listed\n")
            stale += 1
            continue
        if run_file(SKILL, tf.name) != 0:
            sys.stdout.write(f"RED  {tf.name}: fails unmutated, so no mutation means anything\n")
            stale += 1
            continue
        for name, may, target, old, new in listed:
            if old is None:
                sys.stdout.write(f"STALE {tf.name} {name}: the line does not parse as `old` => `new`\n")
                stale += 1
                continue
            work = Path(tempfile.mkdtemp(prefix="skill-mutate."))
            try:
                shutil.copytree(SKILL, work / "s", ignore=shutil.ignore_patterns("__pycache__", ".git"))
                path = work / "s" / (target if "/" in target else f"bin/{target}")
                text = path.read_text() if path.is_file() else ""
                n = text.count(old)
                if n != 1:
                    sys.stdout.write(f"STALE {tf.name} {name}: `{old}` occurs {n}x in {target}\n")
                    stale += 1
                    continue
                path.write_text(text.replace(old, new))
                rc = run_file(work / "s", tf.name)
            finally:
                shutil.rmtree(work, ignore_errors=True)
            if rc != 0:
                killed += 1
                sys.stdout.write(f"red   {tf.name} {name}\n")
            elif may:
                killed += 1
                sys.stdout.write(f"green {tf.name} {name} (allowed to survive)\n")
            else:
                survived += 1
                sys.stdout.write(f"GREEN {tf.name} {name}: SURVIVED, the tests cannot see this rule\n")
    sys.stdout.write(f"--- Results: {killed} passed, {survived + stale} failed ---\n")
    return survived + stale


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--mutate" in args:
        rest = [a for a in args if a != "--mutate"]
        sys.exit(min(run_mutations(rest[0] if rest else None), 255))
    sys.exit(min(run_tests(), 255))
