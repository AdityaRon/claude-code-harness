# This machine

- Never `git reset`. After a bad amend, re-apply.
- Push with an explicit branch.
- A conflict spanning every line of a file is a line-ending flip, not content.
- Never root a long-running background job inside `.claude/worktrees/`.
- Temp files go in the session's own job tmp directory, never `/tmp`, which
  parallel jobs share.
- Write memory files with Write or Edit, never a shell redirect or heredoc: only the
  file tools get the CLI's `modified` stamp and memory-lint.
- An allow rule does not match past a leading `VAR=value` (a short safe list
  aside) and fails closed. Put the binary first, or set it in its own command.
- Before "fixing" shared tooling, check whether the problem is local config.
