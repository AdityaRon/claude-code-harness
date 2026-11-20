# Verifying a change

How to check a change to this repo before a commit or a PR. Moved from the README.

Opt in: nothing here runs from a hook.

- `bash doctor.sh --changed [BASE]` diffs the working tree, uncommitted and untracked
  files included, against its merge base with BASE (default `origin/main`). It prints
  the rows of `config/verify-checklist.tsv` the change matches, always as "K of N rows
  matched", and the suites that cover the changed files. A README or docs file maps
  to the suites that read it, not those that only quote its name. `--run` runs those suites;
  `--stamp` also prints a `Verified:` line naming each with its tally, and none when
  one fails. `--changed HEAD` reads only what is not committed yet.
- Each row cites the incident it comes from, and its check is suites (`run:`) or a
  step to do by hand (`do:`). The table is read from the merge base with `origin/main`,
  whatever BASE is, plus rows new in the branch, so a branch cannot drop or narrow its own rows.
- In a session in this clone, `/verify` (`.claude/skills/verify`) walks the same
  steps, and Claude uses it before a commit or a PR in place of the full `doctor.sh`.
  Its one-line description loads only in sessions in this clone; its body when it is used.
- A commit's `Verified:` trailer names what ran, or says `Verified: none (<why>)`.
  CI's "verification stamps" job lists a PR's commits without one in its summary
  (`tools/verify-stamp.sh`) and passes. `config/verify.conf` on the base branch sets
  the mode: `observe` now; `enforce` would fail the job.
