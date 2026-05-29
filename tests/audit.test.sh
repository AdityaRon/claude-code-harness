#!/usr/bin/env bash
# Tests for audit.sh — verifies Bash commands are logged (new), file edits log
# paths, multiline commands stay one line, and Stop logs a session summary.
set -u
HOOK="hooks/audit.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
run(){ printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; }

echo "=== Bash command is logged ==="
run '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git status --short"}}'
grep -qF "| Bash | git status --short |" "$CLAUDE_AUDIT_LOG" && pass "bash command logged" || fail "bash command logged" "$(cat "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== Edit logs the file path (not a command) ==="
run '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt"}}'
grep -qF "| Edit | /tmp/foo.txt |" "$CLAUDE_AUDIT_LOG" && pass "edit path logged" || fail "edit path logged" "$(cat "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== Multiline bash command collapses to a single log line ==="
BEFORE=$(wc -l < "$CLAUDE_AUDIT_LOG")
run '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"line1\nline2\nline3"}}'
AFTER=$(wc -l < "$CLAUDE_AUDIT_LOG")
[[ $((AFTER - BEFORE)) -eq 1 ]] && pass "multiline command stays one line" || fail "multiline command stays one line" "delta=$((AFTER-BEFORE))"

echo ""
echo "=== Stop logs a session summary ==="
run '{"hook_event_name":"Stop","num_turns":7,"usage":{"total_cost_usd":0.42}}'
grep -qF "session_end | turns=7" "$CLAUDE_AUDIT_LOG" && pass "stop summary logged" || fail "stop summary logged" "$(cat "$CLAUDE_AUDIT_LOG")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
