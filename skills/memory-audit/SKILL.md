---
name: memory-audit
description: Check stored memories against external truth (GitHub PRs, Jira issues) and propose corrections where the world moved on. Use when memory-verify.sh reports STALE or TRIAGE, when a memory's claim about a PR or ticket looks out of date, or before trusting an old memory that says something is still in flight. Not for tidying or index size.
---

# Auditing memories against external truth

Claude Code's own memory hygiene (the limit checks on every write, and
auto-dream where it runs) reasons over memory *content* and session logs, and
never leaves the machine. So a memory saying "PR #4821 is a held draft"
survives consolidation intact: the contradiction lives on GitHub. Working out
*which* external lookup settles it needs judgment, and that is this skill's job.

Leave everything else to the CLI and `memory-archive`: merging duplicates,
rewriting relative dates, shortening and reordering the index. The measured
history of why is in `docs/history/memory-hygiene-problems.md`.

## The hard part, and why a script cannot do it alone

`memory-verify.sh` (installed at `~/.claude/memory-verify.sh`) resolves any
memory carrying a `verify:` block. Most memories do not carry one, and their
references are genuinely ambiguous:

- References are usually bare: `#4821`, not `acme/api#4821`. The same number
  exists in every repo.
- A single memory often cites many references; only one or two are *the claim
  under test*, the rest are supporting detail.
- Memories name several repositories, or none, so the file may not say which
  repo a number belongs to.

So your value is picking the operative claim and resolving the reference. Then
write a `verify:` block back into the file, and that memory is mechanically
checkable from then on. Leave a block on every file you touch, even one you
conclude is still accurate.

## Procedure

**1. Collect findings.**

```bash
bash ~/.claude/memory-verify.sh --json                  # every store
bash ~/.claude/memory-verify.sh --json --store <slug>   # one store
```

If that path does not exist, use `bin/memory-verify.sh` in a harness checkout.

Each line is `{status, store, file, detail}`, and each status means one thing:

- `STALE`: already proven wrong. Go straight to step 3.
- `TRIAGE`: asserts open state with no `verify:` block, so nothing can check
  it. Needs steps 2 and 3. **Not age-gated**: an unverifiable claim about
  something still open is a defect the moment it is written.
- `NEEDS_MCP`: a well-formed claim only this skill can resolve, over MCP.
- `SKIP`: malformed or unrecognised claim. The memory itself needs fixing.
- `VERIFIED`: nothing to do.
- `HOOK`: advisory. An index hook trails off mid-claim while the memory's own
  `description:` still carries the payload. Rewrite the one line in `MEMORY.md`
  from the description; nothing else changes.
- `OVERSIZE`: the index is past a load limit. Claude Code already reports this
  on the write that caused it; hand it to `memory-archive`, not this skill.
- `SETTLED`, `CANDIDATE`: advisory, `--curate` only, and slow (it looks up
  every claim in the store; a full run exceeded 120 s once). Use it on a
  shortlist, never as the opening move.

**2. Work out what the memory actually claims.**

Read the whole file. Then:

- **Find the operative claim**: the sentence asserting current state ("held",
  "PENDING", "awaiting review", "not yet deployed"). Supporting references that
  merely explain history are not claims to verify.
- **Resolve the reference to a repo.** Use repo names in the file's own text
  first. If the file names several, match each reference to the repo discussed
  in its own paragraph.
- **Confirm the match before trusting it.** Fetch the title and compare it to
  what the memory describes:
  ```bash
  gh pr view <num> --repo <owner/repo> --json state,title,mergedAt
  ```
  If the title has nothing to do with the memory's subject, you resolved to the
  wrong repo. A confidently wrong `verify:` block is worse than none, because
  every later run trusts it.
- **If you cannot resolve it, stop and ask.** Do not guess a repo from the
  number's magnitude alone.

**3. Report, and propose an edit. Never delete on your own initiative.**

Touch a memory only *after* an external check confirms its claim is false.
Deleting on a heuristic destroys knowledge silently, worse than staleness.

For each affected memory, show what it claims (quoted), what the lookup
returned with the date (`merged 2026-06-15`), and the proposed edit. Prefer the
smallest correct one:

- **Claim overtaken**: rewrite the claim to what is now true and keep the
  history. `PENDING: merge, deploy, live-verify` becomes
  `Merged 2026-06-15 and verified in prod.`
- **Self-contradiction**: an appended update left the file asserting both open
  and closed state. Delete the superseded sentence, keep the current one.
- **Whole memory now worthless**: say so and recommend deletion, but let the
  user confirm. If the memory records a *lesson* rather than a status, the
  lesson usually outlives the ticket: keep it, fix the status line.

**4. Leave a `verify:` block behind**, near the top of the body, after the
frontmatter:

```yaml
verify:
  - gh acme/api#4821 merged
  - jira PROJ-123 Done
```

Format is `<kind> <ref> <expected-state>`, one claim per line:

- `gh`: ref must be `owner/repo#number`; expected is `merged`, `open`, or
  `closed`. Works for issues too.
- `jira`: ref is the issue key; expected is the status name. Resolved by this
  skill via MCP, not by the script.

Record what you expect to *stay* true. `merged` is stable; `open` will go stale
by design, which is the point: that is the claim worth re-checking.

**5. Keep the index honest.** If you rename or delete a memory, update the
matching `- [Title](file.md) — hook` line in that store's `MEMORY.md`.

`memory-verify.sh` reports index lines as `MEMORY.md:<line>`, aged by the memory
they link to. Treat those like any other finding: resolve the claim, then
rewrite the one-liner. The index loads into every session, so a stale hook
there is read far more often than the memory behind it.

The index gets no `verify:` block of its own; put that on the memory it links
to, and keep the hook consistent with it.

## Rules

- **Never delete a memory without an external check confirming it is false**,
  and never without the user agreeing.
- **Never edit a memory you have not read in full.** The operative claim is
  often not the one the scanner flagged.
- **Absolute dates only.** Rewrite "last week" to the actual date.
- **Do not touch `CLAUDE.md`.** If a memory contradicts it, annotate the memory
  with `contradicts CLAUDE.md, verify which is current` and raise it.
- **Batch your questions.** Audit the set, then bring one set of proposals, not
  one per file.

## Scope

Default to the current project's store. Audit every store only when asked:
memory is siloed per launch directory, so one repo can have two stores.
