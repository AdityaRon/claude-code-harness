#!/usr/bin/env bash
# Approve the pull_request runs GitHub holds on a PR github-actions opened (fork
# PR approval policy first_time_contributors), so its own CI meets main's
# required checks; a dispatched run's checks never reach the PR (#99).
# Usage: .github/approve-pr-ci.sh <PR> [<head SHA just pushed>]. Prints the PR's
# ci.yml run id once it is not held, else nothing, and the caller dispatches.
# Logs on stderr; exits 0.
set -u

PR=${1:-} SHA=${2:-}
TRIES=10 CI_PATH=.github/workflows/ci.yml
warn(){ echo "::warning::approve-pr-ci: $*" >&2; }
if ! printf '%s' "$PR" | grep -qE '^[0-9]+$'; then
  warn "bad PR number [$PR]; nothing approved."
  exit 0
fi
REPO=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
# head_sha must be the full SHA: a short one matched no runs. The caller's SHA
# wins: just after a force-push the PR head can still read as the old commit.
[ -n "$SHA" ] || SHA=$(gh pr view "$PR" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty' 2>/dev/null)
if [ -z "$REPO" ] || ! printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$'; then
  warn "no full head SHA for #$PR [$SHA]; nothing approved."
  exit 0
fi

# Held is status completed, conclusion action_required (run 39066368617, attempt
# 1). Polls for ci.yml itself: on #93 the Upstream drift run was held as well.
DONE=" " CI=""
for i in $(seq 1 "$TRIES"); do
  [ "$i" = 1 ] || sleep 6
  RUNS=$(gh api "repos/$REPO/actions/runs?head_sha=$SHA&event=pull_request&per_page=100" 2>/dev/null \
    | jq -r --arg sha "$SHA" '.workflow_runs[] | select(.head_sha == $sha)
        | "\(.id) \(.path) \(.conclusion // "-")"' 2>/dev/null) || RUNS=""
  CI=$(printf '%s\n' "$RUNS" | awk -v p="$CI_PATH" '$2 == p {print $1, $3; exit}')
  [ -n "$CI" ] || continue
  if [ "${CI#* }" != action_required ]; then
    echo "run ${CI%% *} ($CI_PATH) for #$PR is not held." >&2
    printf '%s\n' "${CI%% *}"
    exit 0
  fi
  while read -r ID P C; do
    [ "$C" = action_required ] || continue
    case "$DONE" in *" $ID "*) continue ;; esac
    if MSG=$(gh api -X POST "repos/$REPO/actions/runs/$ID/approve" 2>&1); then
      echo "approved run $ID ($P) for #$PR." >&2
      DONE="$DONE$ID "
    else
      warn "approval refused for run $ID ($P): $(printf '%s' "$MSG" | tr '\n' ' ')"
      [ "$P" = "$CI_PATH" ] && exit 0
    fi
  done <<< "$RUNS"
done
if [ -z "$CI" ]; then
  warn "no $CI_PATH pull_request run appeared for #$PR at $SHA."
else
  warn "run ${CI%% *} ($CI_PATH) for #$PR is still held after approval."
fi
exit 0
