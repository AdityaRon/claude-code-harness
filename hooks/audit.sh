#!/usr/bin/env bash
# Central audit log. Handles:
#   PostToolUse      — file edits/writes (async)
#   PostToolUseFailure — failed tool calls (async)
#   PermissionDenied — a tool call auto mode refused (async)
#   PostModelSwitch  — the session changed model (async)
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
  PostModelSwitch)
    # Which model produced a given conclusion is otherwise unrecoverable: every
    # other line here is `<ts> | <tool> | <target> | <dir>` with no model field,
    # so a mid-session switch — deliberate or an automatic fallback — leaves no
    # trace at all. For a long background session doing analysis, that is the
    # difference between "this finding came from the model I chose" and a guess.
    #
    # Post, not Pre: PreModelSwitch can block, and gating the model picker is
    # friction with no security gain. This arm only observes.
    #
    # Field names are read defensively. The payload is documented as snake_case
    # (from_model/to_model); the camelCase fallback costs one jq call and avoids
    # logging "unknown -> unknown" if that ever differs in practice.
    FROM=$(jq_get '.from_model'); [[ -z "$FROM" ]] && FROM=$(jq_get '.fromModel')
    TO=$(jq_get '.to_model');     [[ -z "$TO" ]]   && TO=$(jq_get '.toModel')
    log_audit "$TS | model_switch | $(sanitize "${FROM:-unknown}") -> $(sanitize "${TO:-unknown}") | $DIR"
    ;;
  ConfigChange)
    FILE=$(sanitize "$(jq_get '.file_path')")
    log_audit "$TS | config_change | ${FILE:-unknown} | $DIR"
    ;;
  *)
    TOOL=$(sanitize "$(jq_get '.tool_name')")
    if [[ "$TOOL" == mcp__* ]]; then
      # MCP tools reach outside this machine (mail, drive, calendar, browser)
      # and no PreToolUse guard sees them, so this line is the only record a
      # call happened. Field NAMES only: a send_message payload carries the
      # message body, and the audit log is not the place for it.
      KEYS=$(sanitize "$(jq_get '[(.tool_input // {}) | keys_unsorted[]] | join(",")')")
      log_audit "$TS | ${TOOL} | keys=${KEYS:-none} | $DIR"
    elif [[ "$TOOL" == "Agent" ]]; then
      # Evidence for subagent model and fan-out decisions. Never the prompt.
      TYPE=$(sanitize "$(jq_get '.tool_input.subagent_type')")
      MODEL=$(sanitize "$(jq_get '.tool_input.model')")
      ISO=$(sanitize "$(jq_get '.tool_input.isolation')")
      log_audit "$TS | Agent | type=${TYPE:-general-purpose} model=${MODEL:-inherit} isolation=${ISO:-none} | $DIR"
    elif [[ "$TOOL" == "SendMessage" ]]; then
      # Peer messages can ask another session to act; the recipient's own hooks
      # still gate that, but this is the sender-side record. Never the body.
      TO=$(sanitize "$(jq_get '.tool_input.to')")
      LEN=$(jq_get '(.tool_input.message // "") | length')
      NOTIFY=$(jq_get '.tool_input.notify_when_idle')
      log_audit "$TS | SendMessage | to=${TO:-unknown} chars=${LEN:-0} notify_when_idle=${NOTIFY:-false} | $DIR"
    elif [[ "$TOOL" == Artifact* ]]; then
      # Publishes to claude.ai. WebFetch rules stopped covering these in 2.1.268
      # and no guard sees them, so this is the only record. Never data or text.
      ACT=$(sanitize "$(jq_get '.tool_input.action')")
      URL=$(sanitize "$(jq_get '.tool_input.url')")
      case "$TOOL" in
        Artifact)         EXTRA="file=$(sanitize "$(jq_get '.tool_input.file_path')")" ;;
        ArtifactData)     EXTRA="collection=$(sanitize "$(jq_get '.tool_input.collection')") doc=$(sanitize "$(jq_get '.tool_input.doc_id')")" ;;
        ArtifactComments) EXTRA="thread=$(sanitize "$(jq_get '.tool_input.thread_id')")" ;;
        *)                EXTRA="" ;;
      esac
      log_audit "$TS | $TOOL | action=${ACT:-publish} url=${URL:-new} ${EXTRA} | $DIR"
    elif [[ "$TOOL" == "Bash" ]]; then
      CMD=$(sanitize "$(jq_get '.tool_input.command')")
      log_audit "$TS | Bash | ${CMD:-unknown} | $DIR"
    else
      FILE=$(sanitize "$(jq_get '.tool_input.file_path')")
      [[ -z "$FILE" ]] && FILE=$(sanitize "$(jq_get '.tool_input.path')")
      log_audit "$TS | ${TOOL:-unknown} | ${FILE:-unknown} | $DIR"
    fi
    ;;
esac
