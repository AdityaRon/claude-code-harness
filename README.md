# Claude Code Harness

Hooks, settings, rules and skills for Claude Code, installed into `~/.claude`
once per machine, so they apply in every project without touching repo files.
PreToolUse guards stop actions that are hard to undo or that leak secrets
(force pushes, `rm -rf` outside scratch, reading `.env`, writing a token to
disk), ask you about a short list (cluster writes, request bodies to unknown
hosts, inline code that reads the environment), and let everything else run
under auto mode. Every deny and ask is a line in `~/.claude/logs/audit.log`.

What the guards cost: `python3 bin/hook-bench.py --base v1.0.0 --head HEAD`, run
at 4f4dae0 on an Apple M2 with macOS 26.6.2 on 2026-10-17 UTC, measured a Bash
call waiting 54.5 ms at p50 and 108.7 ms at p95 over the 321 Bash payloads in
`tests/bench-corpus.jsonl` (83.4 and 124.1 ms at v1.0.0 in the same run). Other
machines will differ; from v1.0.1 on, each release's `CHANGELOG.md` entry carries
a same-run table against the previous tag (`.github/workflows/release.yml`).
Asks cost more time: in 49 days of one machine's transcripts
(`docs/permission-friction.md`), 849 of 872 guard asks were approved, and the
median approved ask held its call 133 s, against 5 s for a Bash call with no prompt.

## Install and update

Needs macOS or Linux with bash, `jq` (the guards fail closed without it), `gh`,
`python3` (for `bin/hook-bench.py` and `bin/permission-friction.py`) and `claude`.

```bash
git clone https://github.com/AdityaRon/claude-code-harness.git
cd claude-code-harness
bash install.sh
```

- Merges into your `~/.claude/settings.json`: your keys kept, allow and deny lists unioned, the harness's hook entries owned by the harness.
- Backs the previous file up as `settings.json.bak.<timestamp>` and folds in `~/.claude/local-settings/*.json`.
- Runs `doctor.sh` to verify every hook.

Then run `/hooks` in Claude Code to confirm everything is registered. On a new
machine, put your `~/.claude/rules/local-*.md` and `~/.claude/local-settings/`
files in place first; this public repo ships neither. More in
[docs/install.md](docs/install.md), including what lands in `~/.claude`.

**Updating.** `~/.claude/harness-update.sh` checks the newest release tag out
of your clone, runs `doctor.sh`, and installs only on green; `--schedule` runs
it at 01:17, 07:17, 13:17 and 19:17 local time and `--unschedule` stops that.
`--with-cli` also upgrades a Homebrew-cask Claude Code on each run. It refuses
a clone with local changes or commits, so update that one with
`git pull && bash install.sh`. Releases are `vMAJOR.MINOR.PATCH` tags, each
with a GitHub Release and a `CHANGELOG.md` entry. The Release workflow tags
main after each daily Upstream drift run when anything but `CHANGELOG.md`
changed, gated on `doctor.sh` and, when `hooks/` or `config/settings.json`
changed, the hook benchmark: [docs/releases.md](docs/releases.md).

**Keeping up with Claude Code.** Claude Code auto-updates, so the facts the
harness relies on are pinned in `config/upstream-contract.json` and checked daily
by `bin/upstream-check.sh`: [docs/upstream-contract.md](docs/upstream-contract.md).

**Testing.** `bash doctor.sh` runs every suite in `tests/`. CI runs it on Linux
and macOS, lints the scripts with shellcheck, and benchmarks each PR's hooks
against main.

## What it blocks, asks and logs

| Hook | Runs on | Behaviour |
|---|---|---|
| `env-guard` | Bash | Deny: reading, dumping, copying or sending env values and dotfiles (`cat .env`, `printenv`, `nc`) |
| `sensitive-file-guard` | Read, Grep, file writes | Deny: `.env`, keys, SSH and cloud credentials, credential folders. Ask: a Grep at or above your home folder |
| `secret-scanner` | file writes | Deny: high-confidence token shapes (AWS, GitHub, Slack, Stripe, Google, Anthropic, OpenAI, PEM) in written content |
| `git-guard` | Bash | Deny: force push in any spelling, `reset --hard`, `clean -f`, hook tampering, a broad `git add` that would stage a credential file or that it cannot check. Ask: deleting a local or remote branch whose tip no other ref holds, remote and identity changes |
| `rm-guard` | Bash | Deny: recursive `rm` of home, root or a top-level folder, and `rm -rf` outside the session's scratch folder |
| `config-guard` | Bash, file writes | Ask: writes to installed hooks, settings, shell startup files, `~/.gitconfig`, LaunchAgents. Deny: moving or emptying `~/.claude` |
| `network-guard` | Bash, WebFetch | Deny: file uploads and pipe-to-shell. Ask: request bodies, `DELETE`, hosts off the allowlist, `scp`/`rsync`, local servers |
| `interpreter-guard` | Bash | Ask: inline code (`python -c`, `node -e`, heredocs) that touches env, dotfiles, sockets or an env-dumping command, and long inline scripts |
| `kubectl-guard` | Bash | Ask: every mutating verb wherever it sits, secret reads, and any subcommand it cannot classify |
| `mod-gate` | file writes | Deny: a mod hooking `tool.check` or another permission override. Ask: a mod it cannot review, or one that runs code outside the guards |
| `audit` | most events | Log: edits, Bash, MCP calls (field names only), agents, messages, artifacts, failures, auto-mode denials, model switches, settings changes, session end |
| `memory-lint` | file writes | Advise: name, type, description, `verify:` block and index tier of a memory file |
| `comment-budget` | file writes | Advise: a comment block an edit grew past 6 lines |
| `session-start` | SessionStart | Inject: branch, status and recent commits; on resume, files that drifted since the last session |
| `session-snapshot` | Stop, SessionEnd | Record: hashes of the files the session edited, for the resume drift check |
| `pre-compact` | PreCompact | Back up: the transcript before compaction, newest 20 kept |
| `notify` | Notification | Notify: a desktop alert titled with the session name |
| `plan-to-html` | ExitPlanMode | Render: the plan as HTML in your browser, without delaying the prompt |
| `workflow-record` | Workflow | Record: the workflow script's path, linked from the status line |
| status line | every refresh | Show: model and effort, branch, context, cost, rate limits, plan and workflow links, a cold-cache warning |

A guard's deny runs before the permission system, so it holds in every
permission mode (a loaded mod is the exception). A guard's ask still comes to
you in auto mode: Claude Code's [permission-modes doc](https://code.claude.com/docs/en/permission-modes)
says auto mode "still shows you those prompts". The auto-mode classifier
decides only what no guard or rule names. Every row in full:
[docs/guards.md](docs/guards.md), [docs/hooks.md](docs/hooks.md),
[docs/auto-mode.md](docs/auto-mode.md).

## Turning things off and customizing

What `install.sh` does with a value you set, from `config/merge-settings.jq`:

| Setting | Shipped | Install keeps yours? |
|---|---|---|
| `permissions.defaultMode` | `auto` | No: replaced on every install, with a notice |
| `permissions.allow`, `permissions.deny` | scoped lists | Yes: unioned with the shipped lists, minus `config/retired-rules.json` |
| `hooks` | the harness's entries | Yours kept; the harness's own entries rewritten |
| `statusLine` | `~/.claude/statusline.sh` | No: rewritten on every install |
| `sandbox` | off, with a domain allowlist | Yes, per key; a list you set replaces the shipped list |
| `env` | audit log, transcript folder, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Yes, per key |
| `effortLevel` | `high` | Yes, after one move of an installed `xhigh` to `high` (marker `~/.claude/state/effort-high.migrated`) |
| `autoDreamEnabled` | `true` | Yes: `false` keeps auto-dream off ([docs/memory.md](docs/memory.md)) |
| `syncClaudeAiSkills`, `syncClaudeAiPlugins` | `false` | Yes |
| `remoteControlAtStartup` and the other top-level switches ([docs/permissions.md](docs/permissions.md)) | `true` | Yes |

- **A hook off:** there is no per-hook switch. Deleting its entry from `~/.claude/settings.json` lasts until the next install. To keep it off, remove it from `config/settings.json` in your clone; `harness-update.sh` refuses a changed clone, so update with `git pull && bash install.sh`.
- **Auto mode off:** `claude --permission-mode manual` for one session. Every install rewrites `permissions.defaultMode`, so to keep it off set `"manual"` in your clone's `config/settings.json`, as for a hook.
- **Your own hooks:** a script in `~/.claude/hooks` under a name this repo does not use, plus its entry in `~/.claude/settings.json`. Installs keep both.
- **Allow rules for work tools:** `~/.claude/local-settings/<name>.json`; only its `permissions.allow` and `permissions.deny` are read.
- **Hosts:** `~/.claude/net-allowlist.sh candidates 30` lists, from the audit log, hosts network-guard asked about in 30 days; `add <host>` allows GETs to it, `add --body <host>` request bodies too; `list` and `remove` show and drop entries.
- **Environment knobs**, under `env` in settings unless noted:
  - `CLAUDE_AUDIT_LOG`: where the audit log goes.
  - `CLAUDE_PLANS_HTML_DIR`, `CLAUDE_PLAN_HTML_NO_OPEN=1`: where plans render, and whether a browser opens.
  - `CLAUDE_EDITOR_URI`: the editor the status line's `wf` link opens.
  - `CLAUDE_NET_ALLOWLIST`: extra hosts for network-guard, per project.
  - `CLAUDE_CODE_AUTO_COMPACT_WINDOW`: when auto-compact fires; a bare integer.
  - `CCH_KEEP_BACKUPS`, in the shell that runs `install.sh`: how many `settings.json` backups it keeps (default 10).
- **Sandbox:** run `~/.claude/sandbox.sh on`, `off` or `status` yourself (a `!` message or a terminal), then ask Claude to run `~/.claude/sandbox-trial.sh`.

Each of these in full: [docs/customization.md](docs/customization.md).

## Design choices

- A hook sees the whole command and a permission rule sees only a prefix, so enforcement lives in the guards and the deny list is a backstop ([docs/permissions.md](docs/permissions.md)).
- Guards fail closed: no jq or unparsable input denies (`tests/fail-closed.test.sh`), and a crash or timeout blocks through `"onFailure": "block"` (Claude Code 2.1.295 and later).
- No `autoMode` block ships: setting a category appears to replace Claude Code's own rules for it, 65 `soft_deny` rules by the `claude auto-mode defaults` count in [docs/auto-mode.md](docs/auto-mode.md).
- Every deny and ask is an audit line; MCP calls are logged, not guarded ([docs/hooks.md](docs/hooks.md)).
- The memory tools propose and never delete ([docs/memory.md](docs/memory.md)), and the upstream facts are a contract checked daily ([docs/upstream-contract.md](docs/upstream-contract.md)).

## Known limitations

- Regex guards can be evaded by a determined agent; the OS sandbox is the real containment.
- A Claude Code mod (2.1.287+) can override the guards; `mod-gate` reviews only mods written through the file tools.
- MCP connectors are logged, not guarded.
- In auto mode the classifier, by judgment, decides everything no guard or rule names.

More, including what fails closed: [docs/known-limitations.md](docs/known-limitations.md).

## Repo layout

The install and test entry points and the changelog sit at the root; everything
else is grouped by what it is.

```
install.sh  doctor.sh    ← install once per machine; run every suite in tests/
CHANGELOG.md             ← one entry per release
bin/                     ← installed to ~/.claude, or run from the clone
  statusline.sh  harness-update.sh  net-allowlist.sh  sandbox.sh  sandbox-trial.sh
  memory-verify.sh  memory-fix.sh  memory-index.sh  memory-provenance.sh
  session-route.sh       ← which session owns this PR (docs/session-routing.md)
  upstream-check.sh      ← the daily drift check
  hook-bench.py  release-notes.sh  ← the release benchmark and notes
  permission-friction.py ← which guard asks and denies cost the most, from local transcripts
config/                  ← settings.json, merge-settings.jq, retired-rules.json, upstream-contract.json
hooks/                   ← one file per hook, plus shared lib.sh
rules/                   ← installed to ~/.claude/rules, loaded in every session
  prose-and-comments.md  collaboration.md  working-agreement.md  environment.md
  python-tests.md        ← path-scoped: loads only when Claude opens Python
skills/                  ← memory-audit/, memory-archive/, pr-review/
tests/                   ← one <name>.test.sh per hook or script, plus bench-corpus.jsonl
docs/
  install.md  releases.md  upstream-contract.md  guards.md  hooks.md
  permissions.md  auto-mode.md  customization.md  known-limitations.md
  memory.md              ← what Claude Code's memory does now, and each harness tool's verdict
  session-routing.md     ← routing a PR to its session; holds only in single-author repos
  permission-friction.md ← which guard asks and denies cost the most, and why
  permission-friction-cases.jsonl  ← cases bin/permission-friction.py --cases replays
  history/               ← superseded memory research the skills still cite
```

Everything here is portable because the repo is public; machine-local rules and
allow rules live in `~/.claude/rules/local-*.md` and `~/.claude/local-settings/`
([docs/customization.md](docs/customization.md)).
