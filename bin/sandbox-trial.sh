#!/usr/bin/env bash
# What Claude's commands can and cannot do here. Claude runs it as one Bash call
# (sandboxed when sandbox.sh on); a ! command or a terminal runs outside the
# sandbox. Auto mode refuses the call: add Bash(~/.claude/sandbox-trial.sh:*)
# with /permissions first. Each probe cleans up after itself.
#   sandbox-trial.sh [--offline] [--local-url http://127.0.0.1:PORT/]
set -uo pipefail
OFFLINE=0; LOCAL_URL="${SANDBOX_TRIAL_LOCAL_URL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline) OFFLINE=1 ;;
    --local-url) LOCAL_URL="${2:-}"; shift ;;
    --local-url=*) LOCAL_URL="${1#*=}" ;;
    *) sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 2 ;;
  esac
  shift
done
PASS=0; FAIL=0; ON=""
row() { printf '  %-5s %-34s %s\n' "$1" "$2" "$3"; }
try_write() { local f="$1/.sandbox-trial.$$"; (umask 077; : > "$f") 2>/dev/null && { rm -f "$f"; return 0; }; return 1; }

# Is this process sandboxed? A write to $HOME itself is the tell.
if try_write "$HOME"; then ON=0; else ON=1; fi
SET=$(jq -r '.sandbox.enabled // false' "${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}" 2>/dev/null)
if [[ $ON == 1 ]]; then echo "sandbox: ON"
elif [[ "$SET" == true ]]; then
  echo "sandbox: settings say on, but this shell is not sandboxed. Started with ! or from a terminal? Ask Claude to run it."
else echo "sandbox: OFF, so every probe below should simply work"; fi
expect() {   # expect NAME WANT(ok|blocked|any) RESULT(ok|blocked) DETAIL
  local name="$1" want="$2" got="$3" detail="${4:-}"
  if [[ $ON == 0 || "$want" == any ]]; then row INFO "$name" "$got $detail"
  elif [[ "$want" == "$got" ]]; then row PASS "$name" "$got $detail"; PASS=$((PASS+1))
  else row FAIL "$name" "$got, wanted $want $detail"; FAIL=$((FAIL+1)); fi
}
w() { try_write "$1" && echo ok || echo blocked; }

expect "write: project folder"          ok      "$(w "$PWD")"
# Claude Code keeps ~/.claude read-only to commands, ~/.claude/jobs included,
# and an allowWrite entry does not reopen it. Reported, not judged.
if [[ -n "${CLAUDE_JOB_DIR:-}" ]]; then
  expect "write: session scratch"       any     "$(w "$CLAUDE_JOB_DIR/tmp")" "(blocked is expected when on: Bash temp files go under \$TMPDIR)"
else
  row INFO "write: session scratch" "skipped: CLAUDE_JOB_DIR is unset, not a background job"
fi
expect "write: TMPDIR"                  ok      "$(w "${TMPDIR:-/tmp}")" "(${TMPDIR:-/tmp})"
# macOS mktemp with no template uses the per-user temp folder, not $TMPDIR.
m=$(d=$(mktemp -d 2>/dev/null) && rmdir "$d" && echo ok || echo blocked)
expect "write: mktemp -d, no template"  any     "$m" "(blocked: give it a template under \$TMPDIR)"
expect "write: home folder"             blocked "$(w "$HOME")"
expect "write: ~/.claude"               blocked "$(w "$HOME/.claude")"
expect "read: ~/.ssh"                   blocked "$(ls "$HOME/.ssh" >/dev/null 2>&1 && echo ok || echo blocked)" "(sandbox.filesystem.denyRead)"
if command -v python3 >/dev/null; then
  b=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); print("ok")' 2>/dev/null)
  expect "bind: a port on 127.0.0.1"    ok      "${b:-blocked}" "(sandbox.network.allowLocalBinding)"
fi

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null; }
if [[ -n "$LOCAL_URL" ]]; then   # loopback, so it runs with --offline too
  c=$(code "$LOCAL_URL")
  expect "net: $LOCAL_URL" ok "$([[ $c =~ ^[1-5][0-9][0-9]$ ]] && echo ok || echo blocked)" \
    "$([[ $c =~ ^[1-5][0-9][0-9]$ ]] && echo "(HTTP $c)" || echo "(no answer: is the server running? start it first)")"
fi
if [[ $OFFLINE == 0 ]]; then
  c=$(code https://api.github.com/zen); expect "net: api.github.com (listed)" ok "$([[ $c == 200 ]] && echo ok || echo blocked)" "(HTTP $c)"
  c=$(code https://example.com/); expect "net: example.com (not listed)" blocked "$([[ $c == 200 ]] && echo ok || echo blocked)" "(HTTP $c)"
  r=$(git ls-remote https://github.com/AdityaRon/claude-code-harness HEAD 2>/dev/null | head -c 7)
  expect "net: git over https to github" ok "$([[ -n "$r" ]] && echo ok || echo blocked)"
  for sock in /var/run/docker.sock "$HOME/.docker/run/docker.sock"; do   # Docker Desktop uses the second
    [[ -S "$sock" ]] || continue
    c=$(code --unix-socket "$sock" http://localhost/_ping)
    expect "socket: ${sock/#$HOME/~}" blocked "$([[ $c == 200 ]] && echo ok || echo blocked)" "(docker itself is in excludedCommands)"
  done
fi

echo ""
if [[ $ON == 1 ]]; then
  echo "$PASS as expected, $FAIL not. Now run, one per Bash call:"
  echo "  docker ps;  gh api user -q .login;  kubectl version --client;  git fetch --dry-run"
  echo "excludedCommands match the whole command: 'docker ps | head' runs sandboxed and fails."
  echo "And one guard check: cat .env (env-guard should still deny it)."
fi
exit $(( FAIL > 0 ? 1 : 0 ))
