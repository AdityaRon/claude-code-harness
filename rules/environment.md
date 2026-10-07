# This machine

- Force-push and `git reset` are blocked by a hook. After a bad amend, recover
  with `git checkout -` or by re-applying. Never reset.
- `git worktree add -b` sets upstream to origin/main, so a bare `git push` targets
  main. Push with an explicit branch.
- A conflict spanning every line of a file is a line-ending flip, not content.
- Never root a long-running background job inside `.claude/worktrees/`.
- Temp files go in the session's own job tmp directory, never `/tmp`, which
  parallel jobs share. Under the sandbox, Bash cannot write there (Claude Code
  keeps `~/.claude` read-only to commands): Bash-written files go in
  `$TMPDIR/<job id>`, and the Write tool can still use the job directory.
- Claude Code refuses `sleep N` followed by a command. To wait, run an
  until-loop with `run_in_background`, or use Monitor.
- A Bash permission rule matches a prefix and fails closed past a leading
  `VAR=value`, so one command can be allowed bare and denied with an env prefix.
  Put the binary first. Inline the value, or set it in its own command.
- Before "fixing" shared tooling, check whether the problem is local config.
