# Shadow mode

Step 4 of [#237](https://github.com/AdityaRon/claude-code-harness/issues/237).
Some guards and rules may no longer be needed now that auto mode's classifier
runs on every action. For two weeks they run in shadow mode: each one still
works out what it would have decided, writes that down, and decides nothing.
The call goes on to the permission rules and the classifier as if the rule were
not there. Step 9, on or after 2026-11-29, reads the report below and retires
or restores each one.

## What is shadowed, and what covers it meanwhile

The list is `SHADOW` in [`hooks/lib/shadow.sh`](../hooks/lib/shadow.sh), one
entry a line. A guard's name covers every decision it makes; `guard:rule`
covers one rule.

| Entry | Cover while it is shadowed |
|---|---|
| `kubectl-guard` | #241 narrowed `Bash(kubectl:*)` to read verbs and added native ask rules for mutating verbs in both orders (`kubectl delete *`, `kubectl * delete *`). Anything else reaches the classifier. A `get secret` or `config view --raw` with the verb first matches a read prefix and has no ask rule, so the report is the only thing that sees it. |
| `interpreter-guard` | Auto mode drops interpreter allow wildcards such as `Bash(python3:*)`, so the classifier sees inline code. |
| `network-guard:` each ask | No allow rule covers curl, wget, scp, rsync or sftp, so the classifier sees each call. That includes `allowlist-edit`: while it is shadowed, a host added to the machine's allowlist also hides later asks from this log. |
| `rm-guard:rf-outside-scratch` | `rm` has no allow rule, so the classifier sees it. |
| `env-guard:bare-env` | `env` has no allow rule, so the classifier sees it. |

These stay live:

- every network-guard deny (curl or wget into a shell, file uploads);
- rm-guard's denies on catastrophic targets (`/`, `~`, `.`, a top-level folder);
- every other env-guard deny (`printenv`, `export -p`, reading `.env`, `nc`, …);
- git-guard's broad `git add` deny. `Bash(git add:*)` is allowed, so nothing
  else would read the call;
- every fail-closed deny: a payload that does not parse, no jq, a guard that dies;
- the floor that turns an unreadable command into an ask, in rm-guard and env-guard;
- every guard not named above.

A shadowed hit does not end its guard. The guard goes on as if the rule were
not there, so `rm -rf build; rm -rf ~` still denies on `~`.

`~/.claude/hooks/bash-guards.skip` still wins: a skipped guard does not run,
so it writes nothing to the log either.

## The log

`~/.claude/logs/shadow.log` (`CLAUDE_SHADOW_LOG`) gets one JSON line for each
guard on each call, written for the first hit only:

```json
{"ts":"…","session_id":"…","tool_use_id":"toolu_…","permission_mode":"auto",
 "guard":"kubectl-guard","rule":"mutating-verb","reason":"…","would":"ask",
 "tool":"Bash","command":"kubectl delete pod web"}
```

The command and reason are cleaned as `audit.sh` cleans a field: one line, no
control bytes, at most 200 characters for the command and 300 for the reason,
with secrets redacted. The file is created with mode 0600. A shadowed hit
writes no `GUARD` line to the audit log, so `tools/permission-friction.py` does
not count it as a prompt. A run on the command's joined lines, or on an inline
script's shell-out, reports its hit to the outer run, which writes the line.

PreToolUse payloads carry `tool_use_id` and `permission_mode`. A headless probe
on Claude Code 2.1.325 recorded both. The PermissionDenied payload carries them
too, by the hooks doc, so `audit.sh` now writes them into each denial:

```
<ts> | DENIED | <tool> | id=<tool_use_id> mode=<permission mode> | <command, ws URL or path> | <reason> | <dir>
```

The reason is read from `reason`, the documented field. Before this change,
`denial_reason` was read, and every live denial line said `no reason given`.

## The report

```bash
python3 tools/shadow-report.py --days 14
```

It joins the log on `tool_use_id` to three sources: the denials in the audit
log, the Bash guards' timing log, and how each call's permission resolved in
the transcripts. It then prints one row per guard and rule, followed by the
`tool_use_id`s for each outcome. It never prints a command or a reason.

Each decision lands in exactly one outcome column, so the outcome columns of a
row add up to its asks plus denies:

| Column | Meaning |
|---|---|
| Classifier denied | Auto mode refused it, with a verdict (`[Category]`). |
| Denied, no verdict | Auto mode refused it without judging it (no verdict, or the classifier was unavailable). |
| Prompt approved, Prompt rejected | Claude Code asked a human through a native ask rule or a built-in check, and this was the answer. |
| Native deny | A deny rule or a built-in check refused it. |
| Live guard | A guard that is still live asked or denied the same call. |
| Ran: allow rule | An allow rule let it run, so neither the classifier nor a person saw it. |
| Ran: classifier | The classifier saw it and let it run. |
| Ran: other | The permission mode let it run, or the transcript does not record how. |
| No outcome | The window holds no transcript result for it. |
| No id | Its payload had no `tool_use_id`. |

"Not in auto mode" counts the decisions made while no classifier was running,
whatever happened next.

## How step 9 reads it

For each row:

- **Covered:** classifier denied, a native prompt or deny, or a live guard. If
  every decision is in these columns, delete the rule, or the whole guard, with
  its tests and its line in `SHADOW`.
- **Look at the ids:** Ran: classifier. The classifier saw the call and allowed
  it. For a rule that would have denied, read those calls before retiring it.
- **Not covered:** Ran: allow rule, Ran: other, Denied, no verdict, and any
  decision made outside auto mode. Restore the rule, which means deleting its
  line in `SHADOW`, or add a native rule that covers those calls first.
- **Unknown:** No outcome, No id. Find the call before counting it either way.

A row with no decisions in two weeks says nothing about cover. It only shows
that the rule never fired.
