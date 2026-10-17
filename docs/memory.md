# Memory: what Claude Code does now, and what the harness still adds

Measured 2026-10-16 against Claude Code 2.1.300 (Homebrew cask, native arm64
binary at `/opt/homebrew/Caskroom/claude-code@latest/2.1.300/claude`, read with
`strings`), the upstream CHANGELOG at that date, and the live stores under
`~/.claude/projects/*/memory/`. Where a claim is read from minified code it
says so. The 2026-08 research this supersedes is in `history/`.

## What the CLI does on its own

| Behaviour | Since | Evidence |
|---|---|---|
| Loads at most 200 lines and 25,000 `byteCount` of `MEMORY.md`; truncation is line-first | 2.1.83 | binary: `AF=200,tae=25000`; in 2.1.300 `byteCount` is `r.length`, a string length, so characters; the harness measures bytes, which is the stricter reading |
| Reminds the writer to compact the index when a write leaves it near the limit | 2.1.186 | binary: "approaching the … read limit. Compact it" |
| Returns an error on a write that leaves the index over the limit | 2.1.210 | CHANGELOG; binary: "Error: this write left the … over its … read limit. The write succeeded, but everything past the limit … Rewrite it" |
| Stamps `modified` (ISO 8601) in the frontmatter of every memory file it writes | 2.1.214 | CHANGELOG; every file in the live stores carries it |
| Stamps `originSessionId` on memories it writes | observed | all 6 memory files on this machine carry it under `metadata:` |
| Neutralizes markup that imitates its own in `MEMORY.md` and recalled notes | 2.1.284 | CHANGELOG |
| Auto-dream: a background consolidation pass (below) | present, gated | binary only; absent from the CHANGELOG through 2.1.302 and from code.claude.com/docs/en/memory and the settings reference |

### Auto-dream, read from the 2.1.300 binary

- **What it does.** Runs a forked agent over one store with a four-phase prompt
  ("Dream: Memory Consolidation"): orient, gather recent signal (including
  transcript grep), consolidate (merge into existing topic files, convert
  relative dates to absolute, delete contradicted facts), then prune and index
  (keep `MEMORY.md` under 200 lines and ~25KB, remove stale pointers, demote
  lines over ~200 characters, resolve contradictions). Shell access is
  read-only plus `rm` of `.md` files inside the memory directory. It must not
  edit `CLAUDE.md`.
- **Gate.** The feature exists only where the `tengu_onyx_plover` server flag
  reports `enabled` or `available`. The `autoDreamEnabled` setting ("Enable
  background memory consolidation (auto-dream). When set, overrides the
  server-side default") is read only after that check, so setting it where the
  flag is off does nothing, and the `/memory` dialog hides the Auto-dream row.
- **Cadence.** Defaults `minHours: 24`, `minSessions: 5` (flag can override);
  a scan at most every 10 minutes; skipped when a permission rule would refuse
  memory writes.
- **Lock and state.** `<store>/.consolidate-lock`. Held while the PID inside
  is alive and the file is under 1 hour old; after a run the file stays, empty,
  with its mtime set to the consolidation time, which is also how "hours since
  last consolidation" is read. A kill rolls the mtime back.
- **On this machine.** No `.consolidate-lock` exists in any store
  (`find ~/.claude -maxdepth 5 -name '*consolidat*'` is empty) and
  `autoDreamEnabled` is not set in `~/.claude/settings.json`. Auto-dream has
  never run here. Of the six memory files across three stores, four have a
  `modified` stamp within 2 s of their mtime; the other two were rewritten
  16 h and 5 days after their stamp, and the harness audit log names the
  writer: sessions appending with `cat >>` and `python3 - <<EOF` from Bash.
  Neither the CLI's stamp nor memory-lint sees a shell write (both act on the
  Write and Edit tools), which is a gap worth knowing about, and not a dream.
  To check for yourself: `/memory` shows an Auto-dream row only where the flag
  allows it.

## What the harness still does, and why

| Component | Verdict | Reason |
|---|---|---|
| `hooks/session-start.sh` reorder of the index | **Demoted** | Runs only when the index is at or past the pressure thresholds memory-lint uses (180 lines or 20,000 bytes), only when the index changed since the last run (mtime and size stamped under `state/sessions/memory-index/`), and never while `.consolidate-lock` is under an hour old. Was 60-80 ms of a ~100 ms start here, 1.7 s on a slower machine, on stores far from the cap. |
| `hooks/memory-lint.sh` | **Kept, trimmed** | Write-time checks the CLI does not make: name matches filename, valid type, description present and state-free, liveness claims carry a `verify:` block, link separator typos, the memory is indexed and filed under the right tier, `feedback_` past the cut. Dropped: the `modified` check (the CLI stamps it on the write) and the generic over-limit index findings (the CLI errors on them). The `originSessionId` stamp stays as a backstop: the CLI stamps it on the memories it writes through its own path, and whether every Write-tool path into a memory directory gets one is unverified. Auto-dream's `priorMtime` is the lock's, not the files', so the stamp cannot trip its rollback. |
| `bin/memory-verify.sh`, `/memory-audit` | **Kept** | Checks claims against GitHub and Jira. Nothing upstream leaves the machine to do this, and auto-dream's prompt reasons only over the files and transcripts. |
| `bin/memory-provenance.sh` | **Kept** | Who wrote a memory and whether the session citing it also wrote it. Not upstream. |
| `bin/memory-index.sh` | **Kept, on demand** | Tier ordering and `--archive-overflow`, invoked by the gated session-start path and by `/memory-archive`. Auto-dream prunes pointers; it does not order or archive. |
| `bin/memory-fix.sh` | **Kept, on demand** | One-off repairs of name, links and `modified` on memories written before 2.1.214 or by other means. |
| `/memory-archive` | **Kept, cut down** | Triggers only on the CLI's own over-limit error or an explicit ask. Its unique content is the never-delete rule and the hub pattern. |
| the three memory-hygiene documents | **History** | Moved to `history/`. The 200-line cap folklore, the withdrawn heuristics and the measured corpora are still cited by the skills, as history. |

Nothing the harness does writes a store while auto-dream's lock is fresh, and
nothing re-implements consolidation: the contract entry "auto-dream memory
consolidation" in `config/upstream-contract.json` says do not rebuild it.

## If auto-dream turns on here

Expect it to delete contradicted memory files and stale index lines. That is
the inverse of the harness rule "never delete, archive the line", so enabling
`autoDreamEnabled` is a philosophy choice. The harness tools stay valid either
way: verify checks the world, provenance checks the author, lint checks the
write, and the session-start reorder yields to the lock.

## Using the tools

Moved from the README.

Claude Code stores memories under `~/.claude/projects/<slug>/memory/` and now
does most of the hygiene itself: it loads the first 200 lines / 25 KB of
`MEMORY.md`, reminds the writer when a write leaves the index near that limit
and returns an error when it is over it, stamps `modified` and
`originSessionId` on what it writes, and ships a background consolidation pass
(auto-dream) that merges, rewrites relative dates and prunes the index. That
pass is gated on a server flag and had never run on the machine this was
measured on.

What the harness still adds is the part that needs the outside world or the
write itself:

- **`memory-verify.sh` and `/memory-audit`** check a memory's claims against
  GitHub and Jira. *"Draft PR #4821, held"* stays internally consistent
  forever while the PR merged two months ago; nothing in the file disagrees,
  GitHub does. A memory becomes mechanically checkable by carrying a
  `verify:` block (`- gh acme/api#4821 merged`, `- jira PROJ-123 Done`); the
  skill resolves the bare references a script cannot and writes the block
  back. Read-only by contract: it proposes, never deletes.

  ```bash
  bash ~/.claude/memory-verify.sh --store <slug>     # exit 0 fine, 1 stale, 2 triage, 3 could not run
  ```

- **`memory-lint`** checks a memory at the moment it is written, for what the
  CLI does not check: name matches filename, a valid type, a state-free
  description, a `verify:` block on any in-flight claim, link typos, an index
  line in the right tier. Advisory, never blocks.
- **`memory-provenance.sh`** answers who wrote a memory, so a session cannot
  cite as corroboration a memory it wrote itself. `--session NAME` asks whether
  the session telling you something also wrote the memory it cites as
  agreement.
- **`memory-index.sh` and `/memory-archive`** keep the index in tier order and
  relieve one the CLI reports as over its limit, by moving lines to an archive
  rather than deleting. `session-start` runs the reorder only when the index is
  near its cap, has changed since the last run, and auto-dream's
  `.consolidate-lock` is not fresh; on an ordinary store it costs nothing.
