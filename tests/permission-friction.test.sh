#!/usr/bin/env bash
# Tests for bin/permission-friction.py: guard errors, case env, masking.
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PF="$PWD/bin/permission-friction.py"
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
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
echo "=== every shipped case meets its want on this repo's hooks ==="
OUT=$(HOME="$TMP/home" python3 "$PF" --cases --replay "$PWD/hooks" 2>&1); rc=$?
[[ $rc == 0 ]] && pass "$(tail -1 <<<"$OUT")" || fail "shipped cases" "$(grep MISS <<<"$OUT")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
