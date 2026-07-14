#!/usr/bin/env bash
# Backs up the session transcript before compaction (auto or manual).
# Keeps the 20 most recent backups and prunes the rest.
source "$(dirname "$0")/lib.sh"

read_input
TRANSCRIPT=$(jq_get '.transcript_path')
TRIGGER=$(jq_get '.trigger')
[[ -z "$TRIGGER" ]] && TRIGGER="unknown"

[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

BACKUP_DIR=$(expand_tilde "${CLAUDE_TRANSCRIPT_DIR:-$HOME/.claude/transcripts}")
mkdir -p "$BACKUP_DIR" 2>/dev/null || exit 0

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp "$TRANSCRIPT" "$BACKUP_DIR/transcript_${TRIGGER}_${TIMESTAMP}.jsonl" 2>/dev/null || exit 0

# Keep the 20 most recent; remove the rest
ls -t "$BACKUP_DIR"/transcript_*.jsonl 2>/dev/null \
  | tail -n +21 \
  | xargs rm -f 2>/dev/null || true
