# Customization

Machine-local rules, your own hooks, the network allowlist, environment knobs
and the sandbox. Moved from the README.

## What stays out of this repo

`config/settings.json` and `rules/` hold portable content only, because this
repo is public: nothing naming a person, ticket, cluster or customer. An allow
rule for a work tool or an internal CLI goes in `~/.claude/local-settings/`,
folded in on every install (below). Machine-local rules go straight into
`~/.claude/rules` as `local-*.md`, a name nothing here may ship, and the install
never deletes what it did not put there.

## What an install keeps

From `config/merge-settings.jq`: the merge is `shipped * yours`, so for any key
you set, your value wins, down to each leaf of an object such as `env` or
`sandbox`. A list you set (say `sandbox.network.allowedDomains`) replaces the
shipped list rather than adding to it. The exceptions: `permissions.allow` and
`permissions.deny` are unioned (minus `config/retired-rules.json`), the harness
owns `permissions.defaultMode` and `statusLine` and rewrites them, and it owns
the hook entries it installed while keeping yours.

## Allow rules, hooks and hosts

**Allow rules for tools this public repo cannot name** (work skills, internal
CLIs): put them in `~/.claude/local-settings/<name>.json`. Every install folds
each file's `permissions.allow` and `permissions.deny` into the merge and reads
nothing else from it, so a fragment cannot change the mode, hooks or status line.
A repo that ships your work skills can keep its fragment and symlink it in:
```json
{ "permissions": { "allow": ["Bash(~/.claude/skills/my-tool/run.sh:*)", "Bash(tsh status:*)"] } }
```
An allow rule only skips the prompt; the guards still run first. They read
the command Claude runs, not what a script runs: a `kubectl create` Claude
types is still escalated by `kubectl-guard`, one inside an allowed script is
seen by no guard at all.

**Your own hooks**: put the script in `~/.claude/hooks` under a name this repo
does not use, and add its entry to `hooks` in `~/.claude/settings.json`. Every
install keeps both and says how many entries it preserved. A file named like a
shipped hook is overwritten on the next install, so change those here and run
`bash install.sh`. When Claude writes into `~/.claude/hooks`, `config-guard`
asks you first.

**Turning a shipped hook off**: there is no per-hook switch. Deleting its entry
from `~/.claude/settings.json` lasts until the next install, which writes the
harness's hook entries back. To keep it off, remove the entry from
`config/settings.json` in your clone and run `bash install.sh`. A clone with
local changes or commits is one `~/.claude/harness-update.sh` refuses, so update
that machine with `git pull && bash install.sh` instead.

**Hosts this machine reaches often** (an internal log service, a vendor API):
```
~/.claude/net-allowlist.sh candidates 30   # hosts network-guard asked about, most first
~/.claude/net-allowlist.sh add logs.internal.example
```
`add` writes `netAllowlist` in `~/.claude/local-settings/net-allowlist.json`
(any fragment there may carry one). `network-guard` reads it on every call, so
it applies at once and survives every install. An entry covers the host and its
subdomains, for GETs only: a request with a body still asks, unless the host was
added with `add --body` (POST, PUT and PATCH then run; DELETE still asks; same
refusals). Entries that would
allow too much are refused: a name with no dot, a public suffix (`co.uk`), an IP
address, shared hosting (`github.io`), and tunnel or request-capture services
(`ngrok`, `webhook.site`). When Claude runs the script with anything but `list`,
`candidates` or `remove`, or writes into that folder, the guard asks you first;
the Edit and Write tools are denied there. An allow rule never silenced
`network-guard`: a `WebFetch(domain:logs.internal.example)` or
`Bash(curl -s https://logs.internal.example*)` entry in `permissions.allow` skips
the prompt, and a guard's ask comes before it is consulted. After
`git pull && bash install.sh`, move such hosts here with `add`. `candidates`
prints your hosts, so keep its output local.
A new machine has no history for `candidates`, so carry the list instead: keep
`net-allowlist.json` beside your work skills and symlink it in, as with allow
rules above (`add` writes through the link), and seed it once on the machine
that has the history. After that, an ask about an unlisted host names the `add`
command for that host, so each new one costs one prompt and one confirm.

**Extend the network allowlist per-project** (same refusals apply):
```json
{ "env": { "CLAUDE_NET_ALLOWLIST": "internal.example.com api.myservice.io" } }
```

## Environment knobs

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

## Auto-compact

**Pull auto-compact in, so long sessions stop running at near-full context.**
`config/settings.json` ships the value below; your own `env` value wins on
install. Auto-compact does not fire at a percentage. It fires at
`assumed_window − min(max_output_tokens, 20000) − 13000`, so on a 1M-token model
the default trigger is **967k**, and you spend the back half of every session
paying for a near-full context on every turn. Shrinking the *assumed* window
pulls the trigger in:
```json
{ "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "600000" } }
```
600000 → effective 580k → **compacts at 567k**, with the summary precomputed at
≈464k (at the default 0.2 buffer) so the swap is still instant. The CLI takes `min(real_window, configured)`,
so this is a **no-op on any model with a ≤600k window** and only bites on 1M
sessions. Blocking ("context limit reached") still uses the real window.

Use a **bare decimal integer**. The value is parsed with `parseInt` as a
fallback, and anything unparseable silently falls back to the 100000 *floor*,
so `"600k"` reads as `600`, floors to `100000`, and would compact a 1M session at
67k. Accepted range is 100000 to 1000000; outside it the value is floored or
capped without any error. `tests/install-merge.test.sh` asserts all of this.

For true percentage semantics instead, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` takes
1 to 100 as a percent of the effective window and is clamped so it can only ever
*lower* the trigger. It collapses the precompute head start onto the trigger
itself, so compaction stalls while it summarises rather than swapping in.

## OS sandbox

**Try the OS sandbox** (off by default). Run these yourself, with `!` as the first character of a message, or in a terminal. Once it is on, Claude cannot switch it off: a sandboxed command cannot write settings.
```
~/.claude/sandbox.sh on        # sandbox.enabled = true in ~/.claude/settings.json (backup kept)
~/.claude/sandbox.sh status    # also shows managed settings, whose sandbox values win over yours
~/.claude/sandbox.sh off       # back to how it was
```
Running sessions use the change from their next command. Ask Claude to run
`~/.claude/sandbox-trial.sh` and the four direct checks it prints. Each probe says
PASS, FAIL or INFO; a FAIL on a tool you use is the cue to switch it off and adjust
`sandbox` in `config/settings.json` first.

To enable it by hand instead, set it globally in `~/.claude/settings.json`, or per-project in `.claude/settings.json`:
```json
{ "sandbox": { "enabled": true } }
```
Extend its allowlist under `sandbox.network.allowedDomains`. In
`~/.claude/settings.json` your list replaces the shipped one on install, so copy
the shipped domains into it first.
