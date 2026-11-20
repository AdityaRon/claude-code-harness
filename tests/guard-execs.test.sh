#!/usr/bin/env bash
# Processes one Bash call starts, per hook and payload, counted, not timed: a
# CI runner's 1 ms process start hides the cost. strace on Linux, PATH shims
# (execs only) elsewhere. GUARD_EXECS_PRINT=1 prints the counts as budget lines.
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
# shellcheck source-path=SCRIPTDIR source=lib.sh
source tests/lib.sh || exit 1

# A fresh HOME, logs and repo: log_audit stats a log that exists (twice on macOS),
# and a broad git add runs git status in the call's cwd.
export HOME="$TMP/home" CLAUDE_AUDIT_LOG="$TMP/audit.log" CLAUDE_GUARD_TIMING_LOG="$TMP/timing.log" CLAUDE_SHADOW_LOG="$TMP/shadow.log"
export CLAUDE_NET_ALLOWLIST="" CLAUDE_LOCAL_SETTINGS_DIR="$TMP/no-local"
unset CLAUDE_JOB_DIR
mkdir -p "$HOME/.claude" "$TMP/repo" "$TMP/p"
git -C "$TMP/repo" init -q && printf 'x\n' > "$TMP/repo/README.md"

# Today's counts: the dispatcher alone, then each guard past it. Lower one when
# a change starts fewer; one that starts more says why in its PR. A guard's
# forks hold the two bash-guards.sh makes to run it; forks are bash 5.2's.
#  payload                  disp  env  git  int  kub  net   rm  cfg
EXECS='
ls-la                         1    0    0    0    0    0    0    0
shape-cd-chain                1    8   12    5    0    0    0    0
shape-pipes                   1    0   14   10    0    0    0    0
shape-python-heredoc          2    0    0   27    0    0    0    0
shape-notes-then-git          2    0   17   14    0    0    0    0
shape-commit-heredoc          2    0   18   15    0    0    0    0
shape-commit-pr-heredoc       2   17   18   15    0    0    0    0
mult-joined-pass              3    0   22   10    0    0    0    0
mult-inline-shellouts         2    0   43   14    0    0    0    0
mult-git-add-all              1    0   74    0    0    0    0    0
'
FORKS='
ls-la                         2    2    2    2    2    2    2    2
shape-cd-chain                2   22   33   15    2    2    2    2
shape-pipes                   2    2   33   26    2    2    2    2
shape-python-heredoc          6    2    2   65    2    2    2    2
shape-notes-then-git          6    2   46   41    2    2    2    2
shape-commit-heredoc          6    2   47   42    2    2    2    2
shape-commit-pr-heredoc       6   46   47   42    2    2    2    2
mult-joined-pass              8    3   57   29    3    3    3    3
mult-inline-shellouts         6    2  112   35    2    2    2    2
mult-git-add-all              2    2  157    2    2    2    2    2
'
HOOKS="dispatcher env-guard git-guard interpreter-guard kubectl-guard network-guard rm-guard config-guard"
GUARDS=${HOOKS#dispatcher }

cp -R hooks "$TMP/hk"
LOG="$TMP/started"
# A Linux CI job without strace fails: its fork budgets would pass, counting none.
METHOD=shim
if [[ "$(uname -s)" == Linux ]] && command -v strace >/dev/null \
   && strace -ff -qq -e trace=process -o "$TMP/st-probe" true 2>/dev/null && cat "$TMP"/st-probe.* 2>/dev/null | grep -q '^execve('; then
  METHOD=strace
elif [[ "$(uname -s)" == Linux && -n "${CI:-}" ]]; then
  fail "strace" "this Linux CI job has no working strace, so no fork was counted (.github/install-apt-deps.sh strace)"
fi

# A shim for every program on lib.sh's PATH and this one, the first folder's
# winning as on PATH: each appends its name to the log and runs the real one.
if [[ $METHOD == shim ]]; then
  mkdir -p "$TMP/shim"
  LIB_PATH=$(sed -n 's/^export PATH="\(.*\)"$/\1/p' hooks/lib.sh)
  IFS=: read -ra DIRS <<< "${LIB_PATH%:\$PATH}:$PATH"
  for d in "${DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      n=${f##*/}
      [[ "$n" =~ ^[A-Za-z0-9._+-]+$ && -f "$f" && -x "$f" && ! -e "$TMP/shim/$n" ]] || continue
      printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$n" "$LOG" "$f" > "$TMP/shim/$n"
    done
  done
  chmod +x "$TMP/shim"/*
  sed "s#^export PATH=\"#export PATH=\"$TMP/shim:#" hooks/lib.sh > "$TMP/hk/lib.sh"
  cmp -s hooks/lib.sh "$TMP/hk/lib.sh" && { fail "test setup" "lib.sh's PATH line was not found"; results; }
fi

# Execs that succeeded, past the traced bash, and forks that made a process (a
# pid back, not a thread). The names go to $LOG, as the shims write them.
st_count() {   # PREFIX: sets E and F
  local f l first=1
  E=0 F=0; : > "$LOG"
  for f in "$1".*; do
    [[ -f "$f" ]] || continue
    while IFS= read -r l; do
      case "$l" in
        execve\(*'= 0'|execveat\(*'= 0')
          E=$((E + 1)); l=${l#*\"}; l=${l%%\"*}
          if [[ -n "$first" && "${l##*/}" == bash ]]; then first=""; else echo "${l##*/}" >> "$LOG"; fi ;;
        clone\(*|clone3\(*|fork\(*|vfork\(*)
          [[ "$l" =~ \ =\ [1-9][0-9]*$ && "$l" != *CLONE_THREAD* ]] && F=$((F + 1)) ;;
      esac
    done < "$f"
  done
  E=$((E - 1))
}

started() {   # started GUARD|none ID: sets E (execs), F (forks, under strace) and WHAT, by name; 1 if nothing was traced
  local g skip=""
  WHAT=""
  for g in $GUARDS; do [[ "$g" == "$1" ]] || skip="$skip$g"$'\n'; done
  printf '%s' "$skip" > "$TMP/hk/bash-guards.skip"
  : > "$LOG"; rm -f "$CLAUDE_AUDIT_LOG" "$CLAUDE_SHADOW_LOG" "$TMP"/st.*
  if [[ $METHOD == strace ]]; then
    ( cd "$TMP/repo" && strace -ff -qq -e trace=process -o "$TMP/st" bash "$TMP/hk/bash-guards.sh" < "$TMP/p/$2.json" > "$TMP/out" 2>&1 )
    st_count "$TMP/st"
    (( E >= 0 )) || { fail "$2, $1" "strace traced no bash, so nothing was counted"; return 1; }
  else
    ( cd "$TMP/repo" && bash "$TMP/hk/bash-guards.sh" < "$TMP/p/$2.json" > "$TMP/out" 2>&1 )
    E=0; while IFS= read -r _; do E=$((E + 1)); done < "$LOG"; F=""
  fi
  WHAT=$(sort "$LOG" | uniq -c | awk '{ printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1 }')
}

echo "=== the counter counts ==="
if [[ $METHOD == strace ]]; then
  # x=$( ) is a fork; /bin/true a fork and an exec.
  printf 'x=$(echo a)\n/bin/true\n:\n' > "$TMP/cal.sh"
  rm -f "$TMP"/st.*; strace -ff -qq -e trace=process -o "$TMP/st" bash "$TMP/cal.sh"; st_count "$TMP/st"
  [[ $E == 1 && $F == 2 ]] && pass "strace: a capture and a program are 2 forks and 1 exec" || fail "strace calibration" "execs $E, forks $F; want 1 and 2"
else
  echo "  SKIP: fork budgets: no working strace here (Linux only), so PATH shims count execs alone"
fi
jq -nc --arg d "$TMP/repo" '{tool_name:"Bash",tool_input:{command:"ls -la"},cwd:$d,session_id:"t",tool_use_id:"toolu_T",permission_mode:"default"}' > "$TMP/p/ls-la.json"
started none ls-la
[[ $E == 1 && "$WHAT" == "jq x1" ]] && pass "ls -la: the dispatcher starts one program, its jq" || fail "ls -la" "$E: $WHAT"

echo ""
echo "=== the dispatcher and each guard start no more than their budgets on each payload ==="
PE="" PF=""
while read -r id rest; do
  [[ -n "$id" ]] || continue
  BE=() BF=()
  read -ra BE <<< "$rest"
  frow=$(printf '%s\n' "$FORKS" | awk -v id="$id" '$1 == id { $1 = ""; print }')
  [[ -n "$frow" ]] && read -ra BF <<< "$frow"
  [[ ${#BE[@]} == 8 && ${#BF[@]} == 8 ]] || { fail "$id" "a budget row holds 8 numbers: execs ${#BE[@]}, forks ${#BF[@]}"; continue; }
  if [[ "$id" != ls-la ]]; then
    jq -c --arg id "$id" --arg d "$TMP/repo" 'select(.id == $id)
      | {hook_event_name:"PreToolUse", session_id:"t", tool_use_id:"toolu_T", tool_name, tool_input, cwd:$d, permission_mode:"default"}' \
      tests/bench-corpus.jsonl > "$TMP/p/$id.json"
    [[ -s "$TMP/p/$id.json" ]] || { fail "$id" "no such payload in tests/bench-corpus.jsonl"; continue; }
  fi
  started none "$id" || continue
  NE=$E NF=$F NWHAT=$WHAT
  le=$(printf '%-28s' "$id") lf=$le
  k=-1
  for h in $HOOKS; do
    k=$((k + 1))
    if [[ $h == dispatcher ]]; then e=$NE f=$NF what=$NWHAT
    else started "$h" "$id" || continue
      e=$((E - NE)) what=$WHAT; [[ -n "$F" ]] && f=$((F - NF)) || f=""
    fi
    printf '%s' "$what" > "$TMP/what.$h.$id"
    le="$le $(printf '%4s' "$e")" lf="$lf $(printf '%4s' "${f:--}")"
    b=${BE[k]}
    if (( e > b )); then fail "$id, $h: $e execs, budget $b" "$what (the dispatcher's own: $NWHAT)"
    elif (( e < b )); then pass "$id, $h: $e of $b execs ($((b - e)) under: lower the budget)"
    else pass "$id, $h: $e of $b execs"; fi
    if [[ -n "$f" ]]; then
      b=${BF[k]}
      if (( f > b )); then fail "$id, $h: $f forks, budget $b" "execs: $what"
      elif (( f < b )); then pass "$id, $h: $f of $b forks ($((b - f)) under: lower the budget)"
      else pass "$id, $h: $f of $b forks"; fi
    fi
  done
  PE="$PE$le"$'\n' PF="$PF$lf"$'\n'
done <<< "$EXECS"

echo ""
echo "=== each multiplier still multiplies ==="
# A shape that stopped doing what it is here for would pass any budget.
W=$(cat "$TMP/what.git-guard.mult-git-add-all" 2>/dev/null)
[[ "$W" == *"git x"* ]] && pass "git add -A: git-guard runs git status" || fail "git add -A runs no git" "$W"
W=$(cat "$TMP/what.git-guard.mult-inline-shellouts" 2>/dev/null)
[[ "$W" == *"bash x5"* ]] && pass "five git shell-outs: git-guard runs itself on each" || fail "inline shell-outs" "$W"
W=$(cat "$TMP/what.dispatcher.mult-joined-pass" 2>/dev/null)
[[ "$W" == *"jq x2"* ]] && pass "a multi-line -m: the dispatcher makes the joined reading, a second jq" || fail "joined pass" "$W"

if [[ -n "${GUARD_EXECS_PRINT:-}" ]]; then
  echo ""; echo "# execs ($METHOD)"; printf '%s' "$PE"
  [[ $METHOD == strace ]] && { echo "# forks (strace, bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})"; printf '%s' "$PF"; }
fi

echo ""
results
