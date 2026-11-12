---
name: slack-draft
description: How a session that is not the comms session sends Slack. Use when about to send, answer, schedule or react to a Slack message from any session other than the comms session; the draft goes to the comms session, which checks and sends it.
---

# slack-draft: hand a Slack message to the comms session

One long-lived session, the comms session, is the only one that sends Slack
messages (the comms-hub skill is its tick). Do not send, schedule or edit a
Slack message yourself. Send the comms session (find it with ListAgents; ask the
user if none is clearly it) one message for all the drafts you hold:

```
comms-hub draft
to: <channel id> reply <thread ts>      (or: to: <channel id> top-level)
from: <your session's name, as ListAgents lists it>
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
the sent ts, the scheduled id, the reaction, or why it held the draft. Once it
sends, you own that thread's replies for two weeks: the comms session routes
each one back to you.
