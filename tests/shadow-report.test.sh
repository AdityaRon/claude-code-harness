#!/usr/bin/env bash
# Tests for tools/shadow-report.py on a fixture: each shadowed decision lands in
# one outcome, the rows add up, the window and duplicates hold, and no command
# or reason text reaches the report.
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
# shellcheck source-path=SCRIPTDIR source=lib.sh
source tests/lib.sh || exit 1
command -v python3 >/dev/null || { echo "  SKIP: no python3"; exit 0; }
export HOME="$TMP/home" CLAUDE_AUDIT_LOG="$TMP/home/.claude/logs/audit.log" CLAUDE_SHADOW_LOG="$TMP/home/.claude/logs/shadow.log"
export CLAUDE_GUARD_TIMING_LOG="$TMP/home/.claude/logs/guard-timing.log"
mkdir -p "$HOME/.claude/logs" "$HOME/.claude/projects/p"

# Every command and reason holds SECRETCMD, which must not reach the report.
python3 - "$HOME" <<'PY'
import datetime as dt, json, os, sys
home = sys.argv[1]
logs, proj = os.path.join(home, '.claude', 'logs'), os.path.join(home, '.claude', 'projects', 'p')
now = dt.datetime.now(dt.timezone.utc)
iso = lambda d: d.strftime('%Y-%m-%dT%H:%M:%SZ')
t, old = iso(now - dt.timedelta(hours=1)), iso(now - dt.timedelta(days=30))
def rec(uid, guard, rule, would, mode='auto', ts=t):
    return json.dumps(dict(ts=ts, session_id='s1', tool_use_id=uid, permission_mode=mode, guard=guard, rule=rule,
                           reason='would stop SECRETCMD', would=would, tool='Bash', command='SECRETCMD ' + uid))
lines = [
    rec('toolu_k1', 'kubectl-guard', 'mutating-verb', 'ask'),         # classifier denied, with a verdict
    rec('toolu_k1', 'kubectl-guard', 'mutating-verb', 'ask'),         # the same call again: counted once
    rec('toolu_k1', 'network-guard', 'host-unlisted', 'ask'),         # another guard on that call: its own row
    rec('toolu_k2', 'kubectl-guard', 'mutating-verb', 'ask'),         # a native ask rule, approved
    rec('toolu_k3', 'kubectl-guard', 'mutating-verb', 'ask'),         # a native ask rule, rejected
    rec('toolu_k4', 'kubectl-guard', 'secret-read', 'ask'),           # an allow rule let it run
    rec('toolu_i1', 'interpreter-guard', 'sensitive-token', 'ask'),   # the classifier let it run
    rec('toolu_i2', 'interpreter-guard', 'long-inline', 'ask', mode='default'),   # no classifier: the mode
    rec('toolu_r1', 'rm-guard', 'rf-outside-scratch', 'deny'),        # auto mode denied, no verdict
    rec('toolu_r2', 'rm-guard', 'rf-outside-scratch', 'deny'),        # a live guard denied it
    rec('toolu_e1', 'env-guard', 'bare-env', 'deny'),                 # no transcript result
    rec('', 'network-guard', 'host-unlisted', 'ask'),                 # no tool_use_id
    rec('toolu_n1', 'network-guard', 'sends-body', 'ask'),            # a deny rule
    # Transcript only, no permissionDecision: the kind alone says what happened.
    rec('toolu_c1', 'kubectl-guard', 'mutating-verb', 'ask'),         # auto mode blocked it, no audit line
    rec('toolu_c2', 'interpreter-guard', 'sensitive-token', 'ask'),   # a person rejected a prompt, reason unrecorded
    rec('toolu_c3', 'network-guard', 'sends-body', 'ask'),            # a deny rule
    rec('toolu_c4', 'rm-guard', 'rf-outside-scratch', 'deny'),        # a person approved a safety-check prompt
    rec('toolu_old', 'kubectl-guard', 'mutating-verb', 'ask', ts=old),   # outside --days
    'not json SECRETCMD',
]
open(os.path.join(logs, 'shadow.log'), 'w').write('\n'.join(lines) + '\n')
d = '/repo'
open(os.path.join(logs, 'audit.log'), 'w').write(''.join([
    f'{t} | Bash | SECRETCMD ls | {d}\n',
    f'{t} | DENIED | Bash | id=toolu_k1 mode=auto | SECRETCMD a | b | [Shared Cluster Mutation] | {d}\n',
    f'{t} | DENIED | Bash | id=toolu_r1 mode=auto | SECRETCMD x | Auto mode could not evaluate this action and is blocking it for safety | {d}\n',
    f'{old} | DENIED | Bash | id=toolu_e1 mode=auto | SECRETCMD old | [Irreversible Local Destruction] | {d}\n',
]))
open(os.path.join(logs, 'guard-timing.log'), 'w').write(
    'toolu_r2\tBash\tenv-guard=0.01:0:allow\trm-guard=0.02:0:deny\n'
    'toolu_k4\tBash\tenv-guard=0.01:0:allow\tkubectl-guard=0.02:0:allow\n')
out = []
def use(uid):
    out.append(json.dumps(dict(type='assistant', timestamp=t, sessionId='s1', cwd=d,
        message=dict(role='assistant', content=[dict(type='tool_use', id=uid, name='Bash', input=dict(command='SECRETCMD ' + uid))]))))
def result(uid, pd, err=False, kind=None):
    r = dict(type='user', timestamp=t, sessionId='s1',
             message=dict(role='user', content=[dict(type='tool_result', tool_use_id=uid, content='SECRETCMD out', is_error=err)]))
    if pd:
        r['permissionDecision'] = pd
    if kind:
        r['toolDenialKind'] = kind
    out.append(json.dumps(r))
for u in ('toolu_k1', 'toolu_k2', 'toolu_k3', 'toolu_k4', 'toolu_i1', 'toolu_i2', 'toolu_r1', 'toolu_r2', 'toolu_e1', 'toolu_n1',
          'toolu_c1', 'toolu_c2', 'toolu_c3', 'toolu_c4'):
    use(u)
result('toolu_k2', dict(decision='accept', source='user_temporary', grantScope='once', reasonCode='rule:userSettings'))
result('toolu_k3', dict(decision='reject', source='user_reject', reasonCode='rule:userSettings'), err=True, kind='user-rejected')
result('toolu_k4', dict(decision='accept', source='config', reasonType='rule', ruleSource='userSettings'))
result('toolu_i1', dict(decision='accept', source='config', reasonType='classifier'))
result('toolu_i2', dict(decision='accept', source='config', reasonType='mode'))
result('toolu_r2', dict(decision='reject', source='hook', reasonType='hook', reasonCode='hook:PreToolUse'), err=True)
result('toolu_n1', dict(decision='reject', source='config', ruleSource='userSettings', reasonCode='rule:userSettings'), err=True, kind='permission-rule')
result('toolu_c1', None, err=True, kind='automode-blocked')
result('toolu_c2', None, err=True, kind='user-rejected')
result('toolu_c3', None, err=True, kind='permission-rule')
result('toolu_c4', dict(decision='accept', source='user_temporary', grantScope='once', reasonCode='safetyCheck'))
open(os.path.join(proj, 's.jsonl'), 'w').write('\n'.join(out) + '\n')
PY

OUT=$(python3 -I tools/shadow-report.py --days 14 2>&1); RC=$?
[[ $RC == 0 ]] && pass "exit 0" || fail "exit" "rc=$RC $OUT"
row() {   # row GUARD RULE CELLS...: the table row, exactly
  local got; got=$(printf '%s\n' "$OUT" | grep -F "| $1 | $2 |")
  [[ "$got" == "| $1 | $2 | $(printf '%s | ' "${@:3}" | sed 's/ | $//') |" ]] && pass "$1 $2" || fail "$1 $2" "got: $got"
}
#                                           ask deny !auto  cls nov  r+ r- oth  nd  live  rule cls oth  none noid
row kubectl-guard     mutating-verb           4   0   0      2   0    1  1  0    0   0     0    0   0    0    0
row kubectl-guard     secret-read             1   0   0      0   0    0  0  0    0   0     1    0   0    0    0
row interpreter-guard sensitive-token         2   0   0      0   0    0  0  1    0   0     0    1   0    0    0
row interpreter-guard long-inline             1   0   1      0   0    0  0  0    0   0     0    0   1    0    0
row rm-guard          rf-outside-scratch      0   3   0      0   1    0  0  1    0   1     0    0   0    0    0
row env-guard         bare-env                0   1   0      0   0    0  0  0    0   0     0    0   0    1    0
row network-guard     host-unlisted           2   0   0      1   0    0  0  0    0   0     0    0   0    0    1
row network-guard     sends-body              2   0   0      0   0    0  0  0    2   0     0    0   0    0    0
TOTAL=$(printf '%s\n' "$OUT" | grep -F '| **all** |')
[[ "$TOTAL" == "| **all** | | 12 | 4 | 1 | 3 | 1 | 1 | 1 | 2 | 2 | 1 | 1 | 1 | 1 | 1 | 1 |" ]] \
  && pass "the totals: 16 decisions, each in one outcome" || fail "totals" "$TOTAL"
[[ "$OUT" == *"16 shadowed decisions from 14 calls"* && "$OUT" == *"1 unreadable lines skipped"* ]] \
  && pass "the header counts, the old line and the duplicate left out" || fail "header" "$(printf '%s\n' "$OUT" | head -4)"
[[ "$OUT" != *toolu_old* ]] && pass "a line older than --days is left out" || fail "window" "$OUT"
[[ "$OUT" == *"- Classifier denied: toolu_k1"* && "$OUT" == *"- Ran: classifier: toolu_i1"* ]] \
  && pass "the tool_use_ids are listed by outcome" || fail "ids" "$OUT"
[[ "$OUT" != *SECRETCMD* ]] && pass "no command or reason text in the report" || fail "text leaked" "$OUT"
OUT=$(python3 -I tools/shadow-report.py --days 60 2>&1)
printf '%s\n' "$OUT" | grep -qF '| kubectl-guard | mutating-verb | 5 |' && pass "--days 60 reaches the old line" || fail "--days 60" "$OUT"

# --since: the same report as the matching --days, but for its title and the minute it ran.
ago() { python3 -c 'import datetime as dt, sys; print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
same() { sed -e 1d -e 's/ up to [0-9-]* [0-9:]* UTC/ up to NOW/'; }
A=$(python3 -I tools/shadow-report.py --days 14 2>&1 | same)
B=$(python3 -I tools/shadow-report.py --since "$(ago 14)" 2>&1 | same)
[[ -n "$A" && "$A" == "$B" ]] && pass "--since 14 days ago reads what --days 14 reads" || fail "--since = --days" "$(diff <(echo "$A") <(echo "$B") | head -5)"
OUT=$(python3 -I tools/shadow-report.py --since "$(ago 31)" 2>&1)
printf '%s\n' "$OUT" | grep -qF '| kubectl-guard | mutating-verb | 5 |' && [[ "$(head -1 <<<"$OUT")" == "# Shadow report: since "*" UTC" ]] \
  && pass "--since 31 days ago reaches the 30-day-old line, and the title says since" || fail "--since 31" "$(head -12 <<<"$OUT")"
OUT=$(python3 -I tools/shadow-report.py --since "$(ago 29)" 2>&1)
printf '%s\n' "$OUT" | grep -qF '| kubectl-guard | mutating-verb | 4 |' && pass "--since 29 days ago leaves it out" || fail "--since 29" "$OUT"

echo ""
results
