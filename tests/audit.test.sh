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
echo "=== SessionEnd logs the same summary (this is where the harness wires it) ==="
run '{"hook_event_name":"SessionEnd","num_turns":3,"session_id":"abc123","reason":"clear"}'
grep -qF "session_end | turns=3 session=abc123 reason=clear" "$CLAUDE_AUDIT_LOG" \
  && pass "session end summary logged with reason" \
  || fail "session end summary logged with reason" "$(cat "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== SessionEnd without a reason omits the field (no dangling 'reason=') ==="
BEFORE=$(wc -l < "$CLAUDE_AUDIT_LOG")
run '{"hook_event_name":"SessionEnd","num_turns":2,"session_id":"noreason"}'
LINE=$(tail -1 "$CLAUDE_AUDIT_LOG")
if [[ "$LINE" == *"session=noreason"* && "$LINE" != *"reason="* ]]; then
  pass "absent reason omitted"
else
  fail "absent reason omitted" "$LINE"
fi
[[ $(( $(wc -l < "$CLAUDE_AUDIT_LOG") - BEFORE )) -eq 1 ]] \
  && pass "session end is one line" || fail "session end is one line" "$LINE"

echo ""
echo "=== An unknown event still logs rather than dropping the call ==="
run '{"hook_event_name":"SomeFutureEvent","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
grep -qF "| Bash | echo hi |" "$CLAUDE_AUDIT_LOG" && pass "unknown event falls through" || fail "unknown event falls through" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== PermissionDenied records the verdict, not just the attempt ==="
# The whole point of this arm: a refused command must be distinguishable from
# one that ran. Falling through to the catch-all would log the same shape.
run '{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"kubectl delete pod foo"},"denial_reason":"Blocked by classifier"}'
grep -qF "| DENIED | Bash | kubectl delete pod foo | Blocked by classifier |" "$CLAUDE_AUDIT_LOG" \
  && pass "denied bash command logged with reason" \
  || fail "denied bash command logged with reason" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

run '{"hook_event_name":"PermissionDenied","tool_name":"Write","tool_input":{"file_path":"/tmp/blocked.txt"},"denial_reason":"Blocked by classifier"}'
grep -qF "| DENIED | Write | /tmp/blocked.txt |" "$CLAUDE_AUDIT_LOG" \
  && pass "denied file write logged" \
  || fail "denied file write logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

run '{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}'
grep -qF "| DENIED | Bash | rm -rf /tmp/x | no reason given |" "$CLAUDE_AUDIT_LOG" \
  && pass "missing denial_reason does not drop the record" \
  || fail "missing denial_reason does not drop the record" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

# A denial must never be mistaken for a successful call. Anchor on the FIELD
# POSITION, not a substring: an ordinary call logs `<ts> | Bash | <cmd> |`,
# whereas a denial logs `<ts> | DENIED | Bash | <cmd> |`, and the ordinary
# shape is a substring of the denial one — so a plain -F grep passes either way.
run '{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"UNIQUEDENY42"},"denial_reason":"Blocked by classifier"}'
if grep -qE '^[0-9TZ:-]+ \| Bash \| UNIQUEDENY42 ' "$CLAUDE_AUDIT_LOG"; then
  fail "denial is not logged as an ordinary call" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
else
  pass "denial is not logged as an ordinary call"
fi

echo ""
echo "=== PostModelSwitch records which model produced what follows ==="
run '{"hook_event_name":"PostModelSwitch","from_model":"claude-opus-5","to_model":"claude-sonnet-5"}'
grep -qF "| model_switch | claude-opus-5 -> claude-sonnet-5 |" "$CLAUDE_AUDIT_LOG" \
  && pass "model switch logged" || fail "model switch logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

# camelCase fallback: the payload is documented snake_case, so this only proves
# the defensive read works — it must not regress into logging "unknown".
run '{"hook_event_name":"PostModelSwitch","fromModel":"claude-opus-5","toModel":"claude-haiku-4-5"}'
grep -qF "| model_switch | claude-opus-5 -> claude-haiku-4-5 |" "$CLAUDE_AUDIT_LOG" \
  && pass "camelCase payload still logged" || fail "camelCase payload still logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

# A switch with no usable fields must still leave a record rather than vanish.
run '{"hook_event_name":"PostModelSwitch"}'
grep -qF "| model_switch | unknown -> unknown |" "$CLAUDE_AUDIT_LOG" \
  && pass "fieldless switch still recorded" || fail "fieldless switch still recorded" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
