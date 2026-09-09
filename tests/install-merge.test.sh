#!/usr/bin/env bash
# Tests for merge-settings.jq — the filter install.sh runs when merging the
# harness settings into an existing ~/.claude/settings.json.
#
# The load-bearing case: a machine already carrying permissions.defaultMode
# ("default", from a previous install or the /config UI) must end up on the
# harness value, since a plain `$new * $old` merge lets the stale value win.
set -u
FILTER="config/merge-settings.jq"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

# merge OLD_JSON NEW_JSON -> merged JSON on stdout
merge(){
  printf '%s' "$1" > "$TMP/old.json"
  printf '%s' "$2" > "$TMP/new.json"
  jq -s --arg home "${MERGE_HOME:-$HOME}" -f "$FILTER" "$TMP/old.json" "$TMP/new.json"
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
[[ "$(jq -r '.permissions.defaultMode' config/settings.json)" == "auto" ]] \
  && pass "shipped settings.json uses auto" || fail "shipped settings.json uses auto" "$(jq -r '.permissions.defaultMode' config/settings.json)"

echo ""
echo "=== A ~/ rule gains a \$HOME-expanded twin, in allow AND deny ==="
# Whether the CLI expands `~` when matching a Bash rule is undocumented, so
# both spellings must ship. Pin HOME so the assertion is deterministic.
TILDE='{
  "permissions": {
    "defaultMode":"auto",
    "allow":["Bash(~/.claude/skills/vm-query/vm-query.sh:*)"],
    "deny":["Bash(~/bin/danger.sh:*)"]
  }
}'
OUT=$(MERGE_HOME=/home/testuser merge '{}' "$TILDE")
[[ "$(printf '%s' "$OUT" | jq -r '.permissions.allow | join(",")')" \
   == "Bash(/home/testuser/.claude/skills/vm-query/vm-query.sh:*),Bash(~/.claude/skills/vm-query/vm-query.sh:*)" ]] \
  && pass "allow keeps both spellings" || fail "allow keeps both spellings" "$OUT"
[[ "$(printf '%s' "$OUT" | jq -r '.permissions.deny | join(",")')" \
   == "Bash(/home/testuser/bin/danger.sh:*),Bash(~/bin/danger.sh:*)" ]] \
  && pass "deny keeps both spellings" || fail "deny keeps both spellings" "$OUT"

echo ""
echo "=== A rule with no ~/ is not duplicated or rewritten ==="
OUT=$(MERGE_HOME=/home/testuser merge '{}' '{"permissions":{"allow":["Bash(ls:*)"],"deny":[]}}')
[[ "$(printf '%s' "$OUT" | jq -r '.permissions.allow | join(",")')" == "Bash(ls:*)" ]] \
  && pass "plain rule untouched" || fail "plain rule untouched" "$OUT"

echo ""
echo "=== Re-running install.sh is stable (merge is idempotent after the first pass) ==="
# The first merge deliberately grows the lists (tilde expansion), so the
# invariant install.sh needs is that a SECOND run changes nothing further.
norm(){ jq -S '.permissions.allow |= sort | .permissions.deny |= sort' "$1"; }
printf '%s' "$(merge '{}' "$(cat config/settings.json)")" > "$TMP/pass1.json"
printf '%s' "$(merge "$(cat "$TMP/pass1.json")" "$(cat config/settings.json)")" > "$TMP/pass2.json"
if [[ "$(norm "$TMP/pass2.json")" == "$(norm "$TMP/pass1.json")" ]]; then
  pass "second install run is a no-op"
else
  fail "second install run is a no-op" "$(diff <(norm "$TMP/pass1.json") <(norm "$TMP/pass2.json") | head -20)"
fi

echo ""
echo "=== Every shipped ~/ rule reaches the merged output in expanded form ==="
SHIPPED_TILDE=$(jq -r '[.permissions.allow[], .permissions.deny[]] | map(select(contains("~/"))) | length' config/settings.json)
GOT_EXPANDED=$(jq -r --arg h "$HOME" '[.permissions.allow[], .permissions.deny[]] | map(select(startswith("Bash(" + $h))) | length' "$TMP/pass1.json")
[[ "$SHIPPED_TILDE" -gt 0 && "$GOT_EXPANDED" == "$SHIPPED_TILDE" ]] \
  && pass "all $SHIPPED_TILDE tilde rules expanded" \
  || fail "all tilde rules expanded" "shipped=$SHIPPED_TILDE expanded=$GOT_EXPANDED"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
