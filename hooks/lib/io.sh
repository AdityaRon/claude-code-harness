#!/usr/bin/env bash
# hooks/lib.sh sources this: reading the hook payload, decisions, the audit log, redaction.

# Read full stdin once into $INPUT. Safe to call with no stdin.
read_input() {
  [[ -n "${HARNESS_PRESET:-}" ]] && return 0
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

# Fail closed when the payload will not parse. require_jq_or_deny covers jq
# being absent; this covers jq being present and failing on the input. jq_get
# sends that failure to /dev/null and returns "", which every guard reads as
# "no command in this payload" and exits 0 on — so a truncated or corrupted
# payload was a full allow, not a smaller block, and the call went on to the
# permissions list or the auto-mode classifier with no guard opinion at all.
# Call immediately after require_jq_or_deny in every deny-capable guard.
#
# An absent or empty FIELD on parseable input is a different thing and stays
# legitimate: every guard is registered on tools it does not inspect. So this
# tests the document, not the field. No stdin is not a tool call either (hooks
# get run by hand and by the tests), so it is left alone.
require_parsable_or_deny() {
  [[ -z "$INPUT" ]] && return 0
  command -v jq &>/dev/null || return 0
  if [[ -n "${HARNESS_PRESET:-}" ]]; then [[ "${PRESET_OK:-}" == ok ]] && return 0
  else printf '%s' "$INPUT" | jq empty 2>/dev/null && return 0; fi
  emit_deny "Blocked: the security harness could not parse this tool call as JSON, and it will not allow a command it cannot inspect. Retry the call; if it repeats, the hook input is malformed."
  exit 0
}

# Extract a field from $INPUT using jq. Empty if jq is missing or field absent.
# Under the dispatcher the fields every Bash guard reads come from its one jq.
jq_get() {
  local expr="$1"
  if [[ -n "${HARNESS_PRESET:-}" ]]; then
    case "$expr" in
      .tool_input.command) printf '%s\n' "$PRESET_CMD"; return 0 ;;
      .tool_name) printf '%s\n' "$PRESET_TOOL"; return 0 ;;
      .cwd) printf '%s\n' "$PRESET_CWD"; return 0 ;;
      .session_id) printf '%s\n' "$PRESET_SID"; return 0 ;;
      .tool_input.url) printf '%s\n' "$PRESET_URL"; return 0 ;;
      .tool_input.ws.url) printf '%s\n' "$PRESET_WS"; return 0 ;;
    esac
  fi
  if command -v jq &>/dev/null; then
    printf '%s\n' "$INPUT" | jq -r "$expr // \"\"" 2>/dev/null
  fi
}

# First N bytes of stdin, minus a character the cut split. head -c and GNU
# cut -c both count bytes, so either can leave half a multibyte character and an
# audit line no UTF-8 reader accepts; iconv -c drops the partial one.
head_utf8() {
  head -c "$1" | if command -v iconv >/dev/null; then iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; else cat; fi
}

# One audit line per guard decision. The PostToolUse audit only sees calls that
# ran, so without this a deny left no record at all. The target is the command,
# path or URL, never file content: secret-scanner denies on content.
log_decision() {
  local target=""
  command -v jq &>/dev/null && target=$(printf '%s' "$INPUT" \
    | jq -j '.tool_input | .command // .file_path // .path // .notebook_path // .url // .ws.url // ""' 2>/dev/null \
    | tr '\n\t' '  ' | head_utf8 200)
  # Under the dispatcher $0 is bash-guards.sh; GUARD_NAME names the guard.
  log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) | GUARD | $1 | ${GUARD_NAME:-$(basename "$0" .sh)} | ${target:-unknown} | $PWD"
}

# Emit a PreToolUse deny decision with a reason. Safe against quotes/backslashes.
emit_deny() {
  local reason="$1"
  HOOK_DECIDED=deny
  log_decision deny
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
  HOOK_DECIDED=ask
  log_decision ask
  if command -v jq &>/dev/null; then
    jq -nc --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
      "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# A command hd_scan cannot read: the guard goes on with its old reading, so a
# deny or ask stands, and an allow becomes an ask, since which ; & | run there
# is unknown. Each guard calls this in its own shell once the command concerns
# it; only text holding what can make it unreadable pays for the awk.
unreadable_check() {  # guard text
  case "$2" in *'<<'*|*'${'*|*'(('*|*'$['*|*'`'*|*'$('*) ;; *) return 0 ;; esac
  printf '%s\n' "$2" | awk "$HEREDOC_AWK"'{ line[NR] = $0 } END { sh_classify(NR); exit SH_BAD ? 3 : 0 }' || unreadable_floor "$1"
}

unreadable_floor() { UNREADABLE_GUARD=$1; trap unreadable_exit EXIT; }

unreadable_exit() {
  [[ $? -eq 0 && -z "${HOOK_DECIDED:-}" ]] || return 0
  emit_ask "$UNREADABLE_GUARD: this command's quoting is more than the guard can read for certain (a \${ } holding quotes, a heredoc opener it cannot parse, or a quote inside backticks), so it cannot tell which ; & | separate commands. Check what it runs."
}

# Secret-shaped values out of an audit line: URL credentials, well-known token
# prefixes, an AWS secret key, a private key's body after its header (to the
# line's next ` | `, which base64 never holds), and the value after a key-like
# word. The line keeps its shape and its other fields.
redact_secrets() {
  sed -E \
    -e "s#((aws_secret_access_key|AWS_SECRET_ACCESS_KEY|[Ss]ecretAccessKey)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[A-Za-z0-9/+=]{40}#\1***#g" \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----)([^|]*[^| ])?/\1***/g' \
    -e 's#(://[^/@[:space:]:]+):[^/@[:space:]]+@#\1:***@#g' \
    -e 's/((ghp|gho|ghu|ghs|ghr)_|github_pat_|glpat-|xox[abprs]-|xapp-|sk-(ant-|proj-)?|sk_(live|test)_|AKIA|AIza)[A-Za-z0-9_-]{8,}/\1***/g' \
    -e 's/npm_[A-Za-z0-9]{36}/npm_***/g; s/ASIA[0-9A-Z]{16}/ASIA***/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/eyJ***/g' \
    -e 's#(hooks\.slack\.com/services/)[A-Za-z0-9/_+-]{20,}#\1***#g' \
    -e "s/([Aa]uthorization|[Bb]earer|[Tt]oken|TOKEN|[Ss]ecret|SECRET|[Pp]assword|PASSWORD|[Pp]asswd|[Aa]pi[_-]?[Kk]ey|API[_-]?KEY)([\"']?[=:[:space:]]+[\"']?)([Bb]earer[[:space:]]+)?[^[:space:]\"'&]+/\1\2\3***/g"
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

  printf '%s\n' "$line" | redact_secrets >> "$log" 2>/dev/null || return 0
  chmod 600 "$log" 2>/dev/null || true
}
