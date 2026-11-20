# Design choices

Why the harness is built the way it is. Moved from the README.

- The guards keep what auto mode cannot see or should not judge: file reads it never classifies, commands an allow rule may pass before the classifier, and actions that cannot be undone. A hook sees the whole command and a permission rule sees a prefix or a space-wildcard pattern, so those checks live in the guards; native ask rules cover kubectl writes and secret reads, and the classifier judges the rest ([permissions.md](permissions.md)).
- Guards fail closed: no jq or unparsable input denies (`tests/fail-closed.test.sh`), and a crash or timeout blocks through `"onFailure": "block"` (Claude Code 2.1.295 and later). Inside `bash-guards`, a guard that dies is a deny naming it, and an early exit of the hook itself is made exit 2 (`tests/bash-guards.test.sh`).
- No `autoMode` block ships: setting a category appears to replace Claude Code's own rules for it, 72 `soft_deny` rules by `claude auto-mode defaults` on 2.1.325 ([auto-mode.md](auto-mode.md)).
- Every deny and ask is an audit line; MCP calls are logged, not guarded ([hooks.md](hooks.md)).
- The memory tools propose and never delete ([memory.md](memory.md)), and what it relies on in Claude Code is checked daily for breakage ([upstream-contract.md](upstream-contract.md)).
- Sessions kept for days restart from a short handoff rather than resuming a transcript that only grows; the harness measures transcripts, nudges at session start and caps its own backups ([long-running-sessions.md](long-running-sessions.md)).
