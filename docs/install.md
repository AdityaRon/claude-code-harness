# Install, installed files and tests

What `install.sh` does, what it leaves in `~/.claude`, and how the harness is
tested. Moved from the README.

## What the installer does

- Merges into any existing `~/.claude/settings.json` (user keys preserved, allow/deny lists unioned, hooks owned by harness). Details in [customization.md](customization.md#what-an-install-keeps).
- Backs up the previous file as `settings.json.bak.<timestamp>`, and keeps the newest 10 (`CCH_KEEP_BACKUPS` changes the count).
- Folds in machine-local allow/deny rules from `~/.claude/local-settings/*.json` (see [customization.md](customization.md)).
- Runs `doctor.sh` to verify every hook after install.

Then open Claude Code and run `/hooks` to confirm everything is registered.

**On a new machine**, put the machine-local files in place before
`bash install.sh`: rules in `~/.claude/rules/local-*.md`, and allow rules for
work tools and hosts in `~/.claude/local-settings/<name>.json`. This repo is public and
ships neither, so they come from wherever you keep them, such as the repo that
holds your work skills. A machine that already has its rules in
`settings.json` keeps them, because the merge never removes an allow rule.

## File layout after install

As written by `install.sh` at a6197da, plus what the hooks and
`harness-update.sh` write as they run.
Paths inside `~/.claude` are flat: the grouping in the README's repo layout is
for reading the repo, not for the installed tree.

```
~/.claude/
  settings.json            ← merged with harness defaults (user keys preserved)
  settings.json.bak.<ts>   ← one per install, newest 10 kept
  hooks/                   ← every hooks/*.sh, lib.sh included, by glob
  statusline.sh            ← model, repo:branch, context, tokens, cost, rate limits, plan and wf links
  memory-verify.sh         ← checks memories against GitHub; run on demand, not a hook
  memory-fix.sh  memory-index.sh  memory-provenance.sh
  session-route.sh         ← which session owns this PR
  net-allowlist.sh  sandbox.sh  sandbox-trial.sh
  harness-update.sh        ← moves this machine to the newest release
  harness-update.conf      ← with_cli=1 or 0, from --with-cli or --no-cli
  harness-src/             ← harness-update.sh's own clone, made on its first run
  harness.version          ← version, commit, the clone it came from and its origin, install time
  harness-contract.version ← last_verified_version from config/upstream-contract.json
  skills/<name>/SKILL.md   ← memory-audit, memory-archive, pr-review, comms-hub
  skills/comms-hub/bin/    ← its scripts; config.example.toml sits beside its SKILL.md
  rules/*.md               ← copied from rules/; local-*.md and other files left alone
  local-settings/*.json    ← yours, read by install.sh and network-guard
  logs/
    audit.log              ← append-only audit trail, 0600, rotated
    harness-update.log     ← scheduled update runs
  transcripts/
    transcript_<trigger>_<ts>_<session>.jsonl  ← pre-compact backups, newest 20
  state/
    sessions/<session_id>.json  ← per-session edit snapshot, 0600, newest 50 kept
    sessions/memory-index/      ← when session-start last reordered each memory index
    plans/<session_id>.path     ← pointer to the session's latest rendered plan (statusline link)
    harness-latest              ← newest release harness-update.sh fetched
    cli-upgraded                ← harness-update.sh's last CLI upgrade and the pids it cut off
    effort-high.migrated        ← the one-time move of an installed xhigh effortLevel to high has run
  plans-html/
    plan-<ts>.html         ← rendered plan, opened in browser, newest 50 kept
```

## Rules and skills it installs

Rules go to `~/.claude/rules/` and load in every session in every project:

- `prose-and-comments.md`: length, voice, and the reader.
- `collaboration.md`: before replying, and handing work back.
- `working-agreement.md`: keep going, evidence, cost, finishing the loop.
- `environment.md`: git and Claude Code facts that hold on this machine.
- `python-tests.md`: path-scoped, so it loads only when Claude opens Python.

Skills go to `~/.claude/skills/<name>/SKILL.md`:

- `memory-audit`: check memories against external truth.
- `memory-archive`: relieve an over-limit index; proposes, never writes.
- `pr-review`: writing, answering and requesting a review; loads only when a
  review is in play.
- `comms-hub`: the tick for the one session that speaks on Slack for all the
  others. Its `bin/` scripts and `config.example.toml` install with it; its
  tests stay in the clone.

## comms-hub's config and state

Neither lives in this repo or in `~/.claude`, and `install.sh` creates neither:

- Config: `~/.config/comms-hub/config.toml` (`$XDG_CONFIG_HOME` is honoured),
  written by `hub.py init` (in `~/.claude/skills/comms-hub/bin/`, run with the
  Python that `python.sh` beside it prints) from the example beside the skill,
  with your GitHub login and this machine's time zone filled in; it refuses to
  overwrite one. It holds your logins, Slack ids and session names, so it never
  goes in a repo.
- State: `~/.local/state/comms-hub/` (`$XDG_STATE_HOME`, or `state_dir` in the
  config): the daily log, the messages as sent, the Slack snapshot, the gate's
  pass records, the drafts held between ticks, the session's preflight record
  and the feedback backlog.

If you keep your home directory's dotfiles in git, ignore both:

```gitignore
.config/comms-hub/
.local/state/comms-hub/
```

Then `bash doctor.sh --skill comms-hub` checks every prerequisite: `gh` signed
in as the config's login, Python 3.10+ with a TOML reader, `jq`, a connected
Slack MCP server (any server whose name contains `slack`, added with
`claude mcp add` or `/mcp`), SendMessage and ListAgents not denied, and the
comms session's own record of its tools and trigger. The last one fails until
the comms session has run step 0 of the skill once; the others are fixable
before that, on macOS or Linux, and each failure line says how.

## Testing the harness

```bash
bash doctor.sh
```

Runs every test in `tests/*.test.sh` and prints a summary. The suite covers known bypass attempts (symlinked dotfiles, quoted paths, commit messages containing trigger strings, `git -c`/`-C` global-option prefixes, shell-body git aliases, interpreter inline-code escapes and heredocs, combined interpreter flags, `@file` upload variants, stage-then-exfil copies, and mutating HTTP methods), a **fail-closed** check that every Bash/file guard denies when jq is unavailable, the plan-renderer (UTF-8 round-trip, script-injection containment, retention cap), and the settings merge (`config/merge-settings.jq`: that a stale `defaultMode` is replaced, allow/deny lists are unioned, user keys survive, and re-running the installer is a no-op).

`tests/comms-hub.test.sh` runs the comms-hub skill's Python tests with the first Python 3.10+ on PATH that has a TOML reader. Their mutation list is a separate run (150 mutations in 237 s on an Apple M2, 2026-10-22): `python3.11 skills/comms-hub/tests/run.py --mutate` applies each mutation a test file's docstring names to a temp copy of the skill and fails if that file stays green.

CI (`.github/workflows/ci.yml`) runs `doctor.sh` on both Linux and macOS, with Python 3.12, and lints every hook with `shellcheck` on each push and PR. On a PR it also runs the hook benchmark against the base branch; see [releases.md](releases.md).
