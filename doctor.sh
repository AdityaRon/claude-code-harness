#!/usr/bin/env bash
# Runs every test in tests/ and reports totals.
# Exit code = number of suites that failed, were killed or timed out.
#   bash doctor.sh --skill comms-hub   that skill's prerequisites instead
#   bash doctor.sh --hosts             running claude processes whose binary is gone
#   bash doctor.sh --latency [ARGS]    hook wall times from the transcripts (tools/hook-latency.py)
#   bash doctor.sh --census [ARGS]     claude processes, their memory, idle background jobs
#   bash doctor.sh --smoke             only the suites tests/smoke.list names
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

case "${1:-}" in
  --latency) shift; exec python3 tools/hook-latency.py "$@" ;;
  --census) shift; exec python3 tools/session-census.py "$@" ;;
esac

if [[ "${1:-}" == "--skill" ]]; then
  [[ -f "skills/${2:-}/bin/prereqs.sh" ]] || { echo "no prerequisite check for skill '${2:-}'" >&2; exit 2; }
  exec bash "skills/$2/bin/prereqs.sh"
fi

# A background session host whose binary an upgrade deleted loses ~/Desktop,
# ~/Documents and ~/Downloads (docs/known-limitations.md). Exit 1 when one
# exists; the owner's one command after "Operation not permitted".
stale_hosts() { bash -c 'source hooks/lib.sh; stale_claude_hosts' 2>/dev/null; }
if [[ "${1:-}" == "--hosts" ]]; then
  STALE=$(stale_hosts)
  [[ -n "$STALE" ]] || { echo "every running claude process still has its binary"; exit 0; }
  echo "claude processes whose binary an upgrade deleted; a background host among them has lost ~/Desktop, ~/Documents and ~/Downloads, or will when tccd next restarts. Save work, then restart each:"
  printf '%s\n' "$STALE" | awk -F'\t' '{ print "  pid " $1 "  " $2 }'
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "FATAL: jq is required. Install via: brew install jq (macOS), apt-get install jq or dnf install jq (Linux)" >&2
  exit 1
fi

# Guards write every deny and ask to the audit log. A suite that forgets to
# point it elsewhere would fill the real log with test decisions.
AUDIT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$AUDIT_TMP"' EXIT
export CLAUDE_AUDIT_LOG="$AUDIT_TMP/audit.log"

TOTAL_SUITES=0
FAILED_SUITES=0
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TIMED=0
UNCOUNTED=""
NOTES="" NK=0 NT=0 TIMES=""

# --smoke runs the suites tests/smoke.list names, one or more per wired hook
# (repo-layout.test.sh holds it to that); install.sh runs it, the rest run all.
SUITES=(tests/*.test.sh)
if [[ "${1:-}" == "--smoke" ]]; then
  SUITES=()
  while IFS= read -r s || [[ -n "$s" ]]; do
    [[ "$s" == tests/*.test.sh ]] && SUITES+=("$s")
  done < tests/smoke.list
fi

# A suite gets SUITE_TIMEOUT seconds in its own process group, then SIGALRM:
# status 142, read as TIMEOUT. A suite killed by any other signal, with no
# Results line, is KILLED: a restart or an OOM, not a failing test.
SUITE_TIMEOUT=${CCH_SUITE_TIMEOUT:-1800}
set -m
run_bounded() {  # suite out-file: returns the suite's status
  local pid wd st
  bash "$1" > "$2" 2>&1 &
  pid=$!; CUR_PID=$pid
  ( trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$SUITE_TIMEOUT" & s=$!; wait "$s" && kill -ALRM -- -"$pid" 2>/dev/null ) &
  wd=$!
  wait "$pid"; st=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return "$st"
}

# Stopped itself (a session restart sends TERM to the group): the summary says
# so, and the suite that was running reads KILLED, not failed.
CUR_PID="" CUR_SUITE=""
stopped() {
  [[ -n "$CUR_PID" ]] && kill -TERM -- -"$CUR_PID" 2>/dev/null
  echo ""
  echo "SUMMARY: KILLED by SIG$1 while running suite $TOTAL_SUITES of ${#SUITES[@]} ($CUR_SUITE); nothing after it ran ($TOTAL_PASS passed, $TOTAL_FAIL failed before it)"
  exit $((128 + $2))
}
trap 'stopped TERM 15' TERM
trap 'stopped INT 2' INT
trap 'stopped HUP 1' HUP

for f in "${SUITES[@]}"; do
  [[ -f "$f" ]] || continue
  TOTAL_SUITES=$((TOTAL_SUITES+1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "▶ $f"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  T0=$SECONDS CUR_SUITE=$f
  run_bounded "$f" "$AUDIT_TMP/suite.out"
  STATUS=$?
  TIMES="$TIMES$((SECONDS - T0)) $f"$'\n'
  OUTPUT=$(cat "$AUDIT_TMP/suite.out")
  printf '%s\n' "$OUTPUT"
  # Parse the final "Results: N passed, M failed[, T timed out]" line
  line=$(printf '%s\n' "$OUTPUT" | grep -E '^-+ Results:' | tail -1)
  p=$(printf '%s\n' "$line" | sed -nE 's/.* Results: ([0-9]+) passed.*/\1/p')
  ff=$(printf '%s\n' "$line" | sed -nE 's/.*passed, ([0-9]+) failed.*/\1/p')
  tt=$(printf '%s\n' "$line" | sed -nE 's/.*failed, ([0-9]+) timed out.*/\1/p')
  # A suite whose tally does not match this format contributes 0 to both totals,
  # which reads as "it ran and had nothing to report". Name what went uncounted.
  if [[ -z "$p" ]]; then
    UNCOUNTED="$UNCOUNTED $f"
  fi
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${ff:-0}))
  TOTAL_TIMED=$((TOTAL_TIMED + ${tt:-0}))
  if [[ "$STATUS" -eq 0 ]]; then
    :
  elif [[ -z "$line" && "$STATUS" -eq 142 ]]; then
    NT=$((NT+1)); NOTES="${NOTES}TIMEOUT: $f ran past doctor's ${SUITE_TIMEOUT} s limit"$'\n'
  elif [[ -z "$line" && "$STATUS" -ge 128 ]]; then
    NK=$((NK+1)); NOTES="${NOTES}KILLED: $f by SIG$(kill -l $((STATUS - 128)) 2>/dev/null || echo $((STATUS - 128))), no Results line: not a test result"$'\n'
  elif [[ "${ff:-0}" -eq 0 && "${tt:-0}" -gt 0 ]]; then
    NT=$((NT+1)); NOTES="${NOTES}TIMEOUT: $f, ${tt} case(s) past their limit, none failed"$'\n'
  else
    FAILED_SUITES=$((FAILED_SUITES+1))
  fi
done
trap - TERM INT HUP

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY: $TOTAL_SUITES suites │ $TOTAL_PASS passed │ $TOTAL_FAIL failed │ $FAILED_SUITES suite(s) failed$( [[ $NK -gt 0 ]] && echo " │ $NK killed")$( [[ $NT -gt 0 ]] && echo " │ $NT timed out")"
printf '%s' "$NOTES"
if [[ -n "$UNCOUNTED" ]]; then
  echo "NOT COUNTED in the totals above (tally line not in '--- Results: N passed, M failed ---' form):"
  for u in $UNCOUNTED; do echo "  - $u"; done
  echo "Their pass/fail still counts toward 'suite(s) failed' via exit status."
fi
echo "Slowest suites (wall seconds): $(printf '%s' "$TIMES" | sort -rn | head -8 | awk '{ sub("tests/", "", $2); sub(".test.sh", "", $2); printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# Advisory: the updater installs on a green SUMMARY, and a stale host on the
# machine is no reason to hold a harness release back.
STALE=$(stale_hosts)
[[ -z "$STALE" ]] || echo "HOSTS: $(printf '%s\n' "$STALE" | wc -l | tr -d ' ') running claude process(es) have lost their binary to an upgrade (not counted above): bash doctor.sh --hosts"

exit $((FAILED_SUITES + NK + NT))
