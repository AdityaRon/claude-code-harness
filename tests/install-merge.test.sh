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
echo "=== CLAUDE_CODE_AUTO_COMPACT_WINDOW is a plain integer in the CLI's accepted range ==="
# Auto-compact fires at (assumed_window - min(max_output,20000) - 13000). Shrinking
# the assumed window is how that fire point is pulled in: at 600000 a 1M session
# compacts at 567k instead of 967k, while a session on a <=600k model is untouched
# because the CLI takes min(real_window, configured).
#
# The value is parsed with a suffix-aware attempt falling back to parseInt, and an
# unparseable result falls back to the 100000 FLOOR rather than erroring. So "600k"
# reads as 600, floors to 100000, and would silently compact a 1M session at 67k.
# Only a bare decimal integer is safe, and only inside [100000, 1000000] - under the
# floor is raised and over the cap is capped, both without any failure.
ACW=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // empty' config/settings.json)
[[ -n "$ACW" ]] \
  && pass "auto-compact window is set" || fail "auto-compact window is set" "(key absent)"
[[ "$ACW" =~ ^[0-9]+$ ]] \
  && pass "value is a bare decimal integer" \
  || fail "value is a bare decimal integer" "got '$ACW' - a k/m suffix parses to the 100000 floor"
if [[ "$ACW" =~ ^[0-9]+$ ]] && (( ACW >= 100000 && ACW <= 1000000 )); then
  pass "value is within [100000, 1000000]"
else
  fail "value is within [100000, 1000000]" "got '$ACW'"
fi

echo ""
echo "=== The merge delivers the auto-compact window to the installed file ==="
# A setting the repo declares but the merge drops would leave the fire point
# unchanged with nothing to show for it.
OUT=$(merge '{"env":{"CLAUDE_AUDIT_LOG":"~/mine.log"}}' "$(cat config/settings.json)")
[[ "$(printf '%s' "$OUT" | jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW')" == "$ACW" ]] \
  && pass "auto-compact window survives the merge" \
  || fail "auto-compact window survives the merge" "$(printf '%s' "$OUT" | jq -c '.env')"

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
echo "=== Every hook settings.json registers actually exists in hooks/ ==="
# install.sh used to copy an explicit list of filenames. It named 15 and hooks/
# holds 15 real hooks plus lib.sh — but they were different sets: the list
# carried lib.sh and omitted memory-lint.sh, which settings.json registers on
# Write|Edit|MultiEdit. The result was a wired-up hook that install.sh never
# copied, running two weeks stale in ~/.claude with re-installs changing
# nothing. Counting would not have caught it; comparing the sets does.
MISSING=""
for ref in $(grep -oE '~/\.claude/hooks/[a-z0-9-]+\.sh' config/settings.json | sed 's|.*/||' | sort -u); do
  [ -f "hooks/$ref" ] || MISSING="$MISSING $ref"
done
[ -z "$MISSING" ] \
  && pass "every registered hook has a file in hooks/" \
  || fail "every registered hook has a file in hooks/" "missing:$MISSING"

# The converse is not an error — lib.sh is a sourced library, not a hook — but a
# hook file nobody registers is dead weight worth noticing.
UNREGISTERED=""
for f in hooks/*.sh; do
  b=$(basename "$f")
  [ "$b" = "lib.sh" ] && continue
  grep -qF "hooks/$b" config/settings.json || UNREGISTERED="$UNREGISTERED $b"
done
[ -z "$UNREGISTERED" ] \
  && pass "no hook file is left unregistered" \
  || fail "no hook file is left unregistered" "unregistered:$UNREGISTERED"

echo ""
echo "=== rules/ ships by glob, and installing never deletes a local rule ==="
# Same failure mode as the hooks list above: an explicit list drifts out of sync
# with the directory and a file silently stops shipping.
grep -qE 'for rule in "\$REPO"/rules/\*\.md' install.sh \
  && pass "install.sh copies rules/ by glob" \
  || fail "install.sh copies rules/ by glob" "no glob loop over rules/*.md"

# The install must be additive. ~/.claude/rules is also where machine-local
# rules live — the ones naming people, clusters or customers that must never
# enter this repo — and an install that cleared the directory would delete them.
grep -qE 'rm -rf? .*\.claude/rules|rm .*\.claude/rules/\*' install.sh \
  && fail "install.sh never clears ~/.claude/rules" "found a delete" \
  || pass "install.sh never clears ~/.claude/rules"

# A rule carrying an identifier would be published the moment this repo is
# pushed. Keep the shipped set free of people, channels, tickets and customers.
LEAKS=""
for f in rules/*.md; do
  [ -f "$f" ] || continue
  grep -nEi '[A-Z]+_CDB_[A-Z0-9_]+|\b[UDC]0[A-Z0-9]{7,}\b|@[a-z0-9.-]+\.(com|net|io)|\b(INS|ANEP|RAIN|LINK|PSP)-[0-9]+' "$f" >/dev/null \
    && LEAKS="$LEAKS $(basename "$f")"
done
[ -z "$LEAKS" ] \
  && pass "no shipped rule carries an identifier" \
  || fail "no shipped rule carries an identifier" "$LEAKS"

# `local-*.md` is reserved for rules written straight into ~/.claude/rules on one
# machine — the ones naming people, clusters or customers, which cannot live in a
# PUBLIC repo. The install is already additive, but an upgrade that shipped a rule
# with the same name would silently overwrite one. Reserving the prefix makes that
# impossible rather than unlikely.
RESERVED=""
for f in rules/local-*.md; do [ -e "$f" ] && RESERVED="$RESERVED $(basename "$f")"; done
[ -z "$RESERVED" ] \
  && pass "no shipped rule claims the reserved local-* name" \
  || fail "no shipped rule claims the reserved local-* name" "$RESERVED"

# Every always-loaded rule costs window in EVERY session, in every project, for
# the whole life of the session. That is the budget this directory spends, and
# nothing else measures it: the index has a cap the tooling enforces, rules had
# none. A rule that only matters for some files carries `paths:` frontmatter and
# does not count here, because it loads only when Claude opens a matching file.
BUDGET="${RULES_BYTE_BUDGET:-8000}"
LOADED=0
for f in rules/*.md; do
  [ -f "$f" ] || continue
  head -1 "$f" | grep -q '^---$' && continue    # path-scoped: not always loaded
  LOADED=$((LOADED + $(wc -c < "$f" | tr -d ' ')))
done
[ "$LOADED" -le "$BUDGET" ] \
  && pass "always-loaded rules fit the budget ($LOADED of $BUDGET bytes)" \
  || fail "always-loaded rules fit the budget" "$LOADED bytes, over $BUDGET — trim, or give a rule \`paths:\` frontmatter so it loads on demand"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
