---
name: memory-archive
description: Relieve a MEMORY.md index that Claude Code reports as over or approaching its read limit (200 lines, 25,000 bytes), by proposing index lines to archive or lessons to group, never deletions. Use only on that error, or when asked to clean up, archive or merge the memory index. Never as routine maintenance.
---

# Relieving a memory index that is over its read limit

`MEMORY.md` loads into every session and holds one line per memory. Past 200
lines or 25,000 bytes the tail is dropped at session start, silently.

**What already happens without you.** Claude Code checks the index on every
write: over the limit it returns an error to the writer (`Error: this write
left the` index `over its` cap `read limit`), near it a reminder to compact
(`approaching the` cap `read limit. Compact it`). Where auto-dream is
enabled it also prunes and reindexes in the background. And `memory-index.sh`
keeps the index in tier order (ACTIVE, `feedback`, `reference`, `project`,
newest first inside the last two) so that whatever truncation takes is the
cheapest line. Your job starts only when those have run and the index is still
over: deciding *which* lines leave, which a tool cannot judge.

Two things are settled; do not re-derive them:

1. **The size problem is not solvable.** Bounded index, unbounded corpus.
   Archiving and grouping are constant-factor moves against linear growth;
   they buy months. Merging DUPLICATES reclaims nothing (measured: 6 of 1,328
   claims appeared twice). Grouping instances of one *principle* does (76
   `feedback_` lines became 12), and it is the only lever that reaches
   `feedback_`.
2. **The harm was never the limit; it was the ordering.** An append-ordered
   index drops its newest entries, and `feedback_` entries only work when
   loaded. Run `memory-index.sh` first; if ordering alone puts every
   `feedback_` above the cut, the index may not need relieving at all.

## The safety property that makes this delegable

**Never delete. Move the index line and leave a pointer.** The memory file
stays on disk, its line moves to `MEMORY_ARCHIVE.md`, and `MEMORY.md` keeps one
line saying the archive exists and when to read it. A wrong archive costs one
retrieval, not lost knowledge, which is why the judgment does not have to be
reliable.

This skill proposes; `bin/memory-index.sh` performs, and it refuses to write
anything that is not a pure permutation of the existing lines. Keep that split.

## Procedure

**1. Establish there is pressure, and print the numbers.**

```bash
grep -c '^- \[' MEMORY.md      # entries; the 200-line limit
wc -c < MEMORY.md              # bytes; the 25,000 limit
```

If neither is near, stop, say so, and change nothing.

**2. Fix ordering first, then re-measure the harm, not the total.**

```bash
bash ~/.claude/memory-index.sh --store <slug>            # dry run
bash ~/.claude/memory-index.sh --store <slug> --write    # if out of order
grep -n '^- \[' MEMORY.md | awk -F: '$1>200' | grep -c 'feedback_'
```

Zero means the tail holds only the least costly entries. That may be enough.

**3. Relieve the byte limit first; it needs no archiving.** Index hooks drift
long and the detail stays in the memory file, so trimming them loses nothing:

```bash
awk '/^- \[/ { n=length($0); if (n>110) print n"\t"$0 }' MEMORY.md | sort -rn | head -20
```

Trimming the 13 worst hooks on a real store cleared the limit outright.

**4. Archive the cheapest end, mechanically.** `--archive-overflow` moves the
oldest `project` lines, then the oldest `reference`, into `MEMORY_ARCHIVE.md`
with a pointer left behind, draining to a margin below the cap. It never peels
ACTIVE, `feedback`, untyped entries, or anything modified in the last 2 days
(`--min-age-days`, because the cheapest tier is not the cheapest entry when
that tier holds one memory written this morning):

```bash
bash ~/.claude/memory-index.sh --store <slug> --archive-overflow
```

Spend your judgment on what deserves promoting UP into the ACTIVE block, and on
`project_` lines whose work is finished. A hook is not evidence; the body is,
and where a claim's truth lives on GitHub or Jira either check it or say you
did not.

**5. Group instances of one principle under a hub; this is the only lever that
reaches `feedback_`.** When several lessons each record a different way of the
same failure (a tool's output describing the lookup rather than the world, say),
propose one `feedback_hub_<slug>` memory stating the rule with one bullet per
instance (wikilink, trigger, tell). Instance files stay on disk unedited; their
index lines move to `MEMORY_ARCHIVE.md` under a `### feedback_hub_<slug>`
heading; the hub's own line goes in the index. Say what it costs: a situation
the index used to name directly is now one hop away. Hub only what truly shares
a principle. `hooks/memory-lint.sh` names the existing hubs when a new
`feedback_` memory is written into a store that has them.

**6. Hand back a proposal, not a change.** For each candidate: name, type, why
it qualifies, what a wrong call would cost. Then lines now, lines after, limit.
A human approves; `memory-index.sh` writes.

## Rules

- **`feedback_` is never archived on its own.** Its line may move only under a
  hub whose own line IS loaded. If you cannot name that line, it is a deletion
  wearing a different word.
- **`reference_` is rarely archivable.** A fact does not become false because
  its project ended.
- **Finished is not worthless.** Archive the lifecycle, keep the lesson; if the
  lesson is buried in a `project_` memory, propose extracting it first.
- **Do not re-propose "retire settled memories with no lesson-shaped wording".**
  It was built, tried and withdrawn: it flagged a real pipeline mismatch and a
  real blocker. No wordlist separates a status record from a durable fact. See
  `docs/history/memory-hygiene-problems.md`.
- **"Do less" is usually the right answer.** On the run this was written
  against: trim hooks, archive two, merge none, and stay ~8 entries over the
  line limit rather than archive live work. An index over its limit with no
  `feedback_` or `reference_` past the cut is working as intended; report the
  overage and why you are leaving it.
