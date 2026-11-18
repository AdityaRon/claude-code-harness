#!/usr/bin/env bash
# Tests for tools/verify-changed.sh and config/verify-checklist.tsv. Each row is
# replayed on the commits of the incident it cites, in a shared clone holding
# today's table, so a row that would not have fired then fails here.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD VC=$PWD/tools/verify-changed.sh TABLE=config/verify-checklist.tsv
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "want: $2  got: $(printf '%s' "$3" | head -c 600)" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "unwanted: $2  in: $(printf '%s' "$3" | head -c 600)" ;; *) pass "$1" ;; esac; }
fired() { printf '%s\n' "$1" | grep -v '^  note: ' | sed -nE 's/^  ([A-Za-z0-9_.-]+): .*/\1/p' | tr '\n' ' '; }

echo "=== The shipped table parses ==="
NROWS=$(awk -F'\t' '!/^#/ && NF' "$TABLE" | wc -l | tr -d ' ')
BAD=$(awk -F'\t' '!/^#/ && NF && (NF != 5 || $3 == "" || $5 == "") { print FNR }' "$TABLE")
[[ "$NROWS" -ge 7 && -z "$BAD" ]] && pass "$NROWS rows of 5 fields" || fail "rows of 5 fields" "rows=$NROWS bad lines:$BAD"
DUP=$(awk -F'\t' '!/^#/ && NF { print $1 }' "$TABLE" | sort | uniq -d)
[[ -z "$DUP" ]] && pass "ids are unique" || fail "ids are unique" "$DUP"
NOSUITE="" BADRE=""
while IFS=$'\t' read -r id _ re check _; do
  [[ "$id" == \#* || -z "$id" ]] && continue
  if [[ "$re" != - ]]; then printf '' | grep -E -e "$re" >/dev/null 2>&1; [[ $? -eq 2 ]] && BADRE="$BADRE $id"; fi
  [[ "$check" =~ ^(tests/[^[:space:]/]+\.test\.sh[[:space:]]*)+$ ]] || continue
  for s in $check; do [[ -f "$s" ]] || NOSUITE="$NOSUITE $id:$s"; done
done < "$TABLE"
[[ -z "$BADRE" ]] && pass "every diff pattern is an ERE grep accepts" || fail "diff patterns" "$BADRE"
[[ -z "$NOSUITE" ]] && pass "every suite a row names exists" || fail "suites rows name" "$NOSUITE"

echo ""
echo "=== Each row fires on its incident's commits ==="
# id, then the commits of the incident its last field cites: the break, the fix
# or the PR's merge. A replay is the commit's diff from its first parent.
REPLAY="io-socket-linux efd41ed 56d49cf
lexer-oracle f0a01e0 dccb30a
lexer-corpus f0a01e0 dccb30a
skills-pin-handover b32667d 95faf62
hooks-bench 76c2cbe aa30bd0 efd41ed
session-start d2d4f8b d5763b1
shadow d05833c 76c2cbe"
NOREPLAY=""
for id in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$TABLE"); do
  printf '%s\n' "$REPLAY" | grep -q "^$id " || NOREPLAY="$NOREPLAY $id"
done
[[ -z "$NOREPLAY" ]] && pass "every row has an incident replay here" || fail "every row has an incident replay here" "none for:$NOREPLAY"

R=$TMP/replay
git clone -q --shared --no-checkout "$ROOT" "$R"
BLOB=$(git -C "$R" hash-object -w "$ROOT/$TABLE")
with_table() {   # TREEISH: a tree of it with today's table added
  GIT_INDEX_FILE=$TMP/idx git -C "$R" read-tree "$1" \
    && GIT_INDEX_FILE=$TMP/idx git -C "$R" update-index --add --cacheinfo "100644,$BLOB,$TABLE" \
    && GIT_INDEX_FILE=$TMP/idx git -C "$R" write-tree
}
replay() {   # SHA: verify-changed's output for SHA's diff from its first parent
  local b h
  b=$(git -C "$R" commit-tree "$(with_table "$1^1")" -m base) || return 1
  h=$(git -C "$R" commit-tree "$(with_table "$1")" -p "$b" -m head) || return 1
  (cd "$R" && bash "$VC" "$b..$h" 2>&1)
}
missing() {   # WHAT: history this clone lacks; CI clones it all
  if [[ -n "${CI:-}" ]]; then fail "$1" "commit not in this clone"; else echo "  SKIP: $1: commit not in this clone (shallow?)"; fi
}
while read -r id shas; do
  for sha in $shas; do
    if ! git -C "$R" cat-file -e "$sha^{commit}" 2>/dev/null; then missing "$id on $sha"; continue; fi
    OUT=$(replay "$sha")
    case " $(fired "$OUT")" in
      *" $id "*) pass "$id fires on $sha" ;;
      *) fail "$id fires on $sha" "fired: $(fired "$OUT") | $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')" ;;
    esac
  done
done <<< "$REPLAY"

echo ""
echo "=== A docs-only commit fires no row, and says so ==="
if git -C "$R" cat-file -e "6e5697e^{commit}" 2>/dev/null; then
  OUT=$(replay 6e5697e)
  has "6e5697e (docs/known-limitations.md): 0 of $NROWS" "Checklist: 0 of $NROWS rows matched" "$OUT"
  [[ -z "$(fired "$OUT")" ]] && pass "and no row is listed" || fail "and no row is listed" "$(fired "$OUT")"
  has "repo-layout covers a docs change" "tests/repo-layout.test.sh" "$OUT"
else missing "docs-only replay"; fi

echo ""
echo "=== Changed files map to suites ==="
if git -C "$R" cat-file -e "56d49cf^{commit}" 2>/dev/null; then
  OUT=$(replay 56d49cf)
  has "hooks/mod-gate.sh brings tests/mod-gate.test.sh" "  tests/mod-gate.test.sh  (" "$OUT"
  has "lib/io.sh is named by tests/bash-guards.test.sh" "  tests/bash-guards.test.sh  (" "$OUT"
  has "a hooks/lib change brings the smoke suites" "tests/sensitive-file-guard.test.sh  (hooks/lib/io.sh (every wired hook sources it))" "$OUT"
else missing "suite mapping replay"; fi

echo ""
echo "=== The table is the merge base's; head can only add ==="
T=$TMP/t; mkdir -p "$T"; cd "$T" || exit 1
git init -q -b main . && mkdir -p config src lib tests
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
{ row keep-me 'src/*' - 'do keep' '#1'; row narrow 'src/*' - 'do narrow' '#2'
  row needle-row 'lib/x.sh' 'needle' 'do needle' '#3'; row fresh 'new/*' - 'do fresh' '#4'; } > "$TABLE"
printf 'a\n' > src/a.txt
printf 'needle() {\n  one\n  two\n  three\n  four\n  five\n  six\n}\n' > lib/x.sh
git add -A && git commit -qm base
git checkout -qb feat
{ row narrow 'nothing/*' - 'do narrow' '#2'; row needle-row 'lib/x.sh' 'needle' 'do needle' '#3'
  row fresh 'new/*' - 'do fresh' '#4'; row head-row 'src/*' - 'do head' '#5'; } > "$TABLE"
printf 'b\n' >> src/a.txt
git commit -qam 'drop keep-me, narrow narrow, add head-row'
OUT=$(bash "$VC" main 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "exit 0" || fail "exit 0" "rc=$RC $OUT"
case " $(fired "$OUT")" in *" keep-me "*) pass "a row head drops still fires" ;; *) fail "a row head drops still fires" "$OUT" ;; esac
case " $(fired "$OUT")" in *" narrow "*) pass "a row head narrows fires as the base wrote it" ;; *) fail "a row head narrows fires as the base wrote it" "$OUT" ;; esac
case " $(fired "$OUT")" in *" head-row "*) pass "a row new in head is added" ;; *) fail "a row new in head is added" "$OUT" ;; esac
has "says head drops a row" "note: head drops row keep-me" "$OUT"
has "says head changes a row" "note: head changes row narrow" "$OUT"
has "counts base rows plus new ones" "Checklist: 3 of 5 rows matched (table from" "$OUT"
# --changed HEAD diffs from HEAD, but the table still comes from origin/main's merge base.
git update-ref refs/remotes/origin/main main
printf 'c\n' >> src/a.txt
OUT=$(bash "$VC" HEAD 2>&1)
case " $(fired "$OUT")" in *" keep-me "*) pass "--changed HEAD keeps a row the branch dropped" ;; *) fail "--changed HEAD keeps a row the branch dropped" "$OUT" ;; esac
has "and says the table is origin/main's" "the merge base with origin/main" "$OUT"
git checkout -q -- src/a.txt

echo ""
echo "=== Uncommitted, untracked and diff-pattern matches ==="
sed -i.bak 's/  six/  six and more/' lib/x.sh && rm -f lib/x.sh.bak
OUT=$(bash "$VC" main 2>&1)
case " $(fired "$OUT")" in *" needle-row "*) pass "an uncommitted edit inside needle() fires on its hunk header" ;; *) fail "uncommitted edit, hunk header" "$OUT" ;; esac
git checkout -q -- lib/x.sh
printf 'tail\n' >> lib/x.sh; printf 'x\n%.0s' 1 2 3 4 5 6 7 8 9 >> lib/x.sh
git commit -qam 'lines far below needle()'; printf 'y\n' >> lib/x.sh
OUT=$(bash "$VC" HEAD 2>&1)
case " $(fired "$OUT")" in *" needle-row "*) fail "a change the pattern does not match fires nothing" "$OUT" ;; *) pass "a change the pattern does not match fires nothing" ;; esac
git checkout -q -- lib/x.sh
mkdir -p new && printf 'n\n' > new/f.txt
OUT=$(bash "$VC" HEAD 2>&1)
case " $(fired "$OUT")" in *" fresh "*) pass "an untracked file fires its row" ;; *) fail "an untracked file fires its row" "$OUT" ;; esac
rm -rf new

echo ""
echo "=== Each way a file maps to a suite ==="
MP=$TMP/m; mkdir -p "$MP/tools" "$MP/lib" "$MP/hooks/lib" "$MP/tests" "$MP/config"; cd "$MP" || exit 1
git init -q -b main .
row none 'nothing/*' - 'do nothing' '#8' > "$TABLE"
printf 'echo foo\n' > tools/foo.sh
printf 'echo hi\n' > tests/foo.test.sh
printf '# exercises lib/thing.sh\n' > tests/names.test.sh
printf 'tests/smokey.test.sh\n' > tests/smoke.list
printf '# smoke\n' > tests/smokey.test.sh
printf 'x\n' | tee lib/thing.sh hooks/lib/y.sh > /dev/null
git add -A && git commit -qm base
printf 'y\n' | tee -a tools/foo.sh lib/thing.sh hooks/lib/y.sh > /dev/null
OUT=$(bash "$VC" main 2>&1)
has "tools/foo.sh brings tests/foo.test.sh, which does not name it" "  tests/foo.test.sh  (tools/foo.sh)" "$OUT"
has "a suite naming lib/thing.sh is brought" "  tests/names.test.sh  (lib/thing.sh)" "$OUT"
has "a hooks/lib file brings the smoke suites" "  tests/smokey.test.sh  (hooks/lib/y.sh (every wired hook sources it))" "$OUT"
has "and nothing else" "Suites (3)" "$OUT"
cd "$T" || exit 1

echo ""
echo "=== It refuses what it cannot read ==="
OUT=$(bash "$VC" no-such-ref 2>&1); RC=$?
[[ $RC -eq 2 ]] && pass "an unknown BASE exits 2" || fail "an unknown BASE exits 2" "rc=$RC $OUT"
OUT=$(bash "$VC" main..HEAD --run 2>&1); RC=$?
[[ $RC -eq 2 ]] && pass "--run on a range exits 2" || fail "--run on a range exits 2" "rc=$RC $OUT"
printf 'only\tfour\tfields\there\n' >> "$TABLE"
OUT=$(bash "$VC" main 2>&1); RC=$?
[[ $RC -eq 2 ]] && has "a malformed head row exits 2" "head table line" "$OUT" || fail "a malformed head row exits 2" "rc=$RC $OUT"
git checkout -q -- "$TABLE"
U=$TMP/u; mkdir -p "$U" && git -C "$U" init -q -b main && printf 'x\n' > "$U/f" && git -C "$U" add f && git -C "$U" commit -qm x
OUT=$(cd "$U" && bash "$VC" main 2>&1); RC=$?
[[ $RC -eq 2 ]] && has "no table anywhere exits 2" "no checklist rows" "$OUT" || fail "no table anywhere exits 2" "rc=$RC $OUT"
OUT=$(bash "$ROOT/doctor.sh" --changed no-such-ref 2>&1); RC=$?
[[ $RC -eq 2 ]] && has "doctor.sh --changed hands over to it" "verify-changed: no commit no-such-ref" "$OUT" \
  || fail "doctor.sh --changed hands over to it" "rc=$RC $OUT"

echo ""
echo "=== --run and --stamp ==="
W=$TMP/w; mkdir -p "$W/config" "$W/src" "$W/tests"; cd "$W" || exit 1
git init -q -b main .
row pair 'src/*' - 'tests/ok.test.sh tests/skip.test.sh' '#6' > "$TABLE"
row docs 'docs/*' - 'do read it' '#7' >> "$TABLE"
# ok.test.sh fails unless the run points the audit log away from the real one.
printf '[[ "${CLAUDE_AUDIT_LOG:-}" == */cch.*/audit.log ]] || { echo "  FAIL: audit log $CLAUDE_AUDIT_LOG"; exit 1; }\necho "--- Results: 2 passed, 0 failed ---"\n' > tests/ok.test.sh
printf 'echo "  SKIP: needs a clone"\necho "--- Results: 1 passed, 0 failed ---"\n' > tests/skip.test.sh
printf 'echo "  FAIL: broken  detail"\necho "--- Results: 0 passed, 1 failed ---"\nexit 1\n' > tests/bad.test.sh
printf 'a\n' > src/a.txt
git add -A && git commit -qm base
printf 'b\n' >> src/a.txt
OUT=$(env -u CLAUDE_AUDIT_LOG bash "$VC" main --stamp 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "green run exits 0" || fail "green run exits 0" "rc=$RC $OUT"
has "the stamp names each suite with its tally" \
  "Verified: bash tests/ok.test.sh (2 passed); bash tests/skip.test.sh (1 passed, 1 skipped)" "$OUT"
printf '# touched\n' >> tests/bad.test.sh
OUT=$(bash "$VC" main --stamp 2>&1); RC=$?
[[ $RC -eq 1 ]] && pass "one red suite exits 1" || fail "one red suite exits 1" "rc=$RC $OUT"
hasnt "a red run prints no Verified line" "Verified:" "$OUT"
has "and says why" "No Verified line: 1 suite(s) failed." "$OUT"
has "the failing case is shown" "FAIL: broken" "$OUT"
git checkout -q -- . && mkdir -p docs && printf 'd\n' > docs/x.md
OUT=$(bash "$VC" main --stamp 2>&1)
has "nothing to run stamps none, with why" "Verified: none (no suite covers these files)" "$OUT"
has "and names the rows left to do by hand" "Add what you did by hand for: docs" "$OUT"
cd "$ROOT" || exit 1

echo ""
results
