#!/usr/bin/env bash
# Tests for merge-settings.jq — the filter install.sh runs when merging the
# harness settings into an existing ~/.claude/settings.json.
#
# The load-bearing case: a machine already carrying permissions.defaultMode
# ("default", from a previous install or the /config UI) must end up on the
# harness value, since a plain `$new * $old` merge lets the stale value win.
set -u
FILTER="merge-settings.jq"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

# merge OLD_JSON NEW_JSON -> merged JSON on stdout
merge(){
  printf '%s' "$1" > "$TMP/old.json"
  printf '%s' "$2" > "$TMP/new.json"
  jq -s -f "$FILTER" "$TMP/old.json" "$TMP/new.json"
}

HARNESS='{
  "permissions": {"defaultMode":"auto","allow":["Bash(ls:*)"],"deny":["Bash(sudo:*)"]},
  "hooks": {"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/audit.sh"}]}]},
  "statusLine": {"type":"command","command":"~/.claude/statusline.sh"},
  "effortLevel": "xhigh"
}'

echo "=== A stale permissions.defaultMode is replaced by the harness value ==="
OUT=$(merge '{"permissions":{"defaultMode":"default"}}' "$HARNESS")
[[ "$(printf '%s' "$OUT" | jq -r '.permissions.defaultMode')" == "auto" ]] \
  && pass "stale defaultMode overridden" || fail "stale defaultMode overridden" "$OUT"

echo ""
echo "=== defaultMode is set when the user had none ==="
OUT=$(merge '{"env":{"FOO":"bar"}}' "$HARNESS")
[[ "$(printf '%s' "$OUT" | jq -r '.permissions.defaultMode')" == "auto" ]] \
  && pass "defaultMode installed fresh" || fail "defaultMode installed fresh" "$OUT"

echo ""
echo "=== No null defaultMode key when the source has dropped it ==="
OUT=$(merge '{"permissions":{"allow":[]}}' '{"permissions":{"allow":[]},"hooks":{},"statusLine":{}}')
[[ "$(printf '%s' "$OUT" | jq -r '.permissions | has("defaultMode")')" == "false" ]] \
  && pass "no null defaultMode written" || fail "no null defaultMode written" "$OUT"

echo ""
echo "=== A user's own defaultMode survives if the source matches it ==="
OUT=$(merge '{"permissions":{"defaultMode":"auto"}}' "$HARNESS")
[[ "$(printf '%s' "$OUT" | jq -r '.permissions.defaultMode')" == "auto" ]] \
  && pass "matching mode preserved" || fail "matching mode preserved" "$OUT"

echo ""
echo "=== allow / deny lists are unioned, not replaced ==="
OUT=$(merge '{"permissions":{"allow":["Bash(mycmd:*)"],"deny":["Bash(evil:*)"]}}' "$HARNESS")
ALLOW=$(printf '%s' "$OUT" | jq -r '.permissions.allow | sort | join(",")')
DENY=$(printf '%s' "$OUT" | jq -r '.permissions.deny | sort | join(",")')
[[ "$ALLOW" == "Bash(ls:*),Bash(mycmd:*)" ]] \
  && pass "allow unioned" || fail "allow unioned" "$ALLOW"
[[ "$DENY" == "Bash(evil:*),Bash(sudo:*)" ]] \
  && pass "deny unioned" || fail "deny unioned" "$DENY"

echo ""
echo "=== Harness owns hooks and statusLine ==="
OUT=$(merge '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"mine.sh"}]}]},"statusLine":{"type":"command","command":"mine.sh"}}' "$HARNESS")
[[ "$(printf '%s' "$OUT" | jq -r '.hooks | keys | join(",")')" == "SessionEnd" ]] \
  && pass "hooks replaced by harness" || fail "hooks replaced by harness" "$OUT"
[[ "$(printf '%s' "$OUT" | jq -r '.statusLine.command')" == "~/.claude/statusline.sh" ]] \
  && pass "statusline replaced by harness" || fail "statusline replaced by harness" "$OUT"

echo ""
echo "=== Unrelated user keys are preserved ==="
OUT=$(merge '{"env":{"CLAUDE_AUDIT_LOG":"~/mine.log"},"tui":"fullscreen"}' "$HARNESS")
[[ "$(printf '%s' "$OUT" | jq -r '.env.CLAUDE_AUDIT_LOG')" == "~/mine.log" ]] \
  && pass "user env preserved" || fail "user env preserved" "$OUT"
[[ "$(printf '%s' "$OUT" | jq -r '.tui')" == "fullscreen" ]] \
  && pass "unrelated user key preserved" || fail "unrelated user key preserved" "$OUT"
[[ "$(printf '%s' "$OUT" | jq -r '.effortLevel')" == "xhigh" ]] \
  && pass "harness key added" || fail "harness key added" "$OUT"

echo ""
echo "=== The shipped settings.json is valid and sets auto mode ==="
[[ "$(jq -r '.permissions.defaultMode' settings.json)" == "auto" ]] \
  && pass "shipped settings.json uses auto" || fail "shipped settings.json uses auto" "$(jq -r '.permissions.defaultMode' settings.json)"

echo ""
echo "=== The shipped settings.json merges cleanly onto itself (idempotent) ==="
# `unique` sorts the allow/deny lists, so compare content as sets rather than
# byte-for-byte: re-running install.sh must not add, drop, or alter anything.
norm(){ jq -S '.permissions.allow |= sort | .permissions.deny |= sort' "$1"; }
printf '%s' "$(merge "$(cat settings.json)" "$(cat settings.json)")" > "$TMP/self.json"
if [[ "$(norm "$TMP/self.json")" == "$(norm settings.json)" ]]; then
  pass "self-merge is a no-op"
else
  fail "self-merge is a no-op" "$(diff <(norm "$TMP/self.json") <(norm settings.json) | head -20)"
fi

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
