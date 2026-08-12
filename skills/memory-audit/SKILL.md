---
name: memory-audit
description: Check stored memories against external truth (GitHub PRs, Jira issues) and propose corrections for the ones reality has overtaken. Use when asked to audit/clean up memory, when a memory's claim about a PR or ticket looks out of date, when memory-verify.sh reports STALE or TRIAGE, or before trusting an old project memory that asserts something is still in flight.
---

# Auditing memories against external truth

Claude Code's built-in memory hygiene reasons over memory *content* and session
logs. It never leaves the machine. So a memory saying "PR #4821 is a held
draft" survives consolidation intact — nothing inside the file contradicts it.
The contradiction lives on GitHub. Closing that gap needs an external lookup,
and working out *which* lookup needs judgment. That is this skill's job.

## The hard part, and why a script cannot do it alone

`memory-verify.sh` (installed at `~/.claude/memory-verify.sh`) resolves any
memory carrying a `verify:` block. Most memories do not carry one, and their
references are genuinely ambiguous:

- References are usually bare — `#4821`, not `acme/api#4821`. The same number
  exists in every repo.
- A single memory often cites many references — twenty or more is common for a
  long-running piece of work. Only one or two are *the claim under test*; the
  rest are supporting detail.
- Memories frequently name several repositories, or none at all, so the file
  itself may not tell you which repo a given number belongs to.

So your value here is picking the operative claim and resolving the reference.
Once you have, you write a `verify:` block back into the file — and that memory
becomes mechanically checkable forever after. **The audit is not just a cleanup;
it is how the corpus becomes self-checking.** Prefer leaving a `verify:` block
behind on every file you touch, even one you conclude is still accurate.

## Procedure

**1. Collect findings.**

```bash
bash ~/.claude/memory-verify.sh --json                  # every store
bash ~/.claude/memory-verify.sh --json --store <slug>   # one store
```

If that path does not exist, the harness is not installed on this machine; fall
back to `memory-verify.sh` in a checkout of the harness repo.

Each line is `{status, store, file, detail}`. Handle by status:

- `STALE` — already proven wrong. Go straight to step 3.
- `TRIAGE` — no `verify:` block; needs steps 2 and 3.
- `SKIP` — could not be resolved mechanically. Issue-tracker claims land here
  because trackers are reachable only over MCP, not from a shell script;
  resolve those with whichever tracker MCP is connected.
- `VERIFIED` — nothing to do.

**2. Work out what the memory actually claims.**

Read the whole file. Then:

- **Find the operative claim** — the sentence asserting current state ("held",
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

A memory is only safe to touch *after* an external check has confirmed what it
claims is false. Deleting on a heuristic destroys knowledge silently, which is
worse than staleness. Propose; let the user decide.

For each affected memory, show:

- what the memory claims, quoted;
- what the lookup returned, with the date (`merged 2026-06-15`);
- the proposed edit.

Prefer the smallest correct edit:

- **Claim overtaken** — rewrite the claim to what is now true and keep the
  history. `PENDING: merge, deploy, live-verify` becomes
  `Merged 2026-06-15 and verified in prod.`
- **Self-contradiction** — the file asserts both open and closed state because
  an update was appended without revising the original. Delete the superseded
  sentence, keep the current one.
- **Whole memory now worthless** — say so and recommend deletion, but let the
  user confirm. If the memory records a *lesson* rather than a status, the
  lesson usually outlives the ticket: keep it, fix the status line.

**4. Leave a `verify:` block behind.**

Add near the top of the body, after the frontmatter:

```yaml
verify:
  - gh acme/api#4821 merged
  - jira PROJ-123 Done
```

Format is `<kind> <ref> <expected-state>`, one claim per line:

- `gh` — ref must be `owner/repo#number`; expected is `merged`, `open`, or
  `closed`. Works for issues too.
- `jira` — ref is the issue key; expected is the status name. Resolved by this
  skill via MCP, not by the script.

Record what you expect to *stay* true. `merged` is stable; `open` will go stale
by design — which is the point, since that is the claim worth re-checking.

**5. Keep the index honest.** If you rename or delete a memory, update the
matching `- [Title](file.md) — hook` line in that store's `MEMORY.md`. If you
only edited the body, the index line usually still stands — but re-read it, as
it may repeat the stale claim.

## Rules

- **Never delete a memory without an external check confirming it is false**,
  and never without the user agreeing.
- **Never edit a memory you have not read in full.** The operative claim is
  often not the one the scanner flagged.
- **Absolute dates only.** Rewrite "last week" to the actual date.
- **Do not touch `CLAUDE.md`.** If a memory contradicts it, annotate the memory
  with `contradicts CLAUDE.md — verify which is current` and raise it.
- **Batch your questions.** Audit the set, then come back with one consolidated
  set of proposals rather than interrupting per file.

## Scope

Default to the store for the current project. Audit every store only when
asked — memory is siloed per launch directory, so the same repo can have two
stores, and a full sweep is a much larger job than it looks.
