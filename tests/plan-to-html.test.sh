#!/usr/bin/env bash
# Tests for plan-to-html.sh — feeds synthetic ExitPlanMode payloads on stdin and
# asserts the rendered HTML written to $CLAUDE_PLANS_HTML_DIR. Browser launch is
# suppressed via CLAUDE_PLAN_HTML_NO_OPEN=1 so the suite never opens a window.
set -u
HOOK="hooks/plan-to-html.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLANS_HTML_DIR="$TMP/plans-html"
export CLAUDE_PLAN_HTML_NO_OPEN=1

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

check_eq() {
  local label="$1" expect="$2" got="$3"
  if [[ "$got" == "$expect" ]]; then pass "$label"; else fail "$label" "expect=$expect got=$got"; fi
}

# Run the hook with a given tool_name + plan, return path to newest html file.
run_hook() {
  local tool="$1" plan="$2"
  local payload
  payload=$(jq -nc --arg t "$tool" --arg p "$plan" \
    '{tool_name:$t, tool_input:{plan:$p}, hook_event_name:"PreToolUse"}')
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
}

newest() { ls -1t "$CLAUDE_PLANS_HTML_DIR"/plan-*.html 2>/dev/null | head -1; }

echo "=== Renders a plan to HTML ==="
run_hook "ExitPlanMode" $'# My Plan\n\n- step one\n- step two\n\nUse an em-dash — and a checkmark ✓.'
OUT=$(newest)
if [[ -n "$OUT" && -f "$OUT" ]]; then pass "html file written"; else fail "html file written" "dir=$CLAUDE_PLANS_HTML_DIR"; echo "--- Results: $PASS passed, $((FAIL+1)) failed ---"; exit $((FAIL+1)); fi
grep -q "marked.parse" "$OUT" && pass "uses marked renderer" || fail "uses marked renderer" ""
grep -q "marked.min.js" "$OUT" && pass "loads marked from CDN" || fail "loads marked from CDN" ""
grep -q "TextDecoder" "$OUT" && pass "decodes as UTF-8" || fail "decodes as UTF-8" ""
grep -q 'window.marked' "$OUT" && grep -q 'createElement("pre")' "$OUT" && pass "has offline fallback" || fail "has offline fallback" ""

echo ""
echo "=== Base64 round-trips the markdown (incl. non-ASCII) ==="
B64=$(grep -oE 'atob\("[^"]+"\)' "$OUT" | sed -E 's/atob\("([^"]+)"\)/\1/')
DECODED=$(printf '%s' "$B64" | base64 --decode 2>/dev/null)
echo "$DECODED" | grep -q "em-dash — and a checkmark ✓" && pass "non-ASCII survives base64" || fail "non-ASCII survives base64" "decoded=$DECODED"
echo "$DECODED" | grep -q "# My Plan" && pass "markdown body preserved" || fail "markdown body preserved" ""

echo ""
echo "=== Embedded markdown cannot break out of the script tag ==="
rm -f "$CLAUDE_PLANS_HTML_DIR"/plan-*.html
run_hook "ExitPlanMode" 'evil </script><script>alert(1)</script> plan'
OUT2=$(newest)
# The injected </script> must NOT appear literally in the file — it is base64'd.
if grep -q "alert(1)" "$OUT2"; then fail "no raw script injection" "found literal payload"; else pass "no raw script injection"; fi

echo ""
echo "=== Non-ExitPlanMode tool is ignored ==="
rm -f "$CLAUDE_PLANS_HTML_DIR"/plan-*.html
run_hook "Bash" "ls -la"
if [[ -z "$(newest)" ]]; then pass "ignores non-ExitPlanMode tool"; else fail "ignores non-ExitPlanMode tool" "file created"; fi

echo ""
echo "=== Empty plan is ignored ==="
rm -f "$CLAUDE_PLANS_HTML_DIR"/plan-*.html
run_hook "ExitPlanMode" ""
if [[ -z "$(newest)" ]]; then pass "ignores empty plan"; else fail "ignores empty plan" "file created"; fi

echo ""
echo "=== Hook never blocks (emits no deny/ask JSON) ==="
payload=$(jq -nc '{tool_name:"ExitPlanMode", tool_input:{plan:"# p"}, hook_event_name:"PreToolUse"}')
HOOK_OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
if printf '%s' "$HOOK_OUT" | grep -q "permissionDecision"; then fail "no permission decision emitted" "got=$HOOK_OUT"; else pass "no permission decision emitted"; fi

echo ""
echo "=== Retention: keeps newest 50 ==="
rm -f "$CLAUDE_PLANS_HTML_DIR"/plan-*.html
# Seed 55 stale files with old, distinct timestamps (2020-01-01 00:mm) so sort
# order is deterministic. Vary minutes (00..54) to keep every timestamp valid.
i=0
for mm in $(seq -w 0 54); do
  i=$((i+1))
  touch -t "2020010100${mm}" "$CLAUDE_PLANS_HTML_DIR/plan-stale-$i.html" 2>/dev/null
done
# Hook prunes plan-*.html down to newest 50 on its next run.
run_hook "ExitPlanMode" "# trigger prune"
COUNT=$(ls -1 "$CLAUDE_PLANS_HTML_DIR"/plan-*.html 2>/dev/null | wc -l | tr -d ' ')
check_eq "retention cap" "50" "$COUNT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
