#!/usr/bin/env bash
# Tests for kubectl-guard.sh
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
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
check "get svc, context+ns first"  allow 'kubectl --context teleport.prod-prodn1 -n vm get svc vmselect-vm'
check "get pods -A"                allow 'kubectl get pods -A'
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
echo "=== the bypasses that permission rules cannot express (expect: ask) ==="
check "plain delete"               ask  'kubectl delete pod foo -n vm'
check "--namespace, not -n"        ask  'kubectl --namespace vm delete pod foo'
check "--context= equals form"     ask  'kubectl --context=prodn1 delete pod foo'
check "--kubeconfig first"         ask  'kubectl --kubeconfig /tmp/kc delete pod foo'
check "-n then --context"          ask  'kubectl -n vm --context prodn1 delete pod foo'
check "context+ns before delete"   ask  'kubectl --context prodn1 -n vm delete deploy/incident-builder'

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
check "config get-contexts read" allow 'kubectl config get-contexts -o name'
check "config use-context sets"  ask    'kubectl config use-context prodn1'

echo ""
echo "=== flag VALUES must not be read as the verb (expect: allow) ==="
check "context literally named delete-me" allow 'kubectl --context delete-me get pods -n vm'
check "-n value named delete"             allow 'kubectl -n delete get pods'
check "--user value named drain"          allow 'kubectl --user drain get svc'

echo ""
echo "=== runners, chains and paths still resolve the verb (expect: ask) ==="
check "sudo prefix"        ask  'sudo kubectl delete pod foo'
check "timeout prefix"     ask  'timeout 30 kubectl --context X drain node-1'
check "after tsh login"    ask  'tsh kube login prod-prodn1 >/dev/null 2>&1; kubectl -n vm delete pod foo'
check "absolute path"      ask  '/usr/local/bin/kubectl delete pod foo'
check "xargs"              ask  'echo foo | xargs kubectl delete pod'

echo ""
echo "=== get secret materialises credentials (expect: ask) ==="
check "get secret -o yaml"        ask   'kubectl get secret -o yaml -n vm'
check "get secrets plural"        ask   'kubectl --context prodn1 get secrets -n default'
check "get secret jsonpath"       ask   'kubectl -n vm get secret db-creds -o jsonpath={.data}'
check "get svc is still a read"   allow 'kubectl -n vm get svc vmselect-vm'
check "get pods is still a read"  allow 'kubectl --context X -n vm get pods'
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
check "context flag first"       allow 'kubectl --context teleport.prod-prodn1 get svc -A'
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
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
