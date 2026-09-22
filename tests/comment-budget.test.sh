#!/usr/bin/env bash
# Tests for comment-budget.sh — the public-harness half of the comment-length
# check. It is LENGTH ONLY: no ticket-key check, because this repo is public
# and must never encode a work ticket prefix, unlike the committed
# .claude/hooks/comment-budget.py three work repos ship for themselves.
set -u
HOOK="hooks/comment-budget.sh"
PASS=0; FAIL=0

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }

# edit_payload <path> <old> <new> [tool] — the Edit/Write-shaped JSON on stdout.
edit_payload() {
  jq -nc --arg p "$1" --arg o "$2" --arg n "$3" --arg t "${4:-Edit}" \
    '{tool_name:$t, tool_input:{file_path:$p, old_string:$o, new_string:$n}}'
}
write_payload() {  # write_payload <path> <content>
  jq -nc --arg p "$1" --arg c "$2" \
    '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}'
}
multi_payload() {  # multi_payload <path> <o1> <n1> <o2> <n2>
  jq -nc --arg p "$1" --arg o1 "$2" --arg n1 "$3" --arg o2 "$4" --arg n2 "$5" \
    '{tool_name:"MultiEdit", tool_input:{file_path:$p,
       edits:[{old_string:$o1,new_string:$n1},{old_string:$o2,new_string:$n2}]}}'
}

# run <payload...> — feeds the payload to the hook, prints its stderr.
run()    { printf '%s' "$1" | bash "$HOOK" 2>&1; }
# run_rc <payload...> — same, but prints only the exit code.
run_rc() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }

LONG7=$(printf '# a\n# b\n# c\n# d\n# e\n# f\n# g\nx = 1\n')
SHORT=$(printf '# just one line\nx = 1\n')
HEADER8=$(printf '#!/usr/bin/env python3\n# a\n# b\n# c\n# d\n# e\n# f\n# g\n# h\nx = 1\n')

echo "=== a long comment block ADDED is flagged and exits 2 ==="
P=$(edit_payload "f.py" "x = 1" "$LONG7")
OUT=$(run "$P")
check_contains "names the file and the count" "f.py: added an 7-line comment block" "$OUT"
check_contains "tells where rationale belongs" "PR body" "$OUT"
check_eq       "exits 2" "2" "$(run_rc "$P")"

echo ""
echo "=== a short comment is silent ==="
P=$(edit_payload "f.py" "x = 1" "$SHORT")
check_eq "silent" ""  "$(run "$P")"
check_eq "exit 0" "0" "$(run_rc "$P")"

echo ""
echo "=== an existing long block, untouched, is not re-flagged ==="
P=$(edit_payload "f.py" "$LONG7" "${LONG7}y = 2")
check_eq "silent — inherited, not introduced" "" "$(run "$P")"
check_eq "exit 0" "0" "$(run_rc "$P")"

echo ""
echo "=== markdown is not a code file ==="
P=$(write_payload "notes.md" "$LONG7")
check_eq "silent" "" "$(run "$P")"
check_eq "exit 0" "0" "$(run_rc "$P")"

echo ""
echo "=== Write of a new file with an 8-line header is flagged ==="
P=$(write_payload "new.py" "$HEADER8")
check_contains "flags the count, shebang excluded from it" "added an 8-line comment block" "$(run "$P")"
check_eq       "exit 2" "2" "$(run_rc "$P")"

echo ""
echo "=== MultiEdit with one offending edit among several is flagged ==="
P=$(multi_payload "f.py" "x = 1" "y = 2" "z = 3" "$LONG7")
check_contains "flagged from the offending edit" "added an 7-line comment block" "$(run "$P")"
check_eq       "exit 2" "2" "$(run_rc "$P")"

echo ""
echo "=== a repo shipping its own comment-budget.py is left to it, silently ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks"
: > "$TMP/.claude/hooks/comment-budget.py"
P=$(write_payload "f.py" "$HEADER8")
check_eq "silent — the repo's own hook owns this" "" "$(CLAUDE_PROJECT_DIR="$TMP" run "$P")"
check_eq "exit 0" "0" "$(CLAUDE_PROJECT_DIR="$TMP" run_rc "$P")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
