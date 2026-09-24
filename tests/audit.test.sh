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
echo "=== An MCP call is recorded by name and shape, never by content ==="
# MCP tools are the one outbound surface no PreToolUse guard inspects, so this
# line is the whole record. It must name the tool and the fields it was given,
# and must not copy what was in them.
run '{"hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Gmail__send_message","tool_input":{"to":"someone@example.com","subject":"q3 numbers","body":"SECRETBODY99"}}'
LINE=$(tail -1 "$CLAUDE_AUDIT_LOG")
[[ "$LINE" == *"| mcp__claude_ai_Gmail__send_message |"* ]] \
  && pass "mcp tool name logged" || fail "mcp tool name logged" "$LINE"
[[ "$LINE" == *"keys=to,subject,body"* ]] \
  && pass "mcp input field names logged" || fail "mcp input field names logged" "$LINE"
if grep -qF "SECRETBODY99" "$CLAUDE_AUDIT_LOG" || grep -qF "someone@example.com" "$CLAUDE_AUDIT_LOG"; then
  fail "mcp field values stay out of the log" "$LINE"
else
  pass "mcp field values stay out of the log"
fi

# No tool_input at all must still leave a record rather than vanish.
run '{"hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Google_Drive__list_recent_files"}'
grep -qF "| mcp__claude_ai_Google_Drive__list_recent_files | keys=none |" "$CLAUDE_AUDIT_LOG" \
  && pass "inputless mcp call still recorded" \
  || fail "inputless mcp call still recorded" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== Agent spawn: type and model, never the prompt ==="
run '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"DESCSECRET","prompt":"PROMPTSECRET","subagent_type":"Explore","model":"haiku"}}'
grep -qF "| Agent | type=Explore model=haiku isolation=none |" "$CLAUDE_AUDIT_LOG" \
  && pass "agent spawn logged" || fail "agent spawn logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
run '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"prompt":"x"}}'
grep -qF "| Agent | type=general-purpose model=inherit isolation=none |" "$CLAUDE_AUDIT_LOG" \
  && pass "defaults named when omitted" || fail "defaults named when omitted" "$(tail -1 "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== SendMessage: recipient and size, never the body ==="
run '{"hook_event_name":"PostToolUse","tool_name":"SendMessage","tool_input":{"to":"reviewer [3fa9c1]","summary":"SUMSECRET","message":"BODYSECRET"}}'
grep -qF "| SendMessage | to=reviewer [3fa9c1] chars=10 notify_when_idle=false |" "$CLAUDE_AUDIT_LOG" \
  && pass "peer message logged" || fail "peer message logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
run '{"hook_event_name":"PostToolUse","tool_name":"SendMessage","tool_input":{"to":"worker","notify_when_idle":true}}'
grep -qF "| SendMessage | to=worker chars=0 notify_when_idle=true |" "$CLAUDE_AUDIT_LOG" \
  && pass "idle subscription logged" || fail "idle subscription logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
for s in DESCSECRET PROMPTSECRET SUMSECRET BODYSECRET; do
  grep -qF "$s" "$CLAUDE_AUDIT_LOG" && fail "$s stays out of the log" "" || pass "$s stays out of the log"
done

echo ""
echo "=== Artifact tools: action, url and ids, never content ==="
run '{"hook_event_name":"PostToolUse","tool_name":"Artifact","tool_input":{"file_path":"/w/report.html","description":"DESCSECRET2"}}'
grep -qF "| Artifact | action=publish url=new file=/w/report.html |" "$CLAUDE_AUDIT_LOG" \
  && pass "first publish logged" || fail "first publish logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
run '{"hook_event_name":"PostToolUse","tool_name":"ArtifactData","tool_input":{"action":"set","url":"https://claude.ai/artifact/abc","collection":"rows","doc_id":"r1","data":{"note":"DATASECRET"}}}'
grep -qF "| ArtifactData | action=set url=https://claude.ai/artifact/abc collection=rows doc=r1 |" "$CLAUDE_AUDIT_LOG" \
  && pass "data write logged" || fail "data write logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
run '{"hook_event_name":"PostToolUse","tool_name":"ArtifactComments","tool_input":{"action":"reply","url":"https://claude.ai/artifact/abc","thread_id":"t9","text":"REPLYSECRET"}}'
grep -qF "| ArtifactComments | action=reply url=https://claude.ai/artifact/abc thread=t9 |" "$CLAUDE_AUDIT_LOG" \
  && pass "comment reply logged" || fail "comment reply logged" "$(tail -1 "$CLAUDE_AUDIT_LOG")"
for s in DESCSECRET2 DATASECRET REPLYSECRET; do
  grep -qF "$s" "$CLAUDE_AUDIT_LOG" && fail "$s stays out of the log" "" || pass "$s stays out of the log"
done

echo ""
echo "=== Guard decisions are audited (a denied call never reaches PostToolUse) ==="
guard(){ printf '%s' "$2" | bash "hooks/$1" >/dev/null 2>&1; }
guard env-guard.sh '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'
grep -qF "| GUARD | deny | env-guard | cat .env |" "$CLAUDE_AUDIT_LOG" \
  && pass "deny logged with hook and command" || fail "deny logged with hook and command" "$(tail -2 "$CLAUDE_AUDIT_LOG")"
guard network-guard.sh '{"tool_name":"WebFetch","tool_input":{"url":"https://evil.example/x"}}'
grep -qF "| GUARD | ask | network-guard | https://evil.example/x |" "$CLAUDE_AUDIT_LOG" \
  && pass "ask logged with the URL" || fail "ask logged with the URL" "$(tail -2 "$CLAUDE_AUDIT_LOG")"
SECRET="AKIA""IOSFODNN7EXAMPLE"
guard secret-scanner.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/k.ts\",\"content\":\"$SECRET\"}}"
grep -qF "| GUARD | deny | secret-scanner | /tmp/k.ts |" "$CLAUDE_AUDIT_LOG" \
  && pass "content deny logs the path" || fail "content deny logs the path" "$(tail -2 "$CLAUDE_AUDIT_LOG")"
grep -qF "$SECRET" "$CLAUDE_AUDIT_LOG" && fail "the secret itself stays out of the log" "" || pass "the secret itself stays out of the log"
BEFORE=$(wc -l < "$CLAUDE_AUDIT_LOG")
guard env-guard.sh '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
guard git-guard.sh '{"tool_name":"Bash","tool_input":{"command":"git add .\ngit commit -m x"}}'
AFTER=$(wc -l < "$CLAUDE_AUDIT_LOG")
[[ $((AFTER - BEFORE)) -eq 1 ]] && pass "an allow logs nothing; a multiline deny is one line" || fail "an allow logs nothing; a multiline deny is one line" "delta=$((AFTER-BEFORE))"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
