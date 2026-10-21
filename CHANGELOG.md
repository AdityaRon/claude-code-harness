# Changelog

Releases are tagged `vMAJOR.MINOR.PATCH`. The release workflow
(`.github/workflows/release.yml`) writes each entry from the PRs merged since
the previous tag and the hook benchmark against it (`bin/hook-bench.py`); the
GitHub Release carries the same text. `bin/harness-update.sh` moves an
installed machine to the newest tag.

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
