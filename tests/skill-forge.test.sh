#!/usr/bin/env bash
# skill-forge's Python tests in doctor's tally format; python.sh picks a 3.10+
# with a TOML reader. The mutation run (run.py --mutate) and the Docker run
# (live_acceptance.py) are by hand: one is slow, the other needs a daemon.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! PY=$(bash "$REPO/skills/skill-forge/bin/python.sh" 2>&1); then
  echo "  FAIL: $PY"
  echo "--- Results: 0 passed, 1 failed ---"
  exit 1
fi
echo "  python: $PY"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
# The tests set their own config and state; these keep anything they miss off
# the machine's real ones.
OUT=$(TMPDIR="$TMP" PYTHONDONTWRITEBYTECODE=1 SKILL_FORGE_CONFIG="$TMP/none.toml" SKILL_FORGE_STATE="$TMP/state" \
  XDG_DATA_HOME="$TMP/data" "$PY" -B "$REPO/skills/skill-forge/tests/run.py" 2>&1)
RC=$?
printf '%s\n' "$OUT"
exit "$RC"
