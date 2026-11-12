---
name: hand-metrics
description: Use when asked for request rates by job. Not for logs.
---

# hand-metrics

A fixture, not a skill: a hand-written metrics skill in the flat layout, with
one guard (an expired login) and a `top` subcommand the metrics-query template
lacks. tests/test_forge.py compares a drafted metrics-query against it.

`python3 ~/.claude/skills/hand-metrics/tool.py query EXPR` prints `JOB VALUE` per series.
