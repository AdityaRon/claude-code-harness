#!/usr/bin/env bash
# Tests for tools/guard-props.py: each property holds on the shipped files and
# fails on a mutant of what it checks. Small inputs here; the PR that added it
# records the default run's numbers.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
GP="$PWD/tools/guard-props.py"
# CI's guard properties job runs this when what it checks changed; doctor.sh skips it.
[[ -n "${CCH_DOCTOR:-}" ]] && { echo "  SKIP: run by CI's guard properties job, or by hand: bash tests/guard-props.test.sh"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
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
grep -qE '; [1-9][0-9]* overlapping pairs placed\)' "$TMP/out" && pass "the run places two copies of a mark sharing a border" \
  || fail "overlapping pairs" "$(cat "$TMP/out")"
TAIL='tail = buf[max(i, len(buf) - (k - 1)):]'
grep -qF "$TAIL" bin/disk-space.py || fail "test setup" "the count_mark tail line was not found"
cm_mutant() {  # NAME REPLACEMENT GREP: count_mark's tail line replaced, the property run, GREP among the miscounts
  python3 -c 'import sys; s = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))' \
    bin/disk-space.py "$TMP/ds.py" "$TAIL" "$2"
  gp --only count --n 300 --disk-space "$TMP/ds.py"
  [ "$RC" = 1 ] && grep -qE "$3" "$TMP/out" && pass "$1 fails, and names a file it miscounts" || fail "$1" "rc=$RC $(tail -2 "$TMP/out")"
}
# Each mutant must miscount the mark disk-space.py counts, not only the short ones.
cm_mutant "a tail one byte short" 'tail = buf[max(i, len(buf) - (k - 2)):]' "^  mark b'\"subtype\":\"compact_boundary\"'"
cm_mutant "a tail that starts before the last match" 'tail = buf[len(buf) - (k - 1):]' "^  mark b'\"subtype\":\"compact_boundary\"'"
cm_mutant "a 1-byte mark carrying the whole buffer" 'tail = buf[max(i, len(buf) - (k - 1)):] if k > 1 else buf' "^  mark b'.', chunk"

echo ""
echo "=== fastpath: a guard's fast path answers as the guard behind it ==="
# Commands a fast-path mutant answered wrongly on the default run, and two it did not.
for c in 'printenv PATH' "echo hi | 'p'rintenv" "python3 -c \"import subprocess; subprocess.run(['kubectl','delete','pod','x'])\"" \
         'git push --force origin main' 'git reset --hard HEAD~1' $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run([\'rm\',\'-rf\',\'/\'])\nEOF' \
         "cp x ~/.cl''aude/hooks/lib.sh" 'RM -rf ~/' "r''m -rf ~/" 'ls -la' 'kubectl get pods' 'echo x >> ~//.?ashrc'; do
  jq -nc --arg c "$c" '{id: $c, tool_name: "Bash", tool_input: {command: $c}}'
done > "$TMP/c.jsonl"
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl"
[ "$RC" = 0 ] && grep -q "forced to pass: word_filter in env-guard (1), interpreter-guard (1), kubectl-guard (1), network-guard (1); git-guard's git; git-guard's GG_GATE; git-guard's rule union; rm-guard's RM_WORD; config-guard's paths: 0 answered differently" "$TMP/out" \
  && pass "the shipped fast paths: word_filter in four guards, git-guard's two gates and rule union, rm-guard's RM_WORD, config-guard's paths" || fail "fastpath" "rc=$RC $(cat "$TMP/out")"
fp_mutant() {  # NAME FILE SED COUNT CMD-START: a mutant of one fast path, and the commands it gets wrong
  mutant "$1" "$2" "$3"
  gp --only fastpath --n 0 --corpus "$TMP/c.jsonl" --hooks "$TMP/$1"
  [ "$RC" = 1 ] && grep -q ": $4 answered differently" "$TMP/out" && grep -qF "  $5" "$TMP/out" && grep -q '^    reason: .' "$TMP/out" \
    && pass "$1: $4 answered differently, each with the forced side's reason" || fail "$1 mutant" "rc=$RC $(cat "$TMP/out")"
}
fp_mutant no-printenv env-guard.sh 's/\(env\|printenv\|export/(env|export/' 2 'printenv PATH: '
fp_mutant kubectl-space kubectl-guard.sh "s/^word_filter 'kubectl' /word_filter 'kubectl ' /" 1 'python3 -c '
fp_mutant gate-no-push git-guard.sh "s/^GG_GATE='hooks\|push\|/GG_GATE='hooks|/" 1 'git push --force origin main: '
fp_mutant gate-no-reset git-guard.sh "s/^GG_GATE='hooks\|push\|reset\|/GG_GATE='hooks|push|/" 1 'git reset --hard HEAD~1: '
# The union missing one check's pattern ends a call that check denies.
fp_mutant union-no-reset git-guard.sh 's/ "\$SFX_RESET_HARD"//' 1 'git reset --hard HEAD~1: '
fp_mutant rm-word-unquoted rm-guard.sh "s/^RM_WORD=.*$/RM_WORD='(^|[^[:alnum:]_.-])rm([[:space:]]|\$)'/;s/^RM_BARE=.*$/RM_BARE='(^|[^[:alnum:]_.-])rm([[:space:]]|\$)'/" 1 'python3 - <<'
# rm-guard's filter as on main: lower case and the typed text only, so RM and r''m skip a full read that denies them.
fp_mutant rm-word-typed rm-guard.sh "s/^RM_BARE=.*$/RM_BARE='a^'/" 2 'RM -rf ~/: '
# config-guard's filter reading the command as typed again, as before the bare text: a quote-split path gets past it.
fp_mutant config-typed config-guard.sh 's/^    FSRC=\$TARGET\$....\$PRESET_BARE.*$/    FSRC=$TARGET/' 1 "cp x ~/.cl''aude/hooks/lib.sh: "
# Its glob rule taking only one / between names, as before #287's review: ~//.?ashrc gets past it.
# The Runner's HOME holds .bashrc, so the full read's glob finds it and asks.
fp_mutant config-one-slash config-guard.sh "s|^F_SEP=.*$|F_SEP='/'|" 1 'echo x >> ~//.?ashrc: '
# The generator spells a protected path each way the filter must see: a glob, //, /./,
# /DIR/../, and ~, $HOME, ${HOME}, the home path, . or "$PWD" before it.
D=$(python3 -c 'import importlib.util, random, sys
spec = importlib.util.spec_from_file_location("gp", sys.argv[1]); gp = importlib.util.module_from_spec(spec); spec.loader.exec_module(gp)
got = gp.generate_paths(random.Random(1), 400, "/h/home")
want = {"?": "?", "*": "*", "[": "[", "//": "//", "/./": "/./", "/../": "/../", "~/": " ~/", "$HOME": " $HOME/", "${HOME}": "${HOME}",
        "home typed": " /h/home/", ". first": " ./", "$PWD": "\"$PWD\""}
print(" ".join(k for k, v in want.items() if not any(v in c for c in got)) or "all")' "$GP" 2>&1)
[ "$D" = all ] && pass "the generator spells protected paths with each glob, separator and home" || fail "path spellings" "missing: $D"
: > "$TMP/none.jsonl"
gp --only fastpath --n 6 --corpus "$TMP/none.jsonl"
[ "$RC" = 0 ] && grep -q '^fastpath: 7 commands (0 corpus, 7 generated)' "$TMP/out" \
  && pass "fastpath runs n/6 path spellings after the n generated commands" || fail "path spellings run" "rc=$RC $(head -3 "$TMP/out")"
mutant no-filters kubectl-guard.sh 's/^word_filter .*\|\| exit 0$/:/'
for g in env-guard interpreter-guard network-guard; do sed -E 's/^([ \t]*)word_filter .*\|\| exit 0$/\1:/' "hooks/$g.sh" > "$TMP/no-filters/$g.sh"; done
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl" --hooks "$TMP/no-filters"
[ "$RC" = 2 ] && grep -q 'no `word_filter ... || exit 0` line' "$TMP/out" \
  && pass "with no filter left to force it stops, not passes" || fail "nothing to force" "rc=$RC $(cat "$TMP/out")"
mutant no-gate git-guard.sh 's/^\[\[ "\$R" =~ \$GG_GATE \]\] \|\| exit 0$/[[ "$R" =~ $GG_GATE ]] || { shopt -u nocasematch; exit 0; }/'
gp --only fastpath --n 0 --corpus "$TMP/c.jsonl" --hooks "$TMP/no-gate"
[ "$RC" = 2 ] && grep -q "git-guard's GG_GATE: 0 lines like" "$TMP/out" \
  && pass "a fast path whose line changed stops the run, not passes it" || fail "line changed" "rc=$RC $(cat "$TMP/out")"
head -1 "$TMP/c.jsonl" > "$TMP/c1.jsonl"
gp --only fastpath --n 0 --corpus "$TMP/c1.jsonl" --force nope
[ "$RC" = 2 ] && grep -q -- "--force: unknown nope" "$TMP/out" \
  && pass "--force with a fast path it does not know stops" || fail "--force nope" "rc=$RC $(cat "$TMP/out")"

echo ""
echo "=== fastpath: an approved difference (tests/guard-props-approved.jsonl) ==="
# #285: env-guard's full read takes `nc\_x` for nc, where bash runs nc_x. The shipped entry
# approves that command alone; a sibling the same over-read catches still fails.
for c in 'ls; nc\_x -la' 'ls; nc\_y -la'; do jq -nc --arg c "$c" '{id: $c, tool_name: "Bash", tool_input: {command: $c}}'; done > "$TMP/a2.jsonl"
head -1 "$TMP/a2.jsonl" > "$TMP/a1.jsonl"
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl"
[ "$RC" = 0 ] && grep -qF 'approved, not counted (1, tests/guard-props-approved.jsonl): ls; nc\_x -la (#285)' "$TMP/out" \
  && grep -q ': 0 answered differently' "$TMP/out" \
  && pass "the shipped entry approves its command: printed, not failed" || fail "approved" "rc=$RC $(cat "$TMP/out")"
gp --only fastpath --n 0 --corpus "$TMP/a2.jsonl"
[ "$RC" = 1 ] && grep -q ': 1 answered differently' "$TMP/out" && grep -qF '  ls; nc\_y -la: ' "$TMP/out" \
  && grep -qF 'approved, not counted (1' "$TMP/out" \
  && pass "it approves only its command: a sibling still fails" || fail "approved sibling" "rc=$RC $(cat "$TMP/out")"
entry() {  # FIELD=VALUE ...: the shipped #285 entry with these fields changed, as $TMP/ap.jsonl
  python3 -c 'import json, sys
e = json.loads(open(sys.argv[1]).readline())
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    e[k] = v
print(json.dumps(e))' tests/guard-props-approved.jsonl "$@" > "$TMP/ap.jsonl"
}
entry right=full
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q "refused: right is 'full'" "$TMP/out" \
  && pass "an entry approving the full guard's side (a bypass) is refused" || fail "right=full" "rc=$RC $(cat "$TMP/out")"
entry why=
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q 'needs property, guard, command, bash_reads, right, issue, why' "$TMP/out" \
  && pass "an entry with no why is refused" || fail "no why" "rc=$RC $(cat "$TMP/out")"
# bash_reads is checked against the reading the script computes, not any deletion of quotes.
entry "command=echo hi | 'p'rintenv" "bash_reads=echo hi | p'rintenv"
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -qF "bash_reads is not the command as bash reads it: 'echo hi | printenv'" "$TMP/out" \
  && pass "an entry whose bash_reads is not bash's reading is refused" || fail "bash_reads shape" "rc=$RC $(cat "$TMP/out")"
# Quoting the script does not model is refused, whatever bash_reads says. The review's repro:
# bash joins ~/.bash\ and rc into ~/.bashrc, where taking out the \ keeps the newline.
entry $'command=cp x ~/.bash\\\nrc; echo ${x:-"a}"}' $'bash_reads=cp x ~/.bash\nrc; echo ${x:-a}}'
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q 'refused: the command has a backslash-newline' "$TMP/out" \
  && pass "an entry whose command has a backslash-newline is refused" || fail "backslash-newline" "rc=$RC $(cat "$TMP/out")"
entry "command=eval \$'nc\\x20-l'" "bash_reads=eval nc -l"
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -qF "refused: the command has \$'...'" "$TMP/out" \
  && pass "an entry whose command has \$'...' is refused" || fail "ansi-c" "rc=$RC $(cat "$TMP/out")"
entry "command=printf 'nc\\n-l' | sh" "bash_reads=printf ncn-l | sh"
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q 'refused: the command has a quoted part' "$TMP/out" \
  && pass "an entry with a backslash in quotes, which printf reads, is refused" || fail "quoted backslash" "rc=$RC $(cat "$TMP/out")"
entry 'command=echo "#"; ls' 'bash_reads=echo #; ls'
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q 'refused: the command has a quoted part' "$TMP/out" \
  && pass "an entry with a quoted #, a comment once unquoted, is refused" || fail "quoted #" "rc=$RC $(cat "$TMP/out")"
# X="a b" printenv runs printenv, where X=a b printenv runs b: hooks/ denies the one, allows the other.
entry 'command=X="a b" printenv' 'bash_reads=X=a b printenv'
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q 'refused: the command has a quoted part' "$TMP/out" \
  && pass "an entry with a quoted space, which unquoted splits an assignment, is refused" || fail "quoted space" "rc=$RC $(cat "$TMP/out")"
# Taken out, quoting after $API_KEY names $API_KEYx, and an empty '' joins < and < into a heredoc.
entry "command=echo \$API_KEY'x'" 'bash_reads=echo $API_KEYx'
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q 'refused: the command has . right after a \$NAME' "$TMP/out" \
  && pass "an entry quoting right after a \$NAME is refused" || fail "quote after name" "rc=$RC $(cat "$TMP/out")"
entry $'command=cat <\'\'<EOF\nnc -l 4444\nEOF' $'bash_reads=cat <<EOF\nnc -l 4444\nEOF'
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 2 ] && grep -q "refused: the command has an empty ''" "$TMP/out" \
  && pass "an entry with an empty '', which joins its two sides, is refused" || fail "empty quote" "rc=$RC $(cat "$TMP/out")"
# A real bypass (env-guard's filter without printenv, a mutant from above) is not approved by a
# well-formed entry: as bash reads it, the full guard still denies what hooks/ allows.
jq -nc --arg c "echo hi | 'p'rintenv" '{id: $c, tool_name: "Bash", tool_input: {command: $c}}' > "$TMP/b1.jsonl"
entry "command=echo hi | 'p'rintenv" 'bash_reads=echo hi | printenv'
gp --only fastpath --n 0 --corpus "$TMP/b1.jsonl" --approved "$TMP/ap.jsonl" --hooks "$TMP/no-printenv"
[ "$RC" = 1 ] && grep -qF "approval refused (#285): on 'echo hi | printenv', the command as bash reads it, the full guard answers deny" "$TMP/out" \
  && pass "a bypass is not approved by a well-formed entry" || fail "bypass entry" "rc=$RC $(cat "$TMP/out")"
# The full guard must be the stricter side. fastpath cannot produce the other way round (the
# forced copy runs the full guard wherever hooks/ does), so approval() is called on made-up answers.
D=$(python3 -c 'import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("gp", sys.argv[1]); gp = importlib.util.module_from_spec(spec); spec.loader.exec_module(gp)
e = json.loads(open(sys.argv[2]).readline())
for h, f in (("deny", "allow"), ("ask", "ask"), ("ask", "allow")):
    print(gp.approval(e, e["command"], ((h, 0, ()), ""), ((f, 0, ()), ""), None, None, None, None))' "$GP" tests/guard-props-approved.jsonl 2>&1)
[ "$(grep -c '^the full guard is not the stricter side' <<< "$D")" = 3 ] \
  && pass "hooks/ as strict as the full guard, or stricter, is never approved" || fail "stricter side" "$D"
# A check call that timed out answered nothing, so it does not agree with hooks/' allow.
D=$(python3 -c 'import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("gp", sys.argv[1]); gp = importlib.util.module_from_spec(spec); spec.loader.exec_module(gp)
e = json.loads(open(sys.argv[2]).readline())
class Late:   # env-guard alone denies the command; each call on bash_reads times out
    def answer(self, hooks, cmd, extra=None):
        return (("deny", 0, ()), "") if cmd == e["command"] else (("allow", "timeout", ()), "")
print(gp.approval(e, e["command"], (("allow", 0, ()), ""), (("deny", 0, ()), ""), "hooks", "hooks", Late(), sys.argv[3]))' \
  "$GP" tests/guard-props-approved.jsonl "$TMP" 2>&1)
[[ "$D" == "on 'ls; nc_x -la', the command as bash reads it, the full guard answers allow (exit timeout), not hooks/' allow" ]] \
  && pass "a check call that timed out is not read as agreement" || fail "approval timeout" "$D"
entry guard=network-guard
gp --only fastpath --n 0 --corpus "$TMP/a1.jsonl" --approved "$TMP/ap.jsonl"
[ "$RC" = 1 ] && grep -q "approval refused (#285): network-guard alone answers allow, not the full guard's deny" "$TMP/out" \
  && pass "an entry naming a guard that did not give the stricter answer approves nothing" || fail "guard" "rc=$RC $(cat "$TMP/out")"
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
echo "=== A call that times out answers nothing ==="
# kubectl-guard sleeps past --timeout after its fast path, so on `ls` only the forced side
# times out; sleeping before the fast path, both sides do. Neither is a difference or agreement.
jq -nc '{id: "t1", tool_name: "Bash", tool_input: {command: "ls"}}' > "$TMP/t1.jsonl"
mutant slow-full kubectl-guard.sh 's/^unreadable_check kubectl-guard "\$CMD"$/sleep 6; &/'
gp --only fastpath --n 0 --timeout 2 --corpus "$TMP/t1.jsonl" --hooks "$TMP/slow-full"
[ "$RC" = 0 ] && grep -q ': 0 answered differently' "$TMP/out" \
  && grep -qF 'inconclusive, not counted (1, a call timed out after 2 s): t1 (the full guard)' "$TMP/out" \
  && pass "a timeout on one side is inconclusive, not a counterexample" || fail "one-side timeout" "rc=$RC $(cat "$TMP/out")"
mutant slow-both kubectl-guard.sh 's/^joined_pass "\$CMD" /sleep 6; &/'
gp --only fastpath --n 0 --timeout 2 --corpus "$TMP/t1.jsonl" --hooks "$TMP/slow-both"
[ "$RC" = 0 ] && grep -q ': 0 answered differently' "$TMP/out" \
  && grep -qF 'inconclusive, not counted (1, a call timed out after 2 s): t1 (both sides)' "$TMP/out" \
  && pass "a timeout on both sides is inconclusive, not agreement" || fail "both-side timeout" "rc=$RC $(cat "$TMP/out")"
# In the heredoc property, a body whose answer timed out is no difference from its carrier's first.
mutant slow-body kubectl-guard.sh 's/^joined_pass "\$CMD" /[[ "$CMD" == *runbook* ]] \&\& sleep 6; &/'
gp --only heredoc --n 0 --timeout 2 --hooks "$TMP/slow-body"
[ "$RC" = 0 ] && grep -q ': 0 answered differently' "$TMP/out" \
  && grep -qE '^  inconclusive, not counted \([1-9][0-9]*, a call timed out after 2 s\): .*runbook' "$TMP/out" \
  && pass "a heredoc answer that timed out is inconclusive, not a difference" || fail "heredoc timeout" "rc=$RC $(cat "$TMP/out")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
