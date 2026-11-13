#!/usr/bin/env bash
# Tests for tools/pickup-report.sh on a fixture clone, and that install.sh reads
# the last install's commit before it writes its own and prints the report.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$PWD
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
R="$TMP/clone"
mkdir -p "$R"/{hooks,config,rules,bin,tests,docs,skills/s1/bin,skills/s2,skills/c/panel/hooks,skills/c/tests}
for f in hooks/a.sh hooks/b.sh config/settings.json rules/r.md bin/t.sh tests/x.test.sh docs/d.md \
         skills/s1/SKILL.md skills/s1/bin/e.py skills/s2/SKILL.md skills/c/SKILL.md skills/c/panel/hooks/register.tsx \
         skills/c/tests/test_c.py; do
  echo v1 > "$R/$f"
done
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q -m one
PREV=$(git -C "$R" rev-parse HEAD)
report() { bash "$REPO/tools/pickup-report.sh" "$1" "$R"; }

echo "=== nothing installed changed ==="
echo v2 > "$R/docs/d.md"; echo v2 > "$R/tests/x.test.sh"; echo v2 > "$R/skills/c/tests/test_c.py"
OUT=$(report "$PREV")
[[ "$OUT" == "  ✓ nothing installed changed since ${PREV:0:12}" ]] \
  && pass "docs, tests and a skill's tests are not installed, so not listed" || fail "clone-only files" "$OUT"

echo ""
echo "=== each change under how a running session picks it up ==="
echo v2 > "$R/hooks/a.sh"; echo v2 > "$R/config/settings.json"; echo v2 > "$R/rules/r.md"; echo v2 > "$R/bin/t.sh"
echo v2 > "$R/skills/s1/bin/e.py"; echo v2 > "$R/skills/s1/SKILL.md"; echo v2 > "$R/skills/s2/SKILL.md"; echo v2 > "$R/skills/c/panel/hooks/register.tsx"
echo new > "$R/hooks/new.sh"
OUT=$(report "$PREV")
[[ "$OUT" == *"Hooks and settings, on each session's next tool call:  config/settings.json  hooks/a.sh  hooks/new.sh"* ]] \
  && pass "hooks and settings, a file not yet committed included" || fail "live group" "$OUT"
[[ "$OUT" == *"Rules, when a session starts or resumes:  rules/r.md"* ]] && pass "rules" || fail "rules" "$OUT"
[[ "$OUT" == *"Tools in ~/.claude, on their next run:  bin/t.sh"* ]] && pass "tools" || fail "tools" "$OUT"
[[ "$OUT" == *"Skills, when a running session calls them again: /s1 /s2"* ]] \
  && pass "skills by name, once each" || fail "skills" "$OUT"
[[ "$OUT" == *'type `! claude respawn <job>` at your own prompt'*"skills/c/panel/hooks/register.tsx"* ]] \
  && pass "a panel: the respawn command, at the user's own prompt" || fail "panel" "$OUT"
[[ "$OUT" != *"/c "* && "$OUT" != *"/c"$'\n'* && "$OUT" != *"docs/d.md"* ]] \
  && pass "a panel change does not list its skill; clone-only files stay out" || fail "extra lines" "$OUT"

echo ""
echo "=== no record, or a commit the clone lacks ==="
[ -z "$(report "")" ] && [ -z "$(report unknown)" ] && pass "a first install prints nothing" || fail "first install" ""
OUT=$(report 0123456789abcdef0123456789abcdef01234567)
[[ "$OUT" == *"which this clone does not have; after a fetch: tools/pickup-report.sh 0123456789ab"* ]] \
  && pass "a commit the clone lacks says so and how to rerun" || fail "missing commit" "$OUT"

echo ""
echo "=== install.sh reads the old commit= before it writes the new one, and reports ==="
READ=$(grep -n "^PREV_COMMIT=" "$REPO/install.sh" | cut -d: -f1)
WRITE=$(grep -n '^} > ~/.claude/harness.version' "$REPO/install.sh" | cut -d: -f1)
[[ -n "$READ" && -n "$WRITE" && "$READ" -lt "$WRITE" ]] && pass "read at line $READ, written at $WRITE" || fail "read before write" "$READ $WRITE"
grep -qF 'bash "$REPO/tools/pickup-report.sh" "$PREV_COMMIT" "$REPO"' "$REPO/install.sh" \
  && pass "install.sh runs the report with that commit" || fail "install calls report" ""

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
