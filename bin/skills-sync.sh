#!/usr/bin/env bash
# Installs the claude-code-skills release the pin names, from its own clone; on
# a failure ~/.claude/skills is left as it was and it exits 1.
#   skills-sync.sh [--pin FILE (~/.claude/skills.pin)] [--if-behind]
# Overrides: HARNESS_SKILLS_URL (the pin's url=), HARNESS_SKILLS_CLONE (~/.claude/skills-src).
set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" GIT_TERMINAL_PROMPT=0

PIN="$HOME/.claude/skills.pin" IF_BEHIND=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pin) PIN=${2:-}; shift 2 ;;
    --if-behind) IF_BEHIND=1; shift ;;
    *) echo "usage: skills-sync.sh [--pin FILE] [--if-behind]" >&2; exit 2 ;;
  esac
done
no() { echo "  ⚠ skills: $*; ~/.claude/skills left as it was"; exit 1; }

pinned() { sed -n "s/^$1=//p" "$PIN" 2>/dev/null | head -1; }
URL=${HARNESS_SKILLS_URL:-$(pinned url)} TAG=$(pinned tag) COMMIT=$(pinned commit)
CLONE=${HARNESS_SKILLS_CLONE:-$HOME/.claude/skills-src}
[[ -n "$URL" && "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || no "$PIN does not name a url=, a release tag= and a 40-character commit="

if [[ -n "$IF_BEHIND" ]] && [[ "$(sed -n 's/^commit=//p' "$HOME/.claude/skills.version" 2>/dev/null | head -1)" == "$COMMIT" ]]; then
  exit 0
fi

# Cloned beside its place and moved in, so a clone that fails halfway leaves no
# half-made folder for the next run to trust.
if [[ ! -e "$CLONE" ]]; then
  mkdir -p "$(dirname "$CLONE")"
  tmp=$(mktemp -d "$CLONE.new.XXXXXX") || no "cannot make a folder beside $CLONE"
  if ! git clone --quiet "$URL" "$tmp/c" 2>"$tmp/err"; then
    err=$(tail -1 "$tmp/err"); rm -rf "$tmp"
    no "git clone of $URL failed (${err:-no message})"
  fi
  mv "$tmp/c" "$CLONE" || { rm -rf "$tmp"; no "cannot move the clone to $CLONE"; }
  rm -rf "$tmp"
fi
git -C "$CLONE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || no "$CLONE is not a git clone"
# Local edits would install as the release: refused, as harness-update.sh refuses its own clone's.
[[ -z "$(git -C "$CLONE" status --porcelain 2>/dev/null)" ]] || no "$CLONE has local changes; commit, stash or remove them"

have() { [[ "$(git -C "$CLONE" rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" == "$COMMIT" ]]; }
if ! have; then
  err=$(git -C "$CLONE" fetch --quiet "$URL" "refs/tags/$TAG:refs/tags/$TAG" 2>&1 | tail -1) \
    || no "fetch of $TAG from $URL failed (${err:-no message})"
fi
GOT=$(git -C "$CLONE" rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null)
[[ "$GOT" == "$COMMIT" ]] || no "$TAG at $URL is ${GOT:-missing}, and the harness pins $COMMIT"
git -C "$CLONE" checkout --quiet --detach "$COMMIT" 2>/dev/null || no "checkout of $TAG in $CLONE failed"
[[ "$(git -C "$CLONE" rev-parse HEAD)" == "$COMMIT" && -f "$CLONE/install.sh" ]] || no "$CLONE is not at $COMMIT with an install.sh"

echo "  ✓ skills $TAG (${COMMIT:0:12}) from $URL"
bash "$CLONE/install.sh" || { echo "  ⚠ skills: $CLONE/install.sh failed at $TAG; ~/.claude/skills may hold a mix"; exit 1; }
