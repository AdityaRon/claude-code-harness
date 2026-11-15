# Keeping up with Claude Code

How the harness notices when Claude Code breaks something it relies on: the
upstream contract, the daily check, and `/insights`.

This harness hard-codes facts about Claude Code: which hook events exist, which
permission modes are valid, what `settings.json` may contain, how large a memory
index loads. Claude Code **auto-updates**, so those facts can break with no commit
landing here. That has already happened twice: auto mode became the product
default, and `SessionEnd` appeared while the session summary was still wired to
`Stop`.

A push-triggered CI run can never catch this, because upstream changes when the
repo stands still. So:

```bash
bash tools/upstream-check.sh
```

`tools/upstream-check.sh` compares the harness against the **installed** CLI, using only
auth-free commands (`claude doctor`, `claude --version`) so CI needs no credentials.
It is a **breakage check only**; it does not assess what a release adds. It checks:

1. the shipped `settings.json` still validates;
2. every hook event `settings.json` registers still exists;
3. the shipped `defaultMode` is the contract's `expected_default_mode` and the CLI
   still accepts it;
4. every top-level settings key the harness sets is still mentioned in the CLI
   (advisory: a string match in a bundled build is not authoritative);
5. the memory index limits (200 lines, 25,000 bytes) that `memory-lint` and
   `memory-verify` enforce still match the ones read out of the CLI;
6. each mod under `skills/` (today the comms panel) still passes `claude plugin test`.

It works by asking the CLI an impossible question: `claude doctor` prints the full
list of valid hook events and permission modes *only* inside the warning for an
unknown one, so the check registers a sentinel to make it enumerate them. Note that
doctor **exits 0 even when it rejects your settings**, so the output is parsed rather
than trusted.

| Exit | Meaning | Action |
|---|---|---|
| 0 | nothing the harness relies on has moved | none |
| 1 | **breakage**: the harness relies on something upstream changed | fix the harness |
| 2 | could not confirm something: a settings key the CLI no longer mentions, or memory limits that could not be read | verify by hand; the daily run hands it to Claude |
| 3 | the check itself could not run | install `jq` / the CLI |

`config/upstream-contract.json` holds the two assumptions that are not already in
`config/settings.json`: `expected_default_mode` and `memory_index_limits`. The hook
events checked are the ones `settings.json` registers, so adopting a new event needs
no edit there. An event upstream adds, a tool, a setting or a release that breaks
nothing is not a signal, and nothing records a decision about it.

`.github/workflows/upstream-drift.yml` runs it **daily on a schedule** plus on
demand, and on any push touching what it reads. It installs the CLI via npm
rather than piping a remote script into a shell, which is exactly what this
harness's own `network-guard` denies.

On exit 1 or 2 the scheduled run hands the result to Claude, once per CLI version
(a branch `claude/contract-<version>`, whether or not its PR is still open). Claude
may edit the bin, hooks, tests, config, docs, rules and `skills/` folders and run
the tests. For exit 2 it first decides whether the report is a real break, and
changes nothing when it is not. Its PR is always a **draft** for you to read, never
landed by the workflow, and the workflow refuses to publish a fix that touches
`.github/`, drops a deny or ask rule, or adds a line holding a credential
(`tests/workflow-gates.test.sh`). A mod that fails `claude plugin test` is a
breakage in the same way, so Claude may fix under `skills/`. A new fix PR closes the
older ones `github-actions` opened, with a link, and deletes their branches; one you
opened is left alone. GitHub holds the `pull_request` runs on a PR `github-actions`
opens, since the repo's fork PR approval policy is `first_time_contributors`, so the
workflow approves its own PR's CI; a dispatched run does not count for those checks
and is only the fallback when approval is refused. After a merge: `bash install.sh`.
Without a token the same run keeps one open issue with the check's output instead. On
push and PR the workflow fails only on exit 1 or 3. When a scheduled or dispatched
run on main completes, the Release workflow runs and tags what landed
([releases.md](releases.md)).

Until 2026-11-15 the check also kept an acknowledgement of every hook event, tool
and setting Claude Code shipped, and a daily run opened a PR assessing each release
("contract: review Claude Code releases up to ..."). That is gone: reading releases
for features is a person's call, not a daily PR.

Setup, once: run `/install-github-app` in Claude Code for this repo. It installs
the Claude GitHub App, which lets the draft PR run CI, and stores
`CLAUDE_CODE_OAUTH_TOKEN`; confirm with `gh secret list`. The fixes use your
plan's usage. On a fork, `tools/fork-setup.sh` checks this and the rest GitHub
leaves off, and `--apply` turns on the workflows and the PR permission.

## /insights

**`/insights` is a local, monthly input, not a CI step.** It needs a login and a
model, and it reads your session history, so its report can quote prompts, paths
and anything a session printed. Keep the report on your machine. Turn what it
suggests into settings by hand, in a PR, and prefer the harness's own evidence:
`grep ' | mcp__' ~/.claude/logs/audit.log` for which connectors you use, and the
`/fewer-permission-prompts` skill for allow rules. Use it only to add `allow` rules; never
loosen `deny` or `ask` from it. `secret-scanner` still gates whatever lands in `settings.json`.
