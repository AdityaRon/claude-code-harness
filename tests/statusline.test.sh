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

echo "=== Repo name from workspace.repo.name (worktree-safe, full name) ==="
OUT=$(run '{"workspace":{"repo":{"name":"lacework-security-content"},"project_dir":"/x/.claude/worktrees/spark_udf_migration"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}')
printf '%s' "$OUT" | grep -q "lacework-security-content" && pass "uses repo.name, not worktree dir" || fail "uses repo.name, not worktree dir" "$OUT"
printf '%s' "$OUT" | grep -q "spark_udf_migration" && fail "worktree dir not shown as repo" "$OUT" || pass "worktree dir not shown as repo"
OUT=$(run '{"workspace":{"project_dir":"/tmp/myproj"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}')
printf '%s' "$OUT" | grep -q "myproj" && pass "falls back to dir basename without remote" || fail "falls back to dir basename" "$OUT"

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
