#!/usr/bin/env bash
# Tests for secret-scanner.sh
#
# Test fixtures that look like real secrets are composed at runtime from
# `prefix${ZZ}suffix` pairs. The empty shell expansion `${ZZ}` disappears
# at runtime (so the scanner still sees the full token) but breaks the
# literal pattern in source — keeping GitHub push-protection, CI secret
# scanners, and this repo's own secret-scanner from flagging the fixtures.
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"  # guard decisions are audited; keep test ones out of the real log
HOOK="hooks/secret-scanner.sh"
PASS=0; FAIL=0

# Shell-level splitter: expands to empty, defeats static pattern matches.
# (Don't use `_` — bash overwrites it with the last argument of each command.)
ZZ=''

check_write() {
  local label="$1" expect="$2" content="$3"
  local payload
  payload=$(jq -nc --arg c "$content" '{tool_name:"Write", tool_input:{content:$c, file_path:"/tmp/x"}}')
  local result got
  result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null); rc=$?
  if [[ -z "$result" ]]; then
    got="allow"
  else
    got=$(printf '%s\n' "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  fi
  # A hook that crashes prints nothing, which would otherwise read as allow.
  [[ $rc -ne 0 ]] && got="exit $rc"
  if [[ "$got" = "$expect" ]]; then
    echo "  OK ($expect): $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$got): $label"
    FAIL=$((FAIL+1))
  fi
}

check_edit() {
  local label="$1" expect="$2" new_string="$3"
  local payload
  payload=$(jq -nc --arg n "$new_string" '{tool_name:"Edit", tool_input:{new_string:$n, old_string:"placeholder", file_path:"/tmp/x"}}')
  local result got
  result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null); rc=$?
  if [[ -z "$result" ]]; then
    got="allow"
  else
    got=$(printf '%s\n' "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  fi
  # A hook that crashes prints nothing, which would otherwise read as allow.
  [[ $rc -ne 0 ]] && got="exit $rc"
  if [[ "$got" = "$expect" ]]; then
    echo "  OK ($expect): $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$got): $label"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Known secret shapes via Write (expect: deny) ==="
check_write "AWS access key"   deny "const KEY = \"AKIA${ZZ}Q3EGW7PZJ4XN2KHM\";"
check_write "AWS session key"  deny "AWS_KEY=ASIA${ZZ}Q3EGW7PZJ4XN2KHM"
check_write "GitHub PAT"       deny "token: ghp${ZZ}_0123456789abcdefghij0123456789abcdef"
check_write "Slack token"      deny "SLACK=xoxb${ZZ}-1234567890-1234567890-abcdefgh"
check_write "Google API key"   deny "KEY=AIza${ZZ}SyA-example-key-abcdefghijklmnopqrstuv"
check_write "Stripe live"      deny "STRIPE=sk_live${ZZ}_abcdefghij0123456789ABCDEF"
check_write "JWT"              deny "Bearer eyJ${ZZ}hbGciOiJIUzI1NiJ9.eyJzdWIiOjEyMzQ1Njc4OTB9.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9FYR5aaa"
check_write "PEM private key"  deny "-----BEGIN${ZZ} RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA...
-----END RSA PRIVATE KEY-----"
check_write "Anthropic key"    deny "ANTHROPIC_API_KEY=sk-ant${ZZ}-abcdefghijklmnopqrstuvwxyz"

echo ""
echo "=== Known secret shapes via Edit (expect: deny) ==="
check_edit  "AWS access key"   deny "const K = \"AKIA${ZZ}Q3EGW7PZJ4XN2KHM\";"
check_edit  "GitHub PAT"       deny "ghp${ZZ}_0123456789abcdefghij0123456789abcdef"

echo ""
echo "=== Additional secret shapes — M3 (expect: deny) ==="
check_write "OpenAI project key" deny "OPENAI=sk-${ZZ}proj-abcdefghijklmnopqrstuvwxyz0123"
check_write "Slack webhook"      deny "url = \"https://hooks.slack.com/servi${ZZ}ces/T00000000/B00000000/abcdefghijklmnopqrstuvwx\""
check_write "GCP SA type alone"  allow "{ \"type\": \"service${ZZ}_account\", \"project_id\": \"x\" }"
check_write "GCP private_key"    deny "{ \"private${ZZ}_key\": \"-----BEGIN${ZZ} PRIVATE KEY-----\" }"

echo ""
echo "=== NotebookEdit is scanned — M2 (expect: deny) ==="
nb_payload=$(jq -nc --arg n "KEY = \"AKIA${ZZ}Q3EGW7PZJ4XN2KHM\"" '{tool_name:"NotebookEdit", tool_input:{new_source:$n, notebook_path:"/tmp/x.ipynb"}}')
nb_out=$(printf '%s\n' "$nb_payload" | bash "$HOOK" 2>/dev/null)
nb_got=$([ -z "$nb_out" ] && echo allow || printf '%s\n' "$nb_out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
if [[ "$nb_got" = "deny" ]]; then echo "  OK (deny): NotebookEdit cell scanned"; PASS=$((PASS+1)); else echo "  FAIL: NotebookEdit not scanned"; FAIL=$((FAIL+1)); fi

echo ""
echo "=== Write field aliases accepted since 2.1.280 (expect: deny) ==="
for field in file_text file_content; do
  al_out=$(jq -nc --arg f "$field" --arg c "KEY = \"AKIA${ZZ}Q3EGW7PZJ4XN2KHM\"" \
    '{tool_name:"Write", tool_input:{path:"/tmp/x", ($f):$c}}' | bash "$HOOK" 2>/dev/null)
  if [[ "$(printf '%s' "$al_out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)" = "deny" ]]; then
    echo "  OK (deny): Write.$field scanned"; PASS=$((PASS+1))
  else
    echo "  FAIL: Write.$field not scanned"; FAIL=$((FAIL+1))
  fi
done

echo ""
echo "=== Legitimate content (expect: allow) ==="
check_write "TODO comment"     allow '// TODO: load secrets from env, not inline'
check_write "env.example"      allow 'AWS_ACCESS_KEY_ID=your-access-key-here'
check_write "normal code"      allow 'export function foo() { return process.env.TOKEN; }'
check_write "short string"     allow 'const x = "AKIA";'
check_write "AKIA not key"     allow 'function akiaHelper() { /* no */ }'
check_write "documentation"    allow 'Set AWS_ACCESS_KEY_ID to your IAM key ID before running.'

echo ""
echo "=== Non-Write/Edit tool (expect: allow) ==="
payload=$(jq -nc --arg c "AKIA${ZZ}Q3EGW7PZJ4XN2KHM" '{tool_name:"Bash", tool_input:{command:$c}}')
result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null)
got=$([ -z "$result" ] && echo allow || echo "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
if [[ "$got" = "allow" ]]; then
  echo "  OK (allow): Bash tool ignored"; PASS=$((PASS+1))
else
  echo "  FAIL: Bash tool not ignored"; FAIL=$((FAIL+1))
fi

echo ""
echo ""
echo "=== Shapes added 2026-10-07 (expect: deny) ==="
check_write "GitHub fine-grained PAT" deny "T=github${ZZ}_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ"
check_write "GitLab token"       deny "T=glpat${ZZ}-abcdefghij0123456789"
check_write "npm token"          deny "//registry.npmjs.org/:_authToken=npm${ZZ}_abcdefghijklmnopqrstuvwxyz0123456789"
check_write "Slack app token"    deny "SLACK_APP=xapp${ZZ}-1-A0123456789-abcdefghij"
check_write "database URL"       deny "DATABASE_URL=postgres${ZZ}://app:s3cr3tPw@db:5432/x"
check_write "keyed AWS secret"   deny "aws_secret_access_key = Zq8mVb2Lr7${ZZ}Tn4Kd9Wf1Xh6Jp3Gs5Yc0Ue2Ai7Bo4"
check_write "PGP private block"  deny "-----BEGIN${ZZ} PGP PRIVATE KEY BLOCK-----"

echo ""
echo "=== Published samples and look-alikes (expect: allow) ==="
check_write "AWS's documented key ID"     allow "AWS_ACCESS_KEY_ID=AKIA${ZZ}IOSFODNN7EXAMPLE"
check_write "AWS's documented secret"     allow "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfi${ZZ}CYEXAMPLEKEY"
check_write "jwt.io's sample token"       allow "const t = 'eyJ${ZZ}hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'"
check_write "sk- inside an integrity hash" allow "integrity sha512-sk-${ZZ}abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"
check_write "placeholder DB password"     allow "postgres://user:password@localhost:5432/app"
check_write "DB password from a variable" allow "postgres://app:\${DB_PASSWORD}@db/app"

echo ""
echo "=== A secret finished across two edits (expect: deny) ==="
printf 'const K = "AKIA";\n' > "$TMP/split.ts"
split_out=$(jq -nc --arg f "$TMP/split.ts" --arg n "Q3EGW7PZ${ZZ}J4XN2KHM\";" '{tool_name:"Edit", tool_input:{file_path:$f, old_string:"\";", new_string:$n}}' | bash "$HOOK" 2>/dev/null)
[[ "$(printf '%s' "$split_out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)" == deny ]] \
  && { echo "  OK (deny): the tail of a key the file already starts"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: split key passed"; FAIL=$((FAIL+1)); }
printf 'const K = "AKIA%s";\nname = "a"\n' "Q3EGW7PZ${ZZ}J4XN2KHM" > "$TMP/near.ts"
near_out=$(jq -nc --arg f "$TMP/near.ts" '{tool_name:"Edit", tool_input:{file_path:$f, old_string:"\"a\"", new_string:"\"b\""}}' | bash "$HOOK" 2>/dev/null)
[[ -z "$near_out" ]] \
  && { echo "  OK (allow): an unrelated edit next to a key already there"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: unrelated edit blocked"; FAIL=$((FAIL+1)); }

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
