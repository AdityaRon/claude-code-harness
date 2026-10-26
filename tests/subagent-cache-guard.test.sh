#!/usr/bin/env bash
# Tests for subagent-cache-guard.sh
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log" HOME="$TMP/home" CLAUDE_SUBAGENT_CACHE_DIR="$TMP/state"
unset CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL ENABLE_PROMPT_CACHING_1H FORCE_PROMPT_CACHING_5M CLAUDE_SUBAGENT_MAX_COLD_STARTS
mkdir -p "$HOME/.claude"
HOOK="$PWD/hooks/subagent-cache-guard.sh"
PASS=0; FAIL=0

# call LABEL EXPECT [AGENT]: one tool call by AGENT (none: a main-session call).
call() {
  local label="$1" expect="$2" agent="${3:-}" out got
  out=$(jq -nc --arg a "$agent" '{tool_name:"Bash",tool_input:{command:"ls"},session_id:"s1"}
    + (if $a == "" then {} else {agent_id:$a, agent_type:"general-purpose"} end)' | bash "$HOOK" 2>/dev/null)
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
  [[ -z "$got" ]] && got=allow
  if [[ "$got" == "$expect" ]]; then echo "  OK ($expect): $label"; PASS=$((PASS+1))
  else echo "  FAIL (expected=$expect got=$got): $label"; FAIL=$((FAIL+1)); fi
  REASON=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
}
# ago AGENT SECONDS [GAPS] [STOPPED]: the agent's last call was SECONDS ago.
ago() { printf '%s %s %s\n' "$(( $(date +%s) - $2 ))" "${3:-0}" "${4:-0}" > "$TMP/state/$1"; }
gaps() { cut -d' ' -f2 "$TMP/state/$1"; }

echo "=== a main session is never counted ==="
call "no agent_id" allow
[[ ! -d "$TMP/state" ]] && { echo "  OK: no state written"; PASS=$((PASS+1)); } || { echo "  FAIL: state written"; FAIL=$((FAIL+1)); }

echo "=== gaps past the 5-minute TTL count, shorter ones do not ==="
call "first call" allow a1
ago a1 200; call "200 s later: warm" allow a1
[[ "$(gaps a1)" == 0 ]] && { echo "  OK: a warm gap is not counted"; PASS=$((PASS+1)); } || { echo "  FAIL: counted $(gaps a1)"; FAIL=$((FAIL+1)); }
ago a1 400; call "400 s later: cold" allow a1
[[ "$(gaps a1)" == 1 ]] && { echo "  OK: a cold gap is counted"; PASS=$((PASS+1)); } || { echo "  FAIL: gaps $(gaps a1)"; FAIL=$((FAIL+1)); }
ago a1 400 3; call "the fourth cold gap" allow a1
ago a1 400 4; call "the fifth cold gap stops it" deny a1
[[ "$REASON" == *"expired 5 times"*"reply with what you found and what is left"* ]] \
  && { echo "  OK: the reason says why and what to do"; PASS=$((PASS+1)); } || { echo "  FAIL: reason: $REASON"; FAIL=$((FAIL+1)); }
call "its next call, right away, stays denied" deny a1
call "another agent is not affected" allow a2

echo "=== a later resume gets through and counting restarts ==="
ago a1 4000 5 1; call "resumed an hour later" allow a1
[[ "$(gaps a1)" == 0 ]] && { echo "  OK: the count restarts"; PASS=$((PASS+1)); } || { echo "  FAIL: gaps $(gaps a1)"; FAIL=$((FAIL+1)); }

echo "=== the limit and the TTL follow the settings ==="
ago a3 400 1; CLAUDE_SUBAGENT_MAX_COLD_STARTS=2 call "CLAUDE_SUBAGENT_MAX_COLD_STARTS=2: the second gap stops it" deny a3
ago a4 400 9; CLAUDE_SUBAGENT_MAX_COLD_STARTS=0 call "0 turns it off" allow a4
ago a5 1200 4; CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL=1h call "a 1h TTL: 20 minutes is warm" allow a5
ago a5 1200 4; ENABLE_PROMPT_CACHING_1H=1 call "ENABLE_PROMPT_CACHING_1H: warm too" allow a5
ago a5 1200 4; ENABLE_PROMPT_CACHING_1H=1 FORCE_PROMPT_CACHING_5M=1 call "FORCE_PROMPT_CACHING_5M wins: cold" deny a5
printf '{"subagentPromptCacheTtl":"1h"}\n' > "$HOME/.claude/settings.json"
ago a6 1200 4; call "subagentPromptCacheTtl 1h in settings.json: warm" allow a6
rm "$HOME/.claude/settings.json"

echo "=== an agent id is never a path ==="
call "../escape" allow '../escape'
call "a/b" allow 'a/b'
[[ ! -e "$TMP/escape" && ! -e "$TMP/state/a" ]] && { echo "  OK: nothing written outside the state dir"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: wrote a path from the agent id"; FAIL=$((FAIL+1)); }
printf 'garbage here x\n' > "$TMP/state/a7"; call "an unreadable state file starts over" allow a7
# Bash arithmetic would run a substitution inside an array index. No space in
# it, since read splits the fields on one.
printf '#!/bin/sh\ntouch "%s/ran"\n' "$TMP" > "$TMP/mark"; chmod +x "$TMP/mark"
printf '1 x[$(%s/mark)] 0\n' "$TMP" > "$TMP/state/a8"; call "a state file is data" allow a8
[[ ! -e "$TMP/ran" ]] && { echo "  OK: nothing in the state file ran"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: the state file ran a command"; FAIL=$((FAIL+1)); }

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
