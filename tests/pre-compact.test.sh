#!/usr/bin/env bash
# Tests for pre-compact.sh: the transcript is backed up before compaction,
# privately, and the backups are pruned to the newest 20.
set -u
HOOK="hooks/pre-compact.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_TRANSCRIPT_DIR="$TMP/backups"
# A long retention for the count test; the age test sets its own.
printf '{"cleanupPeriodDays": 100000}' > "$TMP/settings.json"; export CLAUDE_SETTINGS_FILE="$TMP/settings.json"
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
run(){ jq -nc --arg t "$1" --arg g "$2" '{hook_event_name:"PreCompact",transcript_path:$t,trigger:$g}' | bash "$HOOK"; }
# GNU first: on Linux `stat -f` is filesystem status and succeeds with the wrong output.
mode(){ stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

echo "=== pre-compact.sh ==="
T="$TMP/session.jsonl"; printf '{"type":"user"}\n{"type":"assistant"}\n' > "$T"; chmod 600 "$T"
run "$T" manual
B=$(ls "$CLAUDE_TRANSCRIPT_DIR"/transcript_manual_*.jsonl 2>/dev/null | head -1)
[[ -n "$B" ]] && pass "backs up with the trigger in the name" || fail "backs up with the trigger in the name" "$(ls "$CLAUDE_TRANSCRIPT_DIR" 2>&1)"
cmp -s "$T" "$B" && pass "the backup matches the transcript" || fail "the backup matches the transcript" "differs"
[[ "$(mode "$B")" == "600" ]] && pass "the backup stays private (600)" || fail "the backup stays private (600)" "$(mode "$B")"

run "$T" "../../escape"
[[ -z "$(find "$TMP" -maxdepth 1 -name 'escape*')" && -n "$(ls "$CLAUDE_TRANSCRIPT_DIR"/transcript_escape_* 2>/dev/null)" ]] \
  && pass "a trigger with a path in it stays in the backup directory" || fail "a trigger with a path in it stays in the backup directory" "$(ls -R "$TMP")"

rm -f "$CLAUDE_TRANSCRIPT_DIR"/*
for i in $(seq -w 1 22); do : > "$CLAUDE_TRANSCRIPT_DIR/transcript_auto_202601${i}_000000.jsonl"; touch -t "202601${i}0000" "$CLAUDE_TRANSCRIPT_DIR/transcript_auto_202601${i}_000000.jsonl"; done
run "$T" auto
N=$(ls "$CLAUDE_TRANSCRIPT_DIR"/transcript_*.jsonl | wc -l | tr -d ' ')
[[ "$N" == "20" ]] && pass "keeps the newest 20" || fail "keeps the newest 20" "kept $N"
[[ ! -e "$CLAUDE_TRANSCRIPT_DIR/transcript_auto_20260101_000000.jsonl" ]] && pass "drops the oldest" || fail "drops the oldest" "still there"

rm -rf "$CLAUDE_TRANSCRIPT_DIR"
run "$TMP/missing.jsonl" auto
[[ ! -d "$CLAUDE_TRANSCRIPT_DIR" ]] && pass "does nothing without a transcript" || fail "does nothing without a transcript" "created $CLAUDE_TRANSCRIPT_DIR"

echo ""
echo ""
echo "=== private even from a 644 source, named per session, pruned by age ==="
rm -f "$CLAUDE_TRANSCRIPT_DIR"/*
chmod 644 "$T"
jq -nc --arg t "$T" '{hook_event_name:"PreCompact",transcript_path:$t,trigger:"auto",session_id:"65633a07-2d78-439e"}' | bash "$HOOK"
B=$(ls "$CLAUDE_TRANSCRIPT_DIR"/transcript_auto_*_65633a07.jsonl 2>/dev/null | head -1)
[[ -n "$B" ]] && pass "the session id is in the name" || fail "session id in name" "$(ls "$CLAUDE_TRANSCRIPT_DIR")"
[[ -n "$B" && "$(mode "$B")" == "600" ]] && pass "600 from a 644 transcript" || fail "600 from 644" "${B:+$(mode "$B")}"
: > "$CLAUDE_TRANSCRIPT_DIR/transcript_auto_20200101_000000.jsonl"; touch -t 202001010000 "$CLAUDE_TRANSCRIPT_DIR/transcript_auto_20200101_000000.jsonl"
printf '{"cleanupPeriodDays": 7}' > "$TMP/settings.json"
run "$T" manual
[[ ! -e "$CLAUDE_TRANSCRIPT_DIR/transcript_auto_20200101_000000.jsonl" ]] && pass "a backup older than cleanupPeriodDays goes, under the count" || fail "age prune" "$(ls "$CLAUDE_TRANSCRIPT_DIR")"
[[ -n "$(ls "$CLAUDE_TRANSCRIPT_DIR"/transcript_manual_* 2>/dev/null)" ]] && pass "today's backup stays" || fail "today's backup stays" "$(ls "$CLAUDE_TRANSCRIPT_DIR")"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
