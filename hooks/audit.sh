#!/usr/bin/env bash
# Central audit log. Handles:
#   PostToolUse      — file edits/writes (async)
#   PostToolUseFailure — failed tool calls (async)
#   ConfigChange     — settings file modified mid-session (async)
#   Stop             — session summary (blocking, so cost is captured before exit)
source "$(dirname "$0")/lib.sh"

read_input
EVENT=$(jq_get '.hook_event_name')
[[ -z "$EVENT" ]] && EVENT="unknown"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DIR=$(pwd)

# Collapse newlines, tabs, and control chars to single spaces so one log
# line stays on one line even if the source field contains raw stderr.
sanitize() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | head -c 200
}

case "$EVENT" in
  Stop)
    TURNS=$(jq_get '.num_turns')
    COST=$(jq_get '.usage.total_cost_usd')
    log_audit "$TS | session_end | turns=${TURNS:-?} cost_usd=${COST:-?} | $DIR"
    ;;
  PostToolUseFailure)
    TOOL=$(sanitize "$(jq_get '.tool_name')")
    ERR=$(sanitize "$(jq_get '.error')")
    log_audit "$TS | FAILED | ${TOOL:-unknown} | ${ERR:-unknown error} | $DIR"
    ;;
  ConfigChange)
    FILE=$(sanitize "$(jq_get '.file_path')")
    log_audit "$TS | config_change | ${FILE:-unknown} | $DIR"
    ;;
  *)
    TOOL=$(sanitize "$(jq_get '.tool_name')")
    if [[ "$TOOL" == "Bash" ]]; then
      CMD=$(sanitize "$(jq_get '.tool_input.command')")
      log_audit "$TS | Bash | ${CMD:-unknown} | $DIR"
    else
      FILE=$(sanitize "$(jq_get '.tool_input.file_path')")
      [[ -z "$FILE" ]] && FILE=$(sanitize "$(jq_get '.tool_input.path')")
      log_audit "$TS | ${TOOL:-unknown} | ${FILE:-unknown} | $DIR"
    fi
    ;;
esac
