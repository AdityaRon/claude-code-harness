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
[[ $rc == 0 && "$(jq -r .sandbox.enabled "$CLAUDE_SETTINGS_FILE")" == true && "$OUT" == *"sandbox:           on"* && "$OUT" == *"denied reads:      ~/.ssh"* ]] \
  && pass "on sets sandbox.enabled true" || fail "on" "rc=$rc $OUT"
jq '.sandbox.filesystem.allowWrite = ["~/.claude/jobs", "/opt/data"]' "$CLAUDE_SETTINGS_FILE" > "$TMP/aw.json"
OUT=$(CLAUDE_SETTINGS_FILE="$TMP/aw.json" bash "$T" status 2>&1)
[[ "$OUT" == *"~/.claude/jobs (no effect"* && "$OUT" == *"/opt/data"* && "$OUT" != *"/opt/data (no effect"* ]] \
  && pass "status flags a write path under ~/.claude as having no effect" || fail "write path flag" "$OUT"
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
OLD='{"sandbox":{"enabled":true,"filesystem":{"allowWrite":["~/.claude/jobs"]}}}'
OUT=$(jq -s --arg home "$HOME" --argjson owned '[]' -f config/merge-settings.jq <(printf '%s' "$OLD") config/settings.json)
[[ "$(printf '%s' "$OUT" | jq -c '[.sandbox.enabled, (.sandbox.excludedCommands | length), .sandbox.network.allowLocalBinding, .sandbox.filesystem.denyRead]')" == '[true,6,true,["~/.ssh"]]' ]] \
  && pass "sandbox on survives install, and the shipped exclusions, local binding and ~/.ssh deny arrive" || fail "merge" "$(printf '%s' "$OUT" | jq -c .sandbox)"

echo ""
echo "=== sandbox-trial.sh, unsandboxed and offline ==="
mkdir -p "$TMP/home/.claude" "$TMP/job/tmp"
export CLAUDE_SETTINGS_FILE="$TMP/none.json"
OUT=$(cd "$TMP" && HOME="$TMP/home" CLAUDE_JOB_DIR="$TMP/job" bash "$OLDPWD/bin/sandbox-trial.sh" --offline 2>&1); rc=$?
[[ $rc == 0 && "$OUT" == *"sandbox: OFF"* ]] && pass "detects that it is not sandboxed" || fail "detect off" "rc=$rc $OUT"
OUT2=$(cd "$TMP" && env -u CLAUDE_JOB_DIR HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" --offline 2>&1)
[[ "$OUT2" == *"session scratch"*"skipped: CLAUDE_JOB_DIR is unset"* ]] && pass "no job dir: the scratch probe is skipped, not failed" || fail "no job dir" "$OUT2"
[[ "$(grep -c '^  INFO' <<<"$OUT")" == 8 ]] && pass "reports every offline probe" || fail "probe count" "$OUT"
jq -n '{sandbox: {enabled: true}}' > "$TMP/on.json"
OUT=$(cd "$TMP" && CLAUDE_SETTINGS_FILE="$TMP/on.json" HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" --offline 2>&1)
[[ "$OUT" == *"settings say on, but this shell is not sandboxed"* ]] && pass "settings on, shell not sandboxed: says so" || fail "settings on" "$OUT"
OUT=$(cd "$TMP" && HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" --offline --local-url http://127.0.0.1:9/ 2>&1)
[[ "$OUT" == *"net: http://127.0.0.1:9/"*"no answer"* ]] && pass "--local-url adds the probe, offline too" || fail "--local-url" "$OUT"
OUT=$(cd "$TMP" && SANDBOX_TRIAL_LOCAL_URL=http://127.0.0.1:9/ HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" --offline 2>&1)
[[ "$OUT" == *"net: http://127.0.0.1:9/"* ]] && pass "the env var still works" || fail "env var" "$OUT"
OUT=$(bash bin/sandbox-trial.sh --sideways 2>&1); rc=$?
[[ $rc == 2 && "$OUT" == *"--local-url"* ]] && pass "unknown flag prints usage" || fail "trial usage" "rc=$rc $OUT"
[[ -z "$(find "$TMP" -name '.sandbox-trial.*')" ]] && pass "leaves no probe files behind" || fail "cleanup" "$(find "$TMP" -name '.sandbox-trial.*')"

echo ""
echo "=== sandbox-trial.sh online, curl and git stubbed ==="
mkdir -p "$TMP/stub"
printf '#!/bin/sh\necho 200\n' > "$TMP/stub/curl"
printf '#!/bin/sh\nprintf "0123456789abcdef\\tHEAD\\n"\n' > "$TMP/stub/git"
chmod +x "$TMP/stub/curl" "$TMP/stub/git"
OUT=$(cd "$TMP" && PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" 2>&1)
[[ "$OUT" == *"example.com (not listed)"*"strictAllowlist denies them"* ]] \
  && pass "no strictAllowlist: an unlisted host is reported, not judged" || fail "not strict" "$OUT"
jq -n '{sandbox: {network: {strictAllowlist: true}}}' > "$TMP/strict.json"
OUT=$(cd "$TMP" && CLAUDE_SETTINGS_FILE="$TMP/strict.json" PATH="$TMP/stub:$PATH" HOME="$TMP/home" bash "$OLDPWD/bin/sandbox-trial.sh" 2>&1)
[[ "$OUT" == *"example.com (not listed)"*"(HTTP 200, strictAllowlist)"* ]] \
  && pass "strictAllowlist: an unlisted host must be blocked" || fail "strict" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
