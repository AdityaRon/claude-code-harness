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
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
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

echo ""
echo "=== one copy per session; the byte cap ==="
printf '{"cleanupPeriodDays": 100000}' > "$TMP/settings.json"
runs(){ jq -nc --arg t "$1" --arg s "$2" '{hook_event_name:"PreCompact",transcript_path:$t,trigger:"auto",session_id:$s}' | bash "$HOOK"; }
D="$CLAUDE_TRANSCRIPT_DIR"; rm -rf "$D"; mkdir -p "$D"
S1="$TMP/s1.jsonl"; printf 'line1\n' > "$S1"
runs "$S1" aaaaaaaa-0001; sleep 1; printf 'line2\n' >> "$S1"; runs "$S1" aaaaaaaa-0001
C=$(ls "$D"/transcript_*_aaaaaaaa.jsonl | wc -l | tr -d ' ')
[ "$C" = 1 ] && cmp -s "$S1" "$(ls "$D"/transcript_*_aaaaaaaa.jsonl)" && pass "a session's second, larger copy replaces its first" || fail "one per session" "$(ls -l "$D")"
S2="$TMP/s2.jsonl"; printf 'other\n' > "$S2"; runs "$S2" bbbbbbbb-0002
[ "$(ls "$D"/transcript_*_aaaaaaaa.jsonl 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ -n "$(ls "$D"/transcript_*_bbbbbbbb.jsonl 2>/dev/null)" ] \
  && pass "another session's copy stays" || fail "other session" "$(ls "$D")"
sleep 1; printf 'x\n' > "$S1"; runs "$S1" aaaaaaaa-0001
[ "$(ls "$D"/transcript_*_aaaaaaaa.jsonl | wc -l | tr -d ' ')" = 2 ] && pass "a truncated source keeps the larger older copy" || fail "truncated source" "$(ls -l "$D")"
: > "$D/transcript_auto_20990101_000000.jsonl"; sleep 1; printf 'line1\nline2\nline3\n' > "$S1"; runs "$S1" aaaaaaaa-0001
[ -e "$D/transcript_auto_20990101_000000.jsonl" ] && pass "a copy with no session id in its name stays" || fail "legacy copy" "$(ls "$D")"
for i in 1 2 3; do head -c 900000 /dev/zero > "$D/transcript_auto_2026020${i}_000000.jsonl"; done
B4=$(ls "$D" | sort); chmod 000 "$S1"; CLAUDE_TRANSCRIPT_BACKUP_MAX_MB=1 runs "$S1" aaaaaaaa-0001; chmod 644 "$S1"
[ "$(ls "$D" | sort)" = "$B4" ] && pass "a copy that fails deletes nothing, even over the cap" || fail "failed cp" "$(ls "$D")"
rm -rf "$D"; mkdir -p "$D"
for i in 1 2 3 4; do head -c 400000 /dev/zero > "$D/transcript_auto_2026010${i}_000000.jsonl"; touch -t "2026010${i}0000" "$D/transcript_auto_2026010${i}_000000.jsonl"; done
head -c 400000 /dev/zero > "$TMP/s3.jsonl"; CLAUDE_TRANSCRIPT_BACKUP_MAX_MB=1 runs "$TMP/s3.jsonl" cccccccc-0003
[ "$(ls "$D" | wc -l | tr -d ' ')" = 2 ] && [ -e "$D/transcript_auto_20260104_000000.jsonl" ] && [ ! -e "$D/transcript_auto_20260103_000000.jsonl" ] \
  && pass "past CLAUDE_TRANSCRIPT_BACKUP_MAX_MB the oldest go" || fail "cap" "$(ls -l "$D")"
head -c 2000000 /dev/zero > "$TMP/s4.jsonl"; CLAUDE_TRANSCRIPT_BACKUP_MAX_MB=1 runs "$TMP/s4.jsonl" dddddddd-0004
[ -n "$(ls "$D"/transcript_*_dddddddd.jsonl 2>/dev/null)" ] && [ "$(ls "$D" | wc -l | tr -d ' ')" = 1 ] \
  && pass "the newest stays even alone over the cap" || fail "keep newest" "$(ls -l "$D")"
rm -rf "$D"; mkdir -p "$D"
for i in 1 2 3; do head -c 900000 /dev/zero > "$D/transcript_auto_2026010${i}_000000.jsonl"; touch -t "2026010${i}0000" "$D/transcript_auto_2026010${i}_000000.jsonl"; done
CLAUDE_TRANSCRIPT_BACKUP_MAX_MB=0 runs "$TMP/s3.jsonl" eeeeeeee-0005
[ "$(ls "$D" | wc -l | tr -d ' ')" = 4 ] && pass "a cap of 0 keeps them all" || fail "cap 0" "$(ls "$D")"
rm -rf "$D"; mkdir -p "$D"
for i in 1 2 3; do head -c 900000 /dev/zero > "$D/transcript_auto_2026010${i}_000000.jsonl"; touch -t "2026010${i}0000" "$D/transcript_auto_2026010${i}_000000.jsonl"; done
runs "$TMP/s3.jsonl" ffffffff-0006
[ "$(ls "$D" | wc -l | tr -d ' ')" = 4 ] && pass "the default cap (1000 MB) leaves 3 MB alone" || fail "default cap" "$(ls "$D")"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
