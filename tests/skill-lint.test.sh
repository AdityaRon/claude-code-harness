#!/usr/bin/env bash
# skill_lint (skills/skill-forge/bin/skill_lint.py) over every skill this repo
# ships. A finding is fixed, or waived in that skill's lint-waivers.toml with
# its reason; the lint fails a waiver with no reason, or one whose check now
# passes, so a waiver cannot outlive its finding. One result per skill.
set -u
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1"; printf '%s\n' "$2" | sed 's/^/        /'; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! PY=$(bash "$REPO/skills/skill-forge/bin/python.sh" 2>&1); then
  echo "  FAIL: $PY"
  echo "--- Results: 0 passed, 1 failed ---"
  exit 1
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

N=0
for s in "$REPO"/skills/*/; do
  [[ -f "$s/SKILL.md" ]] || continue
  N=$((N+1))
  name=$(basename "$s")
  # A config of the machine's own (its line_budget) must not change the verdict.
  if OUT=$(PYTHONDONTWRITEBYTECODE=1 SKILL_FORGE_CONFIG="$TMP/none.toml" "$PY" -B "$REPO/skills/skill-forge/bin/skill_lint.py" "$s" 2>&1); then
    pass "$name: $(printf '%s\n' "$OUT" | grep -cE '^  C[0-9]+ +WAIVED') waived, the rest pass or do not apply"
  else
    fail "$name" "$(printf '%s\n' "$OUT" | grep -E '^  C[0-9]+ +FAIL')"
  fi
done
[[ "$N" -ge 5 ]] && pass "linted $N skills" || fail "linted $N skills" "expected every skill under skills/"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit "$FAIL"
