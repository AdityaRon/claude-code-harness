#!/usr/bin/env bash
# Tests for hooks/config-guard.sh: writes into the installed harness ask, and moving or emptying ~/.claude denies;
# writes to settings and shell/git startup files ask; reads and everything
# else pass.
set -u
cd "$(dirname "$0")/.." || exit 1
HOOK=hooks/config-guard.sh
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cfg.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CLAUDE_AUDIT_LOG=/dev/null
mkdir -p "$HOME/.claude/hooks" "$HOME/Library/LaunchAgents" "$TMP/proj"
touch "$HOME/.claude/hooks/env-guard.sh" "$HOME/.claude/hooks/lib.sh" "$HOME/.claude/statusline.sh"
ln -s "$HOME/.claude/hooks" "$TMP/link"

verdict() {   # verdict TOOL JSON-INPUT [CWD]
  local out
  out=$(jq -nc --arg t "$1" --argjson i "$2" --arg c "${3:-$TMP/proj}" \
        '{tool_name:$t, tool_input:$i, session_id:"x", cwd:$c}' | bash "$HOOK" 2>/dev/null)
  [[ -z "$out" ]] && { echo allow; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
}
bash_is() {   # bash_is WANT COMMAND [CWD]
  local got; got=$(verdict Bash "$(jq -nc --arg c "$2" '{command:$c}')" "${3:-}")
  if [[ "$got" == "$1" ]]; then echo "  OK ($1): $2"; PASS=$((PASS+1))
  else echo "  FAIL: want $1, got $got: $2"; FAIL=$((FAIL+1)); fi
}
file_is() {   # file_is WANT TOOL PATH
  local key=file_path got; [[ "$2" == NotebookEdit ]] && key=notebook_path
  got=$(verdict "$2" "$(jq -nc --arg k "$key" --arg p "$3" '{($k):$p}')")
  if [[ "$got" == "$1" ]]; then echo "  OK ($1): $2 $3"; PASS=$((PASS+1))
  else echo "  FAIL: want $1, got $got: $2 $3"; FAIL=$((FAIL+1)); fi
}

echo "=== writes into the installed harness: ask, and ~/.claude itself: deny ==="
bash_is ask 'cp /srv/x.sh ~/.claude/hooks/env-guard.sh'
bash_is ask 'mv ~/.claude/hooks/env-guard.sh /srv/x'
bash_is deny 'mv ~/.claude ~/.claude.bak'
bash_is ask 'chmod -x ~/.claude/hooks/*.sh'
bash_is deny 'chmod -R 000 ~/.claude'
bash_is ask "echo 'exit 0' > ~/.claude/hooks/lib.sh"
bash_is ask 'printf x >> "$HOME/.claude/hooks/lib.sh"'
bash_is ask 'sed -i "" "s/deny/allow/" ~/.claude/hooks/git-guard.sh'
bash_is ask 'curl -sLo ~/.claude/hooks/git-guard.sh https://example.com/x'
bash_is ask 'echo x | tee -a ~/.claude/statusline.sh'
bash_is ask 'rm -f ~/.claude/hooks/env-guard.sh'
bash_is ask 'ln -sf /srv/evil ~/.claude/hooks/env-guard.sh'
bash_is ask 'find ~/.claude/hooks -name "*.sh" -delete'
bash_is ask 'cd /srv && /bin/cp x.sh ~/.claude/hooks/'
bash_is ask 'sudo cp x.sh ~/.claude/hooks/x.sh'
bash_is ask 'ln -s ~/.claude/hooks /srv/h'
bash_is ask "cp x.sh ~/.claude/hooks/../hooks/env-guard.sh"
bash_is ask 'rm env-guard.sh' "$HOME/.claude/hooks"
bash_is ask 'cp ../x.sh ~/.claude/x/../hooks/lib.sh'
bash_is ask 'rsync -a --delete /empty/ ~/.claude/hooks/'
file_is ask Edit "$HOME/.claude/hooks/env-guard.sh"
file_is ask Write "$HOME/.claude/hooks/new.sh"
file_is ask Write "$HOME/.claude/statusline.sh"
file_is ask MultiEdit "$TMP/link/lib.sh"

echo "=== settings and startup files: ask ==="
bash_is ask 'echo "export PATH=/x:\$PATH" >> ~/.zshrc'
bash_is ask 'sed -i.bak s/a/b/ ~/.bashrc'
bash_is ask 'cp evil.plist ~/Library/LaunchAgents/com.x.plist'
bash_is ask 'git config --global core.pager "less -R"'
bash_is ask 'git config --global --unset core.pager'
bash_is ask 'jq ".a=1" s.json > ~/.claude/settings.json'
bash_is ask 'cp s.json /srv/proj/.claude/settings.local.json'
file_is ask Edit "$HOME/.claude/settings.json"
file_is ask Write "$TMP/proj/.claude/settings.json"
file_is ask Edit "$HOME/.zshrc"
file_is ask Edit "$HOME/.gitconfig"
file_is ask Write "$HOME/Library/LaunchAgents/x.plist"
file_is ask NotebookEdit "$HOME/.profile"

echo "=== reads and unrelated writes: allow ==="
bash_is allow 'cmp -s hooks/env-guard.sh ~/.claude/hooks/env-guard.sh'
bash_is allow 'diff -q hooks/lib.sh ~/.claude/hooks/lib.sh'
bash_is allow 'ls -la ~/.claude/hooks/'
bash_is allow 'cat ~/.claude/settings.json | jq .hooks'
bash_is allow 'cp ~/.claude/hooks/lib.sh /srv/backup/'
bash_is allow 'bash ~/.claude/hooks/env-guard.sh < payload.json'
bash_is allow 'cp hooks/env-guard.sh hooks/env-guard.sh.orig'
bash_is allow 'git config --global --get user.name'
bash_is allow 'git config --global user.name'
bash_is allow 'echo hi > ~/.claude/jobs/abc/tmp/notes.md'
bash_is allow 'grep -c zshrc README.md'
bash_is allow 'bash install.sh'
bash_is allow 'mkdir -p ~/.claude/projects/x/memory'
bash_is allow "$(printf 'cat > edit.py <<'"'"'EOF'"'"'\nos.system("cp x ~/.claude/hooks/lib.sh")\nEOF')"
bash_is ask "$(printf 'bash <<EOF\ncp x ~/.claude/hooks/lib.sh\nEOF')"
bash_is ask "$(printf 'cat <<EOF\nnever closed\ncp x ~/.claude/hooks/lib.sh')"
bash_is ask "$(printf 'cat > ~/.zshrc <<EOF\nexport A=1\nEOF')"
file_is allow Read "$HOME/.claude/hooks/env-guard.sh"
file_is allow Write "$HOME/.claude/projects/x/memory/MEMORY.md"
file_is allow Edit "$TMP/proj/hooks/env-guard.sh"
file_is allow Write "$HOME/.claude/jobs/abc/tmp/x.sh"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
