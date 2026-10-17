#!/usr/bin/env bash
# Tests for .github/close-superseded.sh, with a fake gh on PATH.
set -u
SCRIPT=".github/close-superseded.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_eq(){ if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=[$2] got=[$3]"; fi; }
check_contains(){ case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected [$2] in [$3]" ;; esac; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") [ -z "${FAKE_LIST_FAIL:-}" ] || exit 1; cat "$FAKE_DIR/list.json" ;;
  "pr close") printf '%s\n' "$*" >> "$FAKE_DIR/calls.log"; [ "$3" != "${FAKE_CLOSE_FAIL:-}" ] ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export FAKE_DIR="$TMP"

bot(){ printf '{"number":%s,"headRefName":"%s","author":{"login":"app/github-actions","is_bot":true}}' "$1" "$2"; }
cat > "$TMP/list.json" <<EOF
[ $(bot 90 claude/contract-2.1.300),
  $(bot 88 claude/contract-2.1.99),
  $(bot 89 claude/contract-2.1.299),
  {"number":96,"headRefName":"claude/contract-2.1.200","author":{"login":"github-actions[bot]"}},
  {"number":75,"headRefName":"claude/contract-2.1.296","author":{"login":"AdityaRon","is_bot":false}},
  $(bot 91 claude/contract-2.1.301),
  $(bot 92 drift-autoland),
  $(bot 93 claude/contract-2.1.250-retry) ]
EOF

# run <version> <new PR>: prints the script's output; RC holds its exit code.
run(){ : > "$TMP/calls.log"; OUT=$(PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1); RC=$?; }
closed(){ awk '{print $3}' "$TMP/calls.log" | sort -n | tr '\n' ' '; }

echo "=== closes only older bot contract PRs, numerically ==="
run 2.1.300 90
check_eq "exit 0" "0" "$RC"
check_eq "closes 2.1.99, 2.1.200 (REST login) and 2.1.299" "88 89 96 " "$(closed)"
grep -q ' 75 ' "$TMP/calls.log" && fail "a person's PR is untouched" "#75 closed" || pass "a person's PR is untouched"
grep -q ' 91 ' "$TMP/calls.log" && fail "a newer release is untouched" "#91 closed" || pass "a newer release is untouched"
check_eq "every close deletes the branch" "3" "$(grep -c -- '--delete-branch' "$TMP/calls.log")"
check_eq "every close links the new PR" "3" "$(grep -c 'Superseded by #90,' "$TMP/calls.log")"

echo ""
echo "=== the same version is not older ==="
run 2.1.300 999
check_eq "#90 (2.1.300) stays open" "88 89 96 " "$(closed)"

echo ""
echo "=== failures warn and exit 0 ==="
FAKE_CLOSE_FAIL=88 run 2.1.300 90
check_eq "exit 0 when a close fails" "0" "$RC"
check_contains "warns about #88" "::warning::close-superseded: could not close #88" "$OUT"
check_eq "the others are still closed" "88 89 96 " "$(closed)"
FAKE_LIST_FAIL=1 run 2.1.300 90
check_eq "exit 0 when the list fails" "0" "$RC"
check_contains "warns that nothing was closed" "could not list open PRs" "$OUT"
check_eq "nothing closed" "" "$(closed)"
run latest 90
check_eq "exit 0 on a bad version" "0" "$RC"
check_eq "nothing closed on a bad version" "" "$(closed)"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
