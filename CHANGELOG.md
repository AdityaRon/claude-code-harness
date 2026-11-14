# Changelog

Releases are tagged `vMAJOR.MINOR.PATCH`. The release workflow
(`.github/workflows/release.yml`) writes each entry from the PRs merged since
the previous tag and the hook benchmark against it (`bin/hook-bench.py`); the
GitHub Release carries the same text. `bin/harness-update.sh` moves an
installed machine to the newest tag.

## v1.4.1 (2026-11-14)

Merged since v1.4.0: 3 PRs.

### Security
- interpreter-guard, git-guard: one grep for each same-answer pattern list (#229)

### Speed
- hook-bench test: a call's floor is its slowest sleep, not a separate run's time (#231)

### Other
- skill-forge: skill_lint reads shell scripts with demand.py's heredoc reader (#228)

### Benchmark vs v1.4.0


2026-11-14T00:35:23Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.7 ms, `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 87.2 → 82.3 ms (-6%) | 87.1 → 82.3 ms (-6%) | 148.6 → 142.6 ms (-4%) | 187.2 → 177.2 ms (-5%) |
| WebFetch | 11 | 23.4 → 23.4 ms (+0%) | 30.9 → 30.9 ms (+0%) | 50.9 → 51.2 ms (+1%) | 46.0 → 46.1 ms (+0%) |
| Read/Grep | 41 | 50.2 → 50.3 ms (+0%) | 55.8 → 55.9 ms (+0%) | 76.5 → 77.1 ms (+1%) | 71.0 → 71.2 ms (+0%) |
| Write/Edit | 63 | 63.1 → 63.3 ms (+0%) | 66.9 → 66.9 ms (+0%) | 94.5 → 95.6 ms (+1%) | 164.3 → 164.1 ms (-0%) |
| Monitor | 5 | 48.3 → 49.1 ms (+2%) | 65.3 → 65.2 ms (-0%) | 130.2 → 128.4 ms (-1%) | 131.6 → 132.4 ms (+1%) |
| All | 492 | 74.0 → 72.4 ms (-2%) | 80.5 → 76.8 ms (-4%) | 145.9 → 138.2 ms (-5%) | 170.9 → 163.3 ms (-4%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 85.1 → 80.8 ms (-5%) | 147.4 → 143.0 ms (-3%) | 174.6 → 164.6 ms (-6%) | 83.7 → 79.4 ms |
| config-guard.sh | 63 | 20.8 → 20.9 ms (+0%) | 45.7 → 46.3 ms (+1%) | 29.0 → 29.1 ms (+0%) | 19.4 → 19.5 ms |
| mod-gate.sh | 63 | 4.5 → 4.5 ms (-0%) | 15.9 → 16.1 ms (+1%) | 5.2 → 5.1 ms (-0%) | 3.1 → 3.1 ms |
| network-guard.sh | 11 | 23.1 → 23.1 ms (-0%) | 50.9 → 51.2 ms (+1%) | 36.4 → 36.3 ms (-0%) | 21.7 → 21.6 ms |
| secret-scanner.sh | 63 | 27.5 → 27.5 ms (+0%) | 81.2 → 80.4 ms (-1%) | 33.8 → 33.9 ms (+0%) | 26.1 → 26.1 ms |
| sensitive-file-guard.sh | 104 | 50.3 → 50.3 ms (-0%) | 72.8 → 72.9 ms (+0%) | 56.9 → 56.9 ms (-0%) | 48.9 → 48.9 ms |
| subagent-cache-guard.sh | 492 | 9.2 → 9.2 ms (+0%) | 9.6 → 9.6 ms (-0%) | 9.0 → 9.0 ms (-0%) | 7.8 → 7.8 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.0 (2026-11-13)

Merged since v1.3.1: 23 PRs.

### Security
- pr-review: an ask can block the approval (#226)
- config-guard: case variants, unresolved prefixes, and copies into .claude ask (#223)
- token shapes: the test's roster is secret-scanner's own; four shapes caught everywhere (#221)
- hooks: one bash-guards hook runs the seven Bash and Monitor guards (#215)
- fix(guards): bash 3.2 ends a $( ) at a ) its heredoc body did not open (#208)
- skill-forge: demand.py reads heredocs as bash does, held to the guards' oracle (#206)
- Copies parity: five token-shape lists checked against secret-scanner; one run.py (#204)
- fix(guards): one quote reading for separators and groups; awk reads bytes (#202)
- fix: guards no longer skip a line bash runs after a false heredoc, a group or an escaped $' (#197)

### Speed
- hook-bench: launch a call's hooks together, as Claude Code does (#218) (#225)
- hook-latency: each Bash guard inside bash-guards, from its timing log (#220)
- tests/doctor.test.sh: slowest-first check holds when whole-second times tie (#214)
- tools: hook latency and session census reports; name "command hook N" records (#210)

### Compatibility
- install: say how running sessions pick up each change (#213)
- doctor: KILLED and TIMEOUT apart from failures, wall times, --smoke; install runs the smoke set (#212)

### Other
- session-start tests: bounds from this machine, not a fast one (#224)
- comms-hub panel: type section() and two() for 2.1.323's validate type check (#219)
- refactor: split hooks/lib.sh into hooks/lib/, one file per concern (#216)
- tests: a case past its time limit is a timeout, not a failure (#211)
- session-start: a 3 s budget, one session per machine for nudges and the index, a 30 s timeout (#209)
- Test infra: one pass/fail helper, shellcheck on tests/, a Python compile check, weekly mutations (#205)
- comms-hub: peers send through a slack-draft skill; one panel fixture (#203)
- feat(skill-forge): C10 fails an installed script SKILL.md runs undeclared (#198)

### Benchmark vs v1.3.1


2026-11-13T22:50:52Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V45 96-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.5 ms, `bash -c :` 1.1 ms, `jq -n 1` 1.8 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 77.0 → 63.6 ms (-17%) | 77.3 → 63.9 ms (-17%) | 121.6 → 108.1 ms (-11%) | 204.3 → 135.2 ms (-34%) |
| WebFetch | 11 | 16.7 → 17.3 ms (+4%) | 22.5 → 23.3 ms (+4%) | 37.9 → 39.3 ms (+4%) | 33.3 → 34.6 ms (+4%) |
| Read/Grep | 41 | 36.5 → 37.2 ms (+2%) | 41.2 → 41.5 ms (+1%) | 55.5 → 56.0 ms (+1%) | 52.1 → 52.8 ms (+1%) |
| Write/Edit | 63 | 44.0 → 44.8 ms (+2%) | 46.4 → 47.3 ms (+2%) | 68.4 → 69.6 ms (+2%) | 110.1 → 113.9 ms (+3%) |
| Monitor | 5 | 57.8 → 36.6 ms (-37%) | 67.4 → 47.9 ms (-29%) | 112.9 → 96.8 ms (-14%) | 171.1 → 96.1 ms (-44%) |
| All | 492 | 63.2 → 55.7 ms (-12%) | 69.0 → 58.8 ms (-15%) | 118.1 → 106.5 ms (-10%) | 175.4 → 123.0 ms (-30%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 62.6 ms (head only) | 107.5 ms | 126.4 ms | 61.6 ms |
| config-guard.sh | 440 | 10.7 → 15.1 ms (+41%) | 31.5 → 34.3 ms (+9%) | 11.8 → 21.4 ms (+82%) | 9.7 → 14.0 ms |
| env-guard.sh | 377 | 13.6 ms (base only) | 74.5 ms | 29.2 ms | 12.5 ms |
| git-guard.sh | 377 | 13.6 ms (base only) | 80.2 ms | 27.1 ms | 12.6 ms |
| interpreter-guard.sh | 377 | 13.4 ms (base only) | 73.5 ms | 30.5 ms | 12.3 ms |
| kubectl-guard.sh | 377 | 13.4 ms (base only) | 58.5 ms | 26.2 ms | 12.3 ms |
| mod-gate.sh | 63 | 3.4 → 3.4 ms (-1%) | 11.2 → 11.8 ms (+5%) | 3.9 → 3.9 ms (+0%) | 2.4 → 2.4 ms |
| network-guard.sh | 388 | 16.1 → 17.1 ms (+6%) | 67.7 → 39.5 ms (-42%) | 27.6 → 27.4 ms (-1%) | 15.1 → 16.1 ms |
| rm-guard.sh | 377 | 11.0 ms (base only) | 11.5 ms | 14.3 ms | 9.9 ms |
| secret-scanner.sh | 63 | 19.4 → 19.9 ms (+3%) | 60.1 → 61.4 ms (+2%) | 24.3 → 24.6 ms (+1%) | 18.4 → 18.9 ms |
| sensitive-file-guard.sh | 104 | 36.2 → 36.9 ms (+2%) | 53.6 → 55.1 ms (+3%) | 41.3 → 42.0 ms (+2%) | 35.2 → 35.8 ms |
| subagent-cache-guard.sh | 492 | 6.4 → 7.0 ms (+9%) | 6.6 → 7.2 ms (+9%) | 6.4 → 6.8 ms (+7%) | 5.3 → 5.9 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.3.1 (2026-11-13)

Merged since v1.3.0: 2 PRs.

### Other
- fix(tcc-check): fire on the error line, and after failed Bash calls (#200)
- fix: bin/ holds exactly what installs; clone-only tools move to tools/ (#196)

### Benchmark vs v1.3.0


2026-11-13T00:41:42Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.2 ms, `jq -n 1` 2.0 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 58.5 → 58.2 ms (-0%) | 57.3 → 57.2 ms (-0%) | 99.8 → 100.3 ms (+0%) | 189.7 → 189.8 ms (+0%) |
| WebFetch | 11 | 18.3 → 18.3 ms (-0%) | 24.5 → 24.5 ms (+0%) | 41.3 → 41.7 ms (+1%) | 36.1 → 36.1 ms (+0%) |
| Read/Grep | 41 | 40.7 → 40.7 ms (+0%) | 45.0 → 45.4 ms (+1%) | 61.5 → 61.8 ms (+1%) | 56.7 → 57.2 ms (+1%) |
| Write/Edit | 63 | 40.6 → 40.7 ms (+0%) | 42.6 → 42.7 ms (+0%) | 66.3 → 66.3 ms (-0%) | 104.3 → 104.7 ms (+0%) |
| Monitor | 5 | 41.5 → 41.0 ms (-1%) | 49.0 → 49.1 ms (+0%) | 94.5 → 94.3 ms (-0%) | 160.5 → 160.4 ms (-0%) |
| All | 492 | 51.0 → 51.3 ms (+1%) | 53.6 → 53.6 ms (-0%) | 96.8 → 96.7 ms (-0%) | 163.9 → 164.1 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 440 | 12.0 → 12.0 ms (+0%) | 34.9 → 35.1 ms (+1%) | 13.1 → 13.1 ms (+0%) |
| env-guard.sh | 377 | 14.8 → 14.8 ms (+0%) | 84.0 → 85.0 ms (+1%) | 32.6 → 32.6 ms (+0%) |
| git-guard.sh | 377 | 15.1 → 15.1 ms (-0%) | 86.6 → 86.9 ms (+0%) | 29.9 → 29.8 ms (-0%) |
| interpreter-guard.sh | 377 | 14.9 → 14.9 ms (-0%) | 80.1 → 79.8 ms (-0%) | 33.3 → 33.3 ms (-0%) |
| kubectl-guard.sh | 377 | 14.8 → 14.8 ms (+0%) | 63.7 → 64.2 ms (+1%) | 28.8 → 28.8 ms (-0%) |
| mod-gate.sh | 63 | 3.7 → 3.8 ms (+1%) | 12.5 → 12.6 ms (+1%) | 4.2 → 4.3 ms (+1%) |
| network-guard.sh | 388 | 17.9 → 17.9 ms (+0%) | 73.9 → 73.9 ms (-0%) | 30.2 → 30.3 ms (+0%) |
| rm-guard.sh | 377 | 12.3 → 12.3 ms (+0%) | 12.8 → 13.1 ms (+3%) | 15.9 → 16.0 ms (+0%) |
| secret-scanner.sh | 63 | 22.0 → 22.1 ms (+0%) | 66.3 → 66.3 ms (-0%) | 27.0 → 27.2 ms (+0%) |
| sensitive-file-guard.sh | 104 | 40.6 → 40.6 ms (+0%) | 59.0 → 59.7 ms (+1%) | 45.9 → 46.1 ms (+0%) |
| subagent-cache-guard.sh | 492 | 7.1 → 7.1 ms (+0%) | 7.4 → 7.4 ms (+0%) | 7.0 → 7.0 ms (+0%) |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.3.0 (2026-11-12)

Merged since v1.2.0: 4 PRs.

### Other
- docs: README names every wired hook, skill folder and suite; repo-layout enforces it (#195)
- session-start: 5 processes on a start, not 20 (#193)
- fix: install.sh replaces live files by rename, not in place (#192)
- feat: skill-forge fixes from a first run on a real machine (#191)

### Benchmark vs v1.2.0


2026-11-12T15:28:52Z, Linux 7.0.0-1019-azure x86_64, INTEL(R) XEON(R) PLATINUM 8573C, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.1 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 52.5 → 52.4 ms (-0%) | 52.0 → 52.0 ms (+0%) | 89.9 → 90.7 ms (+1%) | 172.8 → 172.3 ms (-0%) |
| WebFetch | 11 | 17.5 → 17.6 ms (+1%) | 23.1 → 23.1 ms (+0%) | 38.8 → 38.7 ms (-0%) | 34.2 → 34.2 ms (-0%) |
| Read/Grep | 41 | 38.8 → 38.9 ms (+0%) | 42.5 → 42.5 ms (-0%) | 62.6 → 61.1 ms (-2%) | 53.1 → 53.0 ms (-0%) |
| Write/Edit | 63 | 39.7 → 39.2 ms (-1%) | 40.7 → 40.6 ms (-0%) | 58.0 → 56.3 ms (-3%) | 98.4 → 98.1 ms (-0%) |
| Monitor | 5 | 38.9 → 40.0 ms (+3%) | 45.7 → 46.7 ms (+2%) | 87.7 → 88.7 ms (+1%) | 151.5 → 151.6 ms (+0%) |
| All | 492 | 46.4 → 45.3 ms (-2%) | 49.0 → 49.1 ms (+0%) | 87.7 → 88.6 ms (+1%) | 150.0 → 149.5 ms (-0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 440 | 11.1 → 11.1 ms (+0%) | 31.7 → 32.0 ms (+1%) | 11.9 → 11.9 ms (-0%) |
| env-guard.sh | 377 | 13.5 → 13.5 ms (-0%) | 76.8 → 77.4 ms (+1%) | 30.0 → 29.7 ms (-1%) |
| git-guard.sh | 377 | 13.8 → 13.7 ms (-0%) | 78.7 → 79.1 ms (+1%) | 27.2 → 27.2 ms (+0%) |
| interpreter-guard.sh | 377 | 13.5 → 13.4 ms (-1%) | 73.9 → 72.7 ms (-2%) | 30.5 → 30.3 ms (-1%) |
| kubectl-guard.sh | 377 | 13.4 → 13.4 ms (-0%) | 56.7 → 57.4 ms (+1%) | 26.1 → 26.0 ms (-0%) |
| mod-gate.sh | 63 | 3.3 → 3.3 ms (-0%) | 11.1 → 11.8 ms (+6%) | 3.7 → 3.7 ms (+1%) |
| network-guard.sh | 388 | 16.4 → 16.4 ms (-0%) | 65.5 → 65.6 ms (+0%) | 27.5 → 27.5 ms (+0%) |
| rm-guard.sh | 377 | 11.2 → 11.2 ms (-0%) | 12.1 → 12.9 ms (+7%) | 14.6 → 14.6 ms (+0%) |
| secret-scanner.sh | 63 | 21.0 → 20.8 ms (-1%) | 58.0 → 56.3 ms (-3%) | 25.4 → 25.2 ms (-1%) |
| sensitive-file-guard.sh | 104 | 39.1 → 38.9 ms (-1%) | 56.9 → 55.2 ms (-3%) | 43.8 → 43.8 ms (-0%) |
| subagent-cache-guard.sh | 492 | 6.4 → 6.4 ms (+0%) | 6.8 → 6.8 ms (-0%) | 6.2 → 6.3 ms (+0%) |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.2.0 (2026-11-12)

Merged since v1.1.19: 3 PRs.

### Compatibility
- contract: say what asks at write time for a mod Claude writes (#188)

### Other
- feat: skill-forge, one skill per recurring question, with skill_lint (#189)
- comms panel: read the listed PRs again every fifth minute (#187)

### Benchmark vs v1.1.19

hooks/ and config/settings.json are unchanged since v1.1.19; benchmark skipped (both sides would run the same files).

## v1.1.19 (2026-11-11)

Merged since v1.1.18: 4 PRs.

### Compatibility
- config-guard: ask before a Bash write into a mod Claude Code loads by itself (#185)
- contract: review Claude Code releases up to 2.1.322 (#183)

### Other
- comms panel: read when drawn, right labels, keep the last good read (#186)
- comms-hub: route review comments tagged [do] (#184)

### Benchmark vs v1.1.18


2026-11-11T14:36:27Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 69.0 → 69.2 ms (+0%) | 67.7 → 67.8 ms (+0%) | 118.6 → 117.9 ms (-1%) | 224.7 → 224.7 ms (-0%) |
| WebFetch | 11 | 21.7 → 21.5 ms (-1%) | 28.8 → 28.7 ms (-1%) | 48.4 → 48.5 ms (+0%) | 42.7 → 42.4 ms (-1%) |
| Read/Grep | 41 | 48.0 → 48.1 ms (+0%) | 53.0 → 53.2 ms (+0%) | 74.1 → 72.1 ms (-3%) | 66.7 → 67.1 ms (+1%) |
| Write/Edit | 63 | 48.0 → 48.0 ms (-0%) | 50.7 → 50.7 ms (+0%) | 77.5 → 77.5 ms (+0%) | 123.8 → 124.1 ms (+0%) |
| Monitor | 5 | 47.9 → 47.8 ms (-0%) | 58.3 → 57.7 ms (-1%) | 115.4 → 111.2 ms (-4%) | 190.6 → 189.1 ms (-1%) |
| All | 492 | 60.2 → 60.9 ms (+1%) | 63.4 → 63.4 ms (+0%) | 115.3 → 114.2 ms (-1%) | 194.2 → 194.3 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 440 | 14.1 → 14.1 ms (-0%) | 40.9 → 41.5 ms (+2%) | 15.4 → 15.4 ms (+0%) |
| env-guard.sh | 377 | 17.3 → 17.3 ms (-0%) | 99.4 → 99.2 ms (-0%) | 38.7 → 38.8 ms (+0%) |
| git-guard.sh | 377 | 17.7 → 17.7 ms (-0%) | 102.2 → 101.6 ms (-1%) | 35.3 → 35.3 ms (+0%) |
| interpreter-guard.sh | 377 | 17.5 → 17.4 ms (-0%) | 95.7 → 96.4 ms (+1%) | 39.7 → 39.7 ms (+0%) |
| kubectl-guard.sh | 377 | 17.4 → 17.4 ms (-0%) | 75.9 → 75.0 ms (-1%) | 34.2 → 34.2 ms (-0%) |
| mod-gate.sh | 63 | 4.3 → 4.3 ms (-0%) | 15.0 → 15.0 ms (+1%) | 4.9 → 4.9 ms (+0%) |
| network-guard.sh | 388 | 21.1 → 21.1 ms (-0%) | 87.2 → 87.1 ms (-0%) | 35.9 → 35.8 ms (-0%) |
| rm-guard.sh | 377 | 14.4 → 14.4 ms (-0%) | 15.6 → 15.4 ms (-1%) | 18.8 → 18.8 ms (-0%) |
| secret-scanner.sh | 63 | 26.1 → 26.2 ms (+0%) | 77.5 → 77.5 ms (+0%) | 32.3 → 32.4 ms (+0%) |
| sensitive-file-guard.sh | 104 | 47.9 → 47.9 ms (+0%) | 68.7 → 69.6 ms (+1%) | 54.4 → 54.6 ms (+0%) |
| subagent-cache-guard.sh | 492 | 8.2 → 8.2 ms (-0%) | 8.7 → 8.7 ms (+1%) | 8.1 → 8.1 ms (+0%) |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.1.18 (2026-11-07)

Merged since v1.1.17: 3 PRs.

### Compatibility
- contract: review Claude Code releases up to 2.1.319 (#181)

### Other
- comms panel: the new count up top, colour with one meaning, status before message (#180)
- comms-hub: thread owners from sends, every-tick mention searches that must reach (#179)

### Benchmark vs v1.1.17

hooks/ and config/settings.json are unchanged since v1.1.17; benchmark skipped (both sides would run the same files).

## v1.1.17 (2026-11-05)

Merged since v1.1.16: 1 PR.

### Other
- comms-hub: the ticket-link check takes its own project list (#177)

### Benchmark vs v1.1.16

hooks/ and config/settings.json are unchanged since v1.1.16; benchmark skipped (both sides would run the same files).

## v1.1.16 (2026-11-05)

Merged since v1.1.15: 1 PR.

### Other
- comms-hub: close what a send or a hand re-look settles; link tickets and commits (#175)

### Benchmark vs v1.1.15

hooks/ and config/settings.json are unchanged since v1.1.15; benchmark skipped (both sides would run the same files).

## v1.1.15 (2026-11-04)

Merged since v1.1.14: 1 PR.

### Compatibility
- contract: review Claude Code releases up to 2.1.318 (#173)

### Benchmark vs v1.1.14

hooks/ and config/settings.json are unchanged since v1.1.14; benchmark skipped (both sides would run the same files).

## v1.1.14 (2026-11-03)

Merged since v1.1.13: 2 PRs.

### Compatibility
- contract: review Claude Code releases up to 2.1.317 (#171)

### Other
- comms-hub: trace missed ticks, record full scans, minute panel reads (#170)

### Benchmark vs v1.1.13

hooks/ and config/settings.json are unchanged since v1.1.13; benchmark skipped (both sides would run the same files).

## v1.1.13 (2026-10-31)

Merged since v1.1.12: 1 PR.

### Compatibility
- contract: review Claude Code releases up to 2.1.316 (#168)

### Benchmark vs v1.1.12

hooks/ and config/settings.json are unchanged since v1.1.12; benchmark skipped (both sides would run the same files).

## v1.1.12 (2026-10-30)

Merged since v1.1.11: 1 PR.

### Other
- comms panel: per-section open with "fewer", a way back at the end, yesterday's events (#166)

### Benchmark vs v1.1.11

hooks/ and config/settings.json are unchanged since v1.1.11; benchmark skipped (both sides would run the same files).

## v1.1.11 (2026-10-30)

Merged since v1.1.10: 2 PRs.

### Compatibility
- contract: review Claude Code releases up to 2.1.314 (#164)

### Other
- comms-hub: config names a stopped session's transcript after a relaunch; mention control checks its rows (#162)

### Benchmark vs v1.1.10

hooks/ and config/settings.json are unchanged since v1.1.10; benchmark skipped (both sides would run the same files).

## v1.1.10 (2026-10-29)

Merged since v1.1.9: 6 PRs.

### Security
- comms-hub: reviews as a decision list, routed asks, re-looks, PR status in the panel (#158)

### Other
- comms-hub skill: mention queries go in the search's query field (#161)
- comms-hub: hub.py park keeps a PR off the panel and the status sections (#160)
- comms-hub panel: expand to read everything, a text fallback for phones, a waiting PRS line (#159)
- comms-hub panel: a held draft no longer crashes it; rows cut at 80 (#157)
- comms-hub: 600k compact window, kindless log lines, cron ticks counted, review cap (#156)

### Benchmark vs v1.1.9

hooks/ and config/settings.json are unchanged since v1.1.9; benchmark skipped (both sides would run the same files).

## v1.1.9 (2026-10-29)

Merged since v1.1.8: 4 PRs.

### Security
- Guard and audit the Monitor tool like Bash (#154)
- upstream-check: run each shipped mod's tests against the CLI (#152)

### Other
- comms-hub: a panel to read at a glance, from structured log events (#153)
- license: MIT (#150)

### Benchmark vs v1.1.8


2026-10-29T13:16:16Z, Linux 7.0.0-1017-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.5 ms, `jq -n 1` 2.5 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 61.2 → 61.0 ms (-0%) | 62.1 → 62.1 ms (-0%) | 104.3 → 103.9 ms (-0%) | 195.1 → 195.0 ms (-0%) |
| WebFetch | 11 | 19.4 → 19.7 ms (+1%) | 24.9 → 24.9 ms (+0%) | 40.2 → 39.8 ms (-1%) | 35.2 → 35.4 ms (+0%) |
| Read/Grep | 41 | 50.3 → 50.3 ms (-0%) | 53.1 → 52.8 ms (-0%) | 78.2 → 77.3 ms (-1%) | 63.8 → 63.5 ms (-0%) |
| Write/Edit | 63 | 50.2 → 50.4 ms (+0%) | 51.1 → 51.0 ms (-0%) | 77.2 → 78.5 ms (+2%) | 116.0 → 115.9 ms (-0%) |
| Monitor | 5 | 5.9 → 40.5 ms (+585%) | 5.9 → 52.8 ms (+796%) | 6.0 → 102.7 ms (+1601%) | 5.7 → 165.7 ms (+2807%) |
| All | 492 | 54.8 → 55.0 ms (+0%) | 58.5 → 59.0 ms (+1%) | 102.3 → 102.5 ms (+0%) | 168.5 → 170.1 ms (+1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 435 | 12.0 → 12.0 ms (+0%) | 32.9 → 33.0 ms (+0%) | 12.9 → 12.8 ms (-0%) |
| env-guard.sh | 372 | 14.8 → 14.8 ms (-0%) | 88.7 → 88.2 ms (-1%) | 34.4 → 34.3 ms (-0%) |
| git-guard.sh | 372 | 14.2 → 14.2 ms (-0%) | 99.9 → 99.9 ms (+0%) | 31.3 → 31.1 ms (-1%) |
| interpreter-guard.sh | 372 | 14.3 → 14.3 ms (+0%) | 95.6 → 96.1 ms (+0%) | 36.3 → 36.0 ms (-1%) |
| kubectl-guard.sh | 372 | 14.1 → 14.1 ms (-0%) | 65.5 → 65.5 ms (+0%) | 28.9 → 28.7 ms (-1%) |
| mod-gate.sh | 63 | 3.0 → 3.0 ms (-0%) | 12.8 → 13.0 ms (+2%) | 3.5 → 3.5 ms (-0%) |
| network-guard.sh | 383 | 18.2 → 18.2 ms (+0%) | 80.9 → 80.6 ms (-0%) | 31.0 → 31.3 ms (+1%) |
| rm-guard.sh | 372 | 12.3 → 12.3 ms (-0%) | 13.1 → 13.4 ms (+2%) | 16.2 → 16.4 ms (+1%) |
| secret-scanner.sh | 63 | 24.8 → 24.8 ms (+0%) | 77.2 → 78.5 ms (+2%) | 30.9 → 31.0 ms (+0%) |
| sensitive-file-guard.sh | 104 | 50.2 → 50.3 ms (+0%) | 63.4 → 62.1 ms (-2%) | 55.0 → 54.8 ms (-0%) |
| subagent-cache-guard.sh | 492 | 5.8 → 5.8 ms (-0%) | 6.1 → 6.1 ms (+0%) | 5.6 → 5.6 ms (+0%) |

Decisions: 489 of 492 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| monitor-rm-home `sleep 60; rm -rf ~/` | allow (silent) | deny (rm-guard.sh) |
| monitor-curl-unlisted `while true; do curl -s https://status.unlisted.example/poll;` | allow (silent) | ask (network-guard.sh) |
| monitor-ws-unlisted `wss://feed.unlisted.example/events` | allow (silent) | ask (network-guard.sh) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.1.8 (2026-10-28)

Merged since v1.1.7: 3 PRs.

### Compatibility
- upstream drift: a review asks only what the owner must decide (#148)
- contract: review Claude Code releases up to 2.1.312 (#146)

### Other
- comms-hub: post_at must come after the first tick; weekends post Monday (#149)

### Benchmark vs v1.1.7

hooks/ and config/settings.json are unchanged since v1.1.7; benchmark skipped (both sides would run the same files).

## v1.1.7 (2026-10-28)

Merged since v1.1.6: 4 PRs.

### Other
- upstream-check: probes trust their directory in a config dir of their own (#145)
- Claude opens its own PRs, and Upstream drift sends a breakage to Claude to fix (#143)
- fix: don't flag workspace-trust noise as upstream breakage; assess 2.1.311 (#142)
- comms-hub: a panel beside the comms session with held drafts and today's log (#141)

### Benchmark vs v1.1.6

hooks/ and config/settings.json are unchanged since v1.1.6; benchmark skipped (both sides would run the same files).

## v1.1.6 (2026-10-27)

Merged since v1.1.5: 1 PR.

### Other
- comms-hub: a reply that only restates a posted review becomes a reaction (#140)

### Benchmark vs v1.1.5

hooks/ and config/settings.json are unchanged since v1.1.5; benchmark skipped (both sides would run the same files).

## v1.1.5 (2026-10-26)

Merged since v1.1.4: 1 PR.

### Security
- Unattended spend: business-hours comms tick, subagent cache guard, spend report (#137)

### Benchmark vs v1.1.4


2026-10-26T23:17:24Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 487 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 58.1 → 58.0 ms (-0%) | 59.5 → 59.5 ms (+0%) | 99.9 → 99.7 ms (-0%) | 181.2 → 186.8 ms (+3%) |
| WebFetch | 11 | 19.0 → 18.7 ms (-1%) | 23.7 → 23.7 ms (-0%) | 37.5 → 37.8 ms (+1%) | 27.9 → 33.5 ms (+20%) |
| Read/Grep | 41 | 49.5 → 49.4 ms (-0%) | 52.1 → 52.1 ms (+0%) | 78.5 → 77.1 ms (-2%) | 56.5 → 62.2 ms (+10%) |
| Write/Edit | 63 | 49.2 → 49.4 ms (+0%) | 49.6 → 49.5 ms (-0%) | 73.9 → 74.0 ms (+0%) | 106.1 → 111.5 ms (+5%) |
| All | 487 | 52.9 → 52.6 ms (-1%) | 56.8 → 56.8 ms (-0%) | 98.5 → 98.4 ms (-0%) | 157.5 → 163.1 ms (+4%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 435 | 11.8 → 11.9 ms (+0%) | 31.7 → 31.5 ms (-1%) | 12.4 → 12.4 ms (-0%) |
| env-guard.sh | 372 | 14.5 → 14.6 ms (+0%) | 86.2 → 85.9 ms (-0%) | 33.0 → 33.1 ms (+0%) |
| git-guard.sh | 372 | 13.9 → 14.0 ms (+0%) | 96.3 → 96.1 ms (-0%) | 29.9 → 29.9 ms (+0%) |
| interpreter-guard.sh | 372 | 14.1 → 14.1 ms (+0%) | 90.9 → 91.0 ms (+0%) | 34.3 → 34.4 ms (+0%) |
| kubectl-guard.sh | 372 | 13.9 → 13.9 ms (+0%) | 62.4 → 62.2 ms (-0%) | 27.6 → 27.6 ms (-0%) |
| mod-gate.sh | 63 | 2.9 → 3.0 ms (+1%) | 12.6 → 12.7 ms (+0%) | 3.4 → 3.4 ms (-0%) |
| network-guard.sh | 383 | 17.8 → 17.8 ms (+0%) | 77.2 → 77.9 ms (+1%) | 29.7 → 29.7 ms (-0%) |
| rm-guard.sh | 372 | 12.1 → 12.1 ms (-0%) | 12.9 → 12.8 ms (-1%) | 15.7 → 15.7 ms (-0%) |
| secret-scanner.sh | 63 | 23.9 → 23.9 ms (-0%) | 73.9 → 74.0 ms (+0%) | 29.5 → 29.5 ms (-0%) |
| sensitive-file-guard.sh | 104 | 49.2 → 49.2 ms (+0%) | 59.9 → 60.9 ms (+2%) | 53.3 → 53.3 ms (-0%) |
| subagent-cache-guard.sh | 487 | 5.7 ms (head only) | 6.0 ms | 5.5 ms |

Decisions: 487 of 487 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.1.4 (2026-10-25)

Merged since v1.1.3: 1 PR.

### Compatibility
- contract: review Claude Code releases up to 2.1.310 (#134)

### Benchmark vs v1.1.3

hooks/ and config/settings.json are unchanged since v1.1.3; benchmark skipped (both sides would run the same files).

## v1.1.3 (2026-10-24)

Merged since v1.1.2: 1 PR.

### Security
- config-guard asks on the plugin cache; git-guard on a subcommand it cannot read (#133)

### Benchmark vs v1.1.2


2026-10-24T11:16:14Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 487 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.4 ms, `jq -n 1` 2.5 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 56.9 → 57.1 ms (+0%) | 58.7 → 58.9 ms (+0%) | 99.1 → 98.8 ms (-0%) | 179.1 → 179.1 ms (+0%) |
| WebFetch | 11 | 18.3 → 18.6 ms (+2%) | 23.1 → 23.1 ms (+0%) | 36.8 → 36.6 ms (-1%) | 27.2 → 27.2 ms (+0%) |
| Read/Grep | 41 | 48.0 → 48.0 ms (+0%) | 50.6 → 50.6 ms (-0%) | 74.5 → 73.8 ms (-1%) | 55.0 → 55.0 ms (-0%) |
| Write/Edit | 63 | 48.2 → 48.2 ms (+0%) | 48.7 → 48.9 ms (+0%) | 74.3 → 73.5 ms (-1%) | 104.4 → 104.7 ms (+0%) |
| All | 487 | 51.8 → 51.8 ms (+0%) | 55.9 → 56.1 ms (+0%) | 97.7 → 97.7 ms (-0%) | 155.5 → 155.6 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 435 | 11.6 → 11.6 ms (-0%) | 31.2 → 30.8 ms (-1%) | 12.2 → 12.2 ms (+0%) |
| env-guard.sh | 372 | 14.2 → 14.1 ms (-0%) | 85.1 → 84.9 ms (-0%) | 32.7 → 32.6 ms (-0%) |
| git-guard.sh | 372 | 13.5 → 13.5 ms (-0%) | 94.7 → 95.9 ms (+1%) | 29.4 → 29.6 ms (+1%) |
| interpreter-guard.sh | 372 | 13.7 → 13.7 ms (-0%) | 90.8 → 90.5 ms (-0%) | 34.1 → 34.0 ms (-0%) |
| kubectl-guard.sh | 372 | 13.5 → 13.5 ms (+0%) | 62.4 → 61.8 ms (-1%) | 27.3 → 27.3 ms (-0%) |
| mod-gate.sh | 63 | 2.9 → 2.8 ms (-0%) | 12.5 → 12.4 ms (-1%) | 3.3 → 3.4 ms (+1%) |
| network-guard.sh | 383 | 17.4 → 17.4 ms (-0%) | 76.9 → 77.5 ms (+1%) | 29.4 → 29.3 ms (-0%) |
| rm-guard.sh | 372 | 11.8 → 11.8 ms (-0%) | 12.5 → 12.6 ms (+1%) | 15.5 → 15.5 ms (-0%) |
| secret-scanner.sh | 63 | 23.5 → 23.6 ms (+0%) | 74.3 → 73.5 ms (-1%) | 29.2 → 29.3 ms (+0%) |
| sensitive-file-guard.sh | 104 | 48.0 → 48.0 ms (+0%) | 59.0 → 59.5 ms (+1%) | 52.1 → 52.2 ms (+0%) |

Decisions: 484 of 487 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-hole-git-variable-subcommand `X=push; git $X --force origin main` | allow (silent) | ask (git-guard.sh) |
| friction-hole-git-function-args `g() { git "$@"; }; g push --force origin main` | allow (silent) | ask (git-guard.sh) |
| friction-hole-config-plugins-cp `cp hooks.json ~/.claude/plugins/cache/p/hooks/hooks.json` | allow (silent) | ask (config-guard.sh) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.1.2 (2026-10-23)

Merged since v1.1.1: 5 PRs.

### Security
- git-guard and rm-guard: an inline script's shell-out is a command (#129)
- kubectl-guard: text is not a command; an inline script's shell-out is (#126)

### Compatibility
- contract: review Claude Code releases up to 2.1.309 (#130)

### Other
- Name a session host that lost its binary; move clones off ~/Desktop (#128)
- comms-hub: the pass-upstream list (#127)

### Benchmark vs v1.1.1


2026-10-23T22:28:40Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 481 payloads (366 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 366 | 53.7 → 56.1 ms (+5%) | 56.0 → 57.5 ms (+3%) | 95.2 → 96.1 ms (+1%) | 167.4 → 174.9 ms (+5%) |
| WebFetch | 11 | 17.1 → 17.7 ms (+3%) | 22.0 → 22.6 ms (+3%) | 35.1 → 36.1 ms (+3%) | 26.1 → 26.8 ms (+2%) |
| Read/Grep | 41 | 45.8 → 46.2 ms (+1%) | 48.2 → 48.7 ms (+1%) | 70.5 → 70.9 ms (+1%) | 52.6 → 53.0 ms (+1%) |
| Write/Edit | 63 | 45.8 → 46.4 ms (+1%) | 46.3 → 47.0 ms (+1%) | 71.4 → 72.3 ms (+1%) | 98.9 → 100.8 ms (+2%) |
| All | 481 | 48.4 → 50.9 ms (+5%) | 53.3 → 54.6 ms (+2%) | 94.0 → 94.9 ms (+1%) | 145.4 → 151.4 ms (+4%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 429 | 10.7 → 11.3 ms (+5%) | 29.4 → 30.2 ms (+3%) | 11.2 → 11.7 ms (+5%) |
| env-guard.sh | 366 | 13.2 → 13.7 ms (+4%) | 81.8 → 82.8 ms (+1%) | 31.2 → 32.0 ms (+3%) |
| git-guard.sh | 366 | 12.6 → 13.1 ms (+4%) | 83.4 → 93.5 ms (+12%) | 27.2 → 28.4 ms (+5%) |
| interpreter-guard.sh | 366 | 12.7 → 13.2 ms (+4%) | 87.7 → 89.0 ms (+1%) | 32.9 → 33.4 ms (+2%) |
| kubectl-guard.sh | 366 | 12.6 → 13.1 ms (+4%) | 53.5 → 60.7 ms (+13%) | 24.0 → 26.8 ms (+12%) |
| mod-gate.sh | 63 | 2.7 → 2.7 ms (-0%) | 11.5 → 12.1 ms (+5%) | 3.2 → 3.2 ms (+1%) |
| network-guard.sh | 377 | 16.4 → 16.9 ms (+3%) | 74.5 → 75.4 ms (+1%) | 28.1 → 28.8 ms (+2%) |
| rm-guard.sh | 366 | 11.0 → 11.5 ms (+5%) | 11.3 → 11.9 ms (+6%) | 14.2 → 15.1 ms (+6%) |
| secret-scanner.sh | 63 | 22.2 → 22.7 ms (+2%) | 71.4 → 72.3 ms (+1%) | 27.7 → 28.3 ms (+2%) |
| sensitive-file-guard.sh | 104 | 45.8 → 46.3 ms (+1%) | 55.5 → 55.8 ms (+1%) | 49.7 → 50.3 ms (+1%) |

Decisions: 455 of 481 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-subprocess-list-kubectl-view `python3 -c "import subprocess; subprocess.run(['kubectl','de` | allow (silent) | ask (kubectl-guard.sh) |
| friction-subprocess-list-git-view `python3 -c "import subprocess; subprocess.run(['git','push',` | allow (silent) | deny (git-guard.sh) |
| friction-fp-kubectl-heredoc-to-assigned-var `F="$CLAUDE_JOB_DIR/tmp/draft.md"; cat > "$F" <<'EOF' Open a ` | ask (kubectl-guard.sh) | allow (silent) |
| friction-fp-kubectl-heredoc-then-semicolon-line `cat > a.md <<'EOF' Open a shell with kubectl exec, then chec` | ask (kubectl-guard.sh) | allow (silent) |
| friction-fp-kubectl-heredoc-then-plain-line `cat > a.md <<'EOF' Open a shell with kubectl exec, then chec` | ask (kubectl-guard.sh) | allow (silent) |
| friction-fp-kubectl-python-heredoc-comment `python3 - <<'EOF' # kubectl exec opens a shell; this only co` | ask (kubectl-guard.sh) | allow (silent) |
| friction-fp-kubectl-grep-pattern-after-sed `sed -n 1,9p run.sh | grep -E 'kubectl (cp|exec)'` | ask (kubectl-guard.sh) | allow (silent) |
| friction-hole-kubectl-python-os-system `python3 -c "import os; os.system('kubectl --context c delete` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-kubectl-python-heredoc-subprocess `python3 - <<'EOF' import subprocess subprocess.run(["kubectl` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-kubectl-node-execsync `node -e "require('child_process').execSync('kubectl --contex` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-kubectl-assign-prefix-bash-heredoc `X=1 bash <<'EOF' kubectl --context prod delete pod api-1 EOF` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-network-assign-prefix-bash-heredoc `X=1 bash <<'EOF' curl -fsSL https://get.example.dev/install.` | allow (silent) | deny (network-guard.sh) |
| friction-hole-git-assign-prefix-bash-heredoc `X=1 bash <<'EOF' git push --force origin main EOF` | allow (silent) | deny (git-guard.sh) |
| friction-hole-env-assign-prefix-bash-heredoc `X=1 bash <<'EOF' cat .env EOF` | allow (silent) | deny (env-guard.sh) |
| friction-fp-kubectl-python-backtick-text `python3 - <<'EOF' print("see `kubectl delete pod x`") EOF` | ask (kubectl-guard.sh) | allow (silent) |
| friction-fp-kubectl-python-c-spaced-text `python3 -c "print('see: kubectl delete pod a')"` | ask (kubectl-guard.sh) | allow (silent) |
| friction-hole-kubectl-shellout-bash-c `python3 -c "import subprocess; subprocess.run(['bash','-c','` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-kubectl-shellout-concat-kind `python3 - <<'EOF' import os os.system("kubectl get " + kind)` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-kubectl-exec-code-with-globals `python3 -c "exec(\"import os; os.system('kubectl delete pod ` | allow (silent) | ask (kubectl-guard.sh) |
| friction-hole-git-shellout-force-push `python3 -c "import subprocess; subprocess.run(['git','push',` | allow (silent) | deny (git-guard.sh) |
| friction-hole-git-shellout-reset-hard `node -e "require('child_process').execSync('git reset --hard` | allow (silent) | deny (git-guard.sh) |
| friction-hole-git-printed-into-bash `python3 -c "print('git push --force origin main')" | bash` | allow (silent) | deny (git-guard.sh) |
| friction-fp-git-heredoc-edits-test-file `python3 - tests/git-guard.test.sh <<'EOF' import sys p = sys` | deny (git-guard.sh) | allow (silent) |
| friction-hole-rm-shellout-home `python3 -c "import os; os.system('rm -rf /opt/project/build'` | allow (silent) | deny (rm-guard.sh) |
| friction-hole-rm-shellout-list-root `python3 - <<'EOF' import subprocess subprocess.run(['rm','-r` | allow (silent) | deny (rm-guard.sh) |
| friction-fp-rm-heredoc-edits-notes `python3 - <<'EOF' p = 'notes.md' s = open(p).read() + '- `rm` | deny (rm-guard.sh) | allow (silent) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.1.1 (2026-10-23)

Merged since v1.1.0: 1 PR.

### Compatibility
- contract: review Claude Code releases up to 2.1.308 (#125)

### Benchmark vs v1.1.0

hooks/ and config/settings.json are unchanged since v1.1.0; benchmark skipped (both sides would run the same files).

## v1.1.0 (2026-10-21)

Merged since v1.0.8: 7 PRs.

### Security
- git-guard: a plain git branch -d runs (#120)
- mod-gate: ask for a mod that hooks settings.read or agent.spawn (#119)

### Compatibility
- contract: review Claude Code releases up to 2.1.306 (#116)

### Other
- comms-hub: ready for a fork or a fresh setup (#123)
- Clear the four open #72 false denies and A11b message text (#122)
- settings: retire the Bash(python:*) and Bash(node:*) allow rules (#121)
- comms-hub: one session speaks on Slack for all of them (#118)

### Benchmark vs v1.0.8


2026-10-21T22:34:37Z, Linux 7.0.0-1017-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 443 payloads (328 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.6 ms, `jq -n 1` 2.6 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 328 | 61.1 → 61.0 ms (-0%) | 61.1 → 62.0 ms (+2%) | 108.9 → 110.0 ms (+1%) | 185.7 → 187.2 ms (+1%) |
| WebFetch | 11 | 20.2 → 20.2 ms (+0%) | 26.1 → 26.1 ms (+0%) | 42.5 → 42.5 ms (-0%) | 30.9 → 30.9 ms (-0%) |
| Read/Grep | 41 | 53.7 → 53.6 ms (-0%) | 56.3 → 56.4 ms (+0%) | 85.1 → 85.9 ms (+1%) | 61.5 → 61.7 ms (+0%) |
| Write/Edit | 63 | 53.3 → 53.1 ms (-0%) | 53.9 → 53.8 ms (-0%) | 81.6 → 81.2 ms (-0%) | 115.6 → 115.5 ms (-0%) |
| All | 443 | 54.7 → 55.1 ms (+1%) | 58.7 → 59.4 ms (+1%) | 107.3 → 108.6 ms (+1%) | 160.4 → 161.5 ms (+1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 391 | 12.6 → 12.7 ms (+1%) | 34.4 → 34.4 ms (-0%) | 13.4 → 13.4 ms (+0%) |
| env-guard.sh | 328 | 15.5 → 15.6 ms (+0%) | 97.7 → 99.3 ms (+2%) | 37.3 → 37.4 ms (+0%) |
| git-guard.sh | 328 | 14.9 → 14.9 ms (+0%) | 94.1 → 95.5 ms (+1%) | 31.3 → 31.9 ms (+2%) |
| interpreter-guard.sh | 328 | 14.9 → 15.0 ms (+1%) | 86.7 → 90.6 ms (+4%) | 31.2 → 31.6 ms (+1%) |
| kubectl-guard.sh | 328 | 14.6 → 14.7 ms (+0%) | 58.0 → 58.4 ms (+1%) | 24.3 → 24.5 ms (+1%) |
| mod-gate.sh | 63 | 3.3 → 3.2 ms (-1%) | 13.5 → 13.4 ms (-1%) | 3.7 → 3.7 ms (-0%) |
| network-guard.sh | 339 | 19.0 → 19.1 ms (+1%) | 88.3 → 88.1 ms (-0%) | 33.8 → 33.8 ms (+0%) |
| rm-guard.sh | 328 | 12.8 → 12.8 ms (+1%) | 14.0 → 13.9 ms (-1%) | 16.4 → 16.5 ms (+1%) |
| secret-scanner.sh | 63 | 25.9 → 25.8 ms (-0%) | 81.6 → 81.2 ms (-0%) | 32.2 → 32.2 ms (+0%) |
| sensitive-file-guard.sh | 104 | 53.3 → 53.1 ms (-0%) | 65.9 → 67.2 ms (+2%) | 58.2 → 58.2 ms (+0%) |

Decisions: 435 of 443 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-env-jq-string-starts-with-env `jq -c 'select(.guard=="env-guard")' docs/permission-friction` | deny (env-guard.sh) | allow (silent) |
| friction-env-reader-procsub-filter-path `diff a.json <(jq '{denyRead: ["~/.ssh"]}' b.json)` | deny (env-guard.sh) | allow (silent) |
| friction-env-jq-in-quoted-cmdsub `echo "n: $(jq '[.[] | select(.key != "a") | .v] | length' s.` | deny (env-guard.sh) | allow (silent) |
| friction-interp-jinja-env-attribute `python3 - <<'EOF' templates.env.filters['markdown'] = render` | ask (interpreter-guard.sh) | allow (silent) |
| friction-git-commit-message-cmdsub-heredoc `git commit -m "$(cat <<'EOF' guard: message text  git push -` | deny (git-guard.sh) | allow (silent) |
| friction-git-commit-message-semicolon-dq `git commit -m "guard: note; git push --force stays denied"` | deny (git-guard.sh) | allow (silent) |
| friction-git-commit-message-semicolon-sq `git commit -m 'guard: note; git push --force stays denied'` | deny (git-guard.sh) | allow (silent) |
| friction-gh-pr-body-semicolon `gh pr create --title "guard: messages are text" --body 'stil` | deny (git-guard.sh) | allow (silent) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.0.8 (2026-10-21)

Merged since v1.0.7: 1 PR.

### Compatibility
- contract: review Claude Code releases up to 2.1.304 (#115)

### Benchmark vs v1.0.7

hooks/ and config/settings.json are unchanged since v1.0.7; benchmark skipped (both sides would run the same files).

## v1.0.7 (2026-10-19)

Merged since v1.0.6: 1 PR.

### Security
- env-guard: a sed or awk script, and a pattern after xargs, is text (#113)

### Benchmark vs v1.0.6


2026-10-19T23:09:30Z, Linux 7.0.0-1017-azure x86_64, AMD EPYC 9V45 96-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 436 payloads (321 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.0 ms, `jq -n 1` 1.7 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 321 | 42.3 → 42.5 ms (+0%) | 43.0 → 43.4 ms (+1%) | 76.4 → 77.8 ms (+2%) | 130.4 → 131.4 ms (+1%) |
| WebFetch | 11 | 13.3 → 13.4 ms (+1%) | 17.1 → 17.0 ms (-0%) | 27.6 → 27.4 ms (-1%) | 20.4 → 20.3 ms (-0%) |
| Read/Grep | 41 | 36.6 → 36.5 ms (-0%) | 39.5 → 39.1 ms (-1%) | 59.9 → 59.5 ms (-1%) | 43.3 → 42.8 ms (-1%) |
| Write/Edit | 63 | 36.1 → 36.1 ms (-0%) | 36.9 → 36.9 ms (-0%) | 58.4 → 58.2 ms (-0%) | 79.1 → 79.0 ms (-0%) |
| All | 436 | 37.3 → 37.5 ms (+1%) | 41.1 → 41.4 ms (+1%) | 75.7 → 76.5 ms (+1%) | 112.0 → 112.7 ms (+1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 384 | 8.7 → 8.7 ms (+0%) | 23.8 → 23.6 ms (-1%) | 9.3 → 9.3 ms (+0%) |
| env-guard.sh | 321 | 11.0 → 11.0 ms (+0%) | 63.9 → 68.2 ms (+7%) | 25.6 → 26.4 ms (+3%) |
| git-guard.sh | 321 | 10.4 → 10.5 ms (+1%) | 59.9 → 56.6 ms (-6%) | 21.3 → 21.4 ms (+0%) |
| interpreter-guard.sh | 321 | 10.6 → 10.6 ms (+1%) | 63.1 → 62.5 ms (-1%) | 22.2 → 22.2 ms (-0%) |
| kubectl-guard.sh | 321 | 10.4 → 10.4 ms (+0%) | 41.9 → 41.0 ms (-2%) | 17.4 → 17.4 ms (+0%) |
| mod-gate.sh | 63 | 2.3 → 2.3 ms (-1%) | 9.0 → 9.0 ms (-0%) | 2.6 → 2.6 ms (-0%) |
| network-guard.sh | 332 | 13.5 → 13.5 ms (-0%) | 64.2 → 65.3 ms (+2%) | 24.3 → 24.4 ms (+0%) |
| rm-guard.sh | 321 | 8.9 → 8.9 ms (+0%) | 9.8 → 9.8 ms (-0%) | 11.5 → 11.6 ms (+1%) |
| secret-scanner.sh | 63 | 17.4 → 17.4 ms (-0%) | 58.4 → 58.2 ms (-0%) | 22.1 → 22.0 ms (-0%) |
| sensitive-file-guard.sh | 104 | 36.3 → 36.2 ms (-0%) | 49.9 → 45.8 ms (-8%) | 40.2 → 40.0 ms (-0%) |

Decisions: 436 of 436 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.0.6 (2026-10-19)

Merged since v1.0.5: 4 PRs.

### Security
- docs: isolatePeerMachines asks whenever the target is not shown to be local (#109)
- network-guard: claude.com and all its hosts are on the default list (#108)
- kubectl-guard: kubectl, its verb or its kind through a variable, a substitution, xargs or a glued & (#107)

### Compatibility
- contract: record Claude Code 2.1.303 (no harness-relevant entries) (#111)

### Benchmark vs v1.0.5


2026-10-19T13:40:16Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 436 payloads (321 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 321 | 50.7 → 51.5 ms (+2%) | 51.8 → 51.9 ms (+0%) | 92.3 → 92.3 ms (-0%) | 158.2 → 158.2 ms (-0%) |
| WebFetch | 11 | 17.3 → 17.0 ms (-1%) | 22.0 → 21.9 ms (-1%) | 35.1 → 34.9 ms (-0%) | 26.0 → 25.9 ms (-0%) |
| Read/Grep | 41 | 46.0 → 46.2 ms (+0%) | 48.7 → 48.6 ms (-0%) | 72.0 → 70.0 ms (-3%) | 53.1 → 52.9 ms (-0%) |
| Write/Edit | 63 | 46.0 → 45.9 ms (-0%) | 46.6 → 46.6 ms (+0%) | 71.7 → 71.5 ms (-0%) | 99.2 → 99.5 ms (+0%) |
| All | 436 | 46.5 → 46.4 ms (-0%) | 50.0 → 50.0 ms (+0%) | 91.4 → 91.3 ms (-0%) | 136.5 → 136.4 ms (-0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 384 | 10.7 → 10.7 ms (-0%) | 29.5 → 29.6 ms (+0%) | 11.5 → 11.5 ms (+0%) |
| env-guard.sh | 321 | 13.2 → 13.1 ms (-0%) | 80.1 → 80.6 ms (+1%) | 31.6 → 31.6 ms (-0%) |
| git-guard.sh | 321 | 12.6 → 12.6 ms (-0%) | 68.5 → 68.9 ms (+1%) | 25.6 → 25.6 ms (-0%) |
| interpreter-guard.sh | 321 | 12.7 → 12.6 ms (-0%) | 76.1 → 75.8 ms (-0%) | 26.7 → 26.6 ms (-0%) |
| kubectl-guard.sh | 321 | 12.5 → 12.5 ms (-0%) | 49.7 → 48.9 ms (-2%) | 21.0 → 21.0 ms (-0%) |
| mod-gate.sh | 63 | 2.7 → 2.7 ms (+0%) | 11.4 → 11.4 ms (-0%) | 3.2 → 3.2 ms (+0%) |
| network-guard.sh | 332 | 16.4 → 16.4 ms (+0%) | 76.6 → 76.3 ms (-0%) | 29.3 → 29.3 ms (-0%) |
| rm-guard.sh | 321 | 11.0 → 10.9 ms (-0%) | 11.4 → 11.3 ms (-0%) | 14.1 → 14.1 ms (+0%) |
| secret-scanner.sh | 63 | 22.2 → 22.2 ms (+0%) | 71.7 → 71.5 ms (-0%) | 27.8 → 27.9 ms (+0%) |
| sensitive-file-guard.sh | 104 | 45.9 → 45.9 ms (-0%) | 56.1 → 55.7 ms (-1%) | 50.1 → 50.1 ms (+0%) |

Decisions: 436 of 436 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.0.5 (2026-10-18)

Merged since v1.0.4: 1 PR.

### Security
- git-guard reads identity without asking; permission-friction counts approved prompts (#106)

### Benchmark vs v1.0.4


2026-10-18T11:19:06Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 436 payloads (321 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 321 | 51.6 → 51.6 ms (+0%) | 52.8 → 52.9 ms (+0%) | 93.2 → 94.0 ms (+1%) | 161.1 → 161.3 ms (+0%) |
| WebFetch | 11 | 17.1 → 17.2 ms (+0%) | 22.1 → 22.0 ms (-0%) | 35.1 → 35.3 ms (+0%) | 26.1 → 26.1 ms (-0%) |
| Read/Grep | 41 | 46.8 → 46.9 ms (+0%) | 49.1 → 49.1 ms (-0%) | 75.9 → 74.5 ms (-2%) | 53.4 → 53.4 ms (-0%) |
| Write/Edit | 63 | 46.2 → 46.3 ms (+0%) | 46.7 → 46.8 ms (+0%) | 72.4 → 72.4 ms (+0%) | 99.6 → 99.6 ms (+0%) |
| All | 436 | 46.8 → 46.9 ms (+0%) | 50.8 → 50.8 ms (+0%) | 92.5 → 93.2 ms (+1%) | 138.6 → 138.8 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 384 | 10.9 → 10.9 ms (+0%) | 29.7 → 29.6 ms (-0%) | 11.7 → 11.6 ms (-0%) |
| env-guard.sh | 321 | 13.4 → 13.4 ms (-0%) | 81.8 → 82.1 ms (+0%) | 32.2 → 32.3 ms (+0%) |
| git-guard.sh | 321 | 12.8 → 12.8 ms (-0%) | 69.8 → 69.6 ms (-0%) | 26.0 → 26.0 ms (-0%) |
| interpreter-guard.sh | 321 | 12.9 → 12.9 ms (-0%) | 76.7 → 77.0 ms (+0%) | 27.1 → 27.1 ms (+0%) |
| kubectl-guard.sh | 321 | 12.8 → 12.8 ms (+0%) | 50.9 → 50.8 ms (-0%) | 21.5 → 21.5 ms (+0%) |
| mod-gate.sh | 63 | 2.7 → 2.7 ms (+0%) | 11.5 → 11.5 ms (+0%) | 3.2 → 3.2 ms (+0%) |
| network-guard.sh | 332 | 16.7 → 16.7 ms (+0%) | 77.9 → 78.3 ms (+1%) | 29.7 → 29.9 ms (+1%) |
| rm-guard.sh | 321 | 11.1 → 11.1 ms (+0%) | 11.7 → 11.6 ms (-1%) | 14.4 → 14.4 ms (-0%) |
| secret-scanner.sh | 63 | 22.3 → 22.3 ms (-0%) | 72.4 → 72.4 ms (+0%) | 27.9 → 27.9 ms (-0%) |
| sensitive-file-guard.sh | 104 | 46.2 → 46.3 ms (+0%) | 57.0 → 56.1 ms (-2%) | 50.3 → 50.3 ms (+0%) |

Decisions: 436 of 436 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.0.4 (2026-10-18)

Merged since v1.0.3: 1 PR.

### Compatibility
- contract: review Claude Code releases up to 2.1.302 (#93)

### Benchmark vs v1.0.3

hooks/ and config/settings.json are unchanged since v1.0.3; benchmark skipped (both sides would run the same files).

## v1.0.3 (2026-10-18)

Merged since v1.0.2: 2 PRs.

### Security
- kubectl-guard: a grep pattern or path naming kubectl is text, beside any command (#102)

### Speed
- tests: hook-bench's max-vs-sum case uses hooks of clearly different speed (#103)

### Benchmark vs v1.0.2


2026-10-18T02:27:34Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 436 payloads (321 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.5 ms, `jq -n 1` 2.5 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 321 | 51.5 → 55.1 ms (+7%) | 54.5 → 54.8 ms (+0%) | 95.9 → 96.1 ms (+0%) | 166.7 → 167.2 ms (+0%) |
| WebFetch | 11 | 18.1 → 18.0 ms (-1%) | 23.0 → 23.1 ms (+0%) | 37.0 → 37.4 ms (+1%) | 27.2 → 27.4 ms (+0%) |
| Read/Grep | 41 | 49.4 → 49.4 ms (+0%) | 51.8 → 51.6 ms (-0%) | 78.3 → 77.0 ms (-2%) | 56.3 → 56.1 ms (-0%) |
| Write/Edit | 63 | 49.6 → 49.5 ms (-0%) | 49.8 → 49.8 ms (-0%) | 73.9 → 73.6 ms (-0%) | 105.4 → 105.4 ms (-0%) |
| All | 436 | 49.8 → 50.0 ms (+0%) | 52.8 → 53.0 ms (+0%) | 95.1 → 95.5 ms (+0%) | 144.0 → 144.3 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 384 | 11.4 → 11.4 ms (+0%) | 30.9 → 30.9 ms (+0%) | 12.1 → 12.1 ms (+0%) |
| env-guard.sh | 321 | 14.2 → 14.2 ms (-0%) | 84.2 → 86.8 ms (+3%) | 33.4 → 33.4 ms (+0%) |
| git-guard.sh | 321 | 13.5 → 13.5 ms (+0%) | 81.1 → 73.5 ms (-9%) | 27.0 → 27.1 ms (+0%) |
| interpreter-guard.sh | 321 | 13.6 → 13.6 ms (+0%) | 79.2 → 79.3 ms (+0%) | 28.1 → 28.1 ms (+0%) |
| kubectl-guard.sh | 321 | 13.4 → 13.4 ms (+0%) | 50.0 → 51.9 ms (+4%) | 21.9 → 22.3 ms (+2%) |
| mod-gate.sh | 63 | 3.0 → 3.0 ms (-0%) | 12.3 → 12.0 ms (-3%) | 3.4 → 3.4 ms (-0%) |
| network-guard.sh | 332 | 17.4 → 17.4 ms (+0%) | 79.6 → 78.8 ms (-1%) | 30.9 → 30.8 ms (-0%) |
| rm-guard.sh | 321 | 11.7 → 11.6 ms (-0%) | 12.5 → 12.5 ms (-0%) | 15.0 → 15.0 ms (-0%) |
| secret-scanner.sh | 63 | 23.6 → 23.5 ms (-0%) | 73.9 → 73.6 ms (-0%) | 29.3 → 29.2 ms (-0%) |
| sensitive-file-guard.sh | 104 | 49.4 → 49.3 ms (-0%) | 59.3 → 60.2 ms (+1%) | 53.4 → 53.3 ms (-0%) |

Decisions: 436 of 436 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.0.2 (2026-10-17)

Merged since v1.0.1: 1 PR.

### Compatibility
- ci: approve the held CI run on PRs the Actions bot opens (#100)

### Benchmark vs v1.0.1

hooks/ and config/settings.json are unchanged since v1.0.1; benchmark skipped (both sides would run the same files).

## v1.0.1 (2026-10-17)

Merged since v1.0.0: 9 PRs.

### Security
- guards: exit early on commands they do not name; a message is text; broad git add checks what it would stage (#90)

### Compatibility
- rules: cut lines Claude Code or the hooks already cover (#95)

### Memory
- hooks: retire workflow-record; keep memory-lint and comment-budget sync (#98)
- memory: defer to the CLI's own hygiene, gate the session-start reorder, cut the skills (#88)

### Other
- harness-update: update from its own clone, not the one install.sh ran from (#97)
- session-start: on clear, leave branch and commits to the CLI's fresh copy (#96)
- harness-update: a machine installed past the newest tag is up to date (#94)
- settings: ship effort high; move installed xhigh to high once (#92)
- docs: short README, details moved to docs/ (#91)

### Benchmark vs v1.0.0


2026-10-17T20:21:27Z, Linux 6.17.0-1022-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.12.3. Corpus tests/bench-corpus.jsonl: 436 payloads (321 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, run one at a time. Wait is the slowest hook of a call (Claude Code runs them in parallel); CPU is the sum. Process start here: `bash -c :` 1.5 ms, `jq -n 1` 2.6 ms (p50 of 20), so only same-run comparisons are meaningful.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 321 | 75.6 → 52.5 ms (-30%) | 79.1 → 56.0 ms (-29%) | 96.5 → 99.4 ms (+3%) | 274.9 → 171.6 ms (-38%) |
| WebFetch | 11 | 18.9 → 19.3 ms (+2%) | 24.4 → 24.6 ms (+1%) | 39.2 → 39.9 ms (+2%) | 28.7 → 29.0 ms (+1%) |
| Read/Grep | 41 | 52.1 → 52.3 ms (+0%) | 54.3 → 54.5 ms (+0%) | 79.3 → 79.7 ms (+0%) | 59.0 → 59.2 ms (+0%) |
| Write/Edit | 63 | 51.7 → 51.7 ms (-0%) | 51.9 → 52.0 ms (+0%) | 78.4 → 76.0 ms (-3%) | 109.6 → 110.2 ms (+0%) |
| All | 436 | 73.7 → 51.9 ms (-30%) | 71.5 → 54.5 ms (-24%) | 95.6 → 98.5 ms (+3%) | 224.5 → 148.6 ms (-34%) |

| Hook | runs | wall p50 | wall p95 | CPU mean |
|---|---:|---|---|---|
| config-guard.sh | 384 | 11.7 → 11.9 ms (+1%) | 32.1 → 32.3 ms (+1%) | 12.4 → 12.6 ms (+1%) |
| env-guard.sh | 321 | 74.5 → 14.6 ms (-80%) | 90.2 → 87.7 ms (-3%) | 88.0 → 34.4 ms (-61%) |
| git-guard.sh | 321 | 13.8 → 14.0 ms (+1%) | 84.5 → 74.8 ms (-11%) | 28.0 → 27.9 ms (-1%) |
| interpreter-guard.sh | 321 | 31.9 → 14.1 ms (-56%) | 82.9 → 80.9 ms (-2%) | 42.1 → 28.8 ms (-32%) |
| kubectl-guard.sh | 321 | 28.9 → 13.8 ms (-52%) | 49.7 → 51.5 ms (+4%) | 40.3 → 22.5 ms (-44%) |
| mod-gate.sh | 63 | 3.1 → 3.1 ms (+0%) | 12.6 → 12.8 ms (+2%) | 3.6 → 3.6 ms (+0%) |
| network-guard.sh | 332 | 37.8 → 18.0 ms (-52%) | 81.2 → 84.2 ms (+4%) | 49.9 → 31.8 ms (-36%) |
| rm-guard.sh | 321 | 12.1 → 12.1 ms (+0%) | 13.0 → 12.7 ms (-2%) | 15.3 → 15.4 ms (+1%) |
| secret-scanner.sh | 63 | 24.7 → 24.8 ms (+0%) | 78.4 → 76.0 ms (-3%) | 30.4 → 30.5 ms (+0%) |
| sensitive-file-guard.sh | 104 | 51.8 → 51.8 ms (+0%) | 63.2 → 63.4 ms (+0%) | 55.7 → 55.9 ms (+0%) |

Decisions: 432 of 436 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-interp-heredoc-subprocess `python3 - <<'EOF' import subprocess, json out = subprocess.r` | ask (interpreter-guard.sh) | allow (silent) |
| friction-subprocess-list-kubectl-view `python3 -c "import subprocess; subprocess.run(['kubectl','de` | ask (interpreter-guard.sh) | allow (silent) |
| friction-subprocess-list-git-view `python3 -c "import subprocess; subprocess.run(['git','push',` | ask (interpreter-guard.sh) | allow (silent) |
| friction-git-commit-message-heredoc `git commit -F - <<'EOF' guard tweaks  git add . is still den` | deny (git-guard.sh) | allow (silent) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.0.0 (2026-10-16)

The harness as it stands at PR #89: machine-level hooks, settings,
rules and skills for Claude Code, installed once per machine with
`bash install.sh`.

### Security

- Seven Bash guards run on every command: env-guard (secrets and dotfiles
  read, dumped or sent), git-guard (force pushes, hard resets, staging
  everything, hooks and config, worktree and stash removal), interpreter-guard
  (inline code that reaches env, sockets or subprocesses asks; long inline
  scripts ask), kubectl-guard (writes and secret reads ask, deletes are
  denied), network-guard (GETs to a built-in and a per-machine allowlist run;
  other hosts, request bodies and deletes ask; file uploads and
  `curl | sh` are denied), rm-guard (`rm -rf` runs only in the session's
  scratch folders) and config-guard (writes to the installed harness, settings
  files, shell startup files and launch agents ask; moving `~/.claude` is
  denied).
- File guards on Read, Edit, Write and Grep: sensitive-file-guard (`.env`,
  keys, credential folders, a search at or above `$HOME`), secret-scanner
  (high-confidence token shapes in written content) and mod-gate (a mod
  that overrides permission decisions is denied; others are shown).
- Guards parse commands the way the shell does: wrappers and assignments,
  groups and reserved words, `"$@"` functions, quoted separators, heredocs
  that only write prose, and binaries however they are spelled. Every deny
  and ask is written to the audit log with its reason.
- A guard that crashes, times out or cannot parse its input blocks the call
  (`onFailure: block`, fail-closed without jq).
- `permissions.deny` for the shapes a guard cannot see; eleven rules that
  could never match were retired and are removed on install.

### Speed

- One sed pass per guard instead of five; early exits before jq on commands
  that cannot match; `tests/guard-latency.test.sh` caps each guard at 10 s on
  a 12 KB command (bash 3.2's `${var//…}` once took 30 s).
- Measured friction: `bin/permission-friction.py` reads local transcripts,
  and `docs/permission-friction-cases.jsonl` (180 cases) pins what a fix must
  keep and what it must clear; doctor fails on a miss.

### Compatibility

- `config/upstream-contract.json` records the Claude Code release the harness
  was verified against; `bin/upstream-check.sh` asks the installed CLI which
  hook events and modes it accepts and lists unreviewed changelog entries.
  The daily Upstream drift workflow lands a contract review that needs no
  decision and drafts a PR for one that does. The Release workflow tags main
  after it, and `bin/harness-update.sh` installs each tag on a schedule.
  session-start says when the CLI is ahead of or behind the contract.
- install.sh merges into an existing settings.json (user keys and allow rules
  kept, hooks and deny owned by the harness), folds in machine-local rules
  from `~/.claude/local-settings/*.json`, keeps `local-*.md` rules, and runs
  doctor after installing. The sandbox has a per-machine switch and a trial.

### Memory

- memory-lint on every write, memory-index at session start (tier order,
  size caps), memory-verify and memory-fix against GitHub and Jira,
  memory-provenance for who wrote a memory and when; the memory-audit and
  memory-archive skills drive them.

### Other

- Audit log for every tool call, MCP call, agent spawn, peer message,
  artifact action, model switch and config change; session snapshots and
  resume-drift detection; plan-to-html; notifications; a status line with
  live effort, fast mode and context use; comment-budget on edits.
- Rules installed to `~/.claude/rules` (prose, collaboration, working
  agreement, environment) and a pr-review skill.
- Tests: one suite per hook and script under `tests/`, run by `doctor.sh`; CI runs them on Linux
  and macOS, lints every script with shellcheck, and benchmarks every PR's
  hooks against main.
