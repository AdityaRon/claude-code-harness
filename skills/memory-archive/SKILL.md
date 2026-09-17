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
   against linear growth — they buy months, not a solution.
   `docs/memory-hygiene-problems.md` records that merging DUPLICATES reclaims
   nothing, because real corpora are not redundant. Do not read that as "no
   consolidation works": memories that say different things can still be
   instances of one principle, and grouping those freed 63 lines on a live store
   with nothing deleted. That is step 5b, and it is the only lever that reaches
   `feedback_`.
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
- **`feedback_` is never archivable on its own.** It shapes behaviour and only
  works when loaded. Archiving one so that nothing in the index points at it is
  the exact harm the tier ordering exists to prevent. The single exception is
  step 5b: its line may move under a hub whose own line IS loaded, because the
  lesson stays reachable every session. If you cannot name the loaded line that
  reaches it, it is an archive, not a hub.
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

**5b. Group instances of one principle under a hub — the only lever that reaches
`feedback_`.**

Do this when `feedback_` dominates the index. Measured on a live store: 138 of
185 entries (75%) were `feedback_` while being 30% of the files, because it is
the one type `--archive-overflow` never peels, so every incident's named lesson
kept its line forever.

`--curate` will not find these. It groups on shared verbatim claims and there are
none — the memories genuinely say different things. What they share is a
principle: seven separate files each recorded a different way a tool's output
describes the LOOKUP rather than the world (an empty `gh run list` for a workflow
that existed, a port-forward collision answering from another region, `${v:-0}`
rendering no-series as zero). Finding them takes reading the bodies, which is why
it is judgement and not a flag.

The shape:

- one hub memory per principle, `feedback_hub_<slug>`, stating the rule and
  carrying one bullet per instance — a wikilink plus that incident's trigger and
  tell, so the bullet is the retrieval hook the index line used to be;
- every instance file **stays on disk, unedited**;
- each instance's index line moves to `MEMORY_ARCHIVE.md` under a
  `### feedback_hub_<slug>` heading;
- the hub's own line goes in the index, so the lessons are still reachable from
  something loaded every session.

Measured result: 192 index lines → 129, zero deletions, no `reference_` or
`project_` entry archived to make room.

**What it costs, say it out loud:** 76 specific hooks became 12 general ones. A
situation the index used to name directly is now one hop away, inside its hub.
Propose this only where the instances really do share a principle — a hub of
things that merely rhyme is worse than the lines it saves.

**It regrows unless you also write the rule down.** Add one memory saying a new
general lesson joins its hub as a bullet with its index line going straight to
the archive; that only a lesson fitting no hub takes a new index line; that three
unhubbed lessons sharing a principle earn a new hub; and that user preferences
and tool facts are not hub material and keep their own lines. `hooks/memory-lint.sh`
names the existing hubs when a new `feedback_` memory is written into a store
that has them, so the next session meets the rule at the moment it matters.

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

- Did you propose archiving any `feedback_` memory? Withdraw it, unless a hub
  line reaches it (step 5b) and you can name that line.
- Is `feedback_` most of the index? Then you looked for duplicates and found
  none — look for shared PRINCIPLES instead, which is a different question and
  needs the bodies, not the hooks.
- Did you propose deleting anything? Convert it to a merge or an archive.
- Did you re-propose a withdrawn heuristic? Read `docs/memory-hygiene-problems.md`.
- Did you state a denominator — lines now, lines after, limit? A proposal
  without one cannot be judged, and "several" is not a number.
- Would every archived memory still be reachable? If not, it is a deletion
  wearing a different word.
