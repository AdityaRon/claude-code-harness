#!/usr/bin/env bash
# Tests for sensitive-file-guard.sh — including canonicalization bypass attempts.
set -u
HOOK="hooks/sensitive-file-guard.sh"
PASS=0; FAIL=0

# Set up fixture: real dotfile + symlink pointing to it
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "SECRET=abc" > "$TMP/.env"
ln -s "$TMP/.env" "$TMP/benign-looking-link"

check() {
  local label="$1" expect="$2" path="$3"
  local payload
  payload=$(jq -nc --arg p "$path" '{tool_input:{file_path:$p}}')
  local result got
  result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$result" ]]; then
    got="allow"
  else
    got=$(printf '%s\n' "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  fi
  if [[ "$got" = "$expect" ]]; then
    echo "  OK ($expect): $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$got): $label  [path: $path]"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Direct pattern matches (expect: deny) ==="
check ".env"                     deny ".env"
check "subpath .env"             deny "src/config/.env"
check ".env.production"          deny ".env.production"
check ".envrc"                   deny ".envrc"
check "server.pem"               deny "server.pem"
check "tls.key"                  deny "certs/tls.key"
check "~/.aws/credentials"       deny "$HOME/.aws/credentials"
check "~/.netrc"                 deny "$HOME/.netrc"
check "id_rsa"                   deny "$HOME/.ssh/id_rsa"
check "id_ed25519"               deny "$HOME/.ssh/id_ed25519"
check "secrets.yaml"             deny "config/secrets.yaml"

echo ""
echo "=== Canonicalization bypass attempts (expect: deny) ==="
check "symlink to .env"          deny "$TMP/benign-looking-link"
check "relative ../../.env"      deny "../../.env"
check "./path/.env"              deny "./config/.env"

echo ""
echo "=== Absolute / tilde paths (expect: deny) ==="
check "absolute /tmp/x/.env"     deny "/tmp/some/.env"
check "tilde ~/.env"             deny "~/.env"

echo ""
echo "=== Legitimate files (expect: allow) ==="
check "source code"              allow "src/index.ts"
check "package.json"             allow "package.json"
check "README.md"                allow "README.md"
check "env.example"              allow "env.example"
check "key.json (config)"        allow "config/key.json"
check "pem.md"                   allow "docs/pem.md"

echo ""
echo "=== Additional credential files — H3 (expect: deny) ==="
check "prod.env"                 deny "config/prod.env"
check "local.env"                deny "local.env"
check ".npmrc"                   deny "$HOME/.npmrc"
check ".git-credentials"         deny "$HOME/.git-credentials"
check ".pgpass"                  deny "$HOME/.pgpass"
check ".kube/config"             deny "$HOME/.kube/config"
check ".ssh/config"              deny "$HOME/.ssh/config"
check ".docker/config.json"      deny "$HOME/.docker/config.json"
check "credentials.json"         deny "gcp/credentials.json"
check "service-account.json"     deny "keys/my-service-account-abc.json"

echo ""
echo "=== Additional anti-false-positive (expect: allow) ==="
check "environment.ts"           allow "src/environment.ts"
check "kube helper"              allow "src/kube/client.ts"
check "config.json (plain)"      allow "tsconfig.json"

echo ""
echo "=== JSON-escape safety (expect: deny, and output must be valid JSON) ==="
WEIRD='weird "quoted" \path/.env'
payload=$(jq -nc --arg p "$WEIRD" '{tool_input:{file_path:$p}}')
out=$(printf '%s\n' "$payload" | bash "$HOOK")
if printf '%s\n' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  echo "  OK (deny, valid JSON): quoted+backslash path"; PASS=$((PASS+1))
else
  echo "  FAIL: quoted+backslash path — output: $out"; FAIL=$((FAIL+1))
fi

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
