#!/usr/bin/env bash
# PreToolUse on SendMessage. isolatePeerMachines asks on every bridge: address,
# even one whose session runs here (CLI 2.1.330 checks the scheme only). When one
# live session here registered the id, deny and point at its ListAgents row.
# Fails open: the slow path runs in a subshell, so nothing here can block a send.
# A send without "bridge:session_" in it starts no process and loads no lib.sh.

[[ ${CLAUDE_PEER_REDIRECT:-} == off ]] && exit 0
IN=""
[ -t 0 ] || IFS= read -r -d '' IN || true
[[ $IN == *'bridge:session_'* ]] || exit 0

START_RE='^[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]'
NAME_RE='^[A-Za-z0-9 ._/-]{1,80}$'
live() {  # PID PROCSTART: running, and the process the registry row names (not a reused pid)
  kill -0 "$1" 2>/dev/null || return 1
  [[ $2 =~ $START_RE ]] || return 0   # no start time recorded
  local now; now=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)
  [[ ${now// /} == "${2// /}" ]]
}

redirect() {
  { if [[ "$0" == */* ]]; then source "${0%/*}/lib.sh"; else source ./lib.sh; fi; } 2>/dev/null || exit 0   # PATH for jq
  declare -F shadow_hit >/dev/null || exit 0
  # shellcheck disable=SC2034  # shadow_hit reads the payload through lib.sh's jq_get
  INPUT=$IN
  local f c TO SID MODE ID SESS row pid sock owner start name SOCK="" NAME="" LIVE=0 SAME=0
  f=$(printf '%s' "$IN" | jq -r '[.tool_input.to, .session_id, .permission_mode] | map(. // "" | tostring) | @tsv' 2>/dev/null) || exit 0
  TO=${f%%$'\t'*}; f=${f#*$'\t'}; SID=${f%%$'\t'*}; MODE=${f#*$'\t'}
  [[ $TO =~ ^bridge:(session_[A-Za-z0-9]+)$ ]] || exit 0
  ID=${BASH_REMATCH[1]}

  # The CLI's registry of its live sessions on this machine, one <pid>.json each.
  SESS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions
  for f in "$SESS"/*.json; do
    [ -f "$f" ] || continue
    c=""; IFS= read -r -d '' c < "$f"
    [[ $c == *"\"$ID\""* ]] || continue   # cheap: only a file naming the id is parsed
    row=$(jq -r --arg id "$ID" 'select(type == "object" and .bridgeSessionId == $id)
      | [.pid, .messagingSocketPath, .sessionId, .procStart, .name] | map(. // "" | tostring) | @tsv' "$f" 2>/dev/null)
    pid=${row%%$'\t'*}; row=${row#*$'\t'}; sock=${row%%$'\t'*}; row=${row#*$'\t'}
    owner=${row%%$'\t'*}; row=${row#*$'\t'}; start=${row%%$'\t'*}; name=${row#*$'\t'}
    [[ $pid =~ ^[1-9][0-9]*$ ]] || continue       # also: not JSON, or the id only in another field
    [[ -n $SID && $owner == "$SID" ]] && exit 0   # the sender itself: nothing to redirect
    live "$pid" "$start" || continue
    [[ $sock =~ ^/[A-Za-z0-9._/-]+$ && -S $sock ]] || continue
    LIVE=$((LIVE + 1)); SOCK=$sock NAME=$name
  done
  [ "$LIVE" -eq 1 ] || exit 0   # none, or two claiming one id: leave it to the CLI

  # The name goes out as an address: plain text only, no ':' (an address or a
  # label-like instruction), and no other live session here with the same name.
  [[ $NAME =~ $NAME_RE ]] || exit 0
  for f in "$SESS"/*.json; do
    [ -f "$f" ] || continue
    c=""; IFS= read -r -d '' c < "$f"
    [[ $c == *"\"name\":\"$NAME\""* ]] || continue
    row=$(jq -r --arg n "$NAME" 'select(type == "object" and .name == $n)
      | [.pid, .sessionId, .procStart] | map(. // "" | tostring) | @tsv' "$f" 2>/dev/null)
    pid=${row%%$'\t'*}; row=${row#*$'\t'}; owner=${row%%$'\t'*}; start=${row#*$'\t'}
    [[ $pid =~ ^[1-9][0-9]*$ && $owner != "$SID" ]] && live "$pid" "$start" && SAME=$((SAME + 1))
  done
  [ "$SAME" -eq 1 ] || exit 0

  WHY="Harness hook peer-redirect: $TO is the Remote Control address of the session named '$NAME', running on this machine. Run ListAgents, then send the same message to '$NAME' as it is listed there on this machine (its name [ref]): delivered locally with no cross-machine approval. If it is not listed, it is restarting: wait a minute and list again."
  case $MODE in
    default|acceptEdits) ;;                                  # probed live: no classifier in between
    auto|'') shadow_hit deny redirect "$WHY" && exit 0 ;;    # live; peer-redirect:redirect in shadow.sh mutes it
    *) exit 0 ;;                                             # plan, bypassPermissions: not probed
  esac
  log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) | PEER | redirect | $TO -> name=$NAME, uds:$SOCK | $PWD"
  jq -nc --arg r "$WHY" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

OUT=$(redirect)
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
