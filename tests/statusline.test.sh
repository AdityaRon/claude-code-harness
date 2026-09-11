#!/usr/bin/env bash
# Tests for statusline.sh — verifies the base line renders and the session
# plan link appears only when a live pointer exists.
set -u
HOOK="bin/statusline.sh"
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
OUT=$(run '{"workspace":{"repo":{"name":"acme-security-content"},"project_dir":"/x/.claude/worktrees/some_feature_branch"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}')
printf '%s' "$OUT" | grep -q "acme-security-content" && pass "uses repo.name, not worktree dir" || fail "uses repo.name, not worktree dir" "$OUT"
printf '%s' "$OUT" | grep -q "some_feature_branch" && fail "worktree dir not shown as repo" "$OUT" || pass "worktree dir not shown as repo"
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
echo "=== Workflow link appears when a workflow pointer exists ==="
export CLAUDE_WORKFLOW_STATE_DIR="$TMP/wf"; mkdir -p "$CLAUDE_WORKFLOW_STATE_DIR"
export CLAUDE_EDITOR_URI="testeditor://file"
WF="$TMP/run.js"; echo "// wf" > "$WF"
echo "$WF" > "$CLAUDE_WORKFLOW_STATE_DIR/sess-1.path"
OUT=$(run '{"session_id":"sess-1","model":{"display_name":"Opus"},"context_window":{"used_percentage":5}}')
printf '%s' "$OUT" | grep -q "wf" && pass "wf segment present" || fail "wf segment present" "$OUT"
printf '%s' "$OUT" | grep -qF "testeditor://file$WF" && pass "wf opens via editor URI" || fail "wf opens via editor URI" "$OUT"

echo ""
echo "=== No plan segment without a pointer ==="
OUT=$(run '{"session_id":"no-such","model":{"display_name":"Opus"},"context_window":{"used_percentage":5}}')
printf '%s' "$OUT" | grep -q "plan" && fail "no segment without pointer" "$OUT" || pass "no segment without pointer"

echo ""
echo "=== No plan segment for a dangling pointer (target deleted) ==="
echo "$TMP/gone.html" > "$CLAUDE_PLAN_STATE_DIR/sess-2.path"
OUT=$(run '{"session_id":"sess-2","model":{"display_name":"Opus"},"context_window":{"used_percentage":5}}')
printf '%s' "$OUT" | grep -q "plan" && fail "no segment for dangling pointer" "$OUT" || pass "no segment for dangling pointer"

strip(){ printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

echo ""
echo "=== Cost rounds to cents, stable 2 decimals ==="
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"cost":{"total_cost_usd":4.35}}')")
printf '%s' "$OUT" | grep -qF '$4.35' && pass "4.35 -> \$4.35 (no floor off-by-cent)" || fail "cost 4.35" "$OUT"
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"cost":{"total_cost_usd":2}}')")
printf '%s' "$OUT" | grep -qF '$2.00' && pass "2 -> \$2.00 (two decimals)" || fail "cost 2" "$OUT"

echo ""
echo "=== Cost prefixed ~\$ on subscription (rate_limits present), plain \$ otherwise ==="
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":10}}}')")
printf '%s' "$OUT" | grep -qF '~$1.50' && pass "rate-limited -> ~\$" || fail "estimated cost marker" "$OUT"
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"cost":{"total_cost_usd":1.5}}')")
printf '%s' "$OUT" | grep -qF '~$' && fail "no tilde without rate limits" "$OUT" || pass "API account -> plain \$"

echo ""
echo "=== Rate-limit segment colors near the cap; shows if either window present ==="
OUT=$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"rate_limits":{"five_hour":{"used_percentage":93}}}')
printf '%s' "$OUT" | grep -q $'\x1b\[31m5h:93%' && pass "red at >=90%" || fail "rate limit red near cap" "$(strip "$OUT")"
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"rate_limits":{"seven_day":{"used_percentage":40}}}')")
printf '%s' "$OUT" | grep -q '5h:0% 7d:40%' && pass "shows when only seven_day present" || fail "seven_day only" "$OUT"

echo ""
echo "=== Lines +added/-removed shown when non-zero, hidden at 0/0 ==="
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"cost":{"total_lines_added":12,"total_lines_removed":3}}')")
printf '%s' "$OUT" | grep -qF '+12/-3' && pass "lines shown" || fail "lines shown" "$OUT"
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"cost":{"total_lines_added":0,"total_lines_removed":0}}')")
printf '%s' "$OUT" | grep -qE '\+0/-0' && fail "lines hidden at 0/0" "$OUT" || pass "lines hidden at 0/0"

echo ""
echo "=== Non-default output style surfaced, default hidden ==="
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"output_style":{"name":"Explanatory"}}')")
printf '%s' "$OUT" | grep -qF 'style:Explanatory' && pass "non-default style shown" || fail "style shown" "$OUT"
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":1},"output_style":{"name":"default"}}')")
printf '%s' "$OUT" | grep -qF 'style:' && fail "default style hidden" "$OUT" || pass "default style hidden"

echo ""
echo "=== Context bar clamped to 10 cells above 100% ==="
OUT=$(strip "$(run '{"model":{"display_name":"O"},"context_window":{"used_percentage":130}}')")
CELLS=$(printf '%s' "$OUT" | grep -oE '(▓|░)+' | head -1)
[[ "$(printf '%s' "$CELLS" | grep -o '▓' | wc -l | tr -d ' ')" == "10" ]] && pass "bar clamped to 10 at 130%" || fail "bar clamp" "$OUT"

echo ""
echo "=== jq-missing / unparseable -> visible fallback, never blank ==="
OUT=$(printf 'not json' | bash "$HOOK" 2>/dev/null)
[[ -n "$OUT" ]] && pass "non-blank on bad input" || fail "fallback blank" "[$OUT]"

echo ""
echo "=== Branch read from .git/HEAD (subprocess-free), incl. session_id empty + cdir present ==="
REPO="$TMP/fakerepo"; mkdir -p "$REPO/.git"
# Build the payload in a variable — a literal {..,..,..} passed inline would be
# brace-expanded into comma-separated words by the shell before run() sees it.
PAY="{\"model\":{\"display_name\":\"O\"},\"context_window\":{\"used_percentage\":1},\"workspace\":{\"current_dir\":\"$REPO\"}}"
printf 'ref: refs/heads/feature/x\n' > "$REPO/.git/HEAD"
OUT=$(strip "$(run "$PAY")")
printf '%s' "$OUT" | grep -qF ':feature/x' && pass "branch from HEAD with empty session_id (no field-collapse)" || fail "branch/cdir field-collapse" "$OUT"
printf 'deadbeef1234\n' > "$REPO/.git/HEAD"
OUT=$(strip "$(run "$PAY")")
printf '%s' "$OUT" | grep -qF ':deadbee' && pass "detached HEAD -> short SHA" || fail "detached HEAD" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
