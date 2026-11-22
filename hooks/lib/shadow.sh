#!/usr/bin/env bash
# hooks/lib.sh sources this: shadow mode (#237, docs/shadow-mode.md).
# An entry logs what it would have decided to shadow.log and decides nothing.
# A guard name covers all its rules; guard:rule one. Delete a line to restore it.
# Only in auto mode: each entry counts on auto mode's classifier, and another
# mode has none (default mode runs Bash(python3:*) with no prompt), so there
# the rule is live.
SHADOW=(
  kubectl-guard:mutating-verb      # these verbs ask natively, verb first or behind flags.
  kubectl-guard:subverb-change     # Not the credential reads: `get Secret`, `describe secret`
  kubectl-guard:exec               # and a kind from $( ) or xargs match a read allow rule and no
  kubectl-guard:unknown-verb       # ask rule (2.1.325), so they and the unreadable floor stay live.
                                   # So does dynamic-verb: `k(){ kubectl "$@"; }; k get secret`
                                   # never reaches secret-read, and no probe has shown the
                                   # classifier stops it when the user did not ask for it.
  kubectl-guard:input-verb         # kubectl's verb from xargs or an opaque shell-out matches no
  kubectl-guard:ambiguous-var      # allow rule, so the classifier sees it
  kubectl-guard:inline-unreadable
  kubectl-guard:inline-opaque
  kubectl-guard:inline-unchecked
  interpreter-guard                # auto mode drops Bash(python3:*), so the classifier sees inline code
  network-guard:monitor-ws-host    # the asks below: no network allow rule, so the classifier sees each.
                                   # Not allowlist-edit: a cp or echo into local-settings is allow-ruled.
  network-guard:remote-copy
  network-guard:http-server
  network-guard:curl-reroute
  network-guard:proxy-unlisted
  network-guard:sends-body
  network-guard:no-scheme
  network-guard:local-admin-api
  network-guard:host-unlisted
  network-guard:unreadable
  rm-guard:rf-outside-scratch      # rm has no allow rule, so the classifier sees it
  env-guard:bare-env               # env has no allow rule, so the classifier sees it
  peer-redirect:redirect           # the classifier refused the resend when the message had no
                                   # from-name; live once bridge messages are shown to carry it
)

# shadow_hit WOULD RULE REASON: when this guard's RULE is on the list and the call
# is in auto mode, note what it would have decided and return 0. Otherwise return
# 1, and the caller decides. A decision with no RULE (a fail-closed deny) is never
# shadowed. A payload with no permission_mode (an older Claude Code, the bench)
# counts as auto, as before this check.
shadow_hit() {
  local g=${GUARD_NAME:-${0##*/}}
  g=${g%.sh}
  [[ -n "${2:-}" ]] || return 1
  case " ${SHADOW[*]} " in *" $g "*|*" $g:$2 "*) ;; *) return 1 ;; esac
  case "$(jq_get '.permission_mode')" in auto|'') ;; *) return 1 ;; esac
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
  # The command and the reason one line each: a newline, CR or tab is a space, the
  # other control bytes go. One awk, under C as lib.sh runs every awk, reads the
  # command on stdin and the reason from its environment. exec, since lib.sh's awk()
  # or `command awk` would fork once more in a pipeline. Not ${c//…}: there bash 3.2
  # took 34 s on an 8 KB heredoc of 136 lines under en_US.UTF-8, and 4 s under C
  # (Apple M2).
  f=$(printf '%s\n' "$c" | SHADOW_WHY=$3 LC_ALL=C exec awk '
    function clean(s) { gsub(/[\n\r\t]/, " ", s); gsub(/[\001-\010\013-\037]/, "", s); return s }
    { printf "%s%s", (NR > 1 ? " " : ""), clean($0) }
    END { printf "\n%s\n", clean(ENVIRON["SHADOW_WHY"]) }' | redact_secrets)
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
