#!/usr/bin/env bash
# What an install changed since the commit the last one recorded, grouped by how
# a running session picks it up. install.sh runs it; it reads the clone only.
#   tools/pickup-report.sh PREV_COMMIT [REPO]
set -u
PREV=${1:-}
REPO=${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
[[ -n "$PREV" && "$PREV" != unknown ]] || exit 0
if ! git -C "$REPO" cat-file -e "$PREV^{commit}" 2>/dev/null; then
  echo "  ℹ the last install was at ${PREV:0:12}, which this clone does not have; after a fetch: tools/pickup-report.sh ${PREV:0:12}"
  exit 0
fi
# The last install's commit against the working tree, as install copies it, and
# files not yet committed.
FILES=$({ git -C "$REPO" diff --name-only "$PREV" --; git -C "$REPO" ls-files --others --exclude-standard; } 2>/dev/null | sort -u)

LIVE="" RULES="" TOOLS="" PANEL="" SKILLS=""
while IFS= read -r f; do
  case "$f" in
    hooks/*|config/settings.json|config/merge-settings.jq|config/retired-rules.json) LIVE="$LIVE  $f" ;;
    rules/*.md) RULES="$RULES  $f" ;;
    bin/*) TOOLS="$TOOLS  $f" ;;
    skills/*/panel/.claude-plugin/*|skills/*/panel/hooks/*|skills/*/panel/types/*) PANEL="$PANEL  $f" ;;
    skills/*/SKILL.md|skills/*/bin/*|skills/*/*.example.toml|skills/*/templates/*)
      s=${f#skills/}; s=${s%%/*}
      case " $SKILLS " in *" /$s "*) ;; *) SKILLS="$SKILLS /$s" ;; esac ;;
  esac
done <<< "$FILES"

if [[ -z "$LIVE$RULES$TOOLS$PANEL$SKILLS" ]]; then
  echo "  ✓ nothing installed changed since ${PREV:0:12}"
  exit 0
fi
echo "How running sessions pick up what changed since ${PREV:0:12}:"
[[ -n "$LIVE" ]] && echo "  Hooks and settings, on each session's next tool call:$LIVE"
[[ -n "$RULES" ]] && echo "  Rules, when a session starts or resumes:$RULES"
[[ -n "$TOOLS" ]] && echo "  Tools in ~/.claude, on their next run:$TOOLS"
[[ -n "$SKILLS" ]] && echo "  Skills, when a running session calls them again:$SKILLS"
[[ -n "$PANEL" ]] && echo "  A panel, when the session that shows it restarts: type \`! claude respawn <job>\` at your own prompt (from another session the auto-mode classifier denies it):$PANEL"
exit 0
