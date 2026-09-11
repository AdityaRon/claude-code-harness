#!/usr/bin/env bash
# Tests for session-start.sh — resume-drift branch. Stages snapshots at
# $CLAUDE_STATE_DIR, feeds SessionStart payloads on stdin, and asserts the
# drift classifications surfaced in stdout.
set -u
HOOK="hooks/session-start.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_STATE_DIR="$TMP/state"
mkdir -p "$CLAUDE_STATE_DIR"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label" "missing needle: $needle"; fi
}
check_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label" "unexpected needle: $needle"; fi
}

write_snap() {
  local sid="$1" path="$2" hash="$3" exists="$4"
  jq -n --arg p "$path" --arg h "$hash" --argjson e "$exists" \
    '{session_id:"'"$sid"'", ended_at:"2026-04-17T00:00:00Z", cwd:"/tmp",
      git_head:"", git_dirty:[],
      edited_files:[{path:$p, sha256:$h, exists:$e}]}' \
    > "$CLAUDE_STATE_DIR/${sid}.json"
}

run_resume() {
  local sid="$1"
  local payload
  payload=$(jq -nc --arg sid "$sid" '{source:"resume", session_id:$sid, hook_event_name:"SessionStart"}')
  printf '%s' "$payload" | bash "$HOOK" 2>/dev/null
}

TARGET="$TMP/target.txt"
printf 'original content\n' > "$TARGET"
CURRENT_HASH=$(shasum -a 256 "$TARGET" | awk '{print $1}')
STALE_HASH="0000000000000000000000000000000000000000000000000000000000000000"

echo "=== Drifted content → 'Resume drift detected' + 'drifted:' line ==="
write_snap "sess-drift" "$TARGET" "$STALE_HASH" "true"
OUT=$(run_resume "sess-drift")
check_contains "drift heading"      "Resume drift detected" "$OUT"
check_contains "drifted file named" "drifted: $TARGET"      "$OUT"

echo ""
echo "=== Matching hash → 'Resume drift: none' ==="
write_snap "sess-clean" "$TARGET" "$CURRENT_HASH" "true"
OUT=$(run_resume "sess-clean")
check_contains "no-drift banner"  "Resume drift: none"     "$OUT"
check_not_contains "no heading"   "Resume drift detected"  "$OUT"

echo ""
echo "=== File deleted since last session → 'missing:' line ==="
rm "$TARGET"
write_snap "sess-missing" "$TARGET" "$CURRENT_HASH" "true"
OUT=$(run_resume "sess-missing")
check_contains "missing heading"      "Resume drift detected" "$OUT"
check_contains "missing file named"   "missing: $TARGET"      "$OUT"
printf 'original content\n' > "$TARGET"  # restore for later cases

echo ""
echo "=== No snapshot on disk → silent fallback ==="
OUT=$(run_resume "sess-nonexistent-id")
check_not_contains "no drift output" "Resume drift" "$OUT"
check_contains    "git context still printed" "## Git context" "$OUT"

echo ""
echo "=== Non-resume sources skip drift check ==="
write_snap "sess-clean2" "$TARGET" "$CURRENT_HASH" "true"
payload=$(jq -nc '{source:"startup", session_id:"sess-clean2", hook_event_name:"SessionStart"}')
OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
check_not_contains "startup skips drift"  "Resume drift" "$OUT"
payload=$(jq -nc '{source:"clear", session_id:"sess-clean2", hook_event_name:"SessionStart"}')
OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
check_not_contains "clear skips drift"    "Resume drift" "$OUT"

echo ""
echo "=== HEAD change surfaced ==="
# Use the real repo HEAD as CUR_HEAD; stage a snapshot with a different head.
REAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$REAL_HEAD" ]]; then
  SNAP="$CLAUDE_STATE_DIR/sess-head.json"
  FAKE_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  jq -n --arg p "$TARGET" --arg h "$CURRENT_HASH" --arg head "$FAKE_HEAD" \
    '{session_id:"sess-head", ended_at:"2026-04-17T00:00:00Z", cwd:"/tmp",
      git_head:$head, git_dirty:[],
      edited_files:[{path:$p, sha256:$h, exists:true}]}' > "$SNAP"
  OUT=$(run_resume "sess-head")
  check_contains "HEAD change heading" "Resume drift detected" "$OUT"
  check_contains "HEAD change line"    "HEAD changed: deadbeefdead" "$OUT"
else
  echo "  SKIP: HEAD-change test (not in a git repo)"
fi

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
