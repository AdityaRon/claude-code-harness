#!/usr/bin/env bash
# Tests for bin/hook-bench.py on a fixture repo with stub hooks: the gate goes
# red on a slower hook and on a decision change nobody declared, stays green
# A/A, and wait is the slowest hook of a call, not the sum.
set -u
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
BENCH="$PWD/bin/hook-bench.py"
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
INPUT=$(cat); sleep 0.03
case "$INPUT" in *danger*) echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"x"}}' ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 0.03; exit 0\n' > "$FIX/hooks/second.sh"
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
# --floor-ms 50 where speed is not under test: seven sleep-based calls on a
# loaded CI runner can wobble p95 past 20% and 5 ms.
run --base v0.1.0 --head v0.1.0 --gate --floor-ms 50; RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $(cat "$TMP/err")"
[ "$(jqo '.classes.Bash.base.wait.n')" = 7 ] && pass "7 Bash calls counted" || fail "Bash calls" "$(jqo '.classes.Bash.base.wait.n')"
jq -e '.classes.Bash.base.wait.p50 < (.hooks["fast.sh"].base.wall.p50 + .hooks["second.sh"].base.wall.p50 - 10)
       and .classes.Bash.base.wait.p50 >= ([.hooks["fast.sh"].base.wall.p50, .hooks["second.sh"].base.wall.p50] | max) - 5' \
  "$TMP/out.json" >/dev/null \
  && pass "wait is the slowest hook of a call, not the sum" \
  || fail "wait is a max" "$(jqo '[.classes.Bash.base.wait.p50, .hooks["fast.sh"].base.wall.p50, .hooks["second.sh"].base.wall.p50]')"
[ "$(jqo '.hooks["fast.sh"].base.wall.n')" = 7 ] && [ "$(jqo '.hooks["file.sh"].base.wall.n')" = 1 ] \
  && pass "hooks fire by matcher: fast.sh on 7 Bash calls, file.sh on 1 Write" || fail "matchers" "$(jqo '.hooks | keys')"
[ "$(jqo '.hooks | has("missing.sh")')" = false ] && pass "an async hook is not run" || fail "async hook ran" ""
[ "$(jqo '.decisions.same')" = 9 ] && pass "9 of 9 decisions the same" || fail "decisions" "$(jqo '.decisions')"
grep -q '^| Bash | 7 |' "$TMP/out.md" && pass "markdown table has the Bash row" || fail "markdown" "$(head -8 "$TMP/out.md")"
[ "$(jqo '.process_start_ms["bash -c :"] > 0')" = true ] && pass "process start cost measured" || fail "start cost" ""

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
run --base v0.1.0 --head worktree --gate --intended "other,danger" --floor-ms 50; RC=$?
[ "$RC" = 0 ] && pass "--intended danger passes" || fail "--intended" "rc=$RC $(jqo '.gate.failures')"
run --base v0.1.0 --head worktree; RC=$?
[ "$RC" = 0 ] && pass "without --gate the exit is 0 either way" || fail "no gate" "rc=$RC"
( cd "$FIX" && git checkout -q -- hooks/fast.sh )

echo ""
echo "=== a slower hook fails the gate; both the limit and the floor must be crossed ==="
printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 0.07; exit 0\n' > "$FIX/hooks/second.sh"
run --base v0.1.0 --head worktree --gate; RC=$?
[ "$RC" = 1 ] && pass "exit 1 on +40 ms" || fail "slow exit" "rc=$RC"
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
run --base v0.1.0 --head worktree --gate --floor-ms 50; RC=$?
[ "$RC" = 0 ] && [ "$(jqo '.hooks | has("ghost.sh")')" = false ] && pass "ghost.sh ignored" || fail "ghost" "rc=$RC $(cat "$TMP/err")"
( cd "$FIX" && git checkout -q -- config/settings.json )

echo ""
echo "=== --quick takes every third payload; a missing base ref is an error ==="
run --base v0.1.0 --head v0.1.0 --quick; RC=$?
[ "$RC" = 0 ] && [ "$(jqo '.corpus.count')" = 3 ] && pass "3 of 9" || fail "quick" "rc=$RC $(jqo '.corpus.count')"
run --base nope --head v0.1.0; RC=$?
[ "$RC" = 2 ] && pass "exit 2 on a bad ref" || fail "bad ref" "rc=$RC"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
