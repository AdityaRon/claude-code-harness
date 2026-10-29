#!/usr/bin/env bash
# Tests for bin/spend-report.py: dedupe, pricing, rewrites, away spend, ticks, alerts.
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
SR="$PWD/bin/spend-report.py"
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null || { echo "  SKIP: no python3"; exit 0; }
has() { [[ "$OUT" == *"$1"* ]] && pass "$2" || fail "$2" "wanted: $1"$'\n'"$OUT"; }

# One project, a main session and a subagent. Times are 2026-10-20 UTC.
python3 - "$TMP/root" <<'PY'
import json, os, sys
root = sys.argv[1]
main = os.path.join(root, 'proj', 'sess-main.jsonl')
sub = os.path.join(root, 'proj', 'sess-main', 'subagents', 'agent-sub1.jsonl')
os.makedirs(os.path.dirname(sub))
def user(t, text, kind):
    d = {'type': 'user', 'timestamp': f'2026-10-20T{t}Z', 'message': {'role': 'user', 'content': text}}
    if kind: d['origin'] = {'kind': kind}
    return d
def asst(t, mid, model, out=0, read=0, w5=0, w1=0, inp=0, **extra):
    u = {'input_tokens': inp, 'output_tokens': out, 'cache_read_input_tokens': read,
         'cache_creation_input_tokens': w5 + w1,
         'cache_creation': {'ephemeral_5m_input_tokens': w5, 'ephemeral_1h_input_tokens': w1}}
    u.update(extra)
    return {'type': 'assistant', 'timestamp': f'2026-10-20T{t}Z', 'requestId': 'req-' + mid,
            'message': {'id': mid, 'model': model, 'usage': u}}
rows = [
    user('09:00:00', 'fix the build', 'human'),
    # 1M output at $20 = $20.00, streamed as two records.
    asst('09:00:10', 'm1', 'claude-opus-5-5', out=500_000),
    asst('09:00:11', 'm1', 'claude-opus-5-5', out=1_000_000),
    # 150k read at $0.20 = $0.03; 100k 1h write at $8 = $0.80: not a rewrite (write < half).
    asst('09:01:00', 'm2', 'claude-opus-5-5', read=150_000, w1=100_000),
    # Two hours later, no prompt typed since: away. 10k read = $0.002; 200k 5m write at $5 = $1.00, a rewrite.
    # A cron fire, as Claude Code records one: isMeta, with a scheduledFireId and no origin.
    {**user('11:00:00', 'comms-hub tick', None), 'isMeta': True, 'scheduledFireId': 'fire-1'},
    asst('11:00:05', 'm3', 'claude-opus-5-5', read=10_000, w5=200_000),
    # Any other isMeta record starts no turn, even one quoting the prompt.
    {**user('11:00:20', 'comms-hub tick, quoted in a caveat', None), 'isMeta': True},
    # Fast mode doubles: 100k output at $40 = $4.00.
    asst('11:00:30', 'm4', 'claude-opus-5-5', out=100_000, speed='fast'),
    # An advisor iteration, priced at its own model: 100k input at $10 = $1.00.
    asst('11:01:00', 'm5', 'claude-opus-5-5', out=0, iterations=[
        {'type': 'message', 'input_tokens': 0, 'output_tokens': 0},
        {'type': 'advisor_message', 'model': 'claude-fable-5-1', 'input_tokens': 100_000, 'output_tokens': 0}]),
    asst('11:02:00', 'm6', 'claude-unknown-9', out=1000),
]
with open(main, 'w') as f:
    f.write('\n'.join(json.dumps(r) for r in rows) + '\n')
# Haiku 5.5 over 100k tokens of prompt: 200k input at $0.50 = $0.10 and a 200k write at
# $0.625 = $0.125, which is the agent's first call, so not a rewrite. The second call
# re-writes its whole 30k context at $0.125 = $0.00375: a rewrite.
subrows = [asst('11:05:00', 's1', 'claude-haiku-5-5', inp=200_000, w5=200_000),
           asst('11:30:00', 's2', 'claude-haiku-5-5', w5=30_000)]
with open(sub, 'w') as f:
    f.write('\n'.join(json.dumps(r) for r in subrows) + '\n')
json.dump({'agentType': 'reviewer'}, open(sub[:-len('.jsonl')] + '.meta.json', 'w'))
PY
run() { OUT=$(TZ=UTC python3 "$SR" --root "$TMP/root" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 "$@" 2>&1); RC=$?; }

echo "=== totals ==="
run
# 20 + 0.03 + 0.80 + 0.002 + 1.00 + 4.00 + 1.00 (advisor) + 0.10 + 0.125 + 0.00375
has 'total $27.06' "a streamed message counts once, at its final output, and every price applies"
has 'output $24.00' "fast mode doubles the output price"
has 'advisor $1.00' "the advisor iteration is priced at its own model"
has 'claude-unknown-9 (1 calls)' "an unpriced model is named, not dropped silently"
has '8 calls' "eight distinct calls in the window, the streamed one once, the unpriced one too"
[[ $RC -eq 0 ]] && pass "no limit set, exit 0" || fail "exit $RC with no limit"

echo "=== rewrites, away spend, subagents ==="
has '  1 $   0.23  2026-10-20 11:05  sess-mai/sub1' "the subagent's second call is a rewrite, its first is not, and both ran away"
has '  2 $   6.23  sess-mai' "a session's figures include its subagents'"
has 'reviewer' "the subagent's type comes from its meta file"
OUT_LINE=$(printf '%s\n' "$OUT" | grep '^away')
[[ "$OUT_LINE" == *'$6.23 in 6 calls'* ]] && pass "away: the calls more than 60 min after the last typed prompt" \
  || fail "away spend" "$OUT_LINE"
run --away 180
has 'away (no prompt typed in the 180 min before): $0.00' "--away widens the window"

echo "=== ticks and turns ==="
run --tick-prompt 'comms-hub tick' --turns
has "ticks whose prompt contains 'comms-hub tick': 1, \$6.00" "the tick is the turn its prompt started, subagents aside"
has 'scheduled  comms-hub tick' "a cron fire is a scheduled turn"
[[ "$OUT" != *'fix the build'* ]] && pass "--tick-prompt lists only the ticks" || fail "a non-tick turn was listed" "$OUT"

echo "=== alerts ==="
run --max-away 5
[[ $RC -eq 1 && "$OUT" == *'ALERT: away spend $6.23 is over --max-away $5.00'* ]] && pass "away over the limit alerts, exit 1" \
  || fail "max-away" "rc=$RC $OUT"
run --max-rewrites 0
[[ $RC -eq 1 && "$OUT" == *'rewrote its context 1 times'* ]] && pass "rewrites over the limit alert" || fail "max-rewrites" "$OUT"
run --max-rewrites 0 --rewrite-hint 'raise session.compact_window'
[[ "$OUT" == *'over --max-rewrites 0; raise session.compact_window'* ]] && pass "the alert says what to change" \
  || fail "rewrite hint" "$OUT"
run --max-ticks 5 --tick-prompt 'comms-hub tick'
[[ $RC -eq 1 && "$OUT" == *'ticks cost $6.00, over --max-ticks $5.00'* ]] && pass "ticks over the limit alert" || fail "max-ticks" "$OUT"
run --max-away 10 --max-rewrites 5 --max-ticks 10 --tick-prompt tick
[[ $RC -eq 0 && "$OUT" != *ALERT* ]] && pass "under every limit, no alert" || fail "false alert" "$OUT"

echo "=== the window ==="
OUT=$(TZ=UTC python3 "$SR" --root "$TMP/root" --since 2026-10-20T10:00:00+00:00 --until 2026-10-20T11:00:30+00:00 2>&1)
has 'transcripts, 1 calls;' "--since and --until bound the calls"
OUT=$(python3 "$SR" --root "$TMP/root" --since yesterday 2>&1); RC=$?
[[ $RC -eq 2 ]] && pass "a bad --since exits 2" || fail "bad --since exit $RC" "$OUT"
run --json
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["calls"]==8 and d["alerts"]==[]' "$OUT" 2>/dev/null \
  && pass "--json is JSON with the same counts" || fail "--json" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit "$FAIL"
