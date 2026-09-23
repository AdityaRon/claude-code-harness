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
CHECK="bin/upstream-check.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
# Defined because they were not, and calling one anyway printed "command not
# found" while the suite still reported zero failures -- the assertion simply
# never ran. Same names and argument order as every other suite here, so reaching
# for the familiar one is no longer a silent skip.
check_contains(){ case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent(){   case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }

# The real list as of 2.1.266 (PreModelSwitch/PostModelSwitch arrived in 2.1.251).
#
# This models what UPSTREAM offers, so it is deliberately hardcoded rather than
# read from upstream-contract.json: the contract is what this harness has
# acknowledged, and a check cannot supply its own expected input. The cost is
# that the two lists drift by hand — when the harness starts hooking an event
# this stub has never heard of, section 2 reports it as vanished upstream and
# every exit-code assertion below fails at once. That is what happened when
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
echo "No installation issues found."
STUB
chmod +x "$TMP/stub.sh"
export CLAUDE_DOCTOR_CMD="bash $TMP/stub.sh"
# Section 6 would otherwise read this machine's cached changelog.
export CLAUDE_CHANGELOG_PATH="$TMP/no-changelog.md"

# A stand-in for the CLI file that check 4b greps. Without this the tests would
# scan the real ~150MB binary once per settings key per invocation — slow, and it
# would make results depend on the machine's Claude install rather than fixtures.
ALL_KEYS=$(jq -r 'keys[] | select(. != "hooks" and . != "permissions" and . != "env" and . != "sandbox" and . != "statusLine")' config/settings.json)

# 4c greps the same file for every capability in acknowledged_surface, so a
# "complete CLI" fixture has to carry those too. Without them every test using
# this fixture trips 4c, and the failure reads as if it came from the section
# under test rather than from the fixture.
ALL_SURFACE=$(jq -r '(.acknowledged_surface // {})
                     | (((.tools // {}) | keys[]?), ((.settings_keys // {}) | keys[]?))' \
              config/upstream-contract.json | grep -v '^_comment$')

# 4d reads the two memory-index limits out of the CLI rather than trusting the
# contract, so a "complete CLI" fixture has to carry that expression too. The
# identifiers are deliberately NOT the ones the real bundle happens to use: the
# check resolves them from the expression, and a fixture that reused the real
# names would pass even if the check had them hardcoded.
mkcli(){  # mkcli <path> [capability-to-omit]
  local out="$1" omit="${2:-}" k
  : > "$out"
  for k in $ALL_KEYS $ALL_SURFACE; do
    [ "$k" = "$omit" ] && continue
    echo "$k" >> "$out"
  done
  [ "$omit" = "__memlimits__" ] && return 0
  local wl="${MEMLIMIT_LINES:-200}" wb="${MEMLIMIT_BYTES:-25000}"
  echo "var qZ=$wl,zQ9=$wb;let{trimmed:aa,lineCount:bb,byteCount:cc}=T(e),dd=bb>qZ,ee=cc>zQ9;" >> "$out"
}
mkcli "$TMP/fullcli"

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
echo "=== 4c: the acknowledged non-hook surface ==="
# The gap this section exists for: cross-session messaging shipped two tools and
# two settings keys in 2.1.224, and the check said "contract holds" throughout,
# because hook events were the only population it could enumerate.
OUT=$(CLAUDE_CLI_BIN="$TMP/fullcli" run "$ALL_EVENTS" "$ALL_MODES")
printf '%s' "$OUT" | grep -q "4c\. acknowledged tools and settings keys" \
  && pass "4c runs" || fail "4c runs" "$OUT"
printf '%s' "$OUT" | grep -qE "all [0-9]+ acknowledged capabilities still present" \
  && pass "reports all acknowledged capabilities present" || fail "reports all present" "$OUT"
# The denominator must be printed. A bare tick reads as "we checked everything",
# which is the exact misreading that let 2.1.224 through.
printf '%s' "$OUT" | grep -qE "verified [0-9]+ acknowledged capabilit" \
  && pass "prints the denominator" || fail "prints the denominator" "$OUT"
printf '%s' "$OUT" | grep -q "CANNOT" \
  && pass "states it cannot discover unacknowledged capabilities" \
  || fail "states the discovery limitation" "$OUT"

# A capability upstream dropped must strand loudly, not pass quietly.
GONE_CAP=$(printf '%s\n' $ALL_SURFACE | head -1)
mkcli "$TMP/nocap" "$GONE_CAP"
OUT=$(CLAUDE_CLI_BIN="$TMP/nocap" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "a vanished acknowledged capability exits 2" \
  || fail "vanished capability exits 2" "exit=$ST"
printf '%s' "$OUT" | grep -q "$GONE_CAP" \
  && pass "names the vanished capability" || fail "names the vanished capability" "$OUT"
printf '%s' "$OUT" | grep -q "stranded" \
  && pass "says the recorded decision is stranded" || fail "says stranded" "$OUT"

# Every messaging capability must actually be acknowledged — this is the
# regression guard for the specific miss that motivated the section.
for cap in SendMessage ListAgents crossSessionInbound isolatePeerMachines; do
  printf '%s\n' $ALL_SURFACE | grep -qx "$cap" \
    && pass "contract acknowledges $cap" || fail "contract acknowledges $cap" "absent"
done

echo ""
echo "=== An unlocatable CLI file is skipped, not failed ==="
OUT=$(CLAUDE_CLI_BIN="$TMP/does-not-exist" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "absent CLI file skips" || fail "absent CLI file skips" "exit=$ST"
printf '%s' "$OUT" | grep -q "cannot locate the CLI files" \
  && pass "says it skipped" || fail "says it skipped" "$OUT"

echo ""
echo "=== The contract file is well-formed and covers every live event ==="
jq -e '.acknowledged_hook_events | length > 0' config/upstream-contract.json >/dev/null 2>&1 \
  && pass "contract lists acknowledged events" || fail "contract lists acknowledged events" "bad json"
MISSING=""
for ev in $(printf '%s' "$ALL_EVENTS" | tr -d ' ' | tr ',' '\n'); do
  jq -e --arg e "$ev" '.acknowledged_hook_events | index($e) != null' config/upstream-contract.json >/dev/null 2>&1 \
    || MISSING="$MISSING $ev"
done
[ -z "$MISSING" ] && pass "every 2.1.228 event is acknowledged" || fail "every 2.1.228 event is acknowledged" "missing:$MISSING"

echo ""
echo "=== Every event the harness hooks is acknowledged in the contract ==="
UNACK=""
while IFS= read -r ev; do
  jq -e --arg e "$ev" '.acknowledged_hook_events | index($e) != null' config/upstream-contract.json >/dev/null 2>&1 \
    || UNACK="$UNACK $ev"
done < <(jq -r '.hooks | keys[]' config/settings.json)
[ -z "$UNACK" ] && pass "settings.json events all acknowledged" || fail "settings.json events all acknowledged" "unacked:$UNACK"

echo ""
echo "=== 4d: the memory index limits are READ from the CLI, not asserted ==="
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
[ "$ST" != "0" ] && pass "a moved limit is not exit 0" || fail "a moved limit is not exit 0" "exit=$ST"

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


echo "=== 6. releases since last_verified_version (exit 2) ==="
PIN=$(jq -r '.last_verified_version' config/upstream-contract.json); PIN=${PIN%% *}
cat > "$TMP/changelog.md" <<EOF
# Changelog

## 9.9.2

- Added a \`NewShinyTool\` tool for doing things
- Fixed the mouse wheel in fullscreen mode
- [VSCode] Added a hooks dialog
- Changed SendMessage to accept attachments

## 9.9.1

- Fixed a typo in /help

## $PIN

- Added something already assessed
EOF
OUT=$(CLAUDE_CHANGELOG_PATH="$TMP/changelog.md" CLAUDE_CLI_VERSION=9.9.2 run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "unassessed releases exit 2" || fail "unassessed releases exit 2" "exit=$ST"
check_contains "counts both releases" "2 release(s) since $PIN" "$OUT"
check_contains "surfaces an Added line" "NewShinyTool" "$OUT"
check_contains "surfaces a line naming an acknowledged tool" "SendMessage to accept" "$OUT"
check_absent "drops unrelated fixes" "mouse wheel" "$OUT"
check_absent "drops editor-only lines" "[VSCode]" "$OUT"
check_absent "drops a release with no hits" "## 9.9.1" "$OUT"
check_absent "stops at the verified release" "already assessed" "$OUT"

OUT=$(CLAUDE_CHANGELOG_PATH="$TMP/changelog.md" CLAUDE_CLI_VERSION="$PIN" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "verified at the installed version exits 0" || fail "verified at installed version exits 0" "exit=$ST"

# Under test VERSION is "(stubbed)": fall back to the changelog's newest release.
OUT=$(CLAUDE_CHANGELOG_PATH="$TMP/changelog.md" run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "unknown CLI version uses the newest release" || fail "unknown version falls back" "exit=$ST"

# 2.1.279 shipped with no heading: an unlisted version must not read as "nothing new".
OUT=$(CLAUDE_CHANGELOG_PATH="$TMP/changelog.md" CLAUDE_CLI_VERSION=9.9.3 run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "unlisted CLI version still reports" || fail "unlisted CLI version still reports" "exit=$ST"
check_contains "from the newest listed release" "2 release(s) since" "$OUT"

grep -v "^## $PIN\$" "$TMP/changelog.md" > "$TMP/nopin.md"
OUT=$(CLAUDE_CHANGELOG_PATH="$TMP/nopin.md" CLAUDE_CLI_VERSION=9.9.2 run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 2 ] && pass "unlisted pin exits 2" || fail "unlisted pin exits 2" "exit=$ST"
check_contains "and names the problem" "has no changelog heading" "$OUT"
check_absent "without dumping the whole changelog" "already assessed" "$OUT"
check_absent "and does not claim verified" "contract verified" "$OUT"

OUT=$(run "$ALL_EVENTS" "$ALL_MODES"); ST=$?
[ "$ST" -eq 0 ] && pass "absent changelog skips" || fail "absent changelog skips" "exit=$ST"
check_contains "and says so" "skipped: no changelog" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
