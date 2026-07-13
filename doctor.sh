#!/usr/bin/env bash
# Runs every test in tests/ and reports totals.
# Exit code = number of failing suites.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

if ! command -v jq &>/dev/null; then
  echo "FATAL: jq is required. Install via: brew install jq" >&2
  exit 1
fi

TOTAL_SUITES=0
FAILED_SUITES=0
TOTAL_PASS=0
TOTAL_FAIL=0

for f in tests/*.test.sh; do
  [[ -f "$f" ]] || continue
  TOTAL_SUITES=$((TOTAL_SUITES+1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "▶ $f"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  OUTPUT=$(bash "$f" 2>&1)
  STATUS=$?
  printf '%s\n' "$OUTPUT"
  # Parse the final "Results: N passed, M failed" line
  line=$(printf '%s\n' "$OUTPUT" | grep -E '^-+ Results:' | tail -1)
  p=$(printf '%s\n' "$line" | sed -nE 's/.* Results: ([0-9]+) passed.*/\1/p')
  ff=$(printf '%s\n' "$line" | sed -nE 's/.*passed, ([0-9]+) failed.*/\1/p')
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${ff:-0}))
  if [[ "$STATUS" -ne 0 ]]; then
    FAILED_SUITES=$((FAILED_SUITES+1))
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY: $TOTAL_SUITES suites │ $TOTAL_PASS passed │ $TOTAL_FAIL failed │ $FAILED_SUITES suite(s) failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAILED_SUITES
