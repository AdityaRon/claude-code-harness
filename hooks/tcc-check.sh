#!/usr/bin/env bash
# Names the cause when a Bash call hits "Operation not permitted" under
# ~/Desktop, ~/Documents, ~/Downloads or iCloud Drive: macOS privacy control
# (TCC), usually a session host whose binary an upgrade deleted (lib.sh
# host_binary_check), never file modes or the harness sandbox. Advisory,
# synchronous: exit 2 with stderr is what reaches the model.
source "$(dirname "$0")/lib.sh"

# PostToolUse sees a call that exited 0 (a denial in a pipeline or before ||);
# PostToolUseFailure sees the rest, its output in .error. Every Bash call passes
# through; the common path is one substring test on the raw payload, no jq.
read_input
case "$INPUT" in *[Oo]"peration not permitted"*) ;; *) exit 0 ;; esac
command -v jq &>/dev/null || exit 0
[[ "$(jq_get '.tool_name')" == Bash ]] || exit 0

# Only a line shaped like the error: a tool's `x: Operation not permitted`, zsh's
# `(eval):1: operation not permitted: x`, python's `[Errno 1] Operation not
# permitted`. Output that quotes the phrase (grep, cat of this file) is not one.
SHAPE=': Operation not permitted[[:space:]]*$|^[^[:space:]]+: operation not permitted: |\[Errno 1\] Operation not permitted'
LINES=$(printf '%s\n' "$INPUT" \
  | jq -r '(.error | strings), (.tool_response | if type == "object" then .stdout, .stderr else . end | strings)' 2>/dev/null \
  | grep -E -- "$SHAPE")
[[ -n "$LINES" ]] || exit 0

CWD=$(jq_get '.cwd'); H=${HOME%/}
FOLDERS=(Desktop Documents Downloads "Library/Mobile Documents")
ABS="(^|[[:space:]'\"(=])/"
REL="(^|[[:space:]'\"])(Desktop|Documents|Downloads|Library/Mobile Documents)(/|:|'|\"|[[:space:]]|$)"
under() {   # is the path $1 in a protected folder?
  local f
  for f in "${FOLDERS[@]}"; do [[ "$1" == "$H/$f" || "$1" == "$H/$f/"* ]] && return 0; done
  return 1
}
names() {   # does the line $1 name a path in a protected folder?
  local f
  for f in "${FOLDERS[@]}"; do [[ "$1" == *"$H/$f" || "$1" == *"$H/$f"[/:\'\"[:space:]]* ]] && return 0; done
  return 1
}
# A line naming an absolute path is judged by it; one naming none (getcwd, a
# relative path) by the cwd, or from the home folder by a `Desktop/...` it names.
HIT=""
while IFS= read -r l; do
  if names "$l"; then HIT=$l; break; fi
  [[ "$l" =~ $ABS ]] && continue
  if under "$CWD" || { [[ "$CWD" == "$H" ]] && [[ "$l" =~ $REL ]]; }; then HIT=$l; break; fi
done <<< "$LINES"
[[ -n "$HIT" ]] || exit 0

{
  echo "tcc-check: 'Operation not permitted' under ~/Desktop, ~/Documents, ~/Downloads or iCloud Drive is macOS privacy control (TCC), not file modes and not the harness sandbox."
  echo "From: ${HIT:0:300}"
  if ! host_binary_check; then :
  else
    echo "This session's host binary exists, so the folder was never granted to it, or the grant was revoked: System Settings > Privacy & Security > Files and Folders, or run the command from a terminal session. A clone outside those folders is unaffected: ~/.claude/relocate-clones.sh moves one."
  fi
} >&2
exit 2
