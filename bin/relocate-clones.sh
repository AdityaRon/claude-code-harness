#!/usr/bin/env bash
# Moves git clones out of ~/Desktop, ~/Documents and ~/Downloads, where a
# background session loses access after a Claude Code upgrade
# (docs/known-limitations.md). Dry run unless --apply; every action is printed.
#   relocate-clones.sh [--apply] [--to DIR] SRC...                      DIR: ~/code
#   relocate-clones.sh [--apply] --launch-dir DIR [--memory-from SRC]   SRC: ~/Desktop
set -uo pipefail

# Per SRC: refuses while a process has its cwd inside it (lsof); moves it to
# DIR/<name>; runs `git worktree repair` for every repo inside, with the new
# paths of the worktrees that moved with it; renames the ~/.claude/projects
# records of SRC and of every directory under it, refusing when a target record
# exists. Nothing moves until every source checks. --launch-dir links
# ~/.claude/projects/<DIR slug>/memory to SRC's record: one memory, two launch paths.
PROJECTS=${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}
APPLY=0 TO="$HOME/code" LAUNCH="" MEMFROM="$HOME/Desktop" SRCS=()

usage() { sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --to) TO=${2:?--to needs DIR}; shift 2 ;;
    --launch-dir) LAUNCH=${2:?--launch-dir needs DIR}; shift 2 ;;
    --memory-from) MEMFROM=${2:?--memory-from needs DIR}; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) SRCS+=("$1"); shift ;;
  esac
done

# The record slug is the launch path with every non-alphanumeric a dash, as
# Claude Code and session-start.sh form it. Paths are taken as given, not
# resolved: a session's record carries the path it was launched with.
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
abs() { local p=${1/#\~/$HOME}; [[ "$p" == /* ]] || p="$PWD/$p"; p=${p%/}; printf '%s' "$p"; }
act() { if [[ $APPLY == 1 ]]; then printf '%s\n' "$*"; else printf 'would %s\n' "$*"; fi; }
refuse() { echo "refuse: $*" >&2; FAILED=1; }
FAILED=0

# --- --launch-dir: one memory for two launch paths ----------------------------
if [[ -n "$LAUNCH" ]]; then
  [[ ${#SRCS[@]} -eq 0 ]] || { echo "--launch-dir takes no SRC" >&2; usage; }
  L=$(abs "$LAUNCH"); M=$(abs "$MEMFROM"); MSLUG=$(slug "$M")
  FROM="$PROJECTS/$MSLUG/memory"; DIR="$PROJECTS/$(slug "$L")"; LINK="$DIR/memory"; REL="../$MSLUG/memory"
  [[ -d "$FROM" ]] || { refuse "no memory store at $FROM"; exit 1; }
  if [[ -L "$LINK" ]]; then
    [[ "$(readlink "$LINK")" == "$REL" ]] && { echo "already linked: $LINK -> $REL"; exit 0; }
    refuse "$LINK is a link elsewhere: $(readlink "$LINK")"; exit 1
  fi
  [[ -e "$LINK" ]] && { refuse "$LINK exists; merge it into $FROM by hand first"; exit 1; }
  act "mkdir -p $DIR"; act "ln -s $REL $LINK"
  [[ $APPLY == 1 ]] || exit 0
  mkdir -p "$DIR" && ln -s "$REL" "$LINK" && echo "sessions started in $L now share the memory of $M" || exit 1
  exit 0
fi

# --- plan: every source checks before anything moves --------------------------
[[ ${#SRCS[@]} -gt 0 ]] || usage
TO=$(abs "$TO")
command -v lsof >/dev/null || { echo "lsof is needed to see which processes sit inside a source" >&2; exit 1; }
CWDS=$(lsof -Fpn -d cwd 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }')
MOVES=() RENAMES=()
for raw in "${SRCS[@]}"; do
  SRC=$(abs "$raw"); DEST="$TO/${SRC##*/}"
  [[ -d "$SRC" ]] || { refuse "$SRC is not a directory"; continue; }
  SRC_P=$(cd "$SRC" && pwd -P)    # git records physical paths (/private/var for /var)
  [[ "$TO" == "$SRC" || "$TO" == "$SRC/"* ]] && { refuse "$TO is inside $SRC"; continue; }
  [[ -e "$DEST" ]] && refuse "$DEST exists"
  PIDS=$(awk -F'\t' -v d="$SRC" '$2 == d || index($2, d "/") == 1 { print $1 }' <<< "$CWDS" | sort -un | tr '\n' ' ')
  [[ -n "$PIDS" ]] && refuse "a process has its cwd inside $SRC: pid ${PIDS% }. End that session or cd out of it first."
  act "mv $SRC $DEST"
  # Repos inside, and each one's worktrees as the record will read after the move.
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    R=${g%/.git}
    [[ -d "$g" ]] || continue      # a .git file is a worktree, repaired from its repo
    WTS=""
    for gd in "$g/worktrees"/*/gitdir; do
      [[ -f "$gd" ]] || continue
      IFS= read -r wt < "$gd"; wt=${wt%/.git}
      case "$wt" in "$SRC"/*) wt="$DEST${wt#"$SRC"}" ;; "$SRC_P"/*) wt="$DEST${wt#"$SRC_P"}" ;; esac
      WTS="$WTS $wt"
    done
    act "git -C $DEST${R#"$SRC"} worktree repair${WTS}"
  done < <(find "$SRC" -name node_modules -prune -o -name .git -print -prune 2>/dev/null | sort)
  # Records: SRC's own, then any whose remainder is a directory under SRC. A
  # prefix alone would also take a sibling's (career-prep vs career-prep-2).
  SSLUG=$(slug "$SRC")
  SUBS=$(find "$SRC" \( -name .git -o -name node_modules \) -prune -o -type d -print 2>/dev/null \
    | sed "s|^$SRC/||" | awk '{ s = $0; gsub(/[^A-Za-z0-9]/, "-", s); print s "\t" $0 }')
  for d in "$PROJECTS/$SSLUG" "$PROJECTS/$SSLUG"-*; do
    [[ -d "$d" ]] || continue
    NAME=${d##*/}
    if [[ "$NAME" == "$SSLUG" ]]; then SUB=""
    else
      SUB=$(awk -F'\t' -v r="${NAME#"$SSLUG"-}" '$1 == r { print $2; exit }' <<< "$SUBS")
      [[ -n "$SUB" ]] || { echo "not renamed: $d (no directory under $SRC has that path: a sibling's record, or a worktree that is gone)"; continue; }
    fi
    NEW="$PROJECTS/$(slug "$DEST${SUB:+/$SUB}")"
    [[ -e "$NEW" ]] && refuse "record $NEW exists; merge $d into it by hand first"
    act "mv $d $NEW"
    RENAMES+=("$d"$'\t'"$NEW")
  done
  grep -q "^repo=$SRC\(/\|$\)" "$HOME/.claude/harness.version" 2>/dev/null \
    && echo "note: ~/.claude/harness.version has repo= inside $SRC; run bash install.sh from $DEST afterwards"
  MOVES+=("$SRC"$'\t'"$SRC_P"$'\t'"$DEST")
done
[[ $FAILED == 0 ]] || { echo "nothing moved" >&2; exit 1; }
[[ $APPLY == 1 ]] || { echo "dry run: add --apply to do this"; exit 0; }

# --- apply ---------------------------------------------------------------------
mkdir -p "$TO" || exit 1
for m in "${MOVES[@]}"; do
  IFS=$'\t' read -r SRC SRC_P DEST <<< "$m"
  mv "$SRC" "$DEST" || { echo "mv $SRC $DEST failed; records not renamed" >&2; exit 1; }
  while IFS= read -r g; do
    [[ -n "$g" && -d "$g" ]] || continue
    R=${g%/.git}; ARGS=()
    for gd in "$g/worktrees"/*/gitdir; do
      [[ -f "$gd" ]] || continue
      IFS= read -r wt < "$gd"; wt=${wt%/.git}
      case "$wt" in "$SRC"/*) wt="$DEST${wt#"$SRC"}" ;; "$SRC_P"/*) wt="$DEST${wt#"$SRC_P"}" ;; esac
      [[ -d "$wt" ]] && ARGS+=("$wt")
    done
    echo "git -C $R worktree repair ${ARGS[*]:-}"
    git -C "$R" worktree repair "${ARGS[@]}" 2>&1 | sed 's/^/  /'
  done < <(find "$DEST" -name node_modules -prune -o -name .git -print -prune 2>/dev/null | sort)
done
for r in "${RENAMES[@]}"; do
  IFS=$'\t' read -r OLD NEW <<< "$r"
  mv "$OLD" "$NEW" && echo "renamed record ${OLD##*/} -> ${NEW##*/}" || { echo "mv $OLD $NEW failed" >&2; exit 1; }
done
echo "done. Open new sessions from the new paths; a session still open on an old path keeps its own record."
