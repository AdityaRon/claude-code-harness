#!/usr/bin/env bash
# Tests for tools/pickup-report.sh on fixture clones, and for install.sh run for
# real: a first install with no record, then ones that report from the last and
# remove what install wrote that the clone has since deleted.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$PWD
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
# crontab -l reads $HOME/crontab.txt, so no case sees this machine's crontab.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\n[ "$1" = -l ] && cat "$HOME/crontab.txt" 2>/dev/null\nexit 0\n' > "$FAKEBIN/crontab"; chmod 755 "$FAKEBIN/crontab"
R="$TMP/clone"
mkdir -p "$R"/{hooks/sub,hooks/lib,config,rules,bin/sub,tests,docs,skills/s1/bin,skills/s2/tests/templates,skills/s3/templates/x,skills/c/panel/hooks,skills/c/tests}
# Each line past the first holds files deeper than install copies, or not copied.
for f in hooks/a.sh hooks/b.sh hooks/old.sh hooks/lib/l.sh config/settings.json rules/r.md rules/gone.md bin/t.sh bin/u.sh bin/Case.sh \
         bin/w.sh bin/sym.sh skills/s1/SKILL.md skills/s1/bin/e.py skills/s2/SKILL.md skills/s3/templates/x/y.md \
         skills/c/SKILL.md skills/c/panel/hooks/register.tsx \
         tests/x.test.sh docs/d.md skills/c/tests/test_c.py \
         hooks/README.md hooks/sub/y.sh bin/sub/z skills/s2/tests/t.example.toml skills/s2/tests/templates/q.md; do
  echo v1 > "$R/$f"
done
echo 'v1, renamed later' > "$R/rules/old-name.md"
gr() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
gr init -q && gr add -A && gr commit -q -m one
PREV=$(gr rev-parse HEAD)
# The report reads and, with --prune, removes installed copies, so never the real ~/.claude.
RH="$TMP/rhome"; I="$RH/.claude"
report() { HOME="$RH" PATH="$FAKEBIN:$PATH" bash "$REPO/tools/pickup-report.sh" "$@" "$R"; }

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
gr mv rules/old-name.md rules/new-name.md
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
mkdir -p "$TMP/outside"; echo v1 > "$TMP/outside/sym-target"; ln -s "$TMP/outside/sym-target" "$I/sym.sh"; rm "$R/bin/sym.sh"
# Renamed in case only. On a disk that ignores case, Case.sh is the new case.sh
# and is not listed; on one that does not, the old copy is kept and listed.
gr mv bin/Case.sh bin/case.sh; echo v1 > "$I/Case.sh"; echo v1 > "$I/case.sh"
gr add -A && gr commit -q -m two
rm "$R/bin/w.sh"; echo v1 > "$I/w.sh"
echo 'v1 and an edit' > "$I/rules/gone.md"
chmod 755 "$I/u.sh"
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"~/.claude/hooks/old.sh"}]}]}}' > "$I/settings.json"
OUT=$(report --prune "$PREV")
[[ "$OUT" == *"removed here because install wrote it and nothing changed it (each is in git at ${PREV:0:12}):  $I/u.sh  $I/rules/old-name.md"$'\n'* \
   && ! -e "$I/u.sh" && ! -e "$I/rules/old-name.md" ]] \
  && pass "unchanged copies removed and named; a mode change is not an edit" || fail "prune removes" "$OUT; $(ls -R "$I")"
[[ "$OUT" == *"$I/hooks/old.sh (named in $I/settings.json)"* && "$OUT" == *"$I/rules/gone.md (edited since install)"* \
   && -f "$I/hooks/old.sh" && -f "$I/rules/gone.md" ]] \
  && pass "an edited copy and one settings.json names stay, each with its reason" || fail "prune keeps" "$OUT"
[[ -L "$I/sym.sh" && -f "$TMP/outside/sym-target" && "$OUT" == *"$I/sym.sh (not the plain file install wrote)"* ]] \
  && pass "a symlink at the installed path stays" || fail "symlink kept" "$OUT"
[[ -f "$I/w.sh" && "$OUT" == *"$I/w.sh (deleted only in the working tree)"* ]] \
  && pass "a deletion not committed is listed, not removed" || fail "working-tree deletion" "$OUT"
if [[ "$I/Case.sh" -ef "$I/case.sh" ]]; then
  [[ -f "$I/case.sh" && "$OUT" != *"$I/Case.sh"* ]] \
    && pass "a file renamed only in case keeps its copy, unlisted (this disk ignores case)" || fail "case rename" "$OUT"
else
  [[ -f "$I/case.sh" && -f "$I/Case.sh" && "$OUT" == *"$I/Case.sh (this install writes case.sh)"* ]] \
    && pass "a file renamed only in case keeps its old copy, listed (this disk keeps case)" || fail "case rename" "$OUT"
fi

echo ""
echo "=== --prune keeps a file the clone lacks only because it is not ahead of the last install ==="
# A, then B adds bin/x.sh and is installed; the clone then checks out A, or a branch off A.
R2="$TMP/clone2"; mkdir -p "$R2/bin" "$I"
g2() { git -C "$R2" -c user.name=t -c user.email=t@example.com "$@"; }
echo a > "$R2/bin/a.sh"; g2 init -q; g2 add -A; g2 commit -q -m A; A=$(g2 rev-parse HEAD)
echo x > "$R2/bin/x.sh"; g2 add -A; g2 commit -q -m B; B=$(g2 rev-parse HEAD)
prune2() { HOME="$RH" PATH="$FAKEBIN:$PATH" bash "$REPO/tools/pickup-report.sh" --prune "$B" "$R2"; }
echo x > "$I/x.sh"; g2 checkout -q "$A"
OUT=$(prune2)
[[ -f "$I/x.sh" && "$OUT" == *"stays until removed by hand:  $I/x.sh (the clone is not ahead of the last install)" ]] \
  && pass "a downgrade keeps an unchanged copy, and says why" || fail "downgrade" "$OUT"
g2 checkout -q -b side "$A"; echo s > "$R2/bin/s.sh"; g2 add -A; g2 commit -q -m S
OUT=$(prune2)
[[ -f "$I/x.sh" && "$OUT" == *"$I/x.sh (the clone is not ahead of the last install)" ]] \
  && pass "so does a branch split off before the last install" || fail "older branch" "$OUT"
g2 checkout -q -b fwd "$B"; g2 rm -q bin/x.sh; g2 commit -q -m C
OUT=$(prune2)
[[ ! -e "$I/x.sh" && "$OUT" == *"removed here"*"$I/x.sh"* ]] \
  && pass "and a commit after it that deletes the file removes it" || fail "forward delete" "$OUT"

echo ""
echo "=== --prune keeps a copy anything else names, saying where, and one reached through a symlink ==="
R4="$TMP/clone4"; H4="$TMP/rhome4"; I4="$H4/.claude"; OUTSIDE="$TMP/outside/sk"
NAMES="t-env.sh t-cd.sh t-dbl.sh t-esc.sh t-local.sh t-mcp.sh t-plist.sh t-cron.sh t-skill.sh t-uses.sh t-call.sh t-free.sh
       t-zsh.sh t-keys.sh t-cmd.sh t-agent.sh"
mkdir -p "$R4/bin" "$R4/skills/sk/bin" "$I4/skills/refs" "$I4/commands" "$I4/agents" "$H4/Library/LaunchAgents" "$OUTSIDE/bin"
for n in $NAMES; do echo v1 > "$R4/bin/$n"; echo v1 > "$I4/$n"; done
echo v1 > "$R4/skills/sk/SKILL.md"; echo v1 > "$R4/skills/sk/bin/helper.py"
echo v1 > "$OUTSIDE/SKILL.md"; echo v1 > "$OUTSIDE/bin/helper.py"; ln -s "$OUTSIDE" "$I4/skills/sk"
g4() { git -C "$R4" -c user.name=t -c user.email=t@example.com "$@"; }
g4 init -q; g4 add -A; g4 commit -q -m A; A4=$(g4 rev-parse HEAD)
for n in $NAMES; do g4 rm -q "bin/$n"; done; g4 rm -q skills/sk/bin/helper.py; g4 commit -q -m B
cat > "$I4/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"hooks":[
  {"type":"command","command":"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/t-env.sh"},
  {"type":"command","command":"cd ~/.claude && ./t-cd.sh"},
  {"type":"command","command":"~/.claude//t-dbl.sh"},
  {"type":"command","command":"~\/.claude\/t-esc.sh"}]}]}}
JSON
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/t-local.sh"}]}]}}' > "$I4/settings.local.json"
printf '%s\n' '{"mcpServers":{"m":{"command":"/bin/sh","args":["~/.claude/t-mcp.sh"]}}}' > "$H4/.claude.json"
printf '<plist><string>%s/.claude/t-plist.sh</string></plist>\n' "$H4" > "$H4/Library/LaunchAgents/x.plist"
echo '17 3 * * * /bin/bash ~/.claude/t-cron.sh' > "$H4/crontab.txt"
echo 'Run ~/.claude/t-skill.sh first.' > "$I4/skills/refs/SKILL.md"
echo 'uses = ["t-uses.sh"]' > "$I4/skills/refs/forge.toml"
printf '#!/bin/sh\nexec "$(dirname "$0")/t-call.sh"\n' > "$I4/caller.sh"
echo 'alias t=~/.claude/t-zsh.sh' > "$H4/.zshrc"
printf '%s\n' '{"bindings":{"ctrl+t":"!~/.claude/t-keys.sh"}}' > "$I4/keybindings.json"
echo 'Run ~/.claude/t-cmd.sh' > "$I4/commands/foo"
echo 'Use ~/.claude/t-agent.sh' > "$I4/agents/bar"
OUT=$(HOME="$H4" PATH="$FAKEBIN:$PATH" bash "$REPO/tools/pickup-report.sh" --prune "$A4" "$R4")
MISSED=""
for x in "t-env.sh:$I4/settings.json" "t-cd.sh:$I4/settings.json" "t-dbl.sh:$I4/settings.json" "t-esc.sh:$I4/settings.json" \
         "t-local.sh:$I4/settings.local.json" "t-mcp.sh:$H4/.claude.json" "t-plist.sh:$H4/Library/LaunchAgents/x.plist" \
         "t-cron.sh:crontab" "t-skill.sh:$I4/skills/refs/SKILL.md" "t-uses.sh:$I4/skills/refs/forge.toml" "t-call.sh:$I4/caller.sh"; do
  n=${x%%:*}; w=${x#*:}
  [[ -f "$I4/$n" && "$OUT" == *"$I4/$n (named in $w)"* ]] || MISSED="$MISSED $n"
done
[[ -z "$MISSED" ]] \
  && pass "named in settings, settings.local, ~/.claude.json, a plist, crontab, a SKILL.md, a toml or a tool: kept, saying where" \
  || fail "references" "missed:$MISSED; $OUT"
MISSED=""
for x in "t-zsh.sh:$H4/.zshrc" "t-keys.sh:$I4/keybindings.json" "t-cmd.sh:$I4/commands/foo" "t-agent.sh:$I4/agents/bar"; do
  n=${x%%:*}; w=${x#*:}
  [[ -f "$I4/$n" && "$OUT" == *"$I4/$n (named in $w)"* ]] || MISSED="$MISSED $n"
done
[[ -z "$MISSED" ]] \
  && pass "named in ~/.zshrc, keybindings.json, or a commands/ or agents/ file of no extension: kept" \
  || fail "references, wider" "missed:$MISSED; $OUT"
[[ ! -e "$I4/t-free.sh" && "$OUT" == *"removed here"*"$I4/t-free.sh"* ]] \
  && pass "and one named nowhere is removed" || fail "unnamed removed" "$OUT"
[[ -f "$OUTSIDE/bin/helper.py" && "$OUT" == *"$I4/skills/sk/bin/helper.py (outside ~/.claude through a symlink)"* ]] \
  && pass "a copy in a skill linked from outside ~/.claude stays" || fail "symlinked skill" "$OUT"

echo ""
echo "=== --prune decides every candidate before removing any, so order does not matter ==="
# Two deleted pairs, each one file naming the other: the namer sorts first in x, last in y.
R5="$TMP/clone5"; H5="$TMP/rhome5"; I5="$H5/.claude"; mkdir -p "$R5/bin" "$I5"
echo 'exec ~/.claude/x-target.sh' > "$R5/bin/x-caller.sh"; echo v1 > "$R5/bin/x-target.sh"
echo v1 > "$R5/bin/y-a-target.sh"; echo 'exec ~/.claude/y-a-target.sh' > "$R5/bin/y-b-caller.sh"
cp "$R5"/bin/*.sh "$I5/"
g5() { git -C "$R5" -c user.name=t -c user.email=t@example.com "$@"; }
g5 init -q; g5 add -A; g5 commit -q -m A; A5=$(g5 rev-parse HEAD)
g5 rm -q bin/x-caller.sh bin/x-target.sh bin/y-a-target.sh bin/y-b-caller.sh; g5 commit -q -m B
OUT=$(HOME="$H5" PATH="$FAKEBIN:$PATH" bash "$REPO/tools/pickup-report.sh" --prune "$A5" "$R5")
[[ -f "$I5/x-target.sh" && ! -e "$I5/x-caller.sh" && "$OUT" == *"$I5/x-target.sh (named in $I5/x-caller.sh)"* \
   && -f "$I5/y-a-target.sh" && ! -e "$I5/y-b-caller.sh" && "$OUT" == *"$I5/y-a-target.sh (named in $I5/y-b-caller.sh)"* ]] \
  && pass "a named file stays and its namer goes, whichever is checked first" || fail "order" "$OUT; $(ls "$I5")"

echo ""
echo "=== a commit the clone lacks ==="
[ -z "$(report "")" ] && [ -z "$(report unknown)" ] && pass "no record prints nothing" || fail "no record" ""
OUT=$(report 0123456789abcdef0123456789abcdef01234567)
[[ "$OUT" == *"which this clone does not have; after a fetch: tools/pickup-report.sh 0123456789ab"* ]] \
  && pass "a commit the clone lacks says so and how to rerun" || fail "missing commit" "$OUT"

echo ""
echo "=== install.sh: a first install, then the next one reports from the last ==="
inst() {  # [CLONE [HOME]]
  ( export HOME="${2:-$TMP/home}" TMPDIR="$TMP" CCH_SKIP_SELFTEST=1 PATH="$FAKEBIN:$PATH"
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
# This clone's working tree, committed in a copy with files more, then installed.
C="$TMP/copy"; H="$TMP/home2"; mkdir -p "$C" "$H/.claude"
( cd "$REPO" && git ls-files -co --exclude-standard | while IFS= read -r p; do [[ -f "$p" ]] && printf '%s\n' "$p"; done > "$TMP/files" \
  && tar -cf - -T "$TMP/files" ) | tar -xf - -C "$C"
for f in bin/gone-tool.sh bin/edited-tool.sh bin/named-tool.sh rules/gone-rule.md hooks/gone-hook.sh bin/wt-tool.sh bin/case-tool.sh bin/late-tool.sh; do
  printf '#!/bin/sh\ntrue\n' > "$C/$f"
done
gc() { git -C "$C" -c user.name=t -c user.email=t@example.com "$@"; }
gc init -q && gc add -A && gc commit -q -m one
echo mine > "$H/.claude/stray.sh"
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC == 0 && -x "$H/.claude/gone-tool.sh" && -f "$H/.claude/stray.sh" && "$OUT" != *"Deleted from the clone"* ]] \
  && pass "a first install, with no record, removes nothing" || fail "first install over a stray file" "rc=$RC $(printf '%s\n' "$OUT" | tail -4)"
rm "$C/bin/wt-tool.sh"
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC == 0 && -f "$H/.claude/wt-tool.sh" && "$OUT" == *"$H/.claude/wt-tool.sh (deleted only in the working tree)"* ]] \
  && pass "an uncommitted rm, reinstalled at the same commit, is listed, not removed" || fail "uncommitted rm" "rc=$RC $(printf '%s\n' "$OUT" | grep Deleted)"
gc checkout -q -- bin/wt-tool.sh
gc rm -q bin/gone-tool.sh bin/edited-tool.sh bin/named-tool.sh rules/gone-rule.md hooks/gone-hook.sh; gc commit -q -m two
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
[[ -f "$H/.claude/named-tool.sh" && "$OUT" == *"$H/.claude/named-tool.sh (named in $S)"* ]] \
  && pass "a copy an allow rule names is kept" || fail "allow-rule copy kept" "$(printf '%s\n' "$OUT" | grep Deleted)"
[[ -f "$H/.claude/hooks/gone-hook.sh" && "$OUT" == *"$H/.claude/hooks/gone-hook.sh (named in $S)"* \
   && "$(jq -r '[.hooks.PreToolUse[].hooks[].command] | index("~/.claude/hooks/gone-hook.sh") != null' "$S")" == true ]] \
  && pass "a deleted hook settings.json still runs is kept, as the merge keeps its entry" || fail "registered hook kept" "$(printf '%s\n' "$OUT" | grep Deleted)"
gc mv bin/case-tool.sh bin/Case-tool.sh; gc commit -q -m three
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC == 0 && -f "$H/.claude/Case-tool.sh" && -f "$H/.claude/case-tool.sh" ]] \
  && pass "a file renamed only in case keeps the copy this install wrote" || fail "case rename install" "rc=$RC $(printf '%s\n' "$OUT" | grep Deleted)"
THREE=$(gc rev-parse HEAD)
gc rm -q bin/late-tool.sh; gc commit -q -m four
rm "$C/config/merge-settings.jq"
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC != 0 && "$(sed -n 's/^commit=//p' "$H/.claude/harness.version")" == "$THREE" ]] \
  && pass "an install that stops early leaves the last commit recorded" || fail "early stop" "rc=$RC $(cat "$H/.claude/harness.version")"
gc checkout -q -- config/merge-settings.jq
OUT=$(inst "$C" "$H"); RC=$?
[[ $RC == 0 && ! -e "$H/.claude/late-tool.sh" && "$OUT" == *"removed here"*"$H/.claude/late-tool.sh"* ]] \
  && pass "so the next install still removes what was deleted before it" || fail "after early stop" "rc=$RC $(printf '%s\n' "$OUT" | grep -A1 Deleted)"

echo ""
echo "=== a harness with no .git of its own, inside another repo, removes nothing ==="
O="$TMP/outer"; H3="$TMP/home3"; mkdir -p "$O/harness" "$O/bin" "$H3/.claude"
( cd "$REPO" && tar -cf - -T "$TMP/files" ) | tar -xf - -C "$O/harness"
printf '#!/bin/sh\ntrue\n' > "$O/bin/own-tool.sh"; cp "$O/bin/own-tool.sh" "$H3/.claude/own-tool.sh"
go() { git -C "$O" -c user.name=t -c user.email=t@example.com "$@"; }
go init -q && go add -A && go commit -q -m one
inst "$O/harness" "$H3" >/dev/null
go rm -q bin/own-tool.sh; go commit -q -m two
OUT=$(inst "$O/harness" "$H3"); RC=$?
[[ $RC == 0 && -f "$H3/.claude/own-tool.sh" && "$OUT" == *"$H3/.claude/own-tool.sh (the harness is not its own git repo)"* ]] \
  && pass "a file no install wrote is left alone: the outer repo's own tool" || fail "outer repo" "rc=$RC $(printf '%s\n' "$OUT" | grep -A1 Deleted)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
