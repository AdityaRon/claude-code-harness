#!/usr/bin/env bash
# Tests for two gates that live inside workflow YAML, run from the text itself so
# an edit to the workflow is what gets tested: Upstream drift's checks on a fix
# in "Open the PR", and claude.yml's reading of Claude's "Create PR" link.
set -u
DRIFT=.github/workflows/upstream-drift.yml CLAUDE_WF=.github/workflows/claude.yml
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
ROOT=$PWD

echo "=== Upstream drift: a fix is refused for .github/, a lost deny or ask rule, or a credential ==="
# The block from the fix gate's first comment to the `jq empty` after it.
awk '/^          # A fix may touch the harness, but not the workflows/{on=1} on && /^          jq empty config\/upstream-contract.json$/{exit} on' "$DRIFT" \
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
  OAUTH=example-oauth-value CHANGED=$(git diff --name-only) bash -e "$TMP/gate.sh" > "$d.out" 2>&1
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

echo ""
echo "=== ci.yml: the PR bench runs every payload, and only when hooks/ or settings changed ==="
# The run block of the "Benchmark this PR's hooks" step, run against a stub bench.
CI_WF=.github/workflows/ci.yml
awk '/name: Benchmark this PR.s hooks against the base branch/{f=1} f && /^        run: \|$/{on=1; next}
     on && $0 != "" && !/^          /{exit} on' "$CI_WF" | sed 's/^          //' > "$TMP/bench.sh"
if grep -q 'hook-bench.py' "$TMP/bench.sh"; then pass "the bench step is in $CI_WF"; else fail "the bench step is in $CI_WF" "not found"; fi
bench_case() {  # name, a function that edits the PR side; sets BENCH_RC, BENCH_ARGV, BENCH_SUMMARY
  local d="$TMP/bench.$PASS.$FAIL"
  mkdir -p "$d/hooks" "$d/config" "$d/tools" "$d/docs" && cd "$d" || return
  git init -q && git config user.email t@t && git config user.name t
  printf 'echo hi\n' > hooks/guard.sh; printf '{}\n' > config/settings.json; printf 'x\n' > docs/a.md
  printf 'import sys\nopen("argv.txt", "w").write(" ".join(sys.argv[1:]))\nopen("bench.md", "w").write("bench ran")\n' > tools/hook-bench.py
  git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD
  "$2"; git add -A && git commit -qm pr
  BASE=main PR_BODY=$'text\nintended-decisions: id-a id-b' GITHUB_STEP_SUMMARY="$d/summary" bash "$TMP/bench.sh" > "$d.out" 2>&1
  BENCH_RC=$? BENCH_ARGV=$(cat argv.txt 2>/dev/null || echo "not run") BENCH_SUMMARY=$(cat summary 2>/dev/null)
  cd "$ROOT" || return
}
docs_only(){ echo y >> docs/a.md; }
hook_edit(){ echo 'echo bye' >> hooks/guard.sh; }
settings_edit(){ printf '{"a":1}\n' > config/settings.json; }
bench_case "docs only" docs_only
[ "$BENCH_RC" = 0 ] && [ "$BENCH_ARGV" = "not run" ] && [[ "$BENCH_SUMMARY" == *"benchmark skipped"* ]] \
  && pass "a PR that leaves hooks/ and settings alone skips the bench" || fail "docs-only PR" "rc=$BENCH_RC argv=[$BENCH_ARGV] summary=[$BENCH_SUMMARY]"
bench_case "hooks edit" hook_edit
[[ "$BENCH_ARGV" == *"--base origin/main --head HEAD"*"--gate"* ]] && pass "a hooks/ edit runs the bench against the base" \
  || fail "hooks edit runs the bench" "argv=[$BENCH_ARGV]"
[[ " $BENCH_ARGV " != *" --quick "* ]] && pass "the PR bench runs every payload (no --quick)" || fail "no --quick" "argv=[$BENCH_ARGV]"
[[ "$BENCH_ARGV" == *"--intended id-a id-b"* ]] && pass "the PR body's intended-decisions ids reach the gate" \
  || fail "intended ids" "argv=[$BENCH_ARGV]"
[[ " $BENCH_ARGV " == *" --launches strace "* ]] && pass "the PR bench counts each hook's processes under strace" \
  || fail "--launches strace" "argv=[$BENCH_ARGV]"
bench_case "settings edit" settings_edit
[ "$BENCH_ARGV" != "not run" ] && pass "a config/settings.json edit runs the bench" || fail "settings edit runs the bench" "not run"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
