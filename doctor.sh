#!/usr/bin/env bash
# Runs every test in tests/ and reports totals.
# Exit code = number of failing suites.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

if ! command -v jq &>/dev/null; then
  echo "FATAL: jq is required. Install via: brew install jq" >&2
  exit 1
fi

# Guards write every deny and ask to the audit log. A suite that forgets to
# point it elsewhere would fill the real log with test decisions.
AUDIT_TMP=$(mktemp -d); trap 'rm -rf "$AUDIT_TMP"' EXIT
export CLAUDE_AUDIT_LOG="$AUDIT_TMP/audit.log"

TOTAL_SUITES=0
FAILED_SUITES=0
TOTAL_PASS=0
TOTAL_FAIL=0
UNCOUNTED=""

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
  # A suite whose tally does not match this format contributes 0 to both totals,
  # which reads as "it ran and had nothing to report" rather than "it was not
  # counted". Measured: two suites emitting a different tally line cost the
  # summary 44 passes while it still printed a confident total. Suite-level
  # pass/fail is unaffected -- that comes from the exit status -- but a total
  # nobody can reconcile is worse than no total, so name what went uncounted.
  if [[ -z "$p" ]]; then
    UNCOUNTED="$UNCOUNTED $f"
  fi
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${ff:-0}))
  if [[ "$STATUS" -ne 0 ]]; then
    FAILED_SUITES=$((FAILED_SUITES+1))
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY: $TOTAL_SUITES suites │ $TOTAL_PASS passed │ $TOTAL_FAIL failed │ $FAILED_SUITES suite(s) failed"
if [[ -n "$UNCOUNTED" ]]; then
  echo "NOT COUNTED in the totals above (tally line not in '--- Results: N passed, M failed ---' form):"
  for u in $UNCOUNTED; do echo "  - $u"; done
  echo "Their pass/fail still counts toward 'suite(s) failed' via exit status."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAILED_SUITES
