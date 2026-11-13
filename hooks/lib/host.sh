#!/usr/bin/env bash
# hooks/lib.sh sources this: the Claude Code host: its CLI version, process chain, deleted binary.

# --- the session's Claude Code host, and whether its binary still exists -------
# macOS keys a background host's Desktop, Documents and Downloads grant to the
# host binary's path; an upgrade deletes that path while the host runs on, and
# access there fails once tccd restarts (docs/known-limitations.md). Seams:
# CLAUDE_HOST_PS, a file of `pid ppid comm` lines (lib.sh puts the system bin
# dirs first on PATH, so a stand-in ps is never reached); CLAUDE_HOST_BIN/PID/PARENT.
# A path as the CLI names its memory store: every character but an ASCII letter
# or digit becomes a dash. The class is spelled out: a range like A-Z follows the
# locale's collation in bash 3.2 and keeps é under UTF-8, where sed does not.
store_slug() {
  local alnum='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  printf '%s' "${1//[^$alnum]/-}"
}

# The installed CLI's version from the path `claude` resolves to, when the path
# names it (.../claude-code@latest/2.1.322/claude, .../claude/versions/2.1.322):
# one readlink, where `claude --version` starts the CLI (16 ms on an M-series Mac).
# CLAUDE_CLI_PATH stands in for `command -v claude` in tests (PATH is reset above).
cli_version() {
  local p d v
  p=${CLAUDE_CLI_PATH:-$(command -v claude 2>/dev/null)}
  [[ -n "$p" ]] || return 0
  p=$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")
  d=${p%/*}; d=${d##*/}
  for v in "${p##*/}" "$d"; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] && { printf '%s\n' "$v"; return 0; }
  done
  v=$("$p" --version 2>/dev/null)
  [[ -n "$v" ]] && printf '%s\n' "${v%% *}"
}

host_ps_snapshot() {   # pid ppid comm, one process per line
  if [[ -n "${CLAUDE_HOST_PS:-}" ]]; then cat "$CLAUDE_HOST_PS" 2>/dev/null
  else ps -axo pid=,ppid=,comm= 2>/dev/null; fi
}

# The top-most claude process above $1 (default: this process), as four
# tab-separated fields: pid, ppid, its comm, and the first app bundle above it
# (a terminal's, whose grant then covers it) or launchd; nothing when none. TCC
# attributes to the top-most one, the host; the first one up is often the
# `--resume` client inside it.
claude_host() {   # one awk walks the whole chain: an awk per ancestor cost as much as the ps
  host_ps_snapshot | awk -v start="${1:-$$}" '
    { pid = $1; up[pid] = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); comm[pid] = $0 }
    END {
      p = start; n = 0; found = ""; above = ""
      while (p ~ /^[0-9]+$/ && p + 0 > 1 && n < 50 && (p in up)) {
        c = comm[p]; base = c; sub(/.*\//, "", base)
        if (base == "claude" || base == "claude.exe") { found = p "\t" up[p] "\t" c; above = "" }
        else if (found != "" && above == "" && c ~ /\.app\//) above = c
        p = up[p]; n++
      }
      if (found != "") printf "%s\t%s\n", found, (above == "" ? "launchd" : above)
    }'
}

# Silent (0) when this session's host binary exists, the host is under a
# terminal app (that app's bundle-keyed grant covers it), or there is no host;
# otherwise prints the diagnosis, markdown headed, and returns 1.
host_binary_check() {
  local pid comm above host now marker
  if [[ -n "${CLAUDE_HOST_BIN:-}" ]]; then
    pid=${CLAUDE_HOST_PID:-0}; comm=$CLAUDE_HOST_BIN; above=${CLAUDE_HOST_PARENT:-launchd}
  else
    host=$(claude_host "${CLAUDE_HOST_START:-$$}"); [[ -n "$host" ]] || return 0
    IFS=$'\t' read -r pid _ comm above <<< "$host"
  fi
  [[ "$comm" == /* ]] || return 0          # Linux ps gives a bare name: nothing to test
  [[ -e "$comm" ]] && return 0
  case "$above" in *.app/*) return 0 ;; esac
  now=$(command -v claude 2>/dev/null)
  [[ -n "$now" ]] && now=" claude on PATH is now $(readlink -f "$now" 2>/dev/null || printf '%s' "$now")."
  echo "## This session's Claude Code binary is gone"
  echo "The session host, pid $pid, runs from $comm, which no longer exists: an upgrade deleted it and the host runs on from memory.$now macOS keys a background host's Desktop, Documents and Downloads access to that path, so once tccd restarts every access there fails with 'Operation not permitted' (git: couldn't read packed-refs). Save work, then restart this session so it runs from the current binary. A clone outside those folders is unaffected: ~/.claude/relocate-clones.sh moves one. Check all hosts: bash -c 'source ~/.claude/hooks/lib.sh; stale_claude_hosts'."
  marker=$(expand_tilde "${CLAUDE_CLI_UPGRADED:-$HOME/.claude/state/cli-upgraded}")
  [[ -f "$marker" ]] && echo "harness-update.sh's last CLI upgrade: $(head -1 "$marker")"
  return 1
}

# Every running claude process whose absolute binary path is gone, as
# pid<TAB>path lines. For doctor.sh --hosts and the updater.
stale_claude_hosts() {
  local pid comm
  host_ps_snapshot | while read -r pid _ comm; do
    case "${comm##*/}" in claude|claude.exe) ;; *) continue ;; esac
    [[ "$comm" == /* && ! -e "$comm" ]] && printf '%s\t%s\n' "$pid" "$comm"
  done
  return 0
}
