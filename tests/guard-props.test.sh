#!/usr/bin/env bash
# Tests for tools/guard-props.py: each property holds on the shipped files and
# fails on a mutant of what it checks. Small inputs here; the PR that added it
# records the default run's numbers.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
GP="$PWD/tools/guard-props.py"
command -v python3 >/dev/null && command -v jq >/dev/null \
  || { echo "  SKIP: no python3 or jq"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
gp() { python3 "$GP" "$@" > "$TMP/out" 2>&1; RC=$?; }
mutant() {  # NAME FILE SED: a copy of hooks/ with SED applied to FILE, or a fail when it changed nothing
  rm -rf "${TMP:?}/$1"; cp -R hooks "$TMP/$1"
  sed -E "$3" "hooks/$2" > "$TMP/$1/$2"
  cmp -s "hooks/$2" "$TMP/$1/$2" && fail "test setup" "$1: the edit to $2 changed nothing"
}

echo "=== seed: printed, and the same seed is the same run ==="
gp --only count --n 50 --seed 7; A=$(cat "$TMP/out")
gp --only count --n 50 --seed 7
[ "$A" = "$(cat "$TMP/out")" ] && head -1 "$TMP/out" | grep -q '^guard-props: seed 7 (repeat with --seed 7)' \
  && pass "a seed is printed and repeats its run" || fail "seed" "$(head -2 "$TMP/out")"
gp --only count --n 5 --seed random
head -1 "$TMP/out" | grep -qE '^guard-props: seed [0-9]+ \(repeat with --seed [0-9]+\)' \
  && pass "--seed random prints the seed it drew" || fail "random seed" "$(head -1 "$TMP/out")"

echo ""
echo "=== count: count_mark counts what bytes.count counts ==="
gp --only count --n 300
[ "$RC" = 0 ] && grep -q ': 0 counted wrong\.$' "$TMP/out" && pass "the shipped count_mark" || fail "count" "rc=$RC $(cat "$TMP/out")"
for t in 'len(mark) - 2' 'len(mark)'; do
  sed "s/tail = buf\[-(len(mark) - 1):\]/tail = buf[-($t):]/" bin/disk-space.py > "$TMP/ds.py"
  grep -qF "tail = buf[-($t):]" "$TMP/ds.py" || fail "test setup" "the count_mark tail line was not found"
  gp --only count --n 300 --disk-space "$TMP/ds.py"
  [ "$RC" = 1 ] && grep -q 'count_mark [0-9]*, data.count [0-9]*' "$TMP/out" \
    && pass "a tail of $t bytes fails, and names a file it miscounts" || fail "tail $t" "rc=$RC $(tail -2 "$TMP/out")"
done

echo ""
echo "=== fastpath: a word filter answers as the guard behind it ==="
# Commands a filter mutant answered wrongly on the default run, and two it did not.
for c in 'printenv PATH' "echo hi | 'p'rintenv" "python3 -c \"import subprocess; subprocess.run(['kubectl','delete','pod','x'])\"" \
         'ls -la' 'kubectl get pods'; do
  jq -nc --arg c "$c" '{id: $c, tool_name: "Bash", tool_input: {command: $c}}'
done > "$TMP/c.jsonl"
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl"
[ "$RC" = 0 ] && grep -q 'filters forced in env-guard (1), interpreter-guard (1), kubectl-guard (1), network-guard (1): 0 answered differently' "$TMP/out" \
  && pass "the shipped filters, forced in the four guards that have one" || fail "fastpath" "rc=$RC $(cat "$TMP/out")"
mutant no-printenv env-guard.sh 's/\(env\|printenv\|export/(env|export/'
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl" --hooks "$TMP/no-printenv"
[ "$RC" = 1 ] && grep -q ': 2 answered differently' "$TMP/out" && grep -q '^  printenv PATH: ' "$TMP/out" \
  && pass "env-guard's filter without printenv fails on both printenv commands" || fail "printenv mutant" "rc=$RC $(cat "$TMP/out")"
mutant kubectl-space kubectl-guard.sh "s/^word_filter 'kubectl' /word_filter 'kubectl ' /"
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl" --hooks "$TMP/kubectl-space"
[ "$RC" = 1 ] && grep -q ': 1 answered differently' "$TMP/out" && grep -q "^  python3 -c " "$TMP/out" \
  && pass "kubectl-guard's filter as 'kubectl ' fails on kubectl inside a python list" || fail "kubectl mutant" "rc=$RC $(cat "$TMP/out")"
mutant no-filters kubectl-guard.sh 's/^word_filter .*\|\| exit 0$/:/'
for g in env-guard interpreter-guard network-guard; do sed -E 's/^([ \t]*)word_filter .*\|\| exit 0$/\1:/' "hooks/$g.sh" > "$TMP/no-filters/$g.sh"; done
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl" --hooks "$TMP/no-filters"
[ "$RC" = 2 ] && grep -q 'no `word_filter ... || exit 0` line' "$TMP/out" \
  && pass "with no filter left to force it stops, not passes" || fail "nothing to force" "rc=$RC $(cat "$TMP/out")"

echo ""
echo "=== heredoc: a body strip_inert_heredocs drops cannot change an answer ==="
gp --only heredoc --n 0
[ "$RC" = 0 ] && grep -q ': 0 answered differently' "$TMP/out" && ! grep -q 'rm-guard' "$TMP/out" \
  && pass "the shipped strip, rm-guard (it reads prose bodies) left out" || fail "heredoc" "rc=$RC $(cat "$TMP/out")"
mutant strip-bash lib/command.sh "s/^INERT_SEG='\^\(\(cat\|/INERT_SEG='^((bash|sh|cat|/"
gp --only heredoc --n 0 --hooks "$TMP/strip-bash"
[ "$RC" = 1 ] && grep -q "| bash" "$TMP/out" \
  && pass "a strip that drops a body piped to bash fails" || fail "strip mutant" "rc=$RC $(cat "$TMP/out")"
cp "$TMP/out" "$TMP/strip-bash.out"
# inert_rest keeps an unquoted body holding $ or a backtick, which bash expands; this one drops it.
mutant expand lib/command.sh 's/^(    body \{ if \(hd_end\(\$0\)\) \{ )if \(buf ~ \/\[\$`\]\/\) printf "%s", buf; (body = 0; buf = "" \})$/\1\2/'
gp --only heredoc --n 0 --hooks "$TMP/expand"
[ "$RC" = 1 ] && grep -q ': 1 answered differently' "$TMP/out" && grep -q ' 0 bodies dropped that run' "$TMP/out" \
  && pass "a strip that drops a body bash expands fails on the guards' answers alone" || fail "expand mutant" "rc=$RC $(cat "$TMP/out")"
mutant sh-prose lib/command.sh "s/grep -qvE '\\\\\.\(md\|txt\|rst\|log\|csv\)\\\$'/grep -qvE '\\\\.(md|txt|rst|log|csv|sh)\$'/"
gp --only heredoc --n 0 --hooks "$TMP/sh-prose"
[ "$RC" = 1 ] && grep -q ': 0 answered differently' "$TMP/out" && grep -q '^  dropped: "cat > run.sh' "$TMP/out" \
  && pass "a strip that takes run.sh for prose fails the direct check, which the guards' answers miss" || fail "sh mutant" "rc=$RC $(cat "$TMP/out")"
grep -E '^    corpus: \{' "$TMP/strip-bash.out" | head -1 | sed 's/^    corpus: //' \
  | jq -e '.tool_name == "Bash" and (.id | startswith("props-")) and (.tool_input.command | test("[|] bash"))' >/dev/null \
  && pass "each counterexample comes with a line for tests/bench-corpus.jsonl" || fail "corpus line" "$(grep corpus "$TMP/strip-bash.out" | head -2)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
