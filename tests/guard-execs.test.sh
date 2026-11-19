#!/usr/bin/env bash
# Processes git-guard and interpreter-guard start per payload, counted by PATH
# shims, not timed: a CI runner's 1 ms process start hides the cost.
# GUARD_EXECS_PRINT=1 prints the counts as budget lines.
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

# Budgets: a guard's process starts on each payload, today's count. Lower one
# when a change starts fewer; a change that starts more raises it in the same PR,
# and says why there.
#  payload                    git-guard  interpreter-guard
BUDGETS='
shape-cd-chain                  12   5
shape-pipes                     16  10
shape-python-heredoc             0  27
shape-notes-then-git            17  14
shape-commit-heredoc            19  15
shape-commit-pr-heredoc         19  15
mult-joined-pass                22  10
mult-inline-shellouts           48  14
mult-git-add-all                76   0
'
GUARDS="env-guard git-guard interpreter-guard kubectl-guard network-guard rm-guard config-guard"

# A shim for every program on lib.sh's PATH and this one, the first folder's
# winning as on PATH: each appends its name to the log and runs the real one.
LOG="$TMP/started"
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
cp -R hooks "$TMP/hk"
sed "s#^export PATH=\"#export PATH=\"$TMP/shim:#" hooks/lib.sh > "$TMP/hk/lib.sh"
cmp -s hooks/lib.sh "$TMP/hk/lib.sh" && { fail "test setup" "lib.sh's PATH line was not found"; results; }

started() {   # started GUARD|none ID: sets N, the processes one call starts, and WHAT, by name
  local g skip=""
  for g in $GUARDS; do [[ "$g" == "$1" ]] || skip="$skip$g"$'\n'; done
  printf '%s' "$skip" > "$TMP/hk/bash-guards.skip"
  : > "$LOG"; rm -f "$CLAUDE_AUDIT_LOG" "$CLAUDE_SHADOW_LOG"
  ( cd "$TMP/repo" && bash "$TMP/hk/bash-guards.sh" < "$TMP/p/$2.json" > "$TMP/out" 2>&1 )
  N=0; while IFS= read -r _; do N=$((N + 1)); done < "$LOG"
  WHAT=$(sort "$LOG" | uniq -c | awk '{ printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1 }')
}

echo "=== the shims count: ls -la starts the dispatcher's jq and nothing in either guard ==="
jq -nc --arg d "$TMP/repo" '{tool_name:"Bash",tool_input:{command:"ls -la"},cwd:$d,session_id:"t",tool_use_id:"toolu_T",permission_mode:"default"}' > "$TMP/p/ls.json"
started none ls; NONE=$N
started git-guard ls; GG=$N
[[ $NONE == 1 && $GG == 1 ]] && pass "ls -la: one start, the dispatcher's jq" || fail "ls -la" "none $NONE ($WHAT), git-guard $GG"

echo ""
echo "=== each guard starts no more processes than its budget on each payload ==="
PRINT=""
while read -r id bg bi; do
  [[ -n "$id" ]] || continue
  jq -c --arg id "$id" --arg d "$TMP/repo" 'select(.id == $id)
    | {hook_event_name:"PreToolUse", session_id:"t", tool_use_id:"toolu_T", tool_name, tool_input, cwd:$d, permission_mode:"default"}' \
    tests/bench-corpus.jsonl > "$TMP/p/$id.json"
  [[ -s "$TMP/p/$id.json" ]] || { fail "$id" "no such payload in tests/bench-corpus.jsonl"; continue; }
  started none "$id"; NONE=$N
  line=$(printf '%-30s' "$id")
  for g in git-guard interpreter-guard; do
    [[ $g == git-guard ]] && b=$bg || b=$bi
    started "$g" "$id"; c=$((N - NONE))
    line="$line $(printf '%3s' "$c")"
    printf '%s' "$WHAT" > "$TMP/what.$g.$id"
    if (( c < b )); then pass "$id, $g: $c of $b ($((b - c)) under: lower the budget)"
    elif (( c == b )); then pass "$id, $g: $c of $b"
    else fail "$id, $g: $c, budget $b" "$WHAT (the dispatcher's own: $NONE)"; fi
  done
  PRINT="$PRINT$line"$'\n'
done <<< "$BUDGETS"

echo ""
echo "=== each multiplier still multiplies ==="
# A shape that stopped doing what it is here for would pass any budget.
W=$(cat "$TMP/what.git-guard.mult-git-add-all" 2>/dev/null)
[[ "$W" == *"git x"* ]] && pass "git add -A: git-guard runs git status" || fail "git add -A runs no git" "$W"
W=$(cat "$TMP/what.git-guard.mult-inline-shellouts" 2>/dev/null)
[[ "$W" == *"bash x5"* ]] && pass "five git shell-outs: git-guard runs itself on each" || fail "inline shell-outs" "$W"
started none mult-joined-pass
[[ "$WHAT" == *"jq x2"* ]] && pass "a multi-line -m: the dispatcher makes the joined reading, a second jq" || fail "joined pass" "$N: $WHAT"

if [[ -n "${GUARD_EXECS_PRINT:-}" ]]; then
  echo ""; echo "#  payload                    git-guard  interpreter-guard"; printf '%s' "$PRINT"
fi

echo ""
results
