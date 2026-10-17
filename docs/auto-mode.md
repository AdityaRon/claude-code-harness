# Auto mode

Why the harness pins auto mode, what that changes about the guards, and why it
ships no `autoMode` block. Moved from the README.

The harness ships `permissions.defaultMode: "auto"`. Instead of stopping for a
keystroke on every unrecognised action, a model classifier approves or denies
the prompt; read-only work (reading files, searching code) doesn't go to the
classifier at all. Verify the mode with `/status`, or override per session with
`claude --permission-mode manual`.

**This pins auto mode rather than enabling it.** Claude Code's
[permission-modes doc](https://code.claude.com/docs/en/permission-modes), read
2026-10-17, says auto mode is the built-in starting mode for interactive
terminal and VS Code sessions from v2.1.283 (earlier, only on Pro, Max and Team
plans). Setting `"auto"` explicitly states the intent and keeps it if that
built-in default changes again. A settings value of `"default"` does not mean
the product default: the same doc calls Manual mode's config value `default`
("Its config value is `default`, which is what hooks and SDK integrations
use") and accepts `manual` as an alias. So a machine sitting on `"default"`
starts in Manual, and either value is the opt-out. `claude --help` on 2.1.300
lists the `--permission-mode` choices as
`acceptEdits | auto | bypassPermissions | manual | dontAsk | plan`, the alias
rather than `default`.

**It only works in user settings.** Claude Code will not let a repo-level
`.claude/settings.json` grant `defaultMode: auto`, and the ignored value
*shadows* your user-level mode, so don't copy this harness's `settings.json`
into a project. The installer writes `~/.claude/settings.json`, which is the
right place. `install.sh` owns this key: an existing `defaultMode` is replaced
(with a notice) rather than winning the merge, so re-running the installer
actually flips an older install onto auto.

**What this changes about the guards:**

- **The `deny` tier is unaffected.** PreToolUse hooks run before the permission
  system, so a guard that denies still blocks the call in any permission mode.
  A loaded mod is the exception; see [known-limitations.md](known-limitations.md).
- **The `ask` tier still asks you.** A prompt a guard forces stays a question
  to you in auto mode: the
  [permission-modes doc](https://code.claude.com/docs/en/permission-modes) says
  auto mode "still shows you those prompts". What the classifier decides is everything the guards *don't*
  ask about, such as a `curl` to this machine or a command no guard
  inspects. So a guard's ask is the way to be asked explicitly; anything you want
  stopped unconditionally belongs in `permissions.deny` or `autoMode.hard_deny`.
- **Some `permissions.allow` entries are disregarded.** Auto mode ignores allow
  entries it classes as classifier-bypassing, so a broad wildcard may not buy
  you the silence it used to. Run `/doctor` inside a session to list which of
  your entries it's ignoring.

**Tuning the classifier.** Auto mode reads its rules from a top-level
`autoMode` key, `{environment, allow, soft_deny, hard_deny}`:

```bash
claude auto-mode defaults   # the shipped rules (17 allow, 65 soft_deny, 1 hard_deny, 20 environment)
claude auto-mode config     # the effective rules: yours where set, defaults otherwise
claude auto-mode critique   # AI review of your custom rules
claude auto-mode reset      # drop your autoMode section, back to shipped defaults
```

**The harness deliberately ships no `autoMode` block.** `auto-mode config`
describes the resolution as *"your settings where set, defaults otherwise"*,
i.e. setting a category looks like it **replaces** the shipped rules for that
category, not adds to them. Shipping a handful of `soft_deny` rules could
therefore silently drop the 65 that come with Claude Code, which is a bad trade
for a security harness. Write your own rules if you want them, then confirm
what survived with `claude auto-mode config` before trusting it.
