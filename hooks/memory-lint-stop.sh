#!/usr/bin/env bash
# End-of-turn half of memory-lint.sh: reports a memory still without its
# MEMORY.md line, or a handoff whose STATE: is older than its last recorded write.
# Output is additionalContext (Stop hook feedback, no error notice), once: the
# list is emptied as it is read. Nothing pending starts no process, loads no lib.sh.

IN=""
[ -t 0 ] || IFS= read -r -d '' IN || true
SID_RE='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)"'
[[ $IN =~ $SID_RE ]] || exit 0
SID=${BASH_REMATCH[1]}
PEND_ROOT=${CLAUDE_STATE_DIR:-$HOME/.claude/state/sessions}; PEND_ROOT=${PEND_ROOT/#\~/$HOME}/lint-pending
PEND="$PEND_ROOT/$SID"
[ -s "$PEND" ] || exit 0

# Claude Code is already continuing because of a Stop hook: say nothing, keep the list.
ACT_RE='"stop_hook_active"[[:space:]]*:[[:space:]]*true'
[[ $IN =~ $ACT_RE ]] && exit 0

source "${0%/*}/lib.sh"   # PATH for jq; nothing before this point needed it

# The list, newest write last: a memory once, a handoff at its last write's time.
KINDS=() PATHS=() EPOCHS=()
while IFS=' ' read -r t f || [ -n "$t" ]; do
  [[ "$t" =~ ^[0-9]+$ && -n "$f" ]] || continue
  k=memory; [[ "$f" == */trackers/* ]] && k=handoff
  i=0; found=""
  while [ "$i" -lt "${#PATHS[@]}" ]; do
    [ "${PATHS[$i]}" = "$f" ] && { EPOCHS[$i]=$t; found=1; break; }
    i=$((i + 1))
  done
  [ -n "$found" ] || { KINDS[${#PATHS[@]}]=$k; EPOCHS[${#PATHS[@]}]=$t; PATHS[${#PATHS[@]}]=$f; }
done < "$PEND"
: > "$PEND"   # read once; a second Stop has nothing to say

has_line() {  # DIR BASE: a line pointing at BASE in MEMORY.md or MEMORY_ARCHIVE.md
  local fl l
  for fl in "$1/MEMORY.md" "$1/MEMORY_ARCHIVE.md"; do
    [ -f "$fl" ] || continue
    while IFS= read -r l || [ -n "$l" ]; do
      [[ "$l" == *"($2)"* ]] && return 0
    done < "$fl"
  done
  return 1
}

# Each handoff's STATE: stamp, one line apiece (empty for none), converted by one jq.
STAMPS="" n=0 i=0
while [ "$i" -lt "${#PATHS[@]}" ]; do
  if [ "${KINDS[$i]}" = handoff ] && [ -f "${PATHS[$i]}" ]; then
    s=""
    while IFS= read -r l || [ -n "$l" ]; do
      [[ "$l" == STATE:* ]] && { s=${l#STATE:}; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; break; }
    done < "${PATHS[$i]}"
    STAMPS="$STAMPS$s"$'\n'; n=$((n + 1))
  fi
  i=$((i + 1))
done
SEC=()
if [ "$n" -gt 0 ] && command -v jq &>/dev/null; then
  while IFS= read -r l; do SEC[${#SEC[@]}]=$l; done < <(
    jq -nr --arg s "${STAMPS%$'\n'}" '$s | split("\n")[]
      | if . == "" then "none" else . as $x | (try ($x | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch (try ($x | strptime("%Y-%m-%dT%H:%MZ") | mktime) catch "bad")) | tostring end' 2>/dev/null)
fi

MSG="" i=0 h=0
while [ "$i" -lt "${#PATHS[@]}" ]; do
  f=${PATHS[$i]}; b=${f##*/}
  if [ "${KINDS[$i]}" = memory ]; then
    if [ -f "$f" ] && ! has_line "${f%/*}" "$b"; then
      MSG="$MSG- no line in MEMORY.md points at $b, so it will never be recalled. Add one, in the section for its type; a lesson under a principle hub has its line in MEMORY_ARCHIVE.md instead.
"
    fi
  elif [ -f "$f" ]; then
    e=${SEC[$h]:-none}; h=$((h + 1))
    if [[ "$e" =~ ^-?[0-9]+$ ]] && [ "$e" -lt $(( ${EPOCHS[$i]} - 300 )) ]; then
      MSG="$MSG- $b: its STATE: stamp is $(( (${EPOCHS[$i]} - e) / 60 )) min older than your last edit of it. Refresh it from \`date -u +%Y-%m-%dT%H:%MZ\`.
"
    fi
  fi
  i=$((i + 1))
done
[ -n "$MSG" ] || exit 0

MSG="memory-lint, end of turn:
$MSG"
MSG=${MSG//\\/\\\\}; MSG=${MSG//\"/\\\"}; MSG=${MSG//$'\n'/\\n}
printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"%s"}}\n' "$MSG"
exit 0
