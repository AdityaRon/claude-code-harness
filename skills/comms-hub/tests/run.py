#!/usr/bin/env python3
"""Run the comms-hub tests, or their mutations.

  run.py            every test_*.py; ends with `--- Results: N passed, M failed ---`
  run.py --mutate   each mutation listed in a test file's docstring, applied to a
                    temp copy of the skill: the file must go red, or it cannot fail

A docstring mutation line reads
  name: script.py: `old text` => `new text`
and `name (may survive): ...` marks one a reason in the line allows to stay green.
`old text` must occur exactly once in the script, so a mutation cannot go stale.
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
LINE = re.compile(r"^\s+([\w-]+)( \(may survive\))?: ([\w.]+): `(.+?)` => `(.*?)`\s*$")


def run_tests() -> int:
    sys.path.insert(0, str(HERE))
    suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_*.py", top_level_dir=str(HERE))
    result = unittest.TextTestRunner(verbosity=1, stream=sys.stdout).run(suite)
    failed = len(result.failures) + len(result.errors)
    print(f"--- Results: {result.testsRun - failed} passed, {failed} failed ---")
    return failed


def mutations(test_file: Path):
    doc = ast.get_docstring(ast.parse(test_file.read_text())) or ""
    for line in doc.splitlines():
        m = LINE.match("  " + line if not line.startswith(" ") else line)
        if m:
            yield m.group(1), bool(m.group(2)), m.group(3), m.group(4), m.group(5)


def run_file(root: Path, test_file: str) -> int:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    p = subprocess.run([sys.executable, "-B", "-m", "unittest", test_file[:-3]], cwd=root / "tests",
                       env=env, capture_output=True, text=True, timeout=300)
    return p.returncode


def run_mutations() -> int:
    killed = survived = stale = 0
    for tf in sorted(HERE.glob("test_*.py")):
        listed = list(mutations(tf))
        if not listed:
            print(f"NONE {tf.name}: no mutations listed")
            stale += 1
            continue
        if run_file(SKILL, tf.name) != 0:
            print(f"RED  {tf.name}: fails unmutated, so no mutation means anything")
            stale += 1
            continue
        for name, may, script, old, new in listed:
            work = Path(tempfile.mkdtemp(prefix="comms-hub-mutate."))
            try:
                for sub in ("bin", "tests"):
                    shutil.copytree(SKILL / sub, work / sub)
                # test_hub.py reads the example config: without it every hub.py
                # mutation went red on FileNotFoundError, not on the rule.
                for f in SKILL.glob("*.example.toml"):
                    shutil.copy(f, work / f.name)
                target = work / "bin" / script
                text = target.read_text()
                n = text.count(old)
                if n != 1:
                    print(f"STALE {tf.name} {name}: `{old}` occurs {n}x in {script}")
                    stale += 1
                    continue
                target.write_text(text.replace(old, new))
                rc = run_file(work, tf.name)
            finally:
                shutil.rmtree(work, ignore_errors=True)
            if rc != 0:
                killed += 1
                print(f"red   {tf.name} {name}")
            elif may:
                killed += 1
                print(f"green {tf.name} {name} (allowed to survive)")
            else:
                survived += 1
                print(f"GREEN {tf.name} {name}: SURVIVED, the tests cannot see this rule")
    print(f"--- Results: {killed} passed, {survived + stale} failed ---")
    return survived + stale


if __name__ == "__main__":
    sys.exit(min(run_mutations() if "--mutate" in sys.argv[1:] else run_tests(), 255))
