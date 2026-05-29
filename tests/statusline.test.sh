#!/usr/bin/env bash
# Tests for statusline.sh — verifies the base line renders and the session
# plan link appears only when a live pointer exists.
set -u
HOOK="statusline.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLAN_STATE_DIR="$TMP/plans"
mkdir -p "$CLAUDE_PLAN_STATE_DIR"
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
run(){ printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }

echo "=== Base line renders ==="
OUT=$(run '{"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":42}}')
printf '%s' "$OUT" | grep -q "Opus 4.8" && pass "shows model" || fail "shows model" "$OUT"
printf '%s' "$OUT" | grep -q "42%" && pass "shows percent" || fail "shows percent" "$OUT"

echo "=== Repo name abbreviated when long ==="
OUT=$(run '{"workspace":{"project_dir":"/x/lacework-security-content"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}')
printf '%s' "$OUT" | grep -q "lsc" && pass "long repo name acronymized" || fail "long repo name acronymized" "$OUT"

echo ""
echo "=== Rate-limit segment shows only when present ==="
OUT=$(run '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":3},"rate_limits":{"five_hour":{"used_percentage":63},"seven_day":{"used_percentage":21}}}')
printf '%s' "$OUT" | grep -q "5h:63%" && pass "rate limit shown when present" || fail "rate limit shown when present" "$OUT"
OUT=$(run '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}')
printf '%s' "$OUT" | grep -q "5h:" && fail "no rate limit when absent" "$OUT" || pass "no rate limit when absent"

echo ""
echo "=== Plan link appears when a pointer exists ==="
PLAN="$TMP/plan-x.html"; echo "<html></html>" > "$PLAN"
echo "$PLAN" > "$CLAUDE_PLAN_STATE_DIR/sess-1.path"
OUT=$(run '{"session_id":"sess-1","model":{"display_name":"Opus"},"context_window":{"used_percentage":5}}')
printf '%s' "$OUT" | grep -q "plan" && pass "plan label present" || fail "plan label present" "$OUT"
printf '%s' "$OUT" | grep -qF "$PLAN" && pass "links to plan path" || fail "links to plan path" "$OUT"
printf '%s' "$OUT" | grep -qF "8;;file://" && pass "uses OSC-8 hyperlink" || fail "uses OSC-8 hyperlink" "$OUT"

echo ""
echo "=== No plan segment without a pointer ==="
OUT=$(run '{"session_id":"no-such","model":{"display_name":"Opus"},"context_window":{"used_percentage":5}}')
printf '%s' "$OUT" | grep -q "plan" && fail "no segment without pointer" "$OUT" || pass "no segment without pointer"

echo ""
echo "=== No plan segment for a dangling pointer (target deleted) ==="
echo "$TMP/gone.html" > "$CLAUDE_PLAN_STATE_DIR/sess-2.path"
OUT=$(run '{"session_id":"sess-2","model":{"display_name":"Opus"},"context_window":{"used_percentage":5}}')
printf '%s' "$OUT" | grep -q "plan" && fail "no segment for dangling pointer" "$OUT" || pass "no segment for dangling pointer"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
