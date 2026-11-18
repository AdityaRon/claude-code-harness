#!/usr/bin/env bash
# Tests for tools/verify-stamp.sh, and the ci.yml step that runs it, in a temp
# repo: which commits it lists, and how config/verify.conf at the base sets its exit.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD VS=$PWD/tools/verify-stamp.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "want: $2  got: $(printf '%s' "$3" | head -c 800)" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "unwanted: $2  in: $(printf '%s' "$3" | head -c 800)" ;; *) pass "$1" ;; esac; }
listed() { printf '%s\n' "$1" | sed -nE 's/^- `[0-9a-f]+` ([^ ]+) .*/\1/p' | sort | tr '\n' ' '; }

R=$TMP/r; mkdir -p "$R/config" && cd "$R" || exit 1
git init -q -b main .
conf() { mkdir -p config && printf '# mode\nmode=%s\n' "$1" > config/verify.conf; }
conf observe; git add -A && git commit -qm base
git checkout -qb feat
c() { git commit -q --allow-empty -m "$1" ${2:+-m "$2"}; }
TR='Co-Authored-By: x <x@example.com>'
c stamped "Verified: bash tests/a.test.sh (3 passed)
$TR"
c none-why "Verified: none (docs only)
$TR"
c unstamped "Body, no trailer."
c bare "Verified:
$TR"
c none-bare "Verified: none
$TR"
c none-empty "Verified: none ( )
$TR"
c nonexistent-tool "Verified: nonexistent-tool --check
$TR"
c mid-body "Verified: in the body, not the trailer block

$TR"
GIT_AUTHOR_NAME='github-actions[bot]' c 'changelog: v9.9.9'
GIT_AUTHOR_NAME='github-actions[bot]' c bot-other
git checkout -q -b side main && c side-stamped "Verified: x" && git checkout -q feat
git merge -q --no-ff --no-edit side

echo "=== observe: which commits are listed ==="
OUT=$(bash "$VS" main..feat 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "observe exits 0 with commits listed" || fail "observe exits 0" "rc=$RC $OUT"
WANT="bare bot-other mid-body none-bare none-empty unstamped "
[[ "$(listed "$OUT")" == "$WANT" ]] && pass "lists exactly: $WANT" || fail "lists exactly: $WANT" "got: $(listed "$OUT")"
has "a bare Verified: is named as such" "bare (a bare Verified:)" "$OUT"
has "none with no reason is named as such" "none-bare (none, with no (why))" "$OUT"
has "no trailer is named as such" "unstamped (no trailer)" "$OUT"
has "counts what it checked" "6 of 10 commit(s) carry no usable" "$OUT"
has "the changelog commit is left out and counted" "not counting 1 changelog commit(s)" "$OUT"
hasnt "the merge commit is not listed" "Merge branch" "$OUT"
has "says observe" "Observe mode: listed, not failed." "$OUT"
has "says where the mode came from" "config/verify.conf at main" "$OUT"

echo ""
echo "=== The mode is the base's ==="
git checkout -q main && conf enforce && git commit -qam enforce && git checkout -q feat
OUT=$(bash "$VS" main..feat 2>&1); RC=$?
[[ $RC -eq 1 ]] && pass "enforce at the base exits 1" || fail "enforce at the base exits 1" "rc=$RC"
has "and says what to add" "Enforced: add the trailer" "$OUT"
git checkout -q main && conf observe && git commit -qam observe && git checkout -q feat && git merge -q --no-edit main
conf enforce && git commit -qam 'enforce, in the branch only' -m 'Verified: none (config)'
OUT=$(bash "$VS" main..feat 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "enforce in the branch alone exits 0" || fail "enforce in the branch alone exits 0" "rc=$RC $OUT"
conf off && git commit -qam 'off, in the branch only' -m 'Verified: none (config)'
OUT=$(bash "$VS" main..feat 2>&1)
has "off in the branch alone still lists" "Observe mode" "$OUT"
git checkout -q main && conf off && git commit -qam off && git checkout -q feat
OUT=$(bash "$VS" main..feat 2>&1); RC=$?
[[ $RC -eq 0 ]] && has "off at the base checks nothing" "Not checked: config/verify.conf at main" "$OUT" || fail "off at the base" "rc=$RC $OUT"
git checkout -q main && git rm -q config/verify.conf && git commit -qm 'no conf' && git checkout -q feat
conf enforce && git commit -qam 'enforce again in the branch' -m 'Verified: none (config)'
OUT=$(bash "$VS" main..feat 2>&1); RC=$?
[[ $RC -eq 0 ]] && has "a base with no conf observes" "no mode in config/verify.conf at main, so observe" "$OUT" || fail "a base with no conf" "rc=$RC $OUT"

echo ""
echo "=== All stamped, and a bad range ==="
git checkout -q -b clean main && c one "Verified: bash x" && c two "Verified: none (merge only)"
git checkout -q main && conf enforce && git add config/verify.conf && git commit -qm enforce-for-clean && git checkout -q clean
OUT=$(bash "$VS" main..clean 2>&1); RC=$?
[[ $RC -eq 0 ]] && has "every commit stamped passes even under enforce" "(enforce)

All 2 commit(s) carry a usable" "$OUT" || fail "all stamped under enforce" "rc=$RC $OUT"
OUT=$(bash "$VS" main 2>&1); RC=$?
[[ $RC -eq 2 ]] && pass "no range exits 2" || fail "no range exits 2" "rc=$RC"
OUT=$(bash "$VS" nope..clean 2>&1); RC=$?
[[ $RC -eq 2 ]] && pass "an unknown base exits 2" || fail "an unknown base exits 2" "rc=$RC"
OUT=$(cd "$TMP" && bash "$VS" main..clean "$R" 2>&1); RC=$?
[[ $RC -eq 0 ]] && has "REPO names the repo" "All 2 commit(s)" "$OUT" || fail "REPO names the repo" "rc=$RC $OUT"

echo ""
echo "=== The ci.yml step, run from its own text ==="
# The run: block under "List commits without a Verified trailer", as GitHub runs it (bash -e).
awk '/- name: List commits without a Verified trailer$/{f=1} f && /^        run: \|$/{r=1; next} r && /^          /{print; next} r{exit}' \
  "$ROOT/.github/workflows/ci.yml" | sed 's/^          //' > "$TMP/step.sh"
if [[ -s "$TMP/step.sh" ]]; then pass "the step is in ci.yml"; else fail "the step is in ci.yml" "not found"; fi
mkdir -p tools && cp "$VS" tools/
git update-ref refs/remotes/origin/main main
git checkout -q main && conf observe && git commit -qam observe-for-step && git update-ref refs/remotes/origin/main main && git checkout -q feat
: > "$TMP/summary"
OUT=$(BASE=main GITHUB_STEP_SUMMARY=$TMP/summary bash -e "$TMP/step.sh" 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "observe: the step passes" || fail "observe: the step passes" "rc=$RC $OUT"
has "and writes the list to the job summary" "carry no usable" "$(cat "$TMP/summary")"
git checkout -q main && conf enforce && git commit -qam enforce-for-step && git update-ref refs/remotes/origin/main main && git checkout -q feat
OUT=$(BASE=main GITHUB_STEP_SUMMARY=$TMP/summary bash -e "$TMP/step.sh" 2>&1); RC=$?
[[ $RC -eq 1 ]] && pass "enforce: the step fails" || fail "enforce: the step fails" "rc=$RC $OUT"
cd "$ROOT" || exit 1

echo ""
results
