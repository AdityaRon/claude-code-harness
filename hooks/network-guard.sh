#!/usr/bin/env bash
# Network egress guard.
#
# Fires on: PreToolUse → Bash (for curl/wget), and PreToolUse → WebFetch.
#
# Policy:
#   • GET to an allowlisted domain   → silent allow
#   • GET to a non-allowlisted domain → ask
#   • POST / PUT / PATCH / DELETE to anywhere → ask (regardless of domain)
#   • curl/wget with local file body ( @/path ) to non-allowlisted → deny
#     (obvious exfil shape; env-guard also catches this, defense-in-depth)
#
# The allowlist is intentionally conservative: well-known read-only sources
# that Claude needs to function (package registries, GitHub docs, Anthropic).
# Projects can extend it via the CLAUDE_NET_ALLOWLIST env var (space-separated).
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
TOOL=$(jq_get '.tool_name')

# Default allowlist. Extendable via CLAUDE_NET_ALLOWLIST in settings.json env.
DEFAULT_ALLOW=(
  'api.github.com'
  'github.com'
  'raw.githubusercontent.com'
  'codeload.github.com'
  'objects.githubusercontent.com'
  'registry.npmjs.org'
  'registry.yarnpkg.com'
  'pypi.org'
  'files.pythonhosted.org'
  'crates.io'
  'static.crates.io'
  'go.dev'
  'proxy.golang.org'
  'sum.golang.org'
  'docs.anthropic.com'
  'docs.claude.com'
  'code.claude.com'
  'api.anthropic.com'
  'stackoverflow.com'
  'developer.mozilla.org'
  'rubygems.org'
)

host_allowed() {
  local host="$1"
  [[ -z "$host" ]] && return 1
  local h
  for h in "${DEFAULT_ALLOW[@]}"; do
    [[ "$host" = "$h" || "$host" = *".$h" ]] && return 0
  done
  if [[ -n "${CLAUDE_NET_ALLOWLIST:-}" ]]; then
    for h in $CLAUDE_NET_ALLOWLIST; do
      [[ "$host" = "$h" || "$host" = *".$h" ]] && return 0
    done
  fi
  return 1
}

extract_host() {
  local url="$1"
  # Strip scheme, then take everything up to the first / : ? #
  printf '%s' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' | sed -E 's#[/:?#].*$##'
}

case "$TOOL" in
  WebFetch)
    URL=$(jq_get '.tool_input.url')
    [[ -z "$URL" ]] && exit 0
    HOST=$(extract_host "$URL")
    if host_allowed "$HOST"; then
      exit 0
    fi
    emit_ask "WebFetch to $HOST is outside the default allowlist. Confirm the URL is safe (no secrets in the path/query)."
    exit 0
    ;;
  Bash)
    CMD=$(jq_get '.tool_input.command')
    [[ -z "$CMD" ]] && exit 0

    # Other egress channels beyond curl/wget. scp/rsync/sftp copy files to a
    # remote host; a local HTTP server exposes the working tree. All → ask.
    if printf '%s\n' "$CMD" | grep -qE '\b(scp|rsync|sftp)\b[^|;&]*([A-Za-z0-9._-]+@[A-Za-z0-9._-]+:|[A-Za-z0-9._-]+\.[A-Za-z]{2,}:)'; then
      emit_ask "scp/rsync/sftp transfers files to a remote host. Confirm the destination is trusted and the files contain no secrets."
      exit 0
    fi
    if printf '%s\n' "$CMD" | grep -qE '(python3?\s+-m\s+http\.server|php\s+-S|ruby\s+-run\s+-e\s+httpd|npx\s+http-server)'; then
      emit_ask "This starts a local HTTP server exposing files on the network. Confirm this is intended and scoped."
      exit 0
    fi

    # Beyond this point we only concern ourselves with curl/wget invocations.
    if ! printf '%s\n' "$CMD" | grep -qE '\b(curl|wget)\b'; then
      exit 0
    fi

    # Remote code execution: piping curl/wget output into a shell/interpreter.
    #   curl … | sh      wget … | bash      curl … | sudo bash
    if printf '%s\n' "$CMD" | grep -qE '\b(curl|wget)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|ksh|dash|fish|python3?|perl|ruby|node|php)\b'; then
      emit_deny "Blocked: piping curl/wget output into a shell/interpreter (remote code execution). Download to a file, inspect it, then run."
      exit 0
    fi
    #   bash <(curl …)   sh <(wget …)   — process substitution
    if printf '%s\n' "$CMD" | grep -qE '\b(bash|sh|zsh|ksh|dash|python3?|perl|ruby|node)\b[^<]*<\([[:space:]]*(curl|wget)\b'; then
      emit_deny "Blocked: executing curl/wget output via process substitution (remote code execution). Download to a file, inspect it, then run."
      exit 0
    fi
    #   bash -c "$(curl …)"   eval "$(wget …)"   eval `curl …`  — command substitution
    if printf '%s\n' "$CMD" | grep -qE '\b(eval|bash|sh|zsh)\b[^;&]*(\$\(|`)[[:space:]]*(curl|wget)\b'; then
      emit_deny "Blocked: executing curl/wget output via command substitution (remote code execution). Download to a file, inspect it, then run."
      exit 0
    fi

    # File-body upload patterns (exfil shape). Defense-in-depth — env-guard
    # already denies bare --data-binary etc., this layer specifically matches
    # the local-file-reference forms.
    #   -d @file   --data @file   --data-binary @file   --data-urlencode @file
    #   -F key=@file   -F @file   --form key=@file
    #   -T /local/path   --upload-file /local/path
    if printf '%s\n' "$CMD" | grep -qE '\b(curl|wget)\b[^|;&]*(-d|--data|--data-binary|--data-urlencode|--data-raw)(\s+|=)?@'; then
      emit_deny "Blocked: curl/wget uploading a local file as request body (@file). Move data into code, or run manually if legitimate."
      exit 0
    fi
    if printf '%s\n' "$CMD" | grep -qE '\bcurl\b[^|;&]*(-F|--form)\s+[^|;&]*@'; then
      emit_deny "Blocked: curl -F form upload with @file reference. Move data into code, or run manually if legitimate."
      exit 0
    fi
    if printf '%s\n' "$CMD" | grep -qE '\bcurl\b[^|;&]*(-T|--upload-file)\s+[^|;&]+'; then
      emit_deny "Blocked: curl -T / --upload-file uploads a local file. Move data into code, or run manually if legitimate."
      exit 0
    fi

    # Extract URL from the command (first http/https token).
    URL=$(printf '%s\n' "$CMD" | grep -oE 'https?://[^[:space:]\"'\''`]+' | head -1)
    [[ -z "$URL" ]] && exit 0
    HOST=$(extract_host "$URL")

    # Any mutating method → ask regardless of host.
    if printf '%s\n' "$CMD" | grep -qE '\bcurl\b[^|;&]*(-X\s*(POST|PUT|PATCH|DELETE)|--request\s*(POST|PUT|PATCH|DELETE))'; then
      emit_ask "curl is performing a mutating request (POST/PUT/PATCH/DELETE) to $HOST. Confirm the target and payload."
      exit 0
    fi

    # Read-only access to allowlisted host → allow silently.
    if host_allowed "$HOST"; then
      exit 0
    fi

    emit_ask "curl/wget request to $HOST is outside the default allowlist. Confirm this endpoint is safe."
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
