#!/usr/bin/env bash
# Shared helpers for Claude Code harness hooks.
# Source from every hook: source "$(dirname "$0")/lib.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Expand leading ~ in a path; needed because the hook runtime passes env
# values verbatim without shell expansion.
expand_tilde() {
  local p="$1"
  printf '%s\n' "${p/#\~/$HOME}"
}

# Strip tokens that sit in front of a command without changing what runs:
# env assignments (FOO=bar), `env`, and the wrapper commands Claude Code itself
# strips before matching a permission rule (timeout/time/nice/nohup/stdbuf/
# command/builtin/noglob).
#
# Why this is shared: guards that anchor their regexes to a command boundary
# only admit ^, |, &, ;, &&, ||, $( and a backtick. A leading assignment or
# wrapper is none of those, so `VAR=1 git push -f` and `nohup git push -f`
# matched nothing and were allowed silently, while the bare form was denied.
# kubectl-guard was immune only because it tokenises and scans for the binary
# anywhere; git-guard is regex-anchored and was not. Normalising here keeps one
# implementation instead of two divergent ones.
#
# Stripping is applied per segment so a boundary is preserved:
#   `cd /x && VAR=1 nohup git push -f`  ->  `cd /x && git push -f`
# Four passes handle stacked prefixes (`env A=1 B=2 nohup timeout 60 git …`);
# a fixed count avoids sed label/branch syntax, which differs on BSD and GNU.
# Output feeds pattern matching only — never execution — so a mangled quote is
# harmless, and ambiguity makes the guards fail closed by design.
normalize_wrappers() {
  local s="$1" i
  # Give a command-substitution opener its own whitespace BEFORE the assignment
  # rule runs. Without this the assignment pattern swallows the substitution
  # body — `X=$(kubectl delete pod foo)` normalised to `delete pod foo)`, and
  # the kubectl scan then found nothing at all. The openers are separated, not
  # removed: git-guard anchors on `$(` as a command boundary.
  s=$(printf '%s' "$s" | sed -E 's/\$\(/ $( /g; s/`/ ` /g')
  for i in 1 2 3 4; do
    s=$(printf '%s' "$s" | sed -E \
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/\1\2/g' \
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)(env|command|builtin|noglob|nohup|time|nice|stdbuf)[[:space:]]+/\1\2/g' \
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)timeout[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[0-9]+[smhd]?[[:space:]]+/\1\2/g')
  done
  printf '%s' "$s"
}

# Read full stdin once into $INPUT. Safe to call with no stdin.
read_input() {
  if [[ -t 0 ]]; then
    INPUT=""
  else
    INPUT=$(cat)
  fi
  export INPUT
}

# Fail closed for PreToolUse guards: without jq we cannot reliably parse the
# tool input to make a security decision, so deny rather than silently allow.
# Call this immediately after read_input in every deny-capable Bash/file guard.
# Only denies when there is actually input to evaluate (a real tool call).
require_jq_or_deny() {
  command -v jq &>/dev/null && return 0
  [[ -z "$INPUT" ]] && return 0
  emit_deny "Blocked: the security harness cannot parse this tool call because jq is not installed, and it will not allow commands it cannot inspect. Install jq (brew install jq) and retry."
  exit 0
}

# Extract a field from $INPUT using jq. Empty if jq is missing or field absent.
jq_get() {
  local expr="$1"
  if command -v jq &>/dev/null; then
    printf '%s\n' "$INPUT" | jq -r "$expr // \"\"" 2>/dev/null
  fi
}

# Emit a PreToolUse deny decision with a reason. Safe against quotes/backslashes.
emit_deny() {
  local reason="$1"
  if command -v jq &>/dev/null; then
    jq -nc --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
      "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# Emit a PreToolUse ask decision (prompt the user) with a reason.
emit_ask() {
  local reason="$1"
  if command -v jq &>/dev/null; then
    jq -nc --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
      "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# Append to the audit log. Creates parent dir, rotates at 10MB, keeps 5 backups,
# and restricts perms to 0600. Never fails the hook on error.
log_audit() {
  local line="$1"
  local log
  log=$(expand_tilde "${CLAUDE_AUDIT_LOG:-$HOME/.claude/logs/audit.log}")
  local dir
  dir=$(dirname "$log")
  mkdir -p "$dir" 2>/dev/null || return 0

  # Rotate if >10MB
  if [[ -f "$log" ]]; then
    local size
    size=$(stat -c%s "$log" 2>/dev/null || stat -f%z "$log" 2>/dev/null || echo 0)
    if [[ "$size" -gt 10485760 ]]; then
      for i in 4 3 2 1; do
        [[ -f "${log}.${i}" ]] && mv -f "${log}.${i}" "${log}.$((i+1))" 2>/dev/null
      done
      mv -f "$log" "${log}.1" 2>/dev/null
    fi
  fi

  printf '%s\n' "$line" >> "$log" 2>/dev/null || return 0
  chmod 600 "$log" 2>/dev/null || true
}

# SHA-256 of a file's contents. Empty output if file is missing or unreadable.
# Prefers shasum (macOS default), falls back to sha256sum (Linux default).
sha256_file() {
  local p="$1"
  [[ -z "$p" || ! -f "$p" ]] && return 0
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$p" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$p" 2>/dev/null | awk '{print $1}'
  fi
}

# Resolve a path to its canonical form (symlinks, /private/var aliases).
# Falls back gracefully when the path does not exist.
canonical_path() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  p=$(expand_tilde "$p")
  local out=""
  # GNU realpath: accepts nonexistent paths. BSD realpath (macOS default): does not,
  # but resolves symlinks when the target exists. Fall back to python3 for the
  # nonexistent case — python's os.path.realpath always returns a normalized path.
  if command -v realpath &>/dev/null; then
    out=$(realpath "$p" 2>/dev/null) || out=""
  fi
  if [[ -z "$out" ]] && command -v python3 &>/dev/null; then
    out=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null) || out=""
  fi
  [[ -z "$out" ]] && out="$p"
  printf '%s\n' "$out"
}
