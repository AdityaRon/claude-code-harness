#!/usr/bin/env bash
# Recursive remove guard, replacing the Bash(rm -rf:*) deny rules: those matched
# one spelling and refused this session's own scratch folder. Catastrophic targets
# deny; rm -rf runs silently only when every target is in the scratch folder.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0
case "$CMD" in *rm*) ;; *) exit 0 ;; esac

SCRATCH=$(session_scratch)
# A command that sets the variables in_scratch trusts gets no scratch allowance.
if printf '%s\n' "$CMD" | grep -qE '(^|[^A-Za-z0-9_])(CLAUDE_JOB_DIR|HOME|TMPDIR)[[:space:]]*='; then
  SCRATCH=""; TMPDIR=""
fi
BASE=""
CWD=$(jq_get '.cwd')
[[ -n "$CWD" ]] && BASE=$(in_scratch "$CWD" "$SCRATCH" "") || BASE=""

# One segment per line, quoted separators kept as text.
SEGS=$(neutralize_quoted_separators "$(normalize_command "$CMD")" | tr '\n' ';' \
  | sed -E 's/\$\(/;/g; s/`/;/g; s/\|\||&&/;/g; s/[|;&]/\n/g')

NAMES=(); VALUES=()
lookup() {   # value of a simple NAME=value set earlier in this command
  local k
  for (( k=${#NAMES[@]}-1; k>=0; k-- )); do [[ "${NAMES[$k]}" == "$1" ]] && { printf '%s' "${VALUES[$k]}"; return 0; }; done
  return 1
}
expand_var() {   # $NAME/rest or ${NAME}/rest → value/rest, for names set above
  local t="$1" name rest v
  if [[ "$t" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/.*)?$ ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    v=$(lookup "$name") && { printf '%s%s' "$v" "$rest"; return; }
  fi
  printf '%s' "$t"
}

catastrophic() {
  local t="${1//\"/}"; t="${t//\'/}"; t="${t%/}"
  case "$t" in
    ''|'~'|'$HOME'|'${HOME}'|'.'|'..'|'*'|'./*'|'../*'|'~/*'|'$HOME/*'|'${HOME}/*'|'/*') return 0 ;;
  esac
  [[ "$t" =~ ^/[^/]*$ ]] && return 0          # / and every top-level folder
  [[ "$t" == "$HOME" || "$t" == "${HOME%/*}" ]] && return 0
  return 1
}

while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  [[ -z "$seg" ]] && continue
  set -f; set -- $seg; set +f
  [[ "$1" == export && $# -ge 2 ]] && shift
  if [[ $# -eq 1 && "$1" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    v="${BASH_REMATCH[2]}"; v="${v//\"/}"; v="${v//\'/}"
    NAMES+=("${BASH_REMATCH[1]}"); VALUES+=("$(expand_var "$v")")
    continue
  fi
  if [[ "$1" == cd ]]; then
    BASE=$(in_scratch "$(expand_var "${2:-}")" "$SCRATCH" "$BASE") || BASE=""
    continue
  fi
  [[ "$1" == rm ]] || continue
  shift
  rec=0; force=0; targets=(); opts=1
  for a in "$@"; do
    if [[ $opts -eq 1 && "$a" == -- ]]; then opts=0; continue; fi
    if [[ $opts -eq 1 && "$a" == --* ]]; then
      [[ "$a" == --recursive ]] && rec=1; [[ "$a" == --force ]] && force=1; continue
    fi
    if [[ $opts -eq 1 && "$a" == -?* ]]; then
      [[ "$a" == *[rR]* ]] && rec=1; [[ "$a" == *f* ]] && force=1; continue
    fi
    targets+=("$a")
  done
  [[ $rec -eq 1 ]] || continue
  for t in ${targets[@]+"${targets[@]}"}; do
    if catastrophic "$t"; then
      emit_deny "Blocked: recursive rm of $t would remove a home, root, top-level or whole-folder tree. Name what to remove, or ask the user to run it."
      exit 0
    fi
  done
  [[ $force -eq 1 ]] || continue
  ok=1
  [[ ${#targets[@]} -eq 0 ]] && ok=0
  for t in ${targets[@]+"${targets[@]}"}; do
    in_scratch "$(expand_var "$t")" "$SCRATCH" "$BASE" >/dev/null || { ok=0; break; }
  done
  if [[ $ok -eq 0 ]]; then
    if [[ -n "$SCRATCH" ]]; then
      emit_deny "Blocked: rm -rf outside this session's scratch folder (\$CLAUDE_JOB_DIR/tmp, where it runs freely). Remove files by name, or ask the user to run it."
    else
      emit_deny "Blocked: rm -rf with no session scratch folder to confine it. Remove files by name, or ask the user to run it."
    fi
    exit 0
  fi
done <<<"$SEGS"
exit 0
