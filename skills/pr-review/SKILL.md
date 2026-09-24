---
name: pr-review
description: How to write a PR review, answer review comments, and request review. Use when reviewing a pull request, replying to a reviewer or review thread, deferring a review ask, or asking someone to review.
---

# Reviews and review threads

## Writing a review

- The repo's own review rules win. If the target repo records a review format
  (for example `.claude/rules/pr-and-review.md`), read it from `origin/main` and
  follow it; a session launched outside the repo never auto-loads it. The shape
  below is the fallback for a repo with none.
- Shape: open on the sources actually read, not the diff. Bold lead-ins for what
  you chased down, each citing `file`:line. Asks numbered, ranked, non-blocking;
  "Nit:" for trivia; label what is inherited, not introduced. Close "Net: approving".
- An ask the diff cannot be edited to satisfy is a rollout note for the ticket.
- Edit a review in place to keep APPROVED (`gh api -X PUT .../reviews/<id>`);
  trim rather than re-post. A review submitted with an empty body cannot be
  edited, so post the review before any bodiless approval.

## Answering a review

- Answer ON the PR. A pushed fix, an edited PR body, or a chat message does not
  answer a reviewer.
- A deferral needs both channels: its thread, and where the work is tracked now.
- Disagree with evidence and a conclusion, not with the question back.

## Requesting review

- Ready for review implies assigning the reviewer.
- One terse request for every open PR.
- Never escalate a PR as needing approval before reviewing it.
