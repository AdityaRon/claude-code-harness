#!/usr/bin/env bash
# Tests for bin/spend-report.py: dedupe, pricing, rewrites, away spend, ticks, alerts.
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
SR="$PWD/bin/spend-report.py"
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null || { echo "  SKIP: no python3"; exit 0; }
has() { [[ "$OUT" == *"$1"* ]] && pass "$2" || fail "$2" "wanted: $1"$'\n'"$OUT"; }

# One project, a main session and a subagent, from tests/lib/transcripts.py's record
# helpers. Times are 2026-10-20 UTC.
python3 - "$TMP/root" "$(dirname "${BASH_SOURCE[0]}")/lib" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[2])
import transcripts as T
root = sys.argv[1]
main = os.path.join(root, 'proj', 'sess-main.jsonl')
sub = os.path.join(root, 'proj', 'sess-main', 'subagents', 'agent-sub1.jsonl')
day = lambda t: f'2026-10-20T{t}Z'
user = lambda t, text, kind: T.user(day(t), text, kind)
asst = lambda t, mid, model, **kw: T.asst(day(t), mid, model, **kw)
rows = [
    user('09:00:00', 'fix the build', 'human'),
    # 1M output at $20 = $20.00, streamed as two records.
    asst('09:00:10', 'm1', 'claude-opus-5-5', out=500_000),
    asst('09:00:11', 'm1', 'claude-opus-5-5', out=1_000_000),
    # 150k read at $0.20 = $0.03; 100k 1h write at $8 = $0.80: not a rewrite (write < half).
    asst('09:01:00', 'm2', 'claude-opus-5-5', read=150_000, w1=100_000),
    # Two hours later, no prompt typed since: away. 10k read = $0.002; 200k 5m write at $5 = $1.00, a rewrite.
    # A cron fire, as Claude Code records one: isMeta, with a scheduledFireId and no origin.
    T.scheduled(day('11:00:00'), 'comms-hub tick'),
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
T.write(main, rows)
# Haiku 5.5 over 100k tokens of prompt: 200k input at $0.50 = $0.10 and a 200k write at
# $0.625 = $0.125, which is the agent's first call, so not a rewrite. The second call
# re-writes its whole 30k context at $0.125 = $0.00375: a rewrite.
subrows = [asst('11:05:00', 's1', 'claude-haiku-5-5', inp=200_000, w5=200_000),
           asst('11:30:00', 's2', 'claude-haiku-5-5', w5=30_000)]
T.write(sub, subrows)
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

echo "=== rewrite causes ==="
# Each case is a root of its own: one main session (1 h writes) or one subagent (5 min
# writes), a first call that writes, then the calls named, minutes after the one before.
python3 - "$TMP/causes" "$(dirname "${BASH_SOURCE[0]}")/lib" <<'PY'
import os, sys, datetime as dt
sys.path.insert(0, sys.argv[2])
import transcripts as T
base = dt.datetime(2026, 10, 20, 9, 0, tzinfo=dt.timezone.utc)
def at(m): return base + dt.timedelta(seconds=round(m * 60))
def call(m, n, w1=0, w5=0, read=0): return T.asst(at(m), f'm{n}', out=10, read=read, w5=w5, w1=w1)
def boundary(m): return T.boundary(at(m))
def tick(m): return T.scheduled(at(m), 'loop tick', fire='f')
K = 100_000
cases = {
    'gap70': [call(0, 1, w1=K), tick(69.5), call(70, 2, w1=K)],
    'gap30': [call(0, 1, w1=K), call(30, 2, w1=K)],
    'boundary': [call(0, 1, w1=K), boundary(5), call(10, 2, w1=K)],
    # The call before the rewrite only read: the file's writes are still 1 h.
    'noprevwrite': [call(0, 1, w1=3 * K), call(1, 2, read=3 * K), call(31, 3, w1=K)],
    # Exactly the TTL is not past it; a second more is.
    'edge': [call(0, 1, w1=K), call(60, 2, w1=K), call(120 + 1 / 60, 3, w1=K)],
    'sub': [call(0, 1, w5=K), call(6, 2, w5=K), call(10, 3, w5=K)],
}
for name, rows in cases.items():
    d = os.path.join(sys.argv[1], name, 'proj')
    f = os.path.join(d, 'sess', 'subagents', 'agent-a.jsonl') if name == 'sub' else os.path.join(d, 'sess.jsonl')
    T.write(f, rows)
PY
causes() {  # ROOT -> "main ttl-gap/compaction/other, subagents ttl-gap/compaction/other" rewrite calls
  TZ=UTC python3 "$SR" --root "$TMP/causes/$1" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 --json \
    | python3 -c 'import json,sys; c=json.load(sys.stdin)["rewrite_causes"]
print(", ".join(g + " " + "/".join(str(c[g][k]["calls"]) for k in ("ttl-gap","compaction","other")) for g in ("main","subagents")))'
}
want_causes() {  # CASE WANT WHY
  local got; got=$(causes "$1" 2>&1)
  [[ "$got" == "$2" ]] && pass "$3" || fail "$3" "wanted: $2"$'\n'"    got:    $got"
}
want_causes gap70 'main 1/0/0, subagents 0/0/0' "a 1 h file, 70 min since the last call: ttl-gap"
want_causes gap30 'main 0/0/1, subagents 0/0/0' "the same file, 30 min since: other"
want_causes boundary 'main 0/1/0, subagents 0/0/0' "a compact_boundary between the calls, 10 min apart: compaction"
want_causes noprevwrite 'main 0/0/1, subagents 0/0/0' "the call before wrote nothing, 30 min since: the file's 1 h TTL still holds, other"
want_causes edge 'main 1/0/1, subagents 0/0/0' "exactly 60 min is not past a 1 h TTL; 60 min and 1 s is"
want_causes sub 'main 0/0/0, subagents 1/0/1' "a 5 min subagent file: 6 min since is ttl-gap, 4 min is other"
OUT=$(TZ=UTC python3 "$SR" --root "$TMP/causes/gap70" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 2>&1)
has 'main sessions: 200k written; ttl-gap 1 calls 100k (50%), compaction 0 calls 0 (0%), other 0 calls 0 (0%)' \
  "the summary gives each cause's calls, tokens and share of the cache-write tokens"
has 'subagents:     0 written;' "subagents get a line of their own"
OUT=$(TZ=UTC python3 "$SR" --root "$TMP/causes/gap70" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 --tick-prompt 'loop tick' 2>&1)
has 'first call a ttl-gap rewrite in 1 of 1 ticks' "--tick-prompt counts the ticks whose first call was a ttl-gap rewrite"
has '2026-10-20 10:09  sess  first call: ttl-gap rewrite, 100k written, 70 min since this transcript'"'"'s last call (TTL 60 min)' "and says so on each tick's line"
[[ "$(printf '%s\n' "$OUT" | grep -c 'loop tick')" == 1 ]] \
  && pass "a tick's line carries no prompt text" || fail "prompt text on a tick line" "$OUT"

echo "=== synthetic records and copied calls ==="
# <synthetic>: written when not logged in, the login expired or the API was unreachable.
python3 - "$TMP/syn" "$(dirname "${BASH_SOURCE[0]}")/lib" <<'PY'
import datetime as dt, os, sys
sys.path.insert(0, sys.argv[2])
import transcripts as T
root = sys.argv[1]
day = lambda t: f'2026-10-20T{t}Z'
asst = lambda t, mid, **kw: T.asst(day(t), mid, **kw)
syn = lambda t, mid: T.asst(day(t), mid, model='<synthetic>', rec={'isApiErrorMessage': True})
def put(case, name, rows):
    T.write(os.path.join(root, case, 'proj', name + '.jsonl'), rows)
tick = lambda t: T.scheduled(day(t), 'loop tick')
# a: the tick got only a synthetic record.
put('a', 's', [tick('09:00:00'), syn('09:00:05', 'x1')])
# b: a real call 215 min before, then a tick: synthetic, then a real call that writes with 0 read.
put('b', 's', [asst('07:00:00', 'r0', w1=100_000), tick('10:30:00'), syn('10:30:05', 'x1'),
               asst('10:35:00', 'r1', w1=100_000)])
# c: two real calls 120 min apart (1 h TTL) with a synthetic one 30 min before the second.
put('c', 's', [asst('07:00:00', 'r0', w1=100_000), syn('08:30:00', 'x1'), asst('09:00:00', 'r1', w1=100_000)])
# d: a's calls c1, c2 are copied into b (a fork: same ids, same times). b sorts after a, so
# the copies used to move out of a, and a's tick read "600 min" since c0 instead of 5.
c1, c2 = asst('09:50:00', 'c1', read=100_000), asst('09:55:00', 'c2', read=100_000)
put('d', 'a', [asst('00:00:00', 'c0', w1=100_000), c1, c2, tick('10:00:00'), asst('10:00:05', 'c3', read=500_000)])
put('d', 'b', [c1, c2, asst('10:30:00', 'd1', read=100_000)])
# e: the tick's first call c1 is copied as line 1 of a fork subagent's transcript, which
# sorts after the main one. The main copy is the counted one: c1 stays the tick's.
e1 = asst('10:30:10', 'c1', w1=150_000)
put('e', 's', [asst('07:00:00', 'c0', w1=100_000), tick('10:30:00'), e1, asst('10:31:00', 'c2', read=150_000)])
T.write(os.path.join(root, 'e', 'proj', 's', 'subagents', 'agent-f1.jsonl'),
        [{**e1, 'isSidechain': True}, asst('10:30:20', 'f1', read=150_000)])
PY
tickrun() {  # CASE [args]
  local c=$1; shift
  OUT=$(TZ=UTC python3 "$SR" --root "$TMP/syn/$c" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 --tick-prompt 'loop tick' "$@" 2>&1)
}
tickrun a
has ", \$0.00, 1 failed" "a tick with only synthetic records is counted failed"
has 'failed: no API call' "and says so"
[[ "$OUT" != *'first call:'* && "$OUT" != *'first call a ttl-gap'* ]] && pass "and has no first-call line" || fail "a first-call line for a failed tick" "$OUT"
has '0 calls;' "a synthetic record is no call"
tickrun a --json
python3 -c 'import json,sys; t=json.loads(sys.argv[1])["turns"]; assert [x["failed"] for x in t]==[True]' "$OUT" 2>/dev/null \
  && pass "--json marks the turn failed" || fail "--json failed flag" "$OUT"
tickrun b
[[ "$OUT" == *', 0 failed'* ]] && pass "a tick with a real call after the synthetic one is not failed" || fail "b counted failed" "$OUT"
has "first call: ttl-gap rewrite, 100k written, 215 min since this transcript's last call (TTL 60 min)" \
  "synthetic, then a real 0-read write: the real call is the first call, and its cause is ttl-gap"
OUT=$(TZ=UTC python3 "$SR" --root "$TMP/syn/c" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 --json \
  | python3 -c 'import json,sys; c=json.load(sys.stdin)["rewrite_causes"]["main"]; print("/".join(str(c[k]["calls"]) for k in ("ttl-gap","compaction","other")))')
[[ "$OUT" == 1/0/0 ]] && pass "a synthetic record between two real calls more than a TTL apart: the second stays ttl-gap" \
  || fail "ttl-gap across a synthetic record" "$OUT"
tickrun d
has "first call: no rewrite, 5 min since this transcript's last call" "a call copied into a later file stays in its own file's chain: 5 min, not 600"
has '5 calls;' "and its cost is counted once"
tickrun e
has "first call: ttl-gap rewrite, 150k written, 210 min since this transcript's last call (TTL 60 min)" \
  "a parent call copied into a fork subagent stays the parent tick's first call"
has ', 0 failed' "and that tick is not failed"

echo "=== prices ==="
# One call per model: 1M output, 1M cache read and 1M 1 h cache write.
python3 - "$TMP/prices" "$(dirname "${BASH_SOURCE[0]}")/lib" claude-fable-5-2 claude-sonnet-5-5 <<'PY'
import os, sys
sys.path.insert(0, sys.argv[2])
import transcripts as T
for m in sys.argv[3:]:
    T.write(os.path.join(sys.argv[1], m, 'proj', 's.jsonl'),
            [T.asst('2026-10-20T09:00:00Z', 'm', model=m, out=1_000_000, read=1_000_000, w1=1_000_000)])
PY
price_of() {  # MODEL -> the cost of its call, or what went unpriced
  TZ=UTC python3 "$SR" --root "$TMP/prices/$1" --since 2026-10-20T00:00:00+00:00 --until 2026-10-21T00:00:00+00:00 --json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["unpriced"] or "%.2f" % sum(d["total"].values()))'
}
# $40 output, $0.20 cache read, $16 write (2x the $8 input).
[[ "$(price_of claude-fable-5-2)" == 56.20 ]] && pass "claude-fable-5-2 is priced: \$8 in, \$40 out, \$0.20 cache read" \
  || fail "claude-fable-5-2 price" "$(price_of claude-fable-5-2)"
# $10 output, $0.10 cache read (0.05x, not Claude Sonnet 5's 0.1x), $4 write.
[[ "$(price_of claude-sonnet-5-5)" == 14.10 ]] && pass "claude-sonnet-5-5 reads the cache at \$0.10" \
  || fail "claude-sonnet-5-5 price" "$(price_of claude-sonnet-5-5)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit "$FAIL"
