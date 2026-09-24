#!/usr/bin/env bash
# Tests for git-guard.sh — payloads built via jq so the outer command
# doesn't contain trigger strings.
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"  # guard decisions are audited; keep test ones out of the real log
HOOK="hooks/git-guard.sh"
PASS=0; FAIL=0

check() {
  local label="$1" expect="$2" cmd="$3"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
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
echo "=== Prefixes that used to defeat every check above (expect: deny) ==="
# The boundary anchor admits only ^ | & ; && || $( and a backtick. A leading
# assignment or wrapper is none of those, so each of these was ALLOWED SILENTLY
# while the bare form was denied. normalize_wrappers in lib.sh strips them.
check "VAR= prefix"              deny "VAR=1 git push -f origin main"
check "env VAR= prefix"          deny "env FOO=bar git push -f origin main"
check "nohup prefix"             deny "nohup git push -f origin main"
check "timeout prefix"           deny "timeout 60 git push -f origin main"
check "nice prefix"              deny "nice git push --force"
check "stacked prefixes"         deny "env A=1 B=2 nohup timeout 60 git push -f origin main"
check "assignment with \$HOME"    deny "PATH=\$HOME/bin git push -f origin main"
check "substitution assignment"  deny "X=\$(git push --force)"

echo ""
echo "=== Destructive worktree ops, incl. the -C form (expect: deny) ==="
# permissions.deny names these, but a deny rule is prefix-shaped and never saw
# `git -C <path> …` — -C is not a wrapper Claude Code strips. This hook does.
check "reset --hard"             deny "git reset --hard HEAD~3"
check "reset --hard -C"          deny "git -C /tmp/x reset --hard HEAD~3"
check "reset --hard VAR="        deny "VAR=1 git reset --hard origin/main"
check "clean -fd"                deny "git clean -fd"
check "clean -fd -C"             deny "git -C /tmp/x clean -fd"
check "clean --force"            deny "git clean --force"
check "branch -D"                deny "git branch -D topic"
check "branch -D -C"             deny "git -C /tmp/x branch -D topic"

echo ""
echo "=== Read-only and near-miss forms must stay silent (expect: allow) ==="
# Guards against over-blocking: these are the shapes the widened allowlist
# relies on, plus the near-misses the new patterns could plausibly catch.
check "git grep"                 allow "git grep -n needle"
check "git grep -C"              allow "git -C /tmp/x grep -n needle"
check "git rev-parse"            allow "git rev-parse --abbrev-ref HEAD"
check "git worktree list"        allow "git worktree list"
check "git worktree add"         allow "git worktree add /tmp/wt -b topic"
check "git clean --dry-run"      allow "git clean --dry-run"
check "git clean -n"             allow "git clean -n"
check "git branch --show-current" allow "git branch --show-current"
check "git branch -a"            allow "git branch -a"
check "git reset without --hard" allow "git reset HEAD~1"
check "--hard inside a message"  allow "git commit -m 'reset --hard is in the runbook'"
check "git add by name"          allow "git add src/main.py"

echo ""
echo "=== Force-push spellings that went silent — #B (expect: deny) ==="
# Each of these rewrites or deletes remote history, and none of them contains
# a whitespace-bounded -f / --force / --force-with-lease, which is all the
# force check looked for. permissions.deny spells only --force and -f, so
# nothing else stopped them either: the call was a full allow.
check "push +refspec"            deny "git push origin +main"
check "push +full refspec"       deny "git push origin +refs/heads/main:refs/heads/main"
check "push quoted +refspec"     deny "git push origin '+main'"
check "push --mirror"            deny "git push --mirror origin"
check "push --mirror after url"  deny "git push origin --mirror"
check "push -fu bundle"          deny "git push -fu origin main"
check "push -uf bundle"          deny "git push -uf origin main"
check "push -f with -C prefix"   deny "git -C /repo push -qf origin main"
check "push +refspec, VAR="      deny "VAR=1 git push origin +main"

echo ""
echo "=== Broad staging behind a flag or pathspec magic — #B (expect: deny) ==="
# The broad-add check required the path token to sit immediately after `add`,
# so any flag in between hid it. `:/` is pathspec magic for the repo root and
# stages the whole tree just like `.`.
check "git add -v ."             deny "git add -v ."
check "git add --verbose ."      deny "git add --verbose ."
check "git add -n -A"            deny "git add -n -A"
check "git add :/"               deny "git add :/"
check "git add -v :/"            deny "git add -v :/"

echo ""
echo "=== .git/hooks reached by cd — #B (expect: deny) ==="
# The check looked for the literal `.git/hooks/`, with the trailing slash, so
# changing into the directory first and writing a bare filename missed it.
check "cd into hooks, write"     deny "cd .git/hooks && cat > pre-commit"
check "cd into hooks, semicolon" deny "cd .git/hooks; printf x > pre-commit"
check "cd abs hooks dir"         deny "cd /repo/.git/hooks && chmod +x pre-push"

echo ""
echo "=== Near-misses of the widened patterns must stay silent (expect: allow) ==="
# The widened force, staging and hooks patterns must not swallow ordinary work.
check "push -u"                  allow "git push -u origin main"
check "push --set-upstream"      allow "git push --set-upstream origin feature-x"
check "push -q"                  allow "git push -q origin main"
check "push branch with plus"    allow "git push origin feature-c++"
check "push --follow-tags"       allow "git push --follow-tags origin main"
check "add named files"          allow "git add src/a.py src/b.py"
check "add a relative path"      allow "git add ./src/index.ts"
check "add -v by name"           allow "git add -v src/main.py"
check "mirror inside a message"  allow "git commit -m 'document push --mirror and +main'"
check "hooks word in a message"  allow "git commit -m 'harden the git hooks directory'"
# The .git/hooks check is deliberately unanchored — it fires wherever the path
# appears, including inside a commit message. Dropping the trailing slash from
# the pattern widens that, it does not change its shape, so a message naming
# the path literally is denied here exactly as `.git/hooks/` already was.
check "hooks path in a message"  deny  "git commit -m 'note the .git/hooks vector'"

echo ""
echo "=== Quoted and parent-tree staging, xargs, whole-tree discards ==="
check "add quoted dot"            deny 'git add "."'
check "add single-quoted dot"     deny "git add '.'"
check "add parent"                deny 'git add ..'
check "add parent slash"          deny 'git add ../'
check "add pwd"                   deny 'git add "$(pwd)"'
check "add PWD var"               deny 'git add $PWD'
check "xargs force push"          deny 'echo main | xargs git push --force origin'
check "xargs -I force push"       deny 'echo main | xargs -I {} git push -f origin {}'
check "checkout -- ."             deny 'git checkout -- .'
check "checkout ."                deny 'git checkout .'
check "restore ."                 deny 'git restore .'
check "restore -S -W ."           deny 'git restore -S -W .'
check "stash drop"                ask  'git stash drop'
check "stash clear"               ask  'git stash clear'
check "worktree remove --force"   ask  'git worktree remove --force ../wt'
check "add parent file"           allow 'git add ../README.md'
check "add dotfile by name"       allow 'git add .gitignore'
check "xargs add by name"         allow 'echo a.txt | xargs git add'
check "checkout - (switch back)"  allow 'git checkout -'
check "checkout a file"           allow 'git checkout -- src/app.ts'
check "restore --staged ."        allow 'git restore --staged .'
check "stash push"                allow 'git stash push -m wip'
check "worktree remove"           allow 'git worktree remove ../wt'

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
