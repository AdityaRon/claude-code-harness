#!/usr/bin/env bash
# Turn Claude Code's OS sandbox on or off on this machine: sandbox.enabled in
# ~/.claude/settings.json, which every install keeps. Start a new session after.
#   sandbox.sh on | off | status
set -uo pipefail
S="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

usage() { sed -n '2,4s/^# \{0,1\}//p' "$0"; exit 2; }

managed_file() {
  local f
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" /etc/claude-code/managed-settings.json; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

status() {
  [[ -f "$S" ]] || { echo "no $S: run install.sh first"; return 1; }
  jq -r '"sandbox:           \(if .sandbox.enabled == true then "on" else "off" end)",
         "fail if missing:   \(.sandbox.failIfUnavailable // false)",
         "excluded commands: \((.sandbox.excludedCommands // []) | join(", "))",
         "allowed domains:   \((.sandbox.network.allowedDomains // []) | length)",
         "extra write paths: \((.sandbox.filesystem.allowWrite // []) | join(", "))"' "$S"
  local m
  if m=$(managed_file); then
    echo "managed settings:  $m (its sandbox values win over yours: $(jq -c '.sandbox // "none"' "$m" 2>/dev/null || echo unreadable))"
  fi
}

set_to() {
  [[ -f "$S" ]] || { echo "no $S: run install.sh first"; return 1; }
  jq -e . "$S" >/dev/null 2>&1 || { echo "$S is not JSON; nothing changed"; return 1; }
  cp "$S" "$S.bak.$(date +%Y%m%d%H%M%S)"
  jq --argjson v "$1" '.sandbox.enabled = $v' "$S" > "$S.part.$$" && mv -f "$S.part.$$" "$S" \
    || { rm -f "$S.part.$$"; echo "write failed; nothing changed"; return 1; }
  status
  echo "Start a new Claude Code session for this to apply everywhere."
}

case "${1:-}" in
  on)     set_to true ;;
  off)    set_to false ;;
  status) status ;;
  *)      usage ;;
esac
