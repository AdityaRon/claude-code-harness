# Releases, updating and the hook benchmark

How releases are cut and gated, how a machine updates itself, and how to run
the benchmark. Moved from the README.

## Releases

Releases are tags `vMAJOR.MINOR.PATCH`, each with a GitHub Release and a
`CHANGELOG.md` entry, and are cut with no manual step. When
Claude Code breaks something the harness relies on, the daily Upstream drift run
opens a draft fix for you to read. The Release workflow runs when that run completes (and on
`gh workflow run release.yml`, which takes `-f version=v1.2.0` or
`-f bump=minor`) and tags main whenever anything but `CHANGELOG.md` changed
since the previous tag, after `doctor.sh` and, when `hooks/` or
`config/settings.json` changed, `tools/hook-bench.py --gate` against that tag:
no release when a tool class's wait grew more than 20% and 5 ms at p50 or p95,
when a payload's decision changed and no merged PR body declared it with an
`intended-decisions: <payload ids>` line, or when a payload's hooks started
more processes (`--launches strace`) and no merged PR body declared it with an
`intended-launches: <payload ids>` line. A blocked release opens or updates
the "Release blocked" issue, and the next run retries; the next release closes
it. A contract-only release is a patch. The CHANGELOG entry lands by a PR the
workflow opens and merges once CI passes, and each machine's scheduled
`harness-update.sh` installs the tag within six hours. GitHub holds the
`pull_request` runs on a PR `github-actions` opens, since the repo's fork PR
approval policy is `first_time_contributors`, so the workflow approves its own
PR's CI (`.github/approve-pr-ci.sh`): a dispatched run does not count for
main's required checks, and is only the fallback when approval is refused.

The same benchmark, on every payload, runs on each PR that changes `hooks/` or
`config/settings.json` against main (others skip it, since both sides would run
the same files) and posts its table to the job summary; `.github/workflows/ci.yml` runs it with
`--gate` and `--launches strace`, reading the PR's own `intended-decisions:` and
`intended-launches:` lines, so the job fails on the same terms. If a merged PR
changed a decision or started more processes without its line, releases stay
blocked until the line is added to its body (`gh pr edit N --body-file ...`)
and the next run, or a dispatched one, retries.

Both gates run through `.github/bench-gate.sh`, which takes
`tools/hook-bench.py` and `tests/bench-corpus.jsonl` from the base (main for a
PR, the previous tag for a release) with `git show`, not from the change under
test, and says so on the summary's first line ("Gate script and corpus from
`<sha>`"). A change that deletes the payload its hook edit would flip, or
loosens the gate's limits in its own copy, is still judged by the base's.
Payloads with ids new in the change are added to the base's corpus. One the
change removes or changes needs its id on a `removed-payloads: <payload ids>`
line in the PR body (a release reads the merged PRs' lines, as for the
`intended-*` lines); without one the base's payload runs and the gate fails.
That check runs even when the benchmark is skipped, since a deletion merged
alone would be gone from the next PR's base. A change that edits
`tools/hook-bench.py` runs the gate a second time with its own copy, and fails
if either run fails. The workflow files and `.github/bench-gate.sh` themselves
still come from the PR under `pull_request`, so an edit to them is the one way
a PR changes its own gate, and it shows in the diff under `.github/`.

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

`tools/hook-bench.py --base v1.0.0` compares that tag with the working tree
(`--md` for the table); `--corpus audit` replays this machine's audit log and
its output must stay on the machine.

```
tools/hook-bench.py                                  # latest tag vs the working tree
tools/hook-bench.py --base origin/main --head HEAD   # two refs, same run
tools/hook-bench.py --gate --intended id1,id2 --md bench.md --json bench.json
tools/hook-bench.py --corpus audit                   # this machine's audit log; never publish
tools/hook-bench.py --launches auto                  # also count the processes each hook starts
```

Every payload in `tests/bench-corpus.jsonl` is fed to each PreToolUse command
hook that side's `config/settings.json` registers for it, both sides back to
back, alternating which side goes first. A call's hooks are launched together,
as Claude Code does: wait is from the first launch to the last exit, so hooks
that share the cores pay for it; CPU is the sum of each hook's own. The
per-hook table runs each hook alone. `--serial` is the earlier model (each hook
alone, wait the slowest), which scored separate hooks as if each had its own
core: on a 4-core runner it read the Bash dispatcher as 23% slower than v1.3.1
when, launched together, it is 18% faster (#218). `--quick` takes every
third payload, for a quick local look; CI no longer uses it, since sampling let a
decision change reach the release gate (#251). The gate (`--gate`) fails on a decision change not
named in `--intended`, or on a p50 or p95 wait that grows past both
`--limit-pct` (default 20) and `--floor-ms` (default 5), for tool classes with
at least `--min-calls` calls (default 20). Absolute numbers depend on the
machine, so only the same-run comparison is a verdict.

`--launches` adds a pass that counts the processes each hook starts on each
payload, run alone once, and a table of them. With `--gate`, a payload whose
hooks start more on head than on base (execs plus forks, summed over its
hooks) fails unless `--intended-launches` names it, as does one a side could
not count; fewer always passes. A machine
whose endpoint agent inspects each process start pays 16 to 27 ms for one
(`true`, `bash -c :`, `jq -n 1`, the maintainer's work Mac) where a CI runner
pays 0.5 to 1.9 ms, so a count shows a cost the runner's clock hides.
`--launches strace` (Linux) counts each execve past the hook's own bash and each
new process, a `$( )` included; the PR bench runs it. `--launches shim` (macOS)
runs a copy of the hooks whose `lib.sh` puts a shim for every program name
first on PATH, and counts the execs found through PATH: no fork, and no
program started by its full path. `auto` takes strace where it works.
