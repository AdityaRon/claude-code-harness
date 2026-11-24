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
| `isolatePeerMachines` | `true` | With Remote Control on, a `SendMessage` waits for your approval when Claude Code cannot show the target runs on this machine: a Remote Control or cloud session, or a name it could not resolve just then (the account's session list could not be checked). A session on this Mac that it reaches only through Remote Control asks too. A session it finds running on this machine is unaffected. Set `false` to drop the prompt; in auto mode the classifier then reviews each cross-session message. Asks between two sessions on one machine come two ways. On the work Mac (CLI 2.1.330, session transcripts 11-17 to 11-22), 7 of about 600 sends asked. 4 were bare names that resolved to a Remote Control row; one of those was sent while its target restarted and had no local socket (sent 19:10Z, socket back 19:16Z). 3 were `bridge:` addresses copied from a message's `from`: Claude Code tells a session to reply that way, and the gate asks on every `bridge:` address, even one whose session runs here (the 2.1.330 source checks only the scheme). The `peer-redirect` hook denies such a send when that session runs here and points the model at its ListAgents `name [ref]`. Headless haiku trials on 2.1.330 (this Mac, 2026-11-22), each a reply to a simulated `bridge:` message: in default mode, 3 of 3 resends were delivered. In auto mode the classifier allowed the resend in 5 of 5 whose message carried `from-name` and refused it in 5 of 5 without; a resend to a `uds:` path named only in the deny was refused in 4 of 5 (the fifth prompt told the model to follow a redirect). On the work Mac, 32 of 32 messages that arrived over Remote Control carried `from-name` (9 transcripts, read 2026-11-23), so the hook is live in auto mode too, as well as default and acceptEdits, and silent in plan and bypassPermissions, which no probe covered. `peer-redirect:redirect` on the shadow list ([shadow-mode.md](shadow-mode.md)) mutes it in auto mode alone. A name that cannot be the address (not plain text, or shared with another live session here; 3 of 16 live sessions on the work Mac, 11-23) is never shown: the deny gives the session's `uds:` socket instead. In default mode that delivered 6 of 6 (headless haiku, 11-23; each time the model sent to the session's ListAgents row). In auto mode it is on the shadow list as `peer-redirect:redirect-uds`, for the 4 of 5 refusals above. The restart window is a line in `rules/collaboration.md`: re-run ListAgents in a minute rather than send. Not checked: whether a session keeps its Remote Control id across a restart, whether SendFile acts the same, and anything on an interactive session or a larger model. |
| `autoDreamEnabled` | `true` | Turns on auto-dream, Claude Code's background memory consolidation, where its server flag allows it; elsewhere it does nothing. It may delete memory files it finds contradicted, unlike the harness's memory tools, which never delete. See [memory.md](memory.md). Set `false` to opt out; the install keeps your value. |
| `statusLine` | `~/.claude/statusline.sh`, `refreshInterval` 300 | The status line in [hooks.md](hooks.md). Harness-owned: every install writes it. |
| `env` | `CLAUDE_AUDIT_LOG`, `CLAUDE_TRANSCRIPT_DIR`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` `600000` | Where the audit log and pre-compact backups go, and when auto-compact fires; see [customization.md](customization.md). |
| `permissions.allow` | Scoped allowlist | Covers common safe ops: `npm test/run lint/build`, `pytest`, `python3`, `poetry run/install/lock`, `gh run/search`, `cargo test`, `go test`, `ls`, `grep`, `git status`, etc. Read-only verbs added from the audit-log census: `git grep/rev-parse/ls-tree/ls-files/show-ref/cat-file/blame/describe/merge-base/shortlog`, `git remote -v`, `git worktree list`, and read-only `docker` subcommands (`run`/`exec`/`rm`/`cp` deliberately excluded). Interpreter wildcards (`python3`, `poetry run`) are allowed because a permission `allow` only skips the *prompt*; the PreToolUse guards still run, and `interpreter-guard` inspects inline `-c`/`-e`/heredoc code even when wrapped in a runner (`poetry run python -c …`). Only read-only `kubectl` verbs are allowlisted (`get`, `describe`, `logs`, `top`, `explain`, `api-resources`, `api-versions`, `version`, `cluster-info`, `config view`/`get-contexts`/`current-context`, `auth can-i`, `events`); `Bash(kubectl:*)` is retired. `gh api` is allowlisted with **no** guard behind it: it can POST/DELETE through the GitHub API and `network-guard` never inspects it, so that entry is a deliberate convenience trade rather than a guarded one. With the OS sandbox off, an auto-approved `python3 script.py` runs the script's contents unscanned; enable the sandbox for containment. |
| `permissions.ask` | Credential reads the read prefixes would allow: `Bash(kubectl get secret:*)`, `Bash(kubectl get secrets:*)`, and `Bash(kubectl *get *K)`, `Bash(kubectl *get *K *)`, `/*`, `,*` and `.*` for K = `secret` and `secrets`, which match the kind in any position behind any flags; `config view --raw` and `--flatten`, as `Bash(kubectl config view --raw:*)` and `Bash(kubectl *config view*--raw*)`. Deletions by `disk-space.py`: `Bash(python3 ~/.claude/disk-space.py prune --apply:*)`, `clone --apply:*`, `bazel --sweep --apply:*`, `transcripts --apply:*` and `transcripts --restore:*` (a restore moves files too), and each again without `python3`. The script refuses `--apply` anywhere but right after `prune`, `clone`, `transcripts` or `bazel --sweep`, and refuses abbreviations such as `--app`, so flags before `--apply` cannot step past the prefix. Other spellings miss these rules (`/usr/bin/python3 …`, an env prefix, `"$HOME/.claude/…"`, `bash -c`, a relative path after `cd`), and `rm-guard`'s `disk-space-apply` rule asks on those. It asks on any command that names both `disk-space.py` and `--apply`, so a commit message or a `grep` naming both asks too. A spelling built to hide either word gets past it: a glob (`disk-space.p?`), a substitution (`disk-$(echo space).py`, `--app${X}ly`) or a renamed copy. Guard hardening is frozen (#237), and the digest still binds what an apply deletes to the listing it repeats. No headless probe has checked these ten rules yet. A headless probe on 2.1.325 matched each order and form these name, in default and auto mode; it showed that a `:*` prefix stops at a word (`get secret:*` misses `get secrets`) and that a trailing ` *` needs a word after it. An upper-case kind (`get Secret`) is not matched, and a kind ending in `secrets` (`sealedsecrets`) asks too. Also `Bash(kubectl VERB *)` and `Bash(kubectl * VERB *)` for each mutating verb: `delete`, `apply`, `create`, `replace`, `patch`, `edit`, `scale`, `drain`, `cordon`, `uncordon`, `taint`, `label`, `annotate`, `set`, `run`, `exec`, `cp`, and `rollout restart`/`undo`/`pause`/`resume` | A headless probe on 2.1.325 showed an ask rule wins over a matching allow, and the space-wildcard form matches a verb behind global flags (`kubectl -n prod delete pod x`), which a `:*` prefix rule does not. `kubectl-guard` asks on these verbs too. A read naming a verb as a word now asks (`kubectl auth can-i delete pods`): no allow rule can exempt it. |
| `permissions.deny` | `git push --force`, `git reset --hard`, `sudo`, `gh auth token`, … (`rm -rf` moved to `rm-guard`, `kubectl delete` to `kubectl-guard`, which asks on every spelling it reads: [guards.md](guards.md)) | Deny always wins over allow. Over a loaded mod it wins only on a machine with managed settings or a Team/Enterprise login; see [known-limitations.md](known-limitations.md). The deny list also covers writes into the installed-plugin cache `~/.claude/plugins`, `claude plugin install`/`enable`/`update`/`marketplace add`, and `--plugin-url` |

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
  unions the allow, ask and deny lists, so dropping a rule from `config/settings.json`
  does not remove it from a machine that already has it, unless the rule is also
  listed in `config/retired-rules.json`: every install takes those out of
  `~/.claude/settings.json` and says so. A local-settings fragment that lists a
  retired rule keeps it. So narrowing a rule means retiring the old one, as
  `Bash(kubectl:*)` was when the read verbs replaced it.
- **Allowlisting a wrapper script bypasses every guard**; see
  [guards.md](guards.md#allowlisting-a-wrapper-script-bypasses-every-guard).

The practical consequence: **a hook sees the whole command string, a permission
rule sees only a prefix.** Enforcement that must not be evadable belongs in a
guard, with the deny list as a backstop, not the other way round. A Claude Code
mod (2.1.287+) runs above both; see [known-limitations.md](known-limitations.md).
