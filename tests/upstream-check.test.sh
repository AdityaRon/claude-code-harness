#!/usr/bin/env bash
# Tests for upstream-check.sh — the scheduled guard that catches Claude Code
# breaking something the harness relies on.
#
# A breakage detector that only ever passes is worthless, so these tests simulate
# upstream actually moving: an event the harness depends on disappearing, the
# shipped permission mode becoming invalid, a memory limit moving, and doctor's
# output format changing. No Claude Code install needed — CLAUDE_DOCTOR_CMD
# substitutes a stub that behaves like `claude doctor`.
set -u
CHECK="tools/upstream-check.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
# Defined because they were not, and calling one anyway printed "command not
# found" while the suite still reported zero failures -- the assertion simply
# never ran. Same names and argument order as every other suite here, so reaching
# for the familiar one is no longer a silent skip.
check_contains(){ case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent(){   case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }

# The real list as of 2.1.280 (PreModelSwitch/PostModelSwitch arrived in 2.1.251).
#
# This models what UPSTREAM offers, so it is deliberately hardcoded rather than
# read from config/settings.json: a check cannot supply its own expected input.
# The cost is that the list drifts by hand — when the harness starts hooking an
# event this stub has never heard of, section 2 reports it as vanished upstream
# and every exit-code assertion below fails at once. That is what happened when
# PostModelSwitch was adopted.
ALL_EVENTS="PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, UserPromptSubmit, UserPromptExpansion, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, PermissionRequest, PermissionDenied, Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove, InstructionsLoaded, CwdChanged, FileChanged, DirectoryAdded, MessageDisplay"
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
# STUB_TRUST: 2.1.311's trust gate. A directory the config dir does not trust,
# keyed by its physical path as the real CLI keys it, gets the warning.
if [ -n "${STUB_TRUST:-}" ] && ! jq -e --arg d "$(pwd -P)" '.projects[$d].hasTrustDialogAccepted == true' \
     "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" >/dev/null 2>&1; then
  echo "- $PWD/.claude/settings.json > Ignoring permissions.allow entries: this workspace has not been trusted"
fi
echo "No installation issues found."
STUB
chmod +x "$TMP/stub.sh"
export CLAUDE_DOCTOR_CMD="bash $TMP/stub.sh"
# A stand-in for the CLI file that check 4 greps. Without this the tests would
# scan the real ~150MB binary once per settings key per invocation — slow, and it
# would make results depend on the machine's Claude install rather than fixtures.
ALL_TOOLS=$(jq -r '[.hooks[][]?.matcher // empty | split("|")[] | select(test("^[A-Za-z]+$"))] | unique[]' config/settings.json)
ALL_KEYS=$(jq -r 'keys[] | select(. != "hooks" and . != "permissions" and . != "env" and . != "sandbox" and . != "statusLine")' config/settings.json)

# Section 5 reads the two memory-index limits out of the CLI rather than trusting the
# contract, so a "complete CLI" fixture has to carry that expression too. The
# identifiers are deliberately NOT the ones the real bundle happens to use: the
# check resolves them from the expression, and a fixture that reused the real
# names would pass even if the check had them hardcoded.
mkcli(){  # mkcli <path> [key-to-omit]
  local out="$1" omit="${2:-}" k
  : > "$out"
  for k in $ALL_KEYS $ALL_TOOLS; do
    [ "$k" = "$omit" ] && continue
    echo "$k" >> "$out"
  done
  [ "$omit" = "__memlimits__" ] && return 0
  local wl="${MEMLIMIT_LINES:-200}" wb="${MEMLIMIT_BYTES:-25000}"
  echo "var qZ=$wl,zQ9=$wb;let{trimmed:aa,lineCount:bb,byteCount:cc}=T(e),dd=bb>qZ,ee=cc>zQ9;" >> "$out"
}
mkcli "$TMP/fullcli"

run(){ STUB_EVENTS="$1" STUB_MODES="$2" CLAUDE_CLI_BIN="${CLAUDE_CLI_BIN:-$TMP/fullcli}" bash "$CHECK" 2>&1; }

echo "=== Nothing relied on has moved (exit 0) ==="
OUT=$(run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "clean run exits 0" || fail "clean run exits 0" "exit=$ST
$OUT"
printf '%s' "$OUT" | grep -q "RESULT: nothing the harness relies on has moved" \
  && pass "reports nothing moved" || fail "reports nothing moved" "$OUT"

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
echo "=== An event upstream adds is not a signal: this checks breakage only ==="
OUT=$(run "$ALL_EVENTS, BrandNewEvent" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "a new event exits 0" || fail "a new event exits 0" "exit=$ST
$OUT"
check_absent "and is not named" "BrandNewEvent" "$OUT"

echo ""
echo "=== BREAKAGE: the shipped defaultMode and the contract's expected one disagree ==="
jq '.expected_default_mode="plan"' config/upstream-contract.json > "$TMP/c.json"
OUT=$(CLAUDE_UPSTREAM_CONTRACT="$TMP/c.json" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "a disagreeing mode exits 1" || fail "a disagreeing mode exits 1" "exit=$ST"
check_contains "and names both" 'sets defaultMode "auto" but upstream-contract.json expects "plan"' "$OUT"

echo ""
echo "=== BREAKAGE: the CLI rejects the shipped settings.json ==="
OUT=$(STUB_REJECT_REAL='permissions.defaultMode: Invalid value.' run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "rejected settings exits 1" || fail "rejected settings exits 1" "exit=$ST"
printf '%s' "$OUT" | grep -q "the CLI rejects part of settings.json" \
  && pass "reports the rejection" || fail "reports the rejection" "$OUT"

echo ""
echo "=== 2.1.311's trust gate: each probe trusts its directory in a config of its own ==="
# TMPDIR behind a symlink, as macOS's /var is: the gate keys trust by the
# physical path. The sentinel ~/.claude.json must come back byte for byte.
mkdir -p "$TMP/home" "$TMP/realtmp" && ln -s "$TMP/realtmp" "$TMP/linktmp"
printf '{"projects":{}}\n' > "$TMP/home/.claude.json" && cp "$TMP/home/.claude.json" "$TMP/home.before"
OUT=$(STUB_TRUST=1 HOME="$TMP/home" TMPDIR="$TMP/linktmp/" run "$ALL_EVENTS" "$ALL_MODES")
check_absent "the trust gate is not read as a rejection" "the CLI rejects part of settings.json" "$OUT"
cmp -s "$TMP/home/.claude.json" "$TMP/home.before" && pass "the user's ~/.claude.json is untouched" \
  || fail "the user's ~/.claude.json is untouched" "$(cat "$TMP/home/.claude.json")"
[ -z "$(ls -A "$TMP/realtmp")" ] && pass "the probes' config goes with the run's temp dir" \
  || fail "the probes' config goes with the run's temp dir" "$(ls -A "$TMP/realtmp")"

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
ALL_KEYS=$(jq -r 'keys[] | select(. != "hooks" and . != "permissions" and . != "env" and . != "sandbox" and . != "statusLine")' config/settings.json)
DROPPED="skipAutoPermissionPrompt"
mkcli "$TMP/fakecli" "$DROPPED"
OUT=$(CLAUDE_CLI_BIN="$TMP/fakecli" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "missing settings key exits 2" || fail "missing settings key exits 2" "exit=$ST"
printf '%s' "$OUT" | grep -q "no longer mentions these keys.*$DROPPED" \
  && pass "names the dropped key" || fail "names the dropped key" "$OUT"
printf '%s' "$OUT" | grep -q "not authoritative" \
  && pass "marks string matching as non-authoritative" || fail "marks string matching as non-authoritative" "$OUT"

echo ""
echo "=== A CLI file that mentions every key is silent ==="
mkcli "$TMP/fullcli"
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
echo "=== 5: the memory index limits are READ from the CLI, not asserted ==="
# memory-lint and memory-verify gate on 200 lines / 25,000 bytes. Those numbers
# were folklore here for a while -- the research doc called the line cap
# "unsubstantiated" while two tools enforced it as fact -- and a wrong threshold
# fails in the worst direction: the index quietly stops loading its tail and
# nothing says so.
OUT=$(run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -qF "index line limit 200 matches" \
  && pass "matching limits are confirmed by value" || fail "matching limits are confirmed by value" "$OUT"
printf '%s' "$OUT" | grep -qF "index byte limit 25000 matches" \
  && pass "and the byte limit too" || fail "and the byte limit too" "$OUT"
printf '%s' "$OUT" | grep -qF "byteCount (bytes, not characters)" \
  && pass "names the unit, not just the number" || fail "names the unit, not just the number" "$OUT"

# If upstream moves a limit, the check must say which way and name both numbers.
# A bare "mismatch" leaves the reader unable to tell whether the harness is now
# too strict (noise) or too loose (silent truncation).
mkcli "$TMP/movedcli"
MEMLIMIT_LINES=150 mkcli "$TMP/movedcli"
OUT=$(CLAUDE_CLI_BIN="$TMP/movedcli" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
printf '%s' "$OUT" | grep -qF "index LINE limit is 150 upstream" \
  && pass "a moved LINE limit is reported" || fail "a moved LINE limit is reported" "$OUT"
printf '%s' "$OUT" | grep -qF "contract says 200" \
  && pass "and names what the contract claims" || fail "and names what the contract claims" "$OUT"
printf '%s' "$OUT" | grep -qF "gating on the wrong number" \
  && pass "and says which tools are wrong" || fail "and says which tools are wrong" "$OUT"
[ "$ST" -eq 1 ] && pass "a moved limit is a breakage (exit 1)" || fail "a moved limit is a breakage" "exit=$ST"

MEMLIMIT_BYTES=30000 mkcli "$TMP/movedbytes"
OUT=$(CLAUDE_CLI_BIN="$TMP/movedbytes" run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -qF "index BYTE limit is 30000 upstream" \
  && pass "a moved BYTE limit is reported" || fail "a moved BYTE limit is reported" "$OUT"

# The property that matters most. A CLI this cannot parse must read as
# UNVERIFIED, never as a pass -- "we could not check" and "we checked and it is
# fine" are the same output only if you let them be.
mkcli "$TMP/nolimits" __memlimits__
OUT=$(CLAUDE_CLI_BIN="$TMP/nolimits" run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -qF "UNVERIFIED on this run" \
  && pass "an unparseable CLI says UNVERIFIED" || fail "an unparseable CLI says UNVERIFIED" "$OUT"
printf '%s' "$OUT" | grep -qF "matches the contract" \
  && fail "and does not claim a match" "reported a match it never verified" \
  || pass "and does not claim a match"

# Minified names are reused across scopes. The 2.1.282 native binary binds the
# line-limit name to 3600000 earlier in the file, and the check reported that.
{ echo "function f(){var qZ=3600000,x=1}"; cat "$TMP/fullcli"; } > "$TMP/reused"
OUT=$(CLAUDE_CLI_BIN="$TMP/reused" run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -qF "index line limit 200 matches" \
  && pass "a reused minified name resolves to the paired declaration" \
  || fail "a reused minified name resolves to the paired declaration" "$OUT"
{ echo "var qZ=3600000;"; echo "var qZ=150;"; cat "$TMP/nolimits"
  echo "let{trimmed:aa,lineCount:bb,byteCount:cc}=T(e),dd=bb>qZ,ee=cc>zQ9;var zQ9=25000;"; } > "$TMP/ambiguous"
OUT=$(CLAUDE_CLI_BIN="$TMP/ambiguous" run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -qF "UNVERIFIED on this run" \
  && pass "an ambiguous name reads as UNVERIFIED, not a value" \
  || fail "an ambiguous name reads as UNVERIFIED, not a value" "$OUT"
# The Linux 2.1.283 binary names the line limit P$. Unescaped in a regex, the
# $ is an end-of-line anchor and the name never matches.
{ cat "$TMP/nolimits"
  echo 'var P$=200,Z3=25000;let{trimmed:aa,lineCount:b$,byteCount:cc}=T(e),dd=b$>P$,ee=cc>Z3;'; } > "$TMP/dollar"
OUT=$(CLAUDE_CLI_BIN="$TMP/dollar" run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -qF "index line limit 200 matches" \
  && pass "a minified name holding \$ still resolves" \
  || fail "a minified name holding \$ still resolves" "$OUT"


echo ""
echo "=== 6: a tool a hook matcher names must still exist in the CLI ==="
OUT=$(run "$ALL_EVENTS" "$ALL_MODES")
check_contains "tool names are read from the matchers" "✓ ExitPlanMode" "$OUT"
check_absent "the regex matcher is not a tool name" "mcp__" "$OUT"
mkcli "$TMP/notool" ExitPlanMode
OUT=$(CLAUDE_CLI_BIN="$TMP/notool" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "a renamed tool exits 1" || fail "a renamed tool exits 1" "exit=$ST"
check_contains "and is named" "ExitPlanMode is named in a hook matcher" "$OUT"
jq '.hooks.PreToolUse += [{"matcher":"MadeUpTool","hooks":[{"type":"command","command":"true"}]}]' config/settings.json > "$TMP/s.json"
OUT=$(CLAUDE_UPSTREAM_SETTINGS="$TMP/s.json" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 1 ] && pass "a made-up tool in a matcher exits 1" || fail "a made-up tool in a matcher exits 1" "exit=$ST"
check_contains "and names it" "MadeUpTool is named in a hook matcher" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
