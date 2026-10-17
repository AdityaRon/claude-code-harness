#!/usr/bin/env bash
# Close the contract PRs a newer one supersedes, with a comment linking it, and
# delete their branches. Only open PRs that github-actions opened on
# claude/contract-<version> with a lower version; a PR a person opened is never
# touched. Every failure only warns: the new PR is already up.
#
# Usage: .github/close-superseded.sh <version> <new PR number>
set -u

CUR=${1:-} NEW=${2:-}
VER='^[0-9]+(\.[0-9]+)+$'
if ! printf '%s' "$CUR" | grep -qE "$VER" || ! printf '%s' "$NEW" | grep -qE '^[0-9]+$'; then
  echo "::warning::close-superseded: bad arguments [$CUR] [$NEW]; nothing closed."
  exit 0
fi

if ! LIST=$(gh pr list --state open --limit 100 --json number,headRefName,author); then
  echo "::warning::close-superseded: could not list open PRs; nothing closed."
  exit 0
fi
# The GraphQL login of the Actions bot is app/github-actions; REST says github-actions[bot].
if ! ROWS=$(printf '%s' "$LIST" | jq -r '.[]
    | select(.author.login == "app/github-actions" or .author.login == "github-actions[bot]")
    | select(.headRefName | test("^claude/contract-[0-9]+(\\.[0-9]+)+$"))
    | "\(.number) \(.headRefName | ltrimstr("claude/contract-"))"'); then
  echo "::warning::close-superseded: could not read the PR list; nothing closed."
  exit 0
fi

# Numeric per component: sort -V puts 2.1.99 before 2.1.300.
older(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }

printf '%s\n' "$ROWS" | while read -r N V; do
  if [ -z "$N" ] || ! older "$V" "$CUR"; then continue; fi
  if gh pr close "$N" --delete-branch --comment "Superseded by #$NEW, the contract PR for Claude Code $CUR."; then
    echo "Closed #$N (Claude Code $V), superseded by #$NEW."
  else
    echo "::warning::close-superseded: could not close #$N or delete claude/contract-$V."
  fi
done
exit 0
