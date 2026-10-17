# Keeping up with Claude Code

How the harness notices when Claude Code changes under it: the upstream
contract, the daily drift check, and `/insights`. Moved from the README.

This harness hard-codes facts about Claude Code: which hook events exist, which
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
accepted, then reports events upstream has that nobody here has assessed.

It works by asking the CLI an impossible question: `claude doctor` prints the full
list of valid hook events *only* inside the warning for an unknown one, so the
check registers a sentinel event to make it enumerate them. Note that doctor
**exits 0 even when it rejects your settings**, so the output is parsed rather than
trusted.

| Exit | Meaning | Action |
|---|---|---|
| 0 | contract holds | none |
| 1 | **breakage**: the harness relies on something upstream changed | fix the harness |
| 2 | upstream grew: new capability nobody has assessed | adopt it, or record the decision |
| 3 | the check itself could not run | install `jq` / the CLI |

`upstream-contract.json` holds the assumptions. `acknowledged_hook_events` is *not*
"events we use"; it is "events a human has looked at and decided about", and
`notes_on_unused_events` records why each unused one was skipped. When upstream adds
an event the check fails with exit 2 until someone either hooks it or writes down
why not. **That deliberate nag is the mechanism that keeps this harness current
instead of quietly stale.**

`.github/workflows/upstream-drift.yml` runs it **daily on a schedule** plus on
demand, and on any push touching the assumptions. It installs the CLI via npm
rather than `curl … | bash`: piping a remote script into a shell is exactly what
this harness's own `network-guard` denies.

Sections 1 to 4 only see what `doctor` and the binary enumerate, so a new tool or
settings key arrives silently. Section 6 closes that: it reads the changelog
(`~/.claude/cache/changelog.md` locally; CI downloads it and passes
`CLAUDE_CHANGELOG_PATH`), lists the harness-relevant entries for every release after
`last_verified_version`, and exits 2 until someone assesses them and bumps that
field. Entries naming something the contract already has a decision for are
included, because that decision may now be stale.

When the daily run finds a new release it triages first: if no entry since the pin
matches the section 6 filter (1 of the 21 releases 2.1.280 to 2.1.302), it moves
`last_verified_version` itself. Otherwise Claude reviews the releases and edits only
`upstream-contract.json`, once per release. A PR whose body starts with `Nothing to
decide.` is opened ready and merged by the workflow once its CI passes; one that
starts with `Decide:` is a **draft** assigned to you, with new
settings and anything touching deny, ask or a guard as questions, never as changes.
Landing on its own needs a branch rule `github-actions` can satisfy; as of 2026-10-17
`main` needs no approval and requires the `doctor.sh` and `shellcheck` checks.
GitHub holds the `pull_request` runs on a PR `github-actions` opens, since the
repo's fork PR approval policy is `first_time_contributors`, so the workflow
approves its own PR's CI; a dispatched run does not count for those checks and is
only the fallback when approval is refused. A new
contract PR closes the older ones `github-actions` opened, with a link, and deletes
their branches; one you opened is left alone. After any merge: `bash install.sh`.
Without a token the same run keeps one open issue with section 6 instead. Locally,
`session-start` says when the installed CLI is past the contract. On push and PR
the workflow fails only on exit 1 or 3; exit 2 is the scheduled run's to clear.
When a scheduled or dispatched run on main completes, the Release workflow
runs and tags what landed ([releases.md](releases.md)).

Setup, once: run `/install-github-app` in Claude Code for this repo. It installs
the Claude GitHub App, which lets the draft PR run CI, and stores
`CLAUDE_CODE_OAUTH_TOKEN`; confirm with `gh secret list`. The reviews use your
plan's usage.

## /insights

**`/insights` is a local, monthly input, not a CI step.** It needs a login and a
model, and it reads your session history, so its report can quote prompts, paths
and anything a session printed. Keep the report on your machine. Turn what it
suggests into settings by hand, in a PR, and prefer the harness's own evidence:
`grep ' | mcp__' ~/.claude/logs/audit.log` for which connectors you use, and the
`/fewer-permission-prompts` skill for allow rules. Use it only to add `allow` rules; never
loosen `deny` or `ask` from it. `secret-scanner` still gates whatever lands in `settings.json`.
