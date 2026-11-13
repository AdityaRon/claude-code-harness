#!/usr/bin/env bash
# Tests for tools/pickup-report.sh on a fixture clone, and for install.sh run for
# real: a first install with no record, then one that reports from the last and
# removes what it wrote that the clone has since deleted.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$PWD
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
R="$TMP/clone"
mkdir -p "$R"/{hooks/sub,hooks/lib,config,rules,bin/sub,tests,docs,skills/s1/bin,skills/s2/tests/templates,skills/s3/templates/x,skills/c/panel/hooks,skills/c/tests}
# Each line past the first holds files deeper than install copies, or not copied.
for f in hooks/a.sh hooks/b.sh hooks/old.sh hooks/lib/l.sh config/settings.json rules/r.md rules/gone.md bin/t.sh bin/u.sh bin/Case.sh \
         skills/s1/SKILL.md skills/s1/bin/e.py skills/s2/SKILL.md skills/s3/templates/x/y.md \
         skills/c/SKILL.md skills/c/panel/hooks/register.tsx \
         tests/x.test.sh docs/d.md skills/c/tests/test_c.py \
         hooks/README.md hooks/sub/y.sh bin/sub/z skills/s2/tests/t.example.toml skills/s2/tests/templates/q.md; do
  echo v1 > "$R/$f"
done
echo 'v1, renamed later' > "$R/rules/old-name.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q -m one
PREV=$(git -C "$R" rev-parse HEAD)
# The report reads and, with --prune, removes installed copies, so never the real ~/.claude.
RH="$TMP/rhome"; I="$RH/.claude"
report() { HOME="$RH" bash "$REPO/tools/pickup-report.sh" "$@" "$R"; }

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
echo "=== by hand, a deleted file is named where its installed copy stays ==="
mkdir -p "$I/hooks" "$I/rules"
for f in u.sh hooks/old.sh rules/gone.md; do echo v1 > "$I/$f"; done
echo 'v1, renamed later' > "$I/rules/old-name.md"
rm "$R/hooks/old.sh" "$R/rules/gone.md" "$R/bin/u.sh" "$R/hooks/b.sh"
git -C "$R" mv rules/old-name.md rules/new-name.md
OUT=$(report "$PREV")
[[ "$OUT" == *"the earlier copy stays until removed by hand:  $I/u.sh  $I/hooks/old.sh  $I/rules/gone.md  $I/rules/old-name.md" ]] \
  && pass "deleted: a tool, a hook, a rule and a renamed rule's old name, at their installed paths" || fail "deleted" "$OUT"
[[ "$OUT" != *"hooks/b.sh"* ]] && pass "a deleted file with no installed copy is not named" || fail "absent copy named" "$OUT"
[[ -f "$I/u.sh" && -f "$I/hooks/old.sh" && -f "$I/rules/gone.md" && -f "$I/rules/old-name.md" ]] \
  && pass "and without --prune nothing is removed" || fail "removed by hand run" "$(ls -R "$I")"
[[ "$OUT" == *"next tool call:  config/settings.json  hooks/a.sh  hooks/lib/l.sh  hooks/new.sh"$'\n'* && "$OUT" == *"resumes:  rules/new-name.md  rules/r.md"$'\n'* \
   && "$OUT" == *"next run:  bin/t.sh"$'\n'* ]] \
  && pass "and not as a change to pick up; the new name is one" || fail "deleted as change" "$OUT"

echo ""
echo "=== --prune with no record, or a commit the clone lacks, removes nothing ==="
OUT=$(report --prune 0123456789abcdef0123456789abcdef01234567)
[[ "$OUT" == *"which this clone does not have, so nothing deleted from the clone was removed (previous install unknown); after a fetch"* \
   && -z "$(report --prune "")" && -f "$I/u.sh" && -f "$I/rules/old-name.md" ]] \
  && pass "an unchanged copy stays, and the report says the previous install is unknown" || fail "prune, unknown commit" "$OUT; $(ls "$I")"

echo ""
echo "=== --prune removes what install wrote and nothing changed; the rest stays, with why ==="
echo 'v1 and an edit' > "$I/rules/gone.md"
chmod 755 "$I/u.sh"
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"~/.claude/hooks/old.sh"}]}]}}' > "$I/settings.json"
# Renamed in case only. On a case-insensitive disk (macOS's default) Case.sh is
# the new case.sh, which must stay; on a case-sensitive one this cannot fail.
git -C "$R" mv bin/Case.sh bin/case.sh; echo v1 > "$I/case.sh"
OUT=$(report --prune "$PREV")
[[ "$OUT" == *"removed here because install wrote it and nothing changed it (each is in git at ${PREV:0:12}):  $I/u.sh  $I/rules/old-name.md"$'\n'* \
   && ! -e "$I/u.sh" && ! -e "$I/rules/old-name.md" ]] \
  && pass "unchanged copies removed and named; a mode change is not an edit" || fail "prune removes" "$OUT; $(ls -R "$I")"
[[ "$OUT" == *"stays until removed by hand:  $I/hooks/old.sh (settings.json refers to it)  $I/rules/gone.md (edited since install)" \
   && -f "$I/hooks/old.sh" && -f "$I/rules/gone.md" ]] \
  && pass "an edited copy and one settings.json names stay, each with its reason" || fail "prune keeps" "$OUT"
[[ -f "$I/case.sh" ]] && pass "a file renamed only in case keeps its installed copy" || fail "case rename" "$OUT"

echo ""
echo "=== a commit the clone lacks ==="
[ -z "$(report "")" ] && [ -z "$(report unknown)" ] && pass "no record prints nothing" || fail "no record" ""
OUT=$(report 0123456789abcdef0123456789abcdef01234567)
[[ "$OUT" == *"which this clone does not have; after a fetch: tools/pickup-report.sh 0123456789ab"* ]] \
  && pass "a commit the clone lacks says so and how to rerun" || fail "missing commit" "$OUT"

echo ""
echo "=== install.sh: a first install, then the next one reports from the last ==="
inst() {  # [CLONE [HOME]]
  ( export HOME="${2:-$TMP/home}" TMPDIR="$TMP" CCH_SKIP_SELFTEST=1
    unset XDG_CONFIG_HOME XDG_DATA_HOME; mkdir -p "$HOME"
    cd "${1:-$REPO}" && bash install.sh 2>&1 )
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
echo "=== install.sh removes what it wrote that the clone deleted, and keeps the rest ==="
# This clone's working tree, committed in a copy with five files more, installed;
# then the five are deleted and install runs again.
C="$TMP/copy"; H="$TMP/home2"; mkdir -p "$C" "$H/.claude"
( cd "$REPO" && git ls-files -co --exclude-standard | while IFS= read -r p; do [[ -f "$p" ]] && printf '%s\n' "$p"; done > "$TMP/files" \
  && tar -cf - -T "$TMP/files" ) | tar -xf - -C "$C"
FIVE="bin/gone-tool.sh bin/edited-tool.sh bin/named-tool.sh rules/gone-rule.md hooks/gone-hook.sh"
for f in $FIVE; do printf '#!/bin/sh\n# %s\n' "$f" > "$C/$f"; done
git -C "$C" init -q && git -C "$C" add -A && git -C "$C" -c user.name=t -c user.email=t@example.com commit -q -m one
echo mine > "$H/.claude/stray.sh"
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC == 0 && -x "$H/.claude/gone-tool.sh" && -f "$H/.claude/stray.sh" && "$OUT" != *"Deleted from the clone"* ]] \
  && pass "a first install, with no record, removes nothing" || fail "first install over a stray file" "rc=$RC $(printf '%s\n' "$OUT" | tail -4)"
for f in $FIVE; do rm "$C/$f"; done
echo '# my edit' >> "$H/.claude/edited-tool.sh"
S="$H/.claude/settings.json"
jq '.permissions.allow += ["Bash(~/.claude/named-tool.sh:*)"]
    | .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/gone-hook.sh"}]}]' "$S" > "$S.next" && mv "$S.next" "$S"
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC == 0 && "$OUT" == *"removed here because install wrote it and nothing changed it"*":  $H/.claude/gone-tool.sh  $H/.claude/rules/gone-rule.md"$'\n'* \
   && ! -e "$H/.claude/gone-tool.sh" && ! -e "$H/.claude/rules/gone-rule.md" ]] \
  && pass "a tool and a rule install wrote, unchanged, are removed and named" || fail "install removes" "rc=$RC $(printf '%s\n' "$OUT" | grep -A1 Deleted)"
[[ -f "$H/.claude/edited-tool.sh" && "$OUT" == *"$H/.claude/edited-tool.sh (edited since install)"* ]] \
  && pass "an edited copy is kept, and says why" || fail "edited kept" "$(printf '%s\n' "$OUT" | grep Deleted)"
[[ -f "$H/.claude/named-tool.sh" && "$OUT" == *"$H/.claude/named-tool.sh (settings.json refers to it)"* ]] \
  && pass "a copy an allow rule names is kept" || fail "allow-rule copy kept" "$(printf '%s\n' "$OUT" | grep Deleted)"
[[ -f "$H/.claude/hooks/gone-hook.sh" && "$OUT" == *"$H/.claude/hooks/gone-hook.sh (settings.json refers to it)"* \
   && "$(jq -r '[.hooks.PreToolUse[].hooks[].command] | index("~/.claude/hooks/gone-hook.sh") != null' "$S")" == true ]] \
  && pass "a deleted hook settings.json still runs is kept, as the merge keeps its entry" || fail "registered hook kept" "$(printf '%s\n' "$OUT" | grep Deleted)"
[[ -f "$H/.claude/stray.sh" ]] && pass "a file no install wrote is left alone" || fail "stray file" "removed"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
