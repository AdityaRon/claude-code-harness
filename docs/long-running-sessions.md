# Keeping Claude Code sessions alive for days

Written 2026-11-19 against Claude Code **2.1.329** and harness **v1.4.14 to v1.4.15**. Measured on two Macs:
- **The work Mac** runs about 15 background sessions, some of them for two months, each with a `/loop` or cron tick.
- **The personal Mac** runs Claude Code 2.1.328, a few sessions, one of them kept for days.

Where something is inferred rather than measured, it says so.

## Transcripts only grow

A session's transcript (`~/.claude/projects/<project>/<session>.jsonl`) is appended to on every turn. Compaction shortens what the model sees; it does not shrink the file. It appends a summary and a `compact_boundary` record, and every earlier record stays. Resume and respawn load the session from this file (inferred, not measured: they read all of it).

Measured on the work Mac:
- Three sessions kept for eight to nine weeks reached 343 to 395 MB each, and one reached 584 MB in under six weeks (`ls -lS ~/.claude/projects/*/*.jsonl | head`; first and last `timestamp` in each file).
- The project folder held 4.7 GB in 94 transcripts.
- Inferred, not proven: session loading and the agent view got slower as these grew.

On the personal Mac the folder held 78 transcripts, 342 MB, the largest 95 MB.

session-start names a large transcript on resume and after compaction (v1.4.12), so you hear about it before it hurts. Once a day it also counts the large transcripts across the machine.

## Restart from a handoff, not from the transcript

What worked: each long session keeps a short handoff file, and is replaced by a fresh session with the **same name** that reads it first. On the work Mac, live transcripts went to 6.9 to 14.5 MB.

- **The shape** is in [rules/working-agreement.md](../rules/working-agreement.md):
  - the headings `## Scope`, `## Open`, `## Owed`, `## Settled` and `## Next on restart`;
  - a `STATE:` line from `date -u`;
  - `Crons:`.

  Keep it under 5 KB, replaced in place, never appended.
- **memory-lint** checks a file under `trackers/` once it is marked as a handoff by a `STATE:` or `Crons:` line or a `## Next on restart` heading. A file named `*-handoff*.md` without a marker gets one finding asking for one (v1.4.15).
- **Keep the same session name.** Other sessions and your own routing reach a session by name ([session-routing.md](session-routing.md)).
- **Point at big ledgers** instead of copying them, and read a ledger by slice (`grep`, `sed -n`). `tracker-prune.py FILE` lists the settled rows it would move to `<name>-archive.md`. It moves table rows with a Status column, `- [x]` items and `DONE:` bullets, never headings, prose or anything in a code fence.
- **`/clear` in the old session does the same in place:** a new transcript under the same name, flags and job folder, with nothing to delete. It needs someone to type it, and then a prompt to read the handoff.

Traps we hit:
- Until the old session is deleted, two sessions share the name. A send by bare name fails and asks for the `[ref]`. Refs change when sessions restart, so read them from `ListAgents` each time.
- A `STATE:` stamp written early and saved late, such as a write that waited on a permission check, is flagged as stale: memory-lint flags a stamp more than 5 minutes older than the write. Take the stamp at write time.

## Session crons belong to the session

A fresh session, which is what the restart above gives you, has none, so list each cron under `Crons:` as its five fields and its prompt and recreate it there. `claude --resume` and `claude --continue` differ: the [scheduled-tasks page](https://code.claude.com/docs/en/scheduled-tasks) (read 2026-11-20) says they restore CronCreate tasks, except a recurring one past its 7-day expiry, a one-shot whose time has passed, anything after `Exit and stop tasks`, and a self-paced `/loop`, which has to be run again. CronCreate's own description in 2.1.328 says the job is gone when Claude exits; we have not tested which holds. After a resume, run CronList before recreating from `Crons:`, or a tick can run twice. A restored task does not catch up on missed runs. A one-shot that has to wait for a condition can re-arm itself with the same prompt.

## A reboot resumes everything at once

After a reboot of the work Mac, every background session resumed together:
- The 1-minute load sat at 5 to 7 for hours on a 15-core machine.
- The OS's own indexing and media analysis took 90 to 275% CPU, and endpoint agents about 120%.
- All Claude processes together took 12 to 17%.

Do not compare timings across that window: `bin/hook-latency.py` and `tools/shadow-report.py` take `--since` for that.

## Every process a hook starts costs more on a managed machine

Measured, p50 of 5:
- **The work Mac, under load:** `bash -c :` took 25 to 35 ms and `true` 35 ms.
- **A CI runner:** 0.5 to 1.4 ms.
- **The personal Mac:** 8.4 and 8.6 ms at a load average of 22.6, and about 2 ms at 4.5 to 5 (median of 40).

Inferred: endpoint security inspects each new process. A hook that starts ten processes pays that ten times on every tool call.

What helped:
- All Bash guards run as forks of one dispatcher (`bash-guards.sh`).
- `hook-bench.py --launches` counts what each hook starts, and the release and PR gates fail a change that starts more.

In real use, the slowest guard per Bash call (`guard-timing.log`) went from a 0.74 s median on v1.4.9 to 0.26 to 0.41 s on v1.4.14. The slowest 10% still wait 3 s or more, on long chained commands. That part is open: git-guard and interpreter-guard start more processes on commands with heredocs, pipes and git words.

## Disk

- **Transcripts.** The harness never deletes them. Claude Code removes a session's transcript once it has been inactive for `cleanupPeriodDays` (30 by default). On the personal Mac, with that setting unset, the oldest last write was 29.5 days ago. A session that keeps running never qualifies.
  - `python3 ~/.claude/disk-space.py report` (v1.4.15) lists each transcript over 150 MB. For each one it shows the process that has it open or its idle days, and the date Claude Code will remove it. It shows `?` when liveness can't be told.
  - A transcript is still read after its session ends: by `claude --resume`, and by the report tools above.
- **Pre-compact backups.** These were the harness's own growth: until v1.4.12, `pre-compact` kept a full copy at every compaction. Now it keeps one copy per session, the newest 20 within 1000 MB, and none older than `cleanupPeriodDays`. The cap applies at the next compaction: on the work Mac, 2.6 GB in 20 files fell to 797 MB in 11 after one.
- **Job folders.** `disk-space.py report` and `prune`. A live job's tmp is kept: on the work Mac, Python venvs of 1.4 and 1.6 GB sat inside two live jobs.
- **Spotlight.** On the work Mac it had indexed 1,285 transcripts under `~/.claude` (`mdfind -onlyin ~/.claude -count 'kMDItemFSName == "*.jsonl"'`); on the personal Mac, 919. Adding `~/.claude` under Spotlight's Search Privacy took the work Mac's count to 0. Its CPU cost was not measured.

## A lint must not invite a cut

A shape lint first matched every file under a `trackers/` folder. It told a session that a 113 KB working tracker was "past 5000 bytes; settled detail belongs elsewhere". A notes folder may have no other copy. The lint now checks only files marked as handoffs, and no finding says to cut or overwrite. Scope a lint to files that opted in, and phrase every finding so that obeying it cannot lose data.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `CLAUDE_TRANSCRIPT_WARN_MB` | 150 | `env` in settings.json: the size the session-start nudges and `report` use |
| `CLAUDE_TRANSCRIPT_BACKUP_MAX_MB` | 1000 | `env`: the pre-compact backups' total; 0 for no cap |
| `CLAUDE_TRACKER_LINT` | on | `env`: `off` turns the handoff lint off |
| `cleanupPeriodDays` | 30 | Claude Code's own: how long an inactive session's transcript is kept |

Hook details: [hooks.md](hooks.md).

## Not measured

- How common long sessions are.
- Whether transcript size is what slowed the agent view.
- What Spotlight indexing of growing transcripts costs.
