#!/usr/bin/env bash
# Tests for upstream-check.sh — the scheduled guard that catches Claude Code
# changing under the harness.
#
# A drift detector that only ever passes is worthless, so these tests simulate
# upstream actually moving: an event the harness depends on disappearing, the
# shipped permission mode becoming invalid, a new event appearing, and doctor's
# output format changing. No Claude Code install needed — CLAUDE_DOCTOR_CMD
# substitutes a stub that behaves like `claude doctor`.
set -u
CHECK="upstream-check.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

# The real list as of 2.1.228.
ALL_EVENTS="PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, UserPromptSubmit, UserPromptExpansion, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, PermissionRequest, PermissionDenied, Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove, InstructionsLoaded, CwdChanged, FileChanged, DirectoryAdded, MessageDisplay"
ALL_MODES='Expected one of: "acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"'

# Stub doctor. Runs with cwd = the probe directory, like the real one, and answers
# from ./.claude/settings.json. Behaviour is tuned by STUB_* env vars.
cat > "$TMP/stub.sh" <<'STUB'
#!/usr/bin/env bash
set -u
S="./.claude/settings.json"
echo "Claude Code doctor"
echo "Running: native (stub)"
if grep -q 'HarnessDriftSentinel' "$S" 2>/dev/null; then
  echo "Invalid settings"
  echo "- $PWD/.claude/settings.json > hooks.HarnessDriftSentinel: Unknown hook event \"HarnessDriftSentinel\" was ignored. Valid events: ${STUB_EVENTS}"
elif grep -q 'harness-drift-sentinel' "$S" 2>/dev/null; then
  echo "Invalid settings"
  echo "- $PWD/.claude/settings.json > permissions.defaultMode: Invalid value. ${STUB_MODES}"
elif [ -n "${STUB_REJECT_REAL:-}" ]; then
  echo "Invalid settings"
  echo "- $PWD/.claude/settings.json > ${STUB_REJECT_REAL}"
fi
echo "No installation issues found."
STUB
chmod +x "$TMP/stub.sh"
export CLAUDE_DOCTOR_CMD="bash $TMP/stub.sh"

# A stand-in for the CLI file that check 4b greps. Without this the tests would
# scan the real ~150MB binary once per settings key per invocation — slow, and it
# would make results depend on the machine's Claude install rather than fixtures.
ALL_KEYS=$(jq -r 'keys[] | select(. != "hooks" and . != "permissions" and . != "env" and . != "sandbox" and . != "statusLine")' settings.json)
: > "$TMP/fullcli"
for k in $ALL_KEYS; do echo "$k" >> "$TMP/fullcli"; done

run(){ STUB_EVENTS="$1" STUB_MODES="$2" CLAUDE_CLI_BIN="${CLAUDE_CLI_BIN:-$TMP/fullcli}" bash "$CHECK" 2>&1; }

echo "=== Contract holds when upstream matches (exit 0) ==="
OUT=$(run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "clean run exits 0" || fail "clean run exits 0" "exit=$ST
$OUT"
printf '%s' "$OUT" | grep -q "RESULT: contract holds" \
  && pass "reports contract holds" || fail "reports contract holds" "$OUT"

echo ""
echo "=== BREAKAGE: an event the harness registers disappears upstream ==="
# SessionEnd is load-bearing — audit.sh's session summary is wired to it.
GONE_EVENTS=$(printf '%s' "$ALL_EVENTS" | sed 's/SessionEnd, //')
OUT=$(run "$GONE_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "missing event exits 1" || fail "missing event exits 1" "exit=$ST"
printf '%s' "$OUT" | grep -q "SessionEnd is registered in settings.json but is NOT a valid event" \
  && pass "names the dropped event" || fail "names the dropped event" "$OUT"

echo ""
echo "=== BREAKAGE: the shipped defaultMode stops being valid ==="
NO_AUTO='Expected one of: "acceptEdits", "bypassPermissions", "default", "dontAsk", "plan"'
OUT=$(run "$ALL_EVENTS" "$NO_AUTO"); ST=$?
[ "$ST" -eq 1 ] && pass "invalid mode exits 1" || fail "invalid mode exits 1" "exit=$ST"
printf '%s' "$OUT" | grep -q 'no longer a valid defaultMode' \
  && pass "flags the mode" || fail "flags the mode" "$OUT"

echo ""
echo "=== ADVISORY: upstream adds an event nobody has acknowledged (exit 2) ==="
OUT=$(run "$ALL_EVENTS, BrandNewEvent" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "new event exits 2" || fail "new event exits 2" "exit=$ST"
printf '%s' "$OUT" | grep -q "BrandNewEvent" \
  && pass "names the new event" || fail "names the new event" "$OUT"
printf '%s' "$OUT" | grep -q "RESULT: upstream grew" \
  && pass "distinguishes growth from breakage" || fail "distinguishes growth from breakage" "$OUT"

echo ""
echo "=== BREAKAGE: the CLI rejects the shipped settings.json ==="
OUT=$(STUB_REJECT_REAL='permissions.defaultMode: Invalid value.' run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "rejected settings exits 1" || fail "rejected settings exits 1" "exit=$ST"
printf '%s' "$OUT" | grep -q "the CLI rejects part of settings.json" \
  && pass "reports the rejection" || fail "reports the rejection" "$OUT"

echo ""
echo "=== BREAKAGE: doctor's output format changes (no event list at all) ==="
OUT=$(run "" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "unparseable output exits 1" || fail "unparseable output exits 1" "exit=$ST"
printf '%s' "$OUT" | grep -q "could not read the valid-event list" \
  && pass "says it could not parse" || fail "says it could not parse" "$OUT"

echo ""
echo "=== ADVISORY: a settings key the CLI no longer mentions (renamed/removed) ==="
# doctor does not flag unknown top-level keys, so a renamed setting becomes a
# silent no-op. Stand in a fake CLI file that mentions every harness key except
# one and check it is called out.
ALL_KEYS=$(jq -r 'keys[] | select(. != "hooks" and . != "permissions" and . != "env" and . != "sandbox" and . != "statusLine")' settings.json)
DROPPED="skipAutoPermissionPrompt"
: > "$TMP/fakecli"
for k in $ALL_KEYS; do
  [ "$k" = "$DROPPED" ] && continue
  echo "$k" >> "$TMP/fakecli"
done
OUT=$(CLAUDE_CLI_BIN="$TMP/fakecli" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "missing settings key exits 2" || fail "missing settings key exits 2" "exit=$ST"
printf '%s' "$OUT" | grep -q "no longer mentions these keys.*$DROPPED" \
  && pass "names the dropped key" || fail "names the dropped key" "$OUT"
printf '%s' "$OUT" | grep -q "not authoritative" \
  && pass "marks string matching as non-authoritative" || fail "marks string matching as non-authoritative" "$OUT"

echo ""
echo "=== A CLI file that mentions every key is silent ==="
: > "$TMP/fullcli"
for k in $ALL_KEYS; do echo "$k" >> "$TMP/fullcli"; done
OUT=$(CLAUDE_CLI_BIN="$TMP/fullcli" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "all keys present exits 0" || fail "all keys present exits 0" "exit=$ST
$OUT"

echo ""
echo "=== An unlocatable CLI file is skipped, not failed ==="
OUT=$(CLAUDE_CLI_BIN="$TMP/does-not-exist" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "absent CLI file skips" || fail "absent CLI file skips" "exit=$ST"
printf '%s' "$OUT" | grep -q "cannot locate the CLI files" \
  && pass "says it skipped" || fail "says it skipped" "$OUT"

echo ""
echo "=== The contract file is well-formed and covers every live event ==="
jq -e '.acknowledged_hook_events | length > 0' upstream-contract.json >/dev/null 2>&1 \
  && pass "contract lists acknowledged events" || fail "contract lists acknowledged events" "bad json"
MISSING=""
for ev in $(printf '%s' "$ALL_EVENTS" | tr -d ' ' | tr ',' '\n'); do
  jq -e --arg e "$ev" '.acknowledged_hook_events | index($e) != null' upstream-contract.json >/dev/null 2>&1 \
    || MISSING="$MISSING $ev"
done
[ -z "$MISSING" ] && pass "every 2.1.228 event is acknowledged" || fail "every 2.1.228 event is acknowledged" "missing:$MISSING"

echo ""
echo "=== Every event the harness hooks is acknowledged in the contract ==="
UNACK=""
while IFS= read -r ev; do
  jq -e --arg e "$ev" '.acknowledged_hook_events | index($e) != null' upstream-contract.json >/dev/null 2>&1 \
    || UNACK="$UNACK $ev"
done < <(jq -r '.hooks | keys[]' settings.json)
[ -z "$UNACK" ] && pass "settings.json events all acknowledged" || fail "settings.json events all acknowledged" "unacked:$UNACK"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
