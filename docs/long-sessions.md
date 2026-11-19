# Long-running sessions

A session you keep for days, through many compactions, works. Its transcript grows the whole time, though, and nothing in Claude Code tells you so. This page covers what grows, what the harness measures and caps, and what to do when it says a session is large.

## What grows

Claude Code writes each session to `~/.claude/projects/<project>/<session-id>.jsonl`, one line per record. Compaction shrinks what the model sees, not that file. It appends a summary and a `compact_boundary` record, and every earlier record stays. A session restarted from a handoff starts a new, small file.

Measured on one work Mac (harness v1.4.13, 2026-11-19):

| What | Size |
|---|---|
| The project's transcript folder | 94 transcripts, 4.7 GB |
| Five sessions that were restarted or had ended | 212 MB to 584 MB, and one of 1.9 GB |
| Live sessions after restarting from handoffs | 6.9 MB to 14.5 MB |
| The harness's pre-compact backups, before the cap took effect | 2.6 GB in 20 files (09:40Z) |
| The same, after the next compaction under the cap | 797 MB in 11 files (18:40Z) |

The backups were the harness's own doing. Until v1.4.12, `pre-compact` kept a full copy of the transcript at every compaction, so one long session left a copy per compaction, each larger than the last.

## What the harness does

- **Measures, once a day.** `harness-update.sh` runs `disk-space.py stamp`, which records each session transcript's size and compactions. It sizes nothing on the hot path; session-start only reads the stamp.
- **Nudges at session start:**
  - On resume or compaction, if this session's transcript is past `CLAUDE_TRANSCRIPT_WARN_MB` (150 MB), "This session's transcript" names its size and compactions. It says to write the handoff, then restart in a fresh session.
  - Once per measurement, on any start, "Large session transcripts" counts the transcripts written in the last 7 days that are past the same size.
- **Caps the backups.** `pre-compact` keeps one copy per session, since each copy is a byte prefix of the next. It keeps the newest 20 within `CLAUDE_TRANSCRIPT_BACKUP_MAX_MB` (1000 MB, 0 for no cap), and none older than Claude Code's `cleanupPeriodDays`.
- **Lists them on demand.** `python3 ~/.claude/disk-space.py report` lists every transcript past the size. For each one it gives its compactions and last write, the process that has it open (by `lsof`) or the days it has sat idle, and the date Claude Code will remove it. A `?` means `lsof` could not tell: it is never read as dead.
- **Checks the handoff's shape.** `memory-lint` checks a handoff in a `trackers/` folder when it is written: the five headings in order, under 5 KB, a `STATE:` stamp and a `Crons:` line. A file counts as a handoff if it carries a `STATE:` or `Crons:` line or a `## Next on restart` heading. A file named `*-handoff*.md` without them gets one finding asking for them. Everything else in the folder (ledgers, reports, logs) is left alone.
- **Keeps big trackers readable.** `python3 ~/.claude/tracker-prune.py FILE` lists the settled rows a ledger could move to `<name>-archive.md`. `--write` moves them, under a lock, and never leaves a row in neither file.

## What to do

1. When session-start says a transcript is large, write the handoff, `trackers/<name>.md`, replaced in place:
   - the headings `## Scope`, `## Open`, `## Owed`, `## Settled`, `## Next on restart`;
   - a `STATE:` line from `date -u`;
   - `Crons:` with each session cron as its expression and prompt, or `none`.

   Keep it under 5 KB. A ledger it points to is read by slice (`grep`, `sed -n`), never whole.
2. Start a fresh session and have it read the handoff.
3. Leave the old transcript where it is. `claude --resume` and the harness's report tools (`bin/spend-report.py`, `tools/permission-friction.py`, `tools/shadow-report.py`) still read it. Claude Code removes a session's transcript once it has been inactive for `cleanupPeriodDays` (30 days by default). `disk-space.py report` shows the date. Nothing in the harness deletes transcripts.

## Settings

| Setting | Default | Where |
|---|---|---|
| `CLAUDE_TRANSCRIPT_WARN_MB` | 150 | `env` in settings.json: the size the nudges and `report` use |
| `CLAUDE_TRANSCRIPT_BACKUP_MAX_MB` | 1000 | `env`: the backups' total; 0 for no cap |
| `CLAUDE_TRACKER_LINT` | on | `env`: `off` turns the handoff lint off |
| `cleanupPeriodDays` | 30 | Claude Code's own setting: how long an inactive session's transcript is kept |

The rule behind the handoff is in `rules/working-agreement.md` ("Finish the loop"); the hook details are in [hooks.md](hooks.md).
