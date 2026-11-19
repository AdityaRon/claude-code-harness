#!/usr/bin/env bash
# The commits in BASE..HEAD with no usable `Verified:` trailer, as markdown.
#   tools/verify-stamp.sh BASE..HEAD [REPO]
# Not usable: no trailer, a bare `Verified:`, or `none` with no (why). Exempt:
# merges and github-actions[bot]'s changelog commits. The mode is
# config/verify.conf at BASE, so a branch cannot change its own. Exit 1 only
# when enforce lists a commit, 2 when the range cannot be read.
set -u
RANGE=${1:-} REPO=${2:-.}
[[ "$RANGE" == *..* && "$RANGE" != *...* ]] || { echo "usage: verify-stamp.sh BASE..HEAD [REPO]" >&2; exit 2; }
BASE=${RANGE%%..*} HEAD=${RANGE#*..}
g() { git -C "$REPO" "$@"; }
for r in "$BASE" "$HEAD"; do
  [[ -n "$r" ]] && g rev-parse -q --verify "$r^{commit}" >/dev/null \
    || { echo "verify-stamp: no commit '$r' in $REPO" >&2; exit 2; }
done

MODE=$(g show "$BASE:config/verify.conf" 2>/dev/null | sed -n 's/^mode=//p' | tail -1 | tr -d '[:space:]')
case "$MODE" in
  off|observe|enforce) FROM="config/verify.conf at $BASE" ;;
  "") FROM="no mode in config/verify.conf at $BASE, so observe"; MODE=observe ;;
  *) FROM="unknown mode '$MODE' at $BASE, so observe"; MODE=observe ;;
esac
echo "### Verification stamps ($MODE)"
echo ""
if [[ "$MODE" == off ]]; then echo "Not checked: $FROM."; exit 0; fi

US=$'\x1f' GS=$'\x1d'
IS_NONE='^[Nn][Oo][Nn][Ee]([[:space:](]|$)' NONE_WHY='^[Nn][Oo][Nn][Ee][[:space:]]*[(].*[^[:space:]].*[)]$'
N=0 EXEMPT=0 K=0 LIST=""
while IFS=$US read -r -d '' h an s v; do
  if [[ "$an" == "github-actions[bot]" && "$s" == changelog:* ]]; then EXEMPT=$((EXEMPT+1)); continue; fi
  N=$((N+1))
  why="no trailer"
  if [[ -n "$v" ]]; then
    why="a bare Verified:"
    while IFS= read -r -d "$GS" one || [[ -n "$one" ]]; do
      one=$(printf '%s' "$one" | sed -E 's/^[^:]*://; s/^[[:space:]]+//; s/[[:space:]]+$//')
      [[ -n "$one" ]] || continue
      if [[ "$one" =~ $IS_NONE ]]; then
        if [[ "$one" =~ $NONE_WHY ]]; then why=""; break; fi
        why="none, with no (why)"
      else
        why=""; break
      fi
    done <<< "$v"
  fi
  [[ -n "$why" ]] || continue
  K=$((K+1))
  LIST="$LIST- \`$h\` $s ($why)"$'\n'
done < <(g log -z --no-merges --format="%h$US%an$US%s$US%(trailers:key=Verified,separator=%x1d)" "$RANGE" --)

ex=""; [[ "$EXEMPT" -eq 0 ]] || ex=", not counting $EXEMPT changelog commit(s)"
if [[ "$K" -eq 0 ]]; then
  echo "All $N commit(s) carry a usable \`Verified:\` trailer$ex ($FROM)."
  exit 0
fi
echo "$K of $N commit(s) carry no usable \`Verified:\` trailer$ex ($FROM):"
echo ""
printf '%s' "$LIST"
echo ""
if [[ "$MODE" == enforce ]]; then
  echo "Enforced: add the trailer, \`Verified: <what ran>\` or \`Verified: none (<why>)\`, beside Co-Authored-By."
  exit 1
fi
echo "Observe mode: listed, not failed."
