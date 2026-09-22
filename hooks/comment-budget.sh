#!/usr/bin/env bash
# Pushes back on a long comment block the moment it lands, not at review time.
#
# A comment run that grows past ~6 lines is usually rationale that belongs in
# the PR body, not the file — and once it ships, nothing flags it again; the
# next reader just inherits the wall of text. This only compares the run
# length BEFORE and AFTER the edit, so touching a file that already carries a
# long block (inherited, not introduced) stays silent.
#
# Three work repos ship their own `.claude/hooks/comment-budget.py`, which
# also checks for ticket keys in comments — a check this copy cannot carry,
# because it ships in the PUBLIC harness and must never encode a work ticket
# prefix. Where a repo has its own copy, this hook steps aside so the same
# edit does not get flagged twice.
#
# Advisory only: PostToolUse, exit 2 feeds the note back to Claude while the
# edit is still hot, and never blocks the write.
source "$(dirname "$0")/lib.sh"

read_input
command -v jq &>/dev/null || exit 0     # advisory only; never fail a write
TOOL=$(jq_get '.tool_name')

case "$TOOL" in
  Edit|MultiEdit|Write) ;;
  *) exit 0 ;;
esac

FILE=$(jq_get '.tool_input.file_path')
[ -n "$FILE" ] || exit 0

# A repo that ships its own comment-budget.py owns this check for itself.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/.claude/hooks/comment-budget.py" ]; then
  exit 0
fi

case "${FILE##*.}" in
  py|ts|tsx|js|java|go|scala|sql|j2|sh|yaml|yml) ;;
  *) exit 0 ;;
esac

MAX_RUN=6

# Longest run of consecutive comment lines in stdin. A shebang line resets the
# run instead of extending it — `#!/usr/bin/env bash` is not a comment block.
longest_run() {
  awk '
    {
      trimmed = $0
      sub(/^[ \t]*/, "", trimmed)
      if (trimmed ~ /^#!/) { run = 0 }
      else if ($0 ~ /^[ \t]*(#|\/\/|--|\/\*|\*)/) { run++; if (run > best) best = run }
      else { run = 0 }
    }
    END { print best + 0 }
  '
}

FOUND=""

# check_pair <old_b64> <new_b64> — decodes both sides and flags OLD only when
# the new run is both over budget and longer than what was already there, so
# an untouched pre-existing block never fires.
check_pair() {
  local old new run_new run_old
  old=$(printf '%s' "$1" | base64 --decode 2>/dev/null)
  new=$(printf '%s' "$2" | base64 --decode 2>/dev/null)
  run_new=$(printf '%s\n' "$new" | longest_run)
  run_old=$(printf '%s\n' "$old" | longest_run)
  if [ "$run_new" -gt "$MAX_RUN" ] && [ "$run_new" -gt "$run_old" ]; then
    FOUND="$run_new"
  fi
}

case "$TOOL" in
  Edit)
    OLD_B64=$(printf '%s' "$INPUT" | jq -r '(.tool_input.old_string // "") | @base64')
    NEW_B64=$(printf '%s' "$INPUT" | jq -r '(.tool_input.new_string // "") | @base64')
    check_pair "$OLD_B64" "$NEW_B64"
    ;;
  Write)
    NEW_B64=$(printf '%s' "$INPUT" | jq -r '(.tool_input.content // "") | @base64')
    check_pair "" "$NEW_B64"
    ;;
  MultiEdit)
    # NUL/newline-unsafe fields go through base64 first — old_string/new_string
    # can hold anything, including the tab a bare @tsv would otherwise break on.
    while IFS=$'\t' read -r ob nb; do
      [ -z "$ob$nb" ] && continue
      check_pair "$ob" "$nb"
      [ -n "$FOUND" ] && break
    done < <(printf '%s' "$INPUT" | jq -r '.tool_input.edits[]? | [(.old_string // "" | @base64), (.new_string // "" | @base64)] | @tsv')
    ;;
esac

[ -n "$FOUND" ] || exit 0

printf '%s: added an %s-line comment block. Say only what the code cannot (trap, constraint, reason) and move the rationale to the PR body.\n' \
  "$FILE" "$FOUND" >&2
exit 2
