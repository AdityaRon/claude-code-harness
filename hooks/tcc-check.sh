#!/usr/bin/env bash
# Names the cause when a Bash call hits "Operation not permitted" under
# ~/Desktop, ~/Documents, ~/Downloads or iCloud Drive: macOS privacy control
# (TCC), usually a session host whose binary an upgrade deleted (lib.sh
# host_binary_check), never file modes or the harness sandbox. Advisory,
# synchronous: exit 2 with stderr is what reaches the model.
source "$(dirname "$0")/lib.sh"

# PostToolUse sees a call that exited 0 (a denial in a pipeline or before ||);
# PostToolUseFailure sees the rest. Claude Code puts the output, stderr merged
# in, in .tool_response.stdout or in .error after "Exit code N". Every Bash call
# passes through; the common path is one substring test on the raw payload.
read_input
case "$INPUT" in *[Oo]"peration not permitted"*) ;; *) exit 0 ;; esac
command -v jq &>/dev/null || exit 0
OUT=$(printf '%s\n' "$INPUT" | jq -r '((.tool_name, .cwd, .tool_input.command) | if type == "string" then gsub("\n"; " ") else "" end),
  (.error | strings), (.tool_response | if type == "object" then .stdout, .stderr else . end | strings)' 2>/dev/null)
{ IFS= read -r TOOL; IFS= read -r CWD; IFS= read -r CMDLINE; REST=$(cat); } <<< "$OUT"
[[ "$TOOL" == Bash ]] || exit 0

# Only a line shaped like the error, as each tool prints it: `x: Operation not
# permitted` (BSD tools, bash, git, Go lower-case, Rust's "(os error 1)"),
# zsh's `(eval):1: operation not permitted: x`, python's PermissionError, node's
# EPERM. A line quoting one (in backticks, in a PR body) is not one.
SHAPE='(: |\] )[Oo]peration not permitted( \(os error 1\))?[[:space:]]*$|^(\(eval\)|zsh)(:[A-Za-z_]+)?(:[0-9]+)?: operation not permitted: |^(PermissionError|OSError): \[Errno 1\] Operation not permitted|(^|Error: |\[Error: )EPERM: operation not permitted, '
LINES=$(printf '%s\n' "$REST" | grep -E -- "$SHAPE")
[[ -n "$LINES" ]] || exit 0

HRAW=${HOME%/}; H=$HRAW
FOLDERS=(Desktop Documents Downloads "Library/Mobile Documents")
ALT=$(IFS='|'; printf '%s' "${FOLDERS[*]}")
ABS="(^|[[:space:]'\"(=])(/|~/)"
GREPPED='^[^[:space:]:()]+:[0-9]+:'   # file:line: as grep -n prints it
under() {   # is the path $1 in a protected folder?
  local f
  for f in "${FOLDERS[@]}"; do [[ "$1" == "$H/$f" || "$1" == "$H/$f/"* ]] && return 0; done
  return 1
}
resolve() {   # $1 against the folder $2: ~ and $HOME expanded, . and .. folded
  local p=$1 seg out=() segs
  case $p in \~|\~/*) p=$H${p#\~} ;; '$HOME'|'$HOME/'*) p=$H${p#\$HOME} ;; /*) ;; *) p=$2/$p ;; esac
  IFS=/ read -ra segs <<< "$p"
  for seg in "${segs[@]}"; do
    case $seg in ''|.) ;; ..) ((${#out[@]})) && unset 'out[${#out[@]}-1]' ;; *) out+=("$seg") ;; esac
  done
  printf '/%s' "${out[@]}"
}
H=$(resolve "$HRAW" /)   # folded, as resolve folds every path it compares
# The folders the command's own `cd`s go to: an error naming no absolute path
# (getcwd, a relative name) is judged from there too, not only from the cwd.
BASES=("$(resolve "$CWD" /)")
while IFS= read -r t; do
  [[ -n "$t" ]] && BASES+=("$(resolve "${t//[\"\']/}" "$CWD")")
done < <(printf '%s\n' "$CMDLINE" | grep -oE "(^|[;&|(]|then|do)[[:space:]]*cd[[:space:]]+[^;&|)[:space:]]+" | sed -E 's/.*cd[[:space:]]+//')
names() {   # does the line $1 name a path in a protected folder, absolute or from a base?
  local f t b
  for f in "${FOLDERS[@]}"; do
    [[ "$1" == *"$HRAW/$f" || "$1" == *"$HRAW/$f"[/:\'\"[:space:]]* ]] && return 0
  done
  while IFS= read -r t; do
    for b in "${BASES[@]}"; do under "$(resolve "$t" "$b")" && return 0; done
  done < <(printf '%s\n' "$1" | grep -oE "[^[:space:]'\"\`]*($ALT)[^[:space:]'\"\`:]*")
  return 1
}
HIT=""
while IFS= read -r l; do
  [[ "$l" =~ $GREPPED && ! "$l" =~ ^(zsh|bash|sh):[0-9]+: ]] && continue
  if names "$l"; then HIT=$l; break; fi
  [[ "$l" =~ $ABS ]] && continue
  for b in "${BASES[@]}"; do under "$b" && { HIT=$l; break 2; }; done
done <<< "$LINES"
[[ -n "$HIT" ]] || exit 0

{
  echo "tcc-check: 'Operation not permitted' under ~/Desktop, ~/Documents, ~/Downloads or iCloud Drive is macOS privacy control (TCC), not file modes and not the harness sandbox."
  echo "From: $(printf '%s' "$HIT" | head_utf8 300)"
  if ! host_binary_check; then :
  else
    echo "This session's host binary exists, so the folder was never granted to it, or the grant was revoked: System Settings > Privacy & Security > Files and Folders, or run the command from a terminal session. A clone outside those folders is unaffected: ~/.claude/relocate-clones.sh moves one."
  fi
} >&2
exit 2
