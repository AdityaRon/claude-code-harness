#!/usr/bin/env bash
# Tests for bin/release-notes.sh on a fixture repo and a PR list file: which
# PRs count, how they group, what the next version is, and the CHANGELOG insert.
set -u
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
RN="$PWD/bin/release-notes.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
G="git -c user.email=t@example.com -c user.name=t"

FIX="$TMP/fix"; mkdir -p "$FIX"
( cd "$FIX" && git init -q && echo a > f && $G add f && $G commit -qm init && git tag v1.0.0
  for s in "Merge pull request #2 from o/git-guard" "fix: thing (#3)" "Merge pull request #4 from o/mem" \
           "Merge pull request #5 from o/changelog" "Merge pull request #6 from o/contract" "Merge pull request #7 from o/status"; do
    echo "$s" >> f && $G commit -qam "$s"; done ) || { echo "fixture failed"; exit 1; }
cat > "$TMP/prs.json" <<'JSON'
[{"number":2,"title":"git-guard: a branch whose tip a remote holds can be deleted","labels":[],
  "body":"## Why\n\nintended-decisions: bash-git-branch-delete, friction-git-branch-delete\n"},
 {"number":3,"title":"guards: faster Bash checks; jq filters no longer false-deny","labels":[],"body":""},
 {"number":4,"title":"memory-lint: count characters in any locale","labels":[{"name":"enhancement"}],"body":"intended-decisions: x-1"},
 {"number":5,"title":"changelog: v1.0.1","labels":[],"body":""},
 {"number":6,"title":"contract: review Claude Code releases up to 2.1.301","labels":[],"body":""},
 {"number":7,"title":"statusline: show live effort","labels":[],"body":"no decisions line"},
 {"number":9,"title":"network-guard: an old PR before the tag","labels":[],"body":"intended-decisions: old"}]
JSON
rn() { bash "$RN" --repo "$FIX" --prs "$TMP/prs.json" "$@"; }

echo "=== notes: the PRs since the tag, grouped, the changelog PR left out ==="
OUT=$(rn --since v1.0.0 --version v1.0.1 --date 2026-10-20); RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $OUT"
[[ "$OUT" == "## v1.0.1 (2026-10-20)"* ]] && pass "heading has version and date" || fail "heading" "$(head -1 <<<"$OUT")"
grep -q '^Merged since v1.0.0: 5 PRs\.$' <<<"$OUT" && pass "5 PRs counted" || fail "count" "$(grep Merged <<<"$OUT")"
sec() { awk -v h="### $1" '$0 == h { on = 1; next } /^### / { on = 0 } on' <<<"$OUT"; }
grep -q '(#2)$' <<<"$(sec Security)" && pass "git-guard under Security" || fail "Security" "$(sec Security)"
grep -q '(#3)$' <<<"$(sec Speed)" && pass "faster under Speed, before Security" || fail "Speed" "$(sec Speed)"
grep -q '(#4)$' <<<"$(sec Memory)" && pass "memory-lint under Memory" || fail "Memory" "$(sec Memory)"
grep -q '(#6)$' <<<"$(sec Compatibility)" && pass "contract under Compatibility" || fail "Compatibility" "$(sec Compatibility)"
grep -q '(#7)$' <<<"$(sec Other)" && pass "statusline under Other" || fail "Other" "$(sec Other)"
grep -q '#5)' <<<"$OUT" && fail "changelog PR left out" "" || pass "changelog PR left out"
grep -q '#9)' <<<"$OUT" && fail "a PR before the tag left out" "" || pass "a PR before the tag left out"
grep -q '^### Security$' <<<"$OUT" && [ "$(grep -n '^### ' <<<"$OUT" | head -1 | cut -d: -f2)" = "### Security" ] \
  && pass "groups in a fixed order" || fail "order" "$(grep '^### ' <<<"$OUT")"
printf '## Hook benchmark: v1.0.0 vs HEAD\n\n| Tool class | calls |\n|---|---:|\n| Bash | 3 |\n' > "$TMP/bench.md"
OUT=$(rn --since v1.0.0 --version v1.0.1 --bench "$TMP/bench.md")
grep -q '^### Benchmark vs v1.0.0$' <<<"$OUT" && grep -q '^| Bash | 3 |$' <<<"$OUT" && ! grep -q '^## Hook benchmark' <<<"$OUT" \
  && pass "benchmark table appended without its own heading" || fail "bench" "$OUT"
jq 'map(select(.number == 5))' "$TMP/prs.json" > "$TMP/only-changelog.json"
bash "$RN" --repo "$FIX" --prs "$TMP/only-changelog.json" --since v1.0.0 >/dev/null 2>&1; RC=$?
[ "$RC" = 3 ] && pass "only the changelog PR: exit 3" || fail "exit 3" "rc=$RC"
( cd "$FIX" && git tag v1.0.1 )
rn --since v1.0.1 >/dev/null 2>&1; RC=$?
[ "$RC" = 3 ] && pass "nothing merged since the tag: exit 3" || fail "exit 3 at tag" "rc=$RC"
( cd "$FIX" && git tag -d v1.0.1 >/dev/null )

echo ""
echo "=== --next-version ==="
[ "$(rn --since v1.0.0 --next-version)" = v1.1.0 ] && pass "an enhancement label makes it minor" || fail "minor" "$(rn --since v1.0.0 --next-version)"
jq 'map(.labels = [])' "$TMP/prs.json" > "$TMP/nolabels.json"
V=$(bash "$RN" --repo "$FIX" --prs "$TMP/nolabels.json" --since v1.0.0 --next-version)
[ "$V" = v1.0.1 ] && pass "no label: patch" || fail "patch" "$V"
jq 'map(.labels = []) | .[1].title = "feat: a new guard"' "$TMP/prs.json" > "$TMP/feat.json"
V=$(bash "$RN" --repo "$FIX" --prs "$TMP/feat.json" --since v1.0.0 --next-version)
[ "$V" = v1.1.0 ] && pass "a feat title: minor" || fail "feat" "$V"
[ "$(rn --since v1.0.0 --next-version --bump major)" = v2.0.0 ] && pass "--bump major" || fail "major" ""
[ "$(rn --since v1.0.0 --next-version --bump patch)" = v1.0.1 ] && pass "--bump patch overrides the label" || fail "patch override" ""
[ "$(rn --since '' --next-version)" = v1.0.0 ] && pass "first release is v1.0.0" || fail "first" "$(rn --since '' --next-version)"
rn --since v1.0.0 --next-version --bump nope >/dev/null 2>&1; [ $? = 2 ] && pass "bad bump exits 2" || fail "bad bump" ""

echo ""
echo "=== --intended: ids from the merged PR bodies ==="
[ "$(rn --since v1.0.0 --intended)" = "bash-git-branch-delete friction-git-branch-delete x-1 " ] \
  && pass "union of the lines, sorted, without the old PR's" || fail "intended" "[$(rn --since v1.0.0 --intended)]"

echo ""
echo "=== --changelog inserts above the first entry ==="
printf '# Changelog\n\nIntro paragraph.\n\n## v1.0.0 (2026-10-16)\n\nold\n' > "$TMP/CHANGELOG.md"
printf '## v1.0.1 (2026-10-20)\n\nnew\n' > "$TMP/notes.md"
bash "$RN" --changelog "$TMP/notes.md" --file "$TMP/CHANGELOG.md"
EXPECT=$(printf '# Changelog\n\nIntro paragraph.\n\n## v1.0.1 (2026-10-20)\n\nnew\n\n## v1.0.0 (2026-10-16)\n\nold\n')
[ "$(cat "$TMP/CHANGELOG.md")" = "$EXPECT" ] && pass "header kept, entry first" || fail "insert" "$(cat "$TMP/CHANGELOG.md")"
E=$(bash "$RN" --entry v1.0.0 --file "$TMP/CHANGELOG.md")
[ "$E" = "$(printf '## v1.0.0 (2026-10-16)\n\nold')" ] && pass "--entry returns one written entry" || fail "--entry v1.0.0" "$E"
E=$(bash "$RN" --entry v1.0.1 --file "$TMP/CHANGELOG.md")
[ "$E" = "$(printf '## v1.0.1 (2026-10-20)\n\nnew')" ] && pass "--entry stops at the next heading" || fail "--entry v1.0.1" "$E"
printf '## v1.0.10 (2026-11-01)\n\nten\n' > "$TMP/ten.md"; bash "$RN" --changelog "$TMP/ten.md" --file "$TMP/CHANGELOG.md"
E=$(bash "$RN" --entry v1.0.1 --file "$TMP/CHANGELOG.md")
[ "$E" = "$(printf '## v1.0.1 (2026-10-20)\n\nnew')" ] && pass "v1.0.1 does not match v1.0.10" || fail "--entry prefix" "$E"
bash "$RN" --entry v9.9.9 --file "$TMP/CHANGELOG.md" >/dev/null 2>&1; [ $? = 3 ] && pass "no entry: exit 3" || fail "--entry missing" ""
printf '# Changelog\n\nIntro.\n' > "$TMP/empty.md"
bash "$RN" --changelog "$TMP/notes.md" --file "$TMP/empty.md"
[ "$(tail -1 "$TMP/empty.md")" = new ] && pass "no entry yet: appended" || fail "append" "$(cat "$TMP/empty.md")"
grep -q '^## v1\.0\.0 (' "$PWD/CHANGELOG.md" && pass "the shipped CHANGELOG starts at v1.0.0" || fail "shipped changelog" ""

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
