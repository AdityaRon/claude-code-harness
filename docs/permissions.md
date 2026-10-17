# Settings and permission rules

What `config/settings.json` ships, and how Claude Code matches the Bash rules
in it. Moved from the README. What an install keeps of yours is in
[customization.md](customization.md).

## Settings shipped

| Setting | Value | Effect |
|---|---|---|
| `permissions.defaultMode` | `auto` | Every session starts in **auto mode**: a model classifier adjudicates permission prompts instead of stopping for a keystroke. See [auto-mode.md](auto-mode.md) for what this changes about the guards. |
| `fileCheckpointingEnabled` | `true` | Snapshots files before edits so `/rewind` can restore them |
| `effortLevel` | `high` | Default reasoning effort (portable across machines). Shipped as `xhigh` until 2026-10-17; the first install after that moves an installed `xhigh` to `high` once (it then writes `~/.claude/state/effort-high.migrated`), and an `xhigh` you set afterwards is kept. |
| `skipAutoPermissionPrompt` | `true` | Pre-accepts the auto-mode opt-in dialog, so auto mode is live on first launch rather than waiting behind a dialog |
| `sandbox` | off by default | OS sandbox (Seatbelt on macOS, bubblewrap on Linux) around each command Claude runs: writes only to the project and TMPDIR (Claude Code keeps `~/.claude` read-only to commands, the session scratch folder included), no reads of `~/.ssh`, network only to listed domains, and listening on localhost allowed for dev and test servers (`allowLocalBinding`; Claude Code then serves no device tools from this machine to cloud sessions). `~/.claude/sandbox.sh on`/`off`/`status` flips it per machine and every install keeps your choice; `~/.claude/sandbox-trial.sh` reports what works under it. docker, gh, kubectl, tsh, gcloud and terraform are in `excludedCommands` (incompatible or failing TLS under it), so they run as today, guards included, but only when the command is that tool alone: `docker ps | head` runs sandboxed. |
| `includeCoAuthoredBy` | `true` | Adds `Co-authored-by: Claude` to commits |
| `syncClaudeAiSkills` / `syncClaudeAiPlugins` | `false` | Keeps the skills and plugins enabled on your claude.ai account out of terminal sessions. Each synced skill adds its description to every session, and a synced plugin can run hooks or inline shell under this machine's allow rules. They still work on claude.ai. Set either to `true` in `~/.claude/settings.json` to opt back in; the install keeps your value. |
| `remoteControlAtStartup` | `true` | Every interactive session connects to [Remote Control](https://code.claude.com/docs/en/remote-control), so you can pick it up from claude.ai or the Claude app. Needs a claude.ai login. Anyone signed in to your account can then steer the session; turn on **Require trusted devices** in your claude.ai account settings to tie that to known devices. Set `false` to opt out; the install keeps your value. |
| `isolatePeerMachines` | `true` | With Remote Control on, a `SendMessage` to a session on another machine waits for your approval. Sessions on this machine are unaffected. |
| `autoDreamEnabled` | `true` | Turns on auto-dream, Claude Code's background memory consolidation, where its server flag allows it; elsewhere it does nothing. It may delete memory files it finds contradicted, unlike the harness's memory tools, which never delete. See [memory.md](memory.md). Set `false` to opt out; the install keeps your value. |
| `statusLine` | `~/.claude/statusline.sh`, `refreshInterval` 300 | The status line in [hooks.md](hooks.md). Harness-owned: every install writes it. |
| `env` | `CLAUDE_AUDIT_LOG`, `CLAUDE_TRANSCRIPT_DIR`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` `600000` | Where the audit log and pre-compact backups go, and when auto-compact fires; see [customization.md](customization.md). |
| `permissions.allow` | Scoped allowlist | Covers common safe ops: `npm test/run lint/build`, `pytest`, `python3`, `poetry run/install/lock`, `gh run/search`, `cargo test`, `go test`, `ls`, `grep`, `git status`, etc. Read-only verbs added from the audit-log census: `git grep/rev-parse/ls-tree/ls-files/show-ref/cat-file/blame/describe/merge-base/shortlog`, `git remote -v`, `git worktree list`, and read-only `docker` subcommands (`run`/`exec`/`rm`/`cp` deliberately excluded). Interpreter wildcards (`python3`, `poetry run`) are allowed because a permission `allow` only skips the *prompt*; the PreToolUse guards still run, and `interpreter-guard` inspects inline `-c`/`-e`/heredoc code even when wrapped in a runner (`poetry run python -c …`). `gh api` and `kubectl` are both allowlisted, but they are not equally safe. `kubectl` is covered by `kubectl-guard`, which asks before every mutating verb wherever it sits in the command. `gh api` has **no** equivalent coverage: it can POST/DELETE through the GitHub API and `network-guard` never inspects it, so that entry is a deliberate convenience trade rather than a guarded one. With the OS sandbox off, an auto-approved `python3 script.py` runs the script's contents unscanned; enable the sandbox for containment. |
| `permissions.deny` | `git push --force`, `git reset --hard`, `sudo`, `gh auth token`, … (`rm -rf` moved to `rm-guard`, `kubectl delete` to `kubectl-guard`, which asks on every spelling) | Deny always wins over allow. Over a loaded mod it wins only on a machine with managed settings or a Team/Enterprise login; see [known-limitations.md](known-limitations.md). The deny list also covers writes into the installed-plugin cache `~/.claude/plugins`, `claude plugin install`/`enable`/`update`/`marketplace add`, and `--plugin-url` |

## How Bash rules actually match

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
  does **not**, so `VAR=x cmd` fails closed and falls to the classifier. This
  is the single largest source of friction here (7,171 of 40,346 commands) and
  **no rule can fix it**: the first token contains a machine-specific value.
  Put the binary first instead.
- **`git -C <path>` is not a wrapper and is not stripped.** A rule written
  `Bash(git reset --hard:*)` therefore never matches `git -C /tmp/x reset
  --hard`; `git-guard` denies that form instead.
- **A `*` may appear anywhere in a rule, but not beside a trailing `:*`.**
  2.1.292 reads `Bash(git * push --force:*)` as a literal prefix, so its `*`
  matches only a literal `*`, and it warns about the rule at every launch.
  Write the wildcard form without `:*`, as in `Bash(claude * --plugin-url*)`.
- **Whether `~` is expanded is undocumented.** Rather than guess,
  `merge-settings.jq` emits a `$HOME`-expanded twin for every rule containing
  `~/`, so both spellings are present whichever way the CLI compares them.
- **The installer only widens, except for retired rules.** `merge-settings.jq`
  unions the allow and deny lists, so dropping a rule from `config/settings.json`
  does not remove it from a machine that already has it, unless the rule is also
  listed in `config/retired-rules.json`: every install takes those out of
  `~/.claude/settings.json` and says so. A local-settings fragment that lists a
  retired rule keeps it. Narrowing a rule without retiring it (say `Bash(kubectl:*)`
  down to `Bash(kubectl get:*)`) still means editing `~/.claude/settings.json` by
  hand.
- **Allowlisting a wrapper script bypasses every guard**; see
  [guards.md](guards.md#allowlisting-a-wrapper-script-bypasses-every-guard).

The practical consequence: **a hook sees the whole command string, a permission
rule sees only a prefix.** Enforcement that must not be evadable belongs in a
guard, with the deny list as a backstop, not the other way round. A Claude Code
mod (2.1.287+) runs above both; see [known-limitations.md](known-limitations.md).
