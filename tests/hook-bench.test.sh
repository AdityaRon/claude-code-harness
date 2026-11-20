#!/usr/bin/env bash
# Tests for tools/hook-bench.py on a fixture repo with stub hooks: the gate goes
# red on a slower hook and on a decision change nobody declared, stays green
# A/A, and wait is a call's hooks launched together (about the slowest, not the
# sum), or with --serial the slowest of each alone.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
BENCH="$PWD/tools/hook-bench.py"
CORPUS="$PWD/tests/bench-corpus.jsonl"
command -v python3 >/dev/null || { echo "  SKIP: no python3"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

echo "=== the shipped corpus is well formed ==="
N=$(jq -r '.id' "$CORPUS" | wc -l | tr -d ' ')
D=$(jq -r '.id' "$CORPUS" | sort | uniq -d | wc -l | tr -d ' ')
[ "$D" = 0 ] && pass "$N payload ids, none duplicated" || fail "duplicate ids" "$(jq -r '.id' "$CORPUS" | sort | uniq -d | head -3)"
NB=$(jq -r 'select(.tool_name == "Bash") | .id' "$CORPUS" | wc -l | tr -d ' ')
[ "$NB" -ge 300 ] && [ "$((N - NB))" -ge 100 ] \
  && pass "at least 300 Bash and 100 file/web payloads ($NB, $((N - NB)))" || fail "corpus size" "$NB Bash, $((N - NB)) other"
jq -e 'all(has("id") and has("tool_name") and (.tool_input | type == "object"))' -s "$CORPUS" >/dev/null \
  && pass "every payload has id, tool_name and a tool_input object" || fail "payload shape" ""

# A fixture repo: two Bash hooks (one asks on "danger"), one Write/Edit hook,
# one async hook that must be ignored.
FIX="$TMP/fix"; mkdir -p "$FIX/hooks" "$FIX/config"
cat > "$FIX/hooks/fast.sh" <<'SH'
#!/usr/bin/env bash
INPUT=$(cat); sleep 0.12
case "$INPUT" in *danger*) echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"x"}}' ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 0.15; exit 0\n' > "$FIX/hooks/second.sh"
cat > "$FIX/hooks/file.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"x"}}'
SH
cat > "$FIX/config/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/fast.sh"},{"type":"command","command":"~/.claude/hooks/second.sh"}]},
  {"matcher":"Write|Edit","hooks":[{"type":"command","command":"~/.claude/hooks/file.sh"}]},
  {"matcher":"ExitPlanMode","hooks":[{"type":"command","command":"~/.claude/hooks/missing.sh","async":true}]}]}}
JSON
( cd "$FIX" && git init -q && git -c user.email=t@example.com -c user.name=t add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm base && git tag v0.1.0 ) || { echo "fixture failed"; exit 1; }
{ for i in 1 2 3 4 5 6; do jq -nc --arg id "bash-$i" --arg c "echo $i" '{id:$id,tool_name:"Bash",tool_input:{command:$c}}'; done
  jq -nc '{id:"danger",tool_name:"Bash",tool_input:{command:"danger"}}'
  jq -nc '{id:"write-1",tool_name:"Write",tool_input:{file_path:"/x",content:"y"}}'
  jq -nc '{id:"read-1",tool_name:"Read",tool_input:{file_path:"/x"}}'; } > "$TMP/corpus.jsonl"

# --min-calls 5: the fixture's Bash class has 7 calls, its Write class one.
run() { python3 "$BENCH" --repo "$FIX" --corpus "$TMP/corpus.jsonl" --json "$TMP/out.json" --md "$TMP/out.md" --min-calls 5 "$@" >/dev/null 2>"$TMP/err"; }
jqo() { jq -r "$1" "$TMP/out.json"; }

echo ""
echo "=== A/A: same ref on both sides passes the gate ==="
# --floor-ms 100000 where speed is not under test: seven sleep-based calls on a
# loaded macOS runner wobbled past a 50 ms floor (run 39048457929).
run --base v0.1.0 --head v0.1.0 --gate --floor-ms 100000; RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $(cat "$TMP/err")"
[ "$(jqo '.classes.Bash.base.wait.n')" = 7 ] && pass "7 Bash calls counted" || fail "Bash calls" "$(jqo '.classes.Bash.base.wait.n')"
# second.sh sleeps 150 ms and fast.sh 120 ms, launched together: the call cannot end
# before second.sh's sleep, and stays well short of the two one after the other. fast.sh
# was 30 ms until a loaded macOS runner put the max at the sum: wait 283 ms, hooks 79 and
# 203 ms (run 44438931985); the gap is now fast.sh's 120 ms, not 30. The
# floor is the sleep, not second.sh's measured time alone: that is a separate run, and
# on a loaded macOS runner the two differed by 15 ms (run 43522592163). With equal
# hooks, noisy medians on macOS put the median of the max at the sum (run 39076417023).
jq -e '.classes.Bash.base.wait.p50 >= 150
       and .classes.Bash.base.wait.p50 < (.hooks["fast.sh"].base.wall.p50 + .hooks["second.sh"].base.wall.p50 - 10)' \
  "$TMP/out.json" >/dev/null \
  && pass "wait is about the slowest hook of a call, not the sum" \
  || fail "wait is a max" "$(jqo '[.classes.Bash.base.wait.p50, .hooks["fast.sh"].base.wall.p50, .hooks["second.sh"].base.wall.p50]')"
[ "$(jqo '.together')" = true ] && grep -q 'launched together as Claude Code does' "$TMP/out.md" \
  && pass "a call's hooks are launched together by default" || fail "together by default" "$(jqo '.together')"
run --base v0.1.0 --head v0.1.0 --serial --floor-ms 100000
[ "$(jqo '.together')" = false ] && grep -q 'run one at a time' "$TMP/out.md" \
  && jq -e '.classes.Bash.base.wait.p50 >= ([.hooks["fast.sh"].base.wall.p50, .hooks["second.sh"].base.wall.p50] | max) - 1' "$TMP/out.json" >/dev/null \
  && pass "--serial: each hook alone, wait the slowest" || fail "--serial" "$(jqo '[.together, .classes.Bash.base.wait.p50]')"
run --base v0.1.0 --head v0.1.0 --gate --floor-ms 100000
[ "$(jqo '.hooks["fast.sh"].base.wall.n')" = 7 ] && [ "$(jqo '.hooks["file.sh"].base.wall.n')" = 1 ] \
  && pass "hooks fire by matcher: fast.sh on 7 Bash calls, file.sh on 1 Write" || fail "matchers" "$(jqo '.hooks | keys')"
[ "$(jqo '.hooks | has("missing.sh")')" = false ] && pass "an async hook is not run" || fail "async hook ran" ""
[ "$(jqo '.decisions.same')" = 9 ] && pass "9 of 9 decisions the same" || fail "decisions" "$(jqo '.decisions')"
grep -q '^| Bash | 7 |' "$TMP/out.md" && pass "markdown table has the Bash row" || fail "markdown" "$(head -8 "$TMP/out.md")"
[ "$(jqo '.process_start_ms["bash -c :"] > 0')" = true ] && pass "process start cost measured" || fail "start cost" ""
[ "$(jqo '.process_start_ms["true"] > 0')" = true ] && pass "the bare exec floor (true) measured" || fail "exec floor" "$(jqo '.process_start_ms')"
# second.sh sleeps 150 ms: its p50 past one bash start is its wall p50 less `bash -c :`.
PAST=$(awk -F'|' '$2 ~ /^ second\.sh / { gsub(/ ms /, "", $7); split($7, v, "→"); printf "%.1f", v[2] }' "$TMP/out.md")
WANT=$(jq -r '.hooks["second.sh"].head.wall.p50 - .process_start_ms["bash -c :"] | . * 10 | round / 10' "$TMP/out.json")
awk -v a="${PAST:-0}" -v b="${WANT:-x}" 'BEGIN { d = a - b; exit !(b + 0 >= 100 && d < 0.11 && d > -0.11) }' \
  && pass "a hook's p50 past bash start is its wall p50 less bash -c : (second.sh: $PAST ms)" \
  || fail "p50 past bash start" "column $PAST, wall p50 less floor $WANT"

echo ""
echo "=== a decision change in the working tree fails the gate unless intended ==="
sed -i.bak 's/"ask"/"deny"/' "$FIX/hooks/fast.sh" && rm -f "$FIX/hooks/fast.sh.bak"
run --base v0.1.0 --head worktree --gate; RC=$?
[ "$RC" = 1 ] && pass "exit 1" || fail "exit 1" "rc=$RC"
jqo '.gate.failures[]' | grep -q 'decision changed without --intended: danger ask → deny' \
  && pass "the changed payload is named" || fail "failure names the payload" "$(jqo '.gate.failures')"
[ "$(jqo '.decisions.changed | length')" = 1 ] && pass "one changed decision" || fail "changed count" "$(jqo '.decisions.changed')"
grep -q '| danger `danger` | ask (fast.sh) | deny (fast.sh) |' "$TMP/out.md" \
  && pass "markdown lists it with the deciding hook" || fail "markdown diff" "$(grep danger "$TMP/out.md")"
run --base v0.1.0 --head worktree --gate --intended "other,danger" --floor-ms 100000; RC=$?
[ "$RC" = 0 ] && pass "--intended danger passes" || fail "--intended" "rc=$RC $(jqo '.gate.failures')"
run --base v0.1.0 --head worktree; RC=$?
[ "$RC" = 0 ] && pass "without --gate the exit is 0 either way" || fail "no gate" "rc=$RC"
( cd "$FIX" && git checkout -q -- hooks/fast.sh )

echo ""
echo "=== together: the hooks of a call run at the same time, and each is waited for to its end ==="
# A second fixture. Its base runs b.sh alone on Bash; its head adds a.sh, which
# holds a marker while b.sh looks for it. Together b.sh sees the marker and
# allows; one at a time it cannot, and denies. Read, WebFetch and Write each get
# a hook that is slow in a way the old together code did not count or bound.
F2="$TMP/fix2"; mkdir -p "$F2/hooks" "$F2/config"
export MARK="$TMP/mark"
printf '#!/usr/bin/env bash\ncat >/dev/null; : > "$MARK"; sleep 0.4; rm -f "$MARK"\n' > "$F2/hooks/a.sh"
cat > "$F2/hooks/b.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$MARK" ] && exit 0; sleep 0.03; done
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no marker"}}'
SH
printf '#!/usr/bin/env bash\ncat >/dev/null; ( sleep 0.5 ) &\nexit 0\n' > "$F2/hooks/c.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null; ( sleep 20 ) &\nsleep 20\n' > "$F2/hooks/d.sh"
printf '#!/usr/bin/env bash\nhead -c 300000 /dev/zero | tr "\\\\0" x; cat >/dev/null\n' > "$F2/hooks/e.sh"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/b.sh"}]}]}}' > "$F2/config/settings.json"
( cd "$F2" && git init -q && git -c user.email=t@example.com -c user.name=t add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm base && git tag v0.1.0 ) || { echo "fixture 2 failed"; exit 1; }
cat > "$F2/config/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/a.sh"},{"type":"command","command":"~/.claude/hooks/b.sh"}]},
  {"matcher":"Read","hooks":[{"type":"command","command":"~/.claude/hooks/c.sh"}]},
  {"matcher":"WebFetch","hooks":[{"type":"command","command":"~/.claude/hooks/d.sh"}]},
  {"matcher":"Write","hooks":[{"type":"command","command":"~/.claude/hooks/e.sh"}]}]}}
JSON
for i in 1 2 3; do jq -nc --arg id "b-$i" '{id:$id,tool_name:"Bash",tool_input:{command:"echo hi"}}'; done > "$TMP/c2a.jsonl"
{ jq -nc '{id:"r-1",tool_name:"Read",tool_input:{file_path:"/x"}}'
  jq -nc '{id:"w-1",tool_name:"WebFetch",tool_input:{url:"https://example.com/"}}'
  jq -nc --arg big "$(head -c 300000 /dev/zero | tr '\0' y)" '{id:"big-1",tool_name:"Write",tool_input:{file_path:"/x",content:$big}}'; } > "$TMP/c2b.jsonl"
run2() { python3 "$BENCH" --repo "$F2" --base v0.1.0 --head worktree --json "$TMP/out2.json" --md "$TMP/out2.md" --min-calls 1 "$@" >/dev/null 2>"$TMP/err2"; }
run2 --corpus "$TMP/c2a.jsonl"
[ "$(jq '.decisions.changed | length' "$TMP/out2.json")" = 3 ] \
  && pass "together: b.sh sees a.sh's marker, so all 3 calls change deny to allow" \
  || fail "together runs hooks at once" "$(jq -c '.decisions.changed' "$TMP/out2.json") $(cat "$TMP/err2")"
run2 --corpus "$TMP/c2a.jsonl" --serial
[ "$(jq '.decisions.changed | length' "$TMP/out2.json")" = 0 ] \
  && pass "--serial: one at a time b.sh never sees it, and still denies" \
  || fail "--serial runs hooks alone" "$(jq -c '.decisions.changed' "$TMP/out2.json")"
S0=$SECONDS
run2 --corpus "$TMP/c2b.jsonl" --hook-timeout 2
EL=$((SECONDS - S0))
[ "$(jq '.classes["Read/Grep"].head.wait.p50 >= 450' "$TMP/out2.json")" = true ] \
  && pass "a background child holding the hook's output is waited for" \
  || fail "waited to the pipes' close" "$(jq '.classes["Read/Grep"].head.wait' "$TMP/out2.json")"
grep -q '| w-1 ' "$TMP/out2.md" && grep '| w-1 ' "$TMP/out2.md" | grep -q 'error' \
  && [ "$(jq '.classes.WebFetch.head.wait.p50 < 4000' "$TMP/out2.json")" = true ] \
  && pass "a hook past --hook-timeout is an error, and the call ends near the timeout" \
  || fail "timeout bound" "$(grep '| w-1 ' "$TMP/out2.md") $(jq '.classes.WebFetch.head.wait' "$TMP/out2.json")"
[ "$(jq '.classes["Write/Edit"].head.wait.p50 < 1500' "$TMP/out2.json")" = true ] \
  && pass "300 KB in and out does not deadlock" || fail "no deadlock" "$(jq '.classes["Write/Edit"].head.wait' "$TMP/out2.json")"
[ "$EL" -le 30 ] && pass "the run took ${EL}s with two 20 s hooks in it" || fail "bounded run" "${EL}s"

echo ""
echo "=== a slower hook fails the gate; both the limit and the floor must be crossed ==="
# +300 ms, not +40: a loaded macOS runner took ~200 ms for a 30 ms hook, and
# +40 ms there was under 20% at p50 (run 39006980186).
printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 0.45; exit 0\n' > "$FIX/hooks/second.sh"
run --base v0.1.0 --head worktree --gate; RC=$?
[ "$RC" = 1 ] && pass "exit 1 on +300 ms" || fail "slow exit" "rc=$RC"
jqo '.gate.failures[]' | grep -q '^Bash wait p50' && pass "Bash p50 named" || fail "p50 named" "$(jqo '.gate.failures')"
jqo '.gate.failures[]' | grep -q '^Write/Edit' && fail "Write/Edit untouched" "$(jqo '.gate.failures')" || pass "Write/Edit untouched"
run --base v0.1.0 --head worktree --gate --floor-ms 1000; RC=$?
[ "$RC" = 0 ] && pass "under the floor it passes" || fail "floor" "rc=$RC"
run --base v0.1.0 --head worktree --gate --limit-pct 1000; RC=$?
[ "$RC" = 0 ] && pass "under the limit it passes" || fail "limit" "rc=$RC"
run --base v0.1.0 --head worktree --gate --min-calls 20; RC=$?
[ "$RC" = 0 ] && pass "a class under --min-calls is reported, not gated" || fail "min-calls" "rc=$RC $(jqo '.gate.failures')"
( cd "$FIX" && git checkout -q -- hooks/second.sh )

echo ""
echo "=== a hook one side registers but does not ship is skipped, not a crash ==="
jq '.hooks.PreToolUse[0].hooks += [{"type":"command","command":"~/.claude/hooks/ghost.sh"}]' "$FIX/config/settings.json" > "$TMP/s.json" \
  && cp "$TMP/s.json" "$FIX/config/settings.json"
run --base v0.1.0 --head worktree --gate --floor-ms 100000; RC=$?
[ "$RC" = 0 ] && [ "$(jqo '.hooks | has("ghost.sh")')" = false ] && pass "ghost.sh ignored" || fail "ghost" "rc=$RC $(cat "$TMP/err")"
( cd "$FIX" && git checkout -q -- config/settings.json )

echo ""
echo "=== --quick takes every third payload; a missing base ref is an error ==="
run --base v0.1.0 --head v0.1.0 --quick; RC=$?
[ "$RC" = 0 ] && [ "$(jqo '.corpus.count')" = 3 ] && pass "3 of 9" || fail "quick" "rc=$RC $(jqo '.corpus.count')"
run --base nope --head v0.1.0; RC=$?
[ "$RC" = 2 ] && pass "exit 2 on a bad ref" || fail "bad ref" "rc=$RC"

echo ""
echo "=== --launches: the processes each hook starts, per payload, on a copy of the real hooks ==="
F3="$TMP/fix3"; mkdir -p "$F3/config"
cp -R "$PWD/hooks" "$F3/hooks"; cp "$PWD/config/settings.json" "$F3/config/settings.json"
( cd "$F3" && git init -q && git -c user.email=t@example.com -c user.name=t add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm base && git tag base ) || { echo "fixture failed"; exit 1; }
{ jq -nc '{id:"ls",tool_name:"Bash",tool_input:{command:"ls -la"}}'
  jq -nc '{id:"git",tool_name:"Bash",tool_input:{command:"git status"}}'
  jq -nc '{id:"kube",tool_name:"Bash",tool_input:{command:"kubectl get pods"}}'; } > "$TMP/c3.jsonl"
launches() {   # launches METHOD: base vs the worktree, counted; sets LRC
  python3 "$BENCH" --repo "$F3" --corpus "$TMP/c3.jsonl" --base base --head worktree --launches "$1" \
    --json "$TMP/l.json" --md "$TMP/l.md" >/dev/null 2>"$TMP/lerr"; LRC=$?
}
# Per payload, head less base: index 0 is execs, 1 forks.
delta() { jq -c --arg h "$1" --argjson i "$2" '[.launches.per_payload | to_entries[] | (.value.head[$h][$i] - .value.base[$h][$i])]' "$TMP/l.json" 2>/dev/null; }
add_line() {   # add_line TEXT: a line in the worktree's bash-guards.sh, after it reads the payload
  ( cd "$F3" && git checkout -q -- hooks )
  awk -v l="$1" '{ print } /^read_input$/ { print l }' "$F3/hooks/bash-guards.sh" > "$TMP/bg" && cat "$TMP/bg" > "$F3/hooks/bash-guards.sh"
  grep -qxF "$1" "$F3/hooks/bash-guards.sh" || fail "test setup" "the read_input line was not found"
}
STRACE=no
command -v strace >/dev/null && strace -f -o /dev/null true 2>/dev/null && STRACE=yes

launches shim
[ "$LRC" = 0 ] && [ "$(jq -r '.launches.method' "$TMP/l.json")" = shim ] \
  && [ "$(delta bash-guards.sh 0)" = '[0,0,0]' ] && [ "$(jq -c '[.launches.per_payload[].base["bash-guards.sh"][0] >= 1] | all' "$TMP/l.json")" = true ] \
  && pass "shim, same files both sides: bash-guards starts the same, at least its jq" || fail "shim A/A" "rc=$LRC $(cat "$TMP/lerr") $(jq -c '.launches.per_payload' "$TMP/l.json" 2>/dev/null)"
grep -q '^Processes started: execs found through PATH only' "$TMP/l.md" && grep -q '^| bash-guards.sh | 3 | ' "$TMP/l.md" \
  && pass "the markdown has the count table, labelled execs through PATH" || fail "shim markdown" "$(grep -A4 'Processes started' "$TMP/l.md")"
# docs/guards.md: `ls -la` starts one program, the dispatcher's jq; the hook's own bash is not one.
[ "$(jq -c '.launches.per_payload.ls.base["bash-guards.sh"][0]' "$TMP/l.json")" = 1 ] \
  && pass "shim: ls -la is one exec in bash-guards, jq" || fail "shim: ls -la" "$(jq -c '.launches.per_payload.ls' "$TMP/l.json")"
# subagent-cache-guard runs dirname before it loads lib.sh: the shims are first on the PATH it starts with too.
[ "$(jq -c '.launches.per_payload.ls.base["subagent-cache-guard.sh"][0]' "$TMP/l.json")" = 1 ] \
  && pass "shim: subagent-cache-guard's dirname, before lib.sh" || fail "shim: before lib.sh" "$(jq -c '.launches.per_payload.ls' "$TMP/l.json")"
if [ "$STRACE" = yes ]; then
  launches strace
  [ "$LRC" = 0 ] && [ "$(jq -c '.launches.per_payload.ls.base["bash-guards.sh"][0]' "$TMP/l.json")" = 1 ] && [ "$(delta bash-guards.sh 1)" = '[0,0,0]' ] \
    && pass "strace, same files: ls -la is the same one exec, and no payload's forks differ" || fail "strace A/A" "rc=$LRC $(cat "$TMP/lerr") $(jq -c '.launches.per_payload' "$TMP/l.json" 2>/dev/null)"
fi

# `true` is a bash builtin and starts nothing; with the builtin off, `true` is the program on PATH.
add_line 'enable -n true; true; enable true'
launches shim
[ "$(delta bash-guards.sh 0)" = '[1,1,1]' ] && [ "$(delta subagent-cache-guard.sh 0)" = '[0,0,0]' ] \
  && pass "shim: one added external true is exactly one exec more on each payload, in that hook only" \
  || fail "shim: one true" "bash-guards $(delta bash-guards.sh 0), subagent-cache-guard $(delta subagent-cache-guard.sh 0) $(cat "$TMP/lerr")"
if [ "$STRACE" = yes ]; then
  launches strace
  [ "$(delta bash-guards.sh 0)" = '[1,1,1]' ] && [ "$(delta bash-guards.sh 1)" = '[1,1,1]' ] && [ "$(delta subagent-cache-guard.sh 0)" = '[0,0,0]' ] \
    && pass "strace: one added external true is one exec and one fork more on each payload" \
    || fail "strace: one true" "execs $(delta bash-guards.sh 0) forks $(delta bash-guards.sh 1) $(cat "$TMP/lerr")"
else
  echo "  SKIP: no strace here; the strace cases run on Linux CI"
fi

# env finds true by trying each PATH folder with execve: lib.sh's /opt/homebrew/bin and
# /usr/local/bin first. Those tries fail and start nothing; env and true are two execs.
add_line 'env true'
launches shim
[ "$(delta bash-guards.sh 0)" = '[2,2,2]' ] && pass "shim: an added env true is two execs, env and true" || fail "shim: env true" "$(delta bash-guards.sh 0)"
if [ "$STRACE" = yes ]; then
  launches strace
  [ "$(delta bash-guards.sh 0)" = '[2,2,2]' ] && pass "strace: an added env true is two execs; the execve tries that failed are not counted" \
    || fail "strace: env true" "execs $(delta bash-guards.sh 0) forks $(delta bash-guards.sh 1)"
fi

echo ""
echo "=== --gate with --launches: a payload whose hooks start more fails unless --intended-launches names it ==="
gate() {   # gate METHOD [ARGS]: base vs the worktree with --gate; sets LRC
  python3 "$BENCH" --repo "$F3" --corpus "$TMP/c3.jsonl" --base base --head worktree --launches "$1" --gate "${@:2}" \
    --json "$TMP/l.json" --md "$TMP/l.md" >/dev/null 2>"$TMP/lerr"; LRC=$?
}
gfail() { jq -r '.gate.failures[]' "$TMP/l.json" 2>/dev/null | sort | tr '\n' '|'; }
add_line 'enable -n true; true; enable true'
gate shim
[ "$LRC" = 1 ] && [ "$(gfail)" = "launches grew without --intended-launches: git 2 → 3|launches grew without --intended-launches: kube 12 → 13|launches grew without --intended-launches: ls 2 → 3|" ] \
  && pass "one exec more on every payload: the gate fails and names each, base → head over its hooks" || fail "launch gate" "rc=$LRC $(gfail) $(cat "$TMP/lerr")"
grep -q "no payload's hooks may start more processes unless intended" "$TMP/l.md" && pass "the gate line says so" || fail "gate line" "$(grep Gate "$TMP/l.md")"
gate shim --intended-launches 'ls git,kube'
[ "$LRC" = 0 ] && [ "$(jq -c '.gate.intended_launches' "$TMP/l.json")" = '["git","kube","ls"]' ] \
  && pass "--intended-launches naming all three passes" || fail "intended-launches" "rc=$LRC $(gfail)"
gate shim --intended-launches ls
[ "$LRC" = 1 ] && [ "$(gfail)" = "launches grew without --intended-launches: git 2 → 3|launches grew without --intended-launches: kube 12 → 13|" ] \
  && pass "naming one leaves the other two failing" || fail "intended one" "rc=$LRC $(gfail)"
gate shim --intended-launches all
[ "$LRC" = 0 ] && pass "--intended-launches all passes" || fail "intended all" "rc=$LRC $(gfail)"
gate shim --intended 'ls git kube'
[ "$LRC" = 1 ] && pass "--intended (decisions) does not stand in for --intended-launches" || fail "intended is not intended-launches" "rc=$LRC"
# Fewer: base is the commit with the extra exec, head the files without it.
( cd "$F3" && git -c user.email=t@example.com -c user.name=t commit -qam more && git tag more && git checkout -q base -- hooks )
python3 "$BENCH" --repo "$F3" --corpus "$TMP/c3.jsonl" --base more --head worktree --launches shim --gate \
  --json "$TMP/l.json" --md "$TMP/l.md" >/dev/null 2>"$TMP/lerr"; LRC=$?
[ "$LRC" = 0 ] && [ "$(jq -c '.launches.table["bash-guards.sh"] | [.more, .fewer]' "$TMP/l.json")" = '[0,3]' ] \
  && pass "fewer on every payload passes" || fail "fewer" "rc=$LRC $(gfail)"
( cd "$F3" && git checkout -q base 2>/dev/null; git checkout -q -- hooks )
if [ "$STRACE" = yes ]; then
  add_line ': "$( : )"'
  gate strace
  [ "$LRC" = 1 ] && [ "$(gfail | tr '|' '\n' | grep -c 'launches grew without --intended-launches')" = 3 ] \
    && pass "strace: one fork more, no exec, still fails the gate on every payload" || fail "strace fork gate" "rc=$LRC $(gfail)"
fi

add_line ': "$( : )"'
launches shim
[ "$(delta bash-guards.sh 0)" = '[0,0,0]' ] && pass "shim: an added \$( : ) starts no program, and the shim sees no fork" || fail "shim: \$( : )" "$(delta bash-guards.sh 0)"
if [ "$STRACE" = yes ]; then
  launches strace
  [ "$(delta bash-guards.sh 1)" = '[1,1,1]' ] && [ "$(delta bash-guards.sh 0)" = '[0,0,0]' ] \
    && pass "strace: an added \$( : ) is one fork more on each payload, and no exec" \
    || fail "strace: \$( : )" "execs $(delta bash-guards.sh 0) forks $(delta bash-guards.sh 1) $(cat "$TMP/lerr")"
  grep -q '^Processes started: each hook run alone once per payload under `strace -f`' "$TMP/l.md" \
    && pass "the strace table says what it counts" || fail "strace markdown" "$(grep -A4 'Processes started' "$TMP/l.md")"
else
  launches strace
  [ "$LRC" = 2 ] && grep -q 'strace is not installed here, or may not trace' "$TMP/lerr" \
    && pass "--launches strace with no strace: exit 2, never a count of 0" || fail "no strace" "rc=$LRC $(cat "$TMP/lerr")"
fi

# A run past --hook-timeout is not counted, and says so: never a 0 a later gate would read as fewer.
add_line 'sleep 4'
head -1 "$TMP/c3.jsonl" > "$TMP/c1.jsonl"
python3 "$BENCH" --repo "$F3" --corpus "$TMP/c1.jsonl" --base base --head worktree --launches shim --hook-timeout 2 \
  --gate --intended ls --intended-launches all --json "$TMP/l.json" --md "$TMP/l.md" >/dev/null 2>"$TMP/lerr"; LRC=$?
[ "$(jq -c '.launches.per_payload.ls | [.base["bash-guards.sh"][0], .head["bash-guards.sh"]]' "$TMP/l.json")" = '[1,null]' ] \
  && grep -qE '^\| bash-guards\.sh \|.*\| 1 \|$' "$TMP/l.md" \
  && pass "a hook that runs past the timeout: null for that payload, and 1 not counted" || fail "timeout" "$(jq -c '.launches.per_payload' "$TMP/l.json" 2>/dev/null) $(grep bash-guards "$TMP/l.md" | tail -1)"
[ "$LRC" = 1 ] && [ "$(gfail)" = "launches not counted on head: ls|" ] \
  && pass "the gate fails a payload a side could not count, even with --intended-launches all" || fail "gate on not counted" "rc=$LRC $(gfail)"

( cd "$F3" && git checkout -q -- hooks )
grep -v '^export PATH=' "$F3/hooks/lib.sh" > "$TMP/lib" && cat "$TMP/lib" > "$F3/hooks/lib.sh"
launches shim
[ "$LRC" = 2 ] && grep -q 'no `export PATH="..."` line' "$TMP/lerr" \
  && pass "a lib.sh with no PATH line to put the shims in front of: exit 2" || fail "no PATH line" "rc=$LRC $(cat "$TMP/lerr")"
( cd "$F3" && git checkout -q -- hooks )

echo ""
echo "=== progress goes to stderr; an interrupt prints the table so far, exit 130, and never passes the gate ==="
F4="$TMP/fix4"; mkdir -p "$F4/hooks" "$F4/config"
printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 0.2; exit 0\n' > "$F4/hooks/slow.sh"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/slow.sh"}]}]}}' > "$F4/config/settings.json"
( cd "$F4" && git init -q && git -c user.email=t@example.com -c user.name=t add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm base && git tag v0.1.0 ) || { echo "fixture 4 failed"; exit 1; }
for i in 1 2 3 4 5 6 7 8 9 10; do jq -nc --arg id "s-$i" --arg c "echo $i" '{id:$id,tool_name:"Bash",tool_input:{command:$c}}'; done > "$TMP/c4.jsonl"
# Numbers (and their signs) stand for the timings, which differ between two runs; what is left is the shape.
shape() { sed 's/[+-]*[0-9][0-9.]*%*/N/g' "$1"; }
python3 "$BENCH" --repo "$F4" --corpus "$TMP/c4.jsonl" --base v0.1.0 --head v0.1.0 --progress-every 0 --min-calls 5 >"$TMP/q.out" 2>"$TMP/q.err"
python3 "$BENCH" --repo "$F4" --corpus "$TMP/c4.jsonl" --base v0.1.0 --head v0.1.0 --progress-every 0.05 --min-calls 5 >"$TMP/p.out" 2>"$TMP/p.err"
# Not [ ! -s ]: tarfile on Python 3.12 warns on stderr, a line that is not ours (run 44610159230).
! grep -q '^hook-bench:' "$TMP/q.err" && pass "--progress-every 0 writes no progress line to stderr" || fail "quiet" "$(head -3 "$TMP/q.err")"
[ "$(shape "$TMP/q.out")" = "$(shape "$TMP/p.out")" ] && ! grep -q 'hook-bench:' "$TMP/p.out" \
  && pass "stdout is the same with progress on, and carries no progress line" || fail "stdout unchanged" "$(diff <(shape "$TMP/q.out") <(shape "$TMP/p.out") | head -4)"
grep -q '^hook-bench: 10 payloads x 1 pass x 2 sides, after 2 warm-up passes (4 hook starts); at least .* in all, warm-up included, .* process start' "$TMP/p.err" && grep -q -- '--quick takes every third' "$TMP/p.err" \
  && grep -q '^hook-bench: warm base: payload 1 of 2' "$TMP/p.err" && grep -q '^hook-bench: timed [a-z]*: payload [0-9]* of 10, elapsed .*left in timed' "$TMP/p.err" \
  && pass "stderr: the estimate and --quick up front, then warm and timed lines with side, n of N, elapsed" || fail "progress lines" "$(head -5 "$TMP/p.err")"
slow_run() {   # slow_run SIGNAL [ARGS]: stop a run of the 0.2 s hook once WAITFOR shows in stderr (default: timed payload 4); sets SRC
  python3 "$BENCH" --repo "$F4" --corpus "$TMP/c4.jsonl" --base v0.1.0 --head v0.1.0 --progress-every 0.05 --min-calls 5 \
    --json "$TMP/o4.json" --md "$TMP/o4.md" "${@:2}" >"$TMP/o4.out" 2>"$TMP/e4" &
  local pid=$! i
  for i in $(seq 1 600); do grep -q "${WAITFOR:-timed [a-z]*: payload [4-9] of}" "$TMP/e4" && break; sleep 0.02; done
  kill -"$1" "$pid"; wait "$pid"; SRC=$?
}
slow_run INT --gate
DONE=$(jq -r '.partial.done' "$TMP/o4.json" 2>/dev/null)
[ "$SRC" = 130 ] && [ "${DONE:-0}" -ge 3 ] && [ "${DONE:-0}" -lt 10 ] && grep -q "^\*\*partial: $DONE of 10 payloads timed; interrupted during the timed phase (" "$TMP/o4.out" \
  && grep -q '^| Bash | ' "$TMP/o4.out" && cmp -s "$TMP/o4.out" "$TMP/o4.md" \
  && pass "SIGINT: the table so far, marked partial: $DONE of 10 payloads, exit 130" || fail "SIGINT partial table" "rc=$SRC done=$DONE $(head -5 "$TMP/o4.out") $(tail -3 "$TMP/e4")"
[ "$(jq -r '.gate.passed' "$TMP/o4.json")" = false ] && grep -q '^Gate: FAILED' "$TMP/o4.out" \
  && grep -q "partial run: $DONE of 10 payloads; a partial run cannot pass the gate" "$TMP/o4.out" \
  && pass "--gate on a partial run fails, and says why" || fail "gate on partial" "$(grep -A3 Gate "$TMP/o4.out")"
slow_run TERM
[ "$SRC" = 130 ] && grep -q '^\*\*partial: [0-9]* of 10 payloads timed; interrupted during the timed phase (' "$TMP/o4.out" \
  && pass "SIGTERM is handled the same way" || fail "SIGTERM" "rc=$SRC $(head -3 "$TMP/o4.out") $(tail -3 "$TMP/e4")"
WAITFOR='warm [a-z]*: payload 2 of 2' slow_run INT --gate
[ "$SRC" = 130 ] && [ "$(jq -r '.partial.done' "$TMP/o4.json")" = 0 ] \
  && grep -q '^\*\*partial: 0 of 10 payloads timed; interrupted during warm-up (head, 2 of 2)\*\*' "$TMP/o4.out" \
  && [ "$(jq -r '.partial.phase.name' "$TMP/o4.json")" = warm ] \
  && pass "SIGINT in warm-up: the header names warm-up and its count, exit 130" || fail "SIGINT in warm-up" "rc=$SRC $(head -3 "$TMP/o4.out") $(tail -3 "$TMP/e4")"
grep -q '^Gate: FAILED' "$TMP/o4.out" && pass "a warm-up interrupt fails --gate too" || fail "gate in warm-up" "$(grep -A3 Gate "$TMP/o4.out")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
