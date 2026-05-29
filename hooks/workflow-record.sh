#!/usr/bin/env bash
# PostToolUse → Workflow: make a workflow run's persisted .js script easy to find.
# Discoverability only (no rendering): logs the script path to the audit log and
# records a per-session pointer the statusline links to. Open it in your editor.
# Side-effect only; registered async.
source "$(dirname "$0")/lib.sh"

read_input
tool=$(jq_get '.tool_name')
[[ "$tool" == "Workflow" ]] || exit 0

# The Workflow tool returns the persisted script path in its result. Take the
# first .js path found anywhere in tool_response (robust to the exact field name).
script=$(printf '%s' "$INPUT" | jq -r 'first(.tool_response | .. | strings | select(endswith(".js"))) // empty' 2>/dev/null)

# Fallback: newest workflow script under any project's session dir.
if [[ -z "$script" || ! -f "$script" ]]; then
  script=$(ls -1t "$HOME"/.claude/projects/*/*/workflows/scripts/*.js 2>/dev/null | head -1)
fi
[[ -n "$script" && -f "$script" ]] || exit 0

# Audit-log it (shared rotation/perms via log_audit).
log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) | workflow | $script | $(pwd)"

# Per-session pointer for the statusline (mirrors the plan pointer).
sid=$(jq_get '.session_id')
if [[ -n "$sid" ]]; then
  pdir=$(expand_tilde "${CLAUDE_WORKFLOW_STATE_DIR:-$HOME/.claude/state/workflows}")
  if mkdir -p "$pdir" 2>/dev/null; then
    printf '%s\n' "$script" > "$pdir/$sid.path" 2>/dev/null || true
    chmod 600 "$pdir/$sid.path" 2>/dev/null || true
  fi
fi
exit 0
