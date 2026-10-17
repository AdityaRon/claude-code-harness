# Changelog

Releases are tagged `vMAJOR.MINOR.PATCH`. The release workflow
(`.github/workflows/release.yml`) writes each entry from the PRs merged since
the previous tag and the hook benchmark against it (`bin/hook-bench.py`); the
GitHub Release carries the same text. `bin/harness-update.sh` moves an
installed machine to the newest tag.

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
