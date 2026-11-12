#!/usr/bin/env bash
# Release notes, the next version and the CHANGELOG entry from the PRs merged
# since a tag (.github/workflows/release.yml runs it; so can you).
#   release-notes.sh --since TAG [--prs FILE] [--bench FILE] [--version V]   the notes
#   release-notes.sh --since TAG [--prs FILE] --next-version [--bump auto|patch|minor|major]
#   release-notes.sh --since TAG [--prs FILE] --intended     ids from `intended-decisions:` lines
#   release-notes.sh --changelog NOTES.md [--file CHANGELOG.md]
#   release-notes.sh --entry VERSION [--file CHANGELOG.md]    an entry already written
#   release-notes.sh --missing [--file CHANGELOG.md]  tags newer than the newest entry, oldest first
#   release-notes.sh --since TAG --changed        paths changed since TAG but CHANGELOG.md; exit 1 if none
#   release-notes.sh --since TAG --hooks-changed  the same for hooks/ and config/settings.json
# PRs group as Security / Speed / Compatibility / Memory / Other by label, else
# by title. The bump is patch, or minor on the label enhancement or feature or a
# `feat` title; major only when asked. --prs is `gh pr list --json
# number,title,labels,body` output; --since '' is the first release.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '2,15s/^# \{0,1\}//p' "$0"; exit 2; }

SINCE="" PRS="" BENCH="" VERSION="" DATE="" BUMP=auto MODE=notes NOTES="" FILE=""
SINCE_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --since) SINCE="${2:-}"; SINCE_SET=1; shift 2 ;;
    --prs) PRS="$2"; shift 2 ;;
    --bench) BENCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    --bump) BUMP="$2"; shift 2 ;;
    --next-version) MODE=version; shift ;;
    --intended) MODE=intended; shift ;;
    --changelog) MODE=changelog; NOTES="$2"; shift 2 ;;
    --entry) MODE=entry; VERSION="$2"; shift 2 ;;
    --missing) MODE=missing; shift ;;
    --changed) MODE=changed; shift ;;
    --hooks-changed) MODE=hooks; shift ;;
    --file) FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$FILE" ]] || FILE="$REPO/CHANGELOG.md"
if [[ "$MODE" == entry ]]; then
  [[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 2; }
  # `## v1.0.1 ` with its space, so v1.0.1 does not take v1.0.10's entry.
  ENTRY=$(awk -v h="## $VERSION" '
    $0 == h || index($0, h " ") == 1 { on = 1; print; next }
    on && /^## / { exit } on' "$FILE")
  [[ -n "$ENTRY" ]] || { echo "no $VERSION entry in $FILE" >&2; exit 3; }
  printf '%s\n' "$ENTRY"; exit 0
fi
if [[ "$MODE" == missing ]]; then
  [[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 2; }
  # The tags after the top entry's, by version; with no entry, every tag.
  TOP=$(sed -nE 's/^## (v[0-9]+\.[0-9]+\.[0-9]+)( .*)?$/\1/p' "$FILE" | head -1)
  { echo "$TOP"; git -C "$REPO" tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'; } \
    | sort -uV | awk -v top="$TOP" '$0 == top { seen = 1; next } seen'
  exit 0
fi
if [[ "$MODE" == changelog ]]; then
  [[ -f "$NOTES" ]] || { echo "no such file: $NOTES" >&2; exit 2; }
  [[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 2; }
  # Above the first entry; the header and its paragraph stay on top. Trailing
  # blank lines dropped: a Release body cut at its trailer ends with one.
  awk -v notes="$NOTES" '
    BEGIN { while ((getline l < notes) > 0) L[++n] = l; while (n > 0 && L[n] ~ /^[ \t]*$/) n-- }
    !done && /^## / { for (i = 1; i <= n; i++) print L[i]; print ""; done = 1 }
    { print }
    END { if (!done) { print ""; for (i = 1; i <= n; i++) print L[i] } }' "$FILE" > "$FILE.next" \
    && mv "$FILE.next" "$FILE"
  exit $?
fi

[[ "$SINCE_SET" == 1 ]] || { echo "--since TAG is required ('' for the first release)" >&2; usage; }

# The release workflow's loop guard: a merged CHANGELOG PR alone is no release.
# hook-bench.py reads only hooks/ and config/settings.json of each side.
if [[ "$MODE" == changed || "$MODE" == hooks ]]; then
  [[ -n "$SINCE" ]] || exit 0
  if [[ "$MODE" == hooks ]]; then PATHS=(hooks config/settings.json); else PATHS=(. ':!CHANGELOG.md'); fi
  CH=$(git -C "$REPO" diff --name-only "$SINCE" HEAD -- "${PATHS[@]}") || { echo "git diff from $SINCE failed" >&2; exit 2; }
  [[ -n "$CH" ]] || exit 1
  printf '%s\n' "$CH"; exit 0
fi

# PR numbers from the merge commits since the tag: GitHub's merge subject, and
# the `(#N)` a squash merge leaves at the end of its subject.
RANGE="HEAD"; [[ -n "$SINCE" ]] && RANGE="$SINCE..HEAD"
NUMBERS=$(git -C "$REPO" log --format=%s "$RANGE" 2>/dev/null \
  | sed -nE 's/^Merge pull request #([0-9]+) .*/\1/p; s/.*\(#([0-9]+)\)$/\1/p' | sort -un)
if [[ -z "$NUMBERS" ]]; then
  case "$MODE" in
    version) ;;   # a bare tag bump is still a version
    intended) exit 0 ;;
    *) echo "no merged PRs since ${SINCE:-the start}" >&2; exit 3 ;;
  esac
  NUMBERS=""
fi

if [[ -n "$PRS" ]]; then
  ALL=$(cat "$PRS")
else
  command -v gh >/dev/null || { echo "gh is required without --prs" >&2; exit 2; }
  ALL=$(gh pr list --state merged --base main --limit 300 --json number,title,labels,body) || exit 2
fi
NUMS_JSON=$(printf '%s\n' "$NUMBERS" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')
PRS_JSON=$(printf '%s' "$ALL" | jq -c --argjson n "$NUMS_JSON" \
  '[.[] | select(.number as $x | $n | index($x)) | select(.title | test("^changelog:") | not)] | sort_by(-.number)')
if [[ "$MODE" == notes && "$(printf '%s' "$PRS_JSON" | jq 'length')" == 0 ]]; then
  echo "no merged PRs since ${SINCE:-the start} other than the changelog" >&2; exit 3
fi

case "$MODE" in
  intended)
    printf '%s' "$PRS_JSON" | jq -r '.[].body // "" | split("\n")[] | select(test("^intended-decisions:"))
                                     | sub("^intended-decisions:[[:space:]]*"; "") | split("[,[:space:]]+"; "") | .[]' \
      | grep -v '^$' | sort -u | tr '\n' ' '; echo
    exit 0 ;;
  version)
    if [[ "$BUMP" == auto ]]; then
      BUMP="patch"
      MINOR=$(printf '%s' "$PRS_JSON" | jq -r '[.[] | select(
        ((.labels // []) | map(.name | ascii_downcase) | any(. == "enhancement" or . == "feature"))
        or (.title | test("^(feat|feature)[:(]"; "i")))] | length')
      [[ "$MINOR" != 0 ]] && BUMP=minor
    fi
    if [[ -z "$SINCE" ]]; then echo "v1.0.0"; exit 0; fi
    [[ "$SINCE" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "not a release tag: $SINCE" >&2; exit 2; }
    MA=${BASH_REMATCH[1]} MI=${BASH_REMATCH[2]} PA=${BASH_REMATCH[3]}
    case "$BUMP" in
      major) echo "v$((MA + 1)).0.0" ;;
      minor) echo "v$MA.$((MI + 1)).0" ;;
      patch) echo "v$MA.$MI.$((PA + 1))" ;;
      *) echo "bad --bump: $BUMP" >&2; exit 2 ;;
    esac
    exit 0 ;;
esac

# Group by label first, then by the words a title here uses. Speed before
# Security: "guards: faster Bash checks" is a speed change to a guard.
GROUPED=$(printf '%s' "$PRS_JSON" | jq -r '
  def group:
    ((.labels // []) | map(.name | ascii_downcase)) as $l | (.title | ascii_downcase) as $t
    | if ($l | index("security")) then "Security"
      elif ($l | index("speed")) then "Speed"
      elif ($l | index("compatibility")) then "Compatibility"
      elif ($l | index("memory")) then "Memory"
      elif ($t | test("faster|speed|latency|cheaper|bench|slow|[0-9]x ")) then "Speed"
      elif ($t | test("memory")) then "Memory"
      elif ($t | test("^(contract|upstream|drift|install|ci|release|doctor)[: ]|claude code|cli ")) then "Compatibility"
      elif ($t | test("guard|deny|ask|secret|permission|sandbox|audit|sensitive|allowlist|lifecycle|rm-|mod|net|kubectl")) then "Security"
      else "Other" end;
  group_by(group) | map({g: .[0] | group, items: map("- \(.title) (#\(.number))")}) | .[] | "\(.g)\n\(.items | join("\n"))\n"')

COUNT=$(printf '%s' "$PRS_JSON" | jq 'length')
[[ -n "$DATE" ]] || DATE=$(date -u +%Y-%m-%d)
echo "## ${VERSION:-unreleased} ($DATE)"
echo ""
if [[ -n "$SINCE" ]]; then echo "Merged since $SINCE: $COUNT PR$([[ "$COUNT" == 1 ]] || echo s)."
else echo "First release: $COUNT PR$([[ "$COUNT" == 1 ]] || echo s)."; fi
for g in Security Speed Compatibility Memory Other; do
  BLOCK=$(printf '%s\n' "$GROUPED" | awk -v g="$g" '$0 == g { on = 1; next } on && /^$/ { exit } on')
  [[ -n "$BLOCK" ]] || continue
  echo ""; echo "### $g"; printf '%s\n' "$BLOCK"
done
if [[ -n "$BENCH" && -f "$BENCH" ]]; then
  echo ""
  echo "### Benchmark vs ${SINCE:-nothing}"
  echo ""
  # The bench report's own heading would nest wrongly under this one.
  grep -v '^## ' "$BENCH"
fi
