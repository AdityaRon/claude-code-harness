#!/usr/bin/env bash
# Tests for notify.sh: the notification names the session, so one of several
# can be told apart.
set -u
HOOK="hooks/notify.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_eq(){ [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "expected: $2  got: $3"; }

# Prints the title line the hook would show.
title(){
  jq -nc --arg t "$1" --arg c "${2:-/work/my-repo}" \
    '{hook_event_name:"Notification",message:"Claude needs your permission to use Bash",notification_type:"permission_prompt",transcript_path:$t,cwd:$c,session_id:"s1"}' \
    | CLAUDE_NOTIFY_DRY_RUN=1 bash "$HOOK" | head -1
}
rec(){ jq -nc --arg ty "$1" --arg k "$2" --arg v "$3" '{type:$ty,($k):$v,sessionId:"s1"}'; }
filler(){ local i; for ((i = 0; i < $1; i++)); do printf '{"type":"assistant","message":{"content":"%0200d"}}\n' 0; done; }

echo "=== notify.sh ==="
{ rec ai-title aiTitle "old title"; filler 3; rec ai-title aiTitle "fix the login bug"; rec agent-name agentName "fix the login bug"; } > "$TMP/a.jsonl"
check_eq "uses the latest generated title" "Claude Code · fix the login bug" "$(title "$TMP/a.jsonl")"

{ rec custom-title customTitle "billing"; rec ai-title aiTitle "generated"; rec agent-name agentName "generated"; } > "$TMP/b.jsonl"
check_eq "a /rename title outranks the generated one" "Claude Code · billing" "$(title "$TMP/b.jsonl")"

{ rec ai-title aiTitle "early only"; filler 2000; } > "$TMP/c.jsonl"
check_eq "finds a title older than the tail window" "Claude Code · early only" "$(title "$TMP/c.jsonl")"

{ rec ai-title aiTitle "survivor"; filler 1400; rec ai-title aiTitle "recent"; } > "$TMP/d.jsonl"
check_eq "the newest title in the tail window wins" "Claude Code · recent" "$(title "$TMP/d.jsonl")"

check_eq "falls back to the folder without a transcript" "Claude Code · my-repo" "$(title "$TMP/missing.jsonl")"

rec ai-title aiTitle $'say "hi" & quit\n\tnow' > "$TMP/e.jsonl"
check_eq "keeps quotes as text and drops control characters" 'Claude Code · say "hi" & quitnow' "$(title "$TMP/e.jsonl")"

OUT=$(jq -nc '{message:"Claude is waiting for your input",cwd:"/w/r"}' | CLAUDE_NOTIFY_DRY_RUN=1 bash "$HOOK" | sed -n 2p)
check_eq "carries Claude Code's own message" "Claude is waiting for your input" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[[ $FAIL -eq 0 ]]
