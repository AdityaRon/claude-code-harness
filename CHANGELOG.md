# Changelog

Releases are tagged `vMAJOR.MINOR.PATCH`. The release workflow
(`.github/workflows/release.yml`) writes each entry from the PRs merged since
the previous tag and the hook benchmark against it (`bin/hook-bench.py`); the
GitHub Release carries the same text. `bin/harness-update.sh` moves an
installed machine to the newest tag. After v1.4.2 the skills live in
[claude-code-skills](https://github.com/AdityaRon/claude-code-skills), with their
own changelog; `config/skills.pin` names the release each version installs.

## v1.4.18 (2026-11-20)

Merged since v1.4.17: 10 PRs.

### Security
- readme: claim, table, install, guards, limits, evidence; the reference moves to docs (#313)
- bash-guards: a 45 s deadline per guard, and a 60 s timeout behind it (#306)

### Speed
- hook-bench: an upper estimate for the timed phase after warm-up (#317)

### Memory
- memory-lint: defer two in-between findings to a Stop check (#311)

### Other
- harness-checkup: the three largest costs on this machine, offline (#316)
- docs: n beside each measured number in two findings docs (#314)
- docs: session crons on resume, timeout wording; SessionEnd timeout (#312)
- readme: the numbers in one data file, a generator and a test (#310)
- tests: a shared transcript generator, and a canary no report may print (#309)
- spend-report: say why each rewrite happened, and sum its tokens (#308)

### Benchmark vs v1.4.17

Gate script and corpus from `d0e4870` (v1.4.17): 515 payloads, 0 of them new in this change.



2026-11-20T11:40:40Z, Linux 7.0.0-1020-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.TCbZCS/corpus.jsonl: 515 payloads (395 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.7 ms, `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 395 | 75.1 → 77.1 ms (+3%) | 75.8 → 76.8 ms (+1%) | 142.8 → 145.5 ms (+2%) | 150.9 → 153.1 ms (+2%) |
| WebFetch | 11 | 7.0 → 7.1 ms (+2%) | 7.1 → 7.2 ms (+1%) | 7.6 → 7.6 ms (+0%) | 6.8 → 6.9 ms (+1%) |
| Read/Grep | 41 | 49.4 → 48.9 ms (-1%) | 55.1 → 55.3 ms (+0%) | 76.8 → 74.5 ms (-3%) | 68.5 → 68.7 ms (+0%) |
| Write/Edit | 63 | 60.3 → 60.4 ms (+0%) | 64.0 → 64.1 ms (+0%) | 90.3 → 92.0 ms (+2%) | 150.7 → 150.7 ms (+0%) |
| Monitor | 5 | 41.0 → 40.6 ms (-1%) | 56.3 → 57.1 ms (+2%) | 111.4 → 112.4 ms (+1%) | 108.1 → 110.8 ms (+2%) |
| All | 515 | 65.2 → 65.5 ms (+1%) | 71.1 → 71.9 ms (+1%) | 139.4 → 140.3 ms (+1%) | 140.8 → 142.6 ms (+1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 400 | 74.8 → 76.0 ms (+2%) | 143.5 → 144.0 ms (+0%) | 140.9 → 143.0 ms (+2%) | 73.4 → 74.6 ms |
| config-guard.sh | 63 | 19.0 → 18.9 ms (-0%) | 43.9 → 44.1 ms (+0%) | 27.2 → 27.1 ms (-0%) | 17.6 → 17.5 ms |
| mod-gate.sh | 63 | 1.8 → 1.8 ms (-1%) | 14.3 → 14.5 ms (+1%) | 2.5 → 2.5 ms (+0%) | 0.5 → 0.4 ms |
| secret-scanner.sh | 63 | 25.5 → 25.5 ms (+0%) | 79.9 → 79.3 ms (-1%) | 31.9 → 32.0 ms (+0%) | 24.1 → 24.1 ms |
| sensitive-file-guard.sh | 104 | 48.6 → 48.7 ms (+0%) | 71.4 → 73.8 ms (+3%) | 55.6 → 55.7 ms (+0%) | 47.3 → 47.3 ms |
| subagent-cache-guard.sh | 515 | 7.3 → 7.3 ms (-0%) | 7.8 → 7.8 ms (+0%) | 7.1 → 7.1 ms (+0%) | 5.9 → 5.9 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 400 | 21.98 → 21.98 | 98.66 → 98.66 | 48259 → 48259 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 515 | 1.00 → 1.00 | 1.00 → 1.00 | 1030 → 1030 | 0 / 0 | 0 |

Decisions: 515 of 515 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

This change edits tools/hook-bench.py, so the gate ran again with its copy (exit 0):


2026-11-20T11:46:07Z, Linux 7.0.0-1020-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.TCbZCS/corpus.jsonl: 515 payloads (395 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.7 ms, `bash -c :` 1.4 ms, `jq -n 1` 2.4 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 395 | 76.3 → 76.6 ms (+0%) | 75.4 → 76.3 ms (+1%) | 139.5 → 140.0 ms (+0%) | 149.7 → 152.0 ms (+2%) |
| WebFetch | 11 | 7.0 → 7.0 ms (+1%) | 7.2 → 7.1 ms (-1%) | 8.1 → 7.4 ms (-8%) | 7.0 → 6.9 ms (-1%) |
| Read/Grep | 41 | 48.8 → 49.0 ms (+0%) | 54.6 → 54.4 ms (-0%) | 74.5 → 74.2 ms (-0%) | 67.9 → 67.6 ms (-1%) |
| Write/Edit | 63 | 59.6 → 59.9 ms (+1%) | 63.3 → 63.6 ms (+0%) | 92.7 → 92.1 ms (-1%) | 150.2 → 149.9 ms (-0%) |
| Monitor | 5 | 40.6 → 41.1 ms (+1%) | 57.1 → 56.7 ms (-1%) | 112.1 → 110.2 ms (-2%) | 108.5 → 109.5 ms (+1%) |
| All | 515 | 63.9 → 64.4 ms (+1%) | 70.6 → 71.3 ms (+1%) | 137.1 → 137.4 ms (+0%) | 139.8 → 141.5 ms (+1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 400 | 75.1 → 75.9 ms (+1%) | 137.5 → 137.4 ms (-0%) | 140.1 → 142.0 ms (+1%) | 73.7 → 74.5 ms |
| config-guard.sh | 63 | 18.8 → 18.9 ms (+1%) | 43.2 → 43.4 ms (+0%) | 27.0 → 26.9 ms (-0%) | 17.4 → 17.5 ms |
| mod-gate.sh | 63 | 1.8 → 1.8 ms (+1%) | 14.3 → 14.1 ms (-2%) | 2.5 → 2.5 ms (-1%) | 0.4 → 0.4 ms |
| secret-scanner.sh | 63 | 25.3 → 25.4 ms (+0%) | 79.1 → 81.4 ms (+3%) | 31.6 → 31.7 ms (+0%) | 23.9 → 24.0 ms |
| sensitive-file-guard.sh | 104 | 48.3 → 48.3 ms (+0%) | 70.4 → 70.3 ms (-0%) | 55.0 → 55.1 ms (+0%) | 46.9 → 46.9 ms |
| subagent-cache-guard.sh | 515 | 7.3 → 7.3 ms (+0%) | 7.8 → 7.7 ms (-0%) | 7.1 → 7.1 ms (-0%) | 5.9 → 5.9 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 400 | 21.98 → 21.98 | 98.66 → 98.66 | 48259 → 48259 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 515 | 1.00 → 1.00 | 1.00 → 1.00 | 1030 → 1030 | 0 / 0 | 0 |

Decisions: 515 of 515 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.17 (2026-11-20)

Merged since v1.4.16: 2 PRs.

### Speed
- hook-bench: name the phase a partial table stopped in (#305)

### Other
- shadow_note: clean the line in one awk, not ${c//…} (#304)

### Benchmark vs v1.4.16

Gate script and corpus from `4b8bb13` (v1.4.16): 515 payloads, 0 of them new in this change.



2026-11-20T01:35:35Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.qxJHgh/corpus.jsonl: 515 payloads (395 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.1 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 395 | 62.2 → 62.6 ms (+1%) | 61.5 → 61.6 ms (+0%) | 113.5 → 114.2 ms (+1%) | 120.9 → 120.9 ms (+0%) |
| WebFetch | 11 | 5.9 → 5.9 ms (-0%) | 5.9 → 5.9 ms (-0%) | 6.2 → 6.1 ms (-1%) | 5.8 → 5.8 ms (-0%) |
| Read/Grep | 41 | 41.2 → 41.5 ms (+1%) | 46.0 → 46.4 ms (+1%) | 63.9 → 63.4 ms (-1%) | 56.8 → 57.4 ms (+1%) |
| Write/Edit | 63 | 48.9 → 48.5 ms (-1%) | 51.7 → 51.6 ms (-0%) | 75.2 → 74.9 ms (-0%) | 120.4 → 120.2 ms (-0%) |
| Monitor | 5 | 35.3 → 34.8 ms (-1%) | 46.5 → 46.7 ms (+0%) | 90.5 → 92.0 ms (+2%) | 88.3 → 89.6 ms (+2%) |
| All | 515 | 53.0 → 52.8 ms (-0%) | 57.7 → 57.8 ms (+0%) | 111.6 → 112.2 ms (+1%) | 112.9 → 113.0 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 400 | 62.0 → 62.0 ms (+0%) | 113.5 → 112.2 ms (-1%) | 113.7 → 113.7 ms (-0%) | 60.8 → 60.8 ms |
| config-guard.sh | 63 | 15.9 → 15.8 ms (-0%) | 37.2 → 37.6 ms (+1%) | 22.8 → 22.8 ms (+0%) | 14.7 → 14.7 ms |
| mod-gate.sh | 63 | 1.5 → 1.5 ms (+1%) | 12.4 → 12.0 ms (-3%) | 2.1 → 2.1 ms (-0%) | 0.4 → 0.4 ms |
| secret-scanner.sh | 63 | 21.5 → 21.5 ms (-0%) | 65.8 → 65.7 ms (-0%) | 26.6 → 26.6 ms (+0%) | 20.4 → 20.3 ms |
| sensitive-file-guard.sh | 104 | 40.9 → 41.0 ms (+0%) | 61.2 → 60.7 ms (-1%) | 46.5 → 46.5 ms (-0%) | 39.8 → 39.9 ms |
| subagent-cache-guard.sh | 515 | 6.1 → 6.1 ms (+0%) | 6.5 → 6.5 ms (+0%) | 5.9 → 5.9 ms (+0%) | 5.0 → 5.0 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 400 | 21.98 → 21.98 | 98.66 → 98.66 | 48259 → 48259 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 515 | 1.00 → 1.00 | 1.00 → 1.00 | 1030 → 1030 | 0 / 0 | 0 |

Decisions: 515 of 515 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

This change edits tools/hook-bench.py, so the gate ran again with its copy (exit 0):


2026-11-20T01:39:58Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.qxJHgh/corpus.jsonl: 515 payloads (395 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.2 ms, `jq -n 1` 2.0 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 395 | 61.5 → 61.2 ms (-0%) | 61.1 → 61.0 ms (-0%) | 113.2 → 112.8 ms (-0%) | 120.1 → 120.0 ms (-0%) |
| WebFetch | 11 | 5.8 → 5.8 ms (-0%) | 5.9 → 5.8 ms (-1%) | 6.6 → 6.0 ms (-10%) | 5.8 → 5.7 ms (-1%) |
| Read/Grep | 41 | 42.0 → 41.3 ms (-1%) | 46.0 → 45.7 ms (-1%) | 61.9 → 62.4 ms (+1%) | 56.9 → 56.6 ms (-1%) |
| Write/Edit | 63 | 48.2 → 47.9 ms (-0%) | 51.0 → 50.9 ms (-0%) | 74.1 → 72.9 ms (-2%) | 118.4 → 118.8 ms (+0%) |
| Monitor | 5 | 33.6 → 33.3 ms (-1%) | 46.0 → 46.2 ms (+1%) | 90.4 → 91.3 ms (+1%) | 87.8 → 87.9 ms (+0%) |
| All | 515 | 51.5 → 52.1 ms (+1%) | 57.3 → 57.2 ms (-0%) | 110.8 → 110.9 ms (+0%) | 112.1 → 112.0 ms (-0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 400 | 60.8 → 61.1 ms (+1%) | 111.9 → 112.7 ms (+1%) | 112.8 → 112.8 ms (-0%) | 59.6 → 60.0 ms |
| config-guard.sh | 63 | 15.5 → 15.6 ms (+0%) | 36.7 → 36.8 ms (+0%) | 22.3 → 22.4 ms (+0%) | 14.3 → 14.4 ms |
| mod-gate.sh | 63 | 1.4 → 1.4 ms (+0%) | 11.7 → 11.6 ms (-1%) | 2.0 → 2.0 ms (+0%) | 0.3 → 0.3 ms |
| secret-scanner.sh | 63 | 21.1 → 21.1 ms (-0%) | 65.3 → 65.3 ms (-0%) | 26.1 → 26.3 ms (+1%) | 19.9 → 19.9 ms |
| sensitive-file-guard.sh | 104 | 40.1 → 40.3 ms (+0%) | 58.7 → 59.9 ms (+2%) | 45.9 → 45.9 ms (+0%) | 39.0 → 39.1 ms |
| subagent-cache-guard.sh | 515 | 6.0 → 6.0 ms (+0%) | 6.4 → 6.4 ms (-0%) | 5.9 → 5.9 ms (+0%) | 4.8 → 4.9 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 400 | 21.98 → 21.98 | 98.66 → 98.66 | 48259 → 48259 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 515 | 1.00 → 1.00 | 1.00 → 1.00 | 1030 → 1030 | 0 / 0 | 0 |

Decisions: 515 of 515 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.16 (2026-11-20)

Merged since v1.4.15: 4 PRs.

### Security
- git-guard: one grep of every check's pattern; interpreter-guard: one for three (#299)

### Speed
- bench: nine costly command shapes, and a process budget per guard (#297)

### Other
- inert_split: one awk splits segments; shell-outs: a builtin reads the answer (#302)
- docs: keeping sessions alive for days (long-running-sessions.md) (#300)

### Benchmark vs v1.4.15

Gate script and corpus from `fe092af` (v1.4.15): 515 payloads, 9 of them new in this change: shape-cd-chain, shape-pipes, shape-python-heredoc, shape-notes-then-git, shape-commit-heredoc, shape-commit-pr-heredoc, mult-joined-pass, mult-inline-shellouts, mult-git-add-all.



2026-11-20T00:12:45Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.AWYh2p/corpus.jsonl: 515 payloads (395 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.2 ms, `jq -n 1` 2.0 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 395 | 63.3 → 61.8 ms (-2%) | 63.7 → 61.1 ms (-4%) | 118.4 → 113.0 ms (-5%) | 125.0 → 120.1 ms (-4%) |
| WebFetch | 11 | 5.8 → 5.8 ms (+0%) | 5.8 → 5.9 ms (+0%) | 6.0 → 6.0 ms (-0%) | 5.7 → 5.7 ms (+0%) |
| Read/Grep | 41 | 40.8 → 40.9 ms (+0%) | 45.5 → 45.4 ms (-0%) | 62.7 → 62.0 ms (-1%) | 56.3 → 56.1 ms (-0%) |
| Write/Edit | 63 | 47.7 → 48.3 ms (+1%) | 50.8 → 51.2 ms (+1%) | 74.0 → 75.4 ms (+2%) | 118.8 → 119.0 ms (+0%) |
| Monitor | 5 | 33.8 → 34.4 ms (+2%) | 46.3 → 46.7 ms (+1%) | 90.8 → 92.0 ms (+1%) | 87.5 → 87.7 ms (+0%) |
| All | 515 | 54.6 → 52.9 ms (-3%) | 59.3 → 57.3 ms (-3%) | 115.3 → 111.3 ms (-3%) | 115.9 → 112.1 ms (-3%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 400 | 62.9 → 61.2 ms (-3%) | 116.3 → 111.3 ms (-4%) | 117.7 → 113.1 ms (-4%) | 61.7 → 60.0 ms |
| config-guard.sh | 63 | 15.6 → 15.6 ms (-0%) | 36.6 → 36.7 ms (+0%) | 22.4 → 22.4 ms (-0%) | 14.5 → 14.4 ms |
| mod-gate.sh | 63 | 1.5 → 1.5 ms (+0%) | 11.9 → 11.9 ms (-0%) | 2.0 → 2.0 ms (+0%) | 0.3 → 0.3 ms |
| secret-scanner.sh | 63 | 21.1 → 21.1 ms (+0%) | 65.8 → 65.7 ms (-0%) | 26.1 → 26.2 ms (+0%) | 19.9 → 20.0 ms |
| sensitive-file-guard.sh | 104 | 40.2 → 40.3 ms (+0%) | 59.9 → 60.0 ms (+0%) | 45.7 → 45.7 ms (-0%) | 39.0 → 39.1 ms |
| subagent-cache-guard.sh | 515 | 6.0 → 6.0 ms (+0%) | 6.3 → 6.3 ms (+0%) | 5.8 → 5.8 ms (+0%) | 4.8 → 4.8 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 400 | 24.53 → 21.98 | 102.72 → 98.66 | 50902 → 48259 | 25 / 118 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 515 | 1.00 → 1.00 | 1.00 → 1.00 | 1030 → 1030 | 0 / 0 | 0 |

Decisions: 515 of 515 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.15 (2026-11-19)

Merged since v1.4.14: 5 PRs.

### Security
- env-guard: name the workaround in the deny reason of an interpreter heredoc (#296)

### Speed
- hook-bench: progress on stderr and a partial table on interrupt (#293)

### Memory
- memory-lint: one finding for a file named as a handoff but not marked (#294)

### Other
- docs: long-running sessions, and a README section for them (#298)
- disk-space report: large transcripts, who has them open, removal date (#295)

### Benchmark vs v1.4.14

Gate script and corpus from `cbdb437` (v1.4.14): 506 payloads, 0 of them new in this change.



2026-11-19T23:06:21Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.JQlg0r/corpus.jsonl: 506 payloads (386 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.2 ms, `jq -n 1` 2.0 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 386 | 63.0 → 62.7 ms (-0%) | 62.0 → 62.0 ms (-0%) | 115.5 → 115.8 ms (+0%) | 121.7 → 122.0 ms (+0%) |
| WebFetch | 11 | 6.0 → 6.0 ms (-1%) | 6.0 → 6.0 ms (-0%) | 6.2 → 6.1 ms (-1%) | 5.8 → 5.8 ms (-0%) |
| Read/Grep | 41 | 41.8 → 41.9 ms (+0%) | 46.7 → 46.5 ms (-0%) | 65.1 → 64.2 ms (-1%) | 57.5 → 57.4 ms (-0%) |
| Write/Edit | 63 | 49.0 → 49.2 ms (+0%) | 51.9 → 52.0 ms (+0%) | 74.6 → 75.2 ms (+1%) | 120.1 → 120.3 ms (+0%) |
| Monitor | 5 | 34.0 → 34.5 ms (+1%) | 46.4 → 46.7 ms (+1%) | 90.7 → 91.9 ms (+1%) | 87.9 → 88.1 ms (+0%) |
| All | 506 | 54.5 → 54.1 ms (-1%) | 58.2 → 58.1 ms (-0%) | 113.3 → 111.6 ms (-2%) | 113.5 → 113.7 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 391 | 62.8 → 62.4 ms (-1%) | 113.9 → 114.0 ms (+0%) | 114.9 → 115.1 ms (+0%) | 61.6 → 61.2 ms |
| config-guard.sh | 63 | 15.9 → 15.9 ms (-0%) | 37.4 → 37.4 ms (-0%) | 22.8 → 22.8 ms (-0%) | 14.8 → 14.8 ms |
| mod-gate.sh | 63 | 1.5 → 1.5 ms (-0%) | 12.1 → 12.1 ms (+0%) | 2.1 → 2.1 ms (+3%) | 0.4 → 0.4 ms |
| secret-scanner.sh | 63 | 21.6 → 21.6 ms (-0%) | 66.6 → 67.9 ms (+2%) | 26.7 → 26.7 ms (+0%) | 20.4 → 20.4 ms |
| sensitive-file-guard.sh | 104 | 41.4 → 41.4 ms (+0%) | 61.2 → 62.4 ms (+2%) | 46.8 → 47.1 ms (+0%) | 40.2 → 40.3 ms |
| subagent-cache-guard.sh | 506 | 6.2 → 6.1 ms (-0%) | 6.5 → 6.5 ms (-0%) | 6.0 → 5.9 ms (-0%) | 5.0 → 5.0 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 391 | 23.60 → 23.60 | 100.01 → 100.01 | 48329 → 48329 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 506 | 1.00 → 1.00 | 1.00 → 1.00 | 1012 → 1012 | 0 / 0 | 0 |

Decisions: 506 of 506 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

This change edits tools/hook-bench.py, so the gate ran again with its copy (exit 0):


2026-11-19T23:10:41Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.JQlg0r/corpus.jsonl: 506 payloads (386 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.1 ms, `jq -n 1` 2.0 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 386 | 62.8 → 62.8 ms (-0%) | 61.5 → 61.7 ms (+0%) | 114.4 → 113.1 ms (-1%) | 121.2 → 121.5 ms (+0%) |
| WebFetch | 11 | 5.7 → 5.7 ms (+0%) | 5.7 → 5.7 ms (+0%) | 5.8 → 5.9 ms (+1%) | 5.6 → 5.6 ms (+0%) |
| Read/Grep | 41 | 40.6 → 40.6 ms (+0%) | 45.0 → 45.0 ms (+0%) | 61.5 → 62.1 ms (+1%) | 55.6 → 55.7 ms (+0%) |
| Write/Edit | 63 | 48.1 → 48.3 ms (+0%) | 50.9 → 51.1 ms (+0%) | 74.2 → 74.7 ms (+1%) | 118.7 → 118.7 ms (-0%) |
| Monitor | 5 | 34.2 → 33.5 ms (-2%) | 45.3 → 45.3 ms (+0%) | 88.2 → 89.3 ms (+1%) | 85.8 → 86.6 ms (+1%) |
| All | 506 | 53.1 → 53.0 ms (-0%) | 57.5 → 57.6 ms (+0%) | 112.4 → 112.4 ms (-0%) | 112.8 → 113.0 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 391 | 61.7 → 62.1 ms (+1%) | 113.3 → 113.5 ms (+0%) | 113.9 → 114.1 ms (+0%) | 60.6 → 61.0 ms |
| config-guard.sh | 63 | 15.6 → 15.6 ms (+0%) | 36.6 → 36.7 ms (+0%) | 22.4 → 22.4 ms (+0%) | 14.4 → 14.5 ms |
| mod-gate.sh | 63 | 1.4 → 1.5 ms (+0%) | 11.9 → 11.8 ms (-0%) | 2.0 → 2.0 ms (+0%) | 0.3 → 0.3 ms |
| secret-scanner.sh | 63 | 21.1 → 21.1 ms (-0%) | 64.9 → 64.4 ms (-1%) | 26.2 → 26.2 ms (+0%) | 20.0 → 20.0 ms |
| sensitive-file-guard.sh | 104 | 40.1 → 40.1 ms (-0%) | 59.0 → 59.1 ms (+0%) | 45.5 → 45.6 ms (+0%) | 39.0 → 39.0 ms |
| subagent-cache-guard.sh | 506 | 6.0 → 6.0 ms (-0%) | 6.4 → 6.4 ms (+0%) | 5.8 → 5.8 ms (-0%) | 4.9 → 4.9 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 391 | 23.60 → 23.60 | 100.01 → 100.01 | 48329 → 48329 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 506 | 1.00 → 1.00 | 1.00 → 1.00 | 1012 → 1012 | 0 / 0 | 0 |

Decisions: 506 of 506 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.14 (2026-11-19)

Merged since v1.4.13: 5 PRs.

### Security
- rm-guard: its filter reads the text bash runs, in any case (#291)
- config-guard: a glob after //, /./, /DIR/../, the home path or ./ reads in full; the property sees globs (#290)
- guard-props: the #287 review's follow-ups (approved-list reading, printenv word, timeouts, base-list test) (#289)
- config-guard reads split paths and dot-name globs; guard-props approved differences and a daily workflow (#287)

### Speed
- tests/hook-bench: widen the max-vs-sum gap in "wait is a max" (#288)

### Benchmark vs v1.4.13

Gate script and corpus from `775bc48` (v1.4.13): 506 payloads, 14 of them new in this change: config-split-settings-single, config-split-settings-double, config-split-settings-empty-pair, config-split-hooks-empty-single, config-split-hooks-backslash, config-split-hooks-rm, config-split-bashrc, config-split-profile, config-split-gitconfig-backslash, config-split-continuation, config-split-read-passes, config-split-projects-passes, rm-case-home, rm-split-home.



2026-11-19T06:59:27Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus ../../_temp/bench-gate.nuvpb9/corpus.jsonl: 506 payloads (386 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.2 ms, `jq -n 1` 2.0 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 386 | 62.2 → 63.5 ms (+2%) | 60.8 → 62.4 ms (+3%) | 114.2 → 116.5 ms (+2%) | 120.1 → 122.9 ms (+2%) |
| WebFetch | 11 | 5.8 → 5.8 ms (+0%) | 5.8 → 5.8 ms (-0%) | 5.9 → 5.9 ms (-0%) | 5.7 → 5.7 ms (-0%) |
| Read/Grep | 41 | 41.2 → 41.0 ms (-0%) | 45.7 → 45.8 ms (+0%) | 63.8 → 62.9 ms (-2%) | 56.4 → 56.5 ms (+0%) |
| Write/Edit | 63 | 48.9 → 49.2 ms (+1%) | 51.7 → 51.8 ms (+0%) | 75.2 → 75.0 ms (-0%) | 120.1 → 120.7 ms (+0%) |
| Monitor | 5 | 34.5 → 34.3 ms (-1%) | 46.9 → 47.1 ms (+1%) | 93.4 → 93.2 ms (-0%) | 88.5 → 89.1 ms (+1%) |
| All | 506 | 52.2 → 53.8 ms (+3%) | 57.1 → 58.3 ms (+2%) | 112.7 → 113.6 ms (+1%) | 112.2 → 114.4 ms (+2%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 391 | 61.7 → 63.1 ms (+2%) | 114.4 → 115.0 ms (+1%) | 112.7 → 115.4 ms (+2%) | 60.5 → 61.9 ms |
| config-guard.sh | 63 | 15.8 → 16.0 ms (+1%) | 36.9 → 37.5 ms (+1%) | 22.6 → 22.8 ms (+1%) | 14.6 → 14.8 ms |
| mod-gate.sh | 63 | 1.5 → 1.5 ms (-0%) | 12.2 → 12.1 ms (-1%) | 2.1 → 2.1 ms (+1%) | 0.4 → 0.4 ms |
| secret-scanner.sh | 63 | 21.6 → 21.7 ms (+1%) | 66.8 → 67.1 ms (+0%) | 26.6 → 26.9 ms (+1%) | 20.4 → 20.5 ms |
| sensitive-file-guard.sh | 104 | 41.0 → 40.9 ms (-0%) | 59.6 → 59.7 ms (+0%) | 46.3 → 46.4 ms (+0%) | 39.8 → 39.7 ms |
| subagent-cache-guard.sh | 506 | 6.1 → 6.1 ms (+0%) | 6.5 → 6.5 ms (-0%) | 5.9 → 5.9 ms (-0%) | 4.9 → 4.9 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 391 | 23.06 → 23.60 | 98.32 → 100.01 | 47462 → 48329 | 13 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 506 | 1.00 → 1.00 | 1.00 → 1.00 | 1012 → 1012 | 0 / 0 | 0 |

Decisions: 494 of 506 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| config-split-settings-single `cp x ~/'.cl'aude/settings.json` | allow (silent) | ask (bash-guards.sh) |
| config-split-settings-double `cp x ~/.cl"aude"/settings.json` | allow (silent) | ask (bash-guards.sh) |
| config-split-settings-empty-pair `cp x ~/.c""laude/settings.json` | allow (silent) | ask (bash-guards.sh) |
| config-split-hooks-empty-single `cp x ~/.cl''aude/hooks/lib.sh` | allow (silent) | ask (bash-guards.sh) |
| config-split-hooks-backslash `cp x ~/.cl\aude/hooks/lib.sh` | allow (silent) | ask (bash-guards.sh) |
| config-split-hooks-rm `rm ~/.cl''aude/hooks/env-guard.sh` | allow (silent) | ask (bash-guards.sh) |
| config-split-bashrc `echo x >> ~/.bash"rc"` | allow (silent) | ask (bash-guards.sh) |
| config-split-profile `echo x >> ~/.pro"file"` | allow (silent) | ask (bash-guards.sh) |
| config-split-gitconfig-backslash `echo x >> ~/.git\config` | allow (silent) | ask (bash-guards.sh) |
| config-split-continuation `cp x ~/.cl""au\ de/settings.json` | allow (silent) | ask (bash-guards.sh) |
| rm-case-home `RM -rf ~/` | allow (silent) | deny (bash-guards.sh) |
| rm-split-home `r''m -rf ~/` | allow (silent) | deny (bash-guards.sh) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.13 (2026-11-19)

Merged since v1.4.12: 2 PRs.

### Security
- guard-props: property checks for guard fast paths, inert heredocs, count_mark (#280)

### Other
- tests/doctor: time budgets that hold on a loaded runner (#284)

### Benchmark vs v1.4.12

Gate script and corpus from `7013901` (v1.4.12): 492 payloads, 0 of them new in this change.

hooks/ and config/settings.json match v1.4.12; benchmark skipped (both sides would run the same files).

## v1.4.12 (2026-11-18)

Merged since v1.4.11: 7 PRs.

### Speed
- bench: the gate runs the base's script and corpus (#277)

### Memory
- memory-lint: lint only handoffs in trackers/; tracker-prune race fixed (#281)
- memory-lint: tracker ledgers; tracker-prune.py moves settled rows to an archive (#279)

### Other
- skills.pin: claude-code-skills v1.3.0 (#282)
- verify-changed: an opt-in, diff-keyed checklist, a commit stamp CI lists, two rule lines (#278)
- pre-compact: one copy per session, and a byte cap (#276)
- session-start: large transcripts across the machine; the nudge on compact (#275)

### Benchmark vs v1.4.11

Gate script and corpus from `fdf4520` (v1.4.11): 492 payloads, 0 of them new in this change.



2026-11-18T22:14:21Z, Linux 7.0.0-1019-azure x86_64, INTEL(R) XEON(R) PLATINUM 8573C, python 3.14.4. Corpus ../../_temp/bench-gate.I95jSx/corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.5 ms, `bash -c :` 1.0 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 65.0 → 64.8 ms (-0%) | 62.4 → 62.4 ms (-0%) | 115.3 → 116.4 ms (+1%) | 124.1 → 124.0 ms (-0%) |
| WebFetch | 11 | 5.9 → 6.0 ms (+1%) | 5.9 → 5.9 ms (+1%) | 6.0 → 6.1 ms (+2%) | 5.7 → 5.7 ms (+1%) |
| Read/Grep | 41 | 42.9 → 42.8 ms (-0%) | 47.0 → 46.8 ms (-0%) | 68.0 → 66.7 ms (-2%) | 58.1 → 57.9 ms (-0%) |
| Write/Edit | 63 | 50.9 → 51.1 ms (+0%) | 53.9 → 53.8 ms (-0%) | 74.4 → 74.2 ms (-0%) | 124.6 → 124.3 ms (-0%) |
| Monitor | 5 | 34.4 → 35.6 ms (+3%) | 46.6 → 46.7 ms (+0%) | 90.1 → 90.5 ms (+0%) | 89.7 → 89.9 ms (+0%) |
| All | 492 | 55.0 → 54.3 ms (-1%) | 58.6 → 58.6 ms (-0%) | 111.6 → 112.1 ms (+0%) | 115.6 → 115.5 ms (-0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 63.6 → 64.2 ms (+1%) | 114.8 → 114.7 ms (-0%) | 115.9 → 115.7 ms (-0%) | 62.6 → 63.1 ms |
| config-guard.sh | 63 | 16.1 → 16.1 ms (-0%) | 36.9 → 36.9 ms (+0%) | 22.8 → 22.7 ms (-0%) | 15.0 → 15.0 ms |
| mod-gate.sh | 63 | 1.5 → 1.5 ms (-0%) | 12.1 → 12.0 ms (-1%) | 2.0 → 2.0 ms (+0%) | 0.4 → 0.4 ms |
| secret-scanner.sh | 63 | 21.9 → 22.0 ms (+1%) | 63.2 → 63.3 ms (+0%) | 26.9 → 26.8 ms (-0%) | 20.8 → 21.0 ms |
| sensitive-file-guard.sh | 104 | 42.0 → 42.0 ms (-0%) | 58.8 → 58.3 ms (-1%) | 47.2 → 47.1 ms (-0%) | 41.0 → 41.0 ms |
| subagent-cache-guard.sh | 492 | 6.1 → 6.1 ms (-0%) | 6.4 → 6.4 ms (+0%) | 5.9 → 5.9 ms (-0%) | 5.1 → 5.0 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 377 | 23.78 → 23.78 | 100.34 → 100.34 | 46796 → 46796 | 0 / 0 | 0 |
| config-guard.sh | 63 | 5.10 → 5.10 | 15.24 → 15.24 | 1281 → 1281 | 0 / 0 | 0 |
| mod-gate.sh | 63 | 0.19 → 0.19 | 0.44 → 0.44 | 40 → 40 | 0 / 0 | 0 |
| secret-scanner.sh | 63 | 7.65 → 7.65 | 19.95 → 19.95 | 1739 → 1739 | 0 / 0 | 0 |
| sensitive-file-guard.sh | 104 | 13.10 → 13.10 | 30.25 → 30.25 | 4508 → 4508 | 0 / 0 | 0 |
| subagent-cache-guard.sh | 492 | 1.00 → 1.00 | 1.00 → 1.00 | 984 → 984 | 0 / 0 | 0 |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.11 (2026-11-18)

Merged since v1.4.10: 4 PRs.

### Speed
- hook-bench gates on process starts; read_input and git-guard start fewer (stacked on #268) (#270)
- Timing log at=, hook-latency reads it first, --since, and a report-only process count in hook-bench (#268)

### Memory
- memory-lint: a handoff tracker has one shape (#271)

### Other
- skills.pin: claude-code-skills v1.2.0 (#273)

### Benchmark vs v1.4.10


2026-11-18T12:08:09Z, Linux 7.0.0-1019-azure x86_64, Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.1 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 66.1 → 64.1 ms (-3%) | 65.4 → 61.8 ms (-6%) | 118.6 → 115.9 ms (-2%) | 131.9 → 123.3 ms (-7%) |
| WebFetch | 11 | 8.4 → 6.1 ms (-28%) | 8.4 → 6.2 ms (-27%) | 8.8 → 6.9 ms (-22%) | 8.2 → 5.9 ms (-28%) |
| Read/Grep | 41 | 44.3 → 41.9 ms (-5%) | 48.4 → 45.9 ms (-5%) | 67.4 → 66.4 ms (-1%) | 61.6 → 56.7 ms (-8%) |
| Write/Edit | 63 | 55.1 → 51.1 ms (-7%) | 57.4 → 53.7 ms (-6%) | 76.7 → 73.8 ms (-4%) | 140.8 → 125.6 ms (-11%) |
| Monitor | 5 | 36.5 → 34.1 ms (-7%) | 48.2 → 46.2 ms (-4%) | 92.4 → 90.5 ms (-2%) | 92.8 → 89.3 ms (-4%) |
| All | 492 | 56.5 → 54.2 ms (-4%) | 61.5 → 58.0 ms (-6%) | 115.8 → 112.4 ms (-3%) | 124.0 → 115.1 ms (-7%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 64.5 → 62.7 ms (-3%) | 117.0 → 113.3 ms (-3%) | 120.7 → 115.1 ms (-5%) | 63.4 → 61.6 ms |
| config-guard.sh | 63 | 18.0 → 15.8 ms (-12%) | 39.4 → 36.6 ms (-7%) | 24.7 → 22.5 ms (-9%) | 16.9 → 14.7 ms |
| mod-gate.sh | 63 | 3.8 → 1.5 ms (-62%) | 14.0 → 11.8 ms (-16%) | 4.3 → 2.0 ms (-54%) | 2.7 → 0.4 ms |
| secret-scanner.sh | 63 | 23.8 → 21.5 ms (-10%) | 62.9 → 61.1 ms (-3%) | 28.4 → 26.1 ms (-8%) | 22.7 → 20.4 ms |
| sensitive-file-guard.sh | 104 | 43.6 → 41.3 ms (-5%) | 60.8 → 57.9 ms (-5%) | 48.8 → 46.3 ms (-5%) | 42.5 → 40.2 ms |
| subagent-cache-guard.sh | 492 | 8.4 → 6.1 ms (-27%) | 9.0 → 6.5 ms (-28%) | 8.2 → 5.9 ms (-29%) | 7.3 → 5.0 ms |

Processes started: each hook run alone once per payload under `strace -f`. Execs are execve calls past the hook's own bash; forks are new processes (clone, clone3, fork or vfork without CLONE_THREAD), a `$( )` among them. A machine that pays for each process start pays for both.

| Hook | payloads | execs per payload | forks per payload | in all | payloads with more / fewer | not counted |
|---|---:|---|---|---|---|---:|
| bash-guards.sh | 377 | 25.59 → 23.78 | 104.72 → 100.34 | 49127 → 46796 | 0 / 377 | 0 |
| config-guard.sh | 63 | 6.10 → 5.10 | 16.24 → 15.24 | 1407 → 1281 | 0 / 63 | 0 |
| mod-gate.sh | 63 | 1.19 → 0.19 | 1.44 → 0.44 | 166 → 40 | 0 / 63 | 0 |
| secret-scanner.sh | 63 | 8.65 → 7.65 | 20.95 → 19.95 | 1865 → 1739 | 0 / 63 | 0 |
| sensitive-file-guard.sh | 104 | 14.10 → 13.10 | 31.25 → 30.25 | 4716 → 4508 | 0 / 104 | 0 |
| subagent-cache-guard.sh | 492 | 2.00 → 1.00 | 2.00 → 1.00 | 1968 → 984 | 0 / 492 | 0 |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended; no payload's hooks may start more processes unless intended).

## v1.4.10 (2026-11-18)

Merged since v1.4.9: 4 PRs.

### Security
- fix(guards): a quoted separator does not split an inert heredoc segment (#267)

### Speed
- session-start: name a large transcript on resume, and slow guards (#269)

### Memory
- memory tools: batched gh lookups, waivers, orphans, index status, diff and archive (#266)

### Other
- session-start: zsh reads Claude's commands as bash does (#265)

### Benchmark vs v1.4.9


2026-11-18T11:07:41Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.7 ms, `bash -c :` 1.4 ms, `jq -n 1` 2.3 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 82.1 → 81.8 ms (-0%) | 80.0 → 80.6 ms (+1%) | 147.0 → 147.5 ms (+0%) | 160.7 → 162.1 ms (+1%) |
| WebFetch | 11 | 9.8 → 9.8 ms (+0%) | 9.9 → 9.9 ms (+0%) | 10.5 → 10.4 ms (-1%) | 9.7 → 9.7 ms (+0%) |
| Read/Grep | 41 | 54.1 → 54.1 ms (-0%) | 60.1 → 60.1 ms (-0%) | 88.4 → 86.2 ms (-3%) | 76.9 → 76.9 ms (+0%) |
| Write/Edit | 63 | 68.0 → 68.0 ms (+0%) | 70.6 → 71.0 ms (+1%) | 99.0 → 97.2 ms (-2%) | 173.8 → 175.2 ms (+1%) |
| Monitor | 5 | 45.4 → 47.6 ms (+5%) | 60.4 → 61.4 ms (+2%) | 116.7 → 119.6 ms (+3%) | 116.5 → 118.1 ms (+1%) |
| All | 492 | 71.3 → 71.5 ms (+0%) | 75.4 → 75.9 ms (+1%) | 143.0 → 143.1 ms (+0%) | 151.6 → 152.8 ms (+1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 81.2 → 80.3 ms (-1%) | 147.6 → 145.5 ms (-1%) | 148.0 → 149.3 ms (+1%) | 79.7 → 78.8 ms |
| config-guard.sh | 63 | 23.0 → 22.8 ms (-1%) | 49.5 → 50.9 ms (+3%) | 31.4 → 31.4 ms (+0%) | 21.5 → 21.4 ms |
| mod-gate.sh | 63 | 4.9 → 4.9 ms (+0%) | 18.0 → 16.8 ms (-6%) | 5.7 → 5.6 ms (-3%) | 3.5 → 3.5 ms |
| secret-scanner.sh | 63 | 29.8 → 30.0 ms (+1%) | 85.2 → 82.9 ms (-3%) | 36.6 → 36.3 ms (-1%) | 28.4 → 28.6 ms |
| sensitive-file-guard.sh | 104 | 53.9 → 54.0 ms (+0%) | 84.4 → 80.0 ms (-5%) | 61.6 → 61.1 ms (-1%) | 52.5 → 52.6 ms |
| subagent-cache-guard.sh | 492 | 10.2 → 10.2 ms (+0%) | 11.4 → 11.4 ms (-0%) | 10.1 → 10.1 ms (+0%) | 8.8 → 8.8 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.9 (2026-11-18)

Merged since v1.4.8: 1 PR.

### Other
- disk-space: prune job tmp, clones and orphaned Bazel output bases, by digest (#262)

### Benchmark vs v1.4.8


2026-11-18T02:49:58Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.5 ms, `bash -c :` 1.1 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 65.1 → 64.6 ms (-1%) | 63.9 → 63.9 ms (-0%) | 119.1 → 117.0 ms (-2%) | 127.1 → 127.1 ms (+0%) |
| WebFetch | 11 | 7.9 → 7.9 ms (-0%) | 7.9 → 7.9 ms (-0%) | 8.0 → 8.0 ms (-0%) | 7.8 → 7.8 ms (-0%) |
| Read/Grep | 41 | 42.4 → 42.4 ms (-0%) | 46.9 → 47.0 ms (+0%) | 63.0 → 63.6 ms (+1%) | 59.9 → 60.1 ms (+0%) |
| Write/Edit | 63 | 51.1 → 51.5 ms (+1%) | 54.0 → 54.2 ms (+0%) | 79.5 → 78.7 ms (-1%) | 132.6 → 132.8 ms (+0%) |
| Monitor | 5 | 35.5 → 35.8 ms (+1%) | 46.8 → 47.0 ms (+0%) | 89.7 → 89.7 ms (-0%) | 89.8 → 89.3 ms (-1%) |
| All | 492 | 54.5 → 54.8 ms (+0%) | 59.8 → 59.8 ms (+0%) | 114.0 → 113.9 ms (-0%) | 119.1 → 119.2 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 64.7 → 64.6 ms (-0%) | 117.5 → 118.0 ms (+0%) | 117.3 → 117.5 ms (+0%) | 63.6 → 63.5 ms |
| config-guard.sh | 63 | 17.5 → 17.5 ms (+0%) | 38.4 → 38.2 ms (-0%) | 24.2 → 24.3 ms (+0%) | 16.3 → 16.4 ms |
| mod-gate.sh | 63 | 3.7 → 3.7 ms (+0%) | 13.6 → 14.0 ms (+3%) | 4.3 → 4.3 ms (+0%) | 2.5 → 2.6 ms |
| secret-scanner.sh | 63 | 23.1 → 23.1 ms (+0%) | 67.9 → 68.0 ms (+0%) | 28.3 → 28.3 ms (+0%) | 22.0 → 22.0 ms |
| sensitive-file-guard.sh | 104 | 41.9 → 41.9 ms (+0%) | 61.4 → 61.4 ms (-0%) | 47.4 → 47.4 ms (+0%) | 40.8 → 40.8 ms |
| subagent-cache-guard.sh | 492 | 8.2 → 8.3 ms (+0%) | 8.4 → 8.4 ms (-0%) | 8.1 → 8.1 ms (-0%) | 7.1 → 7.1 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.8 (2026-11-18)

Merged since v1.4.7: 1 PR.

### Other
- disk-space: report job folders and Bazel output bases, warn at session start (#261)

### Benchmark vs v1.4.7


2026-11-18T01:53:54Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.7 ms, `bash -c :` 1.4 ms, `jq -n 1` 2.3 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 79.3 → 79.2 ms (-0%) | 77.6 → 77.7 ms (+0%) | 142.8 → 142.5 ms (-0%) | 156.5 → 156.4 ms (-0%) |
| WebFetch | 11 | 9.5 → 9.5 ms (+0%) | 9.5 → 9.5 ms (+0%) | 9.7 → 9.6 ms (-1%) | 9.4 → 9.4 ms (+0%) |
| Read/Grep | 41 | 50.7 → 50.8 ms (+0%) | 56.0 → 56.0 ms (+0%) | 76.6 → 76.6 ms (-0%) | 71.7 → 71.7 ms (+0%) |
| Write/Edit | 63 | 63.2 → 63.7 ms (+1%) | 66.7 → 66.7 ms (+0%) | 95.7 → 96.0 ms (+0%) | 165.9 → 166.3 ms (+0%) |
| Monitor | 5 | 42.6 → 42.7 ms (+0%) | 57.0 → 57.1 ms (+0%) | 109.6 → 109.6 ms (+0%) | 110.3 → 110.9 ms (+1%) |
| All | 492 | 65.9 → 66.6 ms (+1%) | 72.7 → 72.8 ms (+0%) | 139.1 → 139.2 ms (+0%) | 146.8 → 146.9 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 77.4 → 77.9 ms (+1%) | 141.5 → 139.8 ms (-1%) | 143.5 → 143.6 ms (+0%) | 76.0 → 76.6 ms |
| config-guard.sh | 63 | 20.9 → 20.8 ms (-0%) | 45.0 → 45.6 ms (+1%) | 28.8 → 28.9 ms (+0%) | 19.5 → 19.5 ms |
| mod-gate.sh | 63 | 4.3 → 4.3 ms (+1%) | 16.3 → 16.2 ms (-0%) | 5.0 → 5.0 ms (+0%) | 2.9 → 3.0 ms |
| secret-scanner.sh | 63 | 27.5 → 27.6 ms (+0%) | 81.0 → 81.5 ms (+1%) | 33.8 → 33.8 ms (+0%) | 26.2 → 26.2 ms |
| sensitive-file-guard.sh | 104 | 50.1 → 50.1 ms (+0%) | 71.4 → 72.1 ms (+1%) | 56.7 → 56.7 ms (+0%) | 48.7 → 48.8 ms |
| subagent-cache-guard.sh | 492 | 9.7 → 9.6 ms (-0%) | 10.0 → 10.0 ms (-0%) | 9.5 → 9.5 ms (-0%) | 8.3 → 8.3 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.7 (2026-11-17)

Merged since v1.4.6: 1 PR.

### Other
- tests: heredoc-openers' oracle lets a <( ) finish before it kills the group (#259)

### Benchmark vs v1.4.6

hooks/ and config/settings.json are unchanged since v1.4.6; benchmark skipped (both sides would run the same files).

## v1.4.6 (2026-11-17)

Merged since v1.4.5: 6 PRs.

### Security
- config-guard: the pre-filter skips paths under scratch, projects and logs (#257)
- guards: a command naming no guard's word starts no process in them (#256)
- shadow: only in auto mode; in any other mode the rule decides live (#254)

### Speed
- ci: the PR bench runs every payload; skipped when hooks/ and settings are unchanged (#253)

### Other
- skills.pin: claude-code-skills v1.1.0 (comms-hub fixes) (#258)
- tools: name a numbered hook record from its own stdout, never stderr (#255)

### Benchmark vs v1.4.5


2026-11-17T02:07:55Z, Linux 7.0.0-1016-aws x86_64, Intel(R) Xeon(R) 6975P-C, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.4 ms, `bash -c :` 0.9 ms, `jq -n 1` 1.5 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 56.1 → 51.6 ms (-8%) | 55.6 → 50.5 ms (-9%) | 96.2 → 91.1 ms (-5%) | 115.6 → 97.6 ms (-16%) |
| WebFetch | 11 | 6.4 → 6.4 ms (+1%) | 6.4 → 6.4 ms (+1%) | 6.5 → 6.5 ms (+0%) | 6.3 → 6.3 ms (+1%) |
| Read/Grep | 41 | 35.5 → 35.5 ms (-0%) | 38.9 → 38.9 ms (-0%) | 54.2 → 54.3 ms (+0%) | 48.8 → 48.9 ms (+0%) |
| Write/Edit | 63 | 41.2 → 40.9 ms (-1%) | 43.3 → 43.0 ms (-1%) | 60.4 → 61.4 ms (+2%) | 102.6 → 102.6 ms (+0%) |
| Monitor | 5 | 28.7 → 28.2 ms (-2%) | 40.3 → 37.8 ms (-6%) | 75.5 → 72.6 ms (-4%) | 80.9 → 70.1 ms (-13%) |
| All | 492 | 47.2 → 43.7 ms (-7%) | 51.4 → 47.5 ms (-8%) | 94.6 → 89.6 ms (-5%) | 105.6 → 91.9 ms (-13%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 55.9 → 51.7 ms (-7%) | 94.7 → 91.9 ms (-3%) | 108.5 → 91.0 ms (-16%) | 55.0 → 50.9 ms |
| config-guard.sh | 63 | 14.8 → 14.8 ms (+0%) | 31.0 → 30.9 ms (-0%) | 19.9 → 19.9 ms (-0%) | 13.9 → 13.9 ms |
| mod-gate.sh | 63 | 3.1 → 3.1 ms (+0%) | 11.5 → 11.6 ms (+1%) | 3.5 → 3.5 ms (+0%) | 2.2 → 2.2 ms |
| secret-scanner.sh | 63 | 19.0 → 19.1 ms (+0%) | 54.6 → 54.6 ms (+0%) | 23.1 → 23.0 ms (-0%) | 18.2 → 18.2 ms |
| sensitive-file-guard.sh | 104 | 35.2 → 35.0 ms (-1%) | 49.2 → 49.9 ms (+1%) | 39.1 → 39.1 ms (-0%) | 34.4 → 34.1 ms |
| subagent-cache-guard.sh | 492 | 6.7 → 6.8 ms (+1%) | 7.1 → 7.3 ms (+2%) | 6.5 → 6.6 ms (+1%) | 5.8 → 5.9 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.5 (2026-11-16)

Merged since v1.4.4: 5 PRs.

### Security
- kubectl-guard: dynamic-verb asks live again (#250)
- permission-friction: a numbered hook's reason names its guard (#248)
- kubectl-guard: credential reads ask live again; verb rules stay in shadow (#246)

### Other
- skills.pin: claude-code-skills v1.0.1 (#249)
- harness-update gates on the smoke set; doctor logs survive a reboot and name failed suites (#247)

### Benchmark vs v1.4.4


2026-11-16T19:53:32Z, Linux 7.0.0-1016-aws x86_64, Intel(R) Xeon(R) 6975P-C, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.4 ms, `bash -c :` 0.9 ms, `jq -n 1` 1.5 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 56.4 → 56.0 ms (-1%) | 55.5 → 55.5 ms (+0%) | 95.3 → 95.8 ms (+0%) | 115.6 → 115.6 ms (-0%) |
| WebFetch | 11 | 6.4 → 6.4 ms (-0%) | 6.4 → 6.4 ms (-0%) | 6.6 → 6.6 ms (-1%) | 6.3 → 6.3 ms (-0%) |
| Read/Grep | 41 | 34.8 → 34.7 ms (-0%) | 38.3 → 38.2 ms (-0%) | 53.1 → 52.0 ms (-2%) | 48.1 → 48.1 ms (+0%) |
| Write/Edit | 63 | 40.8 → 40.7 ms (-0%) | 42.8 → 42.8 ms (-0%) | 60.6 → 59.6 ms (-2%) | 101.6 → 101.7 ms (+0%) |
| Monitor | 5 | 28.6 → 28.1 ms (-2%) | 40.8 → 40.7 ms (-0%) | 77.3 → 76.6 ms (-1%) | 80.6 → 81.2 ms (+1%) |
| All | 492 | 47.3 → 47.1 ms (-0%) | 51.2 → 51.2 ms (+0%) | 93.7 → 94.4 ms (+1%) | 105.4 → 105.4 ms (-0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 57.0 → 56.8 ms (-0%) | 96.0 → 96.8 ms (+1%) | 108.9 → 109.0 ms (+0%) | 56.2 → 56.0 ms |
| config-guard.sh | 63 | 14.5 → 14.5 ms (+0%) | 30.7 → 30.7 ms (+0%) | 19.6 → 19.6 ms (+0%) | 13.6 → 13.7 ms |
| mod-gate.sh | 63 | 3.0 → 3.0 ms (-1%) | 11.0 → 11.0 ms (-0%) | 3.4 → 3.4 ms (+0%) | 2.1 → 2.1 ms |
| secret-scanner.sh | 63 | 18.6 → 18.7 ms (+0%) | 54.4 → 54.4 ms (+0%) | 22.6 → 22.7 ms (+0%) | 17.8 → 17.8 ms |
| sensitive-file-guard.sh | 104 | 34.4 → 34.3 ms (-0%) | 48.0 → 48.5 ms (+1%) | 38.4 → 38.4 ms (+0%) | 33.5 → 33.5 ms |
| subagent-cache-guard.sh | 492 | 6.7 → 6.7 ms (+0%) | 7.1 → 7.1 ms (+0%) | 6.5 → 6.5 ms (+0%) | 5.8 → 5.8 ms |

Decisions: 490 of 492 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-hole-kubectl-shellout-concat-kind `python3 - <<'EOF' import os os.system("kubectl get " + kind)` | allow (silent) | ask (bash-guards.sh) |
| bash-kubectl-get-secret `kubectl get secret db-creds -n staging -o yaml` | allow (silent) | ask (bash-guards.sh) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.4 (2026-11-15)

Merged since v1.4.3: 5 PRs.

### Security
- docs: the README describes the smaller harness beside auto mode (#243)
- guards: shadow mode for the guards auto mode may cover (#242)
- guards: freeze hardening, silence always-approved asks, kubectl ask rules (#241)

### Compatibility
- contract: a breakage check only (#238)

### Other
- skills: move to claude-code-skills, installed through harness-update (#239)

### Benchmark vs v1.4.3


2026-11-15T19:54:36Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 9V74 80-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 NotebookEdit, 2 MultiEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.6 ms, `bash -c :` 1.2 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 73.5 → 72.3 ms (-2%) | 72.0 → 71.7 ms (-1%) | 122.8 → 123.3 ms (+0%) | 153.9 → 153.6 ms (-0%) |
| WebFetch | 11 | 19.5 → 8.0 ms (-59%) | 25.9 → 8.0 ms (-69%) | 43.4 → 8.2 ms (-81%) | 38.5 → 7.8 ms (-80%) |
| Read/Grep | 41 | 42.6 → 43.2 ms (+1%) | 47.3 → 47.9 ms (+1%) | 63.6 → 64.5 ms (+2%) | 60.2 → 61.0 ms (+1%) |
| Write/Edit | 63 | 51.4 → 52.4 ms (+2%) | 54.4 → 54.8 ms (+1%) | 78.5 → 79.3 ms (+1%) | 132.6 → 134.0 ms (+1%) |
| Monitor | 5 | 41.7 → 35.6 ms (-15%) | 54.2 → 51.7 ms (-5%) | 108.4 → 97.9 ms (-10%) | 111.1 → 106.0 ms (-5%) |
| All | 492 | 62.3 → 60.1 ms (-4%) | 66.5 → 65.9 ms (-1%) | 121.0 → 121.6 ms (+1%) | 140.4 → 139.6 ms (-1%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 72.4 → 71.5 ms (-1%) | 122.3 → 122.3 ms (+0%) | 143.7 → 142.5 ms (-1%) | 71.2 → 70.3 ms |
| config-guard.sh | 63 | 17.6 → 18.0 ms (+2%) | 39.0 → 39.0 ms (+0%) | 24.5 → 24.8 ms (+1%) | 16.5 → 16.8 ms |
| mod-gate.sh | 63 | 3.8 → 3.8 ms (-0%) | 13.5 → 13.9 ms (+3%) | 4.4 → 4.4 ms (+1%) | 2.7 → 2.7 ms |
| network-guard.sh | 11 | 19.3 ms (base only) | 42.5 ms | 30.2 ms | 18.2 ms |
| secret-scanner.sh | 63 | 23.2 → 23.5 ms (+2%) | 68.3 → 69.1 ms (+1%) | 28.3 → 28.7 ms (+2%) | 22.0 → 22.4 ms |
| sensitive-file-guard.sh | 104 | 42.2 → 42.7 ms (+1%) | 62.6 → 62.5 ms (-0%) | 47.8 → 48.2 ms (+1%) | 41.1 → 41.5 ms |
| subagent-cache-guard.sh | 492 | 8.1 → 8.3 ms (+2%) | 8.5 → 8.7 ms (+2%) | 8.0 → 8.2 ms (+2%) | 7.0 → 7.1 ms |

Decisions: 399 of 492 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-kubectl-exec-read `kubectl --context dev-cluster -n default exec api-7d9f -- pr` | ask (bash-guards.sh) | allow (silent) |
| friction-git-worktree-remove-scratch `git -C ~/work/svc worktree remove --force "$CLAUDE_JOB_DIR/t` | ask (bash-guards.sh) | allow (silent) |
| friction-git-branch-delete `git worktree remove "$CLAUDE_JOB_DIR/tmp/h1025" && git branc` | ask (bash-guards.sh) | allow (silent) |
| friction-control-inline-env-read `python3 -c "import os; print(os.environ.get('AWS_SECRET_ACCE` | ask (bash-guards.sh) | allow (silent) |
| friction-control-kubectl-delete `kubectl --context dev-cluster -n default delete pod api-7d9f` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-second-line `echo start kubectl --context prod delete pod api-1` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-after-heredoc `cat > /dev/null <<'EOF' noop EOF kubectl --context prod dele` | ask (bash-guards.sh) | allow (silent) |
| friction-ctl-kubectl-same-line-semicolon `echo start; kubectl --context prod delete pod api-1` | ask (bash-guards.sh) | allow (silent) |
| friction-interp-second-line `echo start python3 -c "import os; print(os.environ.get('GH_T` | ask (bash-guards.sh) | allow (silent) |
| friction-kubectl-exec-cat-secret-path `kubectl --context dev -n default exec api-7d9f -- cat /var/r` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-echo-pipe-bash `echo 'kubectl --context prod delete pod x' | bash` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-printf-pipe-sh `printf '%s\n' 'kubectl delete ns payments' | sh` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-redirect-before-verb `kubectl 2>/dev/null delete pod x` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-xargs `grep -l foo pods.txt | xargs kubectl delete pod` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-heredoc-into-script `cat > "$CLAUDE_JOB_DIR/tmp/run.sh" <<'EOF' kubectl --context` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-net-G-bundled-X `curl -G -sXDELETE -d a=b https://api.github.com/x` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-net-G-then-plain-post `curl -G -d a=b https://api.github.com/x && curl -d c=d https` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-net-G-nonallowlisted `curl -s -G -d q=1 https://logs.internal.example/x` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-interp-glued-quote `python3 -c"import os;print(os.environ['GH_TOKEN'])"` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-interp-node-eval-eq `node --eval="console.log(process.env.GH_TOKEN)"` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-interp-tab-before-flag `python3	-c "import os; print(os.environ['GH_TOKEN'])"` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-echo-pipe-SHELL `echo 'kubectl --context prod delete pod x' | $SHELL` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-echo-pipe-dot-stdin `echo 'kubectl delete pod x' | . /dev/stdin` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-echo-pipe-awk-system `echo 'kubectl delete pod x' | awk '{system($0)}'` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-echo-pipe-tee-then-run `echo 'kubectl delete pod x' | tee run.sh; bash run.sh` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-background-amp `kubectl --context prod delete pod x &` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-net-post-after-amp-url `curl 'https://api.github.com/x?a=1&b=2' -X POST -d a=b` | ask (bash-guards.sh) | allow (silent) |
| friction-bonus-interp-python312-inline `python3.12 -c "import os; print(os.environ.get('GH_TOKEN'))"` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-interp-long-inline-no-semicolon `python3 -c "print(sum(z + 1 for z in (x * 2 for x in range(1` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-interp-perl-ne-envread `perl -ne 'print $ENV{GH_TOKEN}' /dev/null` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-interp-bash-lc-printenv `bash -lc 'printenv | head'` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-net-G-with-X-POST `curl -s -G -X POST -d a=b https://api.github.com/x` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-net-d-allowlisted-no-G `curl -s -d a=b https://api.github.com/x` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-bash-c `bash -c 'kubectl delete pod x'` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-find-exec `find . -name '*.yaml' -exec kubectl delete -f {} \;` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-subshell `echo "$(kubectl delete pod foo)"` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-grep-then-delete `grep -l kubectl scripts/* && kubectl delete pod foo` | ask (bash-guards.sh) | allow (silent) |
| friction-fp-kubectl-heredoc-text `cat > "$CLAUDE_JOB_DIR/tmp/run.sh" <<'EOF' kubectl delete po` | ask (bash-guards.sh) | allow (silent) |
| friction-subprocess-list-kubectl-view `python3 -c "import subprocess; subprocess.run(['kubectl','de` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-git-worktree-jobdir-override `CLAUDE_JOB_DIR=/ git worktree remove --force "$CLAUDE_JOB_DI` | ask (bash-guards.sh) | allow (silent) |
| friction-loopback-post-portforward-shape `kubectl --context prod port-forward svc/api 8080:80 & sleep ` | ask (bash-guards.sh) | allow (silent) |
| friction-loopback-delete `curl -s -X DELETE http://localhost:8080/api/v1/items/42` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-net-unquoted-amp-merged-G `curl -G https://api.github.com/x&curl -d a=b https://api.git` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-brace `{ python3 -c "import socket; s=socket.socket(); s.bind(('127` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-subshell `(python3 -c "import socket; s=socket.socket(); s.bind(('127.` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-if `if python3 -c "import socket; s=socket.socket(); s.bind(('12` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-then `if true; then python3 -c "import socket; s=socket.socket(); ` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-else `if false; then :; else python3 -c "import socket; s=socket.s` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-do `for i in 1; do python3 -c "import socket; s=socket.socket();` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-bang `! python3 -c "import socket; s=socket.socket(); s.bind(('127` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-case `case x in x) python3 -c "import socket; s=socket.socket(); s` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-function `function f { python3 -c "import socket; s=socket.socket(); s` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-fn-args `run() { "$@"; }; run python3 -c "import socket; s=socket.soc` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-rm-brace `{ rm -rf /var/lib/app; }` | deny (bash-guards.sh) | allow (silent) |
| friction-hole-rm-subshell `(rm -rf /var/lib/app)` | deny (bash-guards.sh) | allow (silent) |
| friction-hole-rm-then `if true; then rm -rf /var/lib/app; fi` | deny (bash-guards.sh) | allow (silent) |
| friction-hole-rm-do `for i in 1; do rm -rf /var/lib/app; done` | deny (bash-guards.sh) | allow (silent) |
| friction-hole-rm-bang `! rm -rf /var/lib/app` | deny (bash-guards.sh) | allow (silent) |
| friction-hole-rm-fn-args `run() { "$@"; }; run rm -rf /var/lib/app` | deny (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-subshell `(kubectl delete ns prod)` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-interp-probe-function `probe() { label="$1"; shift; if out=$("$@" 2>&1); then echo ` | ask (bash-guards.sh) | allow (silent) |
| friction-ok-env-heredoc-python-apostrophes `python3 - <<'PY' # don't x = 1  # it's (printenv) text PY` | ask (bash-guards.sh) | allow (silent) |
| friction-kubectl-heredoc-to-unset-var `cat > $F <<'EOF' Open a shell with kubectl exec, then check ` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-bash-heredoc-delete `bash <<'EOF' kubectl --context prod delete pod api-1 EOF` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-heredoc-into-apply `cat <<EOF | kubectl apply -f - apiVersion: v1 kind: ConfigMa` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-write-then-run `cat > "$CLAUDE_JOB_DIR/tmp/x.sh" <<'EOF' kubectl --context p` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-eval `eval "kubectl --context prod delete pod api-1"` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-python-os-system `python3 -c "import os; os.system('kubectl --context c delete` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-python-heredoc-subprocess `python3 - <<'EOF' import subprocess subprocess.run(["kubectl` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-node-execsync `node -e "require('child_process').execSync('kubectl --contex` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-assign-prefix-bash-heredoc `X=1 bash <<'EOF' kubectl --context prod delete pod api-1 EOF` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-python-output-to-bash `python3 - <<'EOF' | bash print("x; kubectl delete pod a") EO` | ask (bash-guards.sh) | allow (silent) |
| friction-pin-kubectl-python-output-to-file-then-run `python3 - <<'EOF' > run.sh print("x; kubectl delete pod a") ` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-shellout-bash-c `python3 -c "import subprocess; subprocess.run(['bash','-c','` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-shellout-concat-kind `python3 - <<'EOF' import os os.system("kubectl get " + kind)` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-kubectl-exec-code-with-globals `python3 -c "exec(\"import os; os.system('kubectl delete pod ` | ask (bash-guards.sh) | allow (silent) |
| friction-hole-rm-shellout-home `python3 -c "import os; os.system('rm -rf /opt/project/build'` | deny (bash-guards.sh) | allow (silent) |
| bash-git-branch-delete `git branch -D old-feature` | ask (bash-guards.sh) | allow (silent) |
| bash-curl-download `curl -fsSL https://example.com/file.tar.gz -o build/file.tar` | ask (bash-guards.sh) | allow (silent) |
| bash-curl-post-json `curl -X POST https://api.example.com/v1/items -H 'Content-Ty` | ask (bash-guards.sh) | allow (silent) |
| bash-curl-delete `curl -X DELETE https://api.example.com/v1/items/42` | ask (bash-guards.sh) | allow (silent) |
| bash-kubectl-get-secret `kubectl get secret db-creds -n staging -o yaml` | ask (bash-guards.sh) | allow (silent) |
| bash-kubectl-apply-dry `kubectl apply -f k8s/deploy.yaml --dry-run=server` | ask (bash-guards.sh) | allow (silent) |
| bash-kubectl-exec-cat `kubectl exec api-0 -n staging -- cat /etc/hosts` | ask (bash-guards.sh) | allow (silent) |
| bash-kubectl-delete `kubectl delete pod api-0 -n staging` | ask (bash-guards.sh) | allow (silent) |
| bash-rm-rf-build `rm -rf build/` | deny (bash-guards.sh) | allow (silent) |
| bash-env-sort `env | sort | head` | deny (bash-guards.sh) | allow (silent) |
| bash-scp `scp build/out.tgz deploy@host.example:/srv/app/` | ask (bash-guards.sh) | allow (silent) |
| webfetch-python-docs `https://docs.python.org/3/library/json.html` | ask (network-guard.sh) | allow (silent) |
| webfetch-example `https://example.com/` | ask (network-guard.sh) | allow (silent) |
| webfetch-intranet `https://wiki.intranet.example/page/retry-policy` | ask (network-guard.sh) | allow (silent) |
| monitor-curl-unlisted `while true; do curl -s https://status.unlisted.example/poll;` | ask (bash-guards.sh) | allow (silent) |
| monitor-ws-unlisted `wss://feed.unlisted.example/events` | ask (bash-guards.sh) | allow (silent) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.3 (2026-11-15)

Merged since v1.4.2: 1 PR.

### Security
- fix(guards): quoted separators and heredoc-body substitutions no longer hide commands (#233)

### Benchmark vs v1.4.2


2026-11-15T14:12:37Z, Linux 7.0.0-1019-azure x86_64, INTEL(R) XEON(R) PLATINUM 8573C, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.5 ms, `bash -c :` 1.1 ms, `jq -n 1` 1.9 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 72.6 → 78.5 ms (+8%) | 73.0 → 76.9 ms (+5%) | 125.2 → 131.5 ms (+5%) | 155.9 → 164.9 ms (+6%) |
| WebFetch | 11 | 21.1 → 21.3 ms (+1%) | 27.4 → 27.6 ms (+1%) | 44.5 → 45.1 ms (+1%) | 40.7 → 41.0 ms (+1%) |
| Read/Grep | 41 | 46.6 → 46.7 ms (+0%) | 51.2 → 51.3 ms (+0%) | 71.0 → 72.2 ms (+2%) | 64.9 → 65.1 ms (+0%) |
| Write/Edit | 63 | 55.6 → 56.0 ms (+1%) | 58.4 → 58.8 ms (+1%) | 80.8 → 79.4 ms (-2%) | 141.2 → 141.8 ms (+0%) |
| Monitor | 5 | 43.0 → 43.0 ms (+0%) | 56.6 → 57.3 ms (+1%) | 110.2 → 111.4 ms (+1%) | 115.1 → 117.6 ms (+2%) |
| All | 492 | 64.5 → 66.1 ms (+2%) | 68.1 → 71.2 ms (+5%) | 122.5 → 128.5 ms (+5%) | 143.5 → 150.4 ms (+5%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 71.7 → 77.6 ms (+8%) | 122.8 → 129.6 ms (+6%) | 145.0 → 153.6 ms (+6%) | 70.6 → 76.5 ms |
| config-guard.sh | 63 | 18.7 → 18.9 ms (+1%) | 39.4 → 40.1 ms (+2%) | 25.5 → 25.8 ms (+1%) | 17.6 → 17.8 ms |
| mod-gate.sh | 63 | 4.0 → 4.0 ms (-0%) | 14.4 → 14.7 ms (+2%) | 4.5 → 4.6 ms (+1%) | 2.9 → 2.9 ms |
| network-guard.sh | 11 | 20.6 → 20.6 ms (-0%) | 44.0 → 44.8 ms (+2%) | 31.8 → 32.1 ms (+1%) | 19.5 → 19.5 ms |
| secret-scanner.sh | 63 | 24.7 → 24.9 ms (+1%) | 69.4 → 69.6 ms (+0%) | 29.9 → 30.1 ms (+1%) | 23.6 → 23.8 ms |
| sensitive-file-guard.sh | 104 | 45.8 → 46.0 ms (+0%) | 64.0 → 64.0 ms (+0%) | 51.3 → 51.4 ms (+0%) | 44.7 → 44.9 ms |
| subagent-cache-guard.sh | 492 | 8.4 → 8.5 ms (+2%) | 8.9 → 9.0 ms (+2%) | 8.2 → 8.3 ms (+1%) | 7.3 → 7.4 ms |

Decisions: 491 of 492 payloads got the same answer on both sides.

| Payload | base | head |
|---|---|---|
| friction-gap-git-push-inside-sh-c `sh -c 'git push --force origin main'` | allow (silent) | deny (bash-guards.sh) |

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

## v1.4.2 (2026-11-14)

Merged since v1.4.1: 5 PRs.

### Security
- fix(guards): a heredoc is inside a substitution only when one is open or in doubt (#234)
- fix(guards): an opener line that leaves a substitution open is unreadable (#227)

### Compatibility
- contract: review Claude Code releases up to 2.1.325 (#235)
- install: remove a file the clone deleted, when install wrote it unchanged (#222)
- contract: review Claude Code releases up to 2.1.323 (#217)

### Benchmark vs v1.4.1


2026-11-14T14:09:28Z, Linux 7.0.0-1019-azure x86_64, AMD EPYC 7763 64-Core Processor, python 3.14.4. Corpus tests/bench-corpus.jsonl: 492 payloads (372 Bash, 36 Write, 31 Read, 23 Edit, 11 WebFetch, 10 Grep, 5 Monitor, 2 MultiEdit, 2 NotebookEdit), each run through both sides, alternating which side goes first. Hooks: the PreToolUse command hooks each side registers in config/settings.json, launched together as Claude Code does. Wait is from the first launch to the last exit, so hooks that share the cores pay for it; CPU is the sum of each hook's own. The per-hook table runs each hook alone. Process start here: `true` 0.7 ms, `bash -c :` 1.4 ms, `jq -n 1` 2.3 ms (p50 of 20), so only same-run comparisons are meaningful. A machine whose process start is slower pays it again for each process a hook starts: the last column is a hook's p50 past one `bash -c :`.

| Tool class | calls | wait p50 | wait mean | wait p95 | CPU mean |
|---|---:|---|---|---|---|
| Bash | 372 | 82.9 → 82.8 ms (-0%) | 82.5 → 83.0 ms (+1%) | 143.2 → 142.4 ms (-1%) | 177.6 → 178.5 ms (+0%) |
| WebFetch | 11 | 23.8 → 23.9 ms (+1%) | 31.1 → 31.4 ms (+1%) | 52.7 → 52.3 ms (-1%) | 46.4 → 46.9 ms (+1%) |
| Read/Grep | 41 | 50.2 → 50.6 ms (+1%) | 55.8 → 56.1 ms (+1%) | 79.4 → 81.4 ms (+3%) | 71.0 → 71.4 ms (+1%) |
| Write/Edit | 63 | 62.3 → 63.0 ms (+1%) | 65.8 → 65.9 ms (+0%) | 94.8 → 95.6 ms (+1%) | 162.0 → 162.7 ms (+0%) |
| Monitor | 5 | 51.0 → 50.1 ms (-2%) | 64.9 → 66.0 ms (+2%) | 129.7 → 130.8 ms (+1%) | 132.8 → 135.5 ms (+2%) |
| All | 492 | 71.5 → 72.5 ms (+1%) | 76.8 → 77.2 ms (+1%) | 139.5 → 137.4 ms (-1%) | 163.4 → 164.2 ms (+0%) |

| Hook | runs | wall p50 | wall p95 | CPU mean | p50 past bash start |
|---|---:|---|---|---|---|
| bash-guards.sh | 377 | 80.1 → 81.3 ms (+1%) | 140.8 → 141.5 ms (+1%) | 165.3 → 165.9 ms (+0%) | 78.7 → 79.9 ms |
| config-guard.sh | 63 | 20.4 → 20.6 ms (+1%) | 44.9 → 45.1 ms (+0%) | 28.4 → 28.7 ms (+1%) | 19.0 → 19.2 ms |
| mod-gate.sh | 63 | 4.4 → 4.4 ms (+1%) | 15.8 → 16.1 ms (+2%) | 5.0 → 5.0 ms (+1%) | 3.0 → 3.0 ms |
| network-guard.sh | 11 | 23.3 → 23.4 ms (+0%) | 51.8 → 51.3 ms (-1%) | 36.4 → 36.5 ms (+0%) | 22.0 → 22.1 ms |
| secret-scanner.sh | 63 | 26.9 → 27.2 ms (+1%) | 79.9 → 80.5 ms (+1%) | 33.0 → 33.3 ms (+1%) | 25.5 → 25.8 ms |
| sensitive-file-guard.sh | 104 | 49.6 → 50.0 ms (+1%) | 71.2 → 71.3 ms (+0%) | 56.1 → 56.5 ms (+1%) | 48.2 → 48.6 ms |
| subagent-cache-guard.sh | 492 | 9.2 → 9.3 ms (+1%) | 9.7 → 9.7 ms (+1%) | 9.1 → 9.1 ms (+1%) | 7.8 → 7.9 ms |

Decisions: 492 of 492 payloads got the same answer on both sides.

Gate: passed (p50 and p95 wait may not grow more than 20% and 5 ms, per class with at least 20 calls; every decision change must be intended).

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
