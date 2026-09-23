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

# --- keep the memory index in tier order ------------------------------------
# MEMORY.md is truncated tail-first at its line cap, and the memory writer
# appends every new entry at the END of the file regardless of type. So ordering
# decays on ordinary use, and what decays off the bottom is whatever was written
# most recently -- including `feedback_` entries, which do nothing unless they
# are loaded. Measured on a live store: it fell out of tier order twice in
# twenty hours, purely from other sessions appending.
#
# memory-lint.sh already REPORTS this, but only when a session happens to write
# a memory, and only to the session that wrote it. Session start is the one
# moment the ordering matters to everybody, and the fix is a pure permutation --
# memory-index.sh refuses to write at all unless the set of entry lines is
# unchanged -- so doing it rather than reporting it is safe here. No
# --archive-overflow: dropping entries is a judgement call and stays manual.
PROJECTS_DIR=$(expand_tilde "${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}")
LAUNCH_DIR=$(jq_get '.cwd')
[[ -z "$LAUNCH_DIR" ]] && LAUNCH_DIR="$PWD"
# Memory is siloed per launch directory, and the store slug is that path with
# every separator turned into a dash. Reorder only THIS session's store: the
# others are not being loaded here, and touching them would surprise whichever
# session owns them.
STORE_SLUG=$(printf '%s' "$LAUNCH_DIR" | tr '/' '-')
INDEX_TOOL=""
for cand in "$(dirname "$0")/../memory-index.sh" "$(dirname "$0")/../bin/memory-index.sh"; do
  [[ -f "$cand" ]] && INDEX_TOOL="$cand" && break
done
if [[ -n "$INDEX_TOOL" && -f "$PROJECTS_DIR/$STORE_SLUG/memory/MEMORY.md" ]]; then
  ORDER_OUT=$(CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" \
    bash "$INDEX_TOOL" --store "$STORE_SLUG" --write 2>/dev/null \
    | grep ': reordered' || true)
  # Silent when it was already ordered, which is the common case.
  if [[ -n "$ORDER_OUT" ]]; then
    echo ""
    echo "## Memory index reordered"
    echo "$ORDER_OUT"
    echo "Entries had drifted out of tier order and were restored to ACTIVE → feedback → reference → project (newest first within reference and project). Nothing was added, removed or edited."
  fi
fi

# --- CLI ahead of the harness contract --------------------------------------
# install.sh records the release the contract was verified at. `claude --version`
# measured 0.07s here, cheap enough to run on every start.
PIN_FILE=$(expand_tilde "${CLAUDE_CONTRACT_PIN:-$HOME/.claude/harness-contract.version}")
if [[ -f "$PIN_FILE" ]]; then
  PIN=$(head -1 "$PIN_FILE")
  CLI=${CLAUDE_CLI_VERSION:-$(claude --version 2>/dev/null | cut -d' ' -f1)}
  if [[ -n "$PIN" && -n "$CLI" && "$CLI" != "$PIN" ]]; then
    echo ""
    echo "## Claude Code is past the harness contract"
    echo "Installed $CLI; the harness was verified at $PIN. The daily Upstream drift workflow drafts the review PR. After it merges, run bash install.sh."
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
