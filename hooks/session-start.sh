#!/usr/bin/env bash
# Injects current git state as context at session start.
# Stdout from SessionStart hooks is added directly to Claude's context window —
# no prompt needed. Claude starts every session already knowing where it is.
#
# On source=resume, also diffs against the snapshot written by
# session-snapshot.sh at the prior session's Stop: if the files the prior
# session edited no longer match their recorded hashes, surface that drift so
# Claude re-verifies before trusting the transcript's narrative.
source "$(dirname "$0")/lib.sh"

read_input
SOURCE=$(jq_get '.source')
SESSION_ID=$(jq_get '.session_id')

# Silently exit if not inside a git repo
if git rev-parse --git-dir &>/dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "detached HEAD")
  DIRTY=$(git status --short 2>/dev/null | head -10)
  COMMITS=$(git log --oneline -5 2>/dev/null)
  STASHES=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

  echo "## Git context"
  echo "Branch: $BRANCH"

  if [[ -n "$DIRTY" ]]; then
    echo "Uncommitted changes:"
    echo "$DIRTY"
  else
    echo "Working tree: clean"
  fi

  echo ""
  echo "Recent commits:"
  echo "$COMMITS"

  if [[ "$STASHES" -gt 0 ]]; then
    echo ""
    echo "Stashes: $STASHES stash(es) present"
  fi
fi

# Resume-drift detection. Only meaningful for source=resume, and only when
# jq and a prior snapshot both exist.
[[ "$SOURCE" != "resume" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0
command -v jq &>/dev/null || exit 0

STATE_DIR=$(expand_tilde "${CLAUDE_STATE_DIR:-$HOME/.claude/state/sessions}")
SNAP="$STATE_DIR/${SESSION_ID}.json"
[[ ! -f "$SNAP" ]] && exit 0

# Compare HEAD.
SNAP_HEAD=$(jq -r '.git_head // ""' "$SNAP" 2>/dev/null)
CUR_HEAD=""
git rev-parse --git-dir &>/dev/null 2>&1 && CUR_HEAD=$(git rev-parse HEAD 2>/dev/null)

# Walk edited_files, classify each.
DRIFT_LINES=()
TOTAL=0
while IFS=$'\t' read -r path expected_hash expected_exists; do
  [[ -z "$path" ]] && continue
  TOTAL=$((TOTAL + 1))
  if [[ ! -f "$path" ]]; then
    if [[ "$expected_exists" == "true" ]]; then
      DRIFT_LINES+=("missing: $path")
    fi
    continue
  fi
  actual_hash=$(sha256_file "$path")
  if [[ -n "$expected_hash" && "$actual_hash" != "$expected_hash" ]]; then
    DRIFT_LINES+=("drifted: $path")
  fi
done < <(jq -r '.edited_files[]? | [.path, .sha256, (.exists|tostring)] | @tsv' "$SNAP" 2>/dev/null)

HEAD_CHANGED=0
if [[ -n "$SNAP_HEAD" && -n "$CUR_HEAD" && "$SNAP_HEAD" != "$CUR_HEAD" ]]; then
  HEAD_CHANGED=1
fi

echo ""
if [[ ${#DRIFT_LINES[@]} -eq 0 && "$HEAD_CHANGED" -eq 0 ]]; then
  echo "Resume drift: none ($TOTAL file(s) checked against prior-session snapshot)"
  exit 0
fi

echo "## Resume drift detected"
echo "The prior session recorded edits to the files below, but the current"
echo "on-disk state no longer matches. Re-verify before trusting conclusions"
echo "from prior-session tool results."
echo ""

if [[ "$HEAD_CHANGED" -eq 1 ]]; then
  echo "HEAD changed: ${SNAP_HEAD:0:12} → ${CUR_HEAD:0:12}"
fi

MAX=20
COUNT=${#DRIFT_LINES[@]}
if [[ "$COUNT" -le "$MAX" ]]; then
  for line in "${DRIFT_LINES[@]}"; do
    echo "$line"
  done
else
  for ((i=0; i<MAX; i++)); do
    echo "${DRIFT_LINES[$i]}"
  done
  echo "... and $((COUNT - MAX)) more"
fi
