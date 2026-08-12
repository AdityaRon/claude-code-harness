# Research addendum to MEMORY-HYGIENE-BRIEF.md

Read this **after** the brief. Written 2026-08-11 against Claude Code **2.1.227**.
It exists because the brief's §1 premise — "garbage-collected by nobody" — is **no longer accurate**.
Claude Code ships a memory-hygiene mechanism today, and most of it is simply **not enabled on this
machine**. Re-scope before building anything.

Claims below were checked on this machine (strings from the shipped binary, live settings, live store
contents) or read from the cited source. Where something is inferred rather than observed, it says so.

---

## 1. What Claude Code already ships

| Feature | Evidence | Bears on |
|---|---|---|
| **`/memory`** — "Use /memory to view and manage Claude memory". Also where Auto Dream is toggled and shared-memory projects are picked. | binary strings | all |
| **Threshold nudge** — `tengu_memory_threshold_crossed` → "Use /memory to review and prune stale entries." | binary strings | brief §1 (the "size-hook nag" is **built-in**, not the harness's) |
| **Age warning on recall** — the `N days old` system-reminder the brief describes. | binary strings + brief | mode 1 |
| **Auto Dream / background memory consolidation** — setting `autoDreamEnabled`: *"Enable background memory consolidation (auto-dream). When set, overrides the server-side default."* | binary strings | modes 2, 4, 5 |
| **Shared / team / org memory** with a server-side sync layer | binary strings | mode 5 |
| **`CLAUDE_MEMORY_STORES`** env var | binary strings | §4 fragmentation, Q5 |

### Auto Dream, in detail — this is the big one

Observed in the shipped binary:

- Runs as a **constrained agent**, not a heuristic. Its own prompt says: *"Shell access is restricted
  to read-only commands (`ls`, `find`, `grep`, `cat`, `stat`, `wc`, `head`, `tail`, and similar) plus
  deleting `.md` files inside the memory directory (outside protected subdirectories like `.git` or
  `agents`; `rm` takes no flags except `-f`). Anything else that writes, redirects to a file, or
  modifies state will be denied."*
- **Has the locking the brief says is missing**: `.consolidate-lock`, plus `[autoDream] lock held by
  live PID`, `lock acquire failed`, and `rollback failed` paths.
- **Triggered by session count**, not size: `Sessions since last consolidation (N)` / `N sessions
  since last consolidation, need M`.
- **Phased**, with a `## Phase 3 — Consolidate` step and `dream-proposal` / `DreamTask` machinery.
- Per public write-ups it merges memories, deletes contradicting facts, and **converts relative dates
  to absolute** — i.e. it already covers mode 2.
- Carries an explicit CLAUDE.md rule: *"do NOT edit CLAUDE.md during a dream. Annotate the memory with
  'contradicts CLAUDE.md — verify which is current'"*.

**State on this machine:** `autoDreamEnabled` is **absent** from `~/.claude/settings.json`, and there
are **no** `*dream*` / `*consolidat*` state files anywhere under `~/.claude`. So either the server-side
default is off, or it has never run here. **Check `/memory` first — it may be one toggle.**

### Shared memory already solves mode 5 server-side

Verbatim strings from the binary:

- *"was NOT saved to shared memory: another session updated the file first (concurrent-write conflict).
  The file on disk has been refreshed with the server's current version. Re-read it and re-apply your
  change if it is still wanted."*
- A **mass-deletion guard**: *"N synced memory files went missing from this session's disk at once,
  which almost always means the local memory folder was wiped rather than deliberately cleared…
  If you really do intend to remove that many memories, delete them in smaller batches."*
- **Secret scanning on memory writes**: content that looks sensitive *"cannot be written to team
  memory. Team memory is shared with all repository collaborators."*

Mode 5 is therefore **solved for synced stores** and **unsolved only for purely local ones**. Any
harness locking scheme must not fight auto-dream's `.consolidate-lock`.

---

## 2. A sixth failure mode the brief doesn't have

**Index overflow → silent non-recall.** Claude loads only **~200 lines** of `MEMORY.md` at session
start; lines past that are dropped with no warning. Same end state as mode 3 (orphan): the fact exists
on disk and is never recalled — but caused by index *length*, not absence from the index. Source:
`alexknowshtml/claude-memory-health`, which demotes at a default of **100** lines for this reason.

**Live headroom on this machine** (index lines vs. sibling files):

```
 84  84   -Users-adityasamalla-Desktop-repos          <- leading indicator, ~42% of cap
 26  27   -...-lacework-security-content              <- 1 unindexed file (the brief's known LSC orphan)
 25  22   -Users-adityasamalla
  6   6   -...-genai-service
  4   4   -...-insights-oncall-tools
  4   4   -...-incident-builder
  2   2   -...-helm3-utils
  1   1   -...-claude-code-harness
```

Not yet a live problem — but it caps how far "just keep appending one-liners" scales, and it makes an
index-length check cheap and worth having. Store topology otherwise **confirms the brief**: 8 stores,
158 `.md` files. (Note a 9th slug now exists for a *git worktree* of this repo —
`…-claude-code-harness--claude-worktrees-default-mode-auto` — so worktrees fragment stores further.)

---

## 3. Prior art in the wild

| Project | Shape | Checks | Deletes? |
|---|---|---|---|
| [`alexknowshtml/claude-memory-health`](https://github.com/alexknowshtml/claude-memory-health) | `/memory-health` slash command + TS scripts (`check-bloat.ts`, `check-orphans.ts`) + optional cron scheduler running `claude` headless | size bloat (>100 lines), orphans, inline content that should be extracted, staleness | **No** — demotes to `cold-storage/` |
| [`dgowrie/claude-workflows` → `skills/memory-audit`](https://github.com/dgowrie/claude-workflows/blob/main/skills/memory-audit/SKILL.md) | skill; discover → read index → evaluate → report → apply | >30 days & no ongoing relevance; files >2KB; relative dates → absolute (anchored on mtime); redundancy; cross-project promotion to global `CLAUDE.md` | **No** — proposes, user confirms |

Converging conventions worth adopting:

1. **Nobody auto-deletes.** Both tools demote or propose. This **matches the brief's non-negotiable**
   — and notably *diverges from Auto Dream*, which does delete (with a model in the loop, a lock, and
   rollback). So "just enable Auto Dream" is **not** a full substitute for the brief's intent; that is
   a real, informed disagreement to make deliberately rather than by accident.
2. **Hot/cold split** — `MEMORY.md` + sibling one-liners for behavioural rules; `cold-storage/` for
   domain detail loaded on demand. These stores already follow the spirit of it.
3. **Slash command / skill, not a hook**, for anything needing judgment. Cron + headless `claude` for
   the unattended pass. Matches the brief's Q1 instinct exactly.
4. **Absolute dates always** — relative dates are treated as a defect to be rewritten.

---

## 4. Revised recommendation

**Do first, before writing code (zero effort):** open `/memory`, see whether Auto Dream is available
and off, and turn it on for one cycle. Measure what it fixes in the 84-file store. Everything below is
scoped by that result.

**Don't build** — shipped or covered by prior art: consolidation/merging, relative→absolute date
rewriting, dedup, locking for *synced* stores, mass-delete protection, secret-scanning memory writes.

**Do build — the genuine gaps, in value order:**

1. **Mode 1, external-claim verification.** Nothing — built-in or community — checks a memory against
   *external truth*. Auto Dream reasons over memory content and session logs; both community tools flag
   staleness by **age**, not by fact. The brief's `verify: {gh: lacework/services#33305}` frontmatter
   idea is genuinely novel and remains the **highest-leverage** item. Both proven-false memories were
   one `gh pr view` away. The brief's caveat stands: it only helps memories written *after* the
   convention exists, and the writing convention lives in Anthropic's system prompt — but the harness
   *can* inject the convention via `SessionStart` stdout or `CLAUDE.md`, which is the lever that makes
   it viable without Anthropic changing anything.
2. **Mode 3 + index parity + index length.** Purely mechanical set-difference plus a line count against
   the ~200 cap. Cheap, no model, correct home for a hook. Print only when something is wrong (the
   brief's context-budget constraint, and the resume-drift precedent).
3. **Mode 5 for local-only stores**, as a `PreToolUse` invariant on `MEMORY.md` (entry count must not
   decrease silently) — *if* auto-dream's lock doesn't already cover the observed clobber. Re-verify the
   original clobber against `.consolidate-lock` behaviour before building.
4. **Store fragmentation (Q5)** — investigate `CLAUDE_MEMORY_STORES` before designing symlink/merge
   schemes; it may be the supported answer. Worktrees make this worse (see the 9th slug above).

**Open question this addendum adds:** is enabling **team/shared memory** preferable to building local
locking? It moves mode 5, mass-delete protection, and secret-scanning onto the server — at the cost of
sending memory contents to a shared store, which is a judgment call for work material and must not be
made unilaterally.
