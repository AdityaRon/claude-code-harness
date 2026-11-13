#!/usr/bin/env bash
# hooks/lib.sh sources this: this session's scratch folder, and the bounded runner.

# This session's scratch folder. A background session gets ~/.claude/jobs/<the
# first 8 characters of its session id>/tmp, and a hook's environment has no
# CLAUDE_JOB_DIR, so it is derived. Empty for an interactive session.
session_scratch() {   # $1: the command and cwd, when the caller has them
  local sid d re='jobs/|CLAUDE_JOB_DIR|claude-[0-9]'
  sid=$(jq_get '.session_id')
  [[ "$sid" =~ ^[0-9a-f]{8}- ]] || return 0
  [[ -d "$HOME/.claude/jobs/${sid:0:8}" ]] && { printf '%s\n' "$HOME/.claude/jobs/${sid:0:8}/tmp"; return 0; }
  # A resumed job keeps its folder under the first session's id and runs under
  # a new one; its state.json names the new id. Measured: every rm-guard deny
  # on one Mac (2026-09-24 to 2026-10-15) was a resumed job's own scratch.
  # Only a path naming a job folder can land in one, so skip the scan otherwise.
  [[ $# -eq 0 || "$1" =~ $re ]] || return 0
  for d in "$HOME"/.claude/jobs/*/; do
    [[ -f "$d/state.json" ]] || continue
    grep -qE "\"(sessionId|resumeSessionId)\":[[:space:]]*\"$sid\"" "$d/state.json" 2>/dev/null \
      && { printf '%s\n' "${d%/}/tmp"; return 0; }
  done
  return 0
}

# Run a command under a wall-clock cap. perl's alarm is on every macOS and Linux
# this runs on (tests/guard-latency.test.sh relies on it); without perl the
# command runs uncapped and Claude Code's own hook timeout applies.
run_bounded() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"; else "$@"; fi
}

# Is path $1, as typed, inside scratch folder $2 (or strictly inside TMPDIR)?
# Understands quotes, ~, $HOME, $CLAUDE_JOB_DIR and $TMPDIR; any other
# expansion or a `..` is never inside. $3 resolves a relative path; empty, never.
# Prints the resolved path when it is inside.
in_scratch() {
  local p="$1" scratch="$2" base="$3" t="${TMPDIR:-}"
  p="${p//\"/}"; p="${p//\'/}"; t="${t%/}"
  [[ -n "$p" ]] || return 1
  case "$p" in *..*) return 1 ;; esac
  # shellcheck disable=SC2088  # '~/' is the tilde as typed; it is expanded below
  case "$p" in
    '$CLAUDE_JOB_DIR/'*|'${CLAUDE_JOB_DIR}/'*) [[ -n "$scratch" ]] || return 1; p="${scratch%/tmp}/${p#*/}" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    '$HOME/'*|'${HOME}/'*) p="$HOME/${p#*/}" ;;
    '$TMPDIR/'*|'${TMPDIR}/'*) [[ -n "$t" ]] || return 1; p="$t/${p#*/}" ;;
    /*) ;;
    *) [[ -n "$base" ]] || return 1; p="${base%/}/$p" ;;
  esac
  case "$p" in *'$'*|*'`'*) return 1 ;; esac
  if [[ -n "$scratch" && ( "$p" == "$scratch" || "$p" == "$scratch/"* ) ]] || [[ -n "$t" && "$p" == "$t/"?* ]]; then
    printf '%s\n' "$p"; return 0
  fi
  # Sandboxed commands get TMPDIR=/tmp/claude-<uid>, and a job's Bash temp files
  # can sit in $TMPDIR/<job id>, accepted below. Hooks run outside the sandbox.
  local sb
  if [[ -n "$scratch" ]]; then
    sb="${scratch%/tmp}"; sb="/tmp/claude-$UID/${sb##*/}"
    case "$p" in "$sb"|"$sb/"*|"/private$sb"|"/private$sb/"*) printf '%s\n' "$p"; return 0 ;; esac
  fi
  return 1
}
