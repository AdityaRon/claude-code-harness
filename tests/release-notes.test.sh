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
# What the drift workflow lands on its own: a contract PR, no label.
jq 'map(select(.number == 6))' "$TMP/prs.json" > "$TMP/contract.json"
V=$(bash "$RN" --repo "$FIX" --prs "$TMP/contract.json" --since v1.0.0 --next-version)
[ "$V" = v1.0.1 ] && pass "a contract-only release is a patch" || fail "contract-only" "$V"

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
# A Release body cut at its `CHANGELOG.md entry:` trailer ends in blank lines.
printf '# Changelog\n\n## v1.0.0 (2026-10-16)\n\nold\n' > "$TMP/cut.md"
printf '## v1.0.1 (2026-10-20)\n\nnew\n\n\n' > "$TMP/cut-notes.md"
bash "$RN" --changelog "$TMP/cut-notes.md" --file "$TMP/cut.md"
[ "$(cat "$TMP/cut.md")" = "$(printf '# Changelog\n\n## v1.0.1 (2026-10-20)\n\nnew\n\n## v1.0.0 (2026-10-16)\n\nold')" ] \
  && pass "trailing blank lines of the notes dropped" || fail "trailing blanks" "$(cat "$TMP/cut.md")"

echo ""
echo "=== --changed / --hooks-changed: what the release loop guard sees ==="
ch() { bash "$RN" --repo "$FIX" "$@" 2>/dev/null; }
OUT=$(ch --since v1.0.0 --changed); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = f ] && pass "--changed lists f since v1.0.0" || fail "--changed" "rc=$RC [$OUT]"
( cd "$FIX" && git tag v1.0.1 && echo entry > CHANGELOG.md && $G add CHANGELOG.md && $G commit -qm "changelog: v1.0.1" )
ch --since v1.0.1 --changed >/dev/null; RC=$?
[ "$RC" = 1 ] && pass "only CHANGELOG.md since the tag: --changed exits 1" || fail "CHANGELOG only" "rc=$RC $(ch --since v1.0.1 --changed)"
ch --since v1.0.1 --hooks-changed >/dev/null; RC=$?
[ "$RC" = 1 ] && pass "and --hooks-changed exits 1" || fail "hooks unchanged" "rc=$RC"
( cd "$FIX" && mkdir -p hooks && echo x > hooks/x.sh && $G add hooks/x.sh && $G commit -qm "hooks: x" )
OUT=$(ch --since v1.0.1 --changed); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = hooks/x.sh ] && pass "a hook commit: --changed exits 0, CHANGELOG.md not listed" || fail "--changed hook" "rc=$RC [$OUT]"
OUT=$(ch --since v1.0.1 --hooks-changed); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = hooks/x.sh ] && pass "and --hooks-changed exits 0" || fail "--hooks-changed" "rc=$RC [$OUT]"
ch --since '' --changed >/dev/null; RC=$?
[ "$RC" = 0 ] && pass "no previous tag: exit 0" || fail "first release" "rc=$RC"
ch --since v9.9.9 --hooks-changed >/dev/null; RC=$?
[ "$RC" = 2 ] && pass "an unknown tag exits 2, not 1" || fail "bad tag" "rc=$RC"

echo ""
echo "=== --missing: tags newer than the newest CHANGELOG entry ==="
MF="$TMP/mfix"; mkdir -p "$MF"
( cd "$MF" && git init -q && echo a > a && $G add a && $G commit -qm a && git tag v1.0.0 && git tag v1.0.1 && git tag nightly ) \
  || { echo "fixture failed"; exit 1; }
mis() { bash "$RN" --repo "$MF" --missing --file "$TMP/m.md" | tr '\n' ' '; }
printf '# Changelog\n\n## v1.0.0 (2026-10-16)\n\nold\n' > "$TMP/m.md"
[ "$(mis)" = "v1.0.1 " ] && pass "entry v1.0.0, tags v1.0.0 v1.0.1: v1.0.1" || fail "one missing" "[$(mis)]"
printf '# Changelog\n\nIntro.\n' > "$TMP/m.md"
[ "$(mis)" = "v1.0.0 v1.0.1 " ] && pass "no entry: every release tag, oldest first" || fail "none written" "[$(mis)]"
printf '# Changelog\n\n## v1.0.1 (2026-10-20)\n\nnew\n\n## v1.0.0 (2026-10-16)\n\nold\n' > "$TMP/m.md"
[ "$(mis)" = "" ] && pass "every tag written: empty" || fail "all present" "[$(mis)]"
( cd "$MF" && git tag v1.0.9 && git tag v1.0.10 )
[ "$(mis)" = "v1.0.9 v1.0.10 " ] && pass "v1.0.10 sorts after v1.0.9" || fail "version sort" "[$(mis)]"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
