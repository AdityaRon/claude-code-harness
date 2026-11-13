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
suite b-fail  'echo "--- Results: 1 passed, 2 failed ---"; exit 2'
suite c-many  'echo "--- Results: 0 passed, 130 failed ---"; exit 130'
suite d-kill  'echo "half way"; kill -TERM $$'
suite e-hang  "sleep 30 & echo \$! > '$TMP/child'; wait"
suite f-cases 'echo "--- Results: 4 passed, 0 failed, 2 timed out ---"; exit 2'
suite g-slow  'sleep 1; echo "--- Results: 1 passed, 0 failed ---"'

echo "=== a kill and a timeout are named, not counted as failures ==="
OUT=$(CCH_SUITE_TIMEOUT=2 bash "$D/doctor.sh" 2>&1); RC=$?
SUM=$(printf '%s\n' "$OUT" | grep '^SUMMARY:')
[ "$SUM" = "SUMMARY: 7 suites │ 9 passed │ 132 failed │ 2 suite(s) failed │ 1 killed │ 2 timed out" ] \
  && pass "summary: 2 failed, 1 killed, 2 timed out" || fail "summary" "$SUM"
[ "$RC" = 5 ] && pass "exit 5: every suite that did not pass, whatever the reason" || fail "exit code" "$RC"
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
OUT=$(bash "$D/doctor.sh" --smoke 2>&1); RC=$?
[[ "$OUT" == *"SUMMARY: 2 suites │ 4 passed │ 0 failed │ 0 suite(s) failed"* && "$RC" = 0 ]] \
  && pass "two suites, green" || fail "--smoke" "rc=$RC $(printf '%s\n' "$OUT" | grep SUMMARY)"

echo ""
echo "=== doctor stopped by a signal says so, and stops the suite it was in ==="
rm -f "$D"/tests/[b-g]-*.test.sh "$TMP/child"
suite b-long "sleep 30 & echo \$! > '$TMP/child'; wait"
bash "$D/doctor.sh" > "$TMP/stopped.out" 2>&1 &
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

echo ""
echo "=== install.sh runs the smoke set; --full runs every suite ==="
grep -qF 'SET=--smoke; [[ "${1:-}" == "--full" ]] && SET=""' install.sh \
  && pass "install.sh calls doctor.sh --smoke and takes --full" || fail "install smoke" "$(grep -n 'doctor.sh' install.sh)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
