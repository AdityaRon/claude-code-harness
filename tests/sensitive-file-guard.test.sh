#!/usr/bin/env bash
# Tests for sensitive-file-guard.sh — including canonicalization bypass attempts.
set -u
HOOK="hooks/sensitive-file-guard.sh"
PASS=0; FAIL=0

# Set up fixture: real dotfile + symlink pointing to it
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"  # guard decisions are audited; keep test ones out of the real log
echo "SECRET=abc" > "$TMP/.env"
ln -s "$TMP/.env" "$TMP/benign-looking-link"

check() {
  local label="$1" expect="$2" path="$3"
  local payload
  payload=$(jq -nc --arg p "$path" '{tool_input:{file_path:$p}}')
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
echo "=== Template files are safe (expect: allow) ==="
check ".env.example"             allow ".env.example"
check ".env.sample subpath"      allow "config/.env.sample"
check ".env.template"            allow ".env.template"
check "credentials.json.example" allow "gcp/credentials.json.example"
check "secrets.py (source)"      allow "app/secrets.py"
check "secrets.ts (source)"      allow "src/secrets.ts"

echo ""
echo "=== secrets.<config> still denied (expect: deny) ==="
check "secrets.yaml"             deny "config/secrets.yaml"
check "secrets.json"             deny "secrets.json"

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
echo "=== The Grep tool reaches the guard — #D ==="
# settings.json registered this guard on Read|Edit|Write|MultiEdit|NotebookEdit.
# Grep prints file CONTENT and was on none of those lists, and has no
# PreToolUse hook of its own, so Grep(pattern=".", path=".env",
# output_mode="content") printed the file this guard exists to protect. The
# hook was never even invoked, so the registration is part of the fix.
MATCHERS=$(jq -r '[.hooks.PreToolUse[]
                   | select([.hooks[].command] | any(test("sensitive-file-guard")))
                   | .matcher] | join(" ")' config/settings.json)
if printf '%s' "$MATCHERS" | grep -qE '(^|\|)Grep(\||$| )'; then
  echo "  OK: settings.json registers sensitive-file-guard on Grep"; PASS=$((PASS+1))
else
  echo "  FAIL: Grep is not in the sensitive-file-guard matcher [$MATCHERS]"; FAIL=$((FAIL+1))
fi

# Grep's input shape is its own: `path` (file or directory), `glob` (which
# files to search) and `pattern` (what to look for inside them). Only the
# first two choose a target.
check_grep() {
  local label="$1" expect="$2" payload="$3"
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
    echo "  OK ($expect): $label"; PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$got): $label  [payload: $payload]"; FAIL=$((FAIL+1))
  fi
}

grep_payload() { jq -nc --arg p "$1" --arg g "$2" --arg pat "$3" \
  '{tool_name:"Grep", tool_input:({pattern:$pat, output_mode:"content"}
     + (if $p == "" then {} else {path:$p} end)
     + (if $g == "" then {} else {glob:$g} end))}'; }

echo ""
echo "=== Grep targets that print a credential file (expect: deny) ==="
check_grep "path is the .env"       deny "$(grep_payload ".env" "" ".")"
check_grep "path is a subpath .env" deny "$(grep_payload "config/.env" "" "KEY")"
check_grep "glob *.env"             deny "$(grep_payload "" "*.env" "KEY")"
check_grep "glob .env*"             deny "$(grep_payload "" ".env*" "KEY")"
check_grep "glob **/.env*"          deny "$(grep_payload "src" "**/.env*" "KEY")"
check_grep "glob *.pem"             deny "$(grep_payload "" "*.pem" "PRIVATE")"
check_grep "glob id_rsa*"           deny "$(grep_payload "" "id_rsa*" "PRIVATE")"
check_grep "glob brace {env,ts}"    deny "$(grep_payload "" "*.{env,ts}" "KEY")"
check_grep "path is the .ssh dir"   deny "$(grep_payload "$HOME/.ssh" "" "PRIVATE")"
check_grep "path is the .aws dir"   deny "$(grep_payload "$HOME/.aws" "" "aws_secret")"

echo ""
echo "=== Ordinary Grep calls stay silent (expect: allow) ==="
check_grep "source tree, no glob"   allow "$(grep_payload "src" "" "TODO")"
check_grep "glob *.ts"              allow "$(grep_payload "" "*.ts" "TODO")"
check_grep "glob **/*.tsx"          allow "$(grep_payload "src" "**/*.tsx" "useState")"
check_grep "glob *.json"            allow "$(grep_payload "" "*.json" "version")"
check_grep "glob on a template"     allow "$(grep_payload "" "*.env.example" "KEY")"
# The pattern is the search string, not a target: looking FOR the text .env
# across source is an ordinary read and must not be confused with reading one.
check_grep "pattern mentions .env"  allow "$(grep_payload "src" "*.ts" "process.env.API_KEY")"
check_grep "pattern is a path"      allow "$(grep_payload "" "" "config/.env")"

echo ""
echo "=== Credential files added 2026-09-24 ==="
check "claude oauth token"       deny "$HOME/.claude/.credentials.json"
check "terraform state"          deny "infra/terraform.tfstate"
check "terraform state backup"   deny "terraform.tfstate.backup"
check "tfvars"                   deny "env/prod.tfvars"
check "pfx"                      deny "certs/client.pfx"
check "gh hosts"                 deny "$HOME/.config/gh/hosts.yml"
check "tfvars template"          allow "env/prod.tfvars.example"
check "terraform source"         allow "infra/main.tf"
check "claude settings"          allow "$HOME/.claude/settings.json"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
