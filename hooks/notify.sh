#!/usr/bin/env bash
# Desktop notification when Claude needs input.
source "$(dirname "$0")/lib.sh"

if command -v osascript &>/dev/null; then
  osascript -e 'display notification "Claude needs your attention" with title "Claude Code"' 2>/dev/null || true
elif command -v notify-send &>/dev/null; then
  notify-send "Claude Code" "Claude needs your attention" 2>/dev/null || true
fi
