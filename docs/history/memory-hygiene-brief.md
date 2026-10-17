# Brief: memory-store hygiene in the Claude Code harness

Handoff context for a harness session. Written 2026-08-11 after auditing the live memory stores.
Everything below was verified on this machine, not assumed.

---

## 1. The problem in one paragraph

Claude Code's file-based memory (`~/.claude/projects/<slug>/memory/`) is **durable by design and
garbage-collected by nobody**. `originSessionId` in each file's frontmatter is provenance metadata,
not a lifetime binding — memories outlive their session permanently and correctly. The gap is that
nothing detects when a memory has become *false*. The only corrective pressure is advisory and aimed
at the model: a `<system-reminder>` stamps an age warning when a memory is read ("this memory is 68
days old… verify before asserting"), and a hook nags when `MEMORY.md` exceeds a size threshold.
Neither inspects content, and neither fires unless a memory happens to be read. A memory that is
never recalled is never checked, and a memory that *is* recalled is trusted with only a soft warning.

## 2. Evidence (from the largest store: 84 files, 47 distinct sessions, Jun 4 → Aug 11)

Spot-checking only the **two oldest** entries claiming open state, both were wrong:

| Memory | Claimed | Reality | Wrong for |
|---|---|---|---|
| a UI fix memory | "draft PR, held, land only if…" | the PR had **merged two months earlier** and was never a draft | ~2 months |
| a websocket-timeout memory | "PENDING: merge, deploy, live-verify" | the PR had **merged two months earlier**; a later paragraph *in the same file* already said "MERGED & verified" | ~2 months |

15 further `project_*` memories in that store assert open state and are 1–3 months old. **Unaudited.**
Both verified failures were resolvable in one `gh pr view` call — i.e. mechanically checkable.

## 3. Failure taxonomy

Five distinct modes, deliberately separated because they need different mechanisms:

1. **Stale assertion** — memory claims state that has since changed. *Detectable* when the memory cites
   an external ID (PR, Jira key). Needs an external lookup (`gh`, Atlassian), not just text analysis.
2. **Append-don't-revise contradiction** — an update was appended while the original contradicting
   sentence stayed. Self-contradictory *within one file* (one memory said both PENDING and MERGED).
   Cheap heuristic: co-occurrence of open-state and closed-state markers. Needs a model to adjudicate.
3. **Orphan file** — exists on disk but absent from `MEMORY.md`. Since only `MEMORY.md` is loaded into
   context, an unindexed file is **never recalled** — pure dead weight that still costs disk and
   confuses audits. Found 2 in the big store (one was a standing user preference about Slack style
   that had therefore been silently inert), and 1 more in a second store.
   Trivially detectable: set difference, both directions.
4. **Index truncation / entry loss** — a compaction pass (size-hook driven) truncated 3 entries
   mid-sentence, destroying the operative fact while leaving a plausible-looking line. Detectable:
   unbalanced parens/brackets, missing terminal punctuation, entry-count drop.
5. **Concurrent-write clobber** — `MEMORY.md` is a shared mutable file with **no locking**. Two live
   sessions in the same project both edit it; last writer wins. Observed twice in one hour today: a
   parallel session's write rejected mine, and its compaction truncated entries I had just written.
   This is the most harness-shaped problem of the five.

## 4. Store topology (matters for any machine-level hook)

Memory is siloed **per launch directory**, not per repo. 8 stores, 158 files:

```
<home>-repos                          84 files   <- the big one
<home>-repos-<repo-a>                 27         <- same repo, different cwd
<home>                                22
<home>-repos-<repo-b>                  6
<home>-repos-<repo-c>                  4
<home>-repos-<repo-d>                  4
<home>-repos-<repo-e>                  2
<home>-repos-claude-code-harness       1
```

Note rows 1 and 2: working on `<repo-a>` from the parent directory vs from the repo
directory writes to **two different stores**. Facts fragment by where you happened to launch. Worth
deciding whether that's a bug to solve or a constraint to live with.

Integrity sweep across all 8 (orphans / indexed-but-missing / truncated) came back clean except the
big store (now repaired) and 1 orphan in the LSC store — so **integrity is mostly fine; staleness is
the systemic issue, and it scales with store age and size.**

## 5. Extension points that already exist here

The harness is well-positioned; nothing new needs inventing structurally.

- **`SessionStart` → `hooks/session-start.sh`** — already wired. Its stdout is injected **directly into
  the context window**, no prompt needed. It already implements the exact pattern this needs:
  *compare recorded prior state to current on-disk state, and surface drift so Claude re-verifies
  before trusting it* (the `source=resume` snapshot-diff block). A memory-staleness report is the
  same shape aimed at a different corpus.
- **`SessionEnd` / `Stop`** — both wired (`audit.sh`, `session-snapshot.sh`). Natural home for a
  mechanical integrity sweep that costs no context.
- **`PreToolUse` on `Write|Edit|MultiEdit`** — already used by `secret-scanner.sh`. A guard could
  enforce a *no-silent-entry-loss* invariant on `MEMORY.md` (reject a write that drops or truncates
  entries), which directly prevents modes 4 and 5.
- **`hooks/lib.sh`** — `read_input`, `jq_get`, `expand_tilde`, `sha256_file` already available.
- **`tests/<hook>.test.sh`** — per-hook test convention, plus `fail-closed.test.sh` and `doctor.sh`.

## 6. Constraints / non-goals

- **Never auto-delete.** Both deletions today were justified only *after* an external check confirmed
  the claim was false. Getting this wrong destroys knowledge silently — strictly worse than staleness.
  Surface-and-nudge beats delete-on-heuristic.
- **Fail-open, silent.** Memory hygiene must never block work. The guards here fail *closed* by design
  (`fail-closed.test.sh`); a hygiene hook should be the opposite.
- **Context budget is the real cost.** `MEMORY.md` is loaded every session in that project — that's
  precisely why entries are one-line hooks with detail in sibling files. Anything `SessionStart`
  prints is paid for on every single session, so a health report must be terse or conditional
  (e.g. print only when something is actually wrong, like the resume-drift block does).
- **Machine-level, cross-store.** Must handle all 8 stores generically, and any new one.

## 7. Open questions for that session

1. **Split of duties** — which parts are a *hook* (mechanical, no model: orphans, truncation, index↔disk
   parity, age) vs a *skill / slash command* (`/memory-audit`: external lookups + judgment)? Hooks
   can't call `gh` cheaply on every session start.
2. **Trigger cadence** — every SessionStart is too often for an external-lookup audit. Age threshold?
   Only on `source=startup`? A staleness stamp file so it runs at most weekly?
3. **Concurrency (mode 5)** — is a lock/atomic-rewrite for `MEMORY.md` worth it, or is a PreToolUse
   invariant check ("entry count must not decrease, no line may lose its terminal clause") enough?
4. **Should memories carry a machine-checkable claim?** e.g. an optional frontmatter field like
   `verify: {gh: owner/repo#NNNN}`. That converts mode 1 from NLP into a lookup, and is the
   single highest-leverage change — but it only helps memories written *after* it exists, and needs
   the writing convention (in the memory system prompt) to change too, which may be outside harness control.
5. **Store fragmentation** — solve (symlink/merge by repo), or document and live with?

## 8. Immediate state

Already repaired by hand in the big store today, so don't re-find these: 1 false memory deleted,
1 self-contradiction fixed, 2 orphans indexed, 3 truncated entries restored, 1 orphaned `[[link]]`
repointed. Index and disk now agree at 84/84. The 15 unaudited open-state `project_*` memories in that
store are the outstanding backlog and a good test corpus for whatever gets built.
