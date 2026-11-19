#!/usr/bin/env bash
# Tests for gates that live inside workflow YAML, run from the text itself so
# an edit to the workflow is what gets tested: Upstream drift's checks on a fix
# in "Open the PR", claude.yml's reading of Claude's "Create PR" link, and the
# bench steps of ci.yml and release.yml with .github/bench-gate.sh.
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
echo "=== ci.yml: the PR bench runs every payload with the base's gate script and corpus ==="
# The run block of the "Benchmark this PR's hooks" step, run on a scratch repo
# with .github/bench-gate.sh and a stub tools/hook-bench.py that logs who it is,
# its argv and the payloads it got, and fails when STUB_FAIL_ON is among them.
CI_WF=.github/workflows/ci.yml
awk '/name: Benchmark this PR.s hooks against the base branch/{f=1} f && /^        run: \|$/{on=1; next}
     on && $0 != "" && !/^          /{exit} on' "$CI_WF" | sed 's/^          //' > "$TMP/bench.sh"
if grep -q 'bench-gate.sh' "$TMP/bench.sh"; then pass "the bench step is in $CI_WF"; else fail "the bench step is in $CI_WF" "not found"; fi
cat > "$TMP/stub.py" <<'PY'
import json, os, sys
WHO = "base"
a = sys.argv[1:]
rows = [json.loads(l) for l in open(a[a.index("--corpus") + 1]) if l.strip()]
open(a[a.index("--md") + 1], "w").write("## Hook benchmark: stub\n")
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps({"who": WHO, "argv": a, "rows": {r["id"]: r["tool_input"]["command"] for r in rows}}) + "\n")
sys.exit(1 if os.environ.get("STUB_FAIL_ON", "") in [r["id"] for r in rows] else 0)
PY
gate_repo() {  # DIR: hooks, settings, the stub gate and a three-payload corpus, committed
  mkdir -p "$1/hooks" "$1/config" "$1/tools" "$1/tests" "$1/docs" "$1/.github" && cd "$1" || return
  git init -q && git config user.email t@t && git config user.name t
  printf 'echo hi\n' > hooks/guard.sh; printf '{}\n' > config/settings.json; printf 'x\n' > docs/a.md
  cp "$TMP/stub.py" tools/hook-bench.py; cp "$ROOT/.github/bench-gate.sh" .github/
  { echo '{"id":"safe-1","tool_name":"Bash","tool_input":{"command":"echo 1"}}'
    echo '{"id":"safe-2","tool_name":"Bash","tool_input":{"command":"echo 2"}}'
    echo '{"id":"deny-1","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'; } > tests/bench-corpus.jsonl
  git add -A && git commit -qm base
}
BODY=$'text\nintended-decisions: id-a id-b\nintended-launches: id-c, id-d' FAIL_ON=""
bench_case() {  # a function that edits the PR side; sets BENCH_RC, BENCH_SUMMARY, BENCH_SHA, LOG
  local d="$TMP/bench.$PASS.$FAIL"
  gate_repo "$d" || return
  git update-ref refs/remotes/origin/main HEAD; BENCH_SHA=$(git rev-parse --short HEAD)
  "$1"; git add -A && git commit -qm pr
  LOG="$d.log"; : > "$LOG"
  BASE=main PR_BODY=$BODY STUB_FAIL_ON=$FAIL_ON STUB_LOG="$LOG" GITHUB_STEP_SUMMARY="$d/summary" bash "$TMP/bench.sh" > "$d.out" 2>&1
  BENCH_RC=$? BENCH_SUMMARY=$(cat "$d/summary" 2>/dev/null)
  cd "$ROOT" || return
}
ran() { jq -r .who "$LOG" | tr '\n' ' '; }                      # who ran, in order
argv() { jq -r --arg w "$1" 'select(.who == $w) | .argv | join(" ")' "$LOG"; }
ids() { jq -r --arg w "$1" 'select(.who == $w) | .rows | keys | join(" ")' "$LOG"; }
cmd() { jq -r --arg w "$1" --arg i "$2" 'select(.who == $w) | .rows[$i]' "$LOG"; }
docs_only(){ echo y >> docs/a.md; }
hook_edit(){ echo 'echo bye' >> hooks/guard.sh; }
settings_edit(){ printf '{"a":1}\n' > config/settings.json; }
drop() { grep -v "\"$1\"" tests/bench-corpus.jsonl > c.tmp; mv c.tmp tests/bench-corpus.jsonl; }
deny_dropped(){ hook_edit; drop deny-1; }
# The PR's own copy reports itself as head and never fails, as --limit-pct 1000 would on a slower hook.
loosened(){ hook_edit; sed -i.bak 's/^WHO = "base"$/WHO = "head"/; s/^sys.exit(1 if .*/sys.exit(0)/' tools/hook-bench.py; rm -f tools/hook-bench.py.bak; }
broken(){ hook_edit; printf 'raise SystemExit(3)\n' > tools/hook-bench.py; }
new_payload(){ hook_edit; echo '{"id":"new-1","tool_name":"Bash","tool_input":{"command":"echo new"}}' >> tests/bench-corpus.jsonl; }
safe2_dropped(){ hook_edit; drop safe-2; }
safe2_changed(){ hook_edit; sed -i.bak 's/"echo 2"/"echo two"/' tests/bench-corpus.jsonl; rm -f tests/bench-corpus.jsonl.bak; }
safe2_dropped_alone(){ drop safe-2; }

bench_case docs_only
[ "$BENCH_RC" = 0 ] && [ -z "$(ran)" ] && [[ "$BENCH_SUMMARY" == *"benchmark skipped"* ]] \
  && pass "a PR that leaves hooks/ and settings alone skips the bench" || fail "docs-only PR" "rc=$BENCH_RC ran=[$(ran)] summary=[$BENCH_SUMMARY]"
bench_case hook_edit
[[ "$(argv base)" == *"--base origin/main --head HEAD"*"--gate"* ]] && pass "a hooks/ edit runs the bench against the base" \
  || fail "hooks edit runs the bench" "argv=[$(argv base)]"
[[ " $(argv base) " != *" --quick "* ]] && pass "the PR bench runs every payload (no --quick)" || fail "no --quick" "argv=[$(argv base)]"
[[ "$(argv base)" == *"--intended id-a id-b"* ]] && pass "the PR body's intended-decisions ids reach the gate" \
  || fail "intended ids" "argv=[$(argv base)]"
[[ " $(argv base) " == *" --launches strace "* ]] && pass "the PR bench counts each hook's processes under strace" \
  || fail "--launches strace" "argv=[$(argv base)]"
[[ "$(argv base)" == *"--intended-launches id-c, id-d"* && "$(argv base)" != *"--intended id-a id-b id-c"* ]] \
  && pass "the PR body's intended-launches ids reach the gate, apart from intended-decisions" || fail "intended-launches ids" "argv=[$(argv base)]"
[[ "$BENCH_SUMMARY" == *"Gate script and corpus from \`$BENCH_SHA\` (origin/main)"* ]] \
  && pass "the summary says the gate script and corpus are from the base's commit" || fail "summary names the base" "[$BENCH_SUMMARY]"
[ "$(ran)" = "base " ] && pass "a PR that leaves tools/hook-bench.py alone runs the gate once" || fail "one run" "ran=[$(ran)]"
bench_case settings_edit
[ -n "$(ran)" ] && pass "a config/settings.json edit runs the bench" || fail "settings edit runs the bench" "not run"

echo ""
echo "=== ci.yml: a PR cannot loosen the gate it is judged by ==="
FAIL_ON=deny-1 bench_case deny_dropped
[ "$BENCH_RC" = 1 ] && [[ " $(ids base) " == *" deny-1 "* ]] \
  && pass "a PR that deletes the deny payload its hook change would flip still runs it, and fails" \
  || fail "deleted deny payload" "rc=$BENCH_RC ids=[$(ids base)]"
[[ "$BENCH_SUMMARY" == *"no \`removed-payloads:\` line, so run as on the base: deny-1 (removed)"* ]] \
  && pass "the summary names the payload removed without a removed-payloads: line" || fail "summary names it" "[$BENCH_SUMMARY]"
FAIL_ON=deny-1 bench_case loosened
[ "$BENCH_RC" = 1 ] && [ "$(ran)" = "base head " ] \
  && pass "a PR whose own tools/hook-bench.py never fails still fails the base's gate" || fail "loosened script" "rc=$BENCH_RC ran=[$(ran)]"
[[ "$BENCH_SUMMARY" == *"ran again with its copy (exit 0)"* ]] && pass "and the summary shows its copy's run apart" \
  || fail "head run in summary" "[$BENCH_SUMMARY]"
bench_case broken
[ "$BENCH_RC" = 3 ] && [ "$(ran)" = "base " ] && [[ "$BENCH_SUMMARY" == *"(exit 3)"* ]] \
  && pass "the base's gate passing does not pass a PR whose own copy fails" || fail "either fails" "rc=$BENCH_RC ran=[$(ran)]"
bench_case new_payload
[ "$BENCH_RC" = 0 ] && [ "$(ids base)" = "deny-1 new-1 safe-1 safe-2" ] \
  && pass "a payload new in the PR is added to the base's corpus" || fail "new payload" "rc=$BENCH_RC ids=[$(ids base)]"
BODY=$'text\r\nremoved-payloads: safe-2\r\nmore\r\n' bench_case safe2_dropped
[ "$BENCH_RC" = 0 ] && [ "$(ids base)" = "deny-1 safe-1" ] && [[ "$BENCH_SUMMARY" == *"Dropped by \`removed-payloads:\`: safe-2."* ]] \
  && pass "removed-payloads: lets a deletion through, from a CRLF body too" || fail "removed-payloads" "rc=$BENCH_RC ids=[$(ids base)] [$BENCH_SUMMARY]"
bench_case safe2_dropped
[ "$BENCH_RC" = 1 ] && [ "$(ids base)" = "deny-1 safe-1 safe-2" ] \
  && pass "without it the deletion fails, and the base's payload runs" || fail "no removed-payloads" "rc=$BENCH_RC ids=[$(ids base)]"
BODY='removed-payloads: safe-2' bench_case safe2_changed
[ "$BENCH_RC" = 0 ] && [ "$(cmd base safe-2)" = "echo two" ] \
  && pass "a changed payload named there runs as changed" || fail "changed, named" "rc=$BENCH_RC cmd=[$(cmd base safe-2)]"
bench_case safe2_changed
[ "$BENCH_RC" = 1 ] && [ "$(cmd base safe-2)" = "echo 2" ] && [[ "$BENCH_SUMMARY" == *"safe-2 (changed)"* ]] \
  && pass "a changed payload not named fails, and runs as on the base" || fail "changed, not named" "rc=$BENCH_RC cmd=[$(cmd base safe-2)]"
bench_case safe2_dropped_alone
[ "$BENCH_RC" = 1 ] && [ -z "$(ran)" ] && [[ "$BENCH_SUMMARY" == *"benchmark skipped"* && "$BENCH_SUMMARY" == *"safe-2 (removed)"* ]] \
  && pass "a deletion with hooks/ untouched still needs the line, though the bench is skipped" \
  || fail "deletion alone" "rc=$BENCH_RC ran=[$(ran)] [$BENCH_SUMMARY]"

echo ""
echo "=== release.yml: the release bench runs the last tag's gate script and corpus ==="
REL_WF=.github/workflows/release.yml
awk '/name: Benchmark against the previous tag/{f=1} f && /^        run: \|$/{on=1; next}
     on && $0 != "" && !/^          /{exit} on' "$REL_WF" | sed 's/^          //' > "$TMP/rbench.sh"
if grep -q 'bench-gate.sh' "$TMP/rbench.sh"; then pass "the bench step is in $REL_WF"; else fail "the bench step is in $REL_WF" "not found"; fi
d="$TMP/rbench"; gate_repo "$d" || exit 1
git tag v1.0.0; TAG_SHA=$(git rev-parse --short HEAD); loosened; drop safe-2; git add -A && git commit -qm release
LOG="$d.log"; : > "$LOG"
LAST=v1.0.0 INTENDED='id-a' INTENDED_LAUNCHES='id-c id-d' REMOVED='safe-2' STUB_FAIL_ON=deny-1 STUB_LOG="$LOG" \
  GITHUB_STEP_SUMMARY="$d/summary" bash "$TMP/rbench.sh" > "$d.out" 2>&1
RRC=$? RARGV=$(argv base) RSUM=$(cat "$d/summary" 2>/dev/null); cd "$ROOT" || exit 1
[[ "$RARGV" == *"--base v1.0.0 --head HEAD --gate"* && " $RARGV " == *" --launches strace "* && "$RARGV" == *"--intended-launches id-c id-d"* && "$RARGV" == *"--intended id-a "* ]] \
  && pass "release bench: --gate, --launches strace and both intended lists" || fail "release bench argv" "argv=[$RARGV] $(tail -3 "$d.out")"
[ "$RRC" = 1 ] && [ "$(ran)" = "base head " ] && [ "$(ids base)" = "deny-1 safe-1" ] \
  && pass "release bench: the tag's script fails what the release's own copy passes, on the tag's corpus less removed-payloads" \
  || fail "release bench from the tag" "rc=$RRC ran=[$(ran)] ids=[$(ids base)]"
[[ "$RSUM" == *"Gate script and corpus from \`$TAG_SHA\` (v1.0.0)"* ]] && pass "release bench: the summary names the tag's commit" \
  || fail "release summary" "[$RSUM]"
grep -qE 'install-apt-deps\.sh jq strace' "$REL_WF" && pass "release.yml installs strace" || fail "release strace" ""
grep -q 'intended_launches=$(bash tools/release-notes.sh --since "$LAST" --prs prs.json --intended-launches)' "$REL_WF" \
  && pass "release.yml reads intended-launches from the merged PRs" || fail "release intended-launches" ""
grep -q 'removed_payloads=$(bash tools/release-notes.sh --since "$LAST" --prs prs.json --removed-payloads)' "$REL_WF" \
  && grep -q 'REMOVED: ${{ steps.plan.outputs.removed_payloads }}' "$REL_WF" \
  && pass "release.yml reads removed-payloads from the merged PRs into the bench step" || fail "release removed-payloads" ""

echo ""
echo "=== guard-props-daily.yml: a counterexample opens an issue, or comments on the open one ==="
PROPS_WF=.github/workflows/guard-props-daily.yml
# Its own workflow, so a counterexample never turns a Release run red.
if grep -q 'guard-props' "$REL_WF"; then fail "release.yml runs no guard-props job" "$(grep -n 'guard-props' "$REL_WF" | head -3)"
else pass "release.yml runs no guard-props job: a Release run's color is the release's"; fi
grep -q "^    - cron: '" "$PROPS_WF" && grep -q '^      issues: write$' "$PROPS_WF" \
  && grep -q 'python3 tools/guard-props.py --seed random > props.txt' "$PROPS_WF" \
  && pass "$PROPS_WF runs on a cron, on a random seed, with issues: write" || fail "daily workflow" "$(head -30 "$PROPS_WF")"
# A PR cannot approve its own differences: CI's property run reads the base's list.
grep -qF 'git show "origin/$BASE:tests/guard-props-approved.jsonl" > "$RUNNER_TEMP/approved.jsonl"' "$CI_WF" \
  && [ "$(grep -c 'python3 tools/guard-props.py' "$CI_WF")" = "$(grep -cF 'python3 tools/guard-props.py --approved "$RUNNER_TEMP/approved.jsonl"' "$CI_WF")" ] \
  && pass "ci.yml's property run takes the approved list from the base branch" || fail "approved from base" "$(grep -n 'guard-props' "$CI_WF")"
awk '/name: Record a counterexample in an issue/{f=1} f && /^        run: \|$/{on=1; next}
     on && $0 != "" && !/^          /{exit} on' "$PROPS_WF" | sed 's/^          //' > "$TMP/issue.sh"
if grep -q 'gh issue' "$TMP/issue.sh"; then pass "the issue step is in $PROPS_WF"; else fail "the issue step is in $PROPS_WF" "not found"; fi
d="$TMP/issue"; mkdir -p "$d/bin"
# props.txt from a real failing run: the count property on a count_mark whose tail is one byte short.
python3 -c 'import sys; s = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(s.replace("(k - 1)):]", "(k - 2)):]"))' \
  bin/disk-space.py "$d/ds.py"
python3 tools/guard-props.py --only count --n 60 --seed 42 --disk-space "$d/ds.py" > "$d/props.txt" 2>&1
grep -q 'count_mark [0-9]*, data.count' "$d/props.txt" || fail "test setup" "the mutant count_mark did not fail: $(head -3 "$d/props.txt")"
# gh, stubbed: each call's arguments to gh.log; `issue list` prints STUB_OPEN, an open issue's number or nothing.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> gh.log\n[ "$1 $2" = "issue list" ] && printf "%%s\\n" "${STUB_OPEN:-}"\nexit 0\n' > "$d/bin/gh"
chmod +x "$d/bin/gh"
issue_case() {  # STUB_OPEN: runs the step in $d; sets ILOG to gh's calls
  ( cd "$d" && rm -f gh.log issue.md && STUB_OPEN=$1 GH_TOKEN=x OWNER=o RUN=https://example.invalid/run PATH="$d/bin:$PATH" bash "$TMP/issue.sh" ) > "$d.out" 2>&1
  ILOG=$(cat "$d/gh.log" 2>/dev/null)
}
issue_case ""
[[ "$ILOG" == *"issue create --title guard properties: counterexample (seed 42) --body-file issue.md --assignee o"* ]] \
  && grep -q -- '--seed 42' "$d/issue.md" && grep -q 'count_mark [0-9]*, data.count' "$d/issue.md" \
  && pass "with none open, one issue is opened, titled with the seed, the miscounts in its body" || fail "issue create" "[$ILOG] $(cat "$d.out")"
issue_case 7
[[ "$ILOG" == *"issue comment 7 --body-file issue.md"* && "$ILOG" != *"issue create"* ]] \
  && pass "with one open, the counterexample is a comment on it" || fail "issue comment" "[$ILOG]"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
