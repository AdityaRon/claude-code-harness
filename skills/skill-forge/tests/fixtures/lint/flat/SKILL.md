---
name: flat-tool
description: Use when asked how many widgets a region holds. Not for moving widgets; the widget console covers that.
---

# flat-tool

A fixture, not a skill: the flat layout many hand-written skills use, with the
engine and its test at the skill root instead of in bin/ and tests/. Its engine
prints raw, opens with no header and writes with no --apply, so skill-lint must
fail C1, C6 and C7 on it. Nothing runs its tests.

`python3 ~/.claude/skills/flat-tool/tool.py --region R` prints the count.
