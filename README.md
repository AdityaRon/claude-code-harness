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
| `env-guard` | PreToolUse → Bash | Blocks commands that read, dump, copy, or exfiltrate env values or dotfiles (`cat .env`, `printenv`, `echo $API_KEY`, `cp .env /tmp/x`, `dd if=.env`, `… < .env`, `curl --data @creds`, `nc`, `eval $(env)`, etc.) |
| `sensitive-file-guard` | PreToolUse → Read/Edit/Write/MultiEdit/NotebookEdit | Blocks access to `*.env`, `*.pem`, `*.key`, SSH keys, AWS creds, `.npmrc`, `.git-credentials`, `.pgpass`, `.kube/config`, `.ssh/config`, `.docker/config.json`, `credentials.json`, service-account JSON. Resolves symlinks so a symlinked path can't bypass. |
| `git-guard` | PreToolUse → Bash | Denies force-push, `.git/hooks` writes, `core.hooksPath` tampering (including via `-c`), shell-body (`!`) aliases, `filter-branch`, broad `git add`. Normalizes `git -c k=v` / `-C dir` global-option prefixes so they can't break the match. |
| `interpreter-guard` | PreToolUse → Bash | Denies `python -c` / `node -e` / `ruby -e` / `perl -ne` / `php -r` / `bash -c` and heredocs when the payload references env vars, dotfiles, sockets, or subprocess APIs — including when wrapped in a command runner (`poetry run`, `env`, `timeout`, `nohup`, …). Raises the bar on the interpreter-bypass route — but string-obfuscated payloads can still evade a regex; the OS sandbox is the real containment. |
| `network-guard` | PreToolUse → Bash, WebFetch | Denies file-body uploads via `curl -d @…` / `-d@…` / `--data=@…`, `-F @…`, `-T`, **and pipe-to-shell remote code execution** (piping curl/wget into a shell or interpreter, process substitution, or command substitution). Prompts on `scp`/`rsync`/`sftp` to a remote host and on local HTTP servers. |
| `secret-scanner` | PreToolUse → Write/Edit/MultiEdit/NotebookEdit | Scans the payload before it hits disk; denies AWS keys, JWTs, PEM blocks, GitHub/Slack(token+webhook)/Stripe/Google/Anthropic/OpenAI(incl. `sk-proj-`) tokens and GCP service-account keys |

### Security — prompt user (`ask`)

| Hook | Triggers |
|---|---|
| `git-guard` | `git push --delete`, `git push origin :branch`, `git remote set-url`, `git config user.email`, non-shell `git config alias.*`, glob staging (`git add '*.ts'`) |
| `interpreter-guard` | Long inline scripts with no obvious sensitive token |
| `network-guard` | `curl -X POST/PUT/PATCH/DELETE` (any host), `curl`/`wget`/`WebFetch` to non-allowlisted domain |

### Audit (async, non-blocking)

| Hook | Event | Behaviour |
|---|---|---|
| `audit` | PostToolUse → Edit/Write | Logs every file Claude touches |
| `audit` | PostToolUse → Bash | Logs every Bash command Claude runs (sanitized to one line) |
| `audit` | PostToolUseFailure | Logs failed tool calls with error summary |
| `audit` | ConfigChange | Logs any settings file modified mid-session |
| `audit` | Stop | Logs a session-end line with the turn count (derived from the transcript — cost isn't exposed to hooks) and session id |

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
| `workflow-record` | PostToolUse → Workflow | Logs each workflow run's persisted `.js` script path to the audit log and records a per-session pointer the status line links to. Clicking the `wf` link opens the script in your editor (auto-detects VS Code / Cursor / Zed; override with `CLAUDE_EDITOR_URI`). Discoverability only — no rendering. |
| `plan-to-html` | PreToolUse → ExitPlanMode | Renders the proposed plan as a styled HTML file and opens it in your browser, so long plans are comfortable to read before you approve/reject in the terminal. (The page loads `marked`/`highlight.js` from a CDN for rendering and gracefully falls back to readable raw markdown when offline — it is not fully self-contained.) Runs `async` — never blocks or delays the approval prompt. Markdown is base64-embedded (no escaping can break the page) and decoded as UTF-8 client-side via [marked](https://marked.js.org/) and rendered with a GitHub-dark theme plus [highlight.js](https://highlightjs.org/) syntax highlighting for fenced code; falls back to readable raw markdown when offline. Plans authored as a **full HTML document** are served verbatim (no double-wrap). Output lands in `~/.claude/plans-html/` (newest 50 kept), and the session's latest plan is linked from the **status line** as a clickable OSC-8 hyperlink. |

### Settings shipped

| Setting | Value | Effect |
|---|---|---|
| `fileCheckpointingEnabled` | `true` | Snapshots files before edits so `/rewind` can restore them |
| `effortLevel` | `xhigh` | Default reasoning effort (portable across machines) |
| `skipAutoPermissionPrompt` | `true` | Pre-accepts the auto-mode opt-in dialog |
| `sandbox` | off by default | OS sandbox (Seatbelt/bubblewrap) drafted with a read-only network allowlist (npm/pypi/crates/go/github/anthropic). Flip `sandbox.enabled` to `true` to confine commands. See Customization. |
| `includeCoAuthoredBy` | `true` | Adds `Co-authored-by: Claude` to commits |
| `permissions.allow` | Scoped allowlist (≈70 entries) | Covers common safe ops: `npm test/run lint/build`, `pytest`, `python3`, `poetry run/install/lock`, `gh run/search`, `cargo test`, `go test`, `ls`, `grep`, `git status`, etc. Interpreter wildcards (`python3`, `poetry run`) are allowed because a permission `allow` only skips the *prompt* — the PreToolUse guards still run, and `interpreter-guard` inspects inline `-c`/`-e`/heredoc code even when wrapped in a runner (`poetry run python -c …`). `gh api` is deliberately **not** allowlisted (it can POST/DELETE via the GitHub API with no network-guard coverage). With the OS sandbox off, an auto-approved `python3 script.py` runs the script's contents unscanned — enable the sandbox for containment. |
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
    workflow-record.sh
  statusline.sh          ← model | repo:branch | context | tokens | cost | [rate limits] | plan + workflow links
  memory-verify.sh       ← checks memories against GitHub; run on demand, not a hook
  skills/
    memory-audit/
      SKILL.md           ← /memory-audit — resolves the claims a script cannot
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
    workflows/
      <session_id>.path  ← pointer to the session's latest workflow run script (statusline link)
  plans-html/
    plan-20260528-143022.html  ← rendered plan, opened in browser, newest 50 kept
```

## Testing the harness

```bash
bash doctor.sh
```

Runs every test in `tests/*.test.sh` and prints a summary. The full suite covers 320+ cases across all hooks, including known bypass attempts (symlinked dotfiles, quoted paths, commit messages containing trigger strings, `git -c`/`-C` global-option prefixes, shell-body git aliases, interpreter inline-code escapes and heredocs, combined interpreter flags, `@file` upload variants, stage-then-exfil copies, and mutating HTTP methods), a **fail-closed** check that every Bash/file guard denies when jq is unavailable, and the plan-renderer (UTF-8 round-trip, script-injection containment, retention cap).

CI (`.github/workflows/ci.yml`) runs `doctor.sh` on both Linux and macOS and lints every hook with `shellcheck` on each push and PR.

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

**Open workflow scripts in a specific editor** (the status-line `wf` link). Auto-detects VS Code/Cursor/Zed; override the URI scheme:
```json
{ "env": { "CLAUDE_EDITOR_URI": "cursor://file" } }
```

**Enable the OS sandbox** (drafted off-by-default with a read-only allowlist). Flip it on globally in `~/.claude/settings.json`, or per-project in `.claude/settings.json`:
```json
{ "sandbox": { "enabled": true } }
```
Extend its allowlist under `sandbox.network.allowedDomains`.

## Known limitations

These guards are defense-in-depth, not a security boundary. Be clear-eyed about what they do **not** cover:

- **Regex guards have a ceiling.** Command-string matching can always be evaded by a determined agent (string-obfuscated interpreter payloads, novel tool invocations, multi-step stage-then-exfil across separate commands). The guards raise the bar and catch the obvious/accidental cases; the **OS sandbox** is the only real containment for the evasion class — see *Enable the OS sandbox*.
- **MCP connectors are not covered.** `network-guard` sees Bash `curl`/`wget` and the `WebFetch` tool, but MCP tools (Slack, Google Drive, Atlassian, …) can read files and send data outbound with no guard in the middle. Control that surface by only connecting MCP servers you trust.
- **Guards fail *closed* without jq**, so a missing-jq machine blocks all Bash/file tool calls rather than allowing them unchecked. Keep `jq` installed (the installer checks for it).

## Per-project additions (not in this harness)

Each repo manages its own:
- `CLAUDE.md` — PR format, reviewer names, workflow rules
- `.claude/settings.json` — project-specific deny rules, auto-formatter, test runner
- Slack notifications — via MCP connector, instructed through CLAUDE.md

## Memory staleness

Claude Code stores memories under `~/.claude/projects/<slug>/memory/`, and ships
its own hygiene pass (auto-dream) that merges duplicates, resolves
contradictions, and rewrites relative dates. That pass reasons over memory
content and session logs — it never leaves the machine.

So one failure mode survives it: a memory whose claim was overtaken by the
outside world. *"Draft PR #4821, held, land only if…"* stays internally
consistent forever, while the PR merged two months ago. Nothing in the file
disagrees; GitHub does.

`memory-verify.sh` closes that gap, and `/memory-audit` handles the half that
needs judgment.

```bash
bash ~/.claude/memory-verify.sh                    # every store
bash ~/.claude/memory-verify.sh --store <slug>     # one store
bash ~/.claude/memory-verify.sh --json             # for the skill
```

Exit codes: `0` nothing to do · `1` something is provably stale · `2` needs
triage · `3` could not run.

A memory becomes mechanically checkable by carrying a `verify:` block:

```yaml
verify:
  - gh acme/api#4821 merged
  - jira PROJ-123 Done
```

Anything with a block is resolved directly against GitHub. Anything without one
is reported as `TRIAGE` — because real memories cite bare `#4821` rather than
`owner/repo#4821`, and often cite twenty of them, so choosing *which* reference
is the claim under test needs a model. That is `/memory-audit`: it resolves the
ambiguous ones, proposes corrections, and writes a `verify:` block back, so each
audited memory is mechanical from then on.

The script is read-only by contract — it never edits, moves, or deletes a
memory, and `/memory-audit` proposes rather than deletes. Deleting on a
heuristic destroys knowledge silently, which is worse than staleness.

**Note:** auto-dream is gated behind a server-side rollout flag
(`tengu_onyx_plover`). Where it is off, the built-in hygiene described above is
not running at all — check `/memory` to see whether it is available to you.
