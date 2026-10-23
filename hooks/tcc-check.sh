#!/usr/bin/env bash
# Names the cause when a Bash call fails with "Operation not permitted" under
# ~/Desktop, ~/Documents or ~/Downloads: macOS privacy control (TCC), usually a
# session host whose binary an upgrade deleted (lib.sh host_binary_check), never
# file modes or the harness sandbox. Advisory, synchronous: exit 2 with stderr
# is what reaches the model. Every Bash call passes through; the common path is
# one substring test on the raw payload, no jq.
source "$(dirname "$0")/lib.sh"

read_input
case "$INPUT" in *"Operation not permitted"*) ;; *) exit 0 ;; esac
command -v jq &>/dev/null || exit 0
[[ "$(jq_get '.tool_name')" == Bash ]] || exit 0
# In the result, not only in the command text.
case "$(jq_get '.tool_response | tostring')" in *"Operation not permitted"*) ;; *) exit 0 ;; esac

CWD=$(jq_get '.cwd'); CMD=$(jq_get '.tool_input.command')
H=${HOME%/}
tcc_folder() {   # is $1 (a path) or $2 (command text) under a TCC-protected folder?
  local f
  for f in Desktop Documents Downloads "Library/Mobile Documents"; do
    [[ "$1" == "$H/$f" || "$1" == "$H/$f/"* ]] && return 0
    case "$2" in *"~/$f"*|*"\$HOME/$f"*|*"$H/$f"*) return 0 ;; esac
  done
  return 1
}
tcc_folder "$CWD" "$CMD" || exit 0

{
  echo "tcc-check: 'Operation not permitted' under ~/Desktop, ~/Documents or ~/Downloads is macOS privacy control (TCC), not file modes and not the harness sandbox."
  if ! host_binary_check; then :
  else
    echo "This session's host binary exists, so the folder was never granted to it, or the grant was revoked: System Settings > Privacy & Security > Files and Folders, or run the command from a terminal session. A clone outside those folders is unaffected: bin/relocate-clones.sh moves one."
  fi
} >&2
exit 2
