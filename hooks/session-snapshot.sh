#!/usr/bin/env bash
# On Stop, record which files this session edited and their final content
# hashes. session-start.sh reads this back on resume to detect drift between
# what the prior session landed on disk and what's actually there now —
# catches the "edits were reverted / never persisted" failure mode.
source "$(dirname "$0")/lib.sh"

read_input
SESSION_ID=$(jq_get '.session_id')
TRANSCRIPT=$(jq_get '.transcript_path')
CWD=$(jq_get '.cwd')
[[ -z "$CWD" ]] && CWD=$(pwd)

# No session id or no transcript → nothing useful to snapshot.
[[ -z "$SESSION_ID" || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0
command -v jq &>/dev/null || exit 0

STATE_DIR=$(expand_tilde "${CLAUDE_STATE_DIR:-$HOME/.claude/state/sessions}")
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Collect the set of file paths that were successfully Edit/Write/MultiEdit'd.
# Transcript entries are JSONL; each line may be a user/assistant/tool message.
# Tool invocations live in assistant messages as content blocks with type
# "tool_use"; we take the last write to each path.
FILES_JSON=$(jq -rcs '
  [ .[]
    | select(.message? // {} | type == "object")
    | (.message.content? // [])[]?
    | select(.type? == "tool_use")
    | select(.name? == "Edit" or .name? == "Write" or .name? == "MultiEdit" or .name? == "NotebookEdit")
    | (.input.file_path? // .input.path? // empty)
  ] | unique' "$TRANSCRIPT" 2>/dev/null)
[[ -z "$FILES_JSON" ]] && FILES_JSON='[]'

# Build the edited_files array: resolve each path to absolute, hash contents.
TMP=$(mktemp 2>/dev/null) || exit 0
printf '[' > "$TMP"
FIRST=1
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  # Resolve relative paths against the session cwd.
  if [[ "$path" != /* ]]; then
    path="$CWD/$path"
  fi
  hash=""
  exists=false
  if [[ -f "$path" ]]; then
    exists=true
    hash=$(sha256_file "$path")
  fi
  if [[ "$FIRST" -eq 1 ]]; then
    FIRST=0
  else
    printf ',' >> "$TMP"
  fi
  jq -nc --arg p "$path" --arg h "$hash" --argjson e "$exists" \
    '{path:$p, sha256:$h, exists:$e}' >> "$TMP"
done < <(printf '%s' "$FILES_JSON" | jq -r '.[]?' 2>/dev/null)
printf ']' >> "$TMP"
EDITED_FILES_JSON=$(cat "$TMP")
rm -f "$TMP"

# Git state — best-effort; empty strings when not in a repo.
GIT_HEAD=""
GIT_DIRTY_JSON='[]'
if (cd "$CWD" && git rev-parse --git-dir &>/dev/null); then
  GIT_HEAD=$(cd "$CWD" && git rev-parse HEAD 2>/dev/null)
  GIT_DIRTY_JSON=$(cd "$CWD" && git status --porcelain 2>/dev/null \
    | jq -Rcs 'split("\n") | map(select(length > 0))')
  [[ -z "$GIT_DIRTY_JSON" ]] && GIT_DIRTY_JSON='[]'
fi

OUT="$STATE_DIR/${SESSION_ID}.json"
jq -n \
  --arg sid "$SESSION_ID" \
  --arg ts "$TS" \
  --arg cwd "$CWD" \
  --arg head "$GIT_HEAD" \
  --argjson dirty "$GIT_DIRTY_JSON" \
  --argjson edited "$EDITED_FILES_JSON" \
  '{session_id:$sid, ended_at:$ts, cwd:$cwd, git_head:$head, git_dirty:$dirty, edited_files:$edited}' \
  > "$OUT" 2>/dev/null || exit 0
chmod 600 "$OUT" 2>/dev/null || true

# Prune to newest 50 snapshots.
ls -t "$STATE_DIR"/*.json 2>/dev/null \
  | tail -n +51 \
  | xargs rm -f 2>/dev/null || true

exit 0
