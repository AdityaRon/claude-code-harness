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
| `sensitive-file-guard` | PreToolUse → Read/Edit/Write/MultiEdit/NotebookEdit/**Grep** | Blocks access to `*.env`, `*.pem`, `*.key`, SSH keys, AWS creds, `.npmrc`, `.git-credentials`, `.pgpass`, `.kube/config`, `.ssh/config`, `.docker/config.json`, `credentials.json`, service-account JSON. Resolves symlinks so a symlinked path can't bypass. **Grep** prints file content like `Read` does, so it is guarded on the same list: its `path` is checked as a file *and* as a credentials directory (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, which a content search would dump wholesale), and its `glob` is checked in de-globbed form, so `*.env`, `**/.env*` and `*.{env,ts}` are all denied. Grep's `pattern` is the text being searched *for*, never a target — grepping source for `process.env.API_KEY` stays an ordinary read. |
| `git-guard` | PreToolUse → Bash | Denies force-push in every spelling (`--force`, `--force-with-lease`, a bundled short flag like `-fu`/`-qf`, a `+` refspec, `--mirror`), `reset --hard`, `clean -f`, `branch -d/-D`, writes into `.git/hooks` (the directory, so `cd .git/hooks && cat > pre-commit` counts), `core.hooksPath` tampering (including via `-c`), shell-body (`!`) aliases, `filter-branch`, broad `git add` (`.`, `./`, `:/`, `-A`, `--all`, including behind a flag like `git add -v .`). Normalizes `git -c k=v` / `-C dir` global-option prefixes, and (via `normalize_wrappers`) leading env assignments and wrapper commands, so neither can break the match. |
| `interpreter-guard` | PreToolUse → Bash | Denies `python -c` / `node -e` / `ruby -e` / `perl -ne` / `php -r` / `bash -c` and heredocs when the payload references env vars, dotfiles, sockets, or subprocess APIs — including when wrapped in a command runner (`poetry run`, `env`, `timeout`, `nohup`, …). Raises the bar on the interpreter-bypass route — but string-obfuscated payloads can still evade a regex; the OS sandbox is the real containment. |
| `network-guard` | PreToolUse → Bash, WebFetch | Denies file-body uploads via `curl -d @…` / `-d@…` / `--data=@…`, `-F @…`, `-T`, **and pipe-to-shell remote code execution** (piping curl/wget into a shell or interpreter, process substitution, or command substitution). Prompts on `scp`/`rsync`/`sftp` to a remote host and on local HTTP servers. |
| `secret-scanner` | PreToolUse → Write/Edit/MultiEdit/NotebookEdit | Scans the payload before it hits disk; denies AWS keys, JWTs, PEM blocks, GitHub/Slack(token+webhook)/Stripe/Google/Anthropic/OpenAI(incl. `sk-proj-`) tokens and GCP service-account keys |

### Security — prompt user (`ask`)

> Under the shipped `defaultMode: auto`, these prompts are resolved by the auto-mode
> classifier rather than by you. See [Auto mode](#auto-mode).

| Hook | Triggers |
|---|---|
| `git-guard` | `git push --delete`, `git push origin :branch`, `git remote set-url`, `git config user.email`, non-shell `git config alias.*`, glob staging (`git add '*.ts'`) |
| `interpreter-guard` | Long inline scripts with no obvious sensitive token |
| `kubectl-guard` | Every mutating `kubectl` verb (`delete`, `apply`, `patch`, `replace`, `edit`, `scale`, `drain`, `cordon`, `taint`, `exec`, `cp`, `run`, `debug`, `proxy`, `rollout undo/restart`, `auth reconcile`, `config use-context`, …) wherever the verb sits in the command, plus `get secret` in every spelling that returns the data — `secret/db-creds`, `pods,secrets`, `Secret`, `secrets.v1.`, and the `--raw /api/v1/…/secrets` path (credential materialisation) — and any subcommand on neither list (fails closed). Only the resource *kind* is compared, so a CRD that merely starts with the word (`secretproviderclass`, `sealedsecrets`) stays a silent read. Exists because `kubectl` takes its global flags **before** the verb, so a prefix-matched rule like `Bash(kubectl delete:*)` misses `kubectl --namespace vm delete pod foo` — no allow/deny pair in `settings.json` can express this. Escalates rather than blocks: auto mode ships ~10 kubectl-specific `soft_deny` rules that clear when you name the target, and a hook `deny` would preempt all of them. Read-only verbs (`get`, `describe`, `logs`, `top`, `port-forward`, `rollout status`, `auth can-i`, `config view`, …) pass silently; flag *values* are skipped so `--context delete-me get pods` is still a read. |
| `network-guard` | `curl -X POST/PUT/PATCH/DELETE` (any host), `curl`/`wget`/`WebFetch` to non-allowlisted domain |

### Audit (async, non-blocking)

| Hook | Event | Behaviour |
|---|---|---|
| `audit` | PostToolUse → Edit/Write | Logs every file Claude touches |
| `audit` | PostToolUse → Bash | Logs every Bash command Claude runs (sanitized to one line) |
| `audit` | PostToolUseFailure | Logs failed tool calls with error summary |
| `audit` | ConfigChange | Logs any settings file modified mid-session |
| `audit` | PostToolUse → `mcp__.*` | Logs every MCP tool call: the tool name and the *names* of the fields it was called with, never their values (a `send_message` payload carries the message body). No PreToolUse guard inspects MCP calls, so this line is the only record one happened. It is a census, not a control: read it with `grep ' | mcp__' ~/.claude/logs/audit.log` to see which connectors actually get used before deciding what to guard. |
| `audit` | PostToolUse → Agent/SendMessage | Logs each subagent spawn (`type`, `model` or `inherit`, `isolation`) and each peer message (`to`, character count, `notify_when_idle`). Never the prompt, description, summary or message body. Evidence for subagent model choices and a sender-side trail for work handed between sessions: `grep -E ' \| (Agent|SendMessage) \| ' ~/.claude/logs/audit.log`. |
| `audit` | PostToolUse → Artifact/ArtifactData/ArtifactComments | Logs each publish, database write and comment action: `action`, `url`, the published file's path, `collection`/`doc_id`, `thread_id`. Never page content, `data`, or comment text. Since 2.1.268 `WebFetch` rules no longer cover these tools, so this is the only record of what went to claude.ai. |
| `audit` | SessionEnd | Logs a session-end line **once per session** — turn count (derived from the transcript; cost isn't exposed to hooks), session id, and why the session ended (`clear` / `logout` / `exit`). Previously wired to `Stop`, which fires at *every* turn end and so wrote a mislabelled `session_end` line per turn. The hook still accepts `Stop` if you rewire it. |

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
| `plan-to-html` | PreToolUse → ExitPlanMode | Renders the proposed plan as a styled HTML file and opens it in your browser, so long plans are comfortable to read before you approve/reject in the terminal. (The page loads `marked`/`highlight.js` from a CDN for rendering and gracefully falls back to readable raw markdown when offline — it is not fully self-contained.) Runs `async` — never blocks or delays the approval prompt. Markdown is base64-embedded (no escaping can break the page) and decoded as UTF-8 client-side via [marked](https://marked.js.org/) and rendered with a GitHub-dark theme plus [highlight.js](https://highlightjs.org/) syntax highlighting for fenced code; falls back to readable raw markdown when offline. Plans authored as a **full HTML document** are served verbatim (no double-wrap). Output lands in `~/.claude/plans-html/` (newest 50 kept), and the session's latest plan is linked from the **status line** as a clickable OSC-8 hyperlink. The status line also warns `cold: next msg re-caches Nk` when upstream's `prompt_cache.expires_at` has passed and `recache_tokens_if_cold` is at least 100k: the first message after the cache goes cold re-sends everything at write price. It re-runs every 300 s (`refreshInterval`) so a terminal left open overnight shows it before you type. The model is followed by the live effort level (yellow at `low` or `medium`), plus `fast` and `no-think` when those apply, because 2.1.280 started new models at their default effort without saying so. |

### Settings shipped

| Setting | Value | Effect |
|---|---|---|
| `permissions.defaultMode` | `auto` | Every session starts in **auto mode** — a model classifier adjudicates permission prompts instead of stopping for a keystroke. See [Auto mode](#auto-mode) for what this changes about the guards. |
| `fileCheckpointingEnabled` | `true` | Snapshots files before edits so `/rewind` can restore them |
| `effortLevel` | `xhigh` | Default reasoning effort (portable across machines) |
| `skipAutoPermissionPrompt` | `true` | Pre-accepts the auto-mode opt-in dialog, so auto mode is live on first launch rather than waiting behind a dialog |
| `sandbox` | off by default | OS sandbox (Seatbelt/bubblewrap) drafted with a read-only network allowlist (npm/pypi/crates/go/github/anthropic). Flip `sandbox.enabled` to `true` to confine commands. See Customization. |
| `includeCoAuthoredBy` | `true` | Adds `Co-authored-by: Claude` to commits |
| `syncClaudeAiSkills` / `syncClaudeAiPlugins` | `false` | Keeps the skills and plugins enabled on your claude.ai account out of terminal sessions. Each synced skill adds its description to every session, and a synced plugin can run hooks or inline shell under this machine's allow rules. They still work on claude.ai. Set either to `true` in `~/.claude/settings.json` to opt back in; the install keeps your value. |
| `permissions.allow` | Scoped allowlist | Covers common safe ops: `npm test/run lint/build`, `pytest`, `python3`, `poetry run/install/lock`, `gh run/search`, `cargo test`, `go test`, `ls`, `grep`, `git status`, etc. Read-only verbs added from the audit-log census: `git grep/rev-parse/ls-tree/ls-files/show-ref/cat-file/blame/describe/merge-base/shortlog`, `git remote -v`, `git worktree list`, `tsh status/login/clusters/kube ls`, and read-only `docker` subcommands (`run`/`exec`/`rm`/`cp` deliberately excluded). Interpreter wildcards (`python3`, `poetry run`) are allowed because a permission `allow` only skips the *prompt* — the PreToolUse guards still run, and `interpreter-guard` inspects inline `-c`/`-e`/heredoc code even when wrapped in a runner (`poetry run python -c …`). `gh api` and `kubectl` are both allowlisted, but they are not equally safe. `kubectl` is covered by `kubectl-guard`, which denies every mutating verb wherever it sits in the command. `gh api` has **no** equivalent coverage — it can POST/DELETE through the GitHub API and `network-guard` never inspects it, so that entry is a deliberate convenience trade rather than a guarded one. With the OS sandbox off, an auto-approved `python3 script.py` runs the script's contents unscanned — enable the sandbox for containment. |
| `permissions.deny` | `git push --force`, `git * reset --hard`, `sudo`, `rm -rf`, `gh auth token`, … | Deny always wins over allow |

### How Bash rules actually match

Verified against CLI 2.1.266 on 2026-09-09, after a friction census over 40,346
logged Bash calls found 31% of them landing on the classifier rather than a
rule. Getting these wrong produces two opposite failures: a rule that looks
permissive and still prompts, and a deny rule that reads as protection and
never fires. Both were present here.

- **Compound commands are split and matched per segment.** Separators are
  `&&`, `||`, `;`, `|`, `|&`, `&`, and newlines; every subcommand must match
  independently. Deny and ask rules additionally apply to commands nested in a
  subshell, a command substitution, or a control-flow body.
- **A fixed wrapper set is stripped before matching**: `timeout`, `time`,
  `nice`, `nohup`, `stdbuf`, plus the builtins `command` and `builtin`, and
  zsh's `noglob`. So `Bash(npm test *)` already covers `timeout 30 npm test`,
  and a `timeout`-prefixed command was never the friction it looked like.
  Not stripped: `env`, `xargs` with flags, `watch`, `setsid`, `flock`,
  `direnv exec`, `devbox run`, `mise exec`, `npx`, `docker exec`.
- **Leading env assignments are asymmetric.** A deny or ask rule matches past
  them (`Bash(rm *)` in deny catches `FOO=bar rm -rf tmp/`), but an allow rule
  does **not** — so `VAR=x cmd` fails closed and falls to the classifier. This
  is the single largest source of friction here (7,171 of 40,346 commands) and
  **no rule can fix it**: the first token contains a machine-specific value.
  Put the binary first instead.
- **`git -C <path>` is not a wrapper and is not stripped.** A rule written
  `Bash(git reset --hard:*)` therefore never matched `git -C /tmp/x reset
  --hard`, which is why the deny list here uses `Bash(git * reset --hard:*)`.
- **A `*` may appear anywhere in a rule**, not only at the end, and `:*` is
  just a compact spelling of a trailing ` *`. Mid-pattern wildcards are what
  make the `git *` and `kubectl * delete` deny rules load-bearing.
- **Whether `~` is expanded is undocumented.** Rather than guess,
  `merge-settings.jq` emits a `$HOME`-expanded twin for every rule containing
  `~/`, so both spellings are present whichever way the CLI compares them.
- **The installer can only widen.** `merge-settings.jq` unions the allow and
  deny lists, so dropping a rule from `config/settings.json` does not remove
  it from a machine that already has it. Narrowing a rule — say `Bash(kubectl:*)`
  down to `Bash(kubectl get:*)` — means editing `~/.claude/settings.json` by
  hand.

- **Allowlisting a wrapper script bypasses every guard.** A PreToolUse hook
  sees only the top-level Bash command, never the `kubectl` or `git` calls a
  script makes internally. The `~/.claude/skills/*` entries shipped here are
  read-only probes for exactly that reason, and a probe that creates and
  deletes cluster resources is deliberately left off the list — allowlisting it
  would launder `kubectl-guard`, which would never see inside it.

The practical consequence: **a hook sees the whole command string, a permission
rule sees only a prefix.** Enforcement that must not be evadable belongs in a
guard, with the deny list as a backstop — not the other way round.

## Auto mode

The harness ships `permissions.defaultMode: "auto"`. Instead of stopping for a
keystroke on every unrecognised action, a model classifier approves or denies
the prompt; read-only work (reading files, searching code) doesn't go to the
classifier at all. Verify the mode with `/status`, or override per session with
`claude --permission-mode manual`.

**This pins auto mode rather than enabling it.** As of Claude Code 2.1.227 auto
*is* the product default: `--permission-mode` accepts
`acceptEdits | auto | bypassPermissions | manual | dontAsk | plan` with no
`default` in the list, and a settings value of `"default"` means "whatever the
product default is" — which is now auto. So a machine sitting on `"default"`
already gets the classifier; setting `"auto"` explicitly just states the intent
and stops it drifting if that default changes again. The real opt-out is
`"manual"`.

**It only works in user settings.** Claude Code will not let a repo-level
`.claude/settings.json` grant `defaultMode: auto`, and the ignored value
*shadows* your user-level mode — so don't copy this harness's `settings.json`
into a project. The installer writes `~/.claude/settings.json`, which is the
right place. `install.sh` owns this key: an existing `defaultMode` is replaced
(with a notice) rather than winning the merge, so re-running the installer
actually flips an older install onto auto.

**What this changes about the guards:**

- **The `deny` tier is unaffected.** PreToolUse hooks run before the permission
  system, so a guard that denies still blocks the call in any mode.
- **The `ask` tier is no longer a question to you.** Everything the guards
  escalate as *ask* — `git push --delete`, `curl -X POST`, `scp` to a remote
  host, long inline interpreter scripts — is now adjudicated by the classifier
  on your behalf. Treat the ask rows in the tables above as "someone else
  decides", and promote anything you want stopped unconditionally into
  `permissions.deny` or `autoMode.hard_deny`.
- **Some `permissions.allow` entries are disregarded.** Auto mode ignores allow
  entries it classes as classifier-bypassing, so a broad wildcard may not buy
  you the silence it used to. Run `/doctor` inside a session to list which of
  your entries it's ignoring.

**Tuning the classifier.** Auto mode reads its rules from a top-level
`autoMode` key — `{environment, allow, soft_deny, hard_deny}`:

```bash
claude auto-mode defaults   # the shipped rules (17 allow, 65 soft_deny, 1 hard_deny, 20 environment)
claude auto-mode config     # the effective rules: yours where set, defaults otherwise
claude auto-mode critique   # AI review of your custom rules
claude auto-mode reset      # drop your autoMode section, back to shipped defaults
```

**The harness deliberately ships no `autoMode` block.** `auto-mode config`
describes the resolution as *"your settings where set, defaults otherwise"* —
i.e. setting a category looks like it **replaces** the shipped rules for that
category, not adds to them. Shipping a handful of `soft_deny` rules could
therefore silently drop the 65 that come with Claude Code, which is a bad trade
for a security harness. Write your own rules if you want them, then confirm
what survived with `claude auto-mode config` before trusting it.

## Repo layout

Two entry points sit at the root; everything else is grouped by what it is.

```
install.sh               ← run once per machine
doctor.sh                ← run every suite in tests/
bin/                     ← executables the harness installs or you invoke
  statusline.sh
  memory-verify.sh       ← memory staleness check (see Memory staleness)
  upstream-check.sh      ← scheduled drift guard (see Upstream drift)
  session-route.sh       ← which session owns this PR? (see docs/session-routing.md)
  memory-provenance.sh   ← who wrote this memory, and when? --session NAME answers
                           "did the session telling me this also write the memory
                           I am about to cite as agreement?"
config/
  settings.json          ← the settings the installer merges in
  merge-settings.jq      ← how that merge is performed
  upstream-contract.json ← the upstream facts the harness relies on
hooks/                   ← one file per hook, plus shared lib.sh
rules/                   ← personal rules, installed to ~/.claude/rules/ and
                           loaded in every session in every project. Portable
                           only: nothing naming a person, ticket, cluster or
                           customer, because this repo is PUBLIC. Machine-local
                           rules go straight into ~/.claude/rules as local-*.md,
                           a name nothing here may ship, and the install never
                           deletes what it did not put there
  prose-and-comments.md  ← length, voice, and where justification belongs
  collaboration.md       ← before replying, and handing work back
  working-agreement.md   ← keep going, evidence, cost, finishing the loop
  environment.md         ← git and Claude Code facts that hold on this machine
  python-tests.md        ← path-scoped: loads only when Claude opens Python
skills/                  ← agent skills, one directory each
  memory-audit/          ← check memories against external truth
  memory-archive/        ← relieve an over-limit index; proposes, never writes
  pr-review/             ← writing, answering and requesting a review; loads
                           only when a review is in play
tests/                   ← one <name>.test.sh per hook or script
docs/                    ← research notes and working documents
  session-routing.md     ← routing a PR to the session that owns it; read the
                           precondition — it only holds in single-author repos
  memory-hygiene-brief.md
                         ← the original audit: what is wrong with file-based
                           memory, and why nothing collects it
  memory-hygiene-research.md
                         ← what Claude Code already ships; read the Errata
                           first — two claims in the body did not hold
  memory-hygiene-problems.md
                         ← measured problems and the rules learned; the
                           memory skills cite this one
```

Paths inside `~/.claude` after install are flat — the grouping above is for
reading the repo, not for the installed tree.

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
    kubectl-guard.sh
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

Runs every test in `tests/*.test.sh` and prints a summary. The full suite covers 880+ cases across 22 suites, including known bypass attempts (symlinked dotfiles, quoted paths, commit messages containing trigger strings, `git -c`/`-C` global-option prefixes, shell-body git aliases, interpreter inline-code escapes and heredocs, combined interpreter flags, `@file` upload variants, stage-then-exfil copies, and mutating HTTP methods), a **fail-closed** check that every Bash/file guard denies when jq is unavailable, the plan-renderer (UTF-8 round-trip, script-injection containment, retention cap), and the settings merge (`config/merge-settings.jq` — that a stale `defaultMode` is replaced, allow/deny lists are unioned, user keys survive, and re-running the installer is a no-op).

CI (`.github/workflows/ci.yml`) runs `doctor.sh` on both Linux and macOS and lints every hook with `shellcheck` on each push and PR.

## Keeping up with Claude Code

This harness hard-codes facts about Claude Code — which hook events exist, which
permission modes are valid, what `settings.json` may contain. Claude Code
**auto-updates**, so those facts rot with no commit landing here. That has already
happened twice: auto mode became the product default, and `SessionEnd` appeared
while the session summary was still wired to `Stop`.

A push-triggered CI run can never catch this, because upstream changes when the
repo stands still. So:

```bash
bash bin/upstream-check.sh
```

`bin/upstream-check.sh` compares the harness against the **installed** CLI, using only
auth-free commands (`claude doctor`, `claude --version`) so CI needs no credentials.
It checks that the shipped `settings.json` still validates, that every hook event
the harness registers still exists, and that the shipped `defaultMode` is still
accepted — then reports events upstream has that nobody here has assessed.

It works by asking the CLI an impossible question: `claude doctor` prints the full
list of valid hook events *only* inside the warning for an unknown one, so the
check registers a sentinel event to make it enumerate them. Note that doctor
**exits 0 even when it rejects your settings**, so the output is parsed rather than
trusted.

| Exit | Meaning | Action |
|---|---|---|
| 0 | contract holds | none |
| 1 | **breakage** — the harness relies on something upstream changed | fix the harness |
| 2 | upstream grew — new capability nobody has assessed | adopt it, or record the decision |
| 3 | the check itself could not run | install `jq` / the CLI |

`upstream-contract.json` holds the assumptions. `acknowledged_hook_events` is *not*
"events we use" — it is "events a human has looked at and decided about", and
`notes_on_unused_events` records why each unused one was skipped. When upstream adds
an event the check fails with exit 2 until someone either hooks it or writes down
why not. **That deliberate nag is the mechanism that keeps this harness current
instead of quietly stale.**

`.github/workflows/upstream-drift.yml` runs it **daily on a schedule** plus on
demand, and on any push touching the assumptions. It installs the CLI via npm
rather than `curl … | bash` — piping a remote script into a shell is exactly what
this harness's own `network-guard` denies.

Sections 1 to 4 only see what `doctor` and the binary enumerate, so a new tool or
settings key arrives silently. Section 6 closes that: it reads the changelog
(`~/.claude/cache/changelog.md` locally; CI downloads it and passes
`CLAUDE_CHANGELOG_PATH`), lists the harness-relevant entries for every release after
`last_verified_version`, and exits 2 until someone assesses them and bumps that
field. Entries naming something the contract already has a decision for are
included, because that decision may now be stale.

When the daily run finds a new release, Claude reviews it and opens a **draft PR**
that edits only `upstream-contract.json`, once per release, assigned to the repo
owner. New settings, and anything touching deny, ask or a guard, come back as
questions in the PR body, never as changes. Your part: read and approve, merge,
`bash install.sh`. Without a token the same run keeps one open issue with section 6
instead. Locally, `session-start` says when the installed CLI is past the contract.

Setup, once: run `/install-github-app` in Claude Code for this repo. It installs
the Claude GitHub App, which lets the draft PR run CI, and stores
`CLAUDE_CODE_OAUTH_TOKEN`; confirm with `gh secret list`. The reviews use your
plan's usage.

**`/insights` is a local, monthly input, not a CI step.** It needs a login and a
model, and it reads your session history, so its report can quote prompts, paths
and anything a session printed. Keep the report on your machine. Turn what it
suggests into settings by hand, in a PR, and prefer the harness's own evidence:
`grep ' | mcp__' ~/.claude/logs/audit.log` for which connectors you use, and the
`/fewer-permission-prompts` skill for allow rules. Use it only to add `allow` rules; never
loosen `deny` or `ask` from it. `secret-scanner` still gates whatever lands in `settings.json`.

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

**Pull auto-compact in, so long sessions stop running at near-full context.**
Auto-compact does not fire at a percentage. It fires at
`assumed_window − min(max_output_tokens, 20000) − 13000`, so on a 1M-token model
the default trigger is **967k** — you spend the back half of every session paying
for a near-full context on every turn. Shrinking the *assumed* window pulls the
trigger in:
```json
{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "600000" } }
```
600000 → effective 580k → **compacts at 567k**, with the summary precomputed at
≈464k (at the default 0.2 buffer) so the swap is still instant. The CLI takes `min(real_window, configured)`,
so this is a **no-op on any model with a ≤600k window** and only bites on 1M
sessions. Blocking ("context limit reached") still uses the real window.

Use a **bare decimal integer**. The value is parsed with `parseInt` as a
fallback, and anything unparseable silently falls back to the 100000 *floor* —
so `"600k"` reads as `600`, floors to `100000`, and would compact a 1M session at
67k. Accepted range is 100000–1000000; outside it the value is floored or capped
without any error. `tests/install-merge.test.sh` asserts all of this.

For true percentage semantics instead, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` takes
1–100 as a percent of the effective window and is clamped so it can only ever
*lower* the trigger. It collapses the precompute head start onto the trigger
itself, so compaction stalls while it summarises rather than swapping in.

**Enable the OS sandbox** (drafted off-by-default with a read-only allowlist). Flip it on globally in `~/.claude/settings.json`, or per-project in `.claude/settings.json`:
```json
{ "sandbox": { "enabled": true } }
```
Extend its allowlist under `sandbox.network.allowedDomains`.

## Known limitations

These guards are defense-in-depth, not a security boundary. Be clear-eyed about what they do **not** cover:

- **Regex guards have a ceiling.** Command-string matching can always be evaded by a determined agent (string-obfuscated interpreter payloads, novel tool invocations, multi-step stage-then-exfil across separate commands). The guards raise the bar and catch the obvious/accidental cases; the **OS sandbox** is the only real containment for the evasion class — see *Enable the OS sandbox*.
- **Auto mode removes you from the loop on the `ask` tier.** With `defaultMode: auto` the classifier resolves the prompts a human used to see. That is the point of the mode, but it means the guards' *ask* rules are advice to a model rather than a stop sign — see [Auto mode](#auto-mode). Set `defaultMode` to `manual` if you want every one of them back in your hands.
- **MCP connectors are logged, not guarded.** `network-guard` sees Bash `curl`/`wget` and the `WebFetch` tool, but MCP tools (Gmail, Google Drive, Slack, Atlassian, browser automation, …) can read files and send data outbound with no guard in the middle. Since the `mcp__.*` audit row above, every such call leaves a line naming the tool and its field names, which is a record after the fact rather than a stop before it. Control the surface by only connecting MCP servers you trust, and use the log to decide which of them deserve a real guard.
- **Guards fail *closed* without jq**, so a missing-jq machine blocks all Bash/file tool calls rather than allowing them unchecked. Keep `jq` installed (the installer checks for it). They fail closed on input jq cannot parse too: a truncated or non-JSON payload is denied rather than read as an empty command. An absent or empty *field* on parseable input is a different case and still passes, since every guard is registered on tools it does not inspect.

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

`MEMORY.md` itself is checked too, reported as `MEMORY.md:<line>` and aged by
the memory each line links to. The index is skipped as a *memory* — it is a list
of links, so it gets no `verify:` resolution — but its one-liners are prose that
goes stale like any other, and the index is the part loaded into context every
session. A stale hook there is read far more often than the memory behind it.

The script is read-only by contract — it never edits, moves, or deletes a
memory, and `/memory-audit` proposes rather than deletes. Deleting on a
heuristic destroys knowledge silently, which is worse than staleness.

**Note:** auto-dream is gated behind a server-side rollout flag
(`tengu_onyx_plover`). Where it is off, the built-in hygiene described above is
not running at all — check `/memory` to see whether it is available to you.
