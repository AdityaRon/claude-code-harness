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
CLAUDE_DIR="$HOME/.claude"
CLAUDE_REAL=$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P)

# Where install puts F under ~/.claude (REL), and how a session picks it up (G);
# fails for a file install does not copy. In a case pattern * matches / too, so
# each pattern is held to install's depth by the number of slashes.
map() {  # F
  local n=${1//[^\/]/}; n=${#n}
  case "$n:$1" in
    1:hooks/*.sh|2:hooks/lib/*.sh|1:config/settings.json|1:config/merge-settings.jq|1:config/retired-rules.json) G=LIVE ;;
    1:rules/*.md) G=RULES ;;
    1:bin/*) G=TOOLS ;;
    4:skills/*/panel/.claude-plugin/plugin.json|4:skills/*/panel/hooks/*|4:skills/*/panel/types/*) G=PANEL ;;
    2:skills/*/SKILL.md|2:skills/*/*.example.toml|3:skills/*/bin/*) G=SKILL ;;
    *) [[ "$1" == skills/* && "${1#skills/*/}" == templates/* ]] || return 1; G=SKILL ;;
  esac
  REL=$1
  if [[ "$G" == TOOLS ]]; then REL=${1#bin/}; fi
  return 0
}

# What this install writes, matched without case: on a disk that ignores case,
# the old name of a file renamed only in case is the copy just written.
WRITES=$(git -C "$REPO" ls-files -co --exclude-standard 2>/dev/null \
         | while IFS= read -r p; do [[ -f "$REPO/$p" ]] && map "$p" && printf '%s\n' "$REL"; done)
# A harness inside another repo would read that repo's history as its own.
TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) && TOP=$(cd "$TOP" && pwd -P)
OWN=""; [[ -n "$TOP" && "$TOP" == "$(cd "$REPO" && pwd -P)" ]] && OWN=1
COMMITTED=$(git -C "$REPO" diff --no-renames --name-only --diff-filter=D "$PREV" HEAD -- 2>/dev/null)

refs() {  # BASE DEST: each place that names BASE, DEST aside
  local s C=$CLAUDE_DIR
  { for s in "$C/settings.json" "$C/settings.local.json" "$HOME/.claude.json" "$HOME"/Library/LaunchAgents/*.plist; do
      if [[ -f "$s" ]] && grep -qF -- "$1" "$s"; then printf '%s\n' "$s"; fi
    done
    find -H "$C" \( -path "$C/projects" -o -path "$C/logs" -o -path "$C/jobs" -o -path "$C/state" -o -path "$C/todos" \
                    -o -path "$C/shell-snapshots" \) -prune \
         -o -type f \( -name '*.sh' -o -name '*.py' -o -name '*.md' -o -name '*.toml' \) -print0 2>/dev/null \
      | xargs -0 grep -lF -- "$1" 2>/dev/null
    if crontab -l 2>/dev/null | grep -qF -- "$1"; then echo crontab; fi
  } | grep -vxF -- "$2" | sort -u
}

# Why DEST, the installed copy of F, is kept; empty when it may go.
prune_why() {  # F REL DEST
  local p
  if [[ -z "$PREV" || "$PREV" == unknown ]] || ! git -C "$REPO" cat-file -e "$PREV^{commit}" 2>/dev/null; then
    echo "previous install unknown"
  elif [[ -z "$OWN" ]]; then
    echo "the harness is not its own git repo"
  elif ! git -C "$REPO" merge-base --is-ancestor "$PREV" HEAD 2>/dev/null; then
    echo "the clone is not ahead of the last install"
  elif ! grep -qxF -- "$1" <<< "$COMMITTED"; then
    echo "deleted only in the working tree"
  elif p=$(grep -ixF -- "$2" <<< "$WRITES" | head -1); [[ -n "$p" ]]; then
    echo "this install writes $p"
  elif p=$(cd "$(dirname "$3")" 2>/dev/null && pwd -P); [[ -z "$p" || -z "$CLAUDE_REAL" || ( "$p" != "$CLAUDE_REAL" && "$p" != "$CLAUDE_REAL"/* ) ]]; then
    echo "outside ~/.claude through a symlink"
  elif [[ ! -f "$3" || -L "$3" ]]; then
    echo "not the plain file install wrote"
  elif [[ "$(git -C "$REPO" hash-object --no-filters -- "$3" 2>/dev/null)" != "$(git -C "$REPO" rev-parse -q --verify "$PREV:$1" 2>/dev/null)" ]]; then
    echo "edited since install"
  elif p=$(refs "$(basename "$3")" "$3"); [[ -n "$p" ]]; then
    printf 'named in %s\n' "$(awk 'NR<=3 { printf "%s%s", (NR>1 ? ", " : ""), $0 } END { if (NR>3) printf " and %d more", NR-3 }' <<< "$p")"
  fi
}

# The last install's commit against the working tree, as install copies it, and
# files not yet committed, each with its status so a deleted file is told apart.
TAB=$'\t'
CHANGES=$({ git -C "$REPO" diff --no-renames --name-status "$PREV" --
            git -C "$REPO" ls-files --others --exclude-standard | awk '{ print "A\t" $0 }'; } 2>/dev/null \
          | sort -t "$TAB" -k2,2 -u)

LIVE="" RULES="" TOOLS="" PANEL="" SKILLS="" GONE="" REMOVED="" DOOMED=""
while IFS=$TAB read -r st f; do
  [[ -n "${f:-}" ]] || continue
  map "$f" || continue
  # A file gone from the clone stays where an earlier install put it, unless
  # --prune removes it. templates/ is swapped whole; config/ is merged.
  if [[ "$st" == D && "$f" != skills/*/templates/* && "$f" != config/* ]]; then
    dest="$CLAUDE_DIR/$REL"
    # Nothing there to keep or remove: no install wrote it, or it is gone already.
    [[ -e "$dest" || -L "$dest" ]] || continue
    w=$(grep -ixF -- "$REL" <<< "$WRITES" | head -1)
    [[ -n "$w" && "$dest" -ef "$CLAUDE_DIR/$w" ]] && continue
    if [[ -z "$PRUNE" ]]; then
      GONE="$GONE  $dest"
    else
      why=$(prune_why "$f" "$REL" "$dest")
      if [[ -z "$why" ]]; then DOOMED="$DOOMED$dest"$'\n'; else GONE="$GONE  $dest ($why)"; fi
    fi
    continue
  fi
  case "$G" in
    LIVE) LIVE="$LIVE  $f" ;;
    RULES) RULES="$RULES  $f" ;;
    TOOLS) TOOLS="$TOOLS  $f" ;;
    PANEL) PANEL="$PANEL  $f" ;;
    SKILL) s=${f#skills/}; s=${s%%/*}
           case " $SKILLS " in *" /$s "*) ;; *) SKILLS="$SKILLS /$s" ;; esac ;;
  esac
done <<< "$CHANGES"
# Removed only once every candidate is decided, so a file one of them names is
# kept whatever the order, even when the file naming it goes.
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  if rm -f -- "$d"; then REMOVED="$REMOVED  $d"; else GONE="$GONE  $d (could not remove)"; fi
done <<< "$DOOMED"

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
