# Reviews, PRs, handing work back

## Before replying to anyone

- Read the whole thread and PR conversation, not just the diff or last message.
- Re-read state that moves: current head, checks, and whether the ticket already
  answers what you were about to ask a person.

## Writing a review

- Shape: open on the sources actually read, not the diff. Bold lead-ins for what
  you chased down, each citing `file`:line. Asks numbered, ranked, non-blocking;
  "Nit:" for trivia; label what is inherited, not introduced. Close "Net: approving".
- An ask the diff cannot be edited to satisfy is a rollout note for the ticket.
- Never say tests or builds passed unless you ran them.
- Edit a review in place to keep APPROVED (`gh api -X PUT .../reviews/<id>`);
  trim rather than re-post.

## Answering a review

- Answer ON the PR. A pushed fix, an edited PR body, or a chat message does not
  answer a reviewer.
- A deferral needs both channels: its thread, and where the work is tracked now.
- Disagree with evidence and a conclusion, not with the question back.

## Requesting review

- Ready for review implies assigning the reviewer.
- One terse request for every open PR.
- Never escalate a PR as needing approval before reviewing it.
- Approval is Aditya's, always.

## Handing work back

- The handoff IS the deliverable: per item, the link, the verdict, and what he
  must do. Separate "approved, needs a merge" from "needs you to read and approve".
- Give facts and evidence; present the call, do not take it.
- Never hand over a path to a file I created. Give the command that produces it.
- Never cite a session-local task id in shared text.
