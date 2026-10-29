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
kind: reply | react
claims:
- <each fact the message states> | <its source: PR URL, ticket key, page URL and version>
user-approved: <the user's words, quoted> | no
fold-in: expected | none
---
<the message, exactly as it should go out; nothing for react>
```

`kind: react` acknowledges a request GitHub already answers, such as a review
request your posted review covers: no message, and `to:` names the request's
ts as for a reply. The review on GitHub is the answer; Slack carries only what
GitHub can't (a decision, merge order, a hold, a question not on the PR, a
review not posted yet). `fold-in: expected` means more is coming for the same
thread (a CI run, an answer you are waiting on). The comms session replies with
the sent ts, the scheduled id, the reaction, or why it held the draft.

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
   (`claude --settings '…'`): a 600k-token compact window and a 2-minute MCP
   timeout for this session only. A compaction leaves the system prompt,
   tools, rules and memory behind: 77-94k tokens on one machine, so a 150k
   window compacted ten times a day. `PY B/hub.py config` prints what the
   latest compaction left and warns when the window leaves under 100k to work
   in; `launch --check` fails a session started with any other window, so
   restart one started before the change. Exported in
   the shell instead, the window loses to the one `~/.claude/settings.json`
   sets. The command also loads the panel (`panel/`, `--plugin-dir`): a pane
   with what needs the user, where their PRs stand (per repo, from the last
   scan, with its age), what goes out and when, what is with other sessions,
   what is held, reviewed, approved and merged over the last five active days,
   and the day's events with a dot on each since the user last looked, from
   `PY B/hub.py panel` as each turn ends, so it costs no tokens (`/comms`
   opens it again and counts as a look). In expanded view (`e` with the pane
   focused, or a `+k more` button) it shows every row and each message whole.
   The phone app docks no pane: there `/comms` answers with the same state as
   text, and while a phone is attached the counts ride the status line.
   Keep the machine awake through active
   hours: one that slept ran no tick until 09:55, so nothing re-gated the
   messages scheduled for 08:30, and it woke to a lost login and a DNS
   failure. On macOS, on power: `sudo pmset -c sleep 0`. `caffeinate -is` in
   front of a command keeps the machine awake only while that command runs,
   so it serves a session launched in the foreground; a background launch
   returns at once, so use `caffeinate -is -w <the session's pid>` there.
   Then step 0 below, then the
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
schedule message tools, and its add-reaction tool if it has one; ListAgents;
SendMessage; CronList, for the tick's trigger; optionally PushNotification and
a Jira or Confluence tool. Then write
`<state dir>/preflight.json` with the Write tool (`PY B/hub.py config` prints
the state dir, the tmp dir, the Slack ids and the routes):

```json
{"checked_at": "2026-10-21T17:00:00Z",
 "slack_read_channel": "<tool name>", "slack_read_thread": "<tool name>",
 "slack_search": "<tool name>", "slack_send": "<tool name>", "slack_schedule": "<tool name>",
 "list_agents": "ListAgents", "send_message": "SendMessage",
 "trigger": "<the tick's cron expression, from CronList>", "tickets": "<tool name, or empty>",
 "slack_delete_scheduled": "<tool name, or empty>", "slack_react": "<tool name, or empty>",
 "push_notification": "<tool name, or empty>"}
```

Leave a key empty when its tool is missing, and tell the user: doctor fails on
it, and the tick cannot run without it. Then `PY B/hub.py launch --check`: a
failure means this session was not started with `hub.py launch`'s command, so
tell the user to restart it with that command. `slack_delete_scheduled`,
`slack_react`, `push_notification` and `tickets` are optional: without the
first, a scheduled message whose claims moved can only be reported, not
withdrawn; without `slack_react`, a draft that should go as a reaction is
held, and the user told; without `push_notification`, the report alone carries
the reviews to approve.

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
`PY B/hub.py log --kind tick "ended: <why>"` and end the tick. Never retry inside the
tick: the next fire is the retry, and every call re-reads this session's
whole context.

0. **A scan still running** from an earlier tick is killed by the next
   `queue.py scan`, which says so. A scan that slept with the laptop ends
   BLOCKED on its wall-clock watchdog: report it, do not retry in a loop.
1. **GitHub**: `PY B/queue.py scan`. Read INBOUND, REVIEWED, WATCHED, AWAITING,
   OUTBOUND, ROUTE, DRIFT and UNKNOWN, and the header's `search-quota` and
   `my-open-xcheck`. If it prints BLOCKED, the queue is unknown, not empty: say
   so, with the reason, and never present the sections as complete.
   - REVIEWED is anyone's open PR whose head moved since my last review: a
     re-look for step 1c, with the `compare` range. Four PRs once got commits
     after my reviews and only the closing report noticed.
   - ROUTE is each item on my PRs that asks something: a `[consider]`,
     `[question]` or `[blocking]` tag, a question, or changes requested, an
     approval's body and inline threads included (an approval carrying a
     `[consider]` was once logged as status and routed nothing until the user
     asked twice). A bare approval or "LGTM" is not in it. Route each at step 3.
   - The scan logs the tick's GitHub work before you start it, a `todo` row per
     ROUTE item and per review or re-look (`logged:`), so a compaction mid-tick
     resumes from disk: `in-flight:` lists what an earlier tick left, each with
     its id, what it is and its link. Finish each. The scan closes a todo once
     GitHub shows it done.
   - `morning-unchecked:` above 0 names scheduled messages that posted with no
     re-gate since the window opened (the machine slept): re-check each claim
     now and tell the user what moved. The scan logged each under Needs you.
   - `prs:` says whether the panel's PR file was written; a BLOCKED scan keeps
     the last one, which the panel shows with its age.
   - `parked:` names the PRs the user parked. When the user asks to drop a PR
     from the panel: `PY B/hub.py park owner/repo#N "<why>"`. It leaves the
     panel and REVIEWED, WATCHED, AWAITING and DRIFT from the next scan on;
     INBOUND, OUTBOUND and ROUTE still show it, since each asks something new.
     `PY B/hub.py unpark owner/repo#N` brings it back, and `PY B/hub.py park`
     lists them. Never filter the PR file after a scan: it flashes back.
   1b. `PY B/resolve_threads.py` (a dry run); read every RESOLVE and SKIP. Then
   `PY B/resolve_threads.py --apply`. It re-reads each thread, prints what
   GitHub reports, and logs what was resolved.
   1c. **Reviews**, for each INBOUND PR and each REVIEWED re-look: first
   `PY B/hub.py window --review`. Exit 1 means the window closes before a
   review could finish with someone there to read it, and a subagent left
   running while the laptop sleeps re-writes its whole cache on every wake:
   log `review of <PR> waits for the next window` and spawn nothing. The PR
   stays in its section, so a later tick reviews it. Otherwise
   `PY B/pr_transcript.py owner/repo#N -o <job tmp>/pr-N.md` (it prints
   `head:` and `review-cap:`), then spawn a reviewer with the Agent tool: the
   pr-review skill, the transcript, the diff, and the ask to write
   `<job tmp>/review-N.json` and hand back at most 5 lines, since the findings
   stay in the file, not in this session's context:

   ```json
   {"head": "<the head: line, all 40 characters>", "body": "<findings only, no verdict>",
    "comments": [{"path": "src/a.py", "line": 3, "side": "RIGHT", "body": "<one finding>"}],
    "findings": [{"kind": "nit"}, {"kind": "question"}], "escalate": "<why the user must read it; leave out if nothing>"}
   ```

   One `findings` entry per finding, its kind `nit`, `consider`, `question` or
   `blocking`. The body and each comment at most the `review-cap:` characters
   (3 of 9 bodies once ran over and were trimmed by hand), leaving out what
   another reviewer already raised (the transcript has every review and
   thread). For an INBOUND PR the diff is `gh pr diff N --repo owner/repo`.
   For a re-look it is the REVIEWED line's range,
   `gh api repos/owner/repo/compare/<my sha>...<head>`, read against my own
   open threads in the transcript: each fixed, not fixed, or a new issue. A
   re-look with every thread fixed and nothing new has no findings. A 404 means
   a force-push dropped my sha: review the whole diff instead. Then
   `PY B/review_lint.py --post <job tmp>/review-N.json --pr owner/repo#N`. It
   lints the body and each comment, re-reads the head and the open state,
   posts through the reviews API with the inline comments, and logs the review
   under Needs you with its verdict (`logged <id>: reviewed <verdict>`):
   approvable when every finding is a nit or a consider and nothing is
   escalated, else needs your read. It closes the review's todo. Exit 1 is a
   refusal, and the output says whether the file or the PR is the problem: fix
   the file and run it again, but a moved head means review again, and a
   closed or draft PR means no review. Exit 3: nothing posted or logged, so the
   review is still to do. Never `gh pr review` by hand: it drops the inline comments,
   and a lint chained with `;` once let a refused body go out. COMMENT only:
   this session never approves or requests changes, whatever the findings say.
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
     thread. Send each printed line whole as the search's query text (the
     Slack MCP's `natural_language_query`), never in a filters field: a bare
     `<@my_user_id>` sent as a filter ran an empty search, which came back
     headed `Search Results for:` with nothing after it and listed the
     workspace's newest posts, alerts and webhooks, none naming the user.
     Rows prove the search returned something, not that it ran as asked:
     check that the result's header names the query, and that every hit of
     the bare search holds `<@my_user_id>`. Either one missing means mentions
     are unknown. Use the date filter: an epoch filter once returned 0, and an
     empty result is ambiguous. An empty search counts as quiet only when the
     same query from `PY B/hub.py queries --control` (a week further back)
     returns rows; ask for the smallest page, since one row proves it. Empty
     too, the search is not working, so say mentions are unknown, never quiet. The newest hit of each shows how far it
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
   - `send: react <emoji> on <ts>`, with a FAIL: every line restates your own
     review, which GitHub already shows (a reviewer asked for approvals to stay
     out of Slack). Never reply: add that reaction to each ts with the
     `slack_react` tool, in quiet hours too, since a reaction is not a message;
     log it (`PY B/hub.py log --kind reacted --ref <PR link> --target <channel id> "review on GitHub"`),
     and tell the peer. No `slack_react` tool: hold the draft and tell the user.
     A top-level draft has no ts: find the message that asked for each review
     (search Slack for the PR's link) and react there; with none in Slack, drop
     it, since GitHub already told the author. A `kind: react` draft skips the
     gate: confirm its claim (your review is on the PR at its head, or the PR
     merged after it), then react the same way. WARN names lines that restate
     inside a message that says more, or a thread reply over 60 words: it may
     send, and reads better cut to what GitHub can't say.
   - `PY B/check_draft.py <file> --assert-fresh`, then send the message with
     the Slack send tool, `thread_ts` set for a reply. A draft with its header
     is gated, and sent, as the message after the header's `---` alone.
   - Quiet hours: when the gate printed `send: schedule`, schedule it for that
     `post_at` epoch instead, which is on the next active day, after its first
     tick. A scheduled message cannot be edited through the
     API, so if the draft said `fold-in: expected`, or another draft for that
     thread is due, hold it and send it live, gated again, at the first tick
     after `post_at`.
   - A held draft (a fold-in expected, a quiet-hours hold, a claim sent back)
     is written with its header to `<state dir>/held/<peer>-<thread ts>.md`
     with the Write tool, never kept in this session's memory: a compaction
     loses memory, and step 1's header counts the files (`held-drafts:`).
     Add `reason: <why, in words>` to the header, and `needs: user` when it
     waits for the user's own go: the panel shows those under Needs you, the
     rest under Held. Delete the file once sent or returned to the peer.
   - While step 1's header prints `scheduled-pending:` above 0, every tick:
     `PY B/check_draft.py --scheduled`, then gate each pending message's copy
     again (`check_draft.py <copy> --reply <ts>`, with the same `--asks`). A
     message can be withdrawn only before its `post_at`; the config refuses a
     `post_at` at or before the first tick, so that tick is the last chance. A
     FAIL means a claim moved (the panel shows it): withdraw it with the
     delete-scheduled tool step 0 recorded, else tell the user now, before
     `post_at`, so they delete it in Slack; either way send the draft back to
     the peer with what changed. Once it is deleted, by you or the user,
     `PY B/check_draft.py --withdrawn <scheduled id> --context "<why>"`, so no
     tick gates it again. When the header prints `morning:`, what was
     scheduled has posted: read each target thread, confirm it landed (a
     reply: the thread's reply count moved since it was scheduled), and log
     `--kind sent` for each, or report one that did not land.
   - Confirm the send: the send tool says OK either way. For a reply, re-read
     the parent thread and compare its reply count with the one read before
     the send; for a top-level message, re-read the channel's first page and
     find the ts. Then
     `PY B/check_draft.py <file> --record-sent <message ts or scheduled id> --replies <before> <after> --context "<who asked what>"`
     keeps a copy and logs it; it refuses a count that did not move. A
     scheduled reply cannot move the count before it posts: record it without
     `--replies`, and with `--post-at HH:MM` when you scheduled it later than
     the gate's `post_at`. `--context` is the panel's text for it: 80
     characters, names in words. Answer the peer with the ts or id.
5. **Log**: one event per item, which the panel shows as one line:
   `PY B/hub.py log --kind <kind> [--ref <PR or ticket link>] [--target <channel id>] [--who <person or session>] [--detail "<the rest>"] "<what, in words>"`.
   The text is at most 80 characters with no ids, ts, hashes, links or time:
   the link is `--ref`, the channel `--target` (named from
   `slack.channel_names`), everything else `--detail`. Sends and resolves log
   themselves, as do the scan's `todo`, `done` and `blocked` rows and
   `review_lint.py --post`'s `reviewed`. Log each item routed
   (`--kind routed --who <session>`, with `--corrects <its todo id>` for a
   ROUTE item, so it moves from in-flight to with-sessions), each
   draft held and why (`--kind held`), each question for the user and each
   BLOCKED scan or unknown mention search (`--kind asked` or `--kind blocked`,
   with `--needs-user`). The command prints the row's id. An entry made after
   the fact passes `--at HH:MM`, never a time in the text. A row with
   `--corrects <id>` replaces that row in the panel: use it for a correction,
   for the user's answer to a question (`--kind answered`), and for a
   session's reply to an item routed to it (`--kind returned`). Step 1's
   header lists what is still open (`needs-you:`, `with-sessions:`). Before
   reporting a question as waiting on the user, read its thread for the user's
   own reply: the mention searches skip the user's messages, and a question
   answered at 17:40 was reported open three ticks running. Answered: log it
   with `--corrects` instead.
   After a full scan, `PY B/hub.py window --full-done`. A tick that found
   nothing new anywhere, and holds and schedules nothing, reports one line.
   On the window's first tick (`scan: full (the window's first)`), also
   `python3 ~/.claude/spend-report.py --since 24h --tick-prompt "comms-hub tick" --max-ticks 40 --max-rewrites 10 --top 3 --rewrite-hint "raise session.compact_window, then restart with hub.py launch"`
   and put every ALERT line in the report: what the ticks and their
   reviewers cost since yesterday. The limit is a day well above normal: 20
   ticks a day at the $1.36 to $1.42 a tick measured on 2026-10-28 and 10-29
   come to about $28, so $40 means something ran away (a compaction loop, a
   reviewer that would not stop), not that a day was busy.
   `PY B/hub.py feedback "<what was corrected>"` for each correction the user
   made this tick to a message or to this protocol: `feedback.md` is the
   backlog for the next change to the skill. Then report to the user, reviews
   first, unasked, in the tick each posts (the list of PRs to approve once came
   20 minutes after nine reviews, and only when the user asked): each review's
   link, its verdict and "read the comment and approve", approvable first.
   Reviews from earlier ticks that still wait on the user stay under
   `needs-you:`; one whose head has moved is a re-look, never approvable (two
   PRs were once called approvable after new commits). When step 0 recorded
   `push_notification`, a tick that posted an approvable review sends one
   notification naming those PRs: the user is often not watching this
   session. Then sent, scheduled, reacted, held, BLOCKED, and what else needs
   them. The user has not
   read the threads, so each item stands alone: its link, who asked what in
   one quoted line (20 words at most), and what went out or what is needed
   from them. The thread is already in this session's context, so that is a
   line per item, never a re-read.

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
| `log/YYYY-MM-DD.jsonl` | the day's events, one row each, which the panel draws |
| `log/YYYY-MM-DD.md` | the same events as lines to read: sends, scheduled ids, resolves, routing, holds |
| `sent/YYYY-MM-DD/<id>.md` | each message as it was sent or scheduled |
| `slack/<channel>.tsv` | the committed snapshot `slack_diff.py` compares against |
| `gate/` | `check_draft.py`'s pass records |
| `held/<peer>-<thread ts>.md` | each draft held between ticks, with its header; the scan counts them |
| `preflight.json` | step 0's record of this session's tools and trigger |
| `trigger.json` | the tick's trigger and when it was created, for its 7-day expiry |
| `tick.json` | when the last full scan finished |
| `last-scan` | when the last scan started, BLOCKED or not; the panel calls an older `prs.json` stale |
| `prs.json` | the last scan that did not end BLOCKED: each open PR I review or authored, which the panel's PRS section reads |
| `prs-history.jsonl` | what changed between two `prs.json`, one row each (reviewed, approved, merged, by day), for the panel's last five days |
| `parked.json` | the PRs the user parked with `hub.py park`, with when and why |
| `feedback.md` | each correction the user makes to a message or to this protocol, dated, for the next change to this skill |
| `queue.pid` | the scan in progress |
