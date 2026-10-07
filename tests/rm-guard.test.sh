#!/usr/bin/env bash
# Tests for rm-guard.sh
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"
HOOK="$PWD/hooks/rm-guard.sh"
export HOME="$TMP/home" TMPDIR="$TMP/t"
SID="abcd1234-0000-4000-8000-000000000000"
S="$HOME/.claude/jobs/abcd1234/tmp"
mkdir -p "$S" "$TMPDIR"
PASS=0; FAIL=0

check() {
  local label="$1" expect="$2" cmd="$3" cwd="${4:-$TMP}" sid="${5:-$SID}" got out rc
  out=$(jq -nc --arg c "$cmd" --arg d "$cwd" --arg s "$sid" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' \
    | bash "$HOOK" 2>/dev/null); rc=$?
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
  [[ -z "$got" ]] && got=allow
  [[ $rc -ne 0 ]] && got="exit $rc"
  if [[ "$got" == "$expect" ]]; then echo "  OK ($expect): $label"; PASS=$((PASS+1))
  else echo "  FAIL (expected=$expect got=$got): $label  [cmd: $cmd]"; FAIL=$((FAIL+1)); fi
}

echo "=== catastrophic targets deny, -f or not ==="
check "rm -rf /"                  deny 'rm -rf /'
check "rm -rf ~"                  deny 'rm -rf ~'
check "rm -rf \$HOME"             deny 'rm -rf "$HOME"'
check "rm -rf ."                  deny 'rm -rf .'
check "rm -rf .."                 deny 'rm -rf ..'
check "rm -rf *"                  deny 'rm -rf *'
check "rm -r /usr, no -f"         deny 'rm -r /usr'
check "sudo rm -rf /etc"          deny 'sudo rm -rf /etc'
check "/bin/rm -rf ~/"            deny '/bin/rm -rf ~/'

echo ""
echo "=== rm -rf outside this session's scratch folder denies, every spelling ==="
check "rm -fr build/"             deny 'rm -fr build/'
check "rm -r -f build"            deny 'rm -r -f build'
check "rm -Rf ~/projects"         deny 'rm -Rf ~/projects'
check "--recursive --force"       deny 'rm --recursive --force out'
check "after xargs: no target"    deny 'find . -name "*.o" | xargs rm -rf'
check "cd elsewhere first"        deny 'cd /tmp && rm -rf x'
check "the job folder itself"     deny 'rm -rf "$CLAUDE_JOB_DIR"'
check "job state, not scratch"    deny 'rm -rf "$CLAUDE_JOB_DIR/state.json"'
check "climbs out with .."        deny 'rm -rf "$CLAUDE_JOB_DIR/tmp/../.."'
check "redefines CLAUDE_JOB_DIR"  deny 'CLAUDE_JOB_DIR=/ rm -rf "$CLAUDE_JOB_DIR/tmp/x"'
check "unknown variable"          deny 'rm -rf "$X/y"'
check "second segment"            deny 'echo ok; rm -rf build'
check "TMPDIR itself"             deny 'rm -rf "$TMPDIR"'
check "another session's scratch" deny 'rm -rf ~/.claude/jobs/ffffffff/tmp/x'
check "no scratch: interactive"   deny 'rm -rf "$CLAUDE_JOB_DIR/tmp/x"' "$TMP" "not-a-session-id"

echo ""
echo "=== rm -rf inside this session's scratch folder runs ==="
check "\$CLAUDE_JOB_DIR/tmp/x"     allow 'rm -rf "$CLAUDE_JOB_DIR/tmp/x"'
check "\${CLAUDE_JOB_DIR}/tmp/x"   allow 'rm -rf ${CLAUDE_JOB_DIR}/tmp/x'
check "~/.claude/jobs/<id>/tmp"    allow 'rm -rf ~/.claude/jobs/abcd1234/tmp/wt-1'
check "literal path"               allow "rm -rf $S/pf-replay"
check "glob inside scratch"        allow 'rm -rf "$CLAUDE_JOB_DIR/tmp/"pf-*'
check "J=…; rm -rf \$J/x"          allow 'J=$CLAUDE_JOB_DIR/tmp; rm -rf $J/net/combo'
check "T=literal; two targets"     allow "T=$S; rm -rf \"\$T/a\" \"\$T/b\""
check "cd scratch && relative"     allow 'cd "$CLAUDE_JOB_DIR/tmp" && rm -rf old'
check "cwd is scratch, relative"   allow 'rm -rf old' "$S"
check "inside TMPDIR"              allow 'rm -rf "$TMPDIR/tmp.abc"'
check "the scratch folder itself"  allow 'rm -rf "$CLAUDE_JOB_DIR/tmp"'

echo ""
echo "=== not a recursive force remove: untouched ==="
check "rm -r build, no -f"         allow 'rm -r build'
check "rm -f file"                 allow 'rm -f notes.txt'
check "git rm -rf --cached"        allow 'git rm -rf --cached vendor'
check "grep for the text"          allow 'grep -rn "rm -rf" docs/'
check "echo the text"              allow "echo 'rm -rf /'"
check "quoted ; in a commit msg"   allow "git commit -m 'drop rm -rf; use the guard'"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
