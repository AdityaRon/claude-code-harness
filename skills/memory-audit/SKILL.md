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
bash ~/.claude/memory-verify.sh --store <slug> --curate  # + index size and merge candidates
```

If that path does not exist, the harness is not installed on this machine; fall
back to `memory-verify.sh` in a checkout of the harness repo.

Each line is `{status, store, file, detail}`. Handle by status:

Each finding means exactly one thing — a queue with mixed meanings gets ignored:

- `STALE` — already proven wrong. Go straight to step 3.
- `TRIAGE` — asserts open state with no `verify:` block, so nothing can check
  it. Needs steps 2 and 3. **Not age-gated**: a claim about something still
  open, with no way to verify it, is a defect the moment it is written, not
  after two weeks. This corpus held a memory asserting three PRs were open when
  all three had merged the same day.
- `NEEDS_MCP` — a well-formed claim only this skill can resolve, because
  trackers are reachable over MCP and not from a shell script. Resolve with
  whichever tracker MCP is connected.
- `SKIP` — malformed or unrecognised claim. The memory itself needs fixing.
- `VERIFIED` — nothing to do.
- `OVERSIZE` — the store's index is past a load limit; see step 6.
- `SETTLED` — advisory, `--curate` only: a **project** memory whose every claim
  is terminal and whose body asserts nothing in flight. Its work is finished, so
  its index line can move to an archive section. This is a claim about the INDEX
  LINE, never about the memory: the file, its links and its lessons all stay
  exactly where they are, and moving the line back is a one-line edit. That
  reversibility is why it can be suggested at all where the withdrawn retirement
  heuristic could not — that one guessed from prose, this reads resolved
  evidence. A `jira`-only memory is judged on its RECORDED status, since a shell
  cannot reach Jira; the finding says so.
- `CANDIDATE` — advisory, `--curate` only: two memories making the same claims.

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
matching `- [Title](file.md) — hook` line in that store's `MEMORY.md`.

`memory-verify.sh` reports index lines as `MEMORY.md:<line>`, aged by the memory
they link to. Treat those exactly like any other finding — resolve the claim,
then rewrite the one-liner. They matter more than their size suggests: the index
is the part loaded into context every session, so a stale hook there is read far
more often than the memory behind it, and the two can disagree. A real store had
a hook saying a PR was a draft awaiting validation while the memory it pointed
at already recorded that PR as merged and validated.

The index gets no `verify:` block of its own — put that on the memory it links
to, and keep the hook consistent with it.


**6. Check the index against its load limits.**

The index has two, and the line one usually binds first:

| | limit |
|---|---|
| lines | **200** |
| characters | **~25,000** |

Past either, the tail is dropped silently at session start — the oldest hooks
simply stop reaching the model, with no error where it is used. `memory-verify.sh`
reports this as `OVERSIZE` on every run, naming which limit and by how much.

**One line per memory means a store with more than ~200 memories cannot comply
by shortening hooks.** Trimming entry text buys headroom on the *character*
limit only.

**Fix the ORDER before trying to fix the size.** Truncation is tail-first, so an
index in append order drops its NEWEST entries. Measured on a real 218-memory
store: 19 entries fell past the cut and five were `feedback_` memories — rules
about how to work, which do nothing unless they are loaded. Ordering the index
ACTIVE → `feedback` → `reference` → `project` costs nothing, changes no content,
and makes whatever falls off the cheapest thing available:

```bash
bash ~/.claude/memory-index.sh --store <slug> --write
```

Run it whenever entries have been appended. The memory writer adds index lines
at the end of the file regardless of type, so the ordering drifts on ordinary
use — twice in one session a project entry landed in the middle of the reference
section. The reorder is a pure permutation and aborts rather than write if the
set of entry lines changed at all.

**Ordering is newest-first inside `reference` and `project` both.** Reference
kept append order until 2026-08-31, which parked the freshest fact at the cut:
on a live 283-memory store the last two reference entries were both written
that same day, while facts from three months earlier sat safely at the top.

**If the index is over its budget, add `--archive-overflow`:**

```bash
bash ~/.claude/memory-index.sh --store <slug> --archive-overflow
```

It moves the cheapest end — oldest project first, then oldest reference — into
`MEMORY_ARCHIVE.md`, leaves a pointer line in `MEMORY.md`, and drains to a
margin below the cap rather than to the cap itself, so the index stays
compliant between runs. It never touches ACTIVE, `feedback`, or untyped
entries. **This is not the withdrawn "retire settled memories" heuristic** —
it judges nothing about worth, it just writes down what truncation was going
to take anyway. Measured: a store growing ~14 memories a day cannot hold any
fixed headroom, so the index is permanently at its cap and the only question
is whether the loss is recorded. See `docs/memory-hygiene-problems.md`.

It will not peel an entry whose memory was modified in the last 2 days
(`--min-age-days N`, 0 disables). Tier cheapness is an INDIRECT proxy for
cost-of-loss and it breaks down when a tier is nearly empty: measured on two
consecutive days, the drain took a `project` memory written that same morning —
the freshest, most actionable entry in the store — because project is the
cheapest tier and that memory was the only thing in it. If the floor blocks
every remaining candidate the drain stops short and says so on stderr, rather
than peeling live work to satisfy a number.


Only then look at shedding entries. `--curate` reports pairs of memories making
the same claims:

```bash
bash ~/.claude/memory-verify.sh --store <slug> --curate
```

Pairs are grouped on **shared verbatim claims**, not on a shared ticket key.
Ticket key was tried first and was wrong: of four groups it produced on a real
store, the one genuine pair shared four verbatim claims and the other three
shared none. Two memories citing one ticket usually means one records the fix
and the other a lesson learned beside it — different content, correctly separate
files. Merging a real pair is an ordinary edit: fold the bodies into one file,
keep both sets of lessons, delete the file that lost, and update its index line
per step 5. Confirm with the user first, as with any deletion.

Expect `--curate` to find nothing on a healthy store. Measured across 1,328
distinct claims in one corpus, six appeared in more than one memory and five of
those were a single pair. **Real memory corpora are not redundant, so merging
duplicates does not reclaim index lines.**

That is a statement about DUPLICATES, not about consolidation. Memories that say
different things can still be instances of one principle, and grouping those
under a hub does reclaim lines — measured at 76 `feedback_` entries collapsing to
12, with no file deleted. `--curate` cannot find them, because it groups on
shared verbatim claims and these share none. See the `memory-archive` skill,
step 5b.

Nor, usually, does retirement. On the same store, live ticket status for all 125
keys the project memories cite showed only **3 of 56** provably settled: 21
asserted open state and 32 cited a ticket that was unresolved or no longer
existed. **A corpus of live work cannot be shrunk — it can only be ordered so
that what truncation takes is the cheapest thing available.** Treat `SETTLED` as
a slow drip that pays off as work finishes, not as a way out of an oversize
index today.

**Why there is no "retire this memory" suggestion.** It was built and removed.
Staleness is not the test: an audit of a real 204-memory store found four
verifiably stale memories and *zero* deletable ones, because in every case the
lesson outlived the ticket. The fallback test — settled outcome plus no
lesson-shaped wording — then flagged a memory recording a verified pipeline
mismatch, and another recording that a table is absent from the lakehouse so a
conversion is blocked. Both are durable facts that happen to contain no
lesson-shaped words. No wordlist separates a pure status record from a durable
fact, and a wrong suggestion costs knowledge that cannot be recovered. Deciding
what to retire stays yours.

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
