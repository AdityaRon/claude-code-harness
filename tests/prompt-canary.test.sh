#!/usr/bin/env bash
# The transcript generator (tests/lib/transcripts.py) writes what it says, and no report that
# reads transcripts prints prompt text: spend-report, disk-space.py report, permission-friction
# and hook-latency each run on its corpus, whose prompts all start with a canary string.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null || { echo "  SKIP: no python3"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
REPO=$PWD
GEN="$REPO/tests/lib/transcripts.py"
P="$TMP/home/.claude/projects"
CANARY=CANARY-7f3a91c2

python3 "$GEN" "$P" --canary "$CANARY" > "$TMP/planted.json" 2>"$TMP/err" \
  && pass "the generator writes a corpus" || fail "the generator writes a corpus" "$(cat "$TMP/err")"

echo "=== the corpus holds what it says ==="
# Read back from the files, not from the generator's own summary.
OUT=$(python3 - "$P" "$CANARY" <<'PY'
import collections, glob, json, os, sys
root, canary = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True))
recs = {f: [json.loads(l) for l in open(f)] for f in files}
ids = collections.Counter(r['message']['id'] for rs in recs.values() for r in rs if r['type'] == 'assistant')
def ttl(rs):
    w1 = sum(r['message']['usage']['cache_creation']['ephemeral_1h_input_tokens'] for r in rs if r['type'] == 'assistant')
    w5 = sum(r['message']['usage']['cache_creation']['ephemeral_5m_input_tokens'] for r in rs if r['type'] == 'assistant')
    return '1h' if w1 > w5 else '5m'
prompts = [r for rs in recs.values() for r in rs if r['type'] == 'user' and isinstance(r['message']['content'], str)]
print('streamed', sum(n > 1 for n in ids.values()))
print('scheduled', sum(bool(r.get('scheduledFireId')) and bool(r.get('isMeta')) for r in prompts))
print('boundaries', sum(r.get('subtype') == 'compact_boundary' for rs in recs.values() for r in rs))
print('subagents', sum('/subagents/agent-' in f and os.path.exists(f[:-6] + '.meta.json') for f in files))
print('ttls', ' '.join(sorted(ttl(rs) for rs in recs.values())))
print('canary-first', sum(r['message']['content'].startswith(canary) for r in prompts), 'of', len(prompts))
print('hooks', sum(r['type'] == 'attachment' and 'durationMs' in r['attachment'] for rs in recs.values() for r in rs))
PY
)
for want in 'streamed 1' 'scheduled 1' 'boundaries 1' 'subagents 1' 'ttls 1h 5m' 'canary-first 4 of 4' 'hooks 1'; do
  [[ "$OUT" == *"$want"* ]] && pass "corpus: $want" || fail "corpus: $want" "$OUT"
done

echo ""
echo "=== no report prints the prompt text ==="
# clean NAME OUTPUT WANT: OUTPUT has WANT (the report read the corpus) and no canary.
clean() {
  if [[ "$2" != *"$3"* ]]; then fail "$1 read the corpus" "wanted: $3"$'\n'"$2"; return; fi
  [[ "$2" != *"$CANARY"* ]] && pass "$1: no prompt text" || fail "$1 printed prompt text" "$(printf '%s\n' "$2" | grep -F "$CANARY" | head -3)"
}
SR() { python3 "$REPO/bin/spend-report.py" --root "$P" --since 1d "$@" 2>&1; }
clean "spend-report" "$(SR --tick-prompt 'loop tick')" "ticks whose prompt contains 'loop tick': 1,"
clean "spend-report --json" "$(SR --tick-prompt 'loop tick' --json)" '"calls": 7'
# The positive control: --turns prints the first 40 characters of each prompt by design.
[[ "$(SR --tick-prompt 'loop tick' --turns)" == *"$CANARY"* ]] \
  && pass "spend-report --turns does print it: the canary sits where a 40-character leak shows" \
  || fail "the canary is not where --turns would print it" "$(SR --tick-prompt 'loop tick' --turns)"

mkdir -p "$TMP/jobs/0a1b2c3d/tmp"; echo '{}' > "$TMP/jobs/0a1b2c3d/state.json"
DS() { CLAUDE_CLI_BIN=/nonexistent/claude python3 "$REPO/bin/disk-space.py" report --jobs "$TMP/jobs" --projects "$P" \
  --transcript-mb 0 --backups "$TMP/none" --settings "$TMP/none.json" "$@" 2>&1; }
clean "disk-space.py report" "$(DS)" "1 compactions"
clean "disk-space.py report --json" "$(DS --json)" '"compactions": 1'

PF() { HOME="$TMP/home" python3 "$REPO/bin/permission-friction.py" --days 1 "$@" 2>&1; }
clean "permission-friction" "$(PF)" "| guard_ask | 1 |"
PF --out "$TMP/pf" >/dev/null
clean "permission-friction --out" "$(cat "$TMP/pf/report.md" "$TMP/pf/friction.json" 2>&1)" '"friction_events": 1'

echo '{}' > "$TMP/settings.json"
HL() { python3 "$REPO/bin/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TMP/none.log" --days 1 "$@" 2>&1; }
clean "hook-latency" "$(HL)" "network-guard.sh"
clean "hook-latency --json" "$(HL --json)" '"network-guard.sh"'

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit "$FAIL"
