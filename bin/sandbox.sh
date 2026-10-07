#!/usr/bin/env bash
# Turn Claude Code's OS sandbox on or off on this machine: sandbox.enabled in
# ~/.claude/settings.json, which every install keeps. Running sessions use it from
# their next command. Run it yourself: a sandboxed command cannot write settings.
#   sandbox.sh on | off | status
set -uo pipefail
S="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

usage() { sed -n '2,5s/^# \{0,1\}//p' "$0"; exit 2; }

managed_file() {
  local f
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" /etc/claude-code/managed-settings.json; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

status() {
  [[ -f "$S" ]] || { echo "no $S: run install.sh first"; return 1; }
  jq -r --arg home "$HOME" '"sandbox:           \(if .sandbox.enabled == true then "on" else "off" end)",
         "fail if missing:   \(.sandbox.failIfUnavailable // false)",
         "excluded commands: \((.sandbox.excludedCommands // []) | join(", "))",
         "allowed domains:   \((.sandbox.network.allowedDomains // []) | length)",
         "local binding:     \(.sandbox.network.allowLocalBinding // false)",
         "denied reads:      \((.sandbox.filesystem.denyRead // []) | join(", "))",
         "extra write paths: \((.sandbox.filesystem.allowWrite // [])
           | map(if startswith("~/.claude") or startswith($home + "/.claude")
                 then . + " (no effect: Claude Code keeps ~/.claude read-only to commands)" else . end)
           | join(", "))"' "$S"
  local m
  if m=$(managed_file); then
    echo "managed settings:  $m (its sandbox values win over yours: $(jq -c '.sandbox // "none"' "$m" 2>/dev/null || echo unreadable))"
  fi
}

set_to() {
  [[ -f "$S" ]] || { echo "no $S: run install.sh first"; return 1; }
  jq -e . "$S" >/dev/null 2>&1 || { echo "$S is not JSON; nothing changed"; return 1; }
  cp "$S" "$S.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null \
    || { echo "cannot write next to $S; nothing changed. Under the sandbox, run it with ! as the first character of a message, or in a terminal."; return 1; }
  jq --argjson v "$1" '.sandbox.enabled = $v' "$S" > "$S.part.$$" && mv -f "$S.part.$$" "$S" \
    || { rm -f "$S.part.$$"; echo "write failed; nothing changed"; return 1; }
  status
  echo "Running sessions use this from their next command."
}

case "${1:-}" in
  on)     set_to true ;;
  off)    set_to false ;;
  status) status ;;
  *)      usage ;;
esac
