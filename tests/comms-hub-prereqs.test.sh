#!/usr/bin/env bash
# Tests for skills/comms-hub/bin/prereqs.sh, what `doctor.sh --skill comms-hub`
# runs: a stranger's first run on a machine with nothing set up must say what
# to do next, line by line. gh and claude are stand-ins on PATH; jq and the
# Python that python.sh picks are real.
set -u
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd)   # macOS TMPDIR ends in /; hub.py prints the path without the //
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$REPO/skills/comms-hub/bin/prereqs.sh"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
export COMMS_HUB_CONFIG="$TMP/config.toml" COMMS_HUB_STATE_DIR="$TMP/state"
# gh: signed in as octocat. claude: `mcp list` prints the file MCP_LIST names.
printf '#!/bin/sh\ncase "$1 $2" in "auth status") exit 0 ;; "api user") echo octocat ;; esac\n' > "$TMP/bin/gh"
printf '#!/bin/sh\ncat "$MCP_LIST" 2>/dev/null\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/gh" "$TMP/bin/claude"
export MCP_LIST="$TMP/mcp.txt"
run() { OUT=$(bash "$P" 2>&1); RC=$?; }

echo "=== no config: says how to make one; the preflight record is expected to be missing ==="
run
[[ $RC == 3 ]] && pass "three failures: config, Slack and preflight" || fail "exit" "rc=$RC $OUT"
[[ "$OUT" == *"FAIL  config"*"hub.py init"*"config.example.toml"* ]] && pass "the config line names hub.py init and the example" || fail "config hint" "$OUT"
[[ "$OUT" == *"FAIL  a Slack MCP server"*"claude mcp add"* ]] && pass "no Slack MCP: says how to add one" || fail "slack hint" "$OUT"
[[ "$OUT" == *"FAIL  session preflight"*"no state dir"* ]] && pass "no state dir without a config" || fail "preflight" "$OUT"

echo ""
echo "=== a filled config, no comms session yet ==="
printf '[github]\nlogin = "octocat"\nowners = ["octocat"]\n[slack]\nprimary_dm = "D0"\nmy_user_id = "U0"\n[quiet_hours]\ntz = "Europe/Berlin"\n' > "$COMMS_HUB_CONFIG"
run
[[ $RC == 2 && "$OUT" == *"ok    config: $COMMS_HUB_CONFIG"* ]] && pass "config ok; Slack and preflight still fail" || fail "filled" "rc=$RC $OUT"
[[ "$OUT" == *"FAIL  session preflight"*"expected until the comms session has run step 0"* ]] \
  && pass "the missing record is called expected, not broken" || fail "expected wording" "$OUT"
printf 'slack-work: npx slack-mcp - ✓ Connected\n' > "$MCP_LIST"
run
[[ "$OUT" == *"ok    Slack MCP: slack-work (connected)"* ]] && pass "a listed, connected Slack server passes" || fail "listed" "$OUT"
printf 'slack-work: npx slack-mcp - ✗ Failed to connect\n' > "$MCP_LIST"
run
[[ "$OUT" == *"FAIL  Slack MCP: slack-work"*"not connected"* ]] && pass "listed but down fails" || fail "down" "$OUT"
rm -f "$MCP_LIST"

echo ""
echo "=== the comms session's record satisfies the Slack check, whatever claude mcp list says ==="
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{checked_at: $t, slack_read_channel: "r", slack_read_thread: "t",
  slack_search: "s", slack_send: "mcp__slack__send", slack_schedule: "sch", list_agents: "ListAgents",
  send_message: "SendMessage", trigger: "7,37 * * * *", tickets: ""}' > "$TMP/state/preflight.json"
run
[[ $RC == 0 ]] && pass "every prerequisite holds" || fail "all ok" "rc=$RC $OUT"
[[ "$OUT" == *"ok    Slack tools: mcp__slack__send and the rest, recorded by the comms session"* ]] \
  && pass "the recorded send tool stands in for the mcp list" || fail "recorded slack" "$OUT"
[[ "$OUT" == *"ok    trigger: 7,37 * * * *"* ]] && pass "the trigger is read from the record" || fail "trigger" "$OUT"
jq 'del(.slack_send)' "$TMP/state/preflight.json" > "$TMP/p.json" && mv "$TMP/p.json" "$TMP/state/preflight.json"
run
[[ $RC == 2 && "$OUT" == *"FAIL  a Slack MCP server"* && "$OUT" == *"FAIL  slack_send"* ]] \
  && pass "no send tool recorded: the mcp list is consulted again, and the key is named" || fail "no send tool" "rc=$RC $OUT"

echo ""
echo "=== gh signed in as someone else ==="
printf '#!/bin/sh\ncase "$1 $2" in "auth status") exit 0 ;; "api user") echo other-account ;; esac\n' > "$TMP/bin/gh"
run
[[ "$OUT" == *"FAIL  gh login matches github.login"*"gh is other-account, the config says octocat"* ]] \
  && pass "names both accounts" || fail "mismatch" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
