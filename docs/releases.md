# Releases, updating and the hook benchmark

How releases are cut and gated, how a machine updates itself, and how to run
the benchmark. Moved from the README.

## Releases

Releases are tags `vMAJOR.MINOR.PATCH`, each with a GitHub Release and a
`CHANGELOG.md` entry: the PRs merged since the previous tag, grouped, and the
hook benchmark against it. The Release workflow makes one weekly when main has
moved, or on demand (`gh workflow run release.yml -f version=v1.2.0`), after
`doctor.sh` and `bin/hook-bench.py --gate` pass: no release when a tool
class's wait grew more than 20% and 5 ms at p50 or p95, or when a payload's
decision changed and no merged PR body declared it with an
`intended-decisions: <payload ids>` line. The same benchmark, on every third
payload, runs on each PR against main and posts its table to the job summary;
`.github/workflows/ci.yml` runs it with `--gate`, reading the PR's own
`intended-decisions:` line, so the job fails on the same terms. If a merged PR changed a decision without that line, the weekly release stays
blocked until the line is added to its body (`gh pr edit N --body-file ...`)
and the workflow is dispatched again.

The first release has no previous tag, so its entry carries no benchmark table;
`.github/workflows/release.yml` writes "No previous tag, so no benchmark for
this release." in its place.

## Updating a machine

To update a machine, run `~/.claude/harness-update.sh`: it fetches tags,
checks the newest release out of the clone `install.sh` ran from (detached;
it refuses a clone with local changes or commits), runs `doctor.sh`, and
installs only on green. `--schedule` runs it daily (launchd on macOS, a
systemd user timer or crontab on Linux); `--unschedule` removes that.
session-start says when a newer release has been fetched than the one
installed.

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
