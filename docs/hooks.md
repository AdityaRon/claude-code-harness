# Audit, context and readability hooks

The hooks that log, carry context and render, as registered in
`config/settings.json`. Moved from the README; the guards are in
[guards.md](guards.md).

## Audit

Async and non-blocking, except the SessionEnd line, which runs synchronously so
it is written before the session exits.

| Hook | Event | Behaviour |
|---|---|---|
| `audit` | PostToolUse → Edit/MultiEdit/Write/NotebookEdit | Logs every file Claude touches |
| `audit` | PostToolUse → Bash | Logs every Bash command Claude runs (sanitized to one line) |
| `audit` | PostToolUseFailure | Logs failed tool calls with error summary |
| guards | PreToolUse deny / ask | Every guard decision is one line, `GUARD \| deny\|ask \| <hook> \| <command, path or URL>`, never file content. A denied call never reaches PostToolUse, so without it the harness's own blocks left no record: `grep ' | GUARD | ' ~/.claude/logs/audit.log`. A call a [mod](known-limitations.md) answers itself reaches neither the guards nor PostToolUse, so it leaves no line at all. |
| `audit` | PermissionDenied | Logs a call auto mode refused: `DENIED \| <tool> \| <command or path> \| <reason>`. Log-only: it emits no `retry`, so the denial stands. |
| `audit` | PostModelSwitch | Logs `model_switch \| <from> -> <to>` when a session changes model, since no other line records which model was running. |
| `audit` | ConfigChange | Logs any settings file modified mid-session |
| `audit` | PostToolUse → `mcp__.*` | Logs every MCP tool call: the tool name and the *names* of the fields it was called with, never their values (a `send_message` payload carries the message body). No PreToolUse guard inspects MCP calls, so this line is the only record one happened. It is a census, not a control: read it with `grep ' | mcp__' ~/.claude/logs/audit.log` to see which connectors actually get used before deciding what to guard. |
| `audit` | PostToolUse → Agent/SendMessage | Logs each subagent spawn (`type`, `model` or `inherit`, `isolation`) and each peer message (`to`, character count, `notify_when_idle`). Never the prompt, description, summary or message body. Evidence for subagent model choices and a sender-side trail for work handed between sessions: `grep -E ' \| (Agent|SendMessage) \| ' ~/.claude/logs/audit.log`. |
| `audit` | PostToolUse → Artifact/ArtifactData/ArtifactComments | Logs each publish, database write and comment action: `action`, `url`, the published file's path, `collection`/`doc_id`, `thread_id`. Never page content, `data`, or comment text. Since 2.1.268 `WebFetch` rules no longer cover these tools, so this is the only record of what went to claude.ai. |
| `audit` | SessionEnd | Logs a session-end line **once per session**: turn count (derived from the transcript; cost isn't exposed to hooks), session id, and why the session ended (`clear` / `logout` / `exit`). Previously wired to `Stop`, which fires at *every* turn end and so wrote a mislabelled `session_end` line per turn. The hook still accepts `Stop` if you rewire it. |

All entries go to `~/.claude/logs/audit.log` (`0600` perms, rotated at 10 MB, 5 backups retained).

## Advisory checks on writes

Both run on PostToolUse, after the write has happened, so they never block it;
their notes go back to Claude while the edit is still in context. Both exit
quietly when jq is missing.

| Hook | Event | Behaviour |
|---|---|---|
| `memory-lint` | PostToolUse → Write/Edit/MultiEdit | On a file under a `memory/` folder: name matches filename, a valid type, a state-free description, a `verify:` block on any in-flight claim, link typos, an index line in the right tier. See [memory.md](memory.md). |
| `comment-budget` | PostToolUse → Edit/MultiEdit/Write | Flags a comment run that this edit grew past 6 lines (`MAX_RUN` in the hook); a long block the file already carried stays silent. Steps aside in a repo that ships its own `.claude/hooks/comment-budget.py`. |

## Context & continuity

| Hook | Event | Behaviour |
|---|---|---|
| `session-start` | SessionStart | On resume, compact, clear and fork, injects git branch, status and last 5 commits (the CLI's own gitStatus covers startup). On `source=resume`, also diffs each file the prior session edited against a content-hash snapshot and surfaces any drift (file reverted, missing, or HEAD moved) so Claude re-verifies before trusting the prior transcript's narrative. |
| `session-snapshot` | Stop (async), SessionEnd | Records the hashes of every file the session edited, plus `git HEAD`, to `~/.claude/state/sessions/<session_id>.json` (0600, keeps newest 50). Feeds the resume-drift check above. Async on Stop because it reads the whole transcript (2.2 s on a 40 MB one); the SessionEnd run catches the last turn if you quit right after it. |
| `pre-compact` | PreCompact | Backs up the full session transcript before compaction. Keeps last 20, and none older than Claude Code's own `cleanupPeriodDays` (default 30). |
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
