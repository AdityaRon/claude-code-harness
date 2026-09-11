#!/usr/bin/env bash
# Tests for workflow-record.sh — records a workflow run's .js path (audit + pointer).
set -u
HOOK="hooks/workflow-record.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"
export CLAUDE_WORKFLOW_STATE_DIR="$TMP/wf"
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
run(){ printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; }
SCRIPT="$TMP/run.js"; echo "// wf" > "$SCRIPT"

echo "=== records pointer + audit from tool_response.scriptPath ==="
run "$(jq -nc --arg p "$SCRIPT" '{tool_name:"Workflow",session_id:"s1",hook_event_name:"PostToolUse",tool_response:{runId:"wf_x",scriptPath:$p}}')"
[[ "$(cat "$CLAUDE_WORKFLOW_STATE_DIR/s1.path" 2>/dev/null)" == "$SCRIPT" ]] && pass "pointer written" || fail "pointer written" ""
grep -qF "| workflow | $SCRIPT |" "$CLAUDE_AUDIT_LOG" && pass "audit logged" || fail "audit logged" "$(cat "$CLAUDE_AUDIT_LOG")"

echo ""
echo "=== finds a .js anywhere in tool_response (robust to field name) ==="
rm -rf "$CLAUDE_WORKFLOW_STATE_DIR"
run "$(jq -nc --arg p "$SCRIPT" '{tool_name:"Workflow",session_id:"s2",hook_event_name:"PostToolUse",tool_response:{nested:{path:$p}}}')"
[[ "$(cat "$CLAUDE_WORKFLOW_STATE_DIR/s2.path" 2>/dev/null)" == "$SCRIPT" ]] && pass "found nested .js path" || fail "found nested .js path" ""

echo ""
echo "=== non-Workflow tool is ignored ==="
rm -rf "$CLAUDE_WORKFLOW_STATE_DIR"
run '{"tool_name":"Bash","session_id":"s3","hook_event_name":"PostToolUse","tool_input":{"command":"ls"}}'
[[ -e "$CLAUDE_WORKFLOW_STATE_DIR/s3.path" ]] && fail "ignores non-Workflow" "pointer created" || pass "ignores non-Workflow"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
