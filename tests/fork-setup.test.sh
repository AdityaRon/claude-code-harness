#!/usr/bin/env bash
# Tests for bin/fork-setup.sh against a stand-in gh that answers from files and
# logs each call, so a report is shown to change nothing and --apply to change
# only what GitHub turned off.
set -u
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO/bin/fork-setup.sh"
export STUB="$TMP/stub" PATH="$TMP/bin:$PATH"
mkdir -p "$STUB" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB/calls"
R=repos/octocat/harness
case "$*" in
  "repo view --json nameWithOwner") echo '{"nameWithOwner":"octocat/harness"}' ;;
  "api -X PUT "*) exit 0 ;;
  "api $R/actions/permissions") cat "$STUB/perm.json" ;;
  "api $R/actions/workflows --paginate") cat "$STUB/workflows.json" ;;
  "api $R/actions/permissions/workflow") cat "$STUB/wp.json" ;;
  "secret list --repo octocat/harness --json name") cat "$STUB/secrets.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
wf() { printf '{"id":%s,"state":"%s","path":".github/workflows/%s"}' "$1" "$2" "$3"; }
fresh_fork() {
  echo '{"enabled":false}' > "$STUB/perm.json"
  # claude-code-review.yml is an entry GitHub keeps for a file this clone no longer ships.
  printf '{"workflows":[%s,%s,%s,%s,%s]}' "$(wf 1 active ci.yml)" "$(wf 2 disabled_manually claude.yml)" \
    "$(wf 3 disabled_inactivity release.yml)" "$(wf 4 disabled_fork upstream-drift.yml)" \
    "$(wf 5 disabled_fork claude-code-review.yml)" > "$STUB/workflows.json"
  echo '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' > "$STUB/wp.json"
  echo '[]' > "$STUB/secrets.json"
  : > "$STUB/calls"
}
run() { OUT=$(bash "$S" "$@" 2>&1); RC=$?; CALLS=$(cat "$STUB/calls"); }

echo "=== a fresh fork, report only ==="
fresh_fork; run
[[ $RC == 5 ]] && pass "five to do: Actions, two workflows, PR permission, secret" || fail "exit" "rc=$RC $OUT"
[[ "$CALLS" != *"-X PUT"* ]] && pass "a report changes nothing" || fail "report wrote" "$CALLS"
[[ "$OUT" == *"fork setup for octocat/harness"* ]] && pass "the repo comes from the clone" || fail "repo" "$OUT"
[[ "$OUT" == *"release.yml is disabled_inactivity"* && "$OUT" == *"upstream-drift.yml is disabled_fork"* ]] \
  && pass "both workflows GitHub turned off are named" || fail "workflows" "$OUT"
[[ "$OUT" == *"claude.yml: turned off by hand, left so"* ]] && pass "one turned off by hand is only noted" || fail "manual" "$OUT"
[[ "$OUT" != *"claude-code-review"* ]] && pass "a workflow this clone does not ship is ignored" || fail "stale" "$OUT"
[[ "$OUT" == *"/install-github-app"*"gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo octocat/harness"* ]] \
  && pass "the missing secret says how to set it" || fail "secret hint" "$OUT"

echo ""
echo "=== --apply ==="
fresh_fork; run --apply
[[ $RC == 1 ]] && pass "only the secret is left" || fail "exit" "rc=$RC $OUT"
[[ "$CALLS" == *"api -X PUT repos/octocat/harness/actions/permissions -F enabled=true"* ]] && pass "Actions turned on" || fail "actions" "$CALLS"
[[ "$CALLS" == *"workflows/3/enable"* && "$CALLS" == *"workflows/4/enable"* ]] && pass "both workflows enabled" || fail "enable" "$CALLS"
[[ "$CALLS" != *"workflows/2/enable"* && "$CALLS" != *"workflows/5/enable"* ]] \
  && pass "neither the manual one nor the stale one is touched" || fail "over-enabled" "$CALLS"
[[ "$CALLS" == *"actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true"* ]] \
  && pass "PRs allowed, the default token scope kept" || fail "pr permission" "$CALLS"
[[ "$CALLS" != *"secret set"* ]] && pass "the secret is never set by the script" || fail "secret set" "$CALLS"

echo ""
echo "=== nothing to do, and the ways it stops ==="
echo '{"enabled":true}' > "$STUB/perm.json"
printf '{"workflows":[%s,%s,%s,%s]}' "$(wf 1 active ci.yml)" "$(wf 2 active claude.yml)" \
  "$(wf 3 active release.yml)" "$(wf 4 active upstream-drift.yml)" > "$STUB/workflows.json"
echo '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}' > "$STUB/wp.json"
echo '[{"name":"CLAUDE_CODE_OAUTH_TOKEN"}]' > "$STUB/secrets.json"
: > "$STUB/calls"; run --repo octocat/harness
[[ $RC == 0 && "$OUT" == *"nothing left to do"* ]] && pass "a set-up repo passes" || fail "all set" "rc=$RC $OUT"
rm "$STUB/perm.json"; run --repo octocat/harness
[[ $RC == 2 && "$OUT" == *"cannot read the Actions settings"* ]] && pass "no admin: says so and stops" || fail "no admin" "rc=$RC $OUT"
run --repo 'octocat/harness; rm -rf x'
[[ $RC == 2 && "$OUT" == *"not OWNER/NAME"* ]] && pass "a repo that is not OWNER/NAME is refused" || fail "bad repo" "rc=$RC $OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
