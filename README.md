# Claude Code Harness

Machine-level security, audit, and context hooks for Claude Code.
Install once per developer machine — works across all projects without touching repo files.

## Install

```bash
git clone https://github.com/aditya-samalla/claude-code-harness.git
cd claude-code-harness
bash install.sh
```

The installer:
- Merges into any existing `~/.claude/settings.json` (user keys preserved, allow/deny lists unioned, hooks owned by harness).
- Backs up the previous file as `settings.json.bak.<timestamp>`.
- Runs `doctor.sh` to verify every hook after install.

Then open Claude Code and run `/hooks` to confirm everything is registered.

## What it does

### Security — hard block (`deny`)

| Hook | Event | Behaviour |
|---|---|---|
| `env-guard` | PreToolUse → Bash | Blocks commands that read, dump, or exfiltrate env values or dotfiles (`cat .env`, `printenv`, `curl --data @creds`, `nc`, `eval $(env)`, etc.) |
| `sensitive-file-guard` | PreToolUse → Read/Edit/Write | Blocks access to `.env*`, `*.pem`, `*.key`, SSH keys, AWS credentials. Resolves symlinks so a symlinked path can't bypass. |
| `git-guard` | PreToolUse → Bash | Denies force-push, `.git/hooks` writes, `core.hooksPath` tampering, `filter-branch`, broad `git add` |
| `interpreter-guard` | PreToolUse → Bash | Denies `python -c` / `node -e` / `ruby -e` / `bash -c` etc. when the inline code references env vars, dotfiles, sockets, or subprocess APIs. Closes the interpreter-bypass route. |
| `network-guard` | PreToolUse → Bash, WebFetch | Denies file-body uploads via `curl -d @…`, `-F @…`, `-T`, **and pipe-to-shell remote code execution** (piping curl/wget into a shell or interpreter, process substitution, or command substitution) |
| `secret-scanner` | PreToolUse → Write/Edit/MultiEdit | Scans the payload before it hits disk; denies AWS keys, JWTs, PEM blocks, GitHub/Slack/Stripe/Google/Anthropic/OpenAI tokens |

### Security — prompt user (`ask`)

| Hook | Triggers |
|---|---|
| `git-guard` | `git push --delete`, `git push origin :branch`, `git remote set-url`, `git config user.email`, glob staging (`git add '*.ts'`) |
| `interpreter-guard` | Long inline scripts with no obvious sensitive token |
| `network-guard` | `curl -X POST/PUT/PATCH/DELETE` (any host), `curl`/`wget`/`WebFetch` to non-allowlisted domain |

### Audit (async, non-blocking)

| Hook | Event | Behaviour |
|---|---|---|
| `audit` | PostToolUse → Edit/Write | Logs every file Claude touches |
| `audit` | PostToolUse → Bash | Logs every Bash command Claude runs (sanitized to one line) |
| `audit` | PostToolUseFailure | Logs failed tool calls with error summary |
| `audit` | ConfigChange | Logs any settings file modified mid-session |
| `audit` | Stop | Logs session turn count and cost on exit |

All entries go to `~/.claude/logs/audit.log` (`0600` perms, rotated at 10 MB, 5 backups retained).

### Context & continuity

| Hook | Event | Behaviour |
|---|---|---|
| `session-start` | SessionStart | Injects git branch, status, and last 5 commits into context automatically. On `source=resume`, also diffs each file the prior session edited against a content-hash snapshot and surfaces any drift (file reverted, missing, or HEAD moved) so Claude re-verifies before trusting the prior transcript's narrative. |
| `session-snapshot` | Stop | Records the hashes of every file the session edited, plus `git HEAD`, to `~/.claude/state/sessions/<session_id>.json` (0600, keeps newest 50). Feeds the resume-drift check above. |
| `pre-compact` | PreCompact | Backs up the full session transcript before compaction. Keeps last 20. |
| `notify` | Notification | Desktop alert when Claude needs input (async) |

### Readability

| Hook | Event | Behaviour |
|---|---|---|
| `plan-to-html` | PreToolUse → ExitPlanMode | Renders the proposed plan as a styled, self-contained HTML file and opens it in your browser, so long plans are comfortable to read before you approve/reject in the terminal. Runs `async` — never blocks or delays the approval prompt. Markdown is base64-embedded (no escaping can break the page) and decoded as UTF-8 client-side via [marked](https://marked.js.org/); falls back to readable raw markdown when offline. Plans authored as a **full HTML document** are served verbatim (no double-wrap). Output lands in `~/.claude/plans-html/` (newest 50 kept), and the session's latest plan is linked from the **status line** as a clickable OSC-8 hyperlink. |

### Settings shipped

| Setting | Value | Effect |
|---|---|---|
| `fileCheckpointingEnabled` | `true` | Snapshots files before edits so `/rewind` can restore them |
| `effortLevel` | `xhigh` | Default reasoning effort (portable across machines) |
| `skipAutoPermissionPrompt` | `true` | Pre-accepts the auto-mode opt-in dialog |
| `sandbox` | off by default | OS sandbox (Seatbelt/bubblewrap) drafted with a read-only network allowlist (npm/pypi/crates/go/github/anthropic). Flip `sandbox.enabled` to `true` to confine commands. See Customization. |
| `includeCoAuthoredBy` | `true` | Adds `Co-authored-by: Claude` to commits |
| `permissions.allow` | Scoped allowlist (≈60 entries) | Covers common safe ops: `npm test/run lint/build`, `pytest`, `cargo test`, `go test`, `ls`, `grep`, `git status`, etc. No wildcards like `Bash(python:*)` — those would let Claude bypass every guard. |
| `permissions.deny` | `git push --force`, `sudo`, `rm -rf`, `gh auth token`, … | Deny always wins over allow |

## File layout after install

```
~/.claude/
  settings.json          ← merged with harness defaults (user keys preserved)
  hooks/
    lib.sh               ← shared helpers (emit_deny, emit_ask, log_audit, …)
    env-guard.sh
    sensitive-file-guard.sh
    git-guard.sh
    interpreter-guard.sh
    network-guard.sh
    secret-scanner.sh
    audit.sh
    notify.sh
    session-start.sh
    session-snapshot.sh
    pre-compact.sh
    plan-to-html.sh
  statusline.sh          ← model | context | tokens | cost | clickable plan link
  logs/
    audit.log            ← append-only audit trail, 0600, rotated
  transcripts/
    transcript_auto_20260415_143022.jsonl
    ...
  state/
    sessions/
      <session_id>.json  ← per-session edit snapshot, 0600, newest 50 kept
    plans/
      <session_id>.path  ← pointer to the session's latest rendered plan (statusline link)
  plans-html/
    plan-20260528-143022.html  ← rendered plan, opened in browser, newest 50 kept
```

## Testing the harness

```bash
bash doctor.sh
```

Runs every test in `tests/*.test.sh` and prints a summary. The full suite covers 240+ cases across all hooks, including known bypass attempts (symlinked dotfiles, quoted paths, commit messages containing trigger strings, interpreter inline-code escapes, file-upload shapes, and mutating HTTP methods) and the plan-renderer (UTF-8 round-trip, script-injection containment, retention cap).

## Customization

**Extend the network allowlist per-project:**
```json
{ "env": { "CLAUDE_NET_ALLOWLIST": "internal.example.com api.myservice.io" } }
```

**Point the audit log elsewhere:**
```json
{ "env": { "CLAUDE_AUDIT_LOG": "~/logs/claude.log" } }
```

**Change where rendered plans are written:**
```json
{ "env": { "CLAUDE_PLANS_HTML_DIR": "~/Desktop/claude-plans" } }
```

**Render plans without auto-opening a browser** (e.g. headless / remote sessions):
```json
{ "env": { "CLAUDE_PLAN_HTML_NO_OPEN": "1" } }
```

**Enable the OS sandbox** (drafted off-by-default with a read-only allowlist). Flip it on globally in `~/.claude/settings.json`, or per-project in `.claude/settings.json`:
```json
{ "sandbox": { "enabled": true } }
```
Extend its allowlist under `sandbox.network.allowedDomains`.

## Per-project additions (not in this harness)

Each repo manages its own:
- `CLAUDE.md` — PR format, reviewer names, workflow rules
- `.claude/settings.json` — project-specific deny rules, auto-formatter, test runner
- Slack notifications — via MCP connector, instructed through CLAUDE.md
