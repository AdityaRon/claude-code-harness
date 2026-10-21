#!/usr/bin/env bash
# comms-hub prerequisites; exit status is the number that failed. Run it as
# `bash doctor.sh --skill comms-hub` or from ~/.claude/skills/comms-hub/bin.
# Only the comms session can see its tools and its /loop trigger, so those come
# from the record it writes at step 0 (<state_dir>/preflight.json), with its age.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILS=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; echo "        $2"; FAILS=$((FAILS + 1)); }
note() { echo "  --    $1"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

echo "comms-hub prerequisites"

if command -v jq >/dev/null 2>&1; then ok "jq ($(jq --version))"
else bad "jq" "install it: brew install jq (macOS), apt-get install jq or dnf install jq (Linux)"; fi

if PY=$(bash "$HERE/python.sh" 2>/dev/null); then
  ok "python: $PY ($("$PY" -c 'import platform; print(platform.python_version())'))"
else
  bad "python 3.10+ with tomllib or tomli" "$(bash "$HERE/python.sh" 2>&1 >/dev/null)"
  PY=""
fi

GH_LOGIN=""
if ! command -v gh >/dev/null 2>&1; then bad "gh" "install the GitHub CLI: brew install gh (macOS), or https://cli.github.com (Linux packages)"
elif ! gh auth status >/dev/null 2>&1; then bad "gh authenticated" "run: gh auth login (as the account the config's github.login names)"
else
  GH_LOGIN=$(gh api user --jq .login 2>/dev/null)
  ok "gh authenticated as ${GH_LOGIN:-an account gh api user did not name}"
fi

STATE=""
if [[ -n "$PY" ]]; then
  CONF=$("$PY" "$HERE/hub.py" config 2>&1)
  if [[ $? -eq 0 ]]; then
    ok "$(printf '%s\n' "$CONF" | head -1)"
    STATE=$(printf '%s\n' "$CONF" | sed -n 's/^state: //p')
    CFG_LOGIN=$(printf '%s\n' "$CONF" | sed -nE 's/^login: ([^ ]+).*/\1/p')
    if [[ -n "$GH_LOGIN" && "$(lower "$CFG_LOGIN")" != "$(lower "$GH_LOGIN")" ]]; then
      bad "gh login matches github.login" "gh is $GH_LOGIN, the config says $CFG_LOGIN; queue.py blocks on that"
    fi
  else
    bad "config" "$CONF"
  fi
fi

# The session's record names the Slack tools it loaded, and a connector added
# in /mcp need not appear in `claude mcp list`; the list is the fallback.
REC="$STATE/preflight.json"
SLACK_REC=""
if [[ -n "$STATE" && -f "$REC" ]]; then SLACK_REC=$(jq -r '.slack_send // empty' "$REC" 2>/dev/null); fi
MCP=""
if command -v claude >/dev/null 2>&1; then
  # macOS has no timeout(1); claude mcp list health-checks every server.
  MCP=$(perl -e 'alarm shift; exec @ARGV' 60 claude mcp list 2>/dev/null)
fi
SLACK=$(printf '%s\n' "$MCP" | grep -i 'slack' | head -1)
if [[ -n "$SLACK_REC" ]]; then
  ok "Slack tools: $SLACK_REC and the rest, recorded by the comms session at step 0"
elif ! command -v claude >/dev/null 2>&1; then
  bad "claude CLI" "not on PATH, so the MCP servers cannot be listed"
elif [[ -z "$SLACK" ]]; then
  bad "a Slack MCP server" "none in \`claude mcp list\` with slack in its name: add one (\`claude mcp add\`, or the Slack connector in /mcp) that reads a channel and a thread, searches, sends and schedules"
elif printf '%s' "$SLACK" | grep -q 'Connected'; then
  ok "Slack MCP: ${SLACK%%:*} (connected)"
else
  bad "Slack MCP: ${SLACK%%:*}" "listed, not connected: ${SLACK##* - }"
fi
TICKETS=$(printf '%s\n' "$MCP" | grep -iE 'jira|confluence|atlassian' | head -1)
if [[ -n "$TICKETS" ]]; then ok "optional ticket or page MCP: ${TICKETS%%:*}"
else note "optional: no Jira or Confluence MCP, so claims citing a ticket or page are checked by hand"; fi

if [[ -f ~/.claude/settings.json ]] && jq -e '[.permissions.deny[]? | select(test("^(SendMessage|ListAgents)(\\(|$)"))] | length > 0' \
     ~/.claude/settings.json >/dev/null 2>&1; then
  bad "SendMessage and ListAgents allowed" "permissions.deny in ~/.claude/settings.json names one, so peers cannot hand drafts over"
else
  ok "SendMessage and ListAgents not in ~/.claude/settings.json permissions.deny"
fi

if [[ -z "$STATE" ]]; then
  bad "session preflight" "no state dir, since the config check failed"
elif [[ ! -f "$REC" ]]; then
  bad "session preflight" "no record at $REC: expected until the comms session has run step 0 of the skill once; the rest above can be fixed first"
elif ! AGE=$(jq -er '(now - (.checked_at | fromdateiso8601)) / 3600 | floor' "$REC" 2>/dev/null); then
  bad "session preflight" "$REC has no checked_at in the form 2026-10-21T17:00:00Z"
else
  for k in slack_read_channel slack_read_thread slack_search slack_send slack_schedule list_agents send_message trigger; do
    v=$(jq -r --arg k "$k" '.[$k] // empty' "$REC")
    if [[ -n "$v" ]]; then ok "$k: $v (recorded by the comms session ${AGE}h ago)"
    else bad "$k" "missing from $REC: the comms session did not find it at step 0"; fi
  done
  [[ "$AGE" -le 168 ]] || bad "session preflight is ${AGE}h old" "rerun step 0 in the comms session; tools come and go"
fi

echo ""
if [[ $FAILS -eq 0 ]]; then echo "comms-hub: every prerequisite holds"
else echo "comms-hub: $FAILS prerequisite(s) failed"; fi
exit "$FAILS"
