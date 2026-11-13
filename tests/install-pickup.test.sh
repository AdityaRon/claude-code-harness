#!/usr/bin/env bash
# Tests for tools/pickup-report.sh on a fixture clone, and for install.sh run for
# real: a first install with no record, then one that reports from the last.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$PWD
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
R="$TMP/clone"
mkdir -p "$R"/{hooks/sub,hooks/lib,config,rules,bin/sub,tests,docs,skills/s1/bin,skills/s2/tests/templates,skills/s3/templates/x,skills/c/panel/hooks,skills/c/tests}
# Each line past the first holds files deeper than install copies, or not copied.
for f in hooks/a.sh hooks/b.sh hooks/old.sh hooks/lib/l.sh config/settings.json rules/r.md rules/gone.md bin/t.sh bin/u.sh \
         skills/s1/SKILL.md skills/s1/bin/e.py skills/s2/SKILL.md skills/s3/templates/x/y.md \
         skills/c/SKILL.md skills/c/panel/hooks/register.tsx \
         tests/x.test.sh docs/d.md skills/c/tests/test_c.py \
         hooks/README.md hooks/sub/y.sh bin/sub/z skills/s2/tests/t.example.toml skills/s2/tests/templates/q.md; do
  echo v1 > "$R/$f"
done
echo 'v1, renamed later' > "$R/rules/old-name.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q -m one
PREV=$(git -C "$R" rev-parse HEAD)
report() { bash "$REPO/tools/pickup-report.sh" "$1" "$R"; }

echo "=== nothing installed changed ==="
for f in docs/d.md tests/x.test.sh skills/c/tests/test_c.py hooks/README.md hooks/sub/y.sh bin/sub/z skills/s2/tests/t.example.toml \
         skills/s2/tests/templates/q.md; do
  echo v2 > "$R/$f"
done
OUT=$(report "$PREV")
[[ "$OUT" == "  ✓ nothing installed changed since ${PREV:0:12}" ]] \
  && pass "docs, tests, and files deeper than install copies are not listed" || fail "clone-only files" "$OUT"

echo ""
echo "=== each change under how a running session picks it up ==="
echo v2 > "$R/hooks/a.sh"; echo v2 > "$R/hooks/lib/l.sh"; echo v2 > "$R/config/settings.json"; echo v2 > "$R/rules/r.md"; echo v2 > "$R/bin/t.sh"
echo v2 > "$R/skills/s1/bin/e.py"; echo v2 > "$R/skills/s1/SKILL.md"; echo v2 > "$R/skills/s2/SKILL.md"; echo v2 > "$R/skills/c/panel/hooks/register.tsx"
echo v2 > "$R/skills/s3/templates/x/y.md"
echo new > "$R/hooks/new.sh"
OUT=$(report "$PREV")
[[ "$OUT" == *"Hooks and settings, on each session's next tool call:  config/settings.json  hooks/a.sh  hooks/lib/l.sh  hooks/new.sh"$'\n'* ]] \
  && pass "hooks and settings, a part of lib.sh and a file not yet committed included" || fail "live group" "$OUT"
[[ "$OUT" == *"Rules, when a session starts or resumes:  rules/r.md"$'\n'* ]] && pass "rules" || fail "rules" "$OUT"
[[ "$OUT" == *"Tools in ~/.claude, on their next run:  bin/t.sh"$'\n'* ]] && pass "tools" || fail "tools" "$OUT"
[[ "$OUT" == *"Skills, when a running session calls them again: /s1 /s2 /s3"$'\n'* ]] \
  && pass "skills by name, once each; a template at any depth counts" || fail "skills" "$OUT"
[[ "$OUT" == *'type `! claude respawn <job>` at your own prompt'*"skills/c/panel/hooks/register.tsx" ]] \
  && pass "a panel: the respawn command, at the user's own prompt" || fail "panel" "$OUT"
[[ "$OUT" != *"/c "* && "$OUT" != *"/c"$'\n'* && "$OUT" != *"docs/d.md"* ]] \
  && pass "a panel change does not list its skill; clone-only files stay out" || fail "extra lines" "$OUT"

echo ""
echo "=== a deleted file is named where its installed copy stays ==="
rm "$R/hooks/old.sh" "$R/rules/gone.md" "$R/bin/u.sh"
git -C "$R" mv rules/old-name.md rules/new-name.md
OUT=$(report "$PREV")
[[ "$OUT" == *"the earlier copy stays until removed by hand:  $HOME/.claude/u.sh  $HOME/.claude/hooks/old.sh  $HOME/.claude/rules/gone.md  $HOME/.claude/rules/old-name.md" ]] \
  && pass "deleted: a tool, a hook, a rule and a renamed rule's old name, at their installed paths" || fail "deleted" "$OUT"
[[ "$OUT" == *"next tool call:  config/settings.json  hooks/a.sh  hooks/lib/l.sh  hooks/new.sh"$'\n'* && "$OUT" == *"resumes:  rules/new-name.md  rules/r.md"$'\n'* \
   && "$OUT" == *"next run:  bin/t.sh"$'\n'* ]] \
  && pass "and not as a change to pick up; the new name is one" || fail "deleted as change" "$OUT"

echo ""
echo "=== no record, or a commit the clone lacks ==="
[ -z "$(report "")" ] && [ -z "$(report unknown)" ] && pass "no record prints nothing" || fail "no record" ""
OUT=$(report 0123456789abcdef0123456789abcdef01234567)
[[ "$OUT" == *"which this clone does not have; after a fetch: tools/pickup-report.sh 0123456789ab"* ]] \
  && pass "a commit the clone lacks says so and how to rerun" || fail "missing commit" "$OUT"

echo ""
echo "=== install.sh: a first install, then the next one reports from the last ==="
inst() {
  ( export HOME="$TMP/home" TMPDIR="$TMP" CCH_SKIP_SELFTEST=1
    unset XDG_CONFIG_HOME XDG_DATA_HOME; mkdir -p "$HOME"
    cd "$REPO" && bash install.sh 2>&1 )
}
OUT=$(inst); RC=$?
[[ $RC == 0 && "$OUT" == *"Done. Open Claude Code"* && -f "$TMP/home/.claude/harness.version" ]] \
  && pass "a first install, with no harness.version, finishes and records one" || fail "first install" "rc=$RC $(printf '%s\n' "$OUT" | tail -4)"
[[ "$OUT" != *"since "* && "$OUT" != *"which this clone does not have"* ]] \
  && pass "and prints no report" || fail "first install report" "$(printf '%s\n' "$OUT" | grep -n 'since\|clone does not')"
# A commit no clone has: the report names it only if install read it before
# writing its own commit over it.
printf 'version=v0\ncommit=0123456789abcdef0123456789abcdef01234567\n' > "$TMP/home/.claude/harness.version"
OUT=$(inst); RC=$?
[[ $RC == 0 && "$OUT" == *"the last install was at 0123456789ab, which this clone does not have"* ]] \
  && pass "the next install reports from the commit the last one recorded" || fail "second install" "rc=$RC $(printf '%s\n' "$OUT" | tail -6)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
