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
SECONDS=0   # the guards' deadline counts from here; bash takes SECONDS from the environment

# log_audit, in each guard that answers, runs dirname on its log path. This is
# POSIX dirname without an exec.
dirname() {
  local p=$1
  case "$p" in *[!/]*) ;; '') printf '.\n'; return 0 ;; *) printf '/\n'; return 0 ;; esac
  p=${p%"${p##*[!/]}"}
  case "$p" in */*) ;; *) printf '.\n'; return 0 ;; esac
  p=${p%/*}
  p=${p%"${p##*[!/]}"}
  printf '%s\n' "${p:-/}"
}
if [[ "$0" == */* ]]; then BG_DIR=${0%/*}; else BG_DIR=.; fi   # dirname "$0", with no fork
source "$BG_DIR/lib.sh" && declare -F read_input jq_get jq_set herestr two_lines emit_deny log_decision decide word_filter >/dev/null || exit 1
# A lib.sh without the seams would have each fork read an empty stdin and allow.
# Its read_input reads /dev/null over INPUT; this one, preset, leaves it.
HARNESS_PRESET=$$ INPUT=$'\001'
read_input < /dev/null
[[ "$INPUT" == $'\001' ]] || {
  BG_DONE=1; echo "Blocked: $BG_DIR/lib.sh is older than bash-guards.sh, so the Bash guards cannot run. Run bash install.sh from the harness clone." >&2; exit 2; }
unset HARNESS_PRESET INPUT

read_input
if [[ -z "$INPUT" ]]; then BG_DONE=1; exit 0; fi
command -v jq &>/dev/null || { BG_DONE=1; require_jq_or_deny; BG_DONE=""; exit 1; }

# One jq for the fields jq_get serves from cache. jq prints a document before it
# fails on what follows (`{...} oops`), so its exit status is the last field, and
# NUL is taken out of each string or one would shift every field after it. Each
# field is jq_get's own `EXPR // ""`, and a field jq cannot read is "", as there.
# Then the command as `tr -d` leaves it with " ' and \ out, for the guards'
# word filters (word_filter, lib/io.sh): made here, no guard starts tr or grep
# to find it names none of its words. Then the epoch second for the timing log:
# bash 3.2 has no clock that starts no process, and this jq runs anyway. Last,
# for config-guard's filter, that bare text with each \ and newline after it out,
# only for a command holding one: join_continued_lines gives up on some.
BG_F=()
while IFS= read -r -d '' bg_f; do BG_F[${#BG_F[@]}]=$bg_f; done < <(
  herestr "$INPUT" jq -j 'def f(p): try ((p // "") | if type == "string" then split("\u0000") | join("") else . end) catch "";
    f(.tool_name), "\u0000", f(.tool_input.command), "\u0000", f(.cwd), "\u0000", f(.session_id), "\u0000",
    f(.tool_input.url), "\u0000", f(.tool_input.ws.url), "\u0000", f(.tool_use_id), "\u0000", f(.permission_mode), "\u0000",
    (f(.tool_input.command) | if type == "string" then . else tojson end
      | split("\"") | join("") | split("\u0027") | join("") | split("\\") | join("")), "\u0000",
    (now | floor | tostring), "\u0000",
    (f(.tool_input.command) | if type == "string" and contains("\\\n") then split("\\\n") | join("")
      | split("\"") | join("") | split("\u0027") | join("") | split("\\") | join("") else "" end), "\u0000"' 2>/dev/null
  printf 'rc=%s\0' "$?")
PRESET_OK=no
[[ ${#BG_F[@]} -eq 12 && "${BG_F[11]}" == rc=0 ]] && PRESET_OK=ok
# Whitespace alone is no document and no error; each guard allowed it.
[[ ${#BG_F[@]} -eq 1 && "${BG_F[0]}" == rc=0 ]] && { PRESET_OK=ok; BG_F=(); }
# shellcheck disable=SC2034  # lib.sh reads them in each guard's fork
{
  PRESET_TOOL=${BG_F[0]:-} PRESET_CMD=${BG_F[1]:-} PRESET_CWD=${BG_F[2]:-} PRESET_SID=${BG_F[3]:-}
  PRESET_URL=${BG_F[4]:-} PRESET_WS=${BG_F[5]:-} PRESET_ID=${BG_F[6]:-} PRESET_MODE=${BG_F[7]:-}
  PRESET_BARE=${BG_F[8]:-} PRESET_NLBARE=${BG_F[10]:-}
  HARNESS_PRESET=$$   # lib.sh honours it only where $$ is this, in these forks
}
BG_AT=${BG_F[9]:-}; BG_AT=${BG_AT//[!0-9]/} BG_S0=$SECONDS
unset BG_F bg_f
# A payload that does not parse is denied once, here, under this hook's name.
[[ "$PRESET_OK" == ok ]] || { BG_DONE=1; require_parsable_or_deny; BG_DONE=""; exit 1; }

# The command with its lines joined as bash joins them, made once here for
# every guard's second run on it (joined_pass, lib/io.sh). The same jq gives that
# command with " ' and \ out too (PRESET_JBARE), for config-guard's filter: a name
# split by a quote and a line's end shows only there.
# shellcheck disable=SC2034  # lib.sh reads them in each guard's fork
PRESET_JOINED="" PRESET_JINPUT="" PRESET_JBARE=""
# shellcheck disable=SC2034
if [[ "$PRESET_CMD" == *$'\n'* && "$PRESET_CMD" == *[\"\'\\]* ]] && PRESET_JOINED=$(join_continued_lines "$PRESET_CMD"); then
  # The payload is jq's first line (tojson holds no newline), the bare text the rest. read
  # and an offset split them: ${bg_j#*$'\n'} took 2.5 s on a 64 KB command under bash 3.2.
  bg_j=$(herestr "$INPUT" jq -j --arg c "$PRESET_JOINED" '(.tool_input.command = $c | tojson), "\n",
    ($c | split("\"") | join("") | split("\u0027") | join("") | split("\\") | join(""))' 2>/dev/null) \
    && IFS= read -r PRESET_JINPUT <<< "$bg_j" && PRESET_JBARE=${bg_j:${#PRESET_JINPUT}+1} \
    || PRESET_JOINED="" PRESET_JINPUT="" PRESET_JBARE=""
  unset bg_j
fi
# The joined text already holds what PRESET_NLBARE would add.
# shellcheck disable=SC2034  # lib.sh reads it in each guard's fork
[[ -n "$PRESET_JBARE" ]] && PRESET_NLBARE=""
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
# deny. The guard's stderr goes straight to this hook's. The guard runs in a
# process group of its own (set -m; bash turns job control off again inside the
# subshell), so a signal here stops it and all it started. What bash itself says
# on this fork's stderr while it waits (a job notice) goes to /dev/null, so only
# time's report joins the guard's answer.
bg_run() {
  exec 4>&2
  TIMEFORMAT=$'\036%R'
  set -m; bg_c="" bg_x=""
  trap 'bg_x=1; [[ -n "${bg_c:-}" ]] && bg_kill' TERM INT HUP
  # shellcheck disable=SC2034,SC1090  # lib.sh reads GUARD_NAME; the file is the guard's
  { time { ( exec 2>&4 4>&-; GUARD_NAME=$1; GUARD_SELF="$BG_DIR/$1.sh"; . "$GUARD_SELF" ) & bg_c=$!
    [[ -z "${bg_x:-}" ]] || bg_kill; wait "$bg_c"; bg_s=$?; } 2>/dev/null; } 2>&1
  printf '\037%s' "$bg_s"
}
# The guard's group is killed, then killed again until nothing is left in it: on
# macOS a child the guard is forking as the group is killed escapes that kill,
# and is in the group once the guard, reaped here, is gone. At most 1000 more,
# since a zombie no init reaps keeps a kill to its group succeeding.
bg_kill() {
  local n=0
  kill -KILL -- "-$bg_c" 2>/dev/null || { kill -KILL "$bg_c" 2>/dev/null; return 0; }
  wait "$bg_c" 2>/dev/null
  while (( n++ < 1000 )) && kill -KILL -- "-$bg_c" 2>/dev/null; do :; done
  return 0
}

# A guard that has not answered CLAUDE_GUARD_DEADLINE seconds (45) after this
# hook started is a deny naming it, and its fork is stopped. settings.json's
# timeout (60) is the backstop; when it fires, Claude Code names no guard.
BG_DEADLINE=${CLAUDE_GUARD_DEADLINE:-45}
case "$BG_DEADLINE" in ''|*[!0-9]*) BG_DEADLINE=45 ;; esac
BG_DEADLINE=$((10#$BG_DEADLINE)); (( BG_DEADLINE > 0 )) || BG_DEADLINE=45
BG_END=$BG_DEADLINE BG_WOKE="" BG_AT_I=0
BG_PID=()
# SECONDS is wall time, so a call the Mac slept through would be late on waking.
# On the late path only, kern.waketime says whether it woke after the call was
# read, and the deadline starts again once from the wake. Linux has no check as
# cheap, so a call there that spans a suspend is late.
BG_SYSCTL=/usr/sbin/sysctl
bg_woke() {
  local w
  [[ -n "$BG_AT" ]] && w=$("$BG_SYSCTL" -n kern.waketime 2>/dev/null) || return 1
  w=${w#*sec = }; w=${w%%,*}   # { sec = 1795126825, usec = 376900 } Thu Nov 19 ...
  case "$w" in ''|*[!0-9]*) return 1 ;; esac
  (( w > BG_AT )) || return 1
  BG_END=$((BG_S0 + w - BG_AT + BG_DEADLINE))
}
# TERM, HUP or INT here stops each guard not yet read, then this hook dies of it.
# One that comes while the guards are being started waits for the last start: a
# guard started but not yet in BG_PID would not be stopped.
bg_stop() {
  local i
  [[ -n "$BG_STARTING" ]] && { BG_SIG=${BG_SIG:-$1}; return 0; }
  for (( i = BG_AT_I; i < ${#BG_PID[@]}; i++ )); do kill -TERM "${BG_PID[i]}" 2>/dev/null; done
  trap - "$1"; kill -s "$1" $$
}
BG_STARTING=1 BG_SIG=""
trap 'bg_stop TERM' TERM; trap 'bg_stop HUP' HUP; trap 'bg_stop INT' INT

# All at once, on fds 10 up (bash 3.2 has no {fd}), read back in list order.
bg_i=0
for bg_g in "${BG_RUN[@]}"; do eval "exec $((10 + bg_i))< <(bg_run \"\$bg_g\")"; BG_PID[bg_i]=$!; bg_i=$((bg_i + 1)); done
BG_STARTING=""
[[ -z "$BG_SIG" ]] || bg_stop "$BG_SIG"
BG_RAW=()
bg_i=0
for bg_g in "${BG_RUN[@]}"; do
  # One byte first, to the deadline: a read that times out keeps nothing it took
  # on bash 3.2, and this one took nothing. Then the rest. An end with no byte
  # before the deadline is no answer (lost); a guard still silent at it is late.
  # The byte is waited for a second at a time: bash runs a trap only once a read
  # returns, so a signal caught as one began would otherwise wait for the
  # deadline. A read that timed out gives over 128, or on bash 3.2 gives 1 as at
  # an end; a second gone tells it apart, and an end it takes for one is read again.
  while :; do
    bg_s0=$SECONDS
    bg_r=""; IFS= read -r -d '' -n 1 -t 1 bg_r <&$((10 + bg_i)); bg_rs=$?
    [[ -z "$bg_r" ]] && (( (bg_rs > 128 || SECONDS > bg_s0) && SECONDS < BG_END )) && continue
    [[ -n "$bg_r" ]] || (( SECONDS < BG_END )) && break
    [[ -z "$BG_WOKE" ]] && BG_WOKE=1 && bg_woke && (( SECONDS < BG_END )) && continue
    bg_r=$'\037late'; break
  done
  if [[ -n "$bg_r" && "$bg_r" != $'\037late' ]]; then
    bg_left=$((BG_END - SECONDS)); (( bg_left < 1 )) && bg_left=1
    bg_rest=""; IFS= read -r -d '' -t "$bg_left" bg_rest <&$((10 + bg_i)); bg_r=$bg_r$bg_rest
    [[ "$bg_r" != *$'\037'* ]] && (( SECONDS >= BG_END )) && bg_r=$'\037late'
  fi
  [[ "$bg_r" == $'\037late' ]] && kill -TERM "${BG_PID[bg_i]}" 2>/dev/null
  BG_RAW[bg_i]=$bg_r; BG_AT_I=$((bg_i + 1))
  eval "exec $((10 + bg_i))<&-"
  bg_i=$((bg_i + 1))
done
unset bg_rest bg_rs bg_s0

# deny > ask > allow. One guard answering is passed on byte for byte; several
# are joined in list order. Each guard wrote its own audit line. An answer is one
# JSON document on one line, as jq -c writes it: Claude Code reads anything else
# on stdout (stray text before or after) as no answer, and the call goes ahead.
bg_one_doc() {
  local s=${1%$'\n'}
  [[ "$s" == '{"hookSpecificOutput":{'*'}}' && "$s" != *$'\n'* ]]
}
BG_N=0 BG_WORST="" BG_ONE="" BG_ALL="" BG_TIMES="" BG_FROM=""
bg_i=0
for bg_g in "${BG_RUN[@]}"; do
  bg_r=${BG_RAW[bg_i]}; bg_i=$((bg_i + 1))
  bg_st=lost bg_t=- bg_body=""
  if [[ "$bg_r" == *$'\037'* ]]; then
    bg_st=${bg_r##*$'\037'}; bg_r=${bg_r%$'\037'*}
    case "$bg_st" in late) ;; ''|*[!0-9]*) bg_st=lost ;; esac
    bg_body=$bg_r
    if [[ "$bg_r" == *$'\036'* ]]; then bg_t=${bg_r##*$'\036'}; bg_t=${bg_t%$'\n'}; bg_body=${bg_r%$'\036'*}; fi
  fi
  bg_d=allow
  case "$bg_body" in *'"permissionDecision":"deny"'*) bg_d=deny ;; *'"permissionDecision":"ask"'*) bg_d=ask ;; esac
  if [[ "$bg_st" == late ]]; then
    bg_d=deny
    bg_body=$(GUARD_NAME=$bg_g emit_deny "Blocked: $bg_g had not answered $BG_DEADLINE s after bash-guards started, so it was stopped and this call was not checked by it. Retry once; if it repeats, split the command into smaller calls.")$'\n'
  elif [[ "$bg_st" != 0 ]]; then
    bg_d=deny
    bg_body=$(GUARD_NAME=$bg_g emit_deny "Blocked: $bg_g did not finish (status $bg_st), so this call was not checked by it. Retry; if it repeats, run bash ~/.claude/hooks/$bg_g.sh by hand on the payload.")$'\n'
  elif [[ "$bg_d" != allow ]] && ! bg_one_doc "$bg_body"; then
    bg_d=deny
    bg_body=$(GUARD_NAME=$bg_g emit_deny "Blocked: $bg_g's answer was not one JSON document, so this call was not checked by it. Retry; if it repeats, run bash ~/.claude/hooks/$bg_g.sh by hand on the payload.")$'\n'
  fi
  BG_TIMES="$BG_TIMES"$'\t'"$bg_g=$bg_t:$bg_st:$bg_d"
  [[ "$bg_d" == allow ]] && continue
  BG_N=$((BG_N + 1)) BG_ONE=$bg_body BG_ALL="$BG_ALL$bg_body" BG_FROM="$BG_FROM, $bg_g"
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
# Whatever path built it, what is printed is one JSON document or nothing.
[[ -z "$BG_OUT" ]] || bg_one_doc "$BG_OUT" \
  || bg_static_deny "Blocked: the answer built from ${BG_FROM#, } was not one JSON document, so this call is denied. Retry; if it repeats, run each of them by hand on the payload."

# One line a call, keyed by tool_use_id: the per-guard seconds, status and
# decision, then at= and the epoch second jq read the call at, written with a
# builtin (no exec). A payload of whitespace alone has no epoch and no at=.
# session-start.sh rotates the file.
BG_LOG=${CLAUDE_GUARD_TIMING_LOG:-$HOME/.claude/logs/guard-timing.log}
BG_LOG=${BG_LOG/#\~/$HOME}
bg_id=${PRESET_ID:--} bg_tool=${PRESET_TOOL:--}
[[ -n "$BG_AT" ]] && BG_TIMES="$BG_TIMES"$'\t'"at=$BG_AT"
{ printf '%s\t%s%s\n' "${bg_id//[$'\t\n']/ }" "${bg_tool//[$'\t\n']/ }" "$BG_TIMES" >> "$BG_LOG"; } 2>/dev/null

printf '%s' "$BG_OUT"
BG_DONE=1
exit 0
