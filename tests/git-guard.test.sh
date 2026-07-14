#!/usr/bin/env bash
# Tests for git-guard.sh — payloads built via jq so the outer command
# doesn't contain trigger strings.
set -u
HOOK="hooks/git-guard.sh"
PASS=0; FAIL=0

check() {
  local label="$1" expect="$2" cmd="$3"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
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
    echo "  FAIL (expected=$expect got=$got): $label  [cmd: $cmd]"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Force-push (expect: deny) ==="
check "git push --force"              deny "git push --force"
check "git push -f origin main"       deny "git push -f origin main"
check "git push origin main --force"  deny "git push origin main --force"
check "git push --force-with-lease"   deny "git push --force-with-lease"
check "chain: add && push --force"    deny "git add file.txt && git push --force origin main"

echo ""
echo "=== Indiscriminate staging (expect: deny) ==="
check "git add ."        deny "git add ."
check "git add -A"       deny "git add -A"
check "git add --all"    deny "git add --all"

echo ""
echo "=== Glob staging (expect: ask) ==="
check "git add *.ts"     ask  "git add *.ts"
check "git add 'src/*'"  ask  "git add 'src/*'"

echo ""
echo "=== Sensitive file staging (expect: deny) ==="
check "git add .env"           deny "git add .env"
check "git add src/.env.local" deny "git add src/.env.local"
check "git add secrets.yaml"   deny "git add secrets.yaml"
check "git add id_rsa"         deny "git add id_rsa"
check "git add server.pem"     deny "git add server.pem"

echo ""
echo "=== Config tampering ==="
check "set core.hooksPath"     deny "git config core.hooksPath /dev/null"
check "set user.email (ask)"   ask  "git config user.email attacker@evil.example"
check "set user.name (ask)"    ask  "git config user.name 'Someone Else'"
check "set signingkey (ask)"   ask  "git config gpg.signingkey BAD"

echo ""
echo "=== .git/hooks writes (expect: deny) ==="
check "echo into pre-commit"   deny "echo evil > .git/hooks/pre-commit"
check "cp into post-commit"    deny "cp payload /repo/.git/hooks/post-commit"

echo ""
echo "=== Remote redirection (expect: ask) ==="
check "remote set-url"         ask  "git remote set-url origin git@evil.example:x/y.git"
check "remote add"             ask  "git remote add upstream git@evil.example:x/y.git"

echo ""
echo "=== Remote branch delete (expect: ask) ==="
check "push --delete"          ask  "git push origin --delete feature-x"
check "push :branch"           ask  "git push origin :feature-x"

echo ""
echo "=== History rewrite (expect: deny) ==="
check "filter-branch"          deny "git filter-branch --env-filter 'x' HEAD"
check "filter-repo"            deny "git filter-repo --path secret"
check "update-ref"             deny "git update-ref -d refs/heads/x"
check "reflog expire"          deny "git reflog expire --expire=now --all"

echo ""
echo "=== Legitimate (expect: allow) ==="
check "git push origin main"         allow "git push origin main"
check "git push"                     allow "git push"
check "git push branch ending -f"    allow "git push origin wip-f"
check "git push feature-force"       allow "git push origin feature-force"
check "git add file.ts"              allow "git add src/index.ts"
check "git add .env.example"         allow "git add .env.example"
check "git add secrets.py"           allow "git add app/secrets.py"
check "git config core.editor"       allow "git config core.editor vim"
check "git commit"                   allow "git commit -m 'fix bug'"
check "git diff"                     allow "git diff HEAD~1"
check "git log"                      allow "git log --oneline -5"

echo ""
echo "=== Sensitive staging still denied (expect: deny) ==="
check "git add secrets.yaml"         deny "git add config/secrets.yaml"
check "git add .git-credentials"     deny "git add .git-credentials"

echo ""
echo "=== Anti-false-positive (expect: allow) ==="
check "commit msg --force"           allow "git commit -m 'block force-push variants'"
check "commit msg .env"              allow "git commit -m 'prevent staging .env files'"
check "commit msg filter-branch"     allow "git commit -m 'guard filter-branch'"
check "commit msg core.hooksPath"    allow "git commit -m 'block core.hooksPath tampering'"

echo ""
echo "=== Global-option prefix bypass — C1 (expect: same as unprefixed) ==="
check "-c push --force"        deny "git -c protocol.version=2 push --force origin main"
check "-c force-with-lease"    deny "git -c x=y push --force-with-lease"
check "-C dir push --force"    deny "git -C /repo push -f origin main"
check "-c hooksPath status"    deny "git -c core.hooksPath=/tmp/h status"
check "-c add ."               deny "git -c x=y add ."
check "-C dir add -A"          deny "git -C . add -A"
check "--git-dir add all"      deny "git --git-dir=.git add --all"
check "-c filter-branch"       deny "git -c x=y filter-branch HEAD"
check "legit -c commit"        allow "git -c user.name=CI commit -m 'ok'"
check "legit -C dir status"    allow "git -C /repo status"

echo ""
echo "=== git add path variants — #7 (expect: deny) ==="
check "git add ./"             deny "git add ./"
check "git add -- ."           deny "git add -- ."

echo ""
echo "=== Malicious alias — H2 (expect: deny for !, ask otherwise) ==="
check "alias with ! body"      deny "git config alias.ci '!sh script.sh'"
check "alias --global !"       deny "git config --global alias.x '!id'"
check "alias plain (ask)"      ask  "git config alias.st status"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
