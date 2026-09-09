#!/usr/bin/env bash
# Central audit log. Handles:
#   PostToolUse      — file edits/writes (async)
#   PostToolUseFailure — failed tool calls (async)
#   PermissionDenied — a tool call auto mode refused (async)
#   ConfigChange     — settings file modified mid-session (async)
#   SessionEnd       — session summary, once per session (blocking)
#   Stop             — same summary shape; accepted so the hook still works if
#                      wired to Stop, but note Stop fires at every turn end, so
#                      the harness wires the summary to SessionEnd instead.
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
  Stop|SessionEnd)
    # Neither payload carries turn count or cost, so derive the turn count
    # (assistant messages) from the transcript when available. Cost is not
    # exposed to hooks; don't log a dead placeholder for it.
    TURNS=$(jq_get '.num_turns')
    if [[ -z "$TURNS" ]]; then
      TRANSCRIPT=$(jq_get '.transcript_path')
      TRANSCRIPT=$(expand_tilde "$TRANSCRIPT")
      if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] && command -v jq &>/dev/null; then
        TURNS=$(jq -rs '[.[] | select((.message.role? // .role?) == "assistant")] | length' "$TRANSCRIPT" 2>/dev/null)
      fi
    fi
    SID=$(jq_get '.session_id')
    # SessionEnd carries why the session ended (clear / logout / exit / other);
    # Stop does not, so the field is appended only when present.
    REASON=$(sanitize "$(jq_get '.reason')")
    log_audit "$TS | session_end | turns=${TURNS:-n/a} session=${SID:-?}${REASON:+ reason=$REASON} | $DIR"
    ;;
  PostToolUseFailure)
    TOOL=$(sanitize "$(jq_get '.tool_name')")
    ERR=$(sanitize "$(jq_get '.error')")
    log_audit "$TS | FAILED | ${TOOL:-unknown} | ${ERR:-unknown error} | $DIR"
    ;;
  PermissionDenied)
    # Under defaultMode auto the classifier resolves prompts a human used to
    # see, so this log recorded every ATTEMPT but never the verdict. Working
    # out what was actually being refused meant re-deriving the rule matcher
    # over 40k logged commands; with this arm it is a grep.
    #
    # Needs its own case: falling through to the catch-all below would log a
    # refused command in the same shape as one that ran.
    #
    # Log-only. No `retry` field is emitted, so the denial stands exactly as
    # decided — this arm observes, it does not overturn.
    TOOL=$(sanitize "$(jq_get '.tool_name')")
    WHY=$(sanitize "$(jq_get '.denial_reason')")
    if [[ "$TOOL" == "Bash" ]]; then
      TARGET=$(sanitize "$(jq_get '.tool_input.command')")
    else
      TARGET=$(sanitize "$(jq_get '.tool_input.file_path')")
      [[ -z "$TARGET" ]] && TARGET=$(sanitize "$(jq_get '.tool_input.path')")
    fi
    log_audit "$TS | DENIED | ${TOOL:-unknown} | ${TARGET:-unknown} | ${WHY:-no reason given} | $DIR"
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
