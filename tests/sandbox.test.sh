#!/usr/bin/env bash
# Tests for bin/sandbox.sh and bin/sandbox-trial.sh (the trial runs unsandboxed here).
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_SETTINGS_FILE="$TMP/settings.json"
T="bin/sandbox.sh"
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }

echo "=== sandbox.sh ==="
OUT=$(bash "$T" status 2>&1); rc=$?
[[ $rc == 1 && "$OUT" == *"run install.sh first"* ]] && pass "no settings file: says so, changes nothing" || fail "no settings" "rc=$rc $OUT"
jq '{permissions: {defaultMode: "auto"}, env: {A: "1"}, sandbox: .sandbox}' config/settings.json > "$CLAUDE_SETTINGS_FILE"
OUT=$(bash "$T" on 2>&1); rc=$?
[[ $rc == 0 && "$(jq -r .sandbox.enabled "$CLAUDE_SETTINGS_FILE")" == true && "$OUT" == *"sandbox:           on"* ]] \
  && pass "on sets sandbox.enabled true" || fail "on" "rc=$rc $OUT"
[[ "$(jq -c '[.env.A, .permissions.defaultMode, (.sandbox.excludedCommands | length)]' "$CLAUDE_SETTINGS_FILE")" == '["1","auto",6]' ]] \
  && pass "other keys untouched" || fail "other keys" "$(cat "$CLAUDE_SETTINGS_FILE")"
compgen -G "$CLAUDE_SETTINGS_FILE.bak.*" >/dev/null && pass "a backup is kept" || fail "backup" "$(ls "$TMP")"
bash "$T" off >/dev/null 2>&1
[[ "$(jq -r .sandbox.enabled "$CLAUDE_SETTINGS_FILE")" == false ]] && pass "off sets it false" || fail "off" "$(cat "$CLAUDE_SETTINGS_FILE")"
printf '{not json' > "$CLAUDE_SETTINGS_FILE"
OUT=$(bash "$T" on 2>&1); rc=$?
[[ $rc == 1 && "$(cat "$CLAUDE_SETTINGS_FILE")" == '{not json' ]] && pass "broken settings left alone" || fail "broken settings" "rc=$rc $OUT"
mkdir "$TMP/ro" && jq -n '{sandbox: {enabled: false}}' > "$TMP/ro/settings.json" && chmod 555 "$TMP/ro"
OUT=$(CLAUDE_SETTINGS_FILE="$TMP/ro/settings.json" bash "$T" on 2>&1); rc=$?
chmod 755 "$TMP/ro"
[[ $rc == 1 && "$OUT" == *"as the first character"* && "$(jq -c . "$TMP/ro/settings.json")" == '{"sandbox":{"enabled":false}}' ]] \
  && pass "an unwritable settings folder: says how to run it, changes nothing" || fail "unwritable" "rc=$rc $OUT"
OUT=$(bash "$T" sideways 2>&1); rc=$?
[[ $rc == 2 && "$OUT" == *"on | off | status"* ]] && pass "unknown word prints usage" || fail "usage" "rc=$rc $OUT"

echo ""
echo "=== install keeps the machine's choice ==="
OLD='{"sandbox":{"enabled":true}}'
OUT=$(jq -s --arg home "$HOME" --argjson owned '[]' -f config/merge-settings.jq <(printf '%s' "$OLD") config/settings.json)
[[ "$(printf '%s' "$OUT" | jq -c '[.sandbox.enabled, (.sandbox.excludedCommands | length)]')" == '[true,6]' ]] \
  && pass "sandbox on survives install, and the shipped exclusions arrive" || fail "merge" "$(printf '%s' "$OUT" | jq -c .sandbox)"

echo ""
echo "=== sandbox-trial.sh, unsandboxed and offline ==="
mkdir -p "$TMP/home/.claude" "$TMP/job/tmp"
OUT=$(cd "$TMP" && HOME="$TMP/home" CLAUDE_JOB_DIR="$TMP/job" bash "$OLDPWD/bin/sandbox-trial.sh" --offline 2>&1); rc=$?
[[ $rc == 0 && "$OUT" == *"sandbox: OFF"* ]] && pass "detects that it is not sandboxed" || fail "detect off" "rc=$rc $OUT"
OUT2=$(cd "$TMP" && env -u CLAUDE_JOB_DIR HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" --offline 2>&1)
[[ "$OUT2" == *"session scratch"*"skipped: CLAUDE_JOB_DIR is unset"* ]] && pass "no job dir: the scratch probe is skipped, not failed" || fail "no job dir" "$OUT2"
[[ "$(grep -c '^  INFO' <<<"$OUT")" == 7 ]] && pass "reports every offline probe" || fail "probe count" "$OUT"
[[ -z "$(find "$TMP" -name '.sandbox-trial.*')" ]] && pass "leaves no probe files behind" || fail "cleanup" "$(find "$TMP" -name '.sandbox-trial.*')"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
