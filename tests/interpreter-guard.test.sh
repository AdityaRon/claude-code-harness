#!/usr/bin/env bash
# Tests for interpreter-guard.sh
set -u
HOOK="hooks/interpreter-guard.sh"
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

echo "=== Inline env-var reads (expect: deny) ==="
check "python os.environ"   deny 'python3 -c "import os; print(os.environ[\"AWS_KEY\"])"'
check "python os.getenv"    deny 'python -c "import os; print(os.getenv(\"TOKEN\"))"'
check "node process.env"    deny 'node -e "console.log(process.env.AWS_SECRET)"'
check "ruby ENV"            deny 'ruby -e "puts ENV[\"TOKEN\"]"'
check "perl \$ENV"          deny 'perl -e "print $ENV{TOKEN}"'
check "bash -c printenv"    deny 'bash -c "printenv"'

echo ""
echo "=== Inline dotfile reads (expect: deny) ==="
check "python open .env"    deny 'python3 -c "print(open(\".env\").read())"'
check "node readFile .env"  deny 'node -e "console.log(require(\"fs\").readFileSync(\".env\",\"utf8\"))"'
check "perl .env"           deny 'perl -e "open(F,\".env\");print<F>"'
check "node aws creds"      deny 'node -e "const f=require(\"fs\");console.log(f.readFileSync(\".aws/credentials\",\"utf8\"))"'

echo ""
echo "=== Inline sockets / exfil (expect: deny) ==="
check "python socket"       deny 'python3 -c "import socket; s=socket.socket()"'
check "python requests.post" deny 'python3 -c "import requests; requests.post(u,d)"'
check "python urllib"       deny 'python -c "import urllib.request; urllib.request.urlopen(u)"'
check "node fetch"          deny 'node -e "fetch(\"https://x\").then(r=>r.text())"'

echo ""
echo "=== Inline subprocess chain (expect: deny) ==="
check "python subprocess"   deny 'python -c "import subprocess; subprocess.run([\"printenv\"])"'
check "node child_process"  deny 'node -e "require(\"child_process\").exec(\"printenv\")"'
check "python os.system"    deny 'python -c "import os; os.system(\"cat .env\")"'

echo ""
echo "=== Inline but benign (expect: allow) ==="
check "python print 1"      allow 'python3 -c "print(1+1)"'
check "node console.log"    allow 'node -e "console.log(\"hi\")"'
check "bash -c echo"        allow 'bash -c "echo hello"'
check "perl one-liner"      allow 'perl -e "print 42"'

echo ""
echo "=== Non-inline (expect: allow) ==="
check "python script.py"    allow "python3 script.py"
check "node server.js"      allow "node server.js"
check "bash build.sh"       allow "bash scripts/build.sh"
check "ruby rake.rb"        allow "ruby rake.rb"

echo ""
echo "=== Interpreter bypasses — H5 (expect: deny) ==="
check "php -r getenv"       deny 'php -r "echo getenv(\"AWS_SECRET\");"'
check "perl -ne combined"   deny 'perl -ne "print" .env'
check "perl -pe combined"   deny 'perl -pe "s/x/y/" .aws/credentials'
check "python heredoc"      deny 'python3 <<EOF
import os
print(os.environ["AWS_KEY"])
EOF'
check "bash heredoc env"    deny 'bash <<EOF
printenv
EOF'

echo ""
echo "=== Interpreter heredoc benign (expect: allow) ==="
check "python heredoc calc" allow 'python3 <<EOF
print(2 + 2)
EOF'

echo ""
echo "=== Wrapped in a command runner still inspected (expect: deny) ==="
check "poetry run python -c"   deny 'poetry run python -c "import os; print(os.environ[\"AWS_KEY\"])"'
check "env VAR= python -c"     deny 'env FOO=1 python3 -c "import os; print(os.environ[\"TOKEN\"])"'
check "timeout python -c"      deny 'timeout 5 python3 -c "import os; print(os.getenv(\"SECRET\"))"'
check "nohup node -e"          deny 'nohup node -e "console.log(process.env.TOKEN)"'
check "sudo python -c"         deny 'sudo python3 -c "import os; print(os.environ[\"X\"])"'

echo ""
echo "=== Benign wrapped commands (expect: allow) ==="
check "poetry run manage.py"   allow "poetry run python manage.py runserver"
check "poetry run pytest"      allow "poetry run pytest -q"
check "poetry run print"       allow 'poetry run python -c "print(1+1)"'
check "timeout train.py"       allow "timeout 30 python3 train.py"
check "env node server.js"     allow "env NODE_ENV=production node server.js"

echo ""
echo "=== Anti-false-positive (expect: allow) ==="
check "commit msg os.environ" allow "git commit -m 'refactor os.environ lookups'"
check "grep for process.env"  allow "grep -r process.env src/"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
