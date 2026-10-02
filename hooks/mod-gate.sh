#!/usr/bin/env bash
# Reviews a mod as Claude writes it: denies hooks that override permission
# decisions, and shows the person what else it hooks and calls. Uses
# `claude plugin validate`, the static analysis Claude Code itself loads mods by.

INPUT=$(cat)
# Every Write and Edit lands here: decide on the raw text, without a fork, that
# this cannot be a mod file before paying for jq.
[[ "$INPUT" =~ \.(js|mjs|cjs|jsx|ts|mts|cts|tsx)\" || "$INPUT" =~ (plugin|hooks)\.json\" ]] || exit 0

source "$(dirname "$0")/lib.sh"
export INPUT
require_jq_or_deny
require_parsable_or_deny

FILE=$(expand_tilde "$(jq_get '.tool_input.file_path')")
[[ -z "$FILE" ]] && exit 0
case "$FILE" in /*) ;; *) FILE="$PWD/$FILE" ;; esac

# The mod is the nearest directory above the file with a manifest. None yet:
# nothing can load, and the manifest's own write will be reviewed instead.
ROOT=""
d=$(dirname "$FILE")
for _ in 1 2 3 4 5 6; do
  if [[ -f "$d/.claude-plugin/plugin.json" ]]; then ROOT="$d"; break; fi
  [[ "$FILE" == "$d/.claude-plugin/plugin.json" ]] && { ROOT="$d"; break; }
  [[ "$d" == "/" ]] && break
  d=$(dirname "$d")
done
[[ -z "$ROOT" ]] && exit 0
# Mods need Claude Code 2.1.287; without the CLI there is nothing to load them.
CLAUDE_BIN=${CLAUDE_MOD_GATE_CLI:-$(command -v claude)}
[[ -z "$CLAUDE_BIN" ]] && exit 0

# Review the mod as it will be after this write, in a scratch copy.
WORK=$(mktemp -d) || exit 0
trap 'rm -rf "$WORK"' EXIT
cp -R "$ROOT/." "$WORK/" 2>/dev/null
REL="${FILE#"$ROOT"/}"
TARGET="$WORK/$REL"
mkdir -p "$(dirname "$TARGET")"
TOOL=$(jq_get '.tool_name')
case "$TOOL" in
  Write)
    printf '%s' "$INPUT" | jq -j '.tool_input.content // .tool_input.file_text // .tool_input.file_content // ""' > "$TARGET" ;;
  Edit|MultiEdit)
    [[ -f "$TARGET" ]] || : > "$TARGET"
    # Literal replacement: split/join, never a regex built from Claude's text.
    jq -Rsj --argjson in "$INPUT" '
      def apply($o; $n; $all):
        if $o == "" then . else
          split($o) as $p
          | if ($p | length) < 2 then .
            elif $all then $p | join($n)
            else $p[0] + $n + ($p[1:] | join($o)) end
        end;
      reduce ($in.tool_input | if .edits then .edits[] else . end) as $e
        (.; apply($e.old_string // ""; $e.new_string // ""; $e.replace_all // false))
    ' "$TARGET" > "$TARGET.new" 2>/dev/null && mv "$TARGET.new" "$TARGET" ;;
  *) exit 0 ;;
esac

REPORT=$(cd "$WORK" && "$CLAUDE_BIN" plugin validate --json "$WORK" 2>/dev/null)
NOTES=$(printf '%s' "$REPORT" | jq -r '[.contents[]?.notes[]?] | .[]' 2>/dev/null)
HOOKS=$(printf '%s\n' "$NOTES" | sed -n 's/^.*hooks: //p' | sed 's/{[^}]*}//g' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u)
CALLS=$(printf '%s\n' "$NOTES" | sed -n 's/^.*calls: //p' | tr ',' '\n' | sed 's/ (via [^)]*)//; s/^ *//; s/ *$//' | grep '^\$' | sort -u)
NAME=$(jq -r '.name // empty' "$WORK/.claude-plugin/plugin.json" 2>/dev/null); NAME=${NAME:-${ROOT##*/}}

# These replace or reshape permission decisions; nothing a pane, a command or a
# counter needs. tool.call stays allowed: counting and answering look the same
# to static analysis, so it is shown below instead.
OVERRIDE=$(printf '%s\n' "$HOOKS" | grep -xE 'tool\.check|classic\.PreToolUse|classic\.PermissionRequest|plugin\.register|engine\.create' | paste -sd, - | sed 's/,/, /g')
if [[ -n "$OVERRIDE" ]]; then
  emit_deny "Blocked: mod '$NAME' hooks $OVERRIDE, which can approve tool calls this harness's guards or deny rules refuse. Rewrite it without those hooks; if you really need one, write the mod yourself and load it with claude --plugin-dir."
  exit 0
fi

if [[ "$(printf '%s' "$REPORT" | jq -r '.success | tostring' 2>/dev/null)" == "false" ]]; then
  MSG="Mod '$NAME' fails claude plugin validate as written, so Claude Code will not load it yet."
elif [[ -n "$HOOKS$CALLS" ]]; then
  RISKY=$(printf '%s\n' "$CALLS" | grep -E '^\$\.(process|http|fs\.write|env|prompt\.submit|session\.(send|authorize)|tool\.call|model)' | paste -sd, - | sed 's/,/, /g')
  MSG="Mod '$NAME' will hook: $(printf '%s' "$HOOKS" | paste -sd, - | sed 's/,/, /g')."
  [[ -n "$CALLS" ]] && MSG="$MSG It calls: $(printf '%s' "$CALLS" | paste -sd, - | sed 's/,/, /g')."
  [[ -n "$RISKY" ]] && MSG="$MSG Outside the guards: $RISKY run with your permissions and no PreToolUse check."
  printf '%s\n' "$HOOKS" | grep -qx 'tool\.call' && MSG="$MSG It hooks tool.call, which can answer a call itself so the guards never run; read that hook before enabling."
else
  exit 0
fi
log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) | MOD | review | $NAME | $FILE"
jq -nc --arg m "$MSG" '{systemMessage: $m}'
