#!/usr/bin/env bash
# Tests that PreToolUse Bash/file guards FAIL CLOSED when jq is unavailable.
# Without jq the guards cannot parse the tool input; a security harness must
# deny rather than silently allow (regression test for the fail-open bug).
#
# jq can't just be dropped from PATH because lib.sh re-adds the standard bin
# dirs where jq usually lives. So we copy lib.sh with its PATH-export line
# rewritten to a curated bin dir that deliberately omits jq.
set -u
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hooks" "$TMP/bin"

# Curated toolbox: everything the guards need before the jq check — but no jq.
for t in bash sh grep sed printf cat dirname stat mkdir chmod date awk tr head tail shasum sha256sum realpath python3; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$TMP/bin/$t"
done

# Copy lib.sh with the fixed PATH rewritten to our jq-free toolbox.
sed "s#^export PATH=.*#export PATH=\"$TMP/bin\"#" hooks/lib.sh > "$TMP/hooks/lib.sh"

check_deny_no_jq() {
  local label="$1" hook="$2" payload="$3"
  cp "hooks/$hook" "$TMP/hooks/$hook"
  local out got
  out=$(printf '%s' "$payload" | PATH="$TMP/bin" bash "$TMP/hooks/$hook" 2>/dev/null)
  # Parse decision without jq (it's absent) — just grep the raw JSON.
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got="deny"; else got="allow"; fi
  # Sanity: confirm jq really is unreachable in this PATH.
  if PATH="$TMP/bin" command -v jq >/dev/null 2>&1; then
    echo "  FAIL ($label): jq still reachable — test setup invalid"; FAIL=$((FAIL+1)); return
  fi
  if [[ "$got" = "deny" ]]; then
    echo "  OK (deny w/o jq): $label"; PASS=$((PASS+1))
  else
    echo "  FAIL (expected deny, got $got): $label"; FAIL=$((FAIL+1))
  fi
}

echo "=== Guards fail closed without jq (expect: deny) ==="
check_deny_no_jq "env-guard"            env-guard.sh            '{"tool_input":{"command":"ls -la"}}'
check_deny_no_jq "git-guard"            git-guard.sh            '{"tool_input":{"command":"git status"}}'
check_deny_no_jq "interpreter-guard"    interpreter-guard.sh    '{"tool_input":{"command":"echo hi"}}'
check_deny_no_jq "network-guard"        network-guard.sh        '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
check_deny_no_jq "sensitive-file-guard" sensitive-file-guard.sh '{"tool_input":{"file_path":"src/index.ts"}}'
check_deny_no_jq "secret-scanner"       secret-scanner.sh       '{"tool_name":"Write","tool_input":{"content":"hello","file_path":"/tmp/x"}}'

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
