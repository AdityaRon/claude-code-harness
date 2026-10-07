#!/usr/bin/env bash
# Tests for session-snapshot.sh — feeds synthetic transcripts on stdin and
# asserts the snapshot JSON written to $CLAUDE_STATE_DIR.
set -u
HOOK="hooks/session-snapshot.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_STATE_DIR="$TMP/state"
WORK="$TMP/work"
mkdir -p "$WORK"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

check_eq() {
  local label="$1" expect="$2" got="$3"
  if [[ "$got" == "$expect" ]]; then pass "$label"; else fail "$label" "expect=$expect got=$got"; fi
}

run_hook() {
  local sid="$1" tpath="$2" cwd="$3"
  local payload
  payload=$(jq -nc --arg sid "$sid" --arg t "$tpath" --arg c "$cwd" \
    '{session_id:$sid, transcript_path:$t, cwd:$c, hook_event_name:"Stop"}')
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
}

echo "=== Basic snapshot creation ==="
printf 'alpha\n' > "$WORK/a.txt"
printf 'beta\n'  > "$WORK/b.txt"

T1="$TMP/t1.jsonl"
{
  jq -nc --arg p "$WORK/a.txt" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"1",name:"Edit",input:{file_path:$p,old_string:"x",new_string:"y"}}]}}'
  jq -nc --arg p "$WORK/b.txt" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"2",name:"Write",input:{file_path:$p,content:"beta"}}]}}'
  jq -nc '{type:"user",message:{role:"user",content:"just chatting"}}'
} > "$T1"

run_hook "sess-basic" "$T1" "$WORK"
SNAP="$CLAUDE_STATE_DIR/sess-basic.json"
if [[ -f "$SNAP" ]]; then pass "snapshot file written"; else fail "snapshot file written" "path=$SNAP"; exit 1; fi
check_eq "session_id"           "sess-basic"                  "$(jq -r '.session_id' "$SNAP")"
check_eq "edited_files length"  "2"                           "$(jq -r '.edited_files | length' "$SNAP")"
EXPECTED_A=$(shasum -a 256 "$WORK/a.txt" | awk '{print $1}')
check_eq "a.txt hash matches disk" "$EXPECTED_A" \
  "$(jq -r --arg p "$WORK/a.txt" '.edited_files[] | select(.path==$p) | .sha256' "$SNAP")"
check_eq "a.txt exists=true"    "true" \
  "$(jq -r --arg p "$WORK/a.txt" '.edited_files[] | select(.path==$p) | .exists' "$SNAP")"

echo ""
echo "=== Missing file recorded as exists=false ==="
T2="$TMP/t2.jsonl"
jq -nc --arg p "$WORK/gone.txt" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"1",name:"Edit",input:{file_path:$p,old_string:"x",new_string:"y"}}]}}' > "$T2"
run_hook "sess-missing" "$T2" "$WORK"
check_eq "missing file exists=false" "false" \
  "$(jq -r '.edited_files[0].exists' "$CLAUDE_STATE_DIR/sess-missing.json")"
check_eq "missing file empty hash"   "" \
  "$(jq -r '.edited_files[0].sha256' "$CLAUDE_STATE_DIR/sess-missing.json")"

echo ""
echo "=== Dedup: same file edited twice → one entry ==="
T3="$TMP/t3.jsonl"
{
  jq -nc --arg p "$WORK/a.txt" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"1",name:"Edit",input:{file_path:$p,old_string:"x",new_string:"y"}}]}}'
  jq -nc --arg p "$WORK/a.txt" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"2",name:"Edit",input:{file_path:$p,old_string:"y",new_string:"z"}}]}}'
} > "$T3"
run_hook "sess-dedup" "$T3" "$WORK"
check_eq "dedup length" "1" "$(jq -r '.edited_files | length' "$CLAUDE_STATE_DIR/sess-dedup.json")"

echo ""
echo "=== Non-Edit tool_use is ignored ==="
T4="$TMP/t4.jsonl"
{
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"1",name:"Bash",input:{command:"ls"}}]}}'
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"2",name:"Read",input:{file_path:"/etc/hosts"}}]}}'
} > "$T4"
run_hook "sess-nonedit" "$T4" "$WORK"
check_eq "no edits → empty array" "0" "$(jq -r '.edited_files | length' "$CLAUDE_STATE_DIR/sess-nonedit.json")"

echo ""
echo "=== Bail-out paths ==="
# No transcript path
payload=$(jq -nc '{session_id:"sess-no-t", transcript_path:"", cwd:"/tmp", hook_event_name:"Stop"}')
printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
if [[ ! -f "$CLAUDE_STATE_DIR/sess-no-t.json" ]]; then pass "no snapshot without transcript"; else fail "no snapshot without transcript" ""; fi
# No session id
payload=$(jq -nc --arg t "$T1" '{session_id:"", transcript_path:$t, cwd:"/tmp", hook_event_name:"Stop"}')
printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
if [[ ! -f "$CLAUDE_STATE_DIR/.json" ]]; then pass "no snapshot without session_id"; else fail "no snapshot without session_id" ""; fi

echo ""
echo "=== Snapshot permissions are 0600 ==="
# GNU stat (-c) first, then BSD stat (-f) fallback. BSD stat cleanly rejects
# -c and falls through, but GNU stat treats -f as filesystem mode without
# failing, so BSD-first yields empty output on Linux.
PERMS=$(stat -c %a "$CLAUDE_STATE_DIR/sess-basic.json" 2>/dev/null || stat -f %A "$CLAUDE_STATE_DIR/sess-basic.json" 2>/dev/null)
check_eq "snapshot perms" "600" "$PERMS"

echo ""
echo "=== Async-safe: atomic write, wired async on Stop and sync on SessionEnd ==="
T9="$TMP/t9.jsonl"; : > "$T9"
run_hook "sess-atomic" "$T9" "$WORK"
check_eq "no partial file left behind" "0" "$(find "$CLAUDE_STATE_DIR" -name '*.part.*' | wc -l | tr -d ' ')"
printf 'not json' > "$CLAUDE_STATE_DIR/sess-atomic.json"
run_hook "sess-atomic" "$T9" "$WORK"
check_eq "a rerun replaces a damaged snapshot with valid JSON" "sess-atomic" "$(jq -r .session_id "$CLAUDE_STATE_DIR/sess-atomic.json" 2>/dev/null)"
SETTINGS="config/settings.json"
check_eq "Stop runs the snapshot async" "true" \
  "$(jq -r '[.hooks.Stop[].hooks[] | select(.command | endswith("session-snapshot.sh")) | .async] | first // false' "$SETTINGS")"
check_eq "SessionEnd runs the snapshot synchronously" "false" \
  "$(jq -r '[.hooks.SessionEnd[].hooks[] | select(.command | endswith("session-snapshot.sh")) | (.async // false | tostring)] | first // "missing"' "$SETTINGS")"

echo ""
echo ""
echo "=== notebook edits and a subagent's edits are recorded ==="
printf 'nb\n' > "$WORK/n.ipynb"; printf 'sub\n' > "$WORK/s.txt"
T5="$TMP/t5.jsonl"; mkdir -p "$TMP/t5/subagents"
jq -nc --arg p "$WORK/n.ipynb" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"9",name:"NotebookEdit",input:{notebook_path:$p,new_source:"x"}}]}}' > "$T5"
jq -nc --arg p "$WORK/s.txt" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"8",name:"Write",input:{file_path:$p,content:"sub"}}]}}' > "$TMP/t5/subagents/agent-1.jsonl"
run_hook "sess-nb" "$T5" "$WORK"
P=$(jq -r '[.edited_files[].path] | join(",")' "$CLAUDE_STATE_DIR/sess-nb.json")
[[ "$P" == *"n.ipynb"* ]] && pass "notebook_path recorded" || fail "notebook_path recorded" "$P"
[[ "$P" == *"s.txt"* ]] && pass "a subagent's write recorded" || fail "subagent write recorded" "$P"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
