#!/usr/bin/env bash
# Tests for the deleted-host-binary diagnosis: lib.sh's claude_host,
# host_binary_check and stale_claude_hosts on a ps snapshot file
# (CLAUDE_HOST_PS), the session-start call, hooks/tcc-check.sh on Bash output,
# and doctor.sh --hosts. No real TCC denial is needed: the check tests whether
# the host's binary path exists, which is the measured cause.
set -u
PASS=0; FAIL=0
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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
has "and the way out, at the installed path" "~/.claude/relocate-clones.sh" "$OUT"
has "and the all-hosts check, from the installed lib.sh" "source ~/.claude/hooks/lib.sh; stale_claude_hosts" "$OUT"
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
echo "=== tcc-check: an 'Operation not permitted' error under a TCC folder names the cause ==="
hook() {   # hook EVENT CWD STDOUT STDERR [TOOL] [COMMAND]: one payload, shaped as Claude Code sends it
  # (captured from a headless run): a failure's output follows "Exit code N" in
  # .error, stdout then stderr, one line each.
  jq -nc --arg ev "$1" --arg d "$2" --arg o "$3" --arg e "$4" --arg t "${5:-Bash}" --arg c "${6:-x}" \
    '{tool_name:$t, hook_event_name:$ev, tool_input:{command:$c}, cwd:$d, session_id:"sess-host"}
     + if $ev == "PostToolUseFailure" then {error:([("Exit code 1"), $o, $e] | map(select(. != "")) | join("\n"))}
       else {tool_response:{stdout:$o, stderr:$e, interrupted:false}} end' \
    | CLAUDE_HOST_START=400 bash hooks/tcc-check.sh 2>&1 >/dev/null; echo "rc=$?"
}
post() { hook PostToolUse "$1" "" "$2" "${3:-Bash}"; }   # post CWD STDERR [TOOL]
failed() { hook PostToolUseFailure "$1" "" "$2"; }      # failed CWD ERROR
fires() { if [[ "$2" == *rc=2* ]]; then pass "$1"; else fail "$1" "[$2]"; fi; }
silent() { if [ "$2" = "rc=0" ]; then pass "$1"; else fail "$1" "[$2]"; fi; }
P="Operation not permitted"
D="$HOME/Desktop/repo"
GETCWD="shell-init: error retrieving current directory: getcwd: cannot access parent directories: $P"
ERR="fatal: couldn't read $D/.git/packed-refs: $P"
OUT=$(post "$D" "$ERR")
has "exit 2, so the text reaches the model" "rc=2" "$OUT"
has "says it is TCC" "macOS privacy control (TCC)" "$OUT"
has "quotes the line it read" "From: $ERR" "$OUT"
has "names the host" "pid 100, runs from $BIN" "$OUT"
fires "a failed call (PostToolUseFailure), read from .error" "$(failed "$D" "$ERR")"
fires "a call that exited 0, the denial in stdout" "$(hook PostToolUse "$TMP/repo" "ls: $HOME/Documents/x: $P" "")"
fires "cwd elsewhere, the line names a Desktop path" "$(post "$TMP/repo" "ls: $HOME/Desktop: $P")"
fires "zsh's own error, a relative path in a TCC cwd" "$(failed "$D" "(eval):1: operation not permitted: notes.txt")"
fires "python's error names a Downloads path" "$(failed "$TMP/repo" "PermissionError: [Errno 1] $P: '$HOME/Downloads/a.csv'")"
fires "getcwd in a TCC cwd" "$(failed "$D" "$GETCWD")"
fires "iCloud Drive" "$(post "$TMP/repo" "cp: $HOME/Library/Mobile Documents/com~apple~CloudDocs/a: $P")"
fires "from the home folder, a relative Desktop path" "$(post "$HOME" "ls: Desktop: $P")"
fires "node's EPERM" "$(failed "$TMP/repo" "Error: EPERM: operation not permitted, open '$HOME/Desktop/a.txt'")"
fires "Go's lower-case error" "$(failed "$TMP/repo" "open $HOME/Desktop/a: operation not permitted")"
fires "Rust's (os error 1)" "$(failed "$TMP/repo" "rg: $HOME/Desktop/a: Operation not permitted (os error 1)")"
fires "zsh's error with a zsh:1: prefix" "$(failed "$D" "zsh:1: operation not permitted: notes.txt")"
fires "a ~/ path, from elsewhere" "$(post "$TMP/repo" "cp: ~/Desktop/a: Operation not permitted")"
fires "a relative ../Desktop from a home subfolder" "$(post "$HOME/code" "ls: ../Desktop: Operation not permitted")"
fires "a relative protected path beside an absolute one" "$(post "$HOME" "mv: rename Desktop/a to /tmp/a: Operation not permitted")"
fires "a relative name after the command's own cd" \
  "$(hook PostToolUseFailure "$TMP/repo" "" "rm: f: $P" Bash "cd ~/Desktop/repo && rm f")"
fires "both streams of a failure, stdout first" "$(hook PostToolUseFailure "$TMP/repo" "partial" "ls: $HOME/Desktop: $P")"
silent "a relative name after a cd elsewhere" \
  "$(hook PostToolUseFailure "$TMP/repo" "" "rm: f: $P" Bash "cd /opt && rm f")"
silent "grep -n output holding zsh's shape" "$(hook PostToolUse "$D" "notes.md:3:(eval):1: operation not permitted: f" "")"
silent "grep -n output of a log line" "$(hook PostToolUse "$D" "app.log:12:open failed: $P" "")"
silent "prose quoting zsh's error in backticks" "$(hook PostToolUse "$D" "\`(eval):1: operation not permitted: f\` is zsh's form" "")"
silent "a PR body quoting python's error" "$(hook PostToolUse "$D" "  - \`PermissionError: [Errno 1] $P: 'f'\` (python)" "")"
silent "a PR body quoting node's error" "$(hook PostToolUse "$D" "- node's \`EPERM: operation not permitted, open 'f'\`" "")"
silent "getcwd elsewhere" "$(failed "$TMP/repo" "$GETCWD")"
silent "not a TCC folder" "$(post "$TMP/repo" "ls: /opt/x: $P")"
silent "a TCC cwd, but the line names a path outside it" "$(post "$D" "rm: /opt/x: $P")"
silent "a folder that only starts like one" "$(post "$TMP/repo" "ls: $HOME/Desktop2/x: $P")"
silent "grep output quoting the phrase, in a TCC cwd" \
  "$(hook PostToolUse "$D" "hooks/tcc-check.sh:13:case \"\$INPUT\" in *\"$P\"*) ;;" "")"
silent "a test file's quoted error naming a Desktop path" \
  "$(hook PostToolUse "$D" "tests/host-binary.test.sh:118:ERR=\"fatal: couldn't read $D/.git/packed-refs: $P\"" "")"
silent "prose quoting it, in a TCC cwd" "$(hook PostToolUse "$D" "when a Bash result holds \"$P\" and the cwd" "")"
silent "a failure whose output only quotes it" "$(failed "$D" "grep: \"$P\" is quoted here")"
silent "not a Bash call" "$(post "$D" "$ERR" Read)"
OUT=$(jq -nc --arg d "$D" --arg c "true # ls: $D: $P" \
  '{tool_name:"Bash", hook_event_name:"PostToolUse", tool_input:{command:$c}, tool_response:{stdout:"ok", stderr:""}, cwd:$d}' \
  | bash hooks/tcc-check.sh 2>&1; echo "rc=$?")
silent "the words only in the command, not the result" "$OUT"
OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"ok"},"cwd":"/x"}' | bash hooks/tcc-check.sh 2>&1; echo "rc=$?")
silent "an ordinary result" "$OUT"
REG=$(jq -r '.hooks | to_entries[] | .key as $e | .value[] | select(.matcher == "Bash")
             | .hooks[] | select(.command | endswith("/tcc-check.sh")) | $e' config/settings.json | sort | tr '\n' ' ')
[ "$REG" = "PostToolUse PostToolUseFailure " ] && pass "settings.json runs it after Bash calls that pass and that fail" \
  || fail "settings.json runs it after Bash calls that pass and that fail" "[$REG]"
: > "$BIN"
OUT=$(post "$D" "$ERR")
has "binary present: TCC named, the grant itself pointed at" "host binary exists" "$OUT"
has "and the installed relocate tool" "~/.claude/relocate-clones.sh" "$OUT"
# The quoted line is cut at 300 bytes, whole characters only, whatever the locale.
# Two lines a byte apart, so one of them puts byte 300 inside a two-byte é.
for tool in ls lsx; do
  LONG="$tool: $HOME/Desktop/$(printf 'é%.0s' $(seq 1 200)): $P"
  OUT=$(jq -nc --arg d "$D" --arg e "$LONG" '{tool_name:"Bash", hook_event_name:"PostToolUse", tool_input:{command:"x"}, tool_response:{stdout:$e, stderr:""}, cwd:$d}' \
    | LC_ALL=C CLAUDE_HOST_START=400 bash hooks/tcc-check.sh 2>&1 >/dev/null)
  printf '%s' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && pass "the quoted line stays valid UTF-8 in the C locale ($tool)" \
    || fail "the quoted line in the C locale ($tool)" "cut mid-character"
done
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
