# Claude Code Harness

Hooks, settings and rules for Claude Code, and the skills from
[claude-code-skills](https://github.com/AdityaRon/claude-code-skills) at a pinned
release, installed into `~/.claude` once per machine, so they apply in every project without touching repo files.
PreToolUse guards stop actions that are hard to undo or that leak secrets
(force pushes, `rm -rf` outside scratch, reading `.env`, writing a token to
disk), ask you about a short list (cluster writes, request bodies to unknown
hosts, inline code that reads the environment), and let everything else run
under auto mode. Every deny and ask is a line in `~/.claude/logs/audit.log`.

What the guards cost: `python3 tools/hook-bench.py --base v1.0.0 --head HEAD`, run
at 4f4dae0 on an Apple M2 with macOS 26.6.2 on 2026-10-17 UTC, measured a Bash
call waiting 54.5 ms at p50 and 108.7 ms at p95 over the 321 Bash payloads in
`tests/bench-corpus.jsonl` (83.4 and 124.1 ms at v1.0.0 in the same run). Other
machines will differ; from v1.0.1 on, each release's `CHANGELOG.md` entry carries
a same-run table against the previous tag (`.github/workflows/release.yml`).
Asks cost more time: in 49 days of one machine's transcripts
(`docs/permission-friction.md`), 849 of 872 guard asks were approved, and the
median approved ask held its call 133 s, against 5 s for a Bash call with no prompt.
On your own machine, `bash doctor.sh --latency` reads each hook's wall time per day from
Claude Code's transcripts, and `bash doctor.sh --census` counts claude processes and their memory.

## Install and update

Needs macOS or Linux with bash, `jq` (the guards fail closed without it), `gh`,
`python3` (for `tools/hook-bench.py` and `tools/permission-friction.py`; 3.10 or
newer with a TOML reader for the comms-hub and skill-forge skills) and `claude`.

```bash
git clone https://github.com/AdityaRon/claude-code-harness.git
cd claude-code-harness
bash install.sh
```

- Merges into your `~/.claude/settings.json`: your keys kept, allow, ask and deny lists unioned, the harness's hook entries owned by the harness.
- Backs the previous file up as `settings.json.bak.<timestamp>` and folds in `~/.claude/local-settings/*.json`.
- Clones claude-code-skills into `~/.claude/skills-src` at the release
  `config/skills.pin` names, verifies its commit and runs its `install.sh`
  (`bin/skills-sync.sh`). If that fetch fails, the installed skills stay as
  they were, the install says so and finishes, and `harness-update.sh` retries.
- Runs `doctor.sh` to verify every hook.

**A fork, or a fresh copy.** Clone your own copy instead, then run
`tools/fork-setup.sh` from it. It reports what GitHub needs before this repo's
workflows run: Actions on, the workflows GitHub turns off on a fork back on,
Actions allowed to open pull requests (Release and Upstream drift open them),
and the `CLAUDE_CODE_OAUTH_TOKEN` secret. `tools/fork-setup.sh --apply` turns on
what is off; the secret you set yourself, with `/install-github-app` in Claude
Code.

Then run `/hooks` in Claude Code to confirm everything is registered. On a new
machine, put your `~/.claude/rules/local-*.md` and `~/.claude/local-settings/`
files in place first; this public repo ships neither. More in
[docs/install.md](docs/install.md), including what lands in `~/.claude`.

**Updating.** `~/.claude/harness-update.sh` checks the newest release tag out
of its own clone, runs `doctor.sh`, and installs only on green; `--schedule` runs
it at 01:17, 07:17, 13:17 and 19:17 local time and `--unschedule` stops that.
`--with-cli` also upgrades a Homebrew-cask Claude Code on each run. It leaves
alone an install from a clone with local changes or commits, so update that
one with `git pull && bash install.sh`. Releases are `vMAJOR.MINOR.PATCH` tags, each
with a GitHub Release and a `CHANGELOG.md` entry. The Release workflow tags
main after each daily Upstream drift run when anything but `CHANGELOG.md`
changed, gated on `doctor.sh` and, when `hooks/` or `config/settings.json`
changed, the hook benchmark: [docs/releases.md](docs/releases.md).

**Keeping up with Claude Code.** Claude Code auto-updates, so what the harness
relies on (hook events, the permission mode, memory index limits) is checked daily
for breakage by `tools/upstream-check.sh`: [docs/upstream-contract.md](docs/upstream-contract.md).

**Testing.** `bash doctor.sh` runs every suite in `tests/`; a new suite sources
`tests/lib.sh` for `pass` and `fail`. `--smoke` runs the few in `tests/smoke.list`
that name every wired hook, which is what `install.sh` runs (`install.sh --full`
runs all). A suite gets 30 minutes (`CCH_SUITE_TIMEOUT`); the summary lists wall
times slowest first and names a suite stopped by a signal KILLED and one past its
limit TIMEOUT, apart from failures. CI runs doctor on Linux and macOS, lints
the scripts and suites with shellcheck, compiles every Python file with macOS's /usr/bin/python3 (3.9),
and benchmarks each PR's hooks against main. The suites that read the skills
(`tests/skills-sync.test.sh`, `tests/token-shapes.test.sh` and part of
`tests/heredoc-openers.test.sh`) take them from a claude-code-skills clone at the
pinned commit, `$CCH_SKILLS_CLONE` or `~/.claude/skills-src`; without one they
skip, except in CI, which clones it.

## What it blocks, asks and logs

| Hook | Runs on | Behaviour |
|---|---|---|
| `bash-guards` | Bash, Monitor | Runs the seven Bash guards below as one hook: one parse of the call, each guard a fork, deny over ask over allow. A guard that dies is a deny naming it. `~/.claude/hooks/bash-guards.skip` switches one off ([docs/guards.md](docs/guards.md)) |
| `env-guard` | Bash | Deny: reading, dumping, copying or sending env values and dotfiles (`cat .env`, `printenv`, `nc`) |
| `sensitive-file-guard` | Read, Grep, file writes | Deny: `.env`, keys, SSH and cloud credentials, credential folders. Ask: a Grep at or above your home folder |
| `secret-scanner` | file writes | Deny: high-confidence token shapes (AWS, GitHub, Slack, Stripe, Google, Anthropic, OpenAI, PEM) in written content |
| `git-guard` | Bash | Deny: force push in any spelling, `reset --hard`, `clean -f`, hook tampering, a broad `git add` that would stage a credential file or that it cannot check. Ask: deleting a remote branch whose tip no other ref holds, remote changes, stash drop. Runs: local branch deletes, `worktree remove --force`, identity and signing config |
| `rm-guard` | Bash | Deny: recursive `rm` of home, root or a top-level folder, and `rm -rf` outside the session's scratch folder |
| `config-guard` | Bash, file writes | Ask: writes to installed hooks, settings, the Bash guards' skip file, shell startup files, `~/.gitconfig`, LaunchAgents, Bash writes into a mod Claude Code loads by itself, and copies or extractions into a `.claude` folder. Deny: moving or emptying `~/.claude` |
| `network-guard` | Bash | Deny: file uploads and pipe-to-shell. Ask: request bodies, `DELETE`, `curl`/`wget` to hosts off the allowlist, `scp`/`rsync`, local servers. WebFetch is not guarded |
| `interpreter-guard` | Bash | Ask: inline code (`python -c`, `node -e`, heredocs) that touches env, dotfiles, sockets or an env-dumping command, and long inline scripts |
| `kubectl-guard` | Bash | Ask: every mutating verb wherever it sits, secret reads, and any subcommand it cannot classify |
| `subagent-cache-guard` | a subagent's tool calls, SubagentStop | Deny: a subagent's tool calls once its prompt cache went cold 5 times in one run (`CLAUDE_SUBAGENT_MAX_COLD_STARTS`), until it replies with where it got to. Main sessions are left alone |
| `mod-gate` | file writes | Deny: a mod hooking `tool.check` or another permission override. Ask: a mod it cannot review. Anything else it hooks or calls, outside the guards included, is shown in a notice |
| `audit` | most events | Log: edits, Bash, MCP calls (field names only), agents, messages, artifacts, failures, auto-mode denials, model switches, settings changes, session end |
| `memory-lint` | file writes | Advise: name, type, description, `verify:` block and index tier of a memory file |
| `comment-budget` | file writes | Advise: a comment block an edit grew past 6 lines |
| `tcc-check` | Bash results and failures | Advise: names macOS privacy control (TCC) when a Bash call prints an "Operation not permitted" error (a tool's, zsh's or python's) for a path in `~/Desktop`, `~/Documents`, `~/Downloads` or iCloud Drive, or for no path while the cwd (or a `cd` in the command) is in one. A line quoting one, in backticks or after grep -n's `file:line:`, is not an error; a log line printed whole still is |
| `session-start` | SessionStart | Inject: branch, status and recent commits; on resume, files that drifted since the last session |
| `session-snapshot` | Stop, SessionEnd | Record: hashes of the files the session edited, for the resume drift check |
| `pre-compact` | PreCompact | Back up: the transcript before compaction, newest 20 kept |
| `notify` | Notification | Notify: a desktop alert titled with the session name |
| `plan-to-html` | ExitPlanMode | Render: the plan as HTML in your browser, without delaying the prompt |
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

- **A Bash guard off:** put its name on a line of `~/.claude/hooks/bash-guards.skip` (`kubectl-guard`, say); `config-guard` asks before Claude writes that file. Names off the shipped list are ignored, so the file can only switch guards off ([docs/guards.md](docs/guards.md)).
- **Any other hook off:** there is no per-hook switch. Deleting its entry from `~/.claude/settings.json` lasts until the next install. To keep it off, remove it from `config/settings.json` in your clone; `harness-update.sh` leaves an install from a changed clone alone, so update with `git pull && bash install.sh`.
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

## Skills

The skills live in [claude-code-skills](https://github.com/AdityaRon/claude-code-skills),
split out of this repo at 6699a5c: comms-hub and slack-draft (one session speaks
on Slack for all of them, with a panel mod beside its chat), skill-forge (one
skill per recurring question in a new job), pr-review, memory-audit and
memory-archive. Their protocols, tests and changelog are there.

- `config/skills.pin` names the release this harness installs: its URL, tag and
  commit. `install.sh` and `harness-update.sh` both install it through
  `bin/skills-sync.sh`, so `harness-update.sh` stays the one entry point.
  `HARNESS_SKILLS_URL` points at another clone of it, as `HARNESS_UPDATE_URL`
  does for this repo; `HARNESS_SKILLS_CLONE` moves `~/.claude/skills-src`.
- That repo's `install.sh` owns `~/.claude/skills` and skill-forge's templates in
  `~/.local/share/skill-forge/`, and records what it wrote in
  `~/.claude/skills.manifest`. This repo writes nothing there and removes nothing
  there (`tools/pickup-report.sh`).
- Several skills run tools this repo installs in `~/.claude`: `memory-verify.sh`,
  `memory-index.sh`, `session-route.sh` and `spend-report.py`.
- `bash doctor.sh --skill comms-hub` runs that skill's prerequisite check from
  `~/.claude/skills-src`.

## Design choices

- A hook sees the whole command and a permission rule sees only a prefix, so enforcement lives in the guards and the deny list is a backstop ([docs/permissions.md](docs/permissions.md)).
- Guards fail closed: no jq or unparsable input denies (`tests/fail-closed.test.sh`), and a crash or timeout blocks through `"onFailure": "block"` (Claude Code 2.1.295 and later). Inside `bash-guards`, a guard that dies is a deny naming it, and an early exit of the hook itself is made exit 2 (`tests/bash-guards.test.sh`).
- No `autoMode` block ships: setting a category appears to replace Claude Code's own rules for it, 65 `soft_deny` rules by the `claude auto-mode defaults` count in [docs/auto-mode.md](docs/auto-mode.md).
- Every deny and ask is an audit line; MCP calls are logged, not guarded ([docs/hooks.md](docs/hooks.md)).
- The memory tools propose and never delete ([docs/memory.md](docs/memory.md)), and what it relies on in Claude Code is checked daily for breakage ([docs/upstream-contract.md](docs/upstream-contract.md)).

## Known limitations

- Regex guards can be evaded by a determined agent; the OS sandbox is the real containment.
- A Claude Code mod (2.1.287+) can override the guards; `mod-gate` reviews only mods written through the file tools, and `config-guard` asks before a Bash write into one Claude Code loads by itself.
- MCP connectors are logged, not guarded.
- In auto mode the classifier, by judgment, decides everything no guard or rule names.

More, including what fails closed: [docs/known-limitations.md](docs/known-limitations.md).

## Repo layout

The install and test entry points, the changelog and the license sit at the root;
everything else is grouped by what it is.

```
install.sh  doctor.sh    ← install once per machine; run every suite in tests/
CHANGELOG.md             ← one entry per release
LICENSE                  ← MIT
bin/                     ← every file installed flat to ~/.claude by install.sh
  statusline.sh  harness-update.sh  net-allowlist.sh  sandbox.sh  sandbox-trial.sh
  skills-sync.sh         ← installs the claude-code-skills release config/skills.pin names
  memory-verify.sh  memory-fix.sh  memory-index.sh  memory-provenance.sh
  session-route.sh       ← which session owns this PR (docs/session-routing.md)
  relocate-clones.sh     ← moves a clone out of ~/Desktop, ~/Documents or ~/Downloads (docs/known-limitations.md)
  spend-report.py        ← what sessions, subagents and loop ticks cost, from local transcripts
tools/                   ← run from the clone only, by CI, releases and whoever maintains a fork
  upstream-check.sh      ← the daily breakage check
  fork-setup.sh          ← what a fork's GitHub settings need before the workflows run
  hook-bench.py  release-notes.sh  ← the release benchmark and notes
  permission-friction.py ← which guard asks and denies cost the most, from local transcripts
  hook-latency.py        ← each hook's wall time per day, from local transcripts (doctor.sh --latency)
  hooknames.py           ← names the hook a transcript record numbers, for the two above
  shadow-report.py       ← what each shadowed guard or rule would have decided, and what happened instead
  session-census.py      ← claude processes, their memory, and idle background jobs (doctor.sh --census)
  pickup-report.sh       ← after an install, how running sessions pick up each change; install.sh runs it with
                           --prune, which removes what install wrote that the clone deleted
config/                  ← settings.json, merge-settings.jq, retired-rules.json, upstream-contract.json,
                           skills.pin
hooks/                   ← one file per hook, plus lib.sh, which sources lib/: command, paths,
                           scratch, io, inline, net, host and shadow; bash-guards.sh runs the Bash guards
rules/                   ← installed to ~/.claude/rules, loaded in every session
  prose-and-comments.md  collaboration.md  working-agreement.md  environment.md
  python-tests.md        ← path-scoped: loads only when Claude opens Python
tests/                   ← <name>.test.sh for most hooks, tools and .github scripts; host-binary covers
                           tcc-check and the host check; install-*, fail-closed, guard-latency,
                           heredoc-openers, repo-layout, token-shapes and workflow-gates cut across
                           files; lib.sh is their shared pass/fail; bench-corpus.jsonl
                           feeds hook-bench; doctor tests doctor.sh's own report; smoke.list is the
                           set install.sh verifies with (doctor.sh --smoke)
docs/
  install.md  releases.md  upstream-contract.md  guards.md  hooks.md
  permissions.md  auto-mode.md  customization.md  known-limitations.md
  memory.md              ← what Claude Code's memory does now, and each harness tool's verdict
  session-routing.md     ← routing a PR to its session; holds only in single-author repos
  permission-friction.md ← which guard asks and denies cost the most, and why
  shadow-mode.md         ← the guards and rules on trial (#237): what they log, how step 9 reads the report
  permission-friction-cases.jsonl  ← cases tools/permission-friction.py --cases replays
  history/               ← superseded memory research the memory skills still cite
```

Everything here is portable because the repo is public; machine-local rules and
allow rules live in `~/.claude/rules/local-*.md` and `~/.claude/local-settings/`
([docs/customization.md](docs/customization.md)).

## License

MIT, in [LICENSE](LICENSE).
