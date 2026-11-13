#!/usr/bin/env bash
# What an install changed since the commit the last one recorded, grouped by how
# a running session picks it up. install.sh runs it with --prune, which removes
# what prune_why allows; without it, it reads the clone only.
#   tools/pickup-report.sh [--prune] PREV_COMMIT [REPO]
set -u
PRUNE=""
if [[ "${1:-}" == --prune ]]; then PRUNE=1; shift; fi
PREV=${1:-}
REPO=${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
[[ -n "$PREV" && "$PREV" != unknown ]] || exit 0
if ! git -C "$REPO" cat-file -e "$PREV^{commit}" 2>/dev/null; then
  echo "  ℹ the last install was at ${PREV:0:12}, which this clone does not have$([[ -n "$PRUNE" ]] && echo ", so nothing deleted from the clone was removed (previous install unknown)"); after a fetch: tools/pickup-report.sh ${PREV:0:12}"
  exit 0
fi

# Why DEST, the installed copy of F, is kept; empty when it may go. Bytes equal
# to F's blob at PREV mean install wrote it and nothing edited it since.
SETTINGS="$HOME/.claude/settings.json"
prune_why() {  # F REL DEST
  if [[ -z "$PREV" || "$PREV" == unknown ]] || ! git -C "$REPO" cat-file -e "$PREV^{commit}" 2>/dev/null; then
    echo "previous install unknown"
  elif [[ ! -f "$3" || -L "$3" ]] \
       || [[ "$(git -C "$REPO" hash-object --no-filters -- "$3" 2>/dev/null)" != "$(git -C "$REPO" rev-parse -q --verify "$PREV:$1" 2>/dev/null)" ]]; then
    echo "edited since install"
  elif grep -qsF -- ".claude/$2" "$SETTINGS"; then
    echo "settings.json refers to it"
  fi
}

# The last install's commit against the working tree, as install copies it, and
# files not yet committed, each with its status so a deleted file is told apart.
TAB=$'\t'
CHANGES=$({ git -C "$REPO" diff --no-renames --name-status "$PREV" --
            git -C "$REPO" ls-files --others --exclude-standard | awk '{ print "A\t" $0 }'; } 2>/dev/null \
          | sort -t "$TAB" -k2,2 -u)

LIVE="" RULES="" TOOLS="" PANEL="" SKILLS="" GONE="" REMOVED=""
while IFS=$TAB read -r st f; do
  [[ -n "${f:-}" ]] || continue
  # In a case pattern * matches / too, so each pattern is held to the depth
  # install copies at by the number of slashes in the path.
  n=${f//[^\/]/}; n=${#n}
  case "$n:$f" in
    1:hooks/*.sh|2:hooks/lib/*.sh|1:config/settings.json|1:config/merge-settings.jq|1:config/retired-rules.json) g=LIVE ;;
    1:rules/*.md) g=RULES ;;
    1:bin/*) g=TOOLS ;;
    4:skills/*/panel/.claude-plugin/plugin.json|4:skills/*/panel/hooks/*|4:skills/*/panel/types/*) g=PANEL ;;
    2:skills/*/SKILL.md|2:skills/*/*.example.toml|3:skills/*/bin/*) g=SKILL ;;
    *) [[ "$f" == skills/* && "${f#skills/*/}" == templates/* ]] || continue; g=SKILL ;;
  esac
  # A file gone from the clone stays where an earlier install put it, unless
  # --prune removes it. templates/ is swapped whole; config/ is merged.
  if [[ "$st" == D && "$f" != skills/*/templates/* && "$f" != config/* ]]; then
    rel=$f; [[ "$g" == TOOLS ]] && rel=${f#bin/}
    dest="$HOME/.claude/$rel"
    # Nothing there to keep or remove: no install wrote it, or it is gone already.
    [[ -e "$dest" || -L "$dest" ]] || continue
    # Still in the clone under that name: on a case-insensitive disk, a file
    # renamed only in case, whose installed copy is the new one.
    [[ -e "$REPO/$f" ]] && continue
    if [[ -z "$PRUNE" ]]; then
      GONE="$GONE  $dest"
    else
      why=$(prune_why "$f" "$rel" "$dest")
      if [[ -z "$why" ]] && rm -f -- "$dest"; then REMOVED="$REMOVED  $dest"; else GONE="$GONE  $dest (${why:-could not remove})"; fi
    fi
    continue
  fi
  case "$g" in
    LIVE) LIVE="$LIVE  $f" ;;
    RULES) RULES="$RULES  $f" ;;
    TOOLS) TOOLS="$TOOLS  $f" ;;
    PANEL) PANEL="$PANEL  $f" ;;
    SKILL) s=${f#skills/}; s=${s%%/*}
           case " $SKILLS " in *" /$s "*) ;; *) SKILLS="$SKILLS /$s" ;; esac ;;
  esac
done <<< "$CHANGES"

if [[ -z "$LIVE$RULES$TOOLS$PANEL$SKILLS$GONE$REMOVED" ]]; then
  echo "  ✓ nothing installed changed since ${PREV:0:12}"
  exit 0
fi
echo "How running sessions pick up what changed since ${PREV:0:12}:"
[[ -n "$LIVE" ]] && echo "  Hooks and settings, on each session's next tool call:$LIVE"
[[ -n "$RULES" ]] && echo "  Rules, when a session starts or resumes:$RULES"
[[ -n "$TOOLS" ]] && echo "  Tools in ~/.claude, on their next run:$TOOLS"
[[ -n "$SKILLS" ]] && echo "  Skills, when a running session calls them again:$SKILLS"
[[ -n "$PANEL" ]] && echo "  A panel, when the session that shows it restarts: type \`! claude respawn <job>\` at your own prompt (from another session the auto-mode classifier denies it):$PANEL"
[[ -n "$REMOVED" ]] && echo "  Deleted from the clone, and removed here because install wrote it and nothing changed it (each is in git at ${PREV:0:12}):$REMOVED"
[[ -n "$GONE" ]] && echo "  Deleted from the clone; the earlier copy stays until removed by hand:$GONE"
exit 0
