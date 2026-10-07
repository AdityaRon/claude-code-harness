#!/usr/bin/env bash
# This machine's network allowlist, in ~/.claude/local-settings/net-allowlist.json
# so installs keep it and this public repo never sees it. GETs only; a body still asks.
#   net-allowlist.sh list | candidates [DAYS] | add HOST... | remove HOST...
# Output names this machine's hosts: keep it local.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOOKS="$HERE/hooks"; [[ -f "$HOOKS/lib.sh" ]] || HOOKS="$HERE/../hooks"
source "$HOOKS/lib.sh"

DIR=$(expand_tilde "${CLAUDE_LOCAL_SETTINGS_DIR:-$HOME/.claude/local-settings}")
FILE="$DIR/net-allowlist.json"

usage() { sed -n '2,5s/^# \{0,1\}//p' "$0"; exit 2; }

# Same parse as network-guard's extract_host: the host curl connects to.
url_host() {
  sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[/?#].*$##; s#^.*@##; s#^(\[[^]]*\]).*$#\1#; s#:[0-9]*$##; s#^\[(.*)\]$#\1#' \
    | tr '[:upper:]' '[:lower:]'
}

# What network-guard decides for a plain GET to this host right now.
guard_says() {
  jq -nc --arg c "curl -s https://$1/" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | CLAUDE_AUDIT_LOG=/dev/null bash "$HOOKS/network-guard.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null | grep . || echo allow
}

cmd_list() {
  local f h why any=0
  for f in "$DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "  ⚠ $(basename "$f"): not JSON, so none of its hosts apply"; continue
    fi
    while IFS= read -r h; do
      any=1
      if why=$(net_host_problem "$h"); then
        printf '  %-40s %s\n' "$h" "$(basename "$f")"
      else
        printf '  ✗ %-38s %s: refused, %s\n' "$h" "$(basename "$f")" "$why"
      fi
    done < <(jq -r '.netAllowlist[]? | strings' "$f")
  done
  for h in ${CLAUDE_NET_ALLOWLIST:-}; do
    any=1
    why=$(net_host_problem "$h") && printf '  %-40s CLAUDE_NET_ALLOWLIST\n' "$h" \
      || printf '  ✗ %-38s CLAUDE_NET_ALLOWLIST: refused, %s\n' "$h" "$why"
  done
  [[ $any == 1 ]] || echo "  (none beyond network-guard's built-in list)"
}

cmd_candidates() {
  local days="${1:-30}" log since
  [[ "$days" =~ ^[0-9]+$ ]] || usage
  log=$(expand_tilde "${CLAUDE_AUDIT_LOG:-$HOME/.claude/logs/audit.log}")
  [[ -f "$log" ]] || { echo "no audit log at $log"; exit 1; }
  since=$(date -u -v-"${days}"d +%F 2>/dev/null || date -u -d "$days days ago" +%F)
  # One "host<TAB>get|body" line per URL in each ask. -G --data-urlencode counts
  # as body: network-guard asks on it today whatever the allowlist says. Audit
  # lines stop at 200 characters and keep shell variables, hence the host filter.
  local rows
  rows=$(grep -F '| GUARD | ask | network-guard |' "$log" | awk -v s="$since" 'substr($0,1,10) >= s' \
    | while IFS= read -r line; do
        kind=get
        printf '%s\n' "$line" | grep -qE '(-X *(POST|PUT|PATCH|DELETE)|--request *(POST|PUT|PATCH|DELETE)|[[:space:]](-d|--data[a-z-]*|--json|-F|--form[a-z-]*|-T|--upload-file)([[:space:]]|=|$))' && kind=body
        printf '%s\n' "$line" | grep -oE 'https?://[^][:space:]"'\''`|<>]+' | url_host \
          | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' | sort -u | sed "s/\$/	$kind/"
      done)
  [[ -n "$rows" ]] || { echo "no network-guard asks with a URL since $since"; return 0; }
  echo "network-guard asks since $since, by host (GET asks are what an entry removes):"
  printf '  %4s %4s  %-40s %s\n' GET BODY HOST NOW
  printf '%s\n' "$rows" | awk -F'\t' '{t[$1]++; if ($2=="get") g[$1]++; else b[$1]++}
      END {for (h in t) printf "%d\t%d\t%d\t%s\n", t[h], g[h], b[h], h}' | sort -t$'\t' -k1,1nr -k4 \
    | while IFS=$'\t' read -r _ g b h; do
        if printf '%s' "$h" | grep -qE '^(localhost|::1|0\.0\.0\.0|127\.[0-9.]+)$'; then
          now="this machine (GETs allowed)"
        elif [[ "$(guard_says "$h")" == allow ]]; then
          now="allowed now"
        elif why=$(net_host_problem "$h"); then
          now="asks; add with: net-allowlist.sh add $h"
        else
          now="asks; refused as an entry: $why"
        fi
        printf '  %4d %4d  %-40s %s\n' "$g" "$b" "$h" "$now"
      done
}

cmd_add() {
  [[ $# -gt 0 ]] || usage
  local h why rc=0 add=()
  for h in "$@"; do
    h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]'); h=${h%.}
    if why=$(net_host_problem "$h"); then add+=("$h"); else echo "  ✗ $h refused: $why"; rc=1; fi
  done
  [[ ${#add[@]} -gt 0 ]] || return $rc
  if [[ -f "$FILE" ]] && ! jq -e . "$FILE" >/dev/null 2>&1; then
    echo "  ✗ $FILE is not JSON; fix it by hand first"; return 1
  fi
  mkdir -p "$DIR"
  local cur='{}'; [[ -f "$FILE" ]] && cur=$(cat "$FILE")
  printf '%s' "$cur" | jq --args '.netAllowlist = ((.netAllowlist // []) + $ARGS.positional | unique)' "${add[@]}" \
    > "$FILE.part.$$" && mv -f "$FILE.part.$$" "$FILE" || { rm -f "$FILE.part.$$"; return 1; }
  for h in "${add[@]}"; do echo "  ✓ $h (and its subdomains)"; done
  return $rc
}

cmd_remove() {
  [[ $# -gt 0 ]] || usage
  [[ -f "$FILE" ]] || { echo "  nothing in $FILE"; return 1; }
  jq -e . "$FILE" >/dev/null 2>&1 || { echo "  ✗ $FILE is not JSON; fix it by hand first"; return 1; }
  local h f
  jq --args '.netAllowlist = ((.netAllowlist // []) - $ARGS.positional)' "$@" < "$FILE" \
    > "$FILE.part.$$" && mv -f "$FILE.part.$$" "$FILE" || { rm -f "$FILE.part.$$"; return 1; }
  for h in "$@"; do
    echo "  ✓ $h removed from $(basename "$FILE")"
    for f in "$DIR"/*.json; do
      [[ "$f" == "$FILE" ]] && continue
      jq -e --arg h "$h" '(.netAllowlist // []) | index($h)' "$f" >/dev/null 2>&1 \
        && echo "    still listed in $(basename "$f")"
    done
  done
  return 0
}

case "${1:-}" in
  list)       cmd_list ;;
  candidates) shift; cmd_candidates "$@" ;;
  add)        shift; cmd_add "$@" ;;
  remove)     shift; cmd_remove "$@" ;;
  *)          usage ;;
esac
