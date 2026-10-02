#!/usr/bin/env bash
# Desktop notification when Claude needs input, titled with the session's name
# so one of several sessions can be told apart.
source "$(dirname "$0")/lib.sh"

read_input
MSG=$(jq_get '.message'); MSG=${MSG:-Claude needs your attention}
CWD=$(jq_get '.cwd')
TRANSCRIPT=$(jq_get '.transcript_path')

# Neither the hook input nor a mod's $.session carries the name; the transcript
# does. Claude Code re-appends its title records every few lines (720 times in a
# 16 MB transcript), so the last 256 KB holds the current one in ~10 ms. A /rename
# title outranks the generated one.
session_name() {
  [[ -f "$TRANSCRIPT" ]] && command -v jq &>/dev/null || return 0
  local pick='[inputs | fromjson? | select(type == "object")] as $r
    | ([$r[] | select(.type == "custom-title") | .customTitle] | last)
      // ([$r[] | select(.type == "agent-name") | .agentName] | last)
      // ([$r[] | select(.type == "ai-title") | .aiTitle] | last) // empty'
  local pat='"type":"(custom-title|agent-name|ai-title)"' name
  name=$(tail -c 262144 "$TRANSCRIPT" | LC_ALL=C grep -aE "$pat" | jq -rRn "$pick" 2>/dev/null)
  # A new session may not have a title yet; only then is the whole file read.
  [[ -z "$name" ]] && name=$(LC_ALL=C grep -aE "$pat" "$TRANSCRIPT" | jq -rRn "$pick" 2>/dev/null)
  printf '%s' "$name" | tr -d '\000-\037' | cut -c1-80
}
NAME=$(session_name)
NAME=${NAME:-${CWD##*/}}
TITLE="Claude Code${NAME:+ · $NAME}"

if [[ -n "${CLAUDE_NOTIFY_DRY_RUN:-}" ]]; then
  printf '%s\n%s\n' "$TITLE" "$MSG"     # test seam
elif command -v osascript &>/dev/null; then
  # Passed as arguments, never spliced into the script: the name is model-written.
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' "$TITLE" "$MSG" 2>/dev/null || true
elif command -v notify-send &>/dev/null; then
  notify-send -- "$TITLE" "$MSG" 2>/dev/null || true
fi
