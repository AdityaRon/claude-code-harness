# Changelog

Releases are tagged `vMAJOR.MINOR.PATCH`. The release workflow
(`.github/workflows/release.yml`) writes each entry from the PRs merged since
the previous tag and the hook benchmark against it (`bin/hook-bench.py`); the
GitHub Release carries the same text. `bin/harness-update.sh` moves an
installed machine to the newest tag.

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
