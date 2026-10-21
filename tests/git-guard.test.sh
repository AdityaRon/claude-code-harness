#!/usr/bin/env bash
# Tests for git-guard.sh — payloads built via jq so the outer command
# doesn't contain trigger strings.
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
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
check "--unset user.email (ask)" ask "git config --unset user.email"
check "git config set (ask)"   ask  "git config set user.name x"
check "write after a read (ask)" ask "git config user.name; git config user.email x@y.z"
check "-C repo, a write (ask)" ask  "git -C repo config user.email x@y.z"
# Reads: the identity check used `.*`, which ran past the `;` after a read.
check "read, then ls"          allow "git config --global user.name; git config --global user.email; ls -lt | head -8"
check "read with --get"        allow "git config --get user.name"
check "read in a substitution" allow 'NAME=$(git config user.name)'
check "read, stderr dropped"   allow "git config user.email 2>/dev/null || echo unset"
check "git config get"         allow "git config get user.name"

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
check "push --delete, no repo to check" ask "git push origin --delete feature-x"
check "push :branch, no repo to check"  ask "git push origin :feature-x"

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
# lib.sh's assignment rule ran through an unquoted `;` and split a quoted value at its space.
check "VAR=1; with no space"     deny "X=1;git push -f origin main"
check "quoted value with a space" deny 'X="a b" git push -f origin main'
check "quoted value with a ;"    deny "X='a;b' git push -f origin main"
check "VAR=1;git status"         allow "X=1;git status"
check "escaped ; in a value"     deny 'X=a\;b git push -f origin main'
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
check "branch -D, no repo to check" ask "git branch -D topic"
check "branch -D -C, not a repo"     ask "git -C /tmp/x branch -D topic"

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
check "push --mirr abbreviation" deny "git push --mirr origin"
check "push --m abbreviation"    deny "git push origin --m"
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
check "hooks path in a dq message" deny 'git commit -m "see .git/hooks; it is guarded"'

echo ""
echo "=== A quoted message is text; what runs is not (A11b) ==="
check "sq message with ; push --force"  allow "git commit -m 'fix: note; git push --force stays denied'"
check "dq message with ; push --force"  allow 'git commit -m "fix: note; git push --force stays denied"'
check "bundled -am message"             allow 'git commit -am "x; git add ."'
check "--message= and attached -m"      allow "git commit --message='a; git reset --hard' -m'b; git clean -f'"
check "git -C dir commit message"       allow "git -C repo commit -m 'note; git push --force'"
check "gh title and body"               allow "gh pr create --title \"a; git push --force\" --body 'b; git add .'"
check "cmdsub heredoc message"          allow $'git commit -m "$(cat <<\'EOF\'\nfix: guard\n\ngit push --force is still denied\nEOF\n)"'
check "cmdsub heredoc, plain unquoted"  allow $'git commit -m "$(cat <<EOF\nguard tweaks; git add . is denied\nEOF\n)"'
check "-F - heredoc message"            allow $'git commit -F - <<\'EOF\'\nguard tweaks\n\ngit add . is still denied\nEOF'
check "push after a message"            deny  "git commit -m 'wip' && git push --force"
check "push after a dq message"         deny  'git commit -am "x; y" ; git push -f origin main'
check "message runs a cmdsub"           deny  'git commit -m "$(git push --force)"'
check "dq message holding \$ stays"     deny  'git commit -m "$X; git push --force"'
check "ANSI-C message stays"            deny  "git commit -m \$'a\\'; git push --force'"
check "unclosed message quote"          deny  "git commit -m 'note; git push --force"
check "cmdsub heredoc piped to bash"    deny  $'git commit -m "$(cat <<\'EOF\' | bash\ngit push --force\nEOF\n)"'
check "cmdsub heredoc read by bash"     deny  $'git commit -m "$(bash <<\'EOF\'\ngit push --force\nEOF\n)"'
check "unquoted heredoc body runs \$()" deny  $'git commit -m "$(cat <<EOF\n$(git push --force)\nEOF\n)"'
check "push takes no message flag"      deny  "git push -m 'x' --force"
check "comment line keeps old reading"  deny  $'# it\'s\ngit commit -m \'x\'; git push --force'
# Known limit: a wrapper before git is not read as a commit, so its message stays.
check "wrapper before commit (limit)"   deny  "VAR=1 git commit -m 'note; git push --force'"

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
echo "=== Other spellings of the binary, more wrappers (issue #2 E) ==="
# The shell runs each of these as git; every one was allowed silently.
check "absolute path"             deny '/usr/bin/git push --force origin main'
check "quoted binary"             deny '"git" push -f origin main'
check "quotes inside the binary"  deny 'g"i"t push -f origin main'
check "backslash-escaped binary"  deny '\git push -f origin main'
check "upper case, case-insensitive fs" deny 'GIT push --force origin main'
check "path after a chain"        deny 'cd x && /usr/bin/git reset --hard'
check "nice -n 10"                deny 'nice -n 10 git push -f origin main'
check "exec"                      deny 'exec git push -f origin main'
check "sudo"                      deny 'sudo git push -f origin main'
check "sudo -u root"              deny 'sudo -u root git push -f origin main'
check "stdbuf -o0"                deny 'stdbuf -o0 git push -f origin main'
check "env -i"                    deny 'env -i git push -f origin main'
check "ionice -c 3"               deny 'ionice -c 3 git push -f origin main'
check "caffeinate -i"             deny 'caffeinate -i git push -f origin main'
check "doas -u root"              deny 'doas -u root git push -f origin main'
check "near miss: mygit"          allow 'mygit push -f origin main'
check "near miss: dir named git"  allow '/opt/git/bin/tool push -f origin main'
check "near miss: echoed"         allow 'echo GIT push --force'
check "near miss: cd into git"    allow 'cd /usr/bin/git'

echo ""
echo "=== worktree remove --force: a scratch worktree of this session runs ==="
WT_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")"; mkdir -p "$WT_HOME/.claude/jobs/abcd1234/tmp"
check_wt() {
  local label="$1" expect="$2" cmd="$3" cwd="${4:-/repo}" out got
  out=$(jq -nc --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"abcd1234-0000-4000-8000-000000000000"}' \
    | HOME="$WT_HOME" TMPDIR="" bash hooks/git-guard.sh 2>/dev/null)
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null); got="${got:-allow}"
  if [[ "$got" == "$expect" ]]; then echo "  OK ($expect): $label"; PASS=$((PASS+1))
  else echo "  FAIL (expected=$expect got=$got): $label  [cmd: $cmd]"; FAIL=$((FAIL+1)); fi
}
check_wt "--force on \$CLAUDE_JOB_DIR/tmp/wt" allow 'git worktree remove --force "$CLAUDE_JOB_DIR/tmp/wt-1"'
check_wt "-f on a literal scratch path"      allow "git worktree remove -f $WT_HOME/.claude/jobs/abcd1234/tmp/wt-2"
check_wt "-C repo, scratch worktree"         allow 'git -C ~/src/app worktree remove --force ~/.claude/jobs/abcd1234/tmp/wt-3'
check_wt "--force on a repo worktree"        ask   'git worktree remove --force ../app-feature'
check_wt "--force, climbs out with .."       ask   'git worktree remove --force "$CLAUDE_JOB_DIR/tmp/../../repo"'
check_wt "--force, redefines CLAUDE_JOB_DIR" ask   'CLAUDE_JOB_DIR=/ git worktree remove --force "$CLAUDE_JOB_DIR/tmp/../../repo"'
check_wt "--force, another session"          ask   'git worktree remove --force ~/.claude/jobs/ffffffff/tmp/wt'
check_wt "--force, CLAUDE_JOB_DIR set inline"  ask   'CLAUDE_JOB_DIR=/x git worktree remove --force "$CLAUDE_JOB_DIR/tmp/wt"'
check_wt "--force in the sandbox job folder"  allow "git worktree remove --force /tmp/claude-$(id -u)/abcd1234/wt-4"
check_wt "--force, another job's folder"      ask   "git worktree remove --force /tmp/claude-$(id -u)/ffffffff/wt"
check_wt "stash drop still asks"             ask   'git stash drop'

echo ""
echo "=== worktree remove --force: a worktree with nothing to lose runs ==="
R="$TMP/wtrepo"; mkdir -p "$R"
git init -q "$R/main" && printf 'build/\n' > "$R/main/.gitignore" && git -C "$R/main" add .gitignore \
  && git -C "$R/main" -c user.email=t@t -c user.name=t commit -q -m init
for k in clean ign dirty mod; do git -C "$R/main" worktree add -q "$R/$k" -b "b-$k"; done
mkdir -p "$R/ign/build" && echo x > "$R/ign/build/out"; echo u > "$R/dirty/new.txt"; echo m >> "$R/mod/.gitignore"
check_wt "--force, clean worktree"           allow "git worktree remove --force $R/clean"
check_wt "--force, only ignored files"       allow "git worktree remove -f $R/ign"
check_wt "--force, an untracked file"        ask   "git worktree remove --force $R/dirty"
check_wt "--force, a modified file"          ask   "git worktree remove --force $R/mod"
check_wt "--force, relative from the cwd"    allow 'git worktree remove --force ../clean' "$R/main"
check_wt "--force, relative after a cd"      ask   'cd /tmp && git worktree remove --force ../clean' "$R/main"
check_wt "--force, a path in a variable"     ask   "W=$R/clean; git worktree remove --force \$W"
check_wt "--force, clean then dirty"         ask   "git worktree remove --force $R/clean && git worktree remove --force $R/dirty"
check_wt "--force, no such path"             ask   "git worktree remove --force $R/gone"

echo ""
echo "=== branch delete: runs only when a remote-tracking ref holds the tip ==="
git init -q --bare "$R/remote.git" && git -C "$R/main" remote add origin "$R/remote.git"
git -C "$R/main" branch b-pushed && git -C "$R/main" branch Feature-X
git -C "$R/main" push -q origin b-pushed Feature-X 2>/dev/null
git -C "$R/main" checkout -q -b b-local \
  && git -C "$R/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local && git -C "$R/main" checkout -q -
M="$R/main"
check_wt "-D, tip on a remote"               allow "git branch -D b-pushed" "$M"
check_wt "-d, tip on a remote"               allow "git branch -d b-pushed" "$M"
check_wt "-D, mixed-case name on a remote"   allow "git branch -D Feature-X" "$M"
check_wt "-D -C, tip on a remote"            allow "git -C $M branch -D b-pushed"
check_wt "-D, redirect after the name"       allow "git branch -D b-pushed 2>/dev/null" "$M"
check_wt "--delete --force"                  allow "git branch --delete --force b-pushed" "$M"
check_wt "-D, commits only local"            ask   "git branch -D b-local" "$M"
check_wt "-D, one of two only local"         ask   "git branch -D b-pushed b-local" "$M"
check_wt "-D, no such branch"                ask   "git branch -D b-gone" "$M"
check_wt "-D, name in a variable"            ask   "B=b-pushed; git branch -D \$B" "$M"
check_wt "-D, after a cd"                    ask   "cd $M && git branch -D b-pushed" "/tmp"
check_wt "-D, names from xargs"              ask   "git branch | xargs git branch -D" "$M"
check_wt "-D, unknown flag"                  ask   "git branch -D -r origin/b-pushed" "$M"
check_wt "-D, then a local-only delete"      ask   "git branch -D b-pushed && git branch -D b-local" "$M"
check_wt "-qD bundle, tip on a remote"       allow "git branch -qD b-pushed" "$M"
check_wt "a new branch named like a flag"    allow "git branch feature-d" "$M"
# The gate reads the normalized line, the parser the command as typed: a second
# delete spelled another way was never checked and the first passed the call.
check_wt "-D, then one spelled /usr/bin/git" ask   "git branch -D b-pushed; /usr/bin/git branch -D b-local" "$M"
check_wt "-D, then one spelled \"git\""        ask   "git branch -D b-pushed; \"git\" branch -D b-local" "$M"
check_wt "-D, then one spelled GIT"          ask   "git branch -D b-pushed && GIT branch -D b-local" "$M"
check_wt "-D, then one spelled \\git"         ask   "git branch -D b-pushed && \\git branch -D b-local" "$M"
check_wt "-D, then one a function runs"      ask   "f() { \"\$@\"; }; git branch -D b-pushed; f git branch -D b-local" "$M"
check_wt "-D, xargs adds a name"             ask   "echo b-local | xargs git branch -D b-pushed" "$M"
check_wt "-qD bundle, commits only local"    ask   "git branch -qD b-local" "$M"
check_wt "-Dq bundle, commits only local"    ask   "git branch -Dq b-local" "$M"
check_wt "--del abbreviation"                ask   "git branch --del --force b-local" "$M"
check_wt "quoted -D"                         ask   "git branch \"-D\" b-local" "$M"
# The gate and the parser both read the command with its quoted message gone.
check_wt "-D after a message naming another" allow "git commit -m 'note; git branch -D b-local' && git branch -D b-pushed" "$M"

echo ""
echo "=== push --delete: runs only when another ref holds the tip the remote reports ==="
gc() { git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"; }
DEF=$(git -C "$M" symbolic-ref --short HEAD)
git -C "$M" push -q origin "$DEF" 2>/dev/null && git -C "$R/remote.git" symbolic-ref HEAD "refs/heads/$DEF"
# b-merged: pushed, fast-forwarded into DEF, local copy deleted
git -C "$M" checkout -q -b b-merged && gc "$M" merged && git -C "$M" push -q origin b-merged 2>/dev/null \
  && git -C "$M" checkout -q "$DEF" && git -C "$M" merge -q --ff-only b-merged && git -C "$M" branch -q -d b-merged
# b-orphan: pushed, never merged, local copy gone
git -C "$M" checkout -q -b b-orphan && gc "$M" orphan && git -C "$M" push -q origin b-orphan 2>/dev/null \
  && git -C "$M" checkout -q "$DEF" && git -C "$M" branch -q -D b-orphan
# b-twin1, b-twin2: one unmerged commit under two remote names, local copy gone
git -C "$M" checkout -q -b b-twin && gc "$M" twin && git -C "$M" push -q origin b-twin:b-twin1 b-twin:b-twin2 2>/dev/null \
  && git -C "$M" checkout -q "$DEF" && git -C "$M" branch -q -D b-twin
# b-ahead: another clone pushed after this one last fetched
git clone -q "$R/remote.git" "$R/other" 2>/dev/null && git -C "$R/other" checkout -q -b b-ahead "origin/$DEF" \
  && gc "$R/other" a1 && git -C "$R/other" push -q origin b-ahead 2>/dev/null \
  && git -C "$M" fetch -q origin && git -C "$M" branch -q b-ahead origin/b-ahead \
  && gc "$R/other" a2 && git -C "$R/other" push -q origin b-ahead 2>/dev/null
git -C "$M" tag v1 && git -C "$M" push -q origin v1 2>/dev/null
# det: a remote whose HEAD names no branch. pu: pushes somewhere other than it fetches. Neither is fetched.
git clone -q --bare "$R/remote.git" "$R/det.git" 2>/dev/null \
  && git -C "$R/det.git" update-ref --no-deref HEAD "$(git -C "$R/det.git" rev-parse "refs/heads/$DEF")"
git -C "$M" remote add det "$R/det.git" && git -C "$M" remote add pu "$R/remote.git" && git -C "$M" remote set-url --push pu "$R/det.git"
check_wt "--delete, tip on a local branch"     allow "git push origin --delete b-pushed" "$M"
check_wt "--delete before the remote"          allow "git push --delete origin b-pushed" "$M"
check_wt "-d"                                  allow "git push -d origin b-pushed" "$M"
check_wt ":branch"                             allow "git push origin :b-pushed" "$M"
check_wt "--delete, merged into the default"   allow "git push origin --delete b-merged" "$M"
check_wt "--delete refs/heads/<name>"          allow "git push origin --delete refs/heads/b-pushed" "$M"
check_wt "--delete, mixed-case name"           allow "git push origin --delete Feature-X" "$M"
check_wt "--delete, two held names"            allow "git push origin --delete b-pushed b-merged" "$M"
check_wt "a push and a :branch"                allow "git push origin $DEF :b-pushed" "$M"
check_wt "-C repo, cwd elsewhere"              allow "git -C $M push origin --delete b-pushed" "/tmp"
check_wt "redirect after the name"             allow "git push origin --delete b-pushed 2>/dev/null" "$M"
check_wt "-q"                                  allow "git push -q origin --delete b-pushed" "$M"
check_wt "one twin; the other still holds it"  allow "git push origin --delete b-twin1" "$M"
check_wt "--delete only in a later segment"    allow "git push origin $DEF; echo --delete" "$M"
check_wt "--delete, only the remote holds it"  ask   "git push origin --delete b-orphan" "$M"
check_wt ":branch, only the remote holds it"   ask   "git push origin :b-orphan" "$M"
check_wt "-d, only the remote holds it"        ask   "git push -d origin b-orphan" "$M"
check_wt "--delete, remote moved since fetch"  ask   "git push origin --delete b-ahead" "$M"
check_wt "--delete, the remote's default"      ask   "git push origin --delete $DEF" "$M"
check_wt "--delete, one of two only remote"    ask   "git push origin --delete b-pushed b-orphan" "$M"
check_wt "--delete, twins hold each other"     ask   "git push origin --delete b-twin1 b-twin2" "$M"
check_wt "--delete, twins in two segments"     ask   "git push origin --delete b-twin1 && git push origin --delete b-twin2" "$M"
check_wt "--delete, no such remote branch"     ask   "git push origin --delete b-local" "$M"
check_wt "--delete, a tag"                     ask   "git push origin --delete v1" "$M"
check_wt "--delete refs/tags/"                 ask   "git push origin --delete refs/tags/v1" "$M"
check_wt "--delete, not a configured remote"   ask   "git push nosuch --delete b-pushed" "$M"
check_wt "--delete, a URL"                     ask   "git push $R/remote.git --delete b-pushed" "$M"
check_wt "--delete, push URL differs"          ask   "git push pu --delete b-pushed" "$M"
check_wt "--delete, remote HEAD names no branch" ask "git push det --delete b-pushed" "$M"
check_wt "--delete, name in a variable"        ask   "B=b-pushed; git push origin --delete \$B" "$M"
check_wt "--delete, quoted name"               ask   "git push origin --delete 'b-pushed'" "$M"
check_wt "--delete, after a cd"                ask   "cd $M && git push origin --delete b-pushed" "/tmp"
check_wt "--delete, names from xargs"          ask   "echo b-pushed | xargs git push origin --delete" "$M"
check_wt "--delete, xargs adds a name"         ask   "echo b-orphan | xargs git push origin --delete b-pushed" "$M"
check_wt "--delete, unknown flag"              ask   "git push --prune origin --delete b-pushed" "$M"
check_wt "--delete, not a repo"                ask   "git push origin --delete b-pushed" "$TMP"
check_wt "--delete, then an unheld one"        ask   "git push origin --delete b-pushed && git push origin --delete b-orphan" "$M"
check_wt "--delete, then one spelled /usr/bin/git" ask "git push origin --delete b-pushed; /usr/bin/git push origin --delete b-orphan" "$M"
check_wt "--delete, then one spelled \"git\""    ask   "git push origin --delete b-pushed; \"git\" push origin --delete b-orphan" "$M"
check_wt "--delete, and the local branch"      ask   "git push origin --delete b-pushed && git branch -D b-pushed" "$M"
check_wt "local -D, then --delete"             ask   "git branch -D b-pushed && git push origin --delete b-pushed" "$M"
check_wt "--del abbreviation"                  ask   "git push origin --del b-orphan" "$M"
check_wt "-qd bundle"                          ask   "git push -qd origin b-orphan" "$M"
check_wt "quoted --delete"                     ask   "git push origin \"--delete\" b-orphan" "$M"
check_wt "quoted :branch"                      ask   "git push origin ':b-orphan'" "$M"
check_wt "+:branch"                            ask   "git push origin +:b-orphan" "$M"
check_wt "-f with --delete"                    deny  "git push -f origin --delete b-pushed" "$M"
check_wt "not a delete: src:dst"               allow "git push origin HEAD:$DEF" "$M"
check_wt "not a delete: a name ending in -d"   allow "git push origin feature-d" "$M"
check_wt "not a delete: -u a:a"                allow "git push -u origin b-pushed:b-pushed" "$M"
check_wt "not a delete: --dry-run"             allow "git push --dry-run origin $DEF" "$M"

echo ""
echo "=== broad add: runs when git status lists no credential file it would stage ==="
G="$R/addrepo"; git init -q "$G" && echo a > "$G/a.txt" && git -C "$G" add a.txt \
  && git -C "$G" -c user.email=t@t -c user.name=t commit -q -m init && mkdir -p "$G/sub" && echo b > "$G/sub/b.txt"
echo s > "$G/.env.example"
check_wt "-A, ordinary untracked files"      allow "git add -A" "$G"
check_wt ". from a subdirectory"             allow "git add ." "$G/sub"
check_wt "-C repo, cwd elsewhere"            allow "git -C $G add --all" "/tmp"
check_wt "-A -- ."                           allow "git add -v -A -- ." "$G"
G2="$R/addrepo2"; git init -q "$G2" && echo s > "$G2/.env"
check_wt "clean add, then one spelled /usr/bin/git" deny "git add -A && /usr/bin/git -C $G2 add -A" "$G"
check_wt "clean add, then one spelled \"git\""        deny "git add -A && \"git\" -C $G2 add -A" "$G"
# Every credential file sensitive-file-guard knows, not a shorter list of its own.
for f in id_ecdsa id_dsa .npmrc .pypirc credentials.json service_account.json certs/client.p12 keys/app.jks \
         prod.tfvars terraform.tfstate kubeconfig .claude.json .kube/config .ssh/deploy_key .docker/config.json; do
  mkdir -p "$(dirname "$G/$f")" && echo x > "$G/$f"
  check_wt "-A, an untracked $f"             deny  "git add -A" "$G"
  rm -f "$G/$f"; rmdir "$(dirname "$G/$f")" 2>/dev/null
done
echo x > "$G/.NPMRC"
check_wt "-A, upper-case .NPMRC"             deny  "git add -A" "$G"
rm -f "$G/.NPMRC"
check_wt "-A, after those are gone"          allow "git add -A" "$G"
# -f adds ignored files git status never lists, in any spelling git takes.
G3="$R/addrepo3"; git init -q "$G3" && printf '.env\n' > "$G3/.gitignore" && git -C "$G3" add .gitignore \
  && git -C "$G3" -c user.email=t@t -c user.name=t commit -q -m init && echo s > "$G3/.env"
check_wt "ignored .env, plain -v ."          allow "git add -v ." "$G3"
check_wt "ignored .env, -A"                  allow "git add -A" "$G3"
check_wt "ignored .env, -f ."                deny  "git add -f ." "$G3"
check_wt "ignored .env, -fv ."               deny  "git add -fv ." "$G3"
check_wt "ignored .env, . -f"                deny  "git add . -f" "$G3"
check_wt "ignored .env, -f -- ."             deny  "git add -f -- ." "$G3"
check_wt "ignored .env, -Af"                 deny  "git add -Af" "$G3"
check_wt "ignored .env, -fA"                 deny  "git add -fA" "$G3"
check_wt "ignored .env, --forc ."            deny  "git add --forc ." "$G3"
check_wt "ignored .env, --f ."               deny  "git add --f ." "$G3"
echo s > "$G/sub/.env"
check_wt "-A, an untracked .env below"       deny  "git add -A" "$G"
check_wt ". from the root, .env below"       deny  "git add ." "$G"
check_wt "-vA bundle, .env below"            deny  "git add -vA" "$G"
check_wt "--al abbreviation, .env below"     deny  "git add --al" "$G"
check_wt "-C repo, .env below"               deny  "git -C $G add -A" "/tmp"
rm "$G/sub/.env"; echo k > "$G/server.key"
check_wt "-A, an untracked .key"             deny  "git add -A" "$G"
rm "$G/server.key"; echo m >> "$G/a.txt"; mv "$G/a.txt" "$G/secrets.yaml"
check_wt "-A, a modified file renamed"       deny  "git add -A" "$G"
mv "$G/secrets.yaml" "$G/a.txt"
check_wt "-Af, ignored files are unseen"     deny  "git add -Af ." "$G"
check_wt "--force"                           deny  "git add --force -A" "$G"
check_wt "after a cd"                        deny  "cd $G && git add -A" "/tmp"
check_wt "repo in a variable"                deny  "git -C \$G add -A" "/tmp"
check_wt "not a repo"                        deny  "git add -A" "$TMP"
check_wt "names from xargs"                  deny  "echo x | xargs git add -A" "$G"
check_wt "clean add, then a named .env"      deny  "git add -A && git add sub/.env" "$G"
rm -rf "$WT_HOME"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
