# Hooks

Every hook the harness wires, then the audit, context and readability hooks in
detail, as registered in `config/settings.json`. Each guard in detail is in
[guards.md](guards.md).

## Every hook

| Hook | Runs on | Behaviour |
|---|---|---|
| `bash-guards` | Bash, Monitor | Runs the seven Bash guards below as one hook: one parse of the call, each guard a fork, deny over ask over allow. A guard that dies is a deny naming it. `~/.claude/hooks/bash-guards.skip` switches one off ([guards.md](guards.md)) |
| `env-guard` | Bash | Deny: reading, dumping, copying or sending env values and dotfiles (`cat .env`, `printenv`, `nc`). Shadow: a bare `env` |
| `sensitive-file-guard` | Read, Grep, file writes | Deny: `.env`, keys, SSH and cloud credentials, credential folders. Ask: a Grep at or above your home folder |
| `secret-scanner` | file writes | Deny: high-confidence token shapes (AWS, GitHub, Slack, Stripe, Google, Anthropic, OpenAI, PEM) in written content |
| `git-guard` | Bash | Deny: force push in any spelling, `reset --hard`, `clean -f`, hook tampering, a broad `git add` that would stage a credential file or that it cannot check. Ask: deleting a remote branch whose tip no other ref holds, remote changes, stash drop. Runs: local branch deletes, `worktree remove --force`, identity and signing config |
| `rm-guard` | Bash | Deny: recursive `rm` of home, root or a top-level folder. Ask: `disk-space.py` with `--apply`, in any spelling. Shadow: `rm -rf` outside the session's scratch folder |
| `config-guard` | Bash, file writes | Ask: writes to installed hooks, settings, the Bash guards' skip file, shell startup files, `~/.gitconfig`, LaunchAgents, Bash writes into a mod Claude Code loads by itself, and copies or extractions into a `.claude` folder. Deny: moving or emptying `~/.claude` |
| `network-guard` | Bash | Deny: file uploads and pipe-to-shell. Ask: edits to the machine-local network allowlist. Shadow: request bodies, `DELETE`, `curl`/`wget` to hosts off the allowlist, `scp`/`rsync`, local servers. WebFetch is not guarded |
| `interpreter-guard` | Bash | Shadow: inline code (`python -c`, `node -e`, heredocs) that touches env, dotfiles, sockets or an env-dumping command, and long inline scripts. Auto mode drops `Bash(python3:*)`, so its classifier sees them |
| `kubectl-guard` | Bash | Asks on a Secret read in any spelling (`get Secret`, `describe secret`, a kind from xargs), on kubeconfig credentials and on kubectl behind a function. Its other verb rules are in shadow: read verbs are allowed by prefix, and native ask rules in `config/settings.json` ask before every mutating verb, verb first or flags first |
| `subagent-cache-guard` | a subagent's tool calls, SubagentStop | Deny: a subagent's tool calls once its prompt cache went cold 5 times in one run (`CLAUDE_SUBAGENT_MAX_COLD_STARTS`), until it replies with where it got to. Main sessions are left alone |
| `peer-redirect` | SendMessage | Deny and redirect: a send to a Remote Control address (`bridge:session_…`) whose session is running on this machine, pointing the model at that session's ListAgents `name [ref]`, so the resend skips the `isolatePeerMachines` prompt ([permissions.md](permissions.md)). Live in default and acceptEdits mode, shadowed in auto mode ([shadow-mode.md](shadow-mode.md)), silent in the others. Silent too when it cannot show the session live, local and the only one with its name; fails open; `CLAUDE_PEER_REDIRECT=off` turns it off |
| `mod-gate` | file writes | Deny: a mod hooking `tool.check` or another permission override. Ask: a mod it cannot review. Anything else it hooks or calls, outside the guards included, is shown in a notice |
| `audit` | most events | Log: edits, Bash, MCP calls (field names only), agents, messages, artifacts, failures, auto-mode denials, model switches, settings changes, session end |
| `memory-lint` | file writes | Advise: name, type, description, `verify:` block and index tier of a memory file. In a `trackers/` folder, only a marked handoff: its shape, size, `STATE:` stamp and `Crons:`, and lines telling a session to read a ledger over 20 KB first; ledgers, reports and archives are not linted (`CLAUDE_TRACKER_LINT=off`) |
| `memory-lint-stop` | Stop | Advise at the end of the turn: a memory still with no index line, or a handoff whose `STATE:` is older than its write (the two-write saves `memory-lint` defers) |
| `comment-budget` | file writes | Advise: a comment block an edit grew past 6 lines |
| `tcc-check` | Bash results and failures | Advise: names macOS privacy control (TCC) when a Bash call prints an "Operation not permitted" error (a tool's, zsh's or python's) for a path in `~/Desktop`, `~/Documents`, `~/Downloads` or iCloud Drive, or for no path while the cwd (or a `cd` in the command) is in one. A line quoting one, in backticks or after grep -n's `file:line:`, is not an error; a log line printed whole still is |
| `session-start` | SessionStart | Inject: branch, status and recent commits; on resume, files that drifted since the last session; once a day, a warning when job folders or Bazel output bases pass a size |
| `session-snapshot` | Stop, SessionEnd | Record: hashes of the files the session edited, for the resume drift check |
| `pre-compact` | PreCompact | Back up: the transcript before compaction, one per session, newest 20 within 1000 MB |
| `notify` | Notification | Notify: a desktop alert titled with the session name |
| `plan-to-html` | ExitPlanMode | Render: the plan as HTML in your browser, without delaying the prompt |
| status line | every refresh | Show: model and effort, branch, context, cost, rate limits, plan and workflow links, a cold-cache warning |

A guard's deny runs before the permission system, so it holds in every
permission mode. The exceptions are a loaded mod and, in auto mode until the
2026-11-29 review, a guard or rule in shadow mode. A guard's ask still comes to
you in auto mode: Claude Code's [permission-modes doc](https://code.claude.com/docs/en/permission-modes)
says auto mode "still shows you those prompts". The auto-mode classifier
decides only what no guard or rule names. "Shadow" above means the guard or rule
logs what it would have decided to `~/.claude/logs/shadow.log` and decides
nothing; the list is `hooks/lib/shadow.sh`, and `tools/shadow-report.py` shows
what the classifier or a native rule did instead ([shadow-mode.md](shadow-mode.md)).
Every row in full: [guards.md](guards.md), the sections below, and
[auto-mode.md](auto-mode.md).

## Audit

Async and non-blocking, except the SessionEnd line, which runs synchronously so
it is written before the session exits.

| Hook | Event | Behaviour |
|---|---|---|
| `audit` | PostToolUse → Edit/MultiEdit/Write/NotebookEdit | Logs every file Claude touches |
| `audit` | PostToolUse → Bash | Logs every Bash command Claude runs (sanitized to one line) |
| `audit` | PostToolUse → Monitor | Logs each monitor's command, or `ws <url>` for a WebSocket one, never its description |
| `audit` | PostToolUseFailure | Logs failed tool calls with error summary |
| guards | PreToolUse deny / ask | Every guard decision is one line, `GUARD \| deny\|ask \| <hook> \| <command, path or URL>`, never file content; a Bash guard run by `bash-guards` logs under its own name. A denied call never reaches PostToolUse, so without it the harness's own blocks left no record: `grep ' | GUARD | ' ~/.claude/logs/audit.log`. A call a [mod](known-limitations.md) answers itself reaches neither the guards nor PostToolUse, so it leaves no line at all. |
| `audit` | PermissionDenied | Logs a call auto mode refused: `DENIED \| <tool> \| id=<tool_use_id> mode=<permission mode> \| <command, ws URL or path> \| <reason>`. The id comes before the command, which can hold ` \| `, so `tools/shadow-report.py` can join on it ([shadow-mode.md](shadow-mode.md)). Log-only: it emits no `retry`, so the denial stands. |
| `audit` | PostModelSwitch | Logs `model_switch \| <from> -> <to>` when a session changes model, since no other line records which model was running. |
| `audit` | ConfigChange | Logs any settings file modified mid-session |
| `audit` | PostToolUse → `mcp__.*` | Logs every MCP tool call: the tool name and the *names* of the fields it was called with, never their values (a `send_message` payload carries the message body). No PreToolUse guard inspects MCP calls, so this line is the only record one happened. It is a census, not a control: read it with `grep ' | mcp__' ~/.claude/logs/audit.log` to see which connectors actually get used before deciding what to guard. |
| `audit` | PostToolUse → Agent/SendMessage | Logs each subagent spawn (`type`, `model` or `inherit`, `isolation`) and each peer message (`to`, character count, `notify_when_idle`). Never the prompt, description, summary or message body. Evidence for subagent model choices and a sender-side trail for work handed between sessions: `grep -E ' \| (Agent|SendMessage) \| ' ~/.claude/logs/audit.log`. |
| `audit` | PostToolUse → Artifact/ArtifactData/ArtifactComments | Logs each publish, database write and comment action: `action`, `url`, the published file's path, `collection`/`doc_id`, `thread_id`. Never page content, `data`, or comment text. Since 2.1.268 `WebFetch` rules no longer cover these tools, so this is the only record of what went to claude.ai. |
| `audit` | SessionEnd | Logs a session-end line **once per session**: turn count (derived from the transcript; cost isn't exposed to hooks), session id, and why the session ended (`clear` / `logout` / `exit`). Previously wired to `Stop`, which fires at *every* turn end and so wrote a mislabelled `session_end` line per turn. The hook still accepts `Stop` if you rewire it. |

All entries go to `~/.claude/logs/audit.log` (`0600` perms, rotated at 10 MB, 5 backups retained).

## Advisory checks on writes

Both run on PostToolUse, after the write has happened, so they cannot block it;
their notes go back to Claude while the edit is still in context. A finding
exits 2, which Claude Code shows as "hook reported a problem" and hands to the
model. Both exit quietly when jq is missing.

Two `memory-lint` findings are about the state between two writes, so they wait
for the end of the turn ([`memory-lint-stop`](#advisory-checks-on-writes), below):
a memory with no `MEMORY.md` line yet (the file is written first, the line
second), and a handoff whose `STATE:` stamp is older than the write (the body is
edited first, the stamp second). PostToolUse records `epoch path` in
`~/.claude/state/sessions/lint-pending/<session id>` with a builtin `printf`.
Stop reads the list once, reports what is still missing, and empties it. An
interrupted turn never reaches Stop, so session-start deletes lists over a day
old once per daily measurement.

| Hook | Event | Behaviour |
|---|---|---|
| `memory-lint` | PostToolUse → Write/Edit/MultiEdit | On a file under a `memory/` folder: name matches filename, a valid type, a state-free description, a `verify:` block on any in-flight claim, link typos, an index line in the right tier. See [memory.md](memory.md). On a file under a `trackers/` folder, only a handoff: a file of at most 20,000 bytes (`TRACKER_LEDGER_BYTES`), with no `<name>-archive.md` beside it, marked by a `STATE:` or `Crons:` line or a `## Next on restart` heading. A file there named `*-handoff*.md` (any case) that passes the size and archive tests but has none of those markers gets one finding, saying so and to add them if it is a handoff or leave it if not; no size, heading or stamp finding until it is marked. It checks the five headings once each and in order, at most 5,000 bytes (`TRACKER_MAX_BYTES`), the `STATE:` stamp against the clock and the `Crons:` lines, and flags a line that tells a session to read a ledger over 20,000 bytes beside it first. Every other file there (ledgers, reports, logs, archives) is not linted on its own writes, and no finding says to cut, overwrite or `--write`: a folder of trackers may have no other copy. `CLAUDE_TRACKER_LINT=off` in settings.json `env` turns the tracker lint off. `tracker-prune.py FILE` lists a ledger's settled rows; `--write` moves them to `<name>-archive.md` under a folder lock, and a run that fails leaves a row in both files, never neither. |
| `memory-lint` | PostToolUse, what it hands the model | A new `feedback_` memory in a store with principle hubs gets the hub advice as `hookSpecificOutput.additionalContext` with exit 0: advice, not a problem notice. A `STATE:` stamp ahead of the clock or not a UTC time is reported at the write; an old one waits for Stop. One jq reads the tool name, path and session id (it was two, three when it stamped `originSessionId`); recording a pending entry starts no process on bash 5, and none for a memory on bash 3.2. A handoff entry asks `date` on 3.2, which that write already outweighs. |
| `memory-lint-stop` | Stop | Reads the session's pending list. A memory still with no line in `MEMORY.md` or `MEMORY_ARCHIVE.md` and a handoff whose `STATE:` is more than 5 min older than the write recorded for it (the write's time, not Stop's) are reported once as `hookSpecificOutput.additionalContext`, which continues the turn as Stop hook feedback with no error notice; `decision: "block"` would show a hook error for advice. Silent and empty when `stop_hook_active` is true (the list stays for the next Stop). With nothing pending it starts no process and loads no `lib.sh`; with a list, one jq, and only when a handoff is on it. Synchronous, unlike the `session-snapshot` Stop entry beside it. |
| `comment-budget` | PostToolUse → Edit/MultiEdit/Write | Flags a comment run that this edit grew past 6 lines (`MAX_RUN` in the hook); a long block the file already carried stays silent. Steps aside in a repo that ships its own `.claude/hooks/comment-budget.py`. |

## Context & continuity

| Hook | Event | Behaviour |
|---|---|---|
| `session-start` | SessionStart | On every start, writes `setopt no_nomatch no_equals` for zsh into `$CLAUDE_ENV_FILE`, which Claude Code sources before each Bash call and nowhere else, so an unmatched glob (`ls x* 2>/dev/null`) or `=word` no longer fails a call written for bash while interactive shells keep their options (`CLAUDE_ZSH_OPTS=off` skips it). On resume, compact and fork, injects git branch, status and last 5 commits (the CLI's own gitStatus covers startup and clear). On `source=resume`, also diffs each file the prior session edited against a content-hash snapshot and surfaces any drift (file reverted, missing, or HEAD moved) so Claude re-verifies before trusting the prior transcript's narrative. On every start, names the session host when its binary no longer exists (a CLI upgrade under a running background session: [known-limitations.md](known-limitations.md)). Once per measurement, so once a day, warns when `~/.claude/jobs` passes 50 GB or the Bazel output root 100 GB (`CLAUDE_DISK_WARN_JOBS_GB`, `CLAUDE_DISK_WARN_BAZEL_GB`), and names `python3 ~/.claude/disk-space.py report` or `bazel`. `report`, on demand only, also lists each transcript past that size with its last write, who has it open (a pid from `lsof`, or idle days, or `?` when lsof cannot tell, never idle then) and the date Claude Code removes it (last write plus `cleanupPeriodDays` from settings.json, default 30); it deletes none, since a transcript is still read after its session ends (`claude --resume`, permission-friction, shadow-report, session-census, spend-report). From the same measurement, once each: on resume or compact, when this session's transcript is listed (150 MB or more, `CLAUDE_TRANSCRIPT_WARN_MB`), its size and compaction count, with the handoff to write (`trackers/<name>.md` in the working-agreement shape) and a restart; on any start, how many transcripts written in the last 7 days are past that size and the largest with its compactions; and on any start, when 1 Bash call in 10 waited over 1 s for its slowest guard (the p90 over the last 200 calls in the guard timing log; `CLAUDE_GUARD_P90_WARN_MS`), the `doctor.sh --latency` command. It reads `~/.claude/state/disk-usage`, which `harness-update.sh` writes once a day with `disk-space.py stamp`, and sizes nothing itself; a stamp over two days old says nothing. Why: [long-running-sessions.md](long-running-sessions.md). |
| `tcc-check` | PostToolUse, PostToolUseFailure → Bash | When a Bash call prints an `Operation not permitted` error line (`x: Operation not permitted` from BSD tools, bash, git, Go and Rust, zsh's `(eval):1: operation not permitted: x`, python's `PermissionError: [Errno 1]`, node's `EPERM`) for a path in `~/Desktop`, `~/Documents`, `~/Downloads` or iCloud Drive, absolute, `~/`, or relative to the cwd or a `cd` in the command, or for no path while one of those is in such a folder (getcwd), says that this is macOS privacy control, quotes the line, names a session host whose binary an upgrade deleted, and gives the fix. A line naming only paths elsewhere, or quoting an error (in backticks, after grep -n's `file:line:`), stays silent; a log line printed whole still fires. A call that fails goes to PostToolUseFailure, with its output in `.error`, not to PostToolUse, so it is registered on both. Synchronous (exit 2 with stderr is what reaches the model); on every other call it is one substring test on the raw payload, no jq. |
| `session-snapshot` | Stop (async), SessionEnd | Records the hashes of every file the session edited, plus `git HEAD`, to `~/.claude/state/sessions/<session_id>.json` (0600, keeps newest 50). Feeds the resume-drift check above. Async on Stop because it reads the whole transcript (2.2 s on a 40 MB one); the SessionEnd run catches the last turn if you quit right after it. SessionEnd hooks share a 1.5 s budget unless a longer `timeout` is set, which raises it to match up to 60 s (hooks page, read 2026-11-20), so that entry sets `"timeout": 10`; without it a 2.2 s run is cut off. |
| `pre-compact` | PreCompact | Backs up the full session transcript before compaction. Keeps one copy per session: an earlier copy no larger than the new one goes (each is a byte prefix of the next), a larger one (a truncated source) stays. Then the newest 20 within `CLAUDE_TRANSCRIPT_BACKUP_MAX_MB` (1000; 0 for no cap; the newest always stays), and none older than Claude Code's own `cleanupPeriodDays` (default 30). Touches only `transcript_*.jsonl` in its own folder. Why: [long-running-sessions.md](long-running-sessions.md). |
| `notify` | Notification | Desktop alert when Claude needs input, titled with the session name (`/rename`, else the generated title, else the folder) and carrying Claude Code's own message (async) |

## Readability

| Hook | Event | Behaviour |
|---|---|---|
| `plan-to-html` | PreToolUse → ExitPlanMode | Renders the proposed plan as a styled HTML file and opens it in your browser, so long plans are comfortable to read before you approve/reject in the terminal. Runs `async`, so it never blocks or delays the approval prompt. Markdown is base64-embedded (no escaping can break the page) and decoded as UTF-8 client-side via [marked](https://marked.js.org/) and rendered with a GitHub-dark theme plus [highlight.js](https://highlightjs.org/) syntax highlighting for fenced code. The page loads `marked`/`highlight.js` from a CDN, so it is not fully self-contained, and falls back to readable raw markdown when offline. Plans authored as a **full HTML document** are served verbatim (no double-wrap). Output lands in `~/.claude/plans-html/` (newest 50 kept), and the session's latest plan is linked from the status line. |

## Status line

`bin/statusline.sh`, installed as `~/.claude/statusline.sh`, shows model and
effort, repo and branch, context, tokens, cost and duration, lines changed,
rate limits, and the plan and workflow links as clickable OSC-8 hyperlinks. The
`wf` link is the newest script this session's Workflow runs saved, which Claude
Code writes to `workflows/scripts` in the session's folder beside its
transcript; it opens in your editor (auto-detects VS Code, Cursor or Zed;
override with `CLAUDE_EDITOR_URI`). It
also warns `cold: next msg re-caches Nk` when upstream's
`prompt_cache.expires_at` has passed and `recache_tokens_if_cold` is at least
100k: the first message after the cache goes cold re-sends everything at write
price. It re-runs every 300 s (`refreshInterval`) so a terminal left open
overnight shows it before you type. The model is followed by the live effort
level (yellow at `low` or `medium`), plus `fast` and `no-think` when those
apply, because 2.1.280 started new models at their default effort without
saying so.
