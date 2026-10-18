# Releases, updating and the hook benchmark

How releases are cut and gated, how a machine updates itself, and how to run
the benchmark. Moved from the README.

## Releases

Releases are tags `vMAJOR.MINOR.PATCH`, each with a GitHub Release and a
`CHANGELOG.md` entry, and they follow Claude Code with no manual step. When
Claude Code ships, the daily Upstream drift run lands the contract bump. The
Release workflow runs when that run completes (and on
`gh workflow run release.yml`, which takes `-f version=v1.2.0` or
`-f bump=minor`) and tags main whenever anything but `CHANGELOG.md` changed
since the previous tag, after `doctor.sh` and, when `hooks/` or
`config/settings.json` changed, `bin/hook-bench.py --gate` against that tag:
no release when a tool class's wait grew more than 20% and 5 ms at p50 or p95,
or when a payload's decision changed and no merged PR body declared it with an
`intended-decisions: <payload ids>` line. A blocked release opens or updates
the "Release blocked" issue, and the next run retries; the next release closes
it. A contract-only release is a patch. The CHANGELOG entry lands by a PR the
workflow opens and merges once CI passes, and each machine's scheduled
`harness-update.sh` installs the tag within six hours. GitHub holds the
`pull_request` runs on a PR `github-actions` opens, since the repo's fork PR
approval policy is `first_time_contributors`, so the workflow approves its own
PR's CI (`.github/approve-pr-ci.sh`): a dispatched run does not count for
main's required checks, and is only the fallback when approval is refused.

The same benchmark, on every third payload, runs on each PR against main and
posts its table to the job summary; `.github/workflows/ci.yml` runs it with
`--gate`, reading the PR's own `intended-decisions:` line, so the job fails on
the same terms. If a merged PR changed a decision without that line, releases
stay blocked until the line is added to its body (`gh pr edit N --body-file ...`)
and the next run, or a dispatched one, retries.

`.github/workflows/release.yml` also runs on a daily cron (`23 19 * * *`, UTC),
a backstop for a PR merged by hand on a day the drift run did not fire. The
first release has no previous tag, so its entry carries no benchmark table; the
workflow writes "No previous tag, so no benchmark for this release." in its
place, and with `hooks/` and `config/settings.json` unchanged since the tag it
skips the benchmark, since both sides would run the same files.

## Updating a machine

To update a machine, run `~/.claude/harness-update.sh`: it fetches tags into
its own clone, `~/.claude/harness-src` (or `$HARNESS_UPDATE_CLONE`; `--repo DIR`
uses DIR), checks the newest release out there detached (it refuses that clone
with local changes or commits), runs `doctor.sh`, and installs only on green.
It never touches the clone `install.sh` ran from: macOS keeps scheduled jobs
out of `~/Desktop`, `~/Documents`, `~/Downloads` and iCloud Drive. The first run
clones from the `origin=` that `install.sh` records in
`~/.claude/harness.version`, else from that clone's origin, else from GitHub,
and logs which. A machine installed from a commit that already holds the
newest tag (`v1.0.0-11-ga6197da` in `~/.claude/harness.version`) is up to date
and is left alone. So is one installed from work the newest tag lacks: a
commit origin does not have or the tag does not include, or uncommitted
changes; update that one with `git pull && bash install.sh`. `--schedule`
runs it at 01:17, 07:17, 13:17 and 19:17 local time (launchd on macOS, a
systemd user timer or crontab on Linux); `--unschedule` removes that. With `--with-cli`, every run, the scheduled ones
too, first upgrades Claude Code when it is a Homebrew cask; npm and native
installs are left to their own updaters, and `--no-cli` turns it off. The
choice is kept in `~/.claude/harness-update.conf`, since a scheduled run takes
no arguments. session-start says when a newer release has been fetched than
the one installed.

## The benchmark by hand

`bin/hook-bench.py --base v1.0.0` compares that tag with the working tree
(`--md` for the table); `--corpus audit` replays this machine's audit log and
its output must stay on the machine.

```
bin/hook-bench.py                                  # latest tag vs the working tree
bin/hook-bench.py --base origin/main --head HEAD   # two refs, same run
bin/hook-bench.py --gate --intended id1,id2 --md bench.md --json bench.json
bin/hook-bench.py --corpus audit                   # this machine's audit log; never publish
```

Every payload in `tests/bench-corpus.jsonl` is fed to each PreToolUse command
hook that side's `config/settings.json` registers for it, both sides back to
back, alternating which side goes first. Wait is the slowest hook of a call,
since Claude Code runs them in parallel; CPU is the sum. `--quick` takes every
third payload, as CI does. The gate (`--gate`) fails on a decision change not
named in `--intended`, or on a p50 or p95 wait that grows past both
`--limit-pct` (default 20) and `--floor-ms` (default 5), for tool classes with
at least `--min-calls` calls (default 20). Absolute numbers depend on the
machine, so only the same-run comparison is a verdict.
