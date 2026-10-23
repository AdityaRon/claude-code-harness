#!/usr/bin/env bash
# Runs every test in tests/ and reports totals.
# Exit code = number of failing suites.
#   bash doctor.sh --skill comms-hub   that skill's prerequisites instead
#   bash doctor.sh --hosts             running claude processes whose binary is gone
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

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
# Advisory: the updater installs on a green SUMMARY, and a stale host on the
# machine is no reason to hold a harness release back.
STALE=$(stale_hosts)
[[ -z "$STALE" ]] || echo "HOSTS: $(printf '%s\n' "$STALE" | wc -l | tr -d ' ') running claude process(es) have lost their binary to an upgrade (not counted above): bash doctor.sh --hosts"

exit $FAILED_SUITES
