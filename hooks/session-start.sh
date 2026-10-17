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

# Skipped on startup: the CLI's own system prompt already carries branch,
# main branch, status and `git log --oneline -n 5` (its gitStatus block), so
# this was a second copy. On resume/compact/clear that snapshot may be stale.
if [[ "$SOURCE" != "startup" ]] && git rev-parse --git-dir &>/dev/null 2>&1; then
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
# every non-alphanumeric turned into a dash, as the CLI does. A path over 200
# characters also gets a hash suffix; that store is not found and is skipped.
# Reorder only THIS session's store: the others are not being loaded here, and
# touching them would surprise whichever session owns them.
STORE_SLUG=$(printf '%s' "$LAUNCH_DIR" | sed 's/[^A-Za-z0-9]/-/g')
INDEX_TOOL=""
for cand in "$(dirname "$0")/../memory-index.sh" "$(dirname "$0")/../bin/memory-index.sh"; do
  [[ -f "$cand" ]] && INDEX_TOOL="$cand" && break
done
# Silent: a pure permutation leaves the model nothing to act on.
if [[ -n "$INDEX_TOOL" && -f "$PROJECTS_DIR/$STORE_SLUG/memory/MEMORY.md" ]]; then
  CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" \
    bash "$INDEX_TOOL" --store "$STORE_SLUG" --write >/dev/null 2>&1 || true
fi

# --- worktree records whose folder is gone ------------------------------------
# A session's scratch worktree goes when its job folder does, but the repo keeps
# the record, and the branch stays checked out there: it cannot be deleted or
# checked out again. Prune the launch repo and the repos one level under it.
# Reading the records forks nothing; git runs only when one is stale, detached.
for g in "$LAUNCH_DIR/.git" "$LAUNCH_DIR"/*/.git; do
  [[ -d "$g/worktrees" ]] || continue
  for f in "$g"/worktrees/*/gitdir; do
    [[ -f "$f" ]] || continue
    IFS= read -r wt < "$f" || continue
    if [[ ! -e "$wt" ]]; then
      (git --git-dir="$g" worktree prune >/dev/null 2>&1 &)
      break
    fi
  done
done

STATE_DIR=$(expand_tilde "${CLAUDE_STATE_DIR:-$HOME/.claude/state/sessions}")

# --- CLI ahead of the harness contract --------------------------------------
# install.sh records the release the contract was verified at. `claude --version`
# measured 0.07s here, cheap enough to run on every start. The nudge is shown
# once per CLI version per day, stamped in STATE_DIR: nothing the reader can do
# changes between sessions, and it fired in every session in every repo.
PIN_FILE=$(expand_tilde "${CLAUDE_CONTRACT_PIN:-$HOME/.claude/harness-contract.version}")
if [[ -f "$PIN_FILE" ]]; then
  PIN=$(head -1 "$PIN_FILE")
  CLI=${CLAUDE_CLI_VERSION:-$(claude --version 2>/dev/null | cut -d' ' -f1)}
  if [[ -n "$PIN" && -n "$CLI" && "$CLI" != "$PIN" ]]; then
    STAMP_FILE="$STATE_DIR/contract-nudge"
    STAMP="$CLI $(date +%Y-%m-%d)"
    if [[ ! -f "$STAMP_FILE" || "$(head -1 "$STAMP_FILE" 2>/dev/null)" != "$STAMP" ]]; then
      echo ""
      # An older CLI is behind, not past: the review already merged, and settings
      # it added (onFailure needs 2.1.295) are ignored until Claude Code updates.
      if [[ "$(printf '%s\n%s\n' "$CLI" "$PIN" | sort -V | head -1)" == "$CLI" ]]; then
        echo "## Claude Code is older than the harness contract"
        echo "Installed $CLI; the harness was verified at $PIN, so settings added since may be ignored. Update Claude Code."
      else
        echo "## Claude Code is past the harness contract"
        echo "Installed $CLI; the harness was verified at $PIN. The daily Upstream drift run lands the review and the release that follows; the scheduled harness-update installs it. If this persists for more than a day, see the Release blocked issue."
      fi
      mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$STAMP" > "$STAMP_FILE" 2>/dev/null
    fi
  fi
fi

# --- a newer harness release ------------------------------------------------
# harness-update.sh writes the newest tag it fetched; nothing here touches the
# network. Only a machine installed from a plain tag is nudged: a clone past
# the tag is being worked on.
LATEST_FILE=$(expand_tilde "${CLAUDE_HARNESS_LATEST:-$HOME/.claude/state/harness-latest}")
VERSION_FILE=$(expand_tilde "${CLAUDE_HARNESS_VERSION:-$HOME/.claude/harness.version}")
if [[ -f "$LATEST_FILE" && -f "$VERSION_FILE" ]]; then
  LATEST=$(head -1 "$LATEST_FILE" | cut -d' ' -f1)
  INSTALLED=$(sed -n 's/^version=//p' "$VERSION_FILE" | head -1)
  SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'
  if [[ "$LATEST" =~ $SEMVER && "$INSTALLED" =~ $SEMVER && "$LATEST" != "$INSTALLED" \
        && "$(printf '%s\n%s\n' "$LATEST" "$INSTALLED" | sort -V | tail -1)" == "$LATEST" ]]; then
    STAMP_FILE="$STATE_DIR/release-nudge"
    STAMP="$LATEST $(date +%Y-%m-%d)"
    if [[ ! -f "$STAMP_FILE" || "$(head -1 "$STAMP_FILE" 2>/dev/null)" != "$STAMP" ]]; then
      echo ""
      echo "## Harness $LATEST is available; $INSTALLED is installed. Run ~/.claude/harness-update.sh."
      mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$STAMP" > "$STAMP_FILE" 2>/dev/null
    fi
  fi
fi

# Resume-drift detection. Only meaningful for source=resume, and only when
# jq and a prior snapshot both exist.
[[ "$SOURCE" != "resume" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0

# A mod Claude wrote in this session loads when it resumes, even if hot reload
# was declined with "Not now". Name each one rather than let it arrive unseen.
DEV_MODS=$(expand_tilde "${CLAUDE_DEV_MODS_DIR:-$HOME/.claude/dev-mods}")/$SESSION_ID
for m in "$DEV_MODS"/*/; do
  [[ -f "$m.claude-plugin/plugin.json" ]] || continue
  echo "Mod loading from this session: ${m%/} (review: claude plugin validate ${m%/})"
done
command -v jq &>/dev/null || exit 0

SNAP="$STATE_DIR/${SESSION_ID}.json"
[[ ! -f "$SNAP" ]] && exit 0

# Compare HEAD.
SNAP_HEAD=$(jq -r '.git_head // ""' "$SNAP" 2>/dev/null)
CUR_HEAD=""
git rev-parse --git-dir &>/dev/null 2>&1 && CUR_HEAD=$(git rev-parse HEAD 2>/dev/null)

# Walk edited_files, classify each.
DRIFT_LINES=()
while IFS=$'\t' read -r path expected_hash expected_exists; do
  [[ -z "$path" ]] && continue
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

[[ ${#DRIFT_LINES[@]} -eq 0 && "$HEAD_CHANGED" -eq 0 ]] && exit 0

echo ""
echo "## Resume drift detected"
if [[ ${#DRIFT_LINES[@]} -gt 0 ]]; then
  echo "The prior session recorded edits to the files below, but the current"
  echo "on-disk state no longer matches. Re-verify before trusting conclusions"
  echo "from prior-session tool results."
  echo ""
fi

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
