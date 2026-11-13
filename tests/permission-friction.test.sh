#!/usr/bin/env bash
# Tests for tools/permission-friction.py: guard errors, case env, masking.
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
PF="$PWD/tools/permission-friction.py"
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null || { echo "  SKIP: no python3"; exit 0; }

mkdir -p "$TMP/hooks" "$TMP/home/.claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/hooks/crash.sh"
printf '#!/usr/bin/env bash\necho not-json\n' > "$TMP/hooks/junk.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$TMP/hooks/blocks.sh"
cat > "$TMP/hooks/allowlist.sh" <<'SH'
#!/usr/bin/env bash
[[ -n "${CLAUDE_NET_ALLOWLIST:-}" ]] && echo '{"hookSpecificOutput":{"permissionDecision":"ask"}}'
exit 0
SH
case_line() { jq -nc --arg id "$1" --arg g "$2" --arg want "$3" --argjson env "${4:-null}" \
  '{id:$id, guard:$g, tool:"Bash", input:{command:"true"}, want:$want} + (if $env then {env:$env} else {} end)'; }

echo "=== a broken guard is an error, never an allow ==="
case_line crash crash allow > "$TMP/c1.jsonl"
OUT=$(HOME="$TMP/home" python3 "$PF" --cases "$TMP/c1.jsonl" --replay "$TMP/hooks" 2>&1); rc=$?
[[ $rc == 1 && "$OUT" == *"now=error"* ]] && pass "a guard exiting 1 reads error and fails the run" || fail "crash" "rc=$rc $OUT"
case_line junk junk allow > "$TMP/c2.jsonl"
OUT=$(HOME="$TMP/home" python3 "$PF" --cases "$TMP/c2.jsonl" --replay "$TMP/hooks" 2>&1); rc=$?
[[ $rc == 1 && "$OUT" == *"now=error"* ]] && pass "a guard printing junk reads error" || fail "junk" "rc=$rc $OUT"
case_line blocks blocks deny > "$TMP/c3.jsonl"
OUT=$(HOME="$TMP/home" python3 "$PF" --cases "$TMP/c3.jsonl" --replay "$TMP/hooks" 2>&1); rc=$?
[[ $rc == 0 && "$OUT" == *"now=deny"* ]] && pass "exit 2 is still a deny" || fail "exit 2" "rc=$rc $OUT"

echo ""
echo "=== cases ignore this machine's allowlist unless they set one ==="
case_line plain allowlist allow > "$TMP/c4.jsonl"
OUT=$(HOME="$TMP/home" CLAUDE_NET_ALLOWLIST=corp.example python3 "$PF" --cases "$TMP/c4.jsonl" --replay "$TMP/hooks" 2>&1); rc=$?
[[ $rc == 0 ]] && pass "the machine's CLAUDE_NET_ALLOWLIST does not reach a case" || fail "machine allowlist leaked" "$OUT"
case_line set allowlist ask '{"CLAUDE_NET_ALLOWLIST":"x.example"}' > "$TMP/c5.jsonl"
OUT=$(HOME="$TMP/home" python3 "$PF" --cases "$TMP/c5.jsonl" --replay "$TMP/hooks" 2>&1); rc=$?
[[ $rc == 0 ]] && pass "a case's own env still applies" || fail "case env" "$OUT"

echo ""
echo "=== masking ==="
OUT=$(HOME="$TMP/home" python3 - "$PF" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location('pf', sys.argv[1])
pf = importlib.util.module_from_spec(spec); spec.loader.exec_module(pf)
for s in ['{"password":"hunter2"}', 'curl -H "Authorization: Bearer abc123def456ghi789j" https://x.example/',
          'curl https://alice:s3cr3t@x.example/', 'curl "https://x.example/?access_token=tok987&q=1"',
          'export API_KEY=k-55555']:
    print(pf.mask(s))
PY
)
for secret in hunter2 abc123def456ghi789j s3cr3t tok987 k-55555; do
  [[ "$OUT" != *"$secret"* ]] && pass "masks $secret" || fail "masks $secret" "$OUT"
done
[[ "$OUT" == *"q=1"* && "$OUT" == *"x.example"* ]] && pass "leaves the rest of the command readable" || fail "over-masking" "$OUT"
printf '%s\n' 'acmecorp => <CORP>' > "$TMP/home/.claude/permission-friction.masks"
OUT=$(HOME="$TMP/home" python3 - "$PF" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location('pf', sys.argv[1])
pf = importlib.util.module_from_spec(spec); spec.loader.exec_module(pf)
print(pf.shape('~/.claude/skills/tool/acmecorp-logs.sh --x'))
PY
)
[[ "$OUT" != *acmecorp* && "$OUT" == *CORP* ]] && pass "command families go through the masks file" || fail "shape masking" "$OUT"


echo ""
echo "=== approved prompts Claude Code raised itself (permissionDecision, 2.1.296+) ==="
mkdir -p "$TMP/home/.claude/projects/p"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
row() {  # id tool cwd source
  jq -nc --arg id "$1" --arg tool "$2" --arg cwd "$3" --arg t "$NOW" \
    '{type:"assistant", timestamp:$t, sessionId:"s1", cwd:$cwd, message:{content:[{type:"tool_use", id:$id, name:$tool, input:{file_path:($cwd + "/a.py"), command:"true"}}]}}'
  jq -nc --arg id "$1" --arg src "$4" --arg t "$NOW" \
    '{type:"user", timestamp:$t, sessionId:"s1", permissionDecision:{decision:"accept", source:$src}, message:{content:[{type:"tool_result", tool_use_id:$id, content:"ok"}]}}'
}
{ row e1 Edit /w/proj/.claude/worktrees/agent-1 user_temporary; row b1 Bash /w/other config
  row q1 AskUserQuestion /w/proj user_temporary; } > "$TMP/home/.claude/projects/p/s1.jsonl"
approved() { HOME="$TMP/home" python3 "$PF" --days 1 --out "$TMP/o" "$@" >/dev/null 2>&1 \
  && jq -r '[.prompt_approved[] | "\(.key)=\(.count)"] | join(",")' "$TMP/o/friction.json"; }
OUT=$(approved); [[ "$OUT" == "file edit under .claude/ in an agent worktree (proj)=1" ]] \
  && pass "a user-approved edit counts; a config allow and a question answer do not" || fail "prompt_approved" "$OUT"
OUT=$(approved --project /w/other); [[ -z "$OUT" ]] && pass "--project keeps only that working directory" || fail "--project" "$OUT"

echo ""
# A --cases run is a pass, a timeout (every miss is a guard past its limit: at
# load average 7.6 one was, and a rerun passed 15 of 15) or a failure.
cases_verdict() {  # rc output; a run that did not finish (no tally, or one that disagrees) is a failure
  local miss n; miss=$(grep '^MISS' <<<"$2"); n=$(grep -c '^MISS' <<<"$2")
  if [[ $1 == 0 ]]; then echo pass
  elif [[ -n "$miss" ]] && ! grep -qv 'now=timeout' <<<"$miss" && [[ "$(tail -1 <<<"$2")" == "$n case(s) differ from want" ]]; then echo timeout
  else echo fail; fi
}

echo "=== a guard past its limit is a timeout, a wrong decision a failure ==="
[ "$(cases_verdict 0 'ok    a  now=deny')" = pass ] && pass "exit 0 passes" || fail "verdict pass" ""
[ "$(cases_verdict 1 $'MISS  a  now=timeout want=deny\nok    b  now=ask\n1 case(s) differ from want')" = timeout ] \
  && pass "misses that are all timeouts read timeout" || fail "verdict timeout" ""
[ "$(cases_verdict 1 $'MISS  a  now=timeout want=deny\nMISS  b  now=allow want=ask\n2 case(s) differ from want')" = fail ] \
  && pass "one wrong decision among them is a failure" || fail "verdict mixed" ""
[ "$(cases_verdict 1 'Traceback (most recent call last):')" = fail ] && pass "a crash is a failure" || fail "verdict crash" ""
[ "$(cases_verdict 1 $'MISS  a  now=timeout want=deny\nTraceback (most recent call last):')" = fail ] \
  && pass "a crash after a timed-out case is a failure" || fail "verdict crash after timeout" ""
printf '#!/usr/bin/env bash\nsleep 3\n' > "$TMP/hooks/slow.sh"
case_line slow slow deny > "$TMP/c6.jsonl"
OUT=$(HOME="$TMP/home" CCH_GUARD_TIMEOUT=1 python3 "$PF" --cases "$TMP/c6.jsonl" --replay "$TMP/hooks" 2>&1); rc=$?
[ "$(cases_verdict "$rc" "$OUT")" = timeout ] && pass "a guard slower than CCH_GUARD_TIMEOUT reads now=timeout" || fail "real timeout" "rc=$rc $OUT"
LINE=$(bash -c 'PASS=2 FAIL=0; source tests/lib.sh; timed_out x; results' 2>&1); RC=$?
[[ "$LINE" == *"--- Results: 2 passed, 0 failed, 1 timed out ---" && $RC == 1 ]] \
  && pass "results: a ', 1 timed out' tally and a nonzero exit" || fail "results line" "rc=$RC $LINE"
bash -c 'PASS=0 FAIL=256; source tests/lib.sh; results' >/dev/null 2>&1; RC=$?
[[ $RC == 100 ]] && pass "256 misses exit 100, not 0" || fail "exit cap" "rc=$RC"
LINE=$(bash -c 'PASS=2 FAIL=0; source tests/lib.sh; results' 2>&1)
[[ "$LINE" == *"--- Results: 2 passed, 0 failed ---" ]] && pass "and no suffix when none did" || fail "results plain" "$LINE"

echo ""
echo "=== a guard ask recorded as \"command hook N\" (2.1.319+) is named through settings.json ==="
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/env-guard.sh"},{"type":"command","command":"~/.claude/hooks/git-guard.sh"}]}]}}' \
  > "$TMP/home/.claude/settings.json"
ASK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This deletes a branch"}}'
{ jq -nc --arg t "$NOW" '{type:"assistant", timestamp:$t, sessionId:"s2", cwd:"/w/proj", message:{content:[{type:"tool_use", id:"g1", name:"Bash", input:{command:"git branch -D x"}}]}}'
  jq -nc --arg t "$NOW" --arg out "$ASK" '{type:"attachment", timestamp:$t, attachment:{type:"hook_success", hookEvent:"PreToolUse", hookName:"PreToolUse:Bash", toolUseID:"g1", command:"command hook 2", durationMs:120, stdout:$out}}'
  jq -nc --arg t "$NOW" '{type:"user", timestamp:$t, sessionId:"s2", permissionDecision:{decision:"accept", source:"user_temporary"}, message:{content:[{type:"tool_result", tool_use_id:"g1", content:"ok"}]}}'
} > "$TMP/home/.claude/projects/p/s2.jsonl"
OUT=$(HOME="$TMP/home" python3 "$PF" --days 1 --out "$TMP/o" >/dev/null 2>&1 && jq -r '[.guard_asks[] | "\(.key)=\(.count)"] | join(",")' "$TMP/o/friction.json")
[[ "$OUT" == "git-guard=1" ]] && pass "hook 2 on Bash is git-guard, not 'command ho'" || fail "numbered hook name" "$OUT"

echo ""
echo "=== an ask from bash-guards goes back to the guards that gave it, by its timing log ==="
H3="$TMP/home3"; mkdir -p "$H3/.claude/projects/p"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash|Monitor","hooks":[{"type":"command","command":"~/.claude/hooks/bash-guards.sh"}]}]}}' > "$H3/.claude/settings.json"
bg_call() {  # id command reason: one Bash call bash-guards asked on, approved
  jq -nc --arg t "$NOW" --arg id "$1" --arg c "$2" '{type:"assistant", timestamp:$t, sessionId:"s3", cwd:"/w/proj", message:{content:[{type:"tool_use", id:$id, name:"Bash", input:{command:$c}}]}}'
  jq -nc --arg t "$NOW" --arg id "$1" --arg r "$3" '{type:"attachment", timestamp:$t, attachment:{type:"hook_success", hookEvent:"PreToolUse", hookName:"PreToolUse:Bash", toolUseID:$id, command:"command hook 1", durationMs:90,
    stdout:({hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"ask", permissionDecisionReason:$r}} | tojson)}}'
  jq -nc --arg t "$NOW" --arg id "$1" '{type:"user", timestamp:$t, sessionId:"s3", permissionDecision:{decision:"accept", source:"user_temporary"}, message:{content:[{type:"tool_result", tool_use_id:$id, content:"ok"}]}}'
}
{ bg_call b1 "git branch -D x" "This deletes a branch"
  bg_call b2 "kubectl delete pod web && git branch -D y" $'This deletes a branch\nDeletes a pod'
  bg_call b3 "git branch -D z" "This deletes a branch"
} > "$H3/.claude/projects/p/s3.jsonl"
A="0.01:0:allow"
printf 'b1\tBash\tenv-guard=%s\tgit-guard=0.02:0:ask\tkubectl-guard=%s\n' "$A" "$A" > "$TMP/timing.log"
printf 'b2\tBash\tenv-guard=%s\tgit-guard=0.02:0:ask\tkubectl-guard=0.03:0:ask\n' "$A" >> "$TMP/timing.log"
OUT=$(HOME="$H3" CLAUDE_GUARD_TIMING_LOG="$TMP/timing.log" python3 "$PF" --days 1 --out "$TMP/o3" >/dev/null 2>&1 \
  && jq -r '[.guard_asks[] | "\(.key)=\(.count)"] | sort | join(",")' "$TMP/o3/friction.json")
# Two guards asking on one call read git-guard+kubectl-guard, as two separate hooks did.
[[ "$OUT" == "bash-guards=1,git-guard+kubectl-guard=1,git-guard=1" ]] \
  && pass "each guard that asked is named, as with separate hooks; no timing line stays bash-guards" || fail "bash-guards attribution" "$OUT"
R=$(jq -r '[.ask_reasons[] | select(.guard == "git-guard+kubectl-guard") | .reason] | join("|")' "$TMP/o3/friction.json" 2>/dev/null)
[[ "$R" == "This deletes a branch" ]] \
  && pass "two guards' joined reasons are split back, each to its guard" || fail "joined reason" "$R"

echo ""
echo "=== every shipped case meets its want on this repo's hooks ==="
OUT=$(HOME="$TMP/home" python3 "$PF" --cases --replay "$PWD/hooks" 2>&1); rc=$?
case "$(cases_verdict "$rc" "$OUT")" in
  pass) pass "$(tail -1 <<<"$OUT")" ;;
  timeout) timed_out "shipped cases" "$(grep -c '^MISS' <<<"$OUT") guard run(s) past their limit: the machine's load, not a decision" ;;
  *) fail "shipped cases" "$(grep MISS <<<"$OUT")" ;;
esac

echo ""
results
