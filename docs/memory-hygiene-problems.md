# Memory system — measured problems, 2026-08-25

Evidence base for the remediation work. Every number here was measured, not
estimated. Main store is `~/.claude/projects/<slug>/memory`
(218 memories); there are 8 stores totalling 289 memories.

## Problems

1. **The index exceeds its load limit and structurally cannot comply.**
   219 lines against a 200-line limit (second limit 25,000 BYTES; currently
   23.5KB, under). 218 memories, one line each. Past either limit the tail is
   dropped silently at session start. Shortening hooks only relieves the
   BYTE limit — the LINE limit needs fewer entries.
   (Both limits verified against the CLI 2026-08-27: upstream compares
   `lineCount > 200` and `byteCount > 25000`. The size one is bytes, not
   characters — em-dashes are three, so a compliant character count can still
   be over. See memory-hygiene-research.md and upstream-check 4d.)

2. **6% of wiki-links are broken** — 35 of 588 do not resolve to a file.

3. **Root cause of most of those: 64 of 218 memories have a hyphenated `name:`
   while the filename uses underscores.** `[[feedback-bash-allowlist-prefix-matching]]`
   never resolves to `feedback_bash_allowlist_prefix_matching.md`.

4. **`verify:` coverage is 6%** — 14 of 218. The other 204 cannot be checked
   mechanically at all.

5. **87 of 218 memories have no `metadata.modified` stamp**, so age falls back
   to file mtime, which moves whenever anything rewrites the file. "How long has
   this claim been wrong" becomes unanswerable.

6. **Index hooks drift from the memories they summarise.** Two confirmed, both
   with the SUMMARY lagging the BODY:
   - an index hook naming three open PRs while the linked memory said
     "all MERGED 2026-08-25" — and that hook sits in the ACTIVE-WORK block, the
     most-read line in the file.
   - a memory `description` saying a PR was "still open and unreviewed" while
     line 33 of its own body said "MERGED".

7. **Long-lived memories decay into false claims.** One 56KB memory (94 very
   long lines) is ~63% a per-repo shipping ledger; two entries still read
   "IN PROGRESS: PR open" while the top of the same file records both merged.

8. **Staleness detection has a timing gap.** Unverified open-state claims are
   triaged only after 14 days, but PR-state claims rot in hours — one memory
   asserted PRs open that had merged the same day it was written.

9. **Cross-store fragmentation.** A memory about repo X lives in whichever store
   the session was launched from, so a store-scoped audit misses it.

## Measured NOT to be a problem

**Content duplication is ~zero.** Of 1,328 distinct bolded claims across the
corpus, only 6 appeared in more than one memory, and 5 of those were a single
pair (since deduplicated, −1,126 bytes). The corpus is genuinely non-redundant,
so **compaction cannot reclaim index lines**.

## Heuristics built and WITHDRAWN — do not re-propose without addressing why

- **"Retire settled memories with no lesson-shaped wording."** Flagged a memory
  recording a verified pipeline MISMATCH (a real bug) and one recording that a
  table is absent from the lakehouse so a conversion is blocked. Both are
  durable FACTS containing no lesson words. No wordlist separates a pure status
  record from a durable fact.
- **"Merge memories that are about the same ticket."** Grouped a 21-hour
  production crash-loop with a PR-landing table because both cited one ticket.
  Verbatim-claim overlap was 4 for the one real pair and 0 for all three
  others — content overlap separates them, ticket key does not.

Standing principle: deleting on a heuristic destroys knowledge silently, which
is strictly worse than staleness. The tool reports; a human decides.

**`memory-index.sh --archive-overflow` is not a third such heuristic, and the
difference is worth stating so it is not mistaken for one.** Both withdrawn
heuristics tried to judge a memory's WORTH from its content - lesson-shaped
wording, a shared ticket key - and both were wrong because no content signal
separates a dead status record from a durable fact. The overflow archiver
judges nothing. It moves exactly the lines the session loader would have
dropped anyway, in exactly the order it would have dropped them, and writes
them down. The comparison is not "archive vs. keep", which would need
judgement; it is "recorded vs. silent", which does not. Nothing is deleted, the
memory file stays on disk, and the index keeps a pointer.

**One correction, measured after the fact.** "The lines the loader would have
dropped anyway" was true of the ORDER but not of the OUTCOME, because tier
cheapness is a proxy that fails when a tier is nearly empty. On two consecutive
days the drain peeled a `project` memory written that same morning — the only
entry in its tier, and the most actionable line in the store. The archiver now
carries an age floor (`--min-age-days`, default 2) and stops short with a message
rather than peeling recent work. Recency is a direct signal where tier is an
indirect one; this does not restore a worth heuristic, it just stops the proxy
being applied where it is known to break.

It is also opt-in: without the flag the tool still only reports, so the
standing principle holds by default. And it does not claim to solve the size
problem - see below, it cannot be solved. It makes running out of room
observable instead of invisible.

## Better rule, derived during the audit

For completed work, **keep the technique and the mechanism facts, drop the
ledger** — a section-level rule, not a file-level one. File-level tests keep
failing because a single memory mixes disposable status with durable fact.

## Fixes already applied

- 4 memories corrected against live GitHub/Jira (a merged ticket still shown
  open, a narrowed lookback, a pair of parity follow-ups, and a cleared
  blocker); 14 now carry `verify:` blocks; 23 claims verify mechanically.
- Index hook `3 PRs open` → `ALL MERGED 08-25`.
- A CI-optimization memory's description and an `IN PROGRESS` line corrected —
  both tickets were Done.
- A tagging-Lambda memory now records the requester's confirmation that the
  payload does carry the expected field and the fault is deployment-side; the
  unanswered long-term-ownership question is flagged as the only thing left.
- 5 verbatim-duplicated lessons stripped from a parity-follow-ups summary.

---

# Review findings and remediation, 2026-08-25

Fable reviewed the enumeration above. Its two sharpest points, both verified:

**Problem 6 is a normalization problem, not a detection one.** State lives in
three places — index hook, frontmatter `description`, body — so any volatile
claim drifts by construction. No mechanical check can fix that. Summaries must
become state-free retrieval cues, with volatile state in exactly one place next
to a `verify:` block. Then the drift class ceases to exist.

**Problem 1 was being measured against the wrong thing.** The limit was never
the harm; the ORDERING was. Truncation is tail-first and the index was in pure
append order, so it dropped the NEWEST entries. Measured live: 19 entries past
the cut, **5 of them `feedback_` memories** — the behaviour-shaping ones, which
are worthless unless loaded. Fixed first.

## Corrections to the numbers above

- **"35 broken wiki-links" was inflated.** 26 were mechanically repairable, 7
  were links to memories not yet written — which the memory format treats as a
  marker for something worth writing, not an error — and 1 was `[[:space:]]`, a
  POSIX character class quoted in a body and matching the wiki-link shape.
- **"87 missing `modified`" is now 88, and only 42 were safely fixable.** The
  other 46 have an mtime of today because tooling touched them, so mtime no
  longer carries information about when the CLAIM last changed.
- **13 memories across 4 stores have no `metadata:` block at all** — old-format
  files predating the convention. Not previously counted.
- **Cross-store fragmentation (#9) is latent, not active.** 5 worktree-slug
  project dirs exist but none has a `memory/` subdir, so nothing has been
  written into one yet.

## Rules learned while fixing

- **Never stamp a date you cannot source.** Backfilling `modified` with today
  fabricates recency and hides a memory from age-gated triage, which is worse
  than no stamp. When the true date is unrecoverable, leave it unstamped.
- **Snapshot mtimes before editing anything.** Otherwise pass 1 bumps 64 files
  and pass 3 records today for all of them — the age signal is destroyed
  corpus-wide in a single run. This nearly happened.
- **A finding queue with mixed meanings gets ignored.** `memory-fix` initially
  counted ambiguous links, missing `name:`, and missing `metadata:` in one
  counter, so 13 malformed memories were reported as "ambiguous links" and then
  masked entirely by a later guard. Same defect Fable flagged in
  `memory-verify`'s overloaded `SKIP`.
- **Repair the frontmatter, never rename the file.** 560 links already resolve
  against filenames; renaming to match `name:` would break the working majority
  to fix the broken few.

## Status

| phase | state |
|---|---|
| 0 · git-init the stores | DONE — 8 stores, 298 files baselined |
| 1 · tier-order the index | DONE — pure permutation, 0 feedback below the cut |
| 2 · `bin/memory-fix.sh` | DONE — 178 repairs on the main store, 45 tests |
| 3 · generate index from frontmatter | DONE, scoped — `bin/memory-index.sh` + placement lint |
| 4 · liveness triage at age zero | DONE — un-gated; caught a real drift the same day |
| 5 · demote settled projects to ARCHIVE.md | DONE as a `SETTLED` finding; no machinery — see below |
| 6 · write-time lint hook | DONE — `hooks/memory-lint.sh`, 25 tests, deployed |

Evidence that phases 3 and 6 are both needed: a memory written by the live
system DURING this session arrived with no `modified:` stamp and a 176-char
index line appended blindly to the end of the file — past the truncation cut,
in the section reserved for a different type.

## Correction: nothing clips an index line on the way in

The review said the injected copy clips lines at ~115 chars and that a previous
char-limit fix had hard-clipped hooks in the file. Checked against this
session's own injected index: the line

    - [BATCH_METADATA carries cypher timings](...) — per-policy ms ALREADY

is 109 characters and arrived **byte-identical** to the file. There is no
injection-side per-line clipping. The mid-clause hooks are an authoring
artifact - hooks were hand-clipped to a ~110 char budget when written, and the
corpus shows it: median 106 chars, p90 110, and only 6 of 220 lines above it.

The budget is still worth enforcing, for a different reason than assumed. The
index as a whole has a 25,000 BYTE limit, and at one line per memory the
per-line length is the only lever on it: 220 x 110 = 24,200, already at the
edge. So compose hooks to the budget - but because of the total, not because
anything truncates a single line.

## Archival cannot fix the index size either

Evidence gathered live from Jira for all 125 ticket keys cited by project
memories. Applying the rule "every cited ticket terminal AND no open-state
language in the body":

| | count |
|---|---|
| provably settled | **3** |
| asserts open state in the body | 21 |
| cites an unresolved or non-existent ticket | 32 |

So demotion sheds **3** index lines, against the ~27 needed. **The corpus is
mostly live work**, which is the same shape as the duplication finding: neither
compaction nor archival can bring this index under 200, because the memories are
neither redundant nor finished.

Two things follow. First, tier-ordering is not a stopgap before the real fix —
it *is* the fix, because managed truncation of the cheapest tail is the only
lever that actually exists. Second, 40 of the 60 ANEP keys no longer resolve in
Jira at all, so a large slice of older project memories can never be proven
settled; their evidence is gone. An archival tool would be correct but would
have very little to do, which is why it was measured rather than built.

Verify blocks recording the live Jira evidence were written for the 3.

## A measurement bug worth remembering

The first run of this analysis reported **13** settled, not 3. The Bash tool's
shell is zsh, which does not word-split unquoted expansions, so `for k in $keys`
iterated once over the whole multi-line string; `grep "^$k"` then treated the
embedded newlines as pattern alternatives, matched every key at once, and the
"is it terminal?" test passed because one of the concatenated statuses was
`Done`. **The wrong answer had exactly the shape of the right one.** Saved as
`reference_bash_tool_runs_zsh_no_word_split`.

## Why the index is not generated

The review's plan was "index generated from frontmatter, hand-editing
forbidden". That cannot hold here: **Claude Code's own memory writer appends
index lines itself.** Twice during one session it appended a `project` entry
into the middle of the `reference` section. A generated index would be violated
by the platform on the very next memory write, and the only way to hold the
invariant would be to let the lint hook rewrite the index — giving up the
property that makes it safe.

So the index stays hand-writable and the ordering is *enforced* rather than
assumed: `bin/memory-index.sh --check|--write` re-sorts as a pure permutation,
and the write-time hook flags an entry filed under the wrong type marker. It
caught a real one immediately.

The one-time rewrite of ~80 descriptions into state-free cues was also dropped.
Descriptions run long by convention (median 167 chars, p75 201) and are not the
hook — it is the **index line** that carries the budget, and that is now checked
directly, along with volatile state in the hook itself.

## Applying it to the existing corpus, 2026-08-25

Ran the whole toolchain across all 8 stores, 295 memories. Corpus-wide findings
went from **133 to 29**, and roughly half of that came from fixing the TOOLS
rather than the memories — three separate cases where the checks disagreed with
each other or cried wolf:

| | |
|---|---|
| index-line budget enforced on tiny indexes | 72 findings, all pointless. The budget exists because the index as a WHOLE is capped near 25,000 chars; seven stores run 269–6,784. Now gated on actual pressure. |
| `type:` parsed two ways | `memory-index` matched only the nested form, filed 13 older memories under REFERENCE, and `memory-lint` — permissive — called all 13 misfiled. Two tools disagreeing about what a memory IS is worse than either being wrong alone. |
| untyped placement double-reported | `memory-index` files untyped entries under REFERENCE deliberately; `memory-lint` then flagged that placement as a second defect. |
| bare `pending` in the state wordlist | two thirds noise; memories describe review states constantly. Also found the description and hook checks each carried their own drifted copy of the list. |

**A finding that can never be actioned is itself noise.** 58 memories had no
`modified:` and an mtime reset to today, so the guard refused all of them
forever. A memory cannot predate the events it records, so `memory-fix` now
falls back to the latest date written INSIDE the memory, capped at today and
tagged `modified_source: content`. That resolved 46; the remaining 12 carry no
date anywhere and stay unstamped, because no date still beats an invented one.

Also applied: index ordering to all 8 stores, hooks composed to budget rather
than hand-clipped, three descriptions rewritten from status ledgers into
state-free cues, two orphaned memories indexed, and verify blocks recorded from
live Jira and GitHub. Every `jira` claim in the corpus was checked against live
Jira; all agree.

**What is left: 17 liveness claims with no `verify:` block.** Each needs a
per-memory GitHub or Jira lookup, which is the audit skill's job, not a script's.

The hook proved itself while this ran: seven memories written by other live
sessions arrived mid-session with missing stamps, 154–1,160-character index
lines, and unverifiable liveness claims. All were caught and fixed as they
landed.
