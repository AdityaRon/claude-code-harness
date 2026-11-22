#!/usr/bin/env bash
# PreToolUse on SendMessage. isolatePeerMachines asks on every bridge: address,
# even one whose session runs here (CLI 2.1.330 checks the scheme only). When one
# live session here registered the id, deny and name it (its uds: socket as the
# fallback); the resend gets the usual check, no cross-machine prompt. Fails open:
# a failure leaves the CLI's own prompt. A send without "bridge:session_" in it
# starts no process and loads no lib.sh.

[[ ${CLAUDE_PEER_REDIRECT:-} == off ]] && exit 0
IN=""
[ -t 0 ] || IFS= read -r -d '' IN || true
[[ $IN == *'bridge:session_'* ]] || exit 0

if [[ "$0" == */* ]]; then source "${0%/*}/lib.sh"; else source ./lib.sh; fi   # PATH for jq, log_audit

FIELDS=$(printf '%s' "$IN" | jq -r '[(.tool_input.to // "" | tostring), (.session_id // "" | tostring)] | @tsv' 2>/dev/null) || exit 0
TO=${FIELDS%%$'\t'*}
SID=${FIELDS#*$'\t'}
[[ $TO =~ ^bridge:(session_[A-Za-z0-9]+)$ ]] || exit 0
ID=${BASH_REMATCH[1]}

# The CLI's registry of its live sessions on this machine, one <pid>.json each.
SESS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions
SOCK="" NAME="" LIVE=0
for f in "$SESS"/*.json; do
  [ -f "$f" ] || continue
  c=""; IFS= read -r -d '' c < "$f"
  [[ $c == *"\"$ID\""* ]] || continue   # cheap: only a file naming the id is parsed
  row=$(jq -r --arg id "$ID" 'select(type == "object" and .bridgeSessionId == $id)
    | [(.pid | tostring), (.messagingSocketPath // "" | tostring), (.sessionId // "" | tostring), (.name // "" | tostring)] | @tsv' "$f" 2>/dev/null)
  pid=${row%%$'\t'*}; rest=${row#*$'\t'}; sock=${rest%%$'\t'*}; rest=${rest#*$'\t'}; owner=${rest%%$'\t'*}; name=${rest#*$'\t'}
  [[ $pid =~ ^[0-9]+$ ]] || continue            # also: not JSON, or the id only in another field
  [[ -n $SID && $owner == "$SID" ]] && exit 0   # the sender itself: nothing to redirect
  kill -0 "$pid" 2>/dev/null || continue        # a file left by a session that ended
  [ -S "$sock" ] || continue                    # no socket: not reachable locally
  LIVE=$((LIVE + 1)); SOCK=$sock NAME=$name
done
[ "$LIVE" -eq 1 ] || exit 0   # none, or two claiming one id: leave it to the CLI

# Redirect to the name as ListAgents lists it: auto mode's classifier denied
# resends to a uds: path named only in a deny. The name goes out verbatim as an
# address, so one that is not plain text is left to the CLI.
NAME_RE='^[A-Za-z0-9 ._:/-]{1,80}$'
[[ $NAME =~ $NAME_RE ]] || exit 0
WHY="Harness hook peer-redirect: $TO is the Remote Control address of '$NAME', a session running on this machine. Run ListAgents, then send the same message to '$NAME' as it is listed there on this machine (its name [ref]): delivered locally with no cross-machine approval. If it is not listed, it is restarting: wait a minute and list again."
# shellcheck disable=SC2034  # shadow_hit reads the payload through lib.sh's jq_get
INPUT=$IN
shadow_hit deny redirect "$WHY" && exit 0   # auto mode: on the shadow list (docs/shadow-mode.md)
log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) | PEER | redirect | $TO -> name=$NAME, uds:$SOCK | $PWD"
jq -nc --arg r "$WHY" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
