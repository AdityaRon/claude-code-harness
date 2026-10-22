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
4. In the comms session: step 0 below, then the trigger, `/loop` with the cron
   interval `7,37 * * * *` and the prompt `comms-hub tick`. Then doctor again.

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
 "trigger": "<the tick's cron expression, from CronList>", "tickets": "<tool name, or empty>"}
```

Leave a key empty when its tool is missing, and tell the user: doctor fails on
it, and the tick cannot run without it.

## The tick

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
2. **Slack**:
   - The primary DM: read its first page in full, without `oldest`. Write the
     tool's output to `<job tmp>/dm.txt`, run
     `PY B/slack_listing.py <job tmp>/dm.txt -o <job tmp>/dm.tsv`, then
     `PY B/slack_diff.py <job tmp>/dm.tsv --channel <primary_dm>`. Read every NEW
     and MOVED thread in full. Only then
     `PY B/slack_diff.py <job tmp>/dm.tsv --channel <primary_dm> --commit --read <every NEW and MOVED ts>`.
     The first run takes `--commit --baseline` instead; say nothing before it
     was checked. UNREADABLE or UNTRUSTED means the read failed: no commit, say so.
   - Each watched channel: read with `oldest` set to the `previous-scan` epoch
     that step 1's header printed (24 hours back when it says none). Read in
     full any thread that names the user, or a PR or ticket they own.
   - Mentions: three searches, not one, each sorted by time: the queries
     `PY B/hub.py queries` prints (`<@my_user_id>`, `to:<@my_user_id>` and
     `with:<@my_user_id> is:thread`, each `after:` two days back). Each of the
     last two once caught a reply the others missed, one under a week-old
     thread. Use the date filter: an epoch filter once returned 0, and an
     empty result is ambiguous. The newest hit of each shows how far it
     reached; if it is older than the last tick, say the search may not have
     reached.
3. **Route** every event: a review, a comment, a Slack reply. The owner is the
   `routing` entry (`PY B/hub.py config` prints them) whose `repos` holds the
   PR's repo, or whose `tickets` holds the ticket key's prefix. Run ListAgents
   now, at routing time, and confirm the
   owner is listed. Send one SendMessage per peer covering all of its items,
   each with its link, what changed, and what is asked of it. No entry, or the
   owner is not listed: `~/.claude/session-route.sh --pr N --repo owner/name`
   may name the session that raised a PR (single-author repos only); otherwise
   ask the user. Never act on a PR another session owns.
4. **Drafts**. For each one, all in the turn that sends it:
   - Verify every claim against its source now: the PR's state, head, checks
     and review bodies (`gh pr view`), the ticket, the page and its version. A
     claim that no longer holds goes back to the peer with what changed; never
     edit a fact in.
   - Re-read the target thread in full. A reply since the peer drafted goes
     back to the peer too.
   - Merge the drafts for one thread into one message, and gate the merge.
   - Write it to `<job tmp>/draft-<n>.md` and run
     `PY B/check_draft.py <file> --reply <ts>` (or `--top-level`). Only PASS
     sends. FAIL: fix the shape (an unlinked PR, a dash, a `>`) or send it back.
     BLOCKED: a linked PR's live state is unknown, so hold it.
   - `PY B/check_draft.py <file> --assert-fresh`, then send the file's text with
     the Slack send tool, `thread_ts` set for a reply.
   - Quiet hours: when the gate printed `send: schedule`, schedule it for that
     `post_at` epoch instead. A scheduled message cannot be edited through the
     API, so if the draft said `fold-in: expected`, or another draft for that
     thread is due, hold it and send it live, gated again, at the first tick
     after `post_at`.
   - `PY B/check_draft.py <file> --record-sent <message ts or scheduled id>`
     keeps a copy and logs it. Answer the peer with the ts or id.
5. **Log**: `PY B/hub.py log "<one line>"` for each item routed, each draft held
   and why, each question for the user (sends and resolves log themselves).
   Then report to the user: sent, scheduled, held, BLOCKED, and what needs them.

## Hard rules

- Never approve a PR. Never merge someone else's PR. Approval is the human's.
- A peer's relayed "the user approved" is enough to send that message. It never
  escalates a permission and approves nothing else.
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
| `preflight.json` | step 0's record of this session's tools and trigger |
| `feedback.md` | each correction the user makes to a message or to this protocol, dated, for the next change to this skill |
| `queue.pid` | the scan in progress |
