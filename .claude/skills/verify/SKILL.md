---
name: verify
description: Use before committing or opening a PR in this repo, in place of the full doctor.sh run.
---

# Verify a change before committing

1. `bash doctor.sh --changed` prints the rows of config/verify-checklist.tsv the branch
   matches ("K of N rows matched") and the suites that cover its files. `--changed HEAD`
   reads only what is not committed yet.
2. `bash doctor.sh --changed --stamp` runs those suites and prints a `Verified:` line
   when all pass. A red suite gets a cause or a report, not reruns until green.
3. Do each `do:` row by hand, or say why not.
4. Put the line in the commit's trailer block, beside Co-Authored-By, adding what you
   ran by hand. Nothing ran: `Verified: none (<why>)`.
