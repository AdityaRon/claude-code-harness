#!/usr/bin/env bash
# Tests for doctor.sh's own reporting, on fixture suites in a copy of it: a kill
# or a timeout is not a failure, a suite gets a time limit, and the summary
# lists wall times slowest first.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
REPO=$PWD

# doctor.sh from a copy whose tests/ holds only the fixtures below.
D="$TMP/d"; mkdir -p "$D/tests"
cp doctor.sh "$D/"; ln -s "$REPO/hooks" "$D/hooks"; ln -s "$REPO/tools" "$D/tools"
suite() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$D/tests/$1.test.sh"; }
suite a-pass  'echo "--- Results: 3 passed, 0 failed ---"'
suite a-stdin 'read -r x; echo "--- Results: 1 passed, 0 failed ---"'
suite b-fail  'echo "--- Results: 1 passed, 2 failed ---"; exit 2'
suite c-many  'echo "--- Results: 0 passed, 130 failed ---"; exit 130'
suite d-kill  'echo "half way"; kill -TERM $$'
suite e-hang  "sleep 30 & echo \$! > '$TMP/child'; wait"
suite f-cases 'echo "--- Results: 4 passed, 0 failed, 2 timed out ---"; exit 2'
suite g-slow  'sleep 1; echo "--- Results: 1 passed, 0 failed ---"'
suite h-142   'exit 142'
suite i-255   'exit 255'

echo "=== a kill and a timeout are named, not counted as failures ==="
# doctor's stdin a pipe open past the limit: a suite that reads it must get EOF, not wait.
OUT=$(sleep 3 | CCH_SUITE_TIMEOUT=2 bash "$D/doctor.sh" 2>&1); RC=$?
SUM=$(printf '%s\n' "$OUT" | grep '^SUMMARY:')
[ "$SUM" = "SUMMARY: 10 suites │ 10 passed │ 132 failed │ 3 suite(s) failed │ 2 killed │ 2 timed out" ] \
  && pass "summary: 3 failed, 2 killed, 2 timed out" || fail "summary" "$SUM"
[ "$RC" = 7 ] && pass "exit 7: every suite that did not pass, whatever the reason" || fail "exit code" "$RC"
[[ "$OUT" != *"TIMEOUT: tests/h-142"* ]] \
  && pass "a suite that exits 142 before the limit did not time out" || fail "142" "$OUT"
[[ "$OUT" != *"KILLED: tests/i-255"* && "$OUT" != *SIG127* ]] \
  && pass "exit 255 names no signal: a failure, not a kill" || fail "255" "$OUT"
[[ "$OUT" != *"TIMEOUT: tests/a-stdin"* ]] \
  && pass "a suite that reads stdin gets EOF" || fail "stdin" "$OUT"
[[ "$OUT" != *"Alarm clock"* ]] \
  && pass "no job-status line from the shell when a suite is stopped" || fail "job line" "$(printf '%s\n' "$OUT" | grep -n 'Alarm')"
[[ "$OUT" == *"KILLED: tests/d-kill.test.sh by SIGTERM, no Results line: not a test result"* ]] \
  && pass "a suite killed by a signal reads KILLED" || fail "killed" "$OUT"
[[ "$OUT" != *"KILLED: tests/c-many"* ]] \
  && pass "a suite with 130 failures that exits 130 is a failure, not a kill: it printed its Results" || fail "exit 130" "$OUT"
[[ "$OUT" == *"TIMEOUT: tests/e-hang.test.sh ran past doctor's 2 s limit"* ]] \
  && pass "a hung suite is stopped at the limit and reads TIMEOUT" || fail "suite timeout" "$OUT"
CHILD=$(cat "$TMP/child" 2>/dev/null)
[[ -n "$CHILD" ]] && ! kill -0 "$CHILD" 2>/dev/null \
  && pass "the hung suite's own child is stopped with it" || { fail "child left running" "pid $CHILD"; kill "$CHILD" 2>/dev/null; }
[[ "$OUT" == *"TIMEOUT: tests/f-cases.test.sh, 2 case(s) past their limit, none failed"* ]] \
  && pass "a suite whose only misses are timed-out cases reads TIMEOUT" || fail "case timeout" "$OUT"
SLOW=$(printf '%s\n' "$OUT" | sed -n 's/^Slowest suites (wall seconds): //p')
[[ "$SLOW" == "e-hang "[23]", g-slow "[12]* ]] \
  && pass "wall times slowest first ($SLOW)" || fail "slowest first" "$SLOW"

echo ""
echo "=== --smoke runs only the listed suites ==="
printf 'tests/a-pass.test.sh\ntests/g-slow.test.sh\n' > "$D/tests/smoke.list"
OUT=$(CCH_SUITE_TIMEOUT=2 bash "$D/doctor.sh" --smoke 2>&1); RC=$?
[[ "$OUT" == *"SUMMARY: 2 suites │ 4 passed │ 0 failed │ 0 suite(s) failed"* && "$RC" = 0 ]] \
  && pass "two suites, green" || fail "--smoke" "rc=$RC $(printf '%s\n' "$OUT" | grep SUMMARY)"
printf 'tests/a-pass.test.sh\r\ntests/g-slow.test.sh\r\n' > "$D/tests/smoke.list"
OUT=$(CCH_SUITE_TIMEOUT=2 bash "$D/doctor.sh" --smoke 2>&1); RC=$?
[[ "$OUT" == *"SUMMARY: 2 suites │ 4 passed │ 0 failed │ 0 suite(s) failed"* && "$RC" = 0 ]] \
  && pass "a list with CRLF line ends runs the same two" || fail "CRLF" "rc=$RC $(printf '%s\n' "$OUT" | tail -3)"
printf '# none yet\n' > "$D/tests/smoke.list"
OUT=$(bash "$D/doctor.sh" --smoke 2>&1); RC=$?
[[ "$RC" = 2 && "$OUT" == *"names no tests/*.test.sh suite"* && "$OUT" != *SUMMARY* ]] \
  && pass "a list naming no suite exits 2 and runs nothing" || fail "empty list" "rc=$RC $OUT"
rm "$D/tests/smoke.list"
OUT=$(bash "$D/doctor.sh" --smoke 2>&1); RC=$?
[[ "$RC" = 2 && "$OUT" == *"names no tests/*.test.sh suite"* ]] \
  && pass "a missing list exits 2" || fail "missing list" "rc=$RC $OUT"

echo ""
echo "=== doctor stopped by a signal says so, and stops the suite it was in ==="
rm -f "$D"/tests/[b-i]-*.test.sh "$D/tests/a-stdin.test.sh" "$TMP/child"
suite b-long "sleep 30 & echo \$! > '$TMP/child'; wait"
# A limit no other run uses, so its watchdog's sleep can be found by its arguments.
U=$((4000 + $$ % 1000))
CCH_SUITE_TIMEOUT=$U bash "$D/doctor.sh" > "$TMP/stopped.out" 2>&1 &
DPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/child" ] && break; sleep 0.5; done
kill -TERM "$DPID"; wait "$DPID"; RC=$?
OUT=$(cat "$TMP/stopped.out")
[[ "$OUT" == *"SUMMARY: KILLED by SIGTERM while running suite 2 of 2 (tests/b-long.test.sh); nothing after it ran (3 passed, 0 failed before it)"* ]] \
  && pass "the summary names the signal and the suite it stopped in" || fail "stopped summary" "$(tail -3 "$TMP/stopped.out")"
[ "$RC" = 143 ] && pass "exit 143" || fail "stopped exit" "$RC"
sleep 0.5
CHILD=$(cat "$TMP/child" 2>/dev/null)
[[ -n "$CHILD" ]] && ! kill -0 "$CHILD" 2>/dev/null \
  && pass "the running suite's group is stopped too" || { fail "suite left running" "pid $CHILD"; kill "$CHILD" 2>/dev/null; }
WD=$(pgrep -fx "sleep $U")
[[ -z "$WD" ]] && pass "and its watchdog" || { fail "watchdog left running" "pids $WD"; kill $WD 2>/dev/null; }

echo ""
echo "=== doctor killed by SIGKILL: its watchdog still stops the suite at the limit ==="
rm -f "$TMP/child"
CCH_SUITE_TIMEOUT=2 bash "$D/doctor.sh" > /dev/null 2>&1 &
DPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/child" ] && break; sleep 0.5; done
kill -KILL "$DPID"; wait "$DPID" 2>/dev/null
CHILD=$(cat "$TMP/child" 2>/dev/null)
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$CHILD" 2>/dev/null || break; sleep 0.5; done
[[ -n "$CHILD" ]] && ! kill -0 "$CHILD" 2>/dev/null \
  && pass "the suite is gone within the 2 s limit plus 2 s" || { fail "suite outlived the watchdog" "pid $CHILD"; kill "$CHILD" 2>/dev/null; }

echo ""
echo "=== install.sh runs the smoke set; --full runs every suite ==="
# The real installer into a throwaway HOME, from a copy of the repo whose
# doctor.sh is a stub that records its arguments and answers as told.
R="$TMP/r"; mkdir -p "$R"
for e in "$REPO"/*; do ln -s "$e" "$R/${e##*/}"; done
rm "$R/doctor.sh"
printf '#!/usr/bin/env bash\necho "[$*]" > "%s"\nprintf "%%s\\n" "$STUB_OUT"\nexit "$STUB_RC"\n' "$TMP/doctor-args" > "$R/doctor.sh"
chmod +x "$R/doctor.sh"
inst() {  # stub-exit stub-output [install args]
  ( export STUB_RC="$1" STUB_OUT="$2" HOME="$TMP/ih" TMPDIR="$TMP"; shift 2
    unset XDG_CONFIG_HOME XDG_DATA_HOME CCH_SKIP_SELFTEST; mkdir -p "$HOME"
    cd "$R" && bash install.sh "$@" 2>&1 )
}
OUT=$(inst 0 "SUMMARY: 18 suites │ 9 passed │ 0 failed │ 0 suite(s) failed")
[ "$(cat "$TMP/doctor-args")" = "[--smoke]" ] && [[ "$OUT" == *"✓ SUMMARY: 18 suites"*"the smoke set; every suite:"* ]] \
  && pass "install runs doctor.sh --smoke and says it was the smoke set" || fail "install smoke" "$(cat "$TMP/doctor-args") $(printf '%s\n' "$OUT" | tail -5)"
OUT=$(inst 143 "SUMMARY: KILLED by SIGTERM while running suite 3 of 52 (tests/x.test.sh); nothing after it ran" --full)
[ "$(cat "$TMP/doctor-args")" = "[]" ] && [[ "$OUT" == *"doctor.sh was stopped before it finished, so this is not a test result"* ]] \
  && pass "install --full runs every suite, and a KILLED summary reads as stopped" || fail "install full" "$(cat "$TMP/doctor-args") $(printf '%s\n' "$OUT" | tail -5)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
