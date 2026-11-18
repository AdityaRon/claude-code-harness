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
# One jq for the three fields, where jq_get would start one each. @sh quotes
# every value for the eval; with no jq, or input that is not an object, all stay empty.
SOURCE="" SESSION_ID="" LAUNCH_DIR=""
if command -v jq &>/dev/null; then
  eval "$(printf '%s\n' "$INPUT" | jq -r '@sh "SOURCE=\(.source // "") SESSION_ID=\(.session_id // "") LAUNCH_DIR=\(.cwd // "")"' 2>/dev/null)"
fi

# zsh's NOMATCH and EQUALS abort bash-shaped commands. $CLAUDE_ENV_FILE is sourced
# before each Bash call only, so interactive shells keep their options. `if`, not
# `&&`: status 0 under bash. Outside the budget, so no start skips it.
ZSH_OPTS='if [ -n "${ZSH_VERSION:-}" ]; then setopt no_nomatch no_equals; fi'
if [[ -n "${CLAUDE_ENV_FILE:-}" && "${CLAUDE_ZSH_OPTS:-on}" != off ]]; then
  _have=""
  if [[ -f "$CLAUDE_ENV_FILE" ]]; then
    while IFS= read -r _l || [[ -n "$_l" ]]; do [[ "$_l" == "$ZSH_OPTS" ]] && { _have=1; break; }; done < "$CLAUDE_ENV_FILE"
  fi
  [[ -n "$_have" ]] || printf '%s\n' "$ZSH_OPTS" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  unset _have _l
fi

# --- time budget -------------------------------------------------------------
# Every section below is context or housekeeping the session can start without.
# One that would start past the budget (bash's whole-second SECONDS: 3.2 has no
# finer clock, so 3 means between two and three seconds) is skipped and named on
# one line at exit. A section already running is not stopped, so the hook can
# overrun by one; settings.json's 30 s timeout is the hard stop (Claude Code's
# own default is 10 minutes). A section skipped for time claims and stamps
# nothing, so the nudge it would have shown waits for the next start that
# reaches it: on a loaded machine a resume storm defers the nudge, not loses it.
BUDGET=${CLAUDE_SESSION_START_BUDGET:-3} SECONDS=0
SKIPPED=""
in_budget() { (( SECONDS < BUDGET )) && return 0; SKIPPED="$SKIPPED $1"; return 1; }
trap '[[ -z "$SKIPPED" ]] || printf "\nsession-start: past its %s s budget, skipped:%s\n" "$BUDGET" "$SKIPPED"' EXIT

# claim FILE STAMP: true for one of the sessions that race to do what STAMP names
# (a day's nudge, one state of an index), so a resume storm does it once. A
# noclobber create is atomic, starts no process and never expires: a run killed
# after it claims loses that one nudge or rewrite. The winner clears older claims.
claim() {
  local c="$1.claim.${2//[^A-Za-z0-9._-]/_}" o old=()
  [[ -w "${1%/*}" ]] || return 0   # an unwritable state folder: every session, as before
  set -C; { : > "$c"; } 2>/dev/null || { set +C; return 1; }; set +C
  for o in "$1".claim.*; do [[ "$o" == "$c" ]] || old+=("$o"); done
  [[ ${#old[@]} -eq 0 ]] || rm -f "${old[@]}"
}

# Skipped on startup: the CLI's own system prompt already carries branch,
# main branch, status and `git log --oneline -n 5` (its gitStatus block), so
# this was a second copy. A cleared conversation gets a fresh gitStatus too.
# On resume/compact/fork that snapshot may be stale.
if [[ "$SOURCE" != "startup" && "$SOURCE" != "clear" ]] && in_budget git-context && git rev-parse --git-dir &>/dev/null 2>&1; then
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

STATE_DIR=$(expand_tilde "${CLAUDE_STATE_DIR:-$HOME/.claude/state/sessions}")

# --- keep the memory index in tier order, when that can matter --------------
# MEMORY.md is cut tail-first at 200 lines and the memory writer appends at the
# end, so a feedback_ entry can land past the cut, where it never loads.
# memory-index.sh restores tier order as a pure permutation. It was most of
# session start, so it runs only when all three hold:
#   - the index is under pressure (memory-lint.sh's thresholds);
#   - the index changed since the last run (mtime and size, stamped below);
#   - auto-dream's .consolidate-lock is older than its 1 h TTL: a younger one
#     means the CLI's own consolidation may be rewriting this store.
# Only THIS session's store: the others are not being loaded here.
PROJECTS_DIR=$(expand_tilde "${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}")
[[ -z "$LAUNCH_DIR" ]] && LAUNCH_DIR="$PWD"
# The store slug is the launch path with every non-alphanumeric a dash, as the
# CLI does it. A path over 200 characters also gets a hash suffix; not found, skipped.
STORE_SLUG=$(store_slug "$LAUNCH_DIR")
MEM_DIR="$PROJECTS_DIR/$STORE_SLUG/memory"
IDX_LINES=0 IDX_BYTES=0
[[ -f "$MEM_DIR/MEMORY.md" ]] && read -r IDX_LINES IDX_BYTES < <(wc -lc < "$MEM_DIR/MEMORY.md")
# The stamp and the lock are read only under pressure, the rare case.
if { [[ "$IDX_LINES" -ge "${MEMORY_INDEX_PRESSURE_LINES:-180}" ]] || [[ "$IDX_BYTES" -ge "${MEMORY_INDEX_PRESSURE_CHARS:-20000}" ]]; } \
   && in_budget memory-index; then
  STAMP_FILE="$STATE_DIR/memory-index/$STORE_SLUG"
  STAMP="$(date -r "$MEM_DIR/MEMORY.md" +%s 2>/dev/null) $IDX_BYTES"
  LOCK_FRESH=""
  [[ -f "$MEM_DIR/.consolidate-lock" ]] && LOCK_FRESH=$(find "$MEM_DIR/.consolidate-lock" -mmin -60 2>/dev/null)
  if [[ "$(head -1 "$STAMP_FILE" 2>/dev/null)" != "$STAMP" ]] && [[ -z "$LOCK_FRESH" ]]; then
    INDEX_TOOL=""
    for cand in "$(dirname "$0")/../memory-index.sh" "$(dirname "$0")/../bin/memory-index.sh"; do
      [[ -f "$cand" ]] && INDEX_TOOL="$cand" && break
    done
    # Silent: a pure permutation leaves the model nothing to act on. Stamped
    # after the write so the stamp records the index as it is now. One session
    # per store and index state writes.
    [[ -d "$STATE_DIR/memory-index" ]] || mkdir -p "$STATE_DIR/memory-index" 2>/dev/null
    if [[ -n "$INDEX_TOOL" ]] && claim "$STAMP_FILE" "$STAMP"; then
      CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" \
        bash "$INDEX_TOOL" --store "$STORE_SLUG" --write >/dev/null 2>&1 || true
      printf '%s %s\n' "$(date -r "$MEM_DIR/MEMORY.md" +%s 2>/dev/null)" "$(wc -c < "$MEM_DIR/MEMORY.md" | tr -d ' ')" > "$STAMP_FILE" 2>/dev/null
    fi
  fi
fi

# --- worktree records whose folder is gone ------------------------------------
# A session's scratch worktree goes when its job folder does, but the repo keeps
# the record, and the branch stays checked out there: it cannot be deleted or
# checked out again. Prune the launch repo and the repos one level under it.
# Reading the records forks nothing; git runs only when one is stale, detached.
in_budget worktree-prune && for g in "$LAUNCH_DIR/.git" "$LAUNCH_DIR"/*/.git; do
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

# --- the host's binary is gone: an upgrade deleted it under a running session --
# Every source, no stamp: a restart is the only fix, and each host is one.
# One ps; CLAUDE_HOST_PS and CLAUDE_HOST_START are the test seams (lib.sh).
if ! host_binary_check; then echo ""; fi

# --- a newer harness release ------------------------------------------------
# harness-update.sh writes the newest tag it fetched; nothing here touches the
# network. Only a machine installed from a plain tag is nudged: a clone past
# the tag is being worked on.
LATEST_FILE=$(expand_tilde "${CLAUDE_HARNESS_LATEST:-$HOME/.claude/state/harness-latest}")
VERSION_FILE=$(expand_tilde "${CLAUDE_HARNESS_VERSION:-$HOME/.claude/harness.version}")
if [[ -f "$LATEST_FILE" && -f "$VERSION_FILE" ]] && in_budget release-nudge; then
  LATEST="" INSTALLED=""
  read -r LATEST _ < "$LATEST_FILE" || true
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == version=* ]] && { INSTALLED=${line#version=}; break; }
  done < "$VERSION_FILE"
  SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'
  if [[ "$LATEST" =~ $SEMVER && "$INSTALLED" =~ $SEMVER && "$LATEST" != "$INSTALLED" \
        && "$(printf '%s\n%s\n' "$LATEST" "$INSTALLED" | sort -V | tail -1)" == "$LATEST" ]]; then
    STAMP_FILE="$STATE_DIR/release-nudge"
    STAMP="$LATEST $(date +%Y-%m-%d)"
    CUR="" && { { read -r CUR < "$STAMP_FILE"; } 2>/dev/null || true; }
    [[ "$CUR" != "$STAMP" && ! -d "$STATE_DIR" ]] && mkdir -p "$STATE_DIR" 2>/dev/null
    if [[ "$CUR" != "$STAMP" ]] && claim "$STAMP_FILE" "$STAMP"; then
      echo ""
      echo "## Harness $LATEST is available; $INSTALLED is installed. Run ~/.claude/harness-update.sh."
      printf '%s\n' "$STAMP" > "$STAMP_FILE" 2>/dev/null
    fi
  fi
fi

# --- job folders and Bazel output bases past a size -------------------------
# harness-update.sh measures once a day (disk-space.py stamp); this reads its
# stamp with builtins and sizes nothing. Over a threshold, one warning per
# measurement, so once a day. A stamp over two days old says nothing: its
# numbers may no longer hold. The one process, date, runs once per measurement.
DISK_STAMP=$(expand_tilde "${CLAUDE_DISK_STAMP:-$HOME/.claude/state/disk-usage}")
if [[ -f "$DISK_STAMP" ]] && in_budget disk-warning; then
  D_JOBS=0 D_BAZEL=0 D_ORPH=0 D_N=0 D_AT=0 D_DATE="" D_TB="" D_TC="" D_GP=0 D_GC=0
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    case "$k" in
      date) [[ "$v" =~ ^[0-9-]+$ ]] && D_DATE=$v; continue ;;
      transcript)  # SESSION BYTES COMPACTIONS; only this session's, only on resume
        [[ "$SOURCE" == resume && -n "$SESSION_ID" && "$v" =~ ^([A-Za-z0-9_-]+)\ ([0-9]{1,15})\ ([0-9]{1,6})$ \
           && "${BASH_REMATCH[1]}" == "$SESSION_ID" ]] && D_TB=${BASH_REMATCH[2]} D_TC=${BASH_REMATCH[3]}
        continue ;;
    esac
    [[ "$v" =~ ^[0-9]{1,15}$ ]] || continue
    case "$k" in
      jobs_bytes) D_JOBS=$v ;; bazel_bytes) D_BAZEL=$v ;; orphan_bytes) D_ORPH=$v ;;
      orphans) D_N=$v ;; measured) D_AT=$v ;; guard_p90_ms) D_GP=$v ;; guard_calls) D_GC=$v ;;
    esac
  done < "$DISK_STAMP"
  D_JL=${CLAUDE_DISK_WARN_JOBS_GB:-50} D_BL=${CLAUDE_DISK_WARN_BAZEL_GB:-100}
  [[ "$D_JL" =~ ^[0-9]{1,6}$ ]] || D_JL=50
  [[ "$D_BL" =~ ^[0-9]{1,6}$ ]] || D_BL=100
  if (( D_AT > 0 )) && (( D_JOBS > D_JL * 1000000000 || D_BAZEL > D_BL * 1000000000 )); then
    STAMP_FILE="$STATE_DIR/disk-warning"
    CUR="" && { { read -r CUR < "$STAMP_FILE"; } 2>/dev/null || true; }
    [[ "$CUR" != "$D_AT" && ! -d "$STATE_DIR" ]] && mkdir -p "$STATE_DIR" 2>/dev/null
    if [[ "$CUR" != "$D_AT" ]] && claim "$STAMP_FILE" "$D_AT"; then
      NOW=${EPOCHSECONDS:-}
      [[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date +%s)
      if (( NOW - D_AT <= 2 * 86400 )); then
        gb() { local t=$(( ($2 + 50000000) / 100000000 )); printf -v "$1" '%d.%d GB' $((t / 10)) $((t % 10)); }
        gb G_JOBS "$D_JOBS"; gb G_BAZEL "$D_BAZEL"; gb G_ORPH "$D_ORPH"
        echo ""
        echo "## Disk, as harness-update.sh measured it on ${D_DATE:-its last run}"
        (( D_JOBS > D_JL * 1000000000 )) && echo "Job folders in ~/.claude/jobs hold $G_JOBS (warns past $D_JL GB). Each job folder's size and tmp entries: python3 ~/.claude/disk-space.py report"
        (( D_BAZEL > D_BL * 1000000000 )) && echo "The Bazel output root holds $G_BAZEL (warns past $D_BL GB), $G_ORPH of it in $D_N output bases whose workspace is gone. Each base: python3 ~/.claude/disk-space.py bazel"
      fi
      printf '%s\n' "$D_AT" > "$STAMP_FILE" 2>/dev/null
    fi
  fi
  # Once per session and measurement: claim's file is per session.
  if [[ -n "$D_TB" ]] && (( D_AT > 0 )); then
    [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR" 2>/dev/null
    if claim "$STATE_DIR/$SESSION_ID.transcript" "$D_AT"; then
      NOW=${EPOCHSECONDS:-}
      [[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date +%s)
      if (( NOW - D_AT <= 2 * 86400 )); then
        echo ""
        echo "## This session's transcript"
        echo "It held $(( (D_TB + 500000) / 1000000 )) MB after $D_TC compactions when harness-update.sh measured it on ${D_DATE:-its last run}. Consider writing a handoff (settled, open, next) and continuing in a fresh session. Every large transcript: python3 ~/.claude/disk-space.py report"
      fi
    fi
  fi
  D_GL=${CLAUDE_GUARD_P90_WARN_MS:-1000}
  [[ "$D_GL" =~ ^[0-9]{1,7}$ ]] || D_GL=1000
  if (( D_GP > D_GL && D_AT > 0 )); then
    [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR" 2>/dev/null
    if claim "$STATE_DIR/guard-latency" "$D_AT"; then
      NOW=${EPOCHSECONDS:-}
      [[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date +%s)
      if (( NOW - D_AT <= 2 * 86400 )); then
        t=$(( (D_GP + 50) / 100 )) l=$(( (D_GL + 50) / 100 ))
        echo ""
        echo "## Bash guards"
        echo "In the last $D_GC Bash calls before ${D_DATE:-the last measurement}, 1 in 10 waited $((t / 10)).$((t % 10)) s or more for its slowest guard (says so past $((l / 10)).$((l % 10)) s). Which guard: bash ~/.claude/harness-src/doctor.sh --latency"
      fi
    fi
  fi
fi

# --- the Bash guards' timing log ----------------------------------------------
# bash-guards.sh appends a line a call with a builtin and never sizes the file.
# Past 10 MB it moves to .1, replacing the last one; detached, as the prune is.
TIMING_LOG=$(expand_tilde "${CLAUDE_GUARD_TIMING_LOG:-$HOME/.claude/logs/guard-timing.log}")
if [[ -f "$TIMING_LOG" ]] && in_budget guard-timing; then
  ( [[ -n "$(find "$TIMING_LOG" -size +10240k 2>/dev/null)" ]] && mv -f "$TIMING_LOG" "$TIMING_LOG.1" ) >/dev/null 2>&1 &
fi

# Resume-drift detection. Only meaningful for source=resume, and only when
# jq and a prior snapshot both exist.
[[ "$SOURCE" != "resume" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0

# A mod Claude wrote in this session loads when it resumes, even if hot reload
# was declined with "Not now". Name each one rather than let it arrive unseen.
# Outside the budget: it starts no process, and it is a safety notice.
DEV_MODS=$(expand_tilde "${CLAUDE_DEV_MODS_DIR:-$HOME/.claude/dev-mods}")/$SESSION_ID
for m in "$DEV_MODS"/*/; do
  [[ -f "$m.claude-plugin/plugin.json" ]] || continue
  echo "Mod loading from this session: ${m%/} (review: claude plugin validate ${m%/})"
done
in_budget resume-drift || exit 0
command -v jq &>/dev/null || exit 0

SNAP="$STATE_DIR/${SESSION_ID}.json"
[[ ! -f "$SNAP" ]] && exit 0

# Compare HEAD.
SNAP_HEAD=$(jq -r '.git_head // ""' "$SNAP" 2>/dev/null)
CUR_HEAD=""
git rev-parse --git-dir &>/dev/null 2>&1 && CUR_HEAD=$(git rev-parse HEAD 2>/dev/null)

# Walk edited_files, classify each. One hash process for all of them, not one
# each: a long session edits dozens. A file the hasher cannot read has drifted.
DRIFT_LINES=() PATHS=() WANT=() GOT_P=() GOT_H=()
while IFS=$'\t' read -r path expected_hash expected_exists; do
  [[ -z "$path" ]] && continue
  if [[ ! -f "$path" ]]; then
    if [[ "$expected_exists" == "true" ]]; then
      DRIFT_LINES+=("missing: $path")
    fi
    continue
  fi
  [[ -n "$expected_hash" ]] && { PATHS+=("$path"); WANT+=("$expected_hash"); }
done < <(jq -r '.edited_files[]? | [.path, .sha256, (.exists|tostring)] | @tsv' "$SNAP" 2>/dev/null)
if [[ ${#PATHS[@]} -gt 0 ]]; then
  while IFS= read -r line; do
    GOT_H+=("${line%%  *}"); GOT_P+=("${line#*  }")
  done < <(sha256_files "${PATHS[@]}")
  for ((i = 0; i < ${#PATHS[@]}; i++)); do
    actual_hash=""
    for ((j = 0; j < ${#GOT_P[@]}; j++)); do
      [[ "${GOT_P[$j]}" == "${PATHS[$i]}" ]] && { actual_hash=${GOT_H[$j]}; break; }
    done
    [[ "$actual_hash" != "${WANT[$i]}" ]] && DRIFT_LINES+=("drifted: ${PATHS[$i]}")
  done
fi

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
