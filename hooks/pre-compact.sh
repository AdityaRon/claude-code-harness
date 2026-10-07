#!/usr/bin/env bash
# Backs up the session transcript before compaction (auto or manual).
# Keeps the 20 most recent backups, and none older than Claude Code keeps
# transcripts itself (cleanupPeriodDays, default 30).
source "$(dirname "$0")/lib.sh"

read_input
TRANSCRIPT=$(jq_get '.transcript_path')
TRIGGER=$(jq_get '.trigger')
SID=$(jq_get '.session_id')
# Both land in a file name: keep "auto"/"manual" and the id's characters, never a "/" or "..".
TRIGGER=${TRIGGER//[^A-Za-z0-9_-]/}
[[ -z "$TRIGGER" ]] && TRIGGER="unknown"
SID=${SID//[^A-Za-z0-9-]/}; SID=${SID:0:8}

[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

BACKUP_DIR=$(expand_tilde "${CLAUDE_TRANSCRIPT_DIR:-$HOME/.claude/transcripts}")
mkdir -p "$BACKUP_DIR" 2>/dev/null || exit 0

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# The session id keeps two compactions in the same second from overwriting each other.
OUT="$BACKUP_DIR/transcript_${TRIGGER}_${TIMESTAMP}${SID:+_$SID}.jsonl"
# The whole conversation: private whatever mode the source had.
(umask 077; cp "$TRANSCRIPT" "$OUT") 2>/dev/null || exit 0
chmod 600 "$OUT" 2>/dev/null || true

# Keep the 20 most recent; remove the rest
ls -t "$BACKUP_DIR"/transcript_*.jsonl 2>/dev/null \
  | tail -n +21 \
  | xargs rm -f 2>/dev/null || true
# And none the CLI has already let go of.
DAYS=$(jq -r '.cleanupPeriodDays // 30' "$(expand_tilde "${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}")" 2>/dev/null)
[[ "$DAYS" =~ ^[0-9]+$ ]] || DAYS=30
find "$BACKUP_DIR" -maxdepth 1 -name 'transcript_*.jsonl' -mtime +"$DAYS" -exec rm -f {} + 2>/dev/null || true
