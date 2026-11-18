#!/usr/bin/env bash
# Backs up the session transcript before compaction (auto or manual).
# Keeps one copy per session (the largest), the 20 most recent within
# CLAUDE_TRANSCRIPT_BACKUP_MAX_MB (1000; 0 for no cap), and none older than
# Claude Code keeps transcripts itself (cleanupPeriodDays, default 30).
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

# Newest first, sizes from one wc. A session's earlier copies are byte prefixes of
# its later ones (measured, Claude Code 2.1.327), so one no larger than this copy
# goes; a larger one (a truncated source) stays. Then 20 within the cap, newest kept.
CAP=${CLAUDE_TRANSCRIPT_BACKUP_MAX_MB:-1000}; [[ "$CAP" =~ ^[0-9]{1,7}$ ]] || CAP=1000
FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(ls -t "$BACKUP_DIR"/transcript_*.jsonl 2>/dev/null)
NAMES=() SIZES=() NEW=-1
if (( ${#FILES[@]} > 0 )); then
  while read -r sz name; do
    [[ "$sz" =~ ^[0-9]+$ && -n "$name" && "$name" != total ]] || continue
    NAMES+=("$name"); SIZES+=("$sz"); [[ "$name" == "$OUT" ]] && NEW=$sz
  done < <(wc -c -- "${FILES[@]}" 2>/dev/null)
fi
DEL=() KEPT=0 TOTAL=0
for k in "${!NAMES[@]}"; do
  n=${NAMES[$k]} s=${SIZES[$k]}
  if [[ -n "$SID" && "$n" != "$OUT" && "${n##*/}" == transcript_*_"$SID".jsonl ]] && (( NEW >= 0 && s <= NEW )); then
    DEL+=("$n"); continue
  fi
  KEPT=$((KEPT + 1)) TOTAL=$((TOTAL + s))
  (( KEPT > 1 && ( KEPT > 20 || ( CAP > 0 && TOTAL > CAP * 1000000 ) ) )) && DEL+=("$n")
done
(( ${#DEL[@]} == 0 )) || rm -f -- "${DEL[@]}" 2>/dev/null || true
# And none the CLI has already let go of.
DAYS=$(jq -r '.cleanupPeriodDays // 30' "$(expand_tilde "${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}")" 2>/dev/null)
[[ "$DAYS" =~ ^[0-9]+$ ]] || DAYS=30
find "$BACKUP_DIR" -maxdepth 1 -name 'transcript_*.jsonl' -mtime +"$DAYS" -exec rm -f {} + 2>/dev/null || true
