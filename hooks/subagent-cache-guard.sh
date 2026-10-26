#!/usr/bin/env bash
# Stops a subagent whose prompt cache keeps expiring under it. A gap longer
# than the subagent TTL (5 minutes by default) between two of its tool calls
# means its next call wrote its whole context to the cache again. After
# CLAUDE_SUBAGENT_MAX_COLD_STARTS of them (5; 0 is off) it denies tool calls
# until the agent replies with where it got to. A resume later than one TTL
# gets through. Main sessions are left alone: their gaps are a person away.
source "$(dirname "$0")/lib.sh"

read_input
[[ "$INPUT" == *'"agent_id"'* ]] || exit 0
AGENT=$(jq_get '.agent_id')
[[ "$AGENT" =~ ^[A-Za-z0-9_.-]{1,80}$ && "$AGENT" != .* ]] || exit 0

MAX=${CLAUDE_SUBAGENT_MAX_COLD_STARTS:-5}
[[ "$MAX" =~ ^[0-9]+$ ]] && (( MAX > 0 )) || exit 0

# The subagent TTL: CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL, else the
# subagentPromptCacheTtl setting, else ENABLE_PROMPT_CACHING_1H; FORCE_PROMPT_CACHING_5M wins.
TTL=${CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL:-}
[[ -n "$TTL" ]] || TTL=$(jq -r '.subagentPromptCacheTtl // empty' "$HOME/.claude/settings.json" 2>/dev/null)
[[ -n "$TTL" || "${ENABLE_PROMPT_CACHING_1H:-}" != 1 ]] || TTL=1h
[[ "${FORCE_PROMPT_CACHING_5M:-}" == 1 ]] && TTL=5m
[[ "$TTL" == 1h ]] && TTL=3600 || TTL=300

DIR=$(expand_tilde "${CLAUDE_SUBAGENT_CACHE_DIR:-$HOME/.claude/state/subagent-cache}")
F="$DIR/$AGENT"
if [[ ! -f "$F" ]]; then
  mkdir -p "$DIR" 2>/dev/null || exit 0
  find "$DIR" -type f -mtime +2 -delete 2>/dev/null   # agents from days ago
fi
NOW=$(date +%s); LAST=0; GAPS=0; STOPPED=0
[[ -f "$F" ]] && read -r LAST GAPS STOPPED < "$F"
[[ "$LAST" =~ ^[0-9]+$ && "$GAPS" =~ ^[0-9]+$ && "$STOPPED" =~ ^[01]$ ]] || { LAST=0; GAPS=0; STOPPED=0; }

COLD=0; (( LAST > 0 && NOW - LAST > TTL )) && COLD=1
if (( STOPPED )); then
  if (( COLD )); then GAPS=0; STOPPED=0; COLD=0; fi   # resumed later, on purpose
else
  GAPS=$((GAPS + COLD))
  (( GAPS >= MAX )) && STOPPED=1
fi
printf '%s %s %s\n' "$NOW" "$GAPS" "$STOPPED" > "$F" 2>/dev/null

if (( STOPPED )); then
  emit_deny "This subagent's prompt cache has expired $GAPS times between its calls (it lives $((TTL / 60)) minutes, and the machine slept or a call stalled past that), and each time its whole context was written to the cache again at the write price. Stop now: reply with what you found and what is left to do, so the work can resume when someone is around. Set CLAUDE_SUBAGENT_MAX_COLD_STARTS to change the limit."
fi
exit 0
