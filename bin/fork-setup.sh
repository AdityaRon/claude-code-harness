#!/usr/bin/env bash
# What a fork, or a fresh copy, needs on GitHub before its workflows run: Actions
# on, workflows GitHub turned off back on, Actions allowed to open PRs (Release and
# Upstream drift do), and the CLAUDE_CODE_OAUTH_TOKEN secret, which only you set.
#   fork-setup.sh [--repo OWNER/NAME] [--apply]
# Reports; --apply turns on what is off. Exit status is the number left to do.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODO=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  TODO  $1"; echo "        $2"; TODO=$((TODO + 1)); }
note() { echo "  --    $1"; }
did()  { echo "  done  $1"; }
usage() { sed -n '5,6s/^# \{0,1\}//p' "$0"; exit 2; }

R="" APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) R="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) usage ;;
  esac
done
command -v gh >/dev/null 2>&1 || { echo "gh is not on PATH: https://cli.github.com" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH" >&2; exit 2; }
if [[ -z "$R" ]]; then
  R=$(cd "$HERE/.." && gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty')
  [[ -n "$R" ]] || { echo "no GitHub repo for this clone: pass --repo OWNER/NAME" >&2; exit 2; }
fi
[[ "$R" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "not OWNER/NAME: $R" >&2; exit 2; }
echo "fork setup for $R$([[ $APPLY == 1 ]] || echo ' (report only; --apply changes it)')"

# Each setting needs admin on the repo; gh's error says which call failed.
if ! P=$(gh api "repos/$R/actions/permissions" 2>&1); then
  echo "cannot read the Actions settings of $R (admin on it needed): $P" >&2; exit 2
fi
if [[ $(jq -r '.enabled' <<<"$P") == true ]]; then ok "Actions enabled"
elif [[ $APPLY == 1 ]] && gh api -X PUT "repos/$R/actions/permissions" -F enabled=true >/dev/null; then did "Actions enabled"
else bad "Actions are off for $R" "--apply turns them on, or Settings > Actions > General"; fi

# Only the workflows this clone ships: GitHub keeps a deleted file's entry.
W=$(gh api "repos/$R/actions/workflows" --paginate 2>/dev/null | jq -r '.workflows[] | "\(.id) \(.state) \(.path)"')
for f in "$HERE"/../.github/workflows/*.yml; do
  path=".github/workflows/$(basename "$f")"
  read -r id state _ <<<"$(awk -v p="$path" '$3 == p' <<<"$W")"
  case "${state:-}" in
    active) ok "$path" ;;
    disabled_fork|disabled_inactivity)
      if [[ $APPLY == 1 ]] && gh api -X PUT "repos/$R/actions/workflows/$id/enable" >/dev/null; then did "$path enabled (was $state)"
      else bad "$path is $state" "--apply enables it, or gh workflow enable $id --repo $R"; fi ;;
    disabled_manually) note "$path: turned off by hand, left so" ;;
    "") note "$path: not on GitHub yet (pushed but never run, or Actions off)" ;;
    *) bad "$path is $state" "see the Actions tab of $R" ;;
  esac
done

if ! WP=$(gh api "repos/$R/actions/permissions/workflow" 2>/dev/null); then
  bad "cannot read whether Actions may open pull requests" "Settings > Actions > General > Workflow permissions"
elif [[ $(jq -r '.can_approve_pull_request_reviews' <<<"$WP") == true ]]; then ok "Actions may open pull requests"
elif [[ $APPLY == 1 ]] && gh api -X PUT "repos/$R/actions/permissions/workflow" \
       -f default_workflow_permissions="$(jq -r '.default_workflow_permissions' <<<"$WP")" \
       -F can_approve_pull_request_reviews=true >/dev/null; then did "Actions may open pull requests"
else bad "Actions may not open pull requests, so Release and Upstream drift cannot" \
         "--apply allows it, or Settings > Actions > General > Allow GitHub Actions to create and approve pull requests"; fi

if gh secret list --repo "$R" --json name 2>/dev/null | jq -e 'any(.[]; .name == "CLAUDE_CODE_OAUTH_TOKEN")' >/dev/null; then
  ok "CLAUDE_CODE_OAUTH_TOKEN is set"
else
  bad "no CLAUDE_CODE_OAUTH_TOKEN secret: claude.yml fails and Upstream drift opens an issue instead of a review" \
      "run /install-github-app in Claude Code for $R, or claude setup-token, then gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $R"
fi

echo ""
if [[ $TODO -eq 0 ]]; then echo "$R: nothing left to do"
else echo "$R: $TODO item(s) left"; fi
exit "$TODO"
