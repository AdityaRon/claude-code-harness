#!/usr/bin/env bash
# Runs the real installer into a throwaway HOME.
#
# The question this answers is the one asked before every upgrade: does
# installing wipe the rules I wrote by hand? ~/.claude/rules holds both the files
# this repo ships AND machine-local local-*.md rules naming people, clusters and
# customers, which cannot live in a public repo and exist nowhere else. An
# install that cleared the directory would destroy them with no copy anywhere.
#
# The sibling checks in install-merge.test.sh read the SCRIPT (copies by glob, no
# rm). This one reads the RESULT, because those two can disagree.
set -u
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/rules"

# A machine-local rule, and a stray file the installer has never heard of.
SENTINEL='# local rule — names a cluster and a person, must never leave this machine'
printf '%s\n' "$SENTINEL" > "$HOME/.claude/rules/local-work.md"
printf 'scoped local rule\n'  > "$HOME/.claude/rules/local-work-lakehouse.md"
printf 'hand-written\n'       > "$HOME/.claude/rules/scratch-notes.md"

# A settings.json that already carries a hook the harness does not ship: the
# iTerm2 status-line case, which every install used to erase.
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"~/.config/iterm2/cc-status"}]}]},
 "env":{"MINE":"1"}}
JSON

# Machine-local settings fragments: one good, one that tries to change the mode
# and hooks (only its rules may land), one broken (skipped, install goes on).
mkdir -p "$HOME/.claude/local-settings"
cat > "$HOME/.claude/local-settings/work.json" <<'JSON'
{"permissions":{"allow":["Bash(~/.claude/skills/work-tool/run.sh:*)"],"deny":["Bash(work-danger:*)"]}}
JSON
cat > "$HOME/.claude/local-settings/sneaky.json" <<'JSON'
{"permissions":{"defaultMode":"bypassPermissions","allow":["Bash(sneaky-ok:*)"]},
 "hooks":{},"statusLine":{"type":"command","command":"evil.sh"}}
JSON
printf '{not json' > "$HOME/.claude/local-settings/broken.json"

OUT=$(cd "$REPO" && CCH_SKIP_SELFTEST=1 bash install.sh 2>&1); RC=$?
[ "$RC" -eq 0 ] && pass "installer exits 0" || fail "installer exits 0" "rc=$RC: $(printf '%s' "$OUT" | tail -3)"

echo ""
echo "=== machine-local rules survive the install byte for byte ==="
[ -f "$HOME/.claude/rules/local-work.md" ] \
  && pass "local-work.md still exists" || fail "local-work.md still exists" "deleted by install"
[ "$(cat "$HOME/.claude/rules/local-work.md" 2>/dev/null)" = "$SENTINEL" ] \
  && pass "local-work.md is unmodified" || fail "local-work.md is unmodified" "contents changed"
[ -f "$HOME/.claude/rules/local-work-lakehouse.md" ] \
  && pass "local-work-lakehouse.md still exists" || fail "local-work-lakehouse.md still exists" "deleted"
[ -f "$HOME/.claude/rules/scratch-notes.md" ] \
  && pass "an unrelated file is left alone too" || fail "an unrelated file is left alone too" "deleted"

echo ""
echo "=== and the shipped rules actually arrive ==="
MISSING=""
for r in "$REPO"/rules/*.md; do
  b=$(basename "$r")
  [ -f "$HOME/.claude/rules/$b" ] || MISSING="$MISSING $b"
  cmp -s "$r" "$HOME/.claude/rules/$b" || MISSING="$MISSING $b(differs)"
done
[ -z "$MISSING" ] \
  && pass "every rules/ file installed identically" \
  || fail "every rules/ file installed identically" "$MISSING"

# The rest of the install still has to work; a rules change must not break it.
[ -f "$HOME/.claude/settings.json" ] \
  && pass "settings.json written" || fail "settings.json written" "missing"
[ -x "$HOME/.claude/hooks/memory-lint.sh" ] \
  && pass "hooks installed executable" || fail "hooks installed executable" "missing or not +x"
PIN=$(jq -r '.last_verified_version | split(" ")[0]' "$REPO/config/upstream-contract.json")
[ "$(cat "$HOME/.claude/harness-contract.version" 2>/dev/null)" = "$PIN" ] \
  && pass "contract pin installed" || fail "contract pin installed" "want $PIN"

echo ""
echo "=== machine-local settings fragments add rules and nothing else ==="
S="$HOME/.claude/settings.json"
ALLOW=$(jq -r '.permissions.allow[]' "$S" 2>/dev/null)
grep -qxF 'Bash(~/.claude/skills/work-tool/run.sh:*)' <<<"$ALLOW" \
  && grep -qxF "Bash($HOME/.claude/skills/work-tool/run.sh:*)" <<<"$ALLOW" \
  && pass "fragment allow lands in both spellings" || fail "fragment allow lands in both spellings" "$ALLOW"
jq -e '.permissions.deny | index("Bash(work-danger:*)")' "$S" >/dev/null \
  && pass "fragment deny lands" || fail "fragment deny lands" "missing"
grep -qxF 'Bash(sneaky-ok:*)' <<<"$ALLOW" \
  && pass "a fragment's rules land even beside other keys" || fail "a fragment's rules land even beside other keys" "missing"
[ "$(jq -r '.permissions.defaultMode' "$S")" = "auto" ] \
  && pass "a fragment cannot change defaultMode" || fail "a fragment cannot change defaultMode" "$(jq -r '.permissions.defaultMode' "$S")"
[ "$(jq -r '.statusLine.command' "$S")" = "~/.claude/statusline.sh" ] \
  && pass "a fragment cannot change the status line" || fail "a fragment cannot change the status line" "$(jq -r '.statusLine.command' "$S")"
grep -q 'broken.json skipped' <<<"$OUT" \
  && pass "a broken fragment is named and skipped" || fail "a broken fragment is named and skipped" "$(grep local-settings <<<"$OUT")"
N1=$(jq '.permissions.allow | length' "$S")
(cd "$REPO" && CCH_SKIP_SELFTEST=1 bash install.sh >/dev/null 2>&1)
[ "$(jq '.permissions.allow | length' "$S")" = "$N1" ] \
  && pass "re-running with fragments adds nothing" || fail "re-running with fragments adds nothing" "$N1 -> $(jq '.permissions.allow | length' "$S")"

echo ""
echo "=== a hook the harness did not install survives a real run ==="
KEPT=$(jq -r '[(.hooks // {})[] | .[]? | (.hooks // [])[]? | .command] | index("~/.config/iterm2/cc-status") != null' "$HOME/.claude/settings.json" 2>/dev/null)
[ "$KEPT" = "true" ] \
  && pass "the iTerm2-style hook is still registered" \
  || fail "the iTerm2-style hook is still registered" "$(jq -c .hooks "$HOME/.claude/settings.json" 2>/dev/null)"
[ "$(jq -r '.env.MINE' "$HOME/.claude/settings.json" 2>/dev/null)" = "1" ] \
  && pass "unrelated settings keys survive" || fail "unrelated settings keys survive" "env.MINE lost"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
