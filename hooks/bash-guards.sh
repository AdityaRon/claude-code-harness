#!/usr/bin/env bash
# The Bash and Monitor guards as one PreToolUse hook. One jq reads the payload,
# then each guard runs as a fork with those fields preset (lib.sh), all at once.
# Seven hooks each started bash, loaded lib.sh and ran jq; this is one start, and
# forks, which exec nothing, for the rest. Decisions, reasons and audit lines
# stay each guard's own; docs/guards.md says how to switch one off.

# The shipped list, in the order the seven entries had in settings.json.
BG_GUARDS=(env-guard git-guard interpreter-guard kubectl-guard network-guard rm-guard config-guard)

# An exit before the end is made exit 2, a block on every Claude Code. A signal
# runs this but keeps its own status (143, 129, 130), and SIGKILL runs nothing:
# those block through onFailure, from 2.1.295.
BG_DONE=""
bg_exit() {
  [[ -n "$BG_DONE" ]] && return 0
  echo "Blocked: bash-guards stopped before every Bash guard had answered, so this call was not checked. Retry; if it repeats, run bash ~/.claude/hooks/bash-guards.sh by hand on the payload." >&2
  exit 2
}
trap bg_exit EXIT
unset HARNESS_PRESET GUARD_NAME GUARD_SELF

# Every guard starts with source "$(dirname "$0")/lib.sh": seven execs a call.
# This is POSIX dirname without one.
dirname() {
  local p=$1
  case "$p" in *[!/]*) ;; '') printf '.\n'; return 0 ;; *) printf '/\n'; return 0 ;; esac
  p=${p%"${p##*[!/]}"}
  case "$p" in */*) ;; *) printf '.\n'; return 0 ;; esac
  p=${p%/*}
  p=${p%"${p##*[!/]}"}
  printf '%s\n' "${p:-/}"
}
BG_DIR=$(dirname "$0")
source "$BG_DIR/lib.sh" && declare -F read_input jq_get emit_deny log_decision >/dev/null || exit 1
# A lib.sh without the seams would have each fork read an empty stdin and allow.
case "$(declare -f read_input)" in *HARNESS_PRESET*) ;; *)
  BG_DONE=1; echo "Blocked: $BG_DIR/lib.sh is older than bash-guards.sh, so the Bash guards cannot run. Run bash install.sh from the harness clone." >&2; exit 2 ;;
esac

read_input
if [[ -z "$INPUT" ]]; then BG_DONE=1; exit 0; fi
command -v jq &>/dev/null || { BG_DONE=1; require_jq_or_deny; BG_DONE=""; exit 1; }

# One jq for the fields jq_get serves from cache. jq prints a document before it
# fails on what follows (`{...} oops`), so its exit status is the last field, and
# NUL is taken out of each string or one would shift every field after it. Each
# field is jq_get's own `EXPR // ""`, and a field jq cannot read is "", as there.
BG_F=()
while IFS= read -r -d '' bg_f; do BG_F[${#BG_F[@]}]=$bg_f; done < <(
  printf '%s' "$INPUT" | jq -j 'def f(p): try ((p // "") | if type == "string" then split("\u0000") | join("") else . end) catch "";
    f(.tool_name), "\u0000", f(.tool_input.command), "\u0000", f(.cwd), "\u0000", f(.session_id), "\u0000",
    f(.tool_input.url), "\u0000", f(.tool_input.ws.url), "\u0000", f(.tool_use_id), "\u0000"' 2>/dev/null
  printf 'rc=%s\0' "$?")
PRESET_OK=no
[[ ${#BG_F[@]} -eq 8 && "${BG_F[7]}" == rc=0 ]] && PRESET_OK=ok
# Whitespace alone is no document and no error; each guard allowed it.
[[ ${#BG_F[@]} -eq 1 && "${BG_F[0]}" == rc=0 ]] && { PRESET_OK=ok; BG_F=(); }
# shellcheck disable=SC2034  # lib.sh reads them in each guard's fork
{
  PRESET_TOOL=${BG_F[0]:-} PRESET_CMD=${BG_F[1]:-} PRESET_CWD=${BG_F[2]:-} PRESET_SID=${BG_F[3]:-}
  PRESET_URL=${BG_F[4]:-} PRESET_WS=${BG_F[5]:-} PRESET_ID=${BG_F[6]:-}
  HARNESS_PRESET=$$   # lib.sh honours it only where $$ is this, in these forks
}
unset BG_F bg_f
# A payload that does not parse is denied once, here, under this hook's name.
[[ "$PRESET_OK" == ok ]] || { BG_DONE=1; require_parsable_or_deny; BG_DONE=""; exit 1; }

# bash-guards.skip beside this hook (~/.claude/hooks/) names guards to leave out,
# one a line. It only takes names off the list above, so a missing or empty file
# runs all seven, and a symlink is not read. In the hooks folder, a write to it is
# one config-guard asks about as it does for the guards themselves.
BG_SKIP=" "
if [[ -f "$BG_DIR/bash-guards.skip" && ! -L "$BG_DIR/bash-guards.skip" ]]; then
  while IFS= read -r bg_l || [[ -n "$bg_l" ]]; do
    bg_l=${bg_l%%#*}; bg_l=${bg_l//[[:space:]]/}; bg_l=${bg_l%.sh}
    [[ -n "$bg_l" ]] && BG_SKIP="$BG_SKIP$bg_l "
  done < "$BG_DIR/bash-guards.skip"
fi
BG_RUN=()
for bg_g in "${BG_GUARDS[@]}"; do [[ "$BG_SKIP" == *" $bg_g "* ]] || BG_RUN[${#BG_RUN[@]}]=$bg_g; done
unset bg_l

# A guard's stdout, then time's \036 and seconds, then \037 and its status. The
# status line comes from here, after the guard: no line, or a status but 0, is a
# deny. The guard's stderr goes straight to this hook's.
bg_run() {
  exec 4>&2
  TIMEFORMAT=$'\036%R'
  # shellcheck disable=SC2034,SC1090  # lib.sh reads GUARD_NAME; the file is the guard's
  { time { ( exec 2>&4 4>&-; GUARD_NAME=$1; GUARD_SELF="$BG_DIR/$1.sh"; . "$GUARD_SELF" ); }; } 2>&1
  printf '\037%s' "$?"
}
# All at once, on fds 10 up (bash 3.2 has no {fd}), read back in list order.
bg_i=0
for bg_g in "${BG_RUN[@]}"; do eval "exec $((10 + bg_i))< <(bg_run \"\$bg_g\")"; bg_i=$((bg_i + 1)); done
BG_RAW=()
bg_i=0
for bg_g in "${BG_RUN[@]}"; do
  bg_r=""; IFS= read -r -d '' bg_r <&$((10 + bg_i))
  BG_RAW[bg_i]=$bg_r
  eval "exec $((10 + bg_i))<&-"
  bg_i=$((bg_i + 1))
done
# Reap the forks. bash does not wait for a process substitution, so each one
# lingered as a zombie and its CPU reached no one timing this hook (wait4).
wait

# deny > ask > allow. One guard answering is passed on byte for byte; several
# are joined in list order. Each guard wrote its own audit line.
BG_N=0 BG_WORST="" BG_ONE="" BG_ALL="" BG_TIMES=""
bg_i=0
for bg_g in "${BG_RUN[@]}"; do
  bg_r=${BG_RAW[bg_i]}; bg_i=$((bg_i + 1))
  bg_st=lost bg_t=- bg_body=""
  if [[ "$bg_r" == *$'\037'* ]]; then
    bg_st=${bg_r##*$'\037'}; bg_r=${bg_r%$'\037'*}
    case "$bg_st" in ''|*[!0-9]*) bg_st=lost ;; esac
    bg_body=$bg_r
    if [[ "$bg_r" == *$'\036'* ]]; then bg_t=${bg_r##*$'\036'}; bg_t=${bg_t%$'\n'}; bg_body=${bg_r%$'\036'*}; fi
  fi
  bg_d=allow
  case "$bg_body" in *'"permissionDecision":"deny"'*) bg_d=deny ;; *'"permissionDecision":"ask"'*) bg_d=ask ;; esac
  if [[ "$bg_st" != 0 ]]; then
    bg_d=deny
    bg_body=$(GUARD_NAME=$bg_g emit_deny "Blocked: $bg_g did not finish (status $bg_st), so this call was not checked by it. Retry; if it repeats, run bash ~/.claude/hooks/$bg_g.sh by hand on the payload.")$'\n'
  fi
  BG_TIMES="$BG_TIMES"$'\t'"$bg_g=$bg_t:$bg_st:$bg_d"
  [[ "$bg_d" == allow ]] && continue
  BG_N=$((BG_N + 1)) BG_ONE=$bg_body BG_ALL="$BG_ALL$bg_body"
  [[ "$bg_d" == deny || -z "$BG_WORST" ]] && BG_WORST=$bg_d
done

bg_static_deny() {   # a deny built with no jq, for an answer that went missing
  log_decision deny
  printf -v BG_OUT '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
}
BG_OUT=""
if (( BG_N == 1 )); then
  BG_OUT=$BG_ONE
elif (( BG_N > 1 )); then
  BG_OUT=$(printf '%s' "$BG_ALL" | jq -cs --arg w "$BG_WORST" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$w,
    permissionDecisionReason:([.[].hookSpecificOutput | select(.permissionDecision == $w) | .permissionDecisionReason] | join("\n"))}}' 2>/dev/null) \
    && [[ -n "$BG_OUT" ]] && BG_OUT="$BG_OUT"$'\n' \
    || bg_static_deny "Blocked: more than one Bash guard answered and their answers could not be combined, so this call is denied. Retry; if it repeats, run each guard by hand on the payload."
fi
# A deny or ask missing from the output (a dead guard's deny whose own jq died)
# would read as an allow. A deny in its place is as strong or stronger.
[[ -z "$BG_WORST" || "$BG_OUT" == *"\"permissionDecision\":\"$BG_WORST\""* || "$BG_OUT" == *'"permissionDecision":"deny"'* ]] \
  || bg_static_deny "Blocked: a Bash guard's answer was lost before it could be passed on, so this call is denied. Retry; if it repeats, run each guard by hand on the payload."

# One line a call, keyed by tool_use_id: the per-guard seconds, status and
# decision, written with a builtin (no exec). session-start.sh rotates it.
BG_LOG=${CLAUDE_GUARD_TIMING_LOG:-$HOME/.claude/logs/guard-timing.log}
BG_LOG=${BG_LOG/#\~/$HOME}
bg_id=${PRESET_ID:--} bg_tool=${PRESET_TOOL:--}
{ printf '%s\t%s%s\n' "${bg_id//[$'\t\n']/ }" "${bg_tool//[$'\t\n']/ }" "$BG_TIMES" >> "$BG_LOG"; } 2>/dev/null

printf '%s' "$BG_OUT"
BG_DONE=1
exit 0
