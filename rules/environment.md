# This machine and this setup

## Git

- Force-push and `git reset` are blocked here by a hook. After a bad amend,
  recover with `git checkout -` or by re-applying, never by resetting.
- `git worktree add -b` sets the new branch's upstream to origin/main, so a bare
  `git push` targets main. Always push with an explicit branch.
- A merge conflict spanning every line of a file is a line-ending flip, not a
  content conflict.

## Claude Code

- Never root a long-running background job inside `.claude/worktrees/`.
- Temporary files go in the session's own job tmp directory, never `/tmp`, which
  parallel jobs share.
- A Bash permission rule matches a prefix and fails closed past a leading
  `VAR=value` assignment, so the same command can be allowed bare and denied with
  an env prefix.
- Shared tooling is shared: before "fixing" a skill, check whether the problem is
  local configuration. *"I don't want to fix the skill if it works for others. The
  skills are for everyone."*
