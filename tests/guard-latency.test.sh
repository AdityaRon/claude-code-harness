#!/usr/bin/env bash
# Every Bash guard runs on every Bash call, so a slow one is felt everywhere.
# Short test commands cannot show it: bash 3.2's ${var//…} once took git-guard
# 30 s on an 8,000-byte command while every suite passed.
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log" CLAUDE_GUARD_TIMING_LOG="$TMP/timing.log"
export CLAUDE_SHADOW_LOG="$TMP/shadow.log"  # shadow mode lines (hooks/lib/shadow.sh), out of the real log too
LIMIT=${GUARD_LATENCY_LIMIT:-10}
PASS=0; FAIL=0

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
timed() {   # timed HOOK PAYLOAD LABEL
  local t0 t1 secs
  t0=$(now)
  # alarm caps a hang so one slow guard cannot stall doctor
  printf '%s' "$2" | perl -e 'alarm shift; exec @ARGV' $((LIMIT + 5)) bash "hooks/$1.sh" >/dev/null 2>&1
  t1=$(now)
  secs=$(perl -e "printf '%.2f', $t1 - $t0")
  if perl -e "exit !($secs < $LIMIT)"; then echo "  OK (${secs}s): $3"; PASS=$((PASS + 1))
  else echo "  FAIL (${secs}s, limit ${LIMIT}s): $3"; FAIL=$((FAIL + 1)); fi
}
each_guard() {
  local payload g
  payload=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/repo",session_id:"00000000-test"}')
  for g in env-guard git-guard interpreter-guard kubectl-guard network-guard rm-guard config-guard bash-guards tcc-check; do
    timed "$g" "$payload" "$g"
  done
}

# About 12 KB, past the early exits: git words, quotes, parens, $( and a path
# under ~/.claude, inside a commit message heredoc.
BODY=$(for i in $(seq 1 160); do
  printf 'line %d: "quoted (text)" it'\''s $(date) | git add and push to ~/.claude/x\n' "$i"
done)
CMD="cd /repo && git commit -F - <<'EOF'
$BODY
EOF"
echo "=== each Bash guard finishes a ${#CMD}-byte command in under ${LIMIT}s ==="
each_guard "$CMD"

echo ""
echo "=== tcc-check runs on every Bash result: a ${#CMD}-byte result holding its trigger, in under ${LIMIT}s ==="
# The common path is one substring test; this is the other one, jq and all.
RESP=$(jq -nc --arg s "$CMD"$'\n'"ls: /repo/x: Operation not permitted" '{stdout:$s, stderr:"", interrupted:false}')
POST=$(jq -nc --arg c "$CMD" --argjson r "$RESP" \
  '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:$c},tool_response:$r,cwd:"/repo",session_id:"00000000-test"}')
timed tcc-check "$POST" "tcc-check on a result that holds the trigger"

echo ""
# An inline script whose strings hold backticks, parens and quotes, in a
# command that names kubectl: kubectl-guard once looped forever on one.
PY=$(for i in $(seq 1 40); do
  printf 'old%d = """  e=(-e '\''s/\\\\$\\\\(/ $( /g; s/`/ ` /g'\'')"""\nprint(f"step {%d}: `make` (done)")\n' "$i" "$i"
done)
CMD="python3 - lib.sh <<'EOF'
$PY
EOF
kubectl get pods; git status; rm -f notes.tmp"
echo "=== and a ${#CMD}-byte inline python script ==="
each_guard "$CMD"

echo ""
# A shadowed ask (hooks/lib/shadow.sh) on a long heredoc, in a UTF-8 locale as on
# a Mac. With shadow_note's old ${c//…}, interpreter-guard took 155 s on this one
# under en_US.UTF-8 and 32 s under C; 0.2 s without it (bash 3.2, Apple M2, load 4
# to 7). bash 5 may not be quadratic there, so the macOS runner is the one that sees it.
U8=$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8|c\.utf-?8' | head -n 1)
PY=$(printf 'import os\nhome = os.environ.get("HOME", "")\n'; for i in $(seq 1 258); do
  printf 'row_%d = {"name": "item %d", "tags": ["a", "b"]}\n' "$i" "$i"
done)
CMD="cd /repo && python3 - <<'PY'
$PY
PY"
if [[ -z "$U8" ]]; then
  echo "  SKIP: no UTF-8 locale in locale -a, for the ${#CMD}-byte shadowed heredoc"
else
  echo "=== a shadowed ask on a ${#CMD}-byte heredoc of 260 lines under $U8, in under ${LIMIT}s ==="
  payload=$(jq -nc --arg c "$CMD" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/repo",session_id:"00000000-test",permission_mode:"auto"}')
  for g in interpreter-guard bash-guards; do
    : > "$CLAUDE_SHADOW_LOG"
    LC_ALL=$U8 timed "$g" "$payload" "$g"
    # Not a pass that skipped the slow path: the guard reached shadow_note.
    [[ "$(jq -r '.guard + ":" + .rule' "$CLAUDE_SHADOW_LOG" 2>/dev/null)" == interpreter-guard:sensitive-token ]] \
      && { echo "  OK: $g wrote its shadow line"; PASS=$((PASS + 1)); } \
      || { echo "  FAIL: $g wrote no shadow line: $(cat "$CLAUDE_SHADOW_LOG" 2>/dev/null)"; FAIL=$((FAIL + 1)); }
  done
fi

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[[ $FAIL -eq 0 ]]
