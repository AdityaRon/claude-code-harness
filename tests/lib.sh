#!/usr/bin/env bash
# Sourced by the suites in tests/: the counts each one reports on its
# "--- Results: N passed, M failed ---" line, which doctor.sh reads.
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
# A case that ran out of time measures the machine's load, not the code: it is
# counted apart, and doctor.sh reads a suite with timeouts and no failures as TIMEOUT.
TIMED=0
timed_out() { echo "  TIMEOUT: $1  ${2:-}"; TIMED=$((TIMED+1)); }
results() {  # the Results line, with ", T timed out" when any did; exits with the misses
  echo "--- Results: $PASS passed, $FAIL failed$( [ "$TIMED" -gt 0 ] && echo ", $TIMED timed out") ---"
  exit $((FAIL + TIMED))
}
