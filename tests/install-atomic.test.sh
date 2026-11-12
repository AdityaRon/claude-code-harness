#!/usr/bin/env bash
# install.sh replaces files that live sessions are running: a hook on each tool
# call, the status line, a skill's tick. Copied in place, a reader could catch a
# hook half written; one Bash call was denied with "syntax error near unexpected
# token" during an install. So every file is written beside its target and
# renamed over it. These checks do not depend on winning a race: a rename gives
# the target a new inode, and a reader holding the old file still reads it whole.
set -u
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'kill "${READER:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME SKILL_FORGE_TEMPLATES
mkdir -p "$HOME"
export CCH_SKIP_SELFTEST=1
install(){ bash "$REPO/install.sh" > "$TMP/install.log" 2>&1; }
inode(){ ls -i "$1" | awk '{print $1}'; }

install || { fail "first install" "$(tail -5 "$TMP/install.log")"; echo "--- Results: $PASS passed, $FAIL failed ---"; exit 1; }

C="$HOME/.claude"
HOOK=$(ls "$C"/hooks/*.sh | head -1)
FILES=("$HOOK" "$C/statusline.sh" "$C/memory-verify.sh" "$C/skills/comms-hub/bin/hub.py"
       "$C/skills/comms-hub/SKILL.md" "$C/rules/$(ls "$REPO/rules" | head -1)")
BEFORE=()   # by index: bash 3.2, macOS's, has no associative arrays
for i in "${!FILES[@]}"; do BEFORE[i]=$(inode "${FILES[i]}"); done

# A session mid-read: it opened the hook before the install, and its copy differs.
echo "# the copy a running session opened" >> "$HOOK"
OLD=$(cat "$HOOK")
exec 3< "$HOOK"

install || fail "second install" "$(tail -5 "$TMP/install.log")"

CHECKED=0
for i in "${!FILES[@]}"; do
  f=${FILES[i]}; CHECKED=$((CHECKED+1))
  [[ -n "${BEFORE[i]}" && "$(inode "$f")" != "${BEFORE[i]}" ]] \
    && pass "${f#"$C"/} replaced by rename (new inode)" \
    || fail "${f#"$C"/} replaced by rename" "inode ${BEFORE[i]:-unread} before and after: rewritten in place"
done
[[ "$CHECKED" -eq 6 ]] && pass "checked 6 installed files" || fail "checked 6 installed files" "checked $CHECKED"
[[ "$(cat <&3)" == "$OLD" ]] \
  && pass "a reader that opened the old hook still reads all of it" \
  || fail "a reader that opened the old hook still reads all of it" "it read the new or a partial file"
exec 3<&-
[[ "$(cat "$HOOK")" == "$(cat "$REPO/hooks/$(basename "$HOOK")")" ]] \
  && pass "the hook now holds the repo's copy" || fail "the hook now holds the repo's copy" "differs"
[[ -x "$HOOK" && -x "$C/statusline.sh" && -x "$C/harness-update.sh" ]] \
  && pass "hooks and tools stay executable" || fail "hooks and tools stay executable" "$(ls -l "$HOOK" "$C/statusline.sh")"
LEFT=$(find "$C" -name '.*.??????' -type f | head -3)
[[ -z "$LEFT" ]] && pass "no temp file left beside a target" || fail "no temp file left beside a target" "$LEFT"

# The symptom itself: parse every hook in a loop while installs run.
: > "$TMP/bad"; : > "$TMP/reads"
( while :; do for h in "$C"/hooks/*.sh; do bash -n "$h" 2>/dev/null || echo "$h" >> "$TMP/bad"; echo >> "$TMP/reads"; done; done ) &
READER=$!
for _ in 1 2 3; do install; done
kill "$READER" 2>/dev/null; wait "$READER" 2>/dev/null
READS=$(wc -l < "$TMP/reads" | tr -d ' ')
[[ ! -s "$TMP/bad" && "$READS" -gt 0 ]] \
  && pass "$READS hook parses during 3 installs, none failed" \
  || fail "hook parses during 3 installs" "$(sort "$TMP/bad" | uniq -c | head -3) of $READS reads"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit "$FAIL"
