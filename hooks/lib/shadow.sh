#!/usr/bin/env bash
# hooks/lib.sh sources this: shadow mode (#237, docs/shadow-mode.md).
# An entry logs what it would have decided to shadow.log and decides nothing.
# A guard name covers all its rules; guard:rule one. Delete a line to restore it.
SHADOW=(
  kubectl-guard                    # read verbs are allowed by prefix, mutating verbs ask natively (#241)
  interpreter-guard                # auto mode drops Bash(python3:*), so the classifier sees inline code
  network-guard:monitor-ws-host    # the asks below: no network allow rule, so the classifier sees each
  network-guard:remote-copy
  network-guard:http-server
  network-guard:allowlist-edit
  network-guard:curl-reroute
  network-guard:proxy-unlisted
  network-guard:sends-body
  network-guard:no-scheme
  network-guard:local-admin-api
  network-guard:host-unlisted
  network-guard:unreadable
  rm-guard:rf-outside-scratch      # rm has no allow rule, so the classifier sees it
  env-guard:bare-env               # env has no allow rule, so the classifier sees it
)

# shadow_hit WOULD RULE REASON: when this guard's RULE is on the list, note what
# it would have decided and return 0. Otherwise return 1, and the caller decides.
# A decision with no RULE (a fail-closed deny) is never shadowed.
shadow_hit() {
  local g=${GUARD_NAME:-${0##*/}}
  g=${g%.sh}
  [[ -n "${2:-}" ]] || return 1
  case " ${SHADOW[*]} " in *" $g "*|*" $g:$2 "*) ;; *) return 1 ;; esac
  shadow_note "$1" "$2" "$3"
  return 0
}

# decide ask|deny RULE REASON: the guard's answer, and the guard ends. A shadowed
# RULE is noted instead, and the guard goes on as if the rule were not there, so a
# live deny after it still denies. A guard shadowed whole has nothing live after.
decide() {
  if shadow_hit "$@"; then
    local g=${GUARD_NAME:-${0##*/}}
    case " ${SHADOW[*]} " in *" ${g%.sh} "*) exit 0 ;; esac
    return 0
  fi
  "emit_$1" "$3"
  exit 0
}

# shadow_relay OUT: a run of this guard on the joined lines (joined_pass) or on an
# inline script's shell-out reports a shadowed hit as a line of OUT; note it here.
shadow_relay() {
  [[ "$1" == *'"shadowHit":'* ]] || return 0
  local f w r
  f=$(printf '%s' "$1" | jq -j 'select(type == "object" and has("shadowHit")) | .shadowHit
    | (.would // ""), "\u001f", (.rule // ""), "\u001f", (.reason // ""), "\u001e"' 2>/dev/null) || return 0
  f=${f%%$'\036'*}
  [[ "$f" == *$'\037'*$'\037'* ]] || return 0
  w=${f%%$'\037'*}; f=${f#*$'\037'}; r=${f%%$'\037'*}
  shadow_note "$w" "$r" "${f#*$'\037'}"
}

# One line a guard a call: the first hit, as the guard would have stopped there.
# A run under another (joined_pass, an inline shell-out) prints it for that one
# to note instead. The command and reason are cleaned as audit.sh cleans a field
# (one line, no control bytes, secrets redacted), redacted before the cut.
shadow_note() {   # WOULD RULE REASON
  [[ -z "${SHADOW_NOTED:-}" ]] || return 0
  SHADOW_NOTED=1
  if [[ -n "${JOINED_PASS:-}" || "${HARNESS_SHELLOUT_DEPTH:-0}" != 0 ]]; then
    jq -nc --arg w "$1" --arg r "$2" --arg why "$3" '{shadowHit:{would:$w, rule:$r, reason:$why}}' 2>/dev/null
    return 0
  fi
  local g=${GUARD_NAME:-${0##*/}} c why f log line
  g=${g%.sh}
  c=$(jq_get '.tool_input.command'); [[ -n "$c" ]] || c=$(jq_get '.tool_input.ws.url')
  c=${c//[$'\n\r\t']/ }; why=${3//[$'\n\r\t']/ }
  f=$(printf '%s\n%s\n' "$c" "$why" | LC_ALL=C tr -d '\000-\011\013-\037' | redact_secrets)
  { IFS= read -r c; IFS= read -r why; } <<<"$f"
  line=$(jq -nc --arg s "$(jq_get '.session_id')" --arg id "$(jq_get '.tool_use_id')" --arg m "$(jq_get '.permission_mode')" \
    --arg g "$g" --arg r "$2" --arg why "$why" --arg w "$1" --arg t "$(jq_get '.tool_name')" --arg c "$c" \
    '{ts:(now | todate), session_id:$s, tool_use_id:$id, permission_mode:$m, guard:$g, rule:$r,
      reason:$why[0:300], would:$w, tool:$t, command:$c[0:200]}' 2>/dev/null) || return 0
  log=$(expand_tilde "${CLAUDE_SHADOW_LOG:-$HOME/.claude/logs/shadow.log}")
  [[ -d "${log%/*}" ]] || mkdir -p "${log%/*}" 2>/dev/null || return 0
  [[ -e "$log" ]] || (umask 077; : >> "$log") 2>/dev/null
  { printf '%s\n' "$line" >> "$log"; } 2>/dev/null
  return 0
}
