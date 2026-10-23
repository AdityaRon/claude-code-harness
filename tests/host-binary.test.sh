#!/usr/bin/env bash
# Tests for the deleted-host-binary diagnosis: lib.sh's claude_host,
# host_binary_check and stale_claude_hosts on a ps snapshot file
# (CLAUDE_HOST_PS), the session-start call, hooks/tcc-check.sh on Bash results,
# and doctor.sh --hosts. No real TCC denial is needed: the check tests whether
# the host's binary path exists, which is the measured cause.
set -u
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "missing: $2 in [$3]"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "unexpected: $2 in [$3]"; else pass "$1"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/Desktop" "$HOME/.claude/state" "$TMP/repo"
export CLAUDE_STATE_DIR="$TMP/state" CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
export CLAUDE_CONTRACT_PIN="$TMP/no-pin" CLAUDE_HARNESS_LATEST="$TMP/no-latest" CLAUDE_HARNESS_VERSION="$TMP/no-version"
export CLAUDE_CLI_UPGRADED="$TMP/cli-upgraded" CLAUDE_AUDIT_LOG="$TMP/audit.log"
mkdir -p "$CLAUDE_STATE_DIR" "$CLAUDE_MEMORY_PROJECTS_DIR"

# A background session: launchd → host → resume client → zsh → bash (400), and a
# terminal one: iTerm2 → zsh → claude → zsh (530). Both binaries start out deleted.
BIN="$TMP/Caskroom/claude-code@latest/2.1.307/claude"
TBIN="$TMP/Caskroom/claude-code@latest/2.1.300/claude"
mkdir -p "$(dirname "$BIN")" "$(dirname "$TBIN")"
export CLAUDE_HOST_PS="$TMP/ps.txt"
cat > "$CLAUDE_HOST_PS" <<EOF
    1     0 /sbin/launchd
  100     1 $BIN
  200   100 $BIN
  300   200 /bin/zsh
  400   300 /bin/bash
  500     1 /Applications/iTerm.app/Contents/MacOS/iTerm2
  510   500 /bin/zsh
  520   510 $TBIN
  530   520 /bin/zsh
  600     1 /Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
EOF
lib() { bash -c "source hooks/lib.sh; $*"; }

echo "=== claude_host: the top-most claude above a pid, and its parent ==="
OUT=$(lib 'claude_host 400')
[ "$OUT" = "$(printf '100\t1\t%s\tlaunchd' "$BIN")" ] && pass "background: the host (100), not the client (200); parent launchd" || fail "background chain" "[$OUT]"
OUT=$(lib 'claude_host 530')
[ "$OUT" = "$(printf '520\t510\t%s\t/Applications/iTerm.app/Contents/MacOS/iTerm2' "$TBIN")" ] && pass "terminal: the one claude, and the app above it" || fail "terminal chain" "[$OUT]"
[ -z "$(lib 'claude_host 600')" ] && pass "no claude above: nothing" || fail "no claude" "$(lib 'claude_host 600')"

echo ""
echo "=== host_binary_check: a deleted host binary is named, with the fix ==="
OUT=$(CLAUDE_HOST_START=400 lib 'host_binary_check'); RC=$?
[ "$RC" = 1 ] && pass "returns 1" || fail "returns 1" "rc=$RC"
has "heads the diagnosis" "## This session's Claude Code binary is gone" "$OUT"
has "names the host pid and the path" "pid 100, runs from $BIN, which no longer exists" "$OUT"
has "names the symptom" "'Operation not permitted'" "$OUT"
has "and the fix" "restart this session" "$OUT"
has "and the way out" "bin/relocate-clones.sh" "$OUT"
lacks "no marker: no updater line" "harness-update.sh's last CLI upgrade" "$OUT"
printf 'claude-code@latest 2.1.306 -> 2.1.307 at 2026-10-22T21:27:26Z; pids running the old binary: 100\n' > "$CLAUDE_CLI_UPGRADED"
OUT=$(CLAUDE_HOST_START=400 lib 'host_binary_check')
has "the updater's record is named when present" "harness-update.sh's last CLI upgrade: claude-code@latest 2.1.306 -> 2.1.307" "$OUT"
rm -f "$CLAUDE_CLI_UPGRADED"

echo ""
echo "=== silent when the binary exists, or the session is under a terminal app ==="
: > "$BIN"
OUT=$(CLAUDE_HOST_START=400 lib 'host_binary_check'); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "binary present: silent, returns 0" || fail "present" "rc=$RC [$OUT]"
rm -f "$BIN"
OUT=$(CLAUDE_HOST_START=530 lib 'host_binary_check'); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "under iTerm2, binary gone: silent (the app's grant covers it)" || fail "terminal" "rc=$RC [$OUT]"
OUT=$(CLAUDE_HOST_START=600 lib 'host_binary_check'); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "no claude above: silent" || fail "none" "rc=$RC [$OUT]"
OUT=$(CLAUDE_HOST_BIN="$TMP/none/claude" CLAUDE_HOST_PID=77 lib 'host_binary_check'); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"pid 77, runs from $TMP/none/claude"* ]] && pass "CLAUDE_HOST_BIN seam stands in for the walk" || fail "seam" "rc=$RC [$OUT]"
OUT=$(CLAUDE_HOST_BIN=claude lib 'host_binary_check'); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "a bare comm (Linux ps): nothing to test, silent" || fail "bare comm" "rc=$RC [$OUT]"

echo ""
echo "=== stale_claude_hosts: every claude process whose binary is gone ==="
OUT=$(lib 'stale_claude_hosts')
[ "$OUT" = "$(printf '100\t%s\n200\t%s\n520\t%s' "$BIN" "$BIN" "$TBIN")" ] && pass "three stale, in ps order" || fail "stale list" "[$OUT]"
: > "$BIN"
OUT=$(lib 'stale_claude_hosts')
[ "$OUT" = "$(printf '520\t%s' "$TBIN")" ] && pass "only the one still gone" || fail "stale list after restore" "[$OUT]"
rm -f "$BIN"

echo ""
echo "=== session-start names the host on every start; silent once it exists ==="
ss() { jq -nc --arg s "$1" --arg d "$TMP/repo" '{source:$s, session_id:"sess-host", cwd:$d, hook_event_name:"SessionStart"}' | CLAUDE_HOST_START=400 bash hooks/session-start.sh 2>/dev/null; }
for s in startup resume compact clear; do
  has "$s: names the deleted binary" "pid 100, runs from $BIN" "$(ss "$s")"
done
: > "$BIN"
lacks "binary present: nothing" "binary is gone" "$(ss startup)"
rm -f "$BIN"

echo ""
echo "=== tcc-check: 'Operation not permitted' under a TCC folder names the cause ==="
post() {   # post CWD COMMAND STDERR [TOOL]
  jq -nc --arg d "$1" --arg c "$2" --arg e "$3" --arg t "${4:-Bash}" \
    '{tool_name:$t, hook_event_name:"PostToolUse", tool_input:{command:$c}, tool_response:{stdout:"", stderr:$e, interrupted:false}, cwd:$d, session_id:"sess-host"}' \
    | CLAUDE_HOST_START=400 bash hooks/tcc-check.sh 2>&1 >/dev/null; echo "rc=$?"
}
ERR="fatal: couldn't read $HOME/Desktop/repo/.git/packed-refs: Operation not permitted"
OUT=$(post "$HOME/Desktop/repo" "git status" "$ERR")
has "exit 2, so the text reaches the model" "rc=2" "$OUT"
has "says it is TCC" "macOS privacy control (TCC)" "$OUT"
has "names the host" "pid 100, runs from $BIN" "$OUT"
OUT=$(post "$TMP/repo" "ls ~/Desktop" "ls: $HOME/Desktop: Operation not permitted")
has "cwd elsewhere, but the command names ~/Desktop: still named" "rc=2" "$OUT"
OUT=$(post "$TMP/repo" "ls /opt/x" "ls: /opt/x: Operation not permitted")
[ "$OUT" = "rc=0" ] && pass "not a TCC folder: silent" || fail "elsewhere" "[$OUT]"
OUT=$(post "$HOME/Desktop/repo" "echo 'Operation not permitted'" "")
[ "$OUT" = "rc=0" ] && pass "the words only in the command, not the result: silent" || fail "command text" "[$OUT]"
OUT=$(post "$HOME/Desktop/repo" "x" "$ERR" Read)
[ "$OUT" = "rc=0" ] && pass "not a Bash call: silent" || fail "other tool" "[$OUT]"
OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"ok"},"cwd":"/x"}' | bash hooks/tcc-check.sh 2>&1; echo "rc=$?")
[ "$OUT" = "rc=0" ] && pass "an ordinary result: silent" || fail "ordinary" "[$OUT]"
: > "$BIN"
OUT=$(post "$HOME/Desktop/repo" "git status" "$ERR")
has "binary present: TCC named, the grant itself pointed at" "host binary exists" "$OUT"
lacks "and no deleted-binary line" "binary is gone" "$OUT"
rm -f "$BIN"

echo ""
echo "=== doctor.sh --hosts: lists the stale processes, exit 1; exit 0 when none ==="
OUT=$(bash doctor.sh --hosts 2>&1); RC=$?
[ "$RC" = 1 ] && pass "exit 1 with stale hosts" || fail "exit 1" "rc=$RC"
has "lists pid 100" "pid 100  $BIN" "$OUT"
has "lists pid 520" "pid 520  $TBIN" "$OUT"
: > "$BIN"; : > "$TBIN"
OUT=$(bash doctor.sh --hosts 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"still has its binary"* ]] && pass "every binary present: exit 0" || fail "exit 0" "rc=$RC [$OUT]"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
