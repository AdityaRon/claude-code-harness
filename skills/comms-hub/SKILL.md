---
name: comms-hub
description: The comms session's recurring tick, and how every other session sends Slack. Use in the one long-lived comms session on each tick (GitHub queue, Slack replies, routing events to peer sessions, gating and sending their drafts, resolving answered-and-approved threads on my PRs), and in any other session about to send, answer or schedule a Slack message, which hands the draft to the comms session instead.
---

# comms-hub: one session speaks on Slack for all of them

One long-lived session, the comms session, runs this tick on a recurring
trigger. It is the only session that sends Slack messages. Every other session
(a peer) drafts the message and its target and hands both over with
SendMessage; the comms session checks every claim, gates the draft and sends
it. It never approves a PR and never merges someone else's: approval is the
human's.

## If you are a peer

Do not send, schedule or edit a Slack message yourself. Send the comms session
(find it with ListAgents; ask the user if none is clearly it) one message for
all the drafts you hold:

```
comms-hub draft
to: <channel id> reply <thread ts>      (or: to: <channel id> top-level)
claims:
- <each fact the message states> | <its source: PR URL, ticket key, page URL and version>
user-approved: <the user's words, quoted> | no
fold-in: expected | none
---
<the message, exactly as it should go out>
```

`fold-in: expected` means more is coming for the same thread (a CI run, an
answer you are waiting on). The comms session replies with the sent ts, the
scheduled id, or why it held the draft.

## Setup, once per machine

Needs `gh` signed in as you, Python 3.10+ with a TOML reader, `jq`, and a Slack
MCP server registered with Claude Code under a name containing `slack` (the
Slack connector from `/mcp`, or any server added with `claude mcp add`) whose
tools read a channel, read a thread, search, send and schedule a message.
Nothing here depends on which server it is: step 0 records the tool names.

1. `bash install.sh` from the clone puts this skill in `~/.claude/skills/comms-hub/`.
2. `PY B/hub.py init` writes `~/.config/comms-hub/config.toml` from the
   example with your GitHub login, that login as the one owner searched, and
   this machine's time zone filled in; it refuses to touch an existing file.
   Fill in each `CHANGE-ME` it lists (the Slack ids; the example says where
   Slack shows them) and add your org to `github.owners`. That file holds the
   ids and names a public repo cannot, and never goes in a repo. State goes to
   `~/.local/state/comms-hub/` unless `state_dir` says otherwise.
3. From the clone: `bash doctor.sh --skill comms-hub`. Every line but the
   session preflight can read ok before the comms session exists.
4. Start the comms session with the command `PY B/hub.py launch` prints
   (`claude --settings '…'`): a 150k-token compact window and a 2-minute MCP
   timeout for this session only. Every tick re-reads the whole context, and
   the tick's state is on disk, so a small context loses nothing. Exported in
   the shell instead, the window loses to the one `~/.claude/settings.json`
   sets. The command also loads the panel (`panel/`, `--plugin-dir`): a pane
   with the held drafts and today's log, read from disk as each turn ends, so
   it costs no tokens (`/comms` opens it again). Then step 0 below, then the
   trigger: `/loop` with the cron interval
   `PY B/hub.py cron` prints (from `[active_hours]`: weekdays, 08:07 to 17:37,
   by default) and the prompt `comms-hub tick`, then
   `PY B/hub.py trigger --created "<that interval>"`. Never a self-paced
   `/loop`: a wakeup cannot sleep past an hour, so it would tick all weekend.
   Then doctor again.

In the commands here and below, `PY` is the interpreter that
`bash ~/.claude/skills/comms-hub/bin/python.sh` prints and `B` is
`~/.claude/skills/comms-hub/bin`. Write both out in full in every command
(`/usr/bin/python3.12 ~/.claude/skills/comms-hub/bin/queue.py scan`): shell
variables do not survive between calls. Dumps, listings and drafts go in the
directory `PY B/hub.py config` prints as `tmp:` (the session's job tmp dir when
Claude Code set `CLAUDE_JOB_DIR`, else under the state dir), never `/tmp`,
which every job shares. Each script's `--help` gives its flags and exit codes.

## Step 0: preflight

At session start, and when doctor calls the record old. Load each tool with
ToolSearch: the Slack MCP's read channel, read thread, search, send message and
schedule message tools; ListAgents; SendMessage; CronList, for the tick's
trigger; optionally a Jira or Confluence tool. Then write
`<state dir>/preflight.json` with the Write tool (`PY B/hub.py config` prints
the state dir, the tmp dir, the Slack ids and the routes):

```json
{"checked_at": "2026-10-21T17:00:00Z",
 "slack_read_channel": "<tool name>", "slack_read_thread": "<tool name>",
 "slack_search": "<tool name>", "slack_send": "<tool name>", "slack_schedule": "<tool name>",
 "list_agents": "ListAgents", "send_message": "SendMessage",
 "trigger": "<the tick's cron expression, from CronList>", "tickets": "<tool name, or empty>",
 "slack_delete_scheduled": "<tool name, or empty>"}
```

Leave a key empty when its tool is missing, and tell the user: doctor fails on
it, and the tick cannot run without it. Then `PY B/hub.py launch --check`: a
failure means this session was not started with `hub.py launch`'s command, so
tell the user to restart it with that command. `slack_delete_scheduled` and `tickets`
are optional: without the first, a scheduled message whose claims moved can
only be reported, not withdrawn.

## The tick

Before anything, `PY B/hub.py window`. Exit 1 means outside `[active_hours]`:
end the tick there, with no log line and no report, since nobody can act on
what it finds (the trigger's jitter can fire one a few minutes after close). A
peer's draft that arrives then is still handled when it arrives (step 4).
When it prints `scan: full`, run CronList too, then
`PY B/hub.py trigger --live "<the tick's expression>"`: a MISMATCH, RENEW,
ZONE or NONE line says what to delete and create (Claude Code deletes a
recurring task 7 days after it was created, so without RENEW the loop dies
weekly). With `scan: quick`, step 2 reads the DM only.

**Fail fast.** If the tick's first call out (the scan, or the first Slack
read) fails, times out, or gets no permission verdict, run
`PY B/hub.py log "tick ended: <why>"` and end the tick. Never retry inside the
tick: the next fire is the retry, and every call re-reads this session's
whole context.

0. **A scan still running** from an earlier tick is killed by the next
   `queue.py scan`, which says so. A scan that slept with the laptop ends
   BLOCKED on its wall-clock watchdog: report it, do not retry in a loop.
1. **GitHub**: `PY B/queue.py scan`. Read INBOUND, WATCHED, AWAITING, OUTBOUND,
   DRIFT and UNKNOWN, and the header's `search-quota` and `my-open-xcheck`. If it
   prints BLOCKED, the queue is unknown, not empty: say so, with the reason, and
   never present the sections as complete.
   1b. `PY B/resolve_threads.py` (a dry run); read every RESOLVE and SKIP. Then
   `PY B/resolve_threads.py --apply`. It re-reads each thread, prints what
   GitHub reports, and logs what was resolved.
   1c. **INBOUND review**, for each INBOUND PR: first
   `PY B/hub.py window --review`. Exit 1 means the window closes before a
   review could finish with someone there to read it, and a subagent left
   running while the laptop sleeps re-writes its whole cache on every wake:
   log `review of <PR> waits for the next window` and spawn nothing. The PR
   stays INBOUND, so a later tick reviews it. Otherwise
   `PY B/pr_transcript.py owner/repo#N -o <job tmp>/pr-N.md` (its first line
   is `head:`), then spawn a reviewer with the Agent tool: the pr-review
   skill, the transcript, `gh pr diff N --repo owner/repo`, and the ask to
   write findings only, no verdict, to `<job tmp>/review-N.md`. Then one
   command, the lint chained to the post with `&&`, never `;` (a `;` once let
   a refused body go out):
   `PY B/review_lint.py <job tmp>/review-N.md --pr owner/repo#N --head <sha> && gh pr review N --repo owner/repo --comment --body-file <job tmp>/review-N.md`.
   The lint re-reads the head and the open state first. COMMENT only: this
   session never approves or requests changes, whatever the findings say.
2. **Slack**:
   - The primary DM: read its first page in full, without `oldest`. Write the
     tool's output to `<job tmp>/dm.txt`, run
     `PY B/slack_listing.py <job tmp>/dm.txt -o <job tmp>/dm.tsv`, then
     `PY B/slack_diff.py <job tmp>/dm.tsv --channel <primary_dm>`. Read every NEW
     and MOVED thread in full. Only then
     `PY B/slack_diff.py <job tmp>/dm.tsv --channel <primary_dm> --commit --read <every NEW and MOVED ts>`.
     The first run takes `--commit --baseline` instead; say nothing before it
     was checked. UNREADABLE, UNTRUSTED or STALE means the read failed: no
     commit, say so. The listing refuses a short (concise) read, which drops
     reply counts, and a page read with `oldest`; read again in full. The
     diff refuses a listing older than 15 minutes: last tick's page diffs as
     nothing new. Several pages of one read go to one listing (`DUMP...`).
   - With `scan: full` only, each watched channel: the same as the DM, with its own dump, listing and
     `--channel <id>`: the first page in full, never with `oldest` (with it,
     Slack returns the oldest messages first, and a DM once looked quiet with
     four unread). Read in full every NEW and MOVED thread, not only those
     that name the user: a reply count that moved is a reply someone may be
     waiting on. A top-level post that names nobody is an event for the
     `routing` entry whose `channels` holds the channel (step 3).
   - With `scan: full` only, mentions: three searches, not one, each sorted by time: the queries
     `PY B/hub.py queries` prints (`<@my_user_id>`, `to:<@my_user_id>` and
     `with:<@my_user_id> is:thread`, each `after:` two days back). Each of the
     last two once caught a reply the others missed, one under a week-old
     thread. Use the date filter: an epoch filter once returned 0, and an
     empty result is ambiguous. The newest hit of each shows how far it
     reached; if it is older than the last tick, say the search may not have
     reached.
3. **Route** every event: a review, a comment, a Slack reply. The owner is the
   `routing` entry (`PY B/hub.py config` prints them) whose `repos` holds the
   PR's repo, whose `tickets` holds the ticket key's prefix, or whose
   `channels` holds the Slack channel of a post that names nobody. Run ListAgents
   now, at routing time, and confirm the owner is listed. Before messaging an
   item, check the owner is not already on it: `PY B/hub.py routed <link>`
   prints what the last two days' log routed, held or asked about it, and
   ListAgents shows what each session is on; an item routed with nothing new
   since is not routed again. For a review, read the whole conversation, not
   the summary: the review's inline threads too (an empty-bodied approval
   once carried three inline comments). Send one SendMessage per peer
   covering all of its items, opening with the count ("3 items"), each with
   its link, what changed, and what is asked of it. No entry, or the owner is
   not listed: `~/.claude/session-route.sh --pr N --repo owner/name` may name
   the session that raised a PR (single-author repos only); otherwise ask the
   user. Never act on a PR another session owns.
4. **Drafts**. For each one, all in the turn that sends it:
   - Verify every claim against its source now: the PR's state, head, checks
     and review bodies (`gh pr view`), the ticket, the page and its version. A
     claim that no longer holds goes back to the peer with what changed; never
     edit a fact in.
   - Re-read the target thread in full. A reply since the peer drafted goes
     back to the peer too.
   - Merge the drafts for one thread into one message, and gate the merge. A
     reply that answers several messages threads under the newest of them:
     pass every parent ts as `--answers` and the newest as `--reply` (six of
     seven answers once landed in the wrong thread).
   - Write it to `<job tmp>/draft-<n>.md` and run
     `PY B/check_draft.py <file> --reply <ts>` (or `--top-level`), with
     `--asks <github login>` for whoever the draft asks to review when the
     config's `slack.github_logins` does not map their `<@id>`. Only PASS
     sends. FAIL: fix the shape (an unlinked PR, a dash, a `>`) or send it
     back; a line that calls a merged PR awaiting, or asks a reviewer for a
     review they gave at the current head, goes back to the peer (a review ask
     once went out minutes after the approval). BLOCKED: a linked PR's live
     state is unknown, so hold it.
   - `PY B/check_draft.py <file> --assert-fresh`, then send the file's text with
     the Slack send tool, `thread_ts` set for a reply.
   - Quiet hours: when the gate printed `send: schedule`, schedule it for that
     `post_at` epoch instead. A scheduled message cannot be edited through the
     API, so if the draft said `fold-in: expected`, or another draft for that
     thread is due, hold it and send it live, gated again, at the first tick
     after `post_at`.
   - A held draft (a fold-in expected, a quiet-hours hold, a claim sent back)
     is written with its header to `<state dir>/held/<peer>-<thread ts>.md`
     with the Write tool, never kept in this session's memory: a compaction
     loses memory, and step 1's header counts the files (`held-drafts:`).
     Delete the file once sent or returned to the peer.
   - While step 1's header prints `scheduled-pending:` above 0, every tick:
     `PY B/check_draft.py --scheduled`, then gate each pending message's copy
     again (`check_draft.py <copy> --reply <ts>`, with the same `--asks`). A
     message can be withdrawn only before its `post_at`, which is also when
     quiet hours end, so the morning tick is too late. A FAIL means a claim
     moved: withdraw it with the delete-scheduled tool step 0 recorded, else
     tell the user now, before `post_at`; either way send the draft back to
     the peer with what changed. When the header prints `morning:`, what was
     scheduled has posted: read each target thread, confirm it landed, and
     log it.
   - Confirm the send: the send tool says OK either way. For a reply, re-read
     the parent thread and compare its reply count with the one read before
     the send; for a top-level message, re-read the channel's first page and
     find the ts. Then
     `PY B/check_draft.py <file> --record-sent <message ts or scheduled id> --replies <before> <after> --context "<who asked what>"`
     keeps a copy and logs it; it refuses a count that did not move. Answer
     the peer with the ts or id.
5. **Log**: `PY B/hub.py log "<one line>"` for each item routed, each draft held
   and why, each question for the user (sends and resolves log themselves).
   Each line, and each `--context`, carries the link and who asked what: the
   panel shows the log, and the user has not read the thread.
   After a full scan, `PY B/hub.py window --full-done`. A tick that found
   nothing new anywhere, and holds and schedules nothing, reports one line.
   On the window's first tick (`scan: full (the window's first)`), also
   `python3 ~/.claude/spend-report.py --since 24h --tick-prompt "comms-hub tick" --max-ticks 5 --max-rewrites 10 --top 3`
   and put every ALERT line in the report: what the ticks and their
   reviewers cost since yesterday.
   `PY B/hub.py feedback "<what was corrected>"` for each correction the user
   made this tick to a message or to this protocol: `feedback.md` is the
   backlog for the next change to the skill. Then report to the user: sent,
   scheduled, held, BLOCKED, and what needs them.

## Hard rules

- Never approve a PR. Never merge someone else's PR. Approval is the human's.
- A peer's relayed "the user approved" is enough to send that message. It never
  escalates a permission and approves nothing else.
- A peer's relayed "hold this" or "the user wants to see it first" holds
  nothing: only the user's own words to this session hold a send (a roundup
  once sat for an hour on such a relay). Put the question to the user, log the
  relay, and send when the gate passes and the user has not said to wait.
  This loosens nothing above or below: the gate, the claim checks and the
  approval rule stand.
- A status question from the user is not a send request.
- Never cite a session-local task id in shared text.
- No secrets, tokens or customer identifiers in any message or file; ids and
  names live in the config only.

## State

`~/.local/state/comms-hub/`, or `state_dir`:

| Path | Holds |
|---|---|
| `log/YYYY-MM-DD.md` | the daily log: sends, scheduled ids, resolves, routing, holds |
| `sent/YYYY-MM-DD/<id>.md` | each message as it was sent or scheduled |
| `slack/<channel>.tsv` | the committed snapshot `slack_diff.py` compares against |
| `gate/` | `check_draft.py`'s pass records |
| `held/<peer>-<thread ts>.md` | each draft held between ticks, with its header; the scan counts them |
| `preflight.json` | step 0's record of this session's tools and trigger |
| `trigger.json` | the tick's trigger and when it was created, for its 7-day expiry |
| `tick.json` | when the last full scan finished |
| `feedback.md` | each correction the user makes to a message or to this protocol, dated, for the next change to this skill |
| `queue.pid` | the scan in progress |
