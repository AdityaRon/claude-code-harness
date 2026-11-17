# This machine

- Never `git reset`. After a bad amend, re-apply.
- Push with an explicit branch.
- A conflict spanning every line of a file is a line-ending flip, not content.
- Never root a long-running background job inside `.claude/worktrees/`.
- Temp files go in the session's own job tmp directory, never `/tmp`, which
  parallel jobs share.
- Delete large intermediate files from job tmp when a task ends
  (`python3 ~/.claude/disk-space.py prune` lists what is old and safe).
- A session removes a PR's clone, and its Bazel output base, once the PR merges or
  closes: `python3 ~/.claude/disk-space.py clone PATH` lists both, and its
  `--apply` deletes them. It keeps a linked worktree: `git worktree remove` that,
  and `disk-space.py bazel --sweep` lists its output base after. Not `rm -rf`.
- Write memory files with Write or Edit, never a shell redirect or heredoc: only the
  file tools get the CLI's `modified` stamp and memory-lint.
- An allow rule does not match past a leading `VAR=value` (a short safe list
  aside) and fails closed. Put the binary first, or set it in its own command.
- Before "fixing" shared tooling, check whether the problem is local config.
