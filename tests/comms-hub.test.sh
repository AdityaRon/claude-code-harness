#!/usr/bin/env bash
# The comms-hub skill's Python tests (skills/comms-hub/tests), in doctor's tally
# format. They need Python 3.10+ with a TOML reader, which macOS's python3 3.9
# is not, so skills/comms-hub/bin/python.sh picks the interpreter. The mutation
# run is separate (187 mutations, 241 s on an Apple M2, 2026-10-27): skills/comms-hub/tests/run.py --mutate
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! PY=$(bash "$REPO/skills/comms-hub/bin/python.sh" 2>&1); then
  echo "  FAIL: $PY"
  echo "--- Results: 0 passed, 1 failed ---"
  exit 1
fi
echo "  python: $PY"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
OUT=$(TMPDIR="$TMP" PYTHONDONTWRITEBYTECODE=1 "$PY" -B "$REPO/skills/comms-hub/tests/run.py" 2>&1)
RC=$?
printf '%s\n' "$OUT"
exit "$RC"
