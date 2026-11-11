---
name: lint-baseline
description: Use when asked whether a feature flag is on for a tenant. Reads the flag table. Not for changing a flag's rollout plan; the flag service's own console covers that.
---

# lint-baseline

A fixture, not a skill: the smallest folder that passes every skill-lint
check. Each entry in `../violations.toml` changes one line of it, and the
lint must then fail that one check and no other. Nothing runs its tests.

`python3 bin/engine.py show TENANT` prints the tenant's flags.
`python3 bin/engine.py flip TENANT FLAG` prints the change; `--apply` makes it.
