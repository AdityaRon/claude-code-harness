#!/usr/bin/env bash
# Tests for two gates that live inside workflow YAML, run from the text itself so
# an edit to the workflow is what gets tested: Upstream drift's fix-mode checks
# in "Open the PR", and claude.yml's reading of Claude's "Create PR" link.
set -u
DRIFT=.github/workflows/upstream-drift.yml CLAUDE_WF=.github/workflows/claude.yml
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
ROOT=$PWD

echo "=== Upstream drift: a fix is refused for .github/, a lost deny or ask rule, or a credential ==="
# The block from `if [ "$MODE" = fix ]` to the `jq empty` after it.
awk '/^          if \[ "\$MODE" = fix \]; then$/{on=1} on && /^          jq empty config\/upstream-contract.json$/{exit} on' "$DRIFT" \
  | sed 's/^          //' > "$TMP/gate.sh"
if [ -s "$TMP/gate.sh" ]; then pass "the fix gate is in $DRIFT"; else fail "the fix gate is in $DRIFT" "not found"; fi

case_() {  # name, expected exit, a function that edits the scratch repo
  local d="$TMP/repo.$PASS.$FAIL" rc
  mkdir -p "$d" && cd "$d" || return
  git init -q && git config user.email t@t && git config user.name t
  mkdir -p config .github/workflows tests hooks
  printf '{"permissions":{"deny":["Bash(rm -rf:*)","Read(.env)"],"ask":["Bash(git push:*)"]}}\n' > config/settings.json
  printf 'on: push\n' > .github/workflows/ci.yml
  printf 'FAKE=ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" > tests/fixture.test.sh
  printf 'echo hi\n' > hooks/guard.sh
  git add -A && git commit -qm base
  "$3"
  MODE=fix OAUTH=example-oauth-value CHANGED=$(git diff --name-only) bash -e "$TMP/gate.sh" > "$d.out" 2>&1
  rc=$?
  cd "$ROOT" || return
  if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1" "exit $rc, want $2: $(head -c 300 "$d.out")"; fi
}
clean_fix(){ echo 'echo fixed' >> hooks/guard.sh; }
deny_removed(){ printf '{"permissions":{"deny":["Bash(rm -rf:*)"],"ask":["Bash(git push:*)"]}}\n' > config/settings.json; }
deny_to_ask(){ printf '{"permissions":{"deny":["Bash(rm -rf:*)"],"ask":["Bash(git push:*)","Read(.env)"]}}\n' > config/settings.json; }
ask_to_deny(){ printf '{"permissions":{"deny":["Bash(rm -rf:*)","Read(.env)","Bash(git push:*)"],"ask":[]}}\n' > config/settings.json; }
workflow_edit(){ echo '# x' >> .github/workflows/ci.yml; }
oauth_added(){ echo 'echo example-oauth-value' >> hooks/guard.sh; }
app_token_added(){ printf 'T=ghs_%s\n' "$(printf 'b%.0s' $(seq 1 36))" >> hooks/guard.sh; }
fixture_kept(){ echo '# a comment' >> tests/fixture.test.sh; }
case_ "a fix to the harness publishes" 0 clean_fix
case_ "a removed deny rule is refused" 1 deny_removed
case_ "a deny rule moved to ask is refused" 1 deny_to_ask
case_ "an ask rule moved to deny publishes" 0 ask_to_deny
case_ "an edit under .github/ is refused" 1 workflow_edit
case_ "the OAuth token in an added line is refused" 1 oauth_added
case_ "an app token in an added line is refused" 1 app_token_added
case_ "a fixture token the fix left alone publishes" 0 fixture_kept

echo ""
echo "=== claude.yml: the PR takes the title and body from Claude's Create PR link ==="
# The python between `python3 - "$BRANCH" <<'PY'` and `PY`.
awk '/python3 - "\$BRANCH" <<'"'"'PY'"'"'$/{on=1; next} on && /^          PY$/{exit} on' "$CLAUDE_WF" \
  | sed 's/^          //' > "$TMP/link.py"
if [ -s "$TMP/link.py" ]; then pass "the link reader is in $CLAUDE_WF"; else fail "the link reader is in $CLAUDE_WF" "not found"; fi
B=claude/issue-139-20261027-2104
# This branch's link, then a later run's link for another branch on the same issue.
cat > "$TMP/comments.txt" <<EOF
**Claude finished** [View job](https://github.com/o/r/actions/runs/1) • [Create PR ➔](https://github.com/o/r/compare/main...$B?quick_pull=1&title=fix%3A%20trust%20noise&body=ships%20at%20USER%20scope%20(%60~%2F.claude%60%20via%20install.sh)%2C%20done)
Later: [Create PR ➔](https://github.com/o/r/compare/main...claude/issue-139-later?quick_pull=1&title=other&body=other)
EOF
( cd "$TMP" && python3 link.py "$B" ) 2>"$TMP/py.err"
[ "$(cat "$TMP/title.txt" 2>/dev/null)" = "fix: trust noise" ] && pass "the title is this branch's, decoded" \
  || fail "title" "[$(cat "$TMP/title.txt" 2>/dev/null)] $(cat "$TMP/py.err")"
[ "$(cat "$TMP/body.md" 2>/dev/null)" = 'ships at USER scope (`~/.claude` via install.sh), done' ] \
  && pass "a body with raw parentheses is read to the link's end" || fail "body" "[$(cat "$TMP/body.md" 2>/dev/null)]"
: > "$TMP/comments.txt"
( cd "$TMP" && python3 link.py "$B" ) 2>"$TMP/py.err"
[ ! -s "$TMP/title.txt" ] && [ ! -s "$TMP/body.md" ] && pass "no link leaves both empty, for the fallback" \
  || fail "no link" "$(cat "$TMP/py.err")"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
