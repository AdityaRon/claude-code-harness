#!/usr/bin/env bash
# Tests for kubectl-guard.sh
set -u
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"  # guard decisions are audited; keep test ones out of the real log
HOOK="hooks/kubectl-guard.sh"
PASS=0; FAIL=0

check() {
  local label="$1" expect="$2" cmd="$3"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
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

echo "=== read-only verbs, flags BEFORE the verb (expect: allow) ==="
check "get svc, context+ns first"  allow 'kubectl --context teleport.example-prod -n vm get svc vmselect-vm'
check "get pods -A"                allow 'kubectl get pods -A'
check "delete on a second line"    ask   $'echo start\nkubectl --context prod delete pod api-1'
check "current-context then ;"     allow 'kubectl config current-context; echo done'
check "which kubectl 2>&1"         allow 'which kubectl 2>&1'
check "grep pattern naming kubectl" allow 'grep -rn "kubectl port-forward" docs/ | head -5'
check "grep, then a real delete"   ask   'grep -l kubectl scripts/* && kubectl delete pod foo'
check "text piped to a shell"      ask   "echo 'kubectl delete pod x' | \$SHELL"
check "describe with ns first"     allow 'kubectl -n vm describe pod vmselect-vm-0'
check "logs"                       allow 'kubectl --context X -n vm logs deploy/foo --tail 100'
check "top"                        allow 'kubectl top pods -n vm'
check "port-forward to a service" allow 'kubectl --context X port-forward -n vm svc/vmselect-vm 18481:8481'
check "version"                    allow 'kubectl version --client'
check "api-resources"              allow 'kubectl api-resources'
check "cluster-info"               allow 'kubectl cluster-info'
check "wait"                       allow 'kubectl wait --for=condition=Ready pod/foo -n vm'
check "label selector says delete" allow 'kubectl get pods -n vm -l app=delete'

echo ""
echo "=== Other spellings of the binary, more wrappers (issue #2 E) ==="
check "upper case"               ask 'KUBECTL delete pod foo'
check "backslash-escaped"        ask '\kubectl delete pod foo'
check "nice -n 10"               ask 'nice -n 10 kubectl delete pod foo'
check "sudo -u root"             ask 'sudo -u root kubectl delete pod foo'
check "upper case read"          allow 'KUBECTL get pods'


echo "=== the bypasses that permission rules cannot express (expect: ask) ==="
check "plain delete"               ask  'kubectl delete pod foo -n vm'
check "verb-first delete, the spelling the retired deny rule covered" ask 'kubectl delete pod foo'
check "--namespace, not -n"        ask  'kubectl --namespace vm delete pod foo'
check "--context= equals form"     ask  'kubectl --context=example-prod delete pod foo'
check "--kubeconfig first"         ask  'kubectl --kubeconfig /tmp/kc delete pod foo'
check "-n then --context"          ask  'kubectl -n vm --context example-prod delete pod foo'
check "context+ns before delete"   ask  'kubectl --context example-prod -n vm delete deploy/api'

echo ""
echo "=== other destructive verbs, none of them covered by a delete deny (expect: ask) ==="
check "drain"        ask  'kubectl drain node-1 --ignore-daemonsets'
check "cordon"       ask  'kubectl cordon node-1'
check "scale to 0"   ask  'kubectl -n vm scale deploy/vmselect --replicas=0'
check "apply -f"     ask  'kubectl apply -f manifest.yaml'
check "patch"        ask  'kubectl -n vm patch deploy foo -p {}'
check "replace"      ask  'kubectl replace -f manifest.yaml'
check "edit"         ask  'kubectl -n vm edit deploy foo'
check "exec"         ask  'kubectl --context X -n vm exec -it pod/foo -- sh'
check "cp"           ask  'kubectl -n vm cp pod/foo:/etc/passwd /tmp/p'
check "run"          ask  'kubectl run tmp --image=curlimages/curl --rm -i --restart=Never'
check "debug"        ask  'kubectl debug -n vm pod/foo --image=busybox'
check "proxy"        ask  'kubectl proxy --port 8001'
check "taint"        ask  'kubectl taint nodes node-1 key=value:NoSchedule'
check "annotate"     ask  'kubectl -n vm annotate pod foo bar=baz'
check "label"        ask  'kubectl -n vm label pod foo bar=baz'
check "expose"       ask  'kubectl -n vm expose deploy foo --port 80'
check "autoscale"    ask  'kubectl -n vm autoscale deploy foo --max 5'
check "set image"    ask  'kubectl -n vm set image deploy/foo c=img:2'
check "certificate"  ask  'kubectl certificate approve csr-1'

echo ""
echo "=== subcommand-sensitive verbs ==="
check "rollout status is read"   allow 'kubectl -n vm rollout status deploy/foo'
check "rollout history is read"  allow 'kubectl rollout history deploy/foo -n vm'
check "rollout undo mutates"     ask    'kubectl -n vm rollout undo deploy/foo'
check "rollout restart mutates"  ask    'kubectl --context X -n vm rollout restart deploy/foo'
check "auth can-i is read"       allow 'kubectl auth can-i delete pods -n vm'
check "auth reconcile mutates"   ask    'kubectl auth reconcile -f rbac.yaml'
check "config view is read"      allow 'kubectl config view --minify'
check "config view --raw: tokens" ask   'kubectl config view --raw'
check "--raw with jsonpath"       ask   "kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}'"
check "--flatten embeds keys"     ask   'kubectl --context x config view --flatten'
check "--raw=false is redacted"   allow 'kubectl config view --raw=false'
check "config get-contexts read" allow 'kubectl config get-contexts -o name'
check "config use-context sets"  ask    'kubectl config use-context example-prod'

echo ""
echo "=== flag VALUES must not be read as the verb (expect: allow) ==="
check "context literally named delete-me" allow 'kubectl --context delete-me get pods -n vm'
check "-n value named delete"             allow 'kubectl -n delete get pods'
check "--user value named drain"          allow 'kubectl --user drain get svc'

echo ""
echo "=== runners, chains and paths still resolve the verb (expect: ask) ==="
check "sudo prefix"        ask  'sudo kubectl delete pod foo'
check "timeout prefix"     ask  'timeout 30 kubectl --context X drain node-1'
check "after tsh login"    ask  'tsh kube login example-prod >/dev/null 2>&1; kubectl -n vm delete pod foo'
check "absolute path"      ask  '/usr/local/bin/kubectl delete pod foo'
check "xargs"              ask  'echo foo | xargs kubectl delete pod'

echo ""
echo "=== get secret materialises credentials (expect: ask) ==="
check "get secret -o yaml"        ask   'kubectl get secret -o yaml -n vm'
check "get secrets plural"        ask   'kubectl --context example-prod get secrets -n default'
check "get secret jsonpath"       ask   'kubectl -n vm get secret db-creds -o jsonpath={.data}'
check "get svc is still a read"   allow 'kubectl -n vm get svc vmselect-vm'
check "get pods is still a read"  allow 'kubectl --context X -n vm get pods'
echo ""

echo "=== describe secret prints key names and annotations (expect: ask) ==="
check "describe secret name"      ask   'kubectl -n vm describe secret db-creds'
check "describe secrets plural"   ask   'kubectl --context example-prod describe secrets -n default'
check "describe secret/name"      ask   'kubectl describe secret/db-creds'
check "describe Secret, case"     ask   'kubectl describe Secret db-creds'
check "describe flags first"      ask   'kubectl describe -n vm secret db-creds'
check "describe pod is a read"    allow 'kubectl -n vm describe pod vmselect-vm-0'
check "describe CRD is a read"    allow 'kubectl describe secretproviderclass vault'
echo ""

echo "=== unknown / absent verbs ==="
check "unknown subcommand fails closed" ask    'kubectl frobnicate widgets'
check "bare kubectl"                    allow 'kubectl'
check "kubectl --help"                  allow 'kubectl --help'
check "no kubectl at all"               allow 'git status --short'
check "read-only chain, both sides"     allow 'kubectl -n vm get svc && kubectl -n vm get pods'
check "read then mutate in one chain"   ask    'kubectl -n vm get svc && kubectl -n vm delete pod foo'

echo ""
echo "=== Command substitution (expect: ask) ==="
# `$(` and a backtick glue onto the next word, so the first token was
# `"$(kubectl` — equal to neither `kubectl` nor */kubectl. Worse, the cheap
# bail-out required whitespace or a slash before `kubectl`, so these exited
# before the verb scan ran at all and were allowed silently.
check "substitution in echo"     ask   'echo "$(kubectl delete pod foo)"'
check "substitution in backticks" ask  'echo `kubectl delete pod foo`'
check "substitution in assignment" ask 'X=$(kubectl delete pod foo)'
check "substitution, backtick assign" ask 'OUT=`kubectl delete pod foo`'
check "substitution, read-only verb" allow 'X=$(kubectl get pods -n vm)'

echo ""
echo "=== Assignment and wrapper prefixes (expect: ask) ==="
check "VAR= prefix"              ask   'CTX=abc kubectl delete pod foo -n vm'
check "assignment with \$HOME"    ask   'PATH=$HOME/bin kubectl delete pod foo'
check "timeout prefix"           ask   'timeout 60 kubectl delete pod foo'
check "nohup prefix"             ask   'nohup kubectl delete pod foo'
check "quoted binary"            ask   "'kubectl' delete pod foo"

echo ""
echo "=== Reads stay silent after normalisation (expect: allow) ==="
check "port-forward"             allow 'kubectl port-forward svc/vmselect-vm 8481:8481 -n vm'
check "context flag first"       allow 'kubectl --context teleport.example-prod get svc -A'
check "no kubectl, has a \$("     allow 'echo "$(date +%s)"'

echo ""
echo "=== secret spellings that went silent — #C (expect: ask) ==="
# The check took the next bare token after `get` and compared it to the two
# literals `secret` and `secrets`. Every spelling below dumps the same data
# and matched neither, so it rode the Bash(kubectl:*) allow entry with no
# guard opinion at all.
check "resource/name form"       ask   'kubectl -n vm get secret/db-creds -o yaml'
check "quoted resource/name"     ask   "kubectl -n vm get 'secret/db-creds' -o yaml"
check "comma-joined kinds"       ask   'kubectl get pods,secrets -A -o yaml'
check "comma list, secret first" ask   'kubectl get secrets,configmaps -A -o yaml'
check "capitalised kind"         ask   'kubectl get Secret -n vm -o json'
check "upper-case plural"        ask   'kubectl get SECRETS -A'
check "group-qualified kind"     ask   'kubectl get secrets.v1. -o yaml'
check "group-qualified + name"   ask   'kubectl get secret.v1.core/db-creds -o yaml'
check "raw API path"             ask   'kubectl get --raw /api/v1/namespaces/vm/secrets'
check "raw API path, one secret" ask   'kubectl get --raw /api/v1/namespaces/vm/secrets/db-creds'
check "raw API path, =form"      ask   'kubectl get --raw=/api/v1/namespaces/vm/secrets'
check "raw path in a chain"      ask   'kubectl get pods -n vm && kubectl get --raw /api/v1/secrets'

echo ""
echo "=== Kinds that merely start with 'secret' are still reads (expect: allow) ==="
# The widened match splits on / . and , and lower-cases — it must not swallow
# a CRD whose name happens to begin with the word.
check "secretproviderclass"      allow 'kubectl get secretproviderclass -n vm'
check "sealedsecrets CRD"        allow 'kubectl get sealedsecrets -n vm'
check "externalsecrets CRD"      allow 'kubectl get externalsecrets.external-secrets.io -n vm'
check "comma list, no secret"    allow 'kubectl get pods,svc,deploy -A'
check "resource/name, not secret" allow 'kubectl get po/web-0 -o yaml'
check "raw path, pods"           allow 'kubectl get --raw /api/v1/namespaces/vm/pods'
check "raw path, CRD"            allow 'kubectl get --raw /apis/x/v1/secretproviderclasses'

echo ""
echo "=== The kind after a flag is still the kind (expect: ask) ==="
# Only the first bare token after `get` was compared, so a format value read
# as the resource and the real kind behind it went unchecked.
check "-o value before kind"     ask   'kubectl get -o yaml secret'
check "-o value, kind and name"  ask   'kubectl get -o yaml secret db'
check "--output value first"     ask   'kubectl get --output json secrets -n vm'
check "-l value first"           ask   'kubectl get -l app=db secret'

echo ""
echo "=== Flag values that only look like a kind are not one (expect: allow) ==="
check "-o before pods"           allow 'kubectl get -o yaml pods'
check "label value secret"       allow 'kubectl get pods -l tier=secret'
check "namespace named secrets"  allow 'kubectl get pods -n secrets'

echo ""
echo "=== mutating verbs are asked about AS mutating, not as unknown ==="
# Both paths answer "ask", so a decision check alone stays green if a verb falls
# off MUTATING_VERBS. The reason says which path ran. Listed here, not read from
# the hook, so the test cannot agree with a list it is meant to check.
for v in delete apply create replace patch edit scale drain cordon cp; do   # exec: own branch, own tests below
  r=$(jq -nc --arg c "kubectl $v pod foo -n vm" '{tool_name:"Bash", tool_input:{command:$c}}' \
      | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  case "$r" in
    *"mutates the cluster"*) echo "  OK (reason): $v is named as mutating"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL (reason): $v is named as mutating  [got: $r]"; FAIL=$((FAIL+1)) ;;
  esac
done

echo ""
echo "=== kubectl exec: read-only probes run, anything else asks ==="
check "exec -- ls"                  allow 'kubectl exec api-7d9 -- ls -la /app'
check "exec -c app -- /bin/ls"      allow 'kubectl -n web exec api-7d9 -c app -- /bin/ls /etc'
check "exec -- hostname"            allow 'kubectl --context prod exec api-7d9 -- hostname'
check "exec -- java -version"       allow 'kubectl exec api-7d9 -- java -version'
check "exec -- python --version"    allow 'kubectl exec api-7d9 -- python3 --version'
check "exec -- ls | grep"           allow 'kubectl exec api-7d9 -- ls /app | grep jar'
check "exec -- cat a secret"        ask   'kubectl exec api-7d9 -- cat /var/run/secrets/kubernetes.io/serviceaccount/token'
check "exec -- env"                 ask   'kubectl exec api-7d9 -- env'
check "exec -- printenv"            ask   'kubectl exec api-7d9 -- printenv DB_PASSWORD'
check "exec -- ps"                  ask   'kubectl exec api-7d9 -- ps aux'
check "exec -- sh -c"               ask   "kubectl exec api-7d9 -- sh -c 'ls'"
check "exec -it -- ls"              ask   'kubectl exec -it api-7d9 -- ls'
check "exec --stdin -- ls"          ask   'kubectl exec --stdin api-7d9 -- ls'
check "exec, no -- (old form)"      ask   'kubectl exec api-7d9 ls'
check "exec -- python -c"           ask   "kubectl exec api-7d9 -- python3 -c 'print(1)'"
check "exec -- ls, then a delete"   ask   'kubectl exec api-7d9 -- ls && kubectl delete pod api-7d9'
check "exec -- version and a file"  ask   'kubectl exec api-7d9 -- java --version /etc/passwd'

echo ""
echo "=== kubectl as text in a PR title or commit message (expect: allow) ==="
check "gh pr title"              allow 'gh pr create --title "kubectl reason checks" --body-file notes.md'
check "git commit -m"            allow "git commit -m 'note the kubectl delete step'"
check "git stash push -m"        allow "git stash push -m 'kubectl delete wip' -- a.sh"
check "git commit -F heredoc"    allow $'git commit -q -F - <<\'EOF\'\nkubectl delete pod x is documented\nEOF'
check "git bisect run"           ask   'git bisect run kubectl delete pod x'
check "git rebase -x"            ask   'git rebase -x "kubectl delete pod x" main'
check "gh, then a real delete"   ask   'gh pr view 1 && kubectl delete pod x'

echo ""
echo "=== The raw pre-filter: spellings that dodge a naive word test still ask ==="
check "upper-case binary"        ask   'KUBECTL delete pod x'
check "quotes split the word"    ask   '"kub""ectl" delete pod x'
check "backslash in the word"    ask   '\kubectl delete pod x'
check "nothing it guards"        allow 'ls -la && npm test'

echo ""
echo "=== Text and paths name kubectl without running it (expect: allow) ==="
# A quoted `|` split the grep pattern into a segment headed by kubectl, and one
# non-text command anywhere in the line made every grep pattern a command.
check "alternation names kubectl delete" allow "git show origin/some-branch:README.md | grep -nE 'git-guard|kubectl-guard|kubectl delete|subprocess' | head -60"
check "git grep alternation after echo"  allow "echo \"--- tests ---\" && git grep -nE 'kubectl delete:|kubectl \\* delete|retired-rules' origin/some-branch -- tests/ install.sh"
check "alternation piped to cut"         allow "git show origin/some-branch:README.md | grep -nE 'permissions\\.deny|kubectl delete|retired' | cut -c1-400"
check "sed, then a grep pattern"         allow 'sed -n 1,60p tests/kubectl-guard.test.sh; grep -n "kubectl" config/settings.json; head -30 hooks/kubectl-guard.sh'
check "make, then a grep pattern"        allow 'make test; grep -n "kubectl" config/settings.json'
check "npm test, then rg"                allow "npm test && rg 'kubectl delete' docs/"
check "rg pattern"                       allow "rg 'kubectl delete' docs/"
check "grep -rn pattern"                 allow 'grep -rn "kubectl apply" .'
check "cat the guard"                    allow 'cat hooks/kubectl-guard.sh'
check "cat a path ending in kubectl"     allow 'cat ./kubectl ./other'
check "alternation inside parentheses"   allow "grep -E '(a|kubectl delete)' x"
check "kubectl get piped to a pattern"   allow "kubectl get pods | grep -E 'Running|kubectl delete'"
check "commit message with a ;"          allow "git commit -m 'note; kubectl delete pod x'"
check "text written to a notes file"     allow "grep -rn 'kubectl delete' . > hits.txt"
check "echo to /dev/null, then make"     allow 'echo kubectl delete pod x >/dev/null 2>&1; make'

echo ""
echo "=== ...but kubectl run any other way still asks (expect: ask) ==="
check "absolute path"                    ask   '/usr/bin/kubectl delete pod x'
check "double-quoted binary"             ask   '"kubectl" delete pod x'
check "a quoted | in a flag value"       ask   "kubectl --context 'a|b' delete pod x"
check "echo piped to bash"               ask   'echo kubectl delete pod x | bash'
check "quoted | piped to bash"           ask   "echo 'a|kubectl delete pod x' | bash"
check "piped to bash with |&"            ask   'echo kubectl delete pod x |& bash'
check "bash -c"                          ask   "bash -c 'kubectl delete pod x'"
check "sh -c"                            ask   'sh -c "kubectl delete pod x"'
check "bash -c, a ; inside"              ask   "bash -c 'kubectl get pods; kubectl delete pod x'"
check "bash -c, \\kubectl after ;"       ask   "bash -c 'true;\\kubectl delete pod x'"
check "bash -c, KUBECTL after ;"         ask   "bash -c 'true;KUBECTL delete pod x'"
check "xargs, no target"                 ask   'xargs kubectl delete'
check "find -exec"                       ask   'find . -exec kubectl delete {} \;'
check "watch"                            ask   'watch kubectl delete pod x'
check "git rebase -x, single quotes"     ask   "git rebase -x 'kubectl delete'"
check "sed, then a real delete"          ask   "sed 's/x/y/' f; kubectl delete pod x"
check "make, then a real delete"         ask   'make test; kubectl delete pod x'
check "substitution, bash -c inside"     ask   "echo \"\$(bash -c 'kubectl delete pod x')\""
check "substitution, ; inside quotes"    ask   'echo "$(echo hi; kubectl delete pod foo)"'
check "eval of a substitution"           ask   'eval $(echo; echo kubectl delete pod x)'
check "brace group piped to bash"        ask   '{ echo kubectl delete pod x; } | bash'
check "subshell piped to bash"           ask   '(echo kubectl delete pod x) | bash'
check "if piped to bash"                 ask   'if true; then echo kubectl delete pod x; fi | bash'
check "if body, second command"          ask   'if true; then echo a; echo kubectl delete pod x; fi | bash'
check "loop body piped to bash"          ask   'for i in 1; do echo a; echo kubectl delete pod x; done | bash'
check "multi-line if piped to bash"      ask   $'if true; then\necho kubectl delete pod x\nfi | bash'
check "| continues on the next line"     ask   $'echo kubectl delete pod x |\nbash'
check "\\ continues the line"            ask   $'echo kubectl delete pod x \\\n| bash'
check "written to a script, then run"    ask   "echo 'kubectl delete pod x' > x.sh; bash x.sh"
check "sort -o a script, then run"       ask   "echo 'kubectl delete pod x' | sort -o x.sh; bash x.sh"
check "printf -v, then run"              ask   "printf -v c 'kubectl delete pod x'; \$c"
check "heredoc apostrophe, then a ;"     ask   $'cat <<\'EOF\' > notes.txt\necho don\'t\nEOF\ngrep x y; kubectl delete pod x'

echo ""
echo "=== A text command that stores text for a later command keeps it scanned ==="
# uniq takes [INPUT [OUTPUT]]; the writer check knew only >, -o and printf -v.
check "uniq OUTPUT operand, then sh"     ask   "echo 'kubectl delete pod y' | uniq - out.sh; sh out.sh"
check "uniq OUTPUT operand, && bash"     ask   "echo 'kubectl delete pod y' | uniq - out.sh && bash out.sh"
check "grep | uniq OUTPUT, then bash"    ask   'grep kubectl in.txt | uniq - out.sh; bash out.sh'
check "uniq -u, OUTPUT operand"          ask   'grep kubectl in | uniq -u - out.sh; sh out.sh'
check "uniq -f value, OUTPUT operand"    ask   "echo 'kubectl delete pod x' | uniq -f 1 - out.sh; sh out.sh"
check "sort -uo, bundled"                ask   "echo 'kubectl delete pod x' | sort -uo x.sh; bash x.sh"
check "sort --out=, abbreviated"         ask   "echo 'kubectl delete pod x' | sort --out=x.sh; bash x.sh"
check "less -O log file"                 ask   "echo 'kubectl delete pod x' | less -O x.sh; bash x.sh"
check "less --log-file"                  ask   "echo 'kubectl delete pod x' | less --log-file=x.sh; bash x.sh"
check "commit message read back"         ask   "git commit -qm 'kubectl delete pod x'; git log -1 --format=%s | bash"
check "git note read back"               ask   "git notes add -m 'kubectl delete pod x'; git notes show | sh"
check "gh comment read back"             ask   "gh pr comment 1 --body 'kubectl delete pod x'; gh pr view 1 --json comments -q '.comments[0].body' | bash"
check "uniq, INPUT only"                 allow "grep -h 'kubectl delete' x | uniq a.txt; make"
check "grep | uniq, no operand"          allow "grep -h 'kubectl delete' a.txt | uniq; make"
check "uniq -f value is not an operand"  allow "grep -h 'kubectl delete' a.txt | uniq -f 1 -; make"
check "grep -o is not an output file"    allow "grep -o 'kubectl delete' a.txt; make"

echo ""
echo "=== kubectl, its verb or its kind through a variable, a substitution or xargs ==="
# Each allowed on main: the scan knew kubectl only as a word on the line.
check "k=kubectl; \"\$k\" delete"         ask   'k=kubectl; "$k" delete pod x'
check "KUBECTL=kubectl; \$KUBECTL"        ask   'KUBECTL=kubectl; $KUBECTL delete pod x'
check "export, \${K}"                     ask   'export K=kubectl; ${K} delete pod x'
check "\$(echo kubectl) delete"           ask   '$(echo kubectl) delete pod x'
check "backtick which kubectl"            ask   '`which kubectl` delete pod x'
check "value via \$(which), then run"     ask   'K=$(which kubectl); $K delete pod x'
check "eval of a variable"                ask   "x='kubectl delete pod x'; eval \"\$x\""
check "eval of an ANSI-C value"           ask   "x=\$'kubectl delete pod x'; eval \"\$x\""
check "variable run bare"                 ask   'x="kubectl delete pod x"; $x'
check "variable to bash -c"               ask   "x='kubectl delete pod x'; bash -c \"\$x\""
check "variable naming a variable"        ask   'a=kubectl; b="$a delete"; $b pod x'
check "\${KUBECTL:-kubectl} delete"       ask   '${KUBECTL:-kubectl} delete pod x'
check "for k in kubectl"                  ask   'for k in kubectl; do "$k" delete pod x; done'
check "two values, one runs"              ask   'k=kubectl; k="kubectl --context prod"; $k delete pod x'
check "kind in a variable"                ask   'kind=secrets; kubectl get $kind -o yaml'
check "kinds in a loop"                   ask   'for r in pods secrets; do kubectl get $r; done'
check "kind from outside the command"     ask   'kubectl get "$KIND"'
check "verb from a substitution"          ask   'kubectl $(cat verb.txt) pod x'
check "verb after a quoted -n \$(…)"      ask   'kubectl -n "$(cat ns)" delete pod x'
check "verb after --context=\"\$(…)\""    ask   'kubectl --context="$(cat ctx)" delete pod x'
check "delete inside a flag value"        ask   'kubectl --context "$(kubectl delete ns y)" get pods'
check "loop value, then delete"           ask   'for ns in a b; do kubectl -n $ns delete pod x; done'
check "xargs supplies the verb"           ask   'echo delete pod x | xargs kubectl'
check "xargs -n1, flags only"             ask   'cat names | xargs -n1 kubectl --context prod'
check "xargs supplies get's kind"         ask   'echo secrets | xargs kubectl get'
check "xargs -I{} as get's kind"          ask   'echo secrets | xargs -I{} kubectl get {}'
check "xargs -I@ as get's kind"           ask   'echo secrets | xargs -I@ kubectl get @'
check "xargs -I @, separate"              ask   'echo secrets | xargs -I @ kubectl get @'
check "parallel supplies the verb"        ask   'echo delete | parallel kubectl'
check "quoted \$(kubectl get secrets)"    ask   'echo "$(kubectl get secrets)"'
check "k=kubectl; \"\$k\" get"            allow 'k=kubectl; "$k" get pods'
check "variable only echoed"              allow 'K=kubectl; echo "$K delete"'
check "\$(which kubectl) get"             allow '$(which kubectl) get pods'
check "\$(command -v kubectl) version"    allow '"$(command -v kubectl)" version'
check "\${KUBECTL:-kubectl} get"          allow '${KUBECTL:-kubectl} get pods -A'
check "loop over namespaces, a read"      allow 'for ns in a b; do kubectl -n "$ns" get pods; done'
check "loop over kinds, all reads"        allow 'for r in pods svc; do kubectl get $r; done'
check "comma in one value"                allow 'x="kubectl get pods,svc"; $x'
check "quoted -n \$(…), a read"           allow 'kubectl -n "$(cat ns)" get pods'
check "--context=\"\$(…)\", a read"       allow 'kubectl --context="$(cat ctx)" get pods'
check "quoted current-context value"      allow 'kubectl --context "$(kubectl config current-context)" get pods'
check "quoted current-context"            allow 'CTX="$(kubectl config current-context)"'
check "xargs grep names kubectl"          allow 'git ls-files | xargs grep -l kubectl'
check "xargs kubectl get pods"            allow 'echo api-0 | xargs kubectl get pods'
check "xargs kubectl describe"            allow 'kubectl get pods -o name | xargs -n1 kubectl describe'
check "xargs kubectl in a grep pattern"   allow 'grep -rn "xargs kubectl" docs/'
check "pattern in a variable, grepped"    allow "pattern='kubectl delete'; grep -rn \"\$pattern\" ."
check "logs of a substituted pod"         allow 'kubectl logs $(kubectl get pods -o name | head -1)'
check "-n from the environment"           allow 'kubectl get pods -n $NS'

echo ""
echo "=== Review of the above: flag values, get's flags, arrays, loops, xargs sources ==="
# An unquoted `)` reaches the scan as `;` (lib.sh's separate_groups).
check "unquoted -n \$(…), then delete"    ask   'kubectl -n $(cat ns) delete pod x'
check "unquoted --context=\$(…), delete"  ask   'kubectl --context=$(cat ctx) delete pod x'
check "unquoted -n \$(…), get secrets"    ask   'kubectl -n $(cat ns) get secrets'
check "unquoted -n \$(…), a read"         allow 'kubectl -n $(cat ns) get pods'
check "xargs get, -o yaml before kind"   ask   'cat names | xargs -n1 kubectl get -o yaml'
check "get -o yaml \$KIND"                ask   'kubectl get -o yaml $KIND'
check "assignment then ; with no space"  ask   'X=1;kubectl delete pod x'
check "k=kubectl;\$k, no space"           ask   'k=kubectl;$k delete pod x'
check "array run as a command"           ask   'cmd=(kubectl delete pod x); "${cmd[@]}"'
check "array of kinds"                   ask   'kinds=(pods secrets); kubectl get "${kinds[@]}"'
check "K=\${K:-kubectl}, then delete"     ask   'KUBECTL=${KUBECTL:-kubectl}; $KUBECTL delete pod x'
check "K=\${K:-kubectl}, a read"          allow 'KUBECTL=${KUBECTL:-kubectl}; $KUBECTL get pods'
check "loop over a piped \$(…) list"      allow 'for ns in $(kubectl get ns -o name | cut -d/ -f2); do kubectl get pods -n $ns; done'
check "loop values only echoed"          allow 'for p in $(kubectl get pods -n a -o name); do echo "$p"; done; for p in $(kubectl get pods -n b -o name); do echo "$p"; done'
check "| xargs kubectl in a message"     allow 'git commit -m "fix: pipe pod names | xargs kubectl"'
check "xargs fed by get pods -o name"    allow 'kubectl get pods -o name | xargs -I{} kubectl get {} -o yaml'
check "xargs, pod/{}"                    allow 'kubectl get pods -o name | xargs -I{} kubectl get pod/{} -o wide'
check "loop over get pods -o name"       allow 'for p in $(kubectl get pods -o name); do kubectl get $p -o yaml; done'
check "xargs fed by get secrets -o name" ask   'kubectl get secrets -o name | xargs -I{} kubectl get {} -o yaml'
check "loop over get secrets -o name"    ask   'for s in $(kubectl get secrets -o name); do kubectl get $s -o yaml; done'
check "loop over api-resources"          ask   'for r in $(kubectl api-resources -o name); do kubectl get $r -A; done'
check "while read, kind unknown"         ask   'kubectl get pods -o name | while read p; do kubectl get $p -o yaml; done'
# Second review.
check "K=\${K:-\$(which kubectl)}, delete" ask  'KUBECTL=${KUBECTL:-$(which kubectl)}; $KUBECTL delete pod x'
check "array grown with +="              ask   'cmd=(kubectl); cmd+=(delete pod x); "${cmd[@]}"'
check "array grown with +=, a read"      allow 'cmd=(kubectl); cmd+=(get pods); "${cmd[@]}"'
check "piped list, loop var before verb" allow 'for ns in $(kubectl get ns -o name | cut -d/ -f2); do kubectl -n $ns get pods; done'
check "grep between -o name and xargs"   allow 'kubectl get pods -o name | grep web | xargs -I{} kubectl get {} -o yaml'
check "grep inside the loop's list"      allow 'for p in $(kubectl get pods -o name | grep web); do kubectl get $p -o yaml; done'
check "sed rewrites the names"           ask   'kubectl get pods -o name | sed s/pod/secret/ | xargs -I{} kubectl get {} -o yaml'

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
