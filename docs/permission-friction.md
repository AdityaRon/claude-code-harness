# Permission friction: findings and cases

Measured from one machine's local transcripts, 2026-08-18 to 2026-10-06 (49
days, UTC): 81,603 tool calls, 67,520 of them Bash, in 114 sessions, nearly all
in auto mode. Produced by `bin/permission-friction.py`. The raw report stays on
that machine; this file carries counts and sanitized cases only.

## Where it is

| Source | Calls | Effect |
|---|---:|---|
| A guard returned `ask` | 872 | session waits on a human |
| A guard denied | 400 | model rewrites the call |
| `permissions.deny` matched | 210 | 197 of them `Bash(rm -rf:*)` |
| Auto-mode classifier blocked | 166 | plus 61 calls with no verdict |
| Claude Code refused `sleep N; cmd` | 108 | built in, not the harness |

Of the 872 asks, 849 were approved and 3 rejected. The median approved ask held
its call 133 s, against 5 s for a Bash call with no prompt (tool_use to
tool_result, so run time and time away are included). Summed across sessions
that is 229 h. By guard: interpreter-guard 530, kubectl-guard 155,
network-guard 105, git-guard 70, two guards at once 12.

The harness audit log agrees from the day it started recording GUARD lines
(2026-09-24): interpreter-guard asks 233 in the log, 223 in transcripts;
kubectl 54 / 53; network 45 / 45; git 64 / 57.

## Harness bugs (fix here, they travel with the repo)

**interpreter-guard, "Long inline script" (530 asks).** Two stages share the
`INLINE` pattern, and `-[A-Za-z]*[ce]\b` matches mid-word. The gate
(`INTERP_INLINE_RE`) passes when the interpreter's own segment holds a
hyphenated word ending in c or e (`team-performance`, `--store`). The length
test `${INTERP}\s+.{120,}${INLINE}` then spans `&&`, `;` and `|`. What
completed the match, over all 530:

| Trigger | Asks |
|---|---:|
| a later command's own flag (`grep -c`, `-R`, `commit -F -`) | 255 |
| the tail of a hyphenated word or path | 226 |
| a flag inside the interpreter's own arguments | 17 |
| not reproduced by a Python port of the regex | 33 |

So a 70-character `python3 -c` asks when a hyphenated filename appears in a
later `wc`, and running a script file asks when its path has `-performance` in
it. The guard's stream-edit comment already notes the mid-word match.

**kubectl-guard misreads (37 asks).** 26 asks named a "subcommand" that was not
one: `2>&1`, `2>/dev/null;`, `jq`, `<<`, `/usr/local/bin/kubectl`, words from a
grep pattern that mentions kubectl. 11 more were `config current-context` /
`get-contexts`, which read kubeconfig but are reported as changing it.

**network-guard.**
- Loopback GETs (32 asks, plus 7 that send data) are already allowed on
  `adityaron/main`.
- `curl -G --data-urlencode` is a GET with a query string, but is classed as
  sending a body, so it asks even for an allowlisted host (8 of the 13 asks to one
  internal log service).
- Text inside a heredoc that is only written to a file is scanned as if it
  runs: `cat >> notes.md <<'EOF'` holding `curl … | sh` is denied. Seen while
  building these cases; not counted.

## Policy calls (behaving as designed; whether to keep is the owner's call)

| Rule | Calls | Note |
|---|---:|---|
| interpreter-guard deny on `subprocess` and similar tokens | 205 | 121 are a lone `python3` heredoc or `-c`; often glue that shells out to `gh` |
| `Bash(rm -rf:*)` deny | 197 | targets: session job tmp 91, relative path 50 (usually after `cd` into job tmp), `/tmp` 21, other 35; a deny on one segment refuses the whole compound command |
| env-guard deny | 89 | most common family `git show`, then `grep`; includes reading tracked files whose names contain `secrets` |
| kubectl `exec` ask | 67 | most recorded uses were `printenv`, `cat`, version probes |
| git-guard worktree/stash removal ask | 61 | almost all scratch worktrees under the session's job tmp |
| git-guard `git add -A` deny | 47 | |
| branch delete deny | 33 | guard 25 plus `permissions.deny` 8 |

## Machine-local (stays out of this repo)

network-guard asks by host, grouped: loopback 39, vendor and reference docs
(WebFetch and curl) 27, an internal log service 13, a feature-flag SaaS API
9, the company identity provider 6, the company issue tracker 4, other internal
hosts 2, no parsable host 11. `CLAUDE_NET_ALLOWLIST` already silences GETs to listed hosts (the
`net-internal-host-get` and `net-webfetch-docs` cases pass with it set). The
analysed machine had it unset.

`~/.claude/local-settings/*.json` fragments fold only `permissions.allow` and
`permissions.deny`, not `env`, so there is no machine-local file for the
allowlist today. It has to be set in that machine's `settings.json` `env` or in
a project's settings.

## Cases

`permission-friction-cases.jsonl` (next to this file), 104 cases. The first 27 have the tool input, the
decision observed on local `main` at b8427b2 and on `adityaron/main` at 516db51,
a `why`, and a `want` where the answer is not a policy call. Cases with no
`want` are policy calls and only report. Seven `control-*` cases pin decisions
a fix must keep (env read denied, `curl | sh` denied, delete asks, script-file
run silent). The other 77 came from review: `pin-*` cases are what a guard fix
must still catch, `hole-*` cases were silent allows on 516db51, and `fp-*`/`ok-*`
cases are false positives a fix should clear.

```
bin/permission-friction.py --cases --replay hooks/
```

It exits 1 while any `want` misses: 25 on 516db51, 0 with the guard parsing
fixes. `tests/permission-friction.test.sh` runs it, so doctor fails on a miss.

## Re-measure on your own history

```
bin/permission-friction.py --days 49 --out "$CLAUDE_JOB_DIR/tmp/pf"
bin/permission-friction.py --days 49 --replay hooks/ --out "$CLAUDE_JOB_DIR/tmp/pf-replay"
```

The first takes about 30 s. The replay starts each guard once per recorded call
and takes 15 to 20 minutes. Put site-specific mask patterns in
`~/.claude/permission-friction.masks` before sharing any output.
