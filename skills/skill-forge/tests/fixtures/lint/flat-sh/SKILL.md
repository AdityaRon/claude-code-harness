---
name: flat-sh
description: Use when asked to roll a service's config forward. Not for a deploy; the deploy pipeline covers that.
---

# flat-sh

A fixture, not a skill: a flat-layout skill whose engine is a shell script at
the skill root. It writes with an unquoted `kubectl apply` and no --apply, and
prints with a bare echo and no header, so skill-lint must fail C1, C6 and C7.
Nothing runs its tests.

`bash ~/.claude/skills/flat-sh/tool.sh SERVICE` applies the service's config.
