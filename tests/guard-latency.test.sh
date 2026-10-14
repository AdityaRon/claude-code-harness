#!/usr/bin/env bash
# Every Bash guard runs on every Bash call, so a slow one is felt everywhere.
# Short test commands cannot show it: bash 3.2's ${var//…} once took git-guard
# 30 s on an 8,000-byte command while every suite passed.
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"
LIMIT=${GUARD_LATENCY_LIMIT:-10}
PASS=0; FAIL=0

# About 12 KB, past the early exits: git words, quotes, parens, $( and a path
# under ~/.claude, inside a commit message heredoc.
BODY=$(for i in $(seq 1 160); do
  printf 'line %d: "quoted (text)" it'\''s $(date) | git add and push to ~/.claude/x\n' "$i"
done)
CMD="cd /repo && git commit -F - <<'EOF'
$BODY
EOF"
PAYLOAD=$(jq -nc --arg c "$CMD" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/repo",session_id:"00000000-test"}')

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
echo "=== each Bash guard finishes a ${#CMD}-byte command in under ${LIMIT}s ==="
for g in env-guard git-guard interpreter-guard kubectl-guard network-guard rm-guard config-guard; do
  t0=$(now)
  # alarm caps a hang so one slow guard cannot stall doctor
  printf '%s' "$PAYLOAD" | perl -e 'alarm shift; exec @ARGV' $((LIMIT + 5)) bash "hooks/$g.sh" >/dev/null 2>&1
  t1=$(now)
  secs=$(perl -e "printf '%.2f', $t1 - $t0")
  if perl -e "exit !($secs < $LIMIT)"; then echo "  OK (${secs}s): $g"; PASS=$((PASS + 1))
  else echo "  FAIL (${secs}s, limit ${LIMIT}s): $g"; FAIL=$((FAIL + 1)); fi
done

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[[ $FAIL -eq 0 ]]
