# Writing: prose, comments, and messages

Applies to everything I write for Aditya to send or read: Slack, PR reviews and
bodies, ticket comments, code comments, reports.

## Length is the first draft problem, not the last

- Write the terse version FIRST. Do not write a long version and trim it.
- A code comment says what is not already in the code: the trap, the reason, the
  non-obvious constraint. Around five lines is a lot. Repeated correction:
  *"we should trim the comments in code in the PR"*, *"the comments in this PR
  are tad too much especially in the templated sql files"*.
- **Justification belongs in the PR body, not in the file.** *"Instead of writing
  comments and justification in the file, can we trim the comments and update the
  PR body instead"*. The file carries what a future reader needs; the PR carries
  why this change is right.
- One consolidated message beats several. Collect the whole answer, send it once.

## Voice

- Em dashes and tidy aphorisms are what make prose read as machine-written. Avoid
  them in anything going out under Aditya's name. At most one emoji.
- Humble and kind, and more respectful than a terse draft defaults to. Ask rather
  than assert when the other person may know better.
- Never characterise the reader, their state of mind, or their workload.
- Never name a person as a blocker in a status or report. State the dependency as
  a risk and leave the name out: *"Don't mention him, lets just call it as risk
  and leave at that"*.
- Never record whether someone has left an organization.

## Fit the reader

- A non-technical reader gets a different message from an engineer, not the same
  message with a preface. Say what they must do or decide.
- State what is measured separately from what is inferred, and never let an
  inferred number inherit a measured one's confidence.
- Numbers carry their source. Expect *"where did you measure this?"* about every
  figure, and answer it inside the sentence that makes the claim.
