---
name: skill-forge
description: Use when starting in a new job's environment, or when asked to find the operational questions that keep coming up, inventory the systems that answer them, turn one into a skill, or lint a skill. Drafts one skill per recurring question from an archetype with the read-only, provenance and fault-injection guards built in. Not for a library of per-system skills (one per database or tool), and not for answering the question itself; the drafted skill does that.
---

# skill-forge: one skill per recurring question

A skill earns its keep when it answers ONE recurring question end to end
("why is this job slow", "which tenant drove the volume", "is this flag on for
X"), crossing whatever systems that takes. Never draft one skill per system.

In the commands below, `PY` is the interpreter that
`bash ~/.claude/skills/skill-forge/bin/python.sh` prints and `F` is
`~/.claude/skills/skill-forge/bin`. Write both out in full in every command
(`/usr/bin/python3.12 ~/.claude/skills/skill-forge/bin/discover.py`): shell
variables do not survive between calls. The config is
`~/.config/skill-forge/config.toml` (start from
`~/.claude/skills/skill-forge/config.example.toml`); state, `inventory.md`
included, is in `~/.local/state/skill-forge/`.

## The protocol, one skill per run

1. **Discover, read-only.** `PY F/discover.py` writes `inventory.md`: access
   (contexts, profiles, SSO and secret CLIs, each with its re-login command and
   what an expired session looks like), observability, data stores, control
   planes and repos, each line with the command that found it. Names only.
   `--probe-local` reads local containers. `--probe-context CTX` lists one
   cluster's cronjobs and services; ask the user before `--yes-prod`, and never
   port-forward or connect to production without that yes.
2. **Find demand.** `PY F/demand.py --top 10` ranks repeated command
   sequences, repeated questions and repeated failures from transcripts and
   shell history. Evidence is counts and sessions by date, never content.
3. **Choose.** Show the ranked list; the user picks one. One skill per run.
4. **Draft.** `PY F/forge.py list`, then
   `PY F/forge.py draft ARCHETYPE NAME --question "..."` renders into
   `~/.local/state/skill-forge/drafts/NAME`. Edit for this job: the trigger
   phrasings people actually type, what it does not cover and the sibling that
   does, and the engine's queries. Gotchas starts empty.
5. **Verify on the real target, with the user present.**
   `PY F/forge.py verify DIR` runs the skill's tests, each listed mutation
   (every one must go red) and skill_lint, all offline. Then run the engine for
   a real instance of the question, and inject each required guard's fault on
   the real system: a misspelled metric for ABSENT, a tiny cap for PARTIAL, an
   expired login for AUTH, a wrong context for the target check. A skill that
   only passed against fakes is not done.
6. **Install.** `PY F/forge.py install DIR` prints the copy; `--apply` copies
   to `~/.claude/skills/NAME` (or `--dest`, a work repo the user names) and
   records the question in `inventory.md`. It refuses the public harness clone
   and any skill the lint fails.
7. **Maintain.** When a session hits a new trap with a drafted skill, the fix
   goes into its engine as a guard with a test and a mutation, plus one Gotchas
   line. A memory alone is not a fix.

## Archetypes

| archetype | answers through | required guards |
|---|---|---|
| sql-readonly | one read-only statement, layered checks, `--self-test` | absent, partial, expired auth, wrong target |
| metrics-query | a Prometheus-compatible API; `ab` and `volume-step` analyses | absent, partial, expired auth, window, wrong target |
| logs-fetch | a log store, with the stream selector computed, not guessed | absent, partial, expired auth, window, wrong target |
| cluster-probe | a throwaway pod with a workload identity, always deleted | incomplete capture, leftover probe, expired auth, wrong target |
| job-run | a Job from a CronJob's own template, per-cluster results | absent, partial, expired auth, wrong target, incomplete capture |
| api-readonly | any REST API, GET only, paginated with a cap | absent, partial, expired auth, wrong target |
| runbook | an alert payload to deep links and the next skill | absent, wrong target, window |
| local-repro | Docker on production's exact image tag, synthetic seed data | wrong target, absent, incomplete capture |

## The conventions skill_lint checks

`PY F/skill_lint.py SKILL_DIR` lints any skill, drafted or hand-written, with
its scripts in `bin/` or at the skill root (`*.py`, `*.sh`) and its tests in
`tests/` or at the root. Fix a finding, or waive it in the skill's
`lint-waivers.toml` with a reason. A waiver without a reason fails, and so does
one for a check that now passes. WARN means every engine check was N/A: the
lint saw nothing to judge, and its note says what SKILL.md runs that it did not
read. That is not a pass.

| # | convention | the check |
|---|---|---|
| C1 | read-only by default; a write needs `--apply`, and without it prints what would change | a write verb needs `--apply` and a dry-run test |
| C2 | SQL read-only in layers: role, READ ONLY, allowlist, nested-write scan | `--self-test` exists and passes |
| C3 | no stored credentials; borrowed identity; secrets by env or stdin | no secret-named flag, argv secret or secret shape |
| C4 | a write and its audit row in one transaction | a test says so |
| C5 | guards against confident wrong answers | each required guard has a `test_guard_<id>` |
| C6 | a provenance header opens every output | the engine calls `header()` (shell: prints `# target:`); a golden test |
| C7 | every print goes through the masker | no `print` in an engine (shell: pipes through `mask.py --filter`); a planted-pattern test |
| C8 | thin SKILL.md, thick engine, literal trigger phrasings | `Use when` in the description; line budget; `--help` |
| C9 | a test file per script; mutations listed; no real clients in tests | the files, the lists, a quoting test where shell or SQL is built |
| C10 | a self-contained folder | anything outside goes through a declared env var; every script of its own SKILL.md runs is one the lint read |

## Reading the output

Every output opens with `#` lines: target, window (UTC, with bounds), command,
rows, partial. Exit 0 is an answer (or EMPTY, which is a real zero), 2 ABSENT
(the instrument does not exist, so not zero), 3 PARTIAL or VOID, 4 AUTH (an
expired login, never "no data"), 5 REFUSED or BLOCKED.

## Gotchas

- macOS `python3` is 3.9 and has no TOML reader; use the interpreter
  `python.sh` prints.
- `forge.py verify` proves the draft against fakes only. Step 5's live fault
  injection is what proves the guards on this job's systems.
