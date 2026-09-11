---
name: memory-archive
description: Relieve pressure on a memory index by proposing which memories to archive or merge, when MEMORY.md has grown past its load limits. Use when memory-lint or memory-verify reports OVERSIZE, when the index is near ~200 lines or ~25,000 characters, when asked to "clean up the memory index", "archive old memories", or "merge duplicate memories" — and never as routine maintenance, because the index only needs relieving when it is actually under pressure.
---

# Relieving a memory index that is over its load limit

`MEMORY.md` loads into every session and holds one line per memory. Past its
limits the tail is dropped at session start, silently. So the index has a
budget, memories do not, and the corpus grows faster than any cleanup: one
store went from 156 memories to 330 in fifteen days.

**Read this before proposing anything.** Two things are already settled, and
re-deriving them wastes a session:

1. **The size problem is not solvable and you should not try.** Bounded
   context, unbounded corpus. Archiving and merging are constant-factor moves
   against linear growth — they buy months, not a solution. `docs/memory-hygiene-problems.md`
   records that compaction cannot reclaim index lines at all.
2. **The harm was never the limit; it was the ORDERING.** Truncation is
   tail-first, so an append-ordered index drops the *newest* entries — measured
   once as 19 entries past the cut, 5 of them `feedback_` memories, which shape
   behaviour and are worthless unless loaded. `bin/memory-index.sh` fixes that by
   tiering the index, and orders `reference` and `project` newest-first inside
   their tiers. **Run it before archiving anything**: if ordering alone
   puts every `feedback_` above the cut, the pressure may not need relieving at all.
   If it is genuinely over budget, `--archive-overflow` moves the cheapest end
   into `MEMORY_ARCHIVE.md` mechanically and leaves a pointer. Use it for the
   bulk, and spend your judgement on what deserves promoting UP into the ACTIVE
   block — the decision a tool cannot make. It refuses to peel anything modified
   in the last 2 days (`--min-age-days`), because the cheapest TIER is not the
   cheapest ENTRY when that tier holds one memory written this morning.

## Before you begin

Read `docs/memory-hygiene-problems.md` in the harness repo, in particular the section
headed **"Heuristics built and WITHDRAWN — do not re-propose without addressing
why."** The most attractive heuristic here — *retire settled memories with no
lesson-shaped wording* — was built, tried, and withdrawn: it flagged a memory
recording a verified pipeline mismatch (a real bug) and one recording that a
table is absent from the lakehouse (a real blocker). If you find yourself
proposing it, you have not read the file.

## The safety property that makes this delegable

**Never delete. Move the index line and leave a pointer.**

Archiving must mean: the memory file stays on disk, its index line moves to
`MEMORY_ARCHIVE.md`, and `MEMORY.md` keeps one line saying the archive exists and
when to read it. Like this, which collapses forty entries into one:

```
- [ARCHIVE: 40 settled/older project memories](MEMORY_ARCHIVE.md) — index lines
  only; every memory file is still on disk and recallable. Read this when older
  work is referenced.
```

This inverts the risk. A wrong archive costs one retrieval, not lost knowledge —
which is why the judgment does not have to be reliable, and why this work can go
to a fast model. Deleting on a heuristic destroys knowledge silently, which is
strictly worse than staleness. `memory-verify.sh` is read-only by contract for
the same reason.

## Division of labour

- **This skill proposes.** It never writes to a memory store.
- **`bin/memory-index.sh` performs**, and refuses to write when it would not be a
  pure permutation, or when the index holds a line that is neither an entry nor a
  tier marker.

That split is deliberate and mirrors `memory-verify` (reports) versus
`memory-fix` (repairs). Keep it.

## Procedure

**1. Establish there is pressure, and print the number.**

```bash
grep -c '^- \[' MEMORY.md      # entries; the ~200-line limit
wc -c < MEMORY.md              # characters; the ~25,000 limit
```

Shortening index hooks relieves only the character limit. The line limit needs
fewer entries. If neither is near, stop — say so and change nothing.

**2. Fix ordering first, then re-measure.**

```bash
bash bin/memory-index.sh --store <slug>            # dry run
bash bin/memory-index.sh --store <slug> --write    # then, if out of order
```

Then check the harm directly rather than the total:

```bash
grep -n '^- \[' MEMORY.md | awk -F: '$1>200' | grep -c 'feedback_'
```

Zero means the tail holds only the least costly entries to lose. That may be
enough on its own.

**3. Relieve the CHARACTER limit first — it needs no archiving at all.**

The two limits are independent and the character one is almost always cheaper to
clear. Index hooks drift long; trimming them deletes nothing, because the full
detail stays in the memory file. Find the worst offenders:

```bash
awk '/^- \[/ { n=length($0); if (n>110) print n"\t"$0 }' MEMORY.md | sort -rn | head -20
```

Measured on a real store: 79 lines were over the ~110-char budget by 4,108
characters in total, and trimming just the 13 worst — each over 210 characters —
took a 26,346-char index to roughly 24,360, clearing the limit outright. No
memory was archived and nothing was lost.

Do this before proposing any archive. If it clears the pressure, stop here.

**4. Propose archive candidates — never `feedback_`.**

Candidates are `project_` memories whose work is finished: the PR merged, the
ticket closed, the migration done.

Work from the index hooks, not from a tool:

```bash
grep '^- \[' MEMORY.md | grep '(project_'
```

Each line already carries a one-line summary, which is enough to judge whether
the work is finished. Open only the handful you are genuinely unsure about, and
say which ones you opened.

**Do not start with `memory-verify.sh --curate`.** It performs external lookups
across the whole store, and on a real run it exceeded 120s and was killed, which
cost the attempt entirely. Use it deliberately on a shortlist, never as the
opening move.

**A hook is not evidence; the body is, and the body may also be stale.** On a
real run, one memory's hook said a fix was FIXED while its body recorded the PR
as open with items owed — and the PR had in fact merged that same afternoon, so
both were wrong in opposite directions. Where a claim's truth lives on GitHub or
Jira, either check it or state plainly that you did not.

Rules:
- **`feedback_` is never archivable.** It shapes behaviour and only works when
  loaded. Archiving one is the exact harm the tier ordering exists to prevent.
- **`reference_` is rarely archivable.** A durable fact does not become false
  because its project ended.
- **Finished ≠ worthless.** A memory recording *why* something failed stays
  useful long after the work is settled. Archive the lifecycle, keep the lesson —
  and if the lesson is buried inside a `project_` memory, propose extracting it
  as a `feedback_` memory before archiving the rest.

**5. Propose merges rather than deletions.**

Two memories covering one subject become one memory, and one index line. Merging
preserves both bodies; deletion does not. When proposing a merge, say what would
be lost if you are wrong — if the answer is "nothing, both texts are kept", the
proposal is safe.

**6. Hand back a proposal, not a change.**

For each candidate give: the memory name, its type, why it qualifies, and what a
wrong call would cost. Then state the total index lines reclaimed. A human
approves; `memory-index.sh` writes.

## "Do less" is a valid answer, and usually the right one

The expected outcome is a small proposal, not a large one. On the run this skill
was written against, the honest conclusion was: clear the character limit by
trimming hooks, archive two memories, merge none — and deliberately stay ~8
entries over the line limit, because forcing compliance would have meant
archiving live work.

That is the correct trade. Tier ordering plus *managed* truncation of the project
tail is the mechanism; the tail is the designed sacrifice zone. As long as no
`feedback_` and no `reference_` entry sits past the cut, an index over its line
limit is working as intended, not failing. Report the overage, say why you are
leaving it, and do not archive live work to make a number look right.

## Checking your own proposal

Before handing it over:

- Did you propose archiving any `feedback_` memory? Withdraw it.
- Did you propose deleting anything? Convert it to a merge or an archive.
- Did you re-propose a withdrawn heuristic? Read `docs/memory-hygiene-problems.md`.
- Did you state a denominator — lines now, lines after, limit? A proposal
  without one cannot be judged, and "several" is not a number.
- Would every archived memory still be reachable? If not, it is a deletion
  wearing a different word.
