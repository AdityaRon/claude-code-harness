#!/usr/bin/env bash
# Network egress guard.
#
# Fires on: PreToolUse → Bash (for curl/wget), and PreToolUse → WebFetch.
#
# Policy:
#   • GET to an allowlisted domain   → silent allow
#   • GET to this machine (127.x, localhost, ::1) → silent allow, except a
#     local admin API (kubectl proxy, Docker, Vault ports; Kubernetes paths) → ask
#   • GET to a non-allowlisted domain → ask
#   • POST / PUT / PATCH / DELETE to anywhere → ask (regardless of domain)
#   • curl/wget with local file body ( @/path ) to non-allowlisted → deny
#     (obvious exfil shape; env-guard also catches this, defense-in-depth)
#
# The allowlist is intentionally conservative: well-known read-only sources
# that Claude needs to function (package registries, GitHub docs, Anthropic).
# Projects can extend it via the CLAUDE_NET_ALLOWLIST env var (space-separated),
# and a machine via `netAllowlist` in ~/.claude/local-settings/*.json, which
# survives every install (bin/net-allowlist.sh). Both pass net_host_problem.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
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
  # Reference docs: static pages whose request logs no one else can read, and
  # most of the remaining GET asks on one machine (2026-10-06). Exact doc hosts
  # where the parent domain also serves user content (hub.docker.com).
  'www.postgresql.org'
  'www.rfc-editor.org'
  'web.dev'
  'wikipedia.org'
  'nodejs.org'
  'kubernetes.io'
  'docs.docker.com'
  'www.anthropic.com'
  'support.claude.com'
  'platform.claude.com'
)

# This machine. A GET here never leaves it; a local dev server is most of what
# this guard used to ask about (25 of 51 decisions in the audit log, 2026-10-02).
is_loopback() {
  [[ "$1" == "localhost" || "$1" == "::1" || "$1" == "0.0.0.0" ]] && return 0
  [[ "$1" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# A local server that fronts credentials: `kubectl proxy` (8001), the Docker
# API (2375/2376), Vault (8200), or any port serving Kubernetes API paths. A GET
# there reads what kubectl-guard asks about, so it asks here too.
local_admin_url() {
  local auth path port
  auth=$(printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[/?#].*$##; s#^.*@##')
  path=$(printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/?#]*##')
  port=$(printf '%s' "$auth" | sed -nE 's#^.*\]:([0-9]+)$#\1#p; s#^[^][]*:([0-9]+)$#\1#p')
  [[ "$port" =~ ^(8001|2375|2376|8200)$ ]] && return 0
  printf '%s' "$path" | grep -qiE '^/(api/v1/(namespaces|secrets|configmaps|serviceaccounts|nodes)|apis/[a-z0-9.-]+/v[0-9][a-z0-9]*)(/|\?|$)|/secrets(/|\?|$)'
}

host_allowed() {
  local host="$1"
  [[ -z "$host" ]] && return 1
  is_loopback "$host" && return 0
  local h
  for h in "${DEFAULT_ALLOW[@]}"; do
    [[ "$host" = "$h" || "$host" = *".$h" ]] && return 0
  done
  if [[ -n "${CLAUDE_NET_ALLOWLIST:-}" ]]; then
    for h in $CLAUDE_NET_ALLOWLIST; do
      net_host_problem "$h" >/dev/null || continue
      [[ "$host" = "$h" || "$host" = *".$h" ]] && return 0
    done
  fi
  while IFS= read -r h; do
    [[ "$host" = "$h" || "$host" = *".$h" ]] && return 0
  done < <(local_net_hosts)
  return 1
}

# The fix for a repeat ask, in the ask itself: only for a host that may be listed.
add_hint() {
  net_host_problem "$1" >/dev/null && printf ' To stop asking on this machine: ~/.claude/net-allowlist.sh add %s' "$1"
}

extract_host() {
  local url="$1"
  # Scheme, then path/query, then userinfo, then port, in that order: cutting at
  # the first ':' read `https://github.com:x@evil.example/` as github.com, while
  # curl connects to evil.example.
  printf '%s' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[/?#].*$##; s#^.*@##; s#^(\[[^]]*\]).*$#\1#; s#:[0-9]*$##; s#^\[(.*)\]$#\1#' \
    | tr '[:upper:]' '[:lower:]'
}

case "$TOOL" in
  WebFetch)
    URL=$(jq_get '.tool_input.url')
    [[ -z "$URL" ]] && exit 0
    HOST=$(extract_host "$URL")
    if host_allowed "$HOST"; then
      exit 0
    fi
    emit_ask "WebFetch to $HOST is outside the default allowlist. Confirm the URL is safe (no secrets in the path/query).$(add_hint "$HOST")"
    exit 0
    ;;
  Bash)
    CMD=$(jq_get '.tool_input.command')
    [[ -z "$CMD" ]] && exit 0
    CMD=$(neutralize_quoted_amps "$(strip_inert_heredocs "$CMD")")
    # `/usr/bin/curl` and `CURL` are curl too: scan the normalized form (lib.sh) as
    # a second line.
    CMD=$(printf '%s\n%s' "$CMD" "$(normalize_command "$CMD")")

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

    # The machine-local allowlist is this guard's input: widening it takes one
    # human click per change, auto mode included. Edit and Write are denied there.
    # A run of the script asks unless its arguments are plainly list, candidates
    # or remove: a quoted or expanded `add` ('add', $X, xargs) is unreadable, and
    # xargs is stripped from the normalized line, so no arguments asks too.
    Q="[\"']?"
    NAME="${Q}([^[:space:]]*/)?net-allowlist(\.sh)?${Q}"
    RUN="^[[:space:]]*((then|do|else|elif|!)[[:space:]]+)*((bash|sh|zsh|source|\.|xargs)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?${NAME}([[:space:]]|\$)"
    SAFE="^[[:space:]]*((then|do|else|elif|!)[[:space:]]+)*((bash|sh|zsh|source|\.)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?${NAME}[[:space:]]+(list|candidates([[:space:]]+[0-9]+)?|remove([[:space:]]+${Q}[a-z0-9.-]+${Q})+)([[:space:]]+[12]?>>?[[:space:]]*[^[:space:]|;&]*)*[[:space:]]*${Q}\$"
    if [[ "$CMD" == *net-allowlist* || "$CMD" == *local-settings* ]] && {
       printf '%s\n' "$CMD" | grep -qE "net-allowlist(\.sh)?${Q}[[:space:]]+[^|;&]*\badd\b" \
       || printf '%s\n' "$CMD" | tr '|;&`(){}' '\n' | grep -E "$RUN" | grep -qvE "$SAFE" \
       || { printf '%s\n' "$CMD" | grep -q 'local-settings' \
            && printf '%s\n' "$CMD" | sed -E 's#[0-9]*>&[0-9-]##g; s#[0-9&]*>>?[[:space:]]*/dev/null##g' \
               | grep -qE '>|\b(tee|cp|mv|ln|rsync|dd|install|sponge|tar|unzip|curl|wget|mkfifo|mknod|python3?|node|ruby|perl|php|ex|ed|vim?|nvim)\b|\b(sed|g?awk)[[:space:]]+-[a-zA-Z]*i'; }; }; then
      emit_ask "This can change the machine-local network allowlist (~/.claude/local-settings); requests to a host it adds stop asking. Confirm the host."
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
    # --data-urlencode also reads a file in its name@file form; name=value@x is literal content.
    if printf '%s\n' "$CMD" | grep -qE '\b(curl|wget)\b[^|;&]*((-d|--data|--data-binary|--data-urlencode|--data-raw)(\s+|=)?@|--data-urlencode(\s+|=)["'"'"']?[^=@"'"'"'[:space:]]*@)'; then
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

    # A proxy or connection override sends the bytes somewhere other than the
    # URL's host, which is all the checks below look at. A proxy on this machine
    # or on a list is a hop and the URL still decides; any other proxy asks, and
    # so does every flag that reroutes the request or reads options from a file.
    CURLS=$(printf '%s\n' "$CMD" | grep -oE '\bcurl\b[^|;&]*')
    if printf '%s\n' "$CURLS" | grep -qE '\s(--connect-to|--resolve|--config|--unix-socket|--abstract-unix-socket|-[a-zA-Z]*K)(\s|=|$)'; then
      emit_ask "curl --connect-to, --resolve, --unix-socket or -K/--config decides where this request really goes, which the URL check cannot see. Confirm it."
      exit 0
    fi
    PROXIES=$( { printf '%s\n' "$CURLS" | grep -oE '\s(-[a-zA-Z]*x|--proxy|--preproxy|--socks4a?|--socks5(-hostname)?)(\s+|=)?[^[:space:]-][^[:space:]]*' \
                 | sed -E 's/^[[:space:]]*(-[a-zA-Z]*x|--[a-z0-9-]+)(=|[[:space:]]+)?//'
               printf '%s\n' "$CMD" | grep -oE '(^|[^A-Za-z0-9_])(https?_proxy|HTTPS?_PROXY|all_proxy|ALL_PROXY|ftp_proxy|FTP_PROXY)[[:space:]]*=[[:space:]]*[^[:space:];&|]+' \
                 | sed -E 's/^.*=[[:space:]]*//'; } | tr -d "\"'" )
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      [[ "$v" == *://* ]] || v="http://$v"
      PH=$(extract_host "$v")
      host_allowed "$PH" && continue
      emit_ask "curl/wget routes this request through ${PH:-an unparsed proxy}, which is on no allowlist, so the URL check does not cover where it goes. Confirm the proxy.$(add_hint "$PH")"
      exit 0
    done <<<"$PROXIES"

    # Every http(s) URL in the command: curl fetches each one, so checking only
    # the first let `curl <allowlisted> <anything>` through. A backslash is part
    # of the token: curl 8.7 reads 'https://github.com\@evil.example/' as user
    # `github.com\` at evil.example, and a token cut at the backslash said github.
    URLS=$(printf '%s\n' "$CMD" | grep -oE 'https?://[^[:space:]"'\''`]+' | awk '!seen[$0]++')
    URL=$(printf '%s\n' "$URLS" | head -1)
    HOST=$(extract_host "$URL")

    # Any request that sends a body → ask regardless of host. A body flag is a
    # POST even with no -X, so `curl -d "$(cat notes)" <allowlisted host>` was
    # a silent allow. This runs before the URL test: a URL with no scheme was
    # never parsed, and its POST went through unseen.
    BODY_RE='\bcurl\b[^|;&]*(-X\s*(POST|PUT|PATCH|DELETE)|--request\s*(POST|PUT|PATCH|DELETE)|\s(-d|--data[a-z-]*|--json|-F|--form[a-z-]*|-T|--upload-file)(\s|=|$))'
    # curl -G / --get turns -d/--data-* into the query string: a GET, so the host
    # test below decides. Judged per curl segment, so a second curl without -G
    # still asks. An explicit -X (bundled too: -sXPOST) or a non-data body flag
    # (-F, -T, --json) is still a write.
    SENDS=0
    while IFS= read -r seg; do
      [[ -z "$seg" ]] && continue
      printf '%s\n' "$seg" | grep -qE "$BODY_RE" || continue
      if printf '%s\n' "$seg" | grep -qE '\s(-[a-zA-Z]*G[a-zA-Z]*|--get)(\s|$)' \
         && ! printf '%s\n' "$seg" | grep -qE '\s(-[a-zA-Z]*X[a-zA-Z]*|--request)(\s|=|[A-Z])|\s(--json|-F|--form[a-z-]*|-T|--upload-file)(\s|=|$)'; then
        continue
      fi
      SENDS=1; break
    done < <(printf '%s\n' "$CMD" | grep -oE '\bcurl\b[^|;&]*')
    if [[ $SENDS -eq 1 ]] \
       || printf '%s\n' "$CMD" | grep -qE '\bwget\b[^|;&]*--(post-data|post-file|body-data|body-file|method)\b'; then
      emit_ask "curl/wget is sending data (POST/PUT/PATCH/DELETE or a request body) to ${HOST:-a host without a scheme}. Confirm the target and payload."
      exit 0
    fi

    if [[ -z "$URL" ]]; then
      # No scheme to parse. A bare host argument (`curl example.com/x`) still
      # makes a request, so ask; flags alone (`curl --version`) do not.
      # Anchored to a command boundary so `grep curl notes.md` is not a request.
      if printf '%s\n' "$CMD" | grep -qE '(^|[|&;`]|\$\()\s*(curl|wget)\s([^|;&]*\s)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/|\s|$)'; then
        # `curl 127.0.0.1:8090/x` is this machine too; every other bare host asks.
        BARE=$(printf '%s\n' "$CMD" | grep -oE '(^|\s)[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/[^[:space:]]*)?' | sed -E 's/^[[:space:]]+//')
        ALL_LOCAL=1
        while IFS= read -r b; do
          [[ -z "$b" ]] && continue
          is_loopback "$(extract_host "$b")" && ! local_admin_url "$b" || { ALL_LOCAL=0; break; }
        done <<<"$BARE"
        [[ $ALL_LOCAL -eq 1 ]] && exit 0
        emit_ask "curl/wget target has no http(s):// scheme, so its host could not be checked against the allowlist. Confirm the endpoint."
      fi
      exit 0
    fi

    # Read-only access to allowlisted hosts → allow silently; any other → ask.
    while IFS= read -r u; do
      [[ -z "$u" ]] && continue
      H=$(extract_host "$u")
      if is_loopback "$H" && local_admin_url "$u"; then
        emit_ask "curl/wget to $u on this machine looks like a local admin API (kubectl proxy, Docker, Vault or Kubernetes paths), which can return cluster or host credentials. Confirm this read."
        exit 0
      fi
      host_allowed "$H" || { emit_ask "curl/wget request to $H is outside the default allowlist. Confirm this endpoint is safe.$(add_hint "$H")"; exit 0; }
    done <<<"$URLS"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
