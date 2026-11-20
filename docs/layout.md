# Repo layout

Where each file in this repo lives and what it is for. Moved from the README;
what an install writes to `~/.claude` is in [install.md](install.md#file-layout-after-install).

The install and test entry points, the changelog and the license sit at the root;
everything else is grouped by what it is.

```
install.sh  doctor.sh    ← install once per machine; run every suite in tests/
CHANGELOG.md             ← one entry per release
LICENSE                  ← MIT
.claude/skills/verify/   ← /verify in a session in this clone (doctor.sh --changed, then the stamp);
                           not installed
bin/                     ← every file installed flat to ~/.claude by install.sh
  statusline.sh  harness-update.sh  net-allowlist.sh  sandbox.sh  sandbox-trial.sh
  skills-sync.sh         ← installs the claude-code-skills release config/skills.pin names
  memory-verify.sh  memory-fix.sh  memory-index.sh  memory-provenance.sh
  session-route.sh       ← which session owns this PR (docs/session-routing.md)
  relocate-clones.sh     ← moves a clone out of ~/Desktop, ~/Documents or ~/Downloads (docs/known-limitations.md)
  spend-report.py        ← what sessions, subagents and loop ticks cost, and what caused each context
                           rewrite (a lapsed cache TTL, a compaction), from local transcripts
  disk-space.py          ← what job folders and Bazel output bases hold (report, bazel); harness-update.sh
                           records the totals, large transcripts and the guards' p90 once a day for
                           session-start's warnings (doctor.sh --disk);
                           prune, clone and bazel --sweep list what is safe to delete and delete it by digest
  tracker-prune.py       ← moves a tracker's settled rows to <name>-archive.md beside it; a dry run unless --write
  permission-friction.py ← which guard asks and denies cost the most, from local transcripts
  hook-latency.py        ← each hook's wall time per day, from local transcripts (doctor.sh --latency)
  hooknames.py           ← names the hook a transcript record numbers, for the two above: by the guard
                           whose words are in the reason on its own stdout, else by settings.json
  harness-checkup.py     ← the three largest costs on this machine, from the tools above and
                           memory-verify; offline, and it prints no prompt text and no dollar amounts
tools/                   ← run from the clone only, by CI, releases and whoever maintains a fork
  upstream-check.sh      ← the daily breakage check
  fork-setup.sh          ← what a fork's GitHub settings need before the workflows run
  hook-bench.py  release-notes.sh  ← the release benchmark and notes
  guard-props.py         ← property checks: guard fast paths, inert heredocs, count_mark (docs/guards.md)
  shadow-report.py       ← what each shadowed guard or rule would have decided, and what happened instead
  session-census.py      ← claude processes, their memory, and idle background jobs (doctor.sh --census;
                           --sizes adds disk-space.py's report)
  pickup-report.sh       ← after an install, how running sessions pick up each change; install.sh runs it with
                           --prune, which removes what install wrote that the clone deleted
  verify-changed.sh      ← the checklist rows and suites a branch's changes call for (doctor.sh --changed)
  verify-stamp.sh        ← a PR's commits with no Verified: trailer, for CI's job summary
  readme-figures.py      ← README.md's summary table, evidence tables and docs/figures/ charts, from
                           docs/data/readme-numbers.json and CHANGELOG.md up to the release it cites
config/                  ← settings.json, merge-settings.jq, retired-rules.json, upstream-contract.json,
                           skills.pin, verify-checklist.tsv, verify.conf
hooks/                   ← one file per hook, plus lib.sh, which sources lib/: command, paths,
                           scratch, io, inline, net, host and shadow; bash-guards.sh runs the Bash guards
rules/                   ← installed to ~/.claude/rules, loaded in every session
  prose-and-comments.md  collaboration.md  working-agreement.md  environment.md
  python-tests.md        ← path-scoped: loads only when Claude opens Python or a file under tests/
tests/                   ← <name>.test.sh for most hooks, tools and .github scripts; host-binary covers
                           tcc-check and the host check; install-*, fail-closed, guard-latency,
                           heredoc-openers, prompt-canary, repo-layout, shadow, token-shapes and
                           workflow-gates cut across files; guard-execs holds git-guard and
                           interpreter-guard to a process budget per corpus shape; readme-numbers
                           holds README.md's numbers to the files they cite; lib.sh is their
                           shared pass/fail; lib/transcripts.py writes synthetic transcripts at test
                           time (no real one is committed), and prompt-canary checks that no report
                           on them prints prompt text; bench-corpus.jsonl feeds hook-bench; doctor
                           tests doctor.sh's own report; smoke.list is the set install.sh and
                           harness-update.sh verify with (doctor.sh --smoke)
docs/
  install.md  releases.md  upstream-contract.md  guards.md  hooks.md
  permissions.md  auto-mode.md  customization.md  known-limitations.md
  verify.md              ← checking a change before a commit or a PR (doctor.sh --changed, /verify)
  design.md              ← why the harness is built the way it is
  layout.md              ← this map
  memory.md              ← what Claude Code's memory does now, and each harness tool's verdict
  session-routing.md     ← routing a PR to its session; holds only in single-author repos
  permission-friction.md ← which guard asks and denies cost the most, and why
  shadow-mode.md         ← the guards and rules on trial (#237): what they log, how step 9 reads the report
  long-running-sessions.md ← keeping sessions alive for days: transcripts, handoffs, crons, process cost, disk
  permission-friction-cases.jsonl  ← cases bin/permission-friction.py --cases replays
  history/               ← superseded memory research the memory skills still cite
  data/readme-numbers.json ← every number README.md's tables and charts show, with n, source and command
  figures/               ← README.md's diagram and charts, light and dark, written by tools/readme-figures.py
```

Everything here is portable because the repo is public; machine-local rules and
allow rules live in `~/.claude/rules/local-*.md` and `~/.claude/local-settings/`
([customization.md](customization.md)).
