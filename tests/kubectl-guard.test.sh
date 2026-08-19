#!/usr/bin/env bash
# Tests for kubectl-guard.sh
set -u
HOOK="hooks/kubectl-guard.sh"
PASS=0; FAIL=0

check() {
  local label="$1" expect="$2" cmd="$3"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
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

echo "=== read-only verbs, flags BEFORE the verb (expect: allow) ==="
check "get svc, context+ns first"  allow 'kubectl --context teleport.prod-prodn1 -n vm get svc vmselect-vm'
check "get pods -A"                allow 'kubectl get pods -A'
check "describe with ns first"     allow 'kubectl -n vm describe pod vmselect-vm-0'
check "logs"                       allow 'kubectl --context X -n vm logs deploy/foo --tail 100'
check "top"                        allow 'kubectl top pods -n vm'
check "port-forward (vm-query path)" allow 'kubectl --context X port-forward -n vm svc/vmselect-vm 18481:8481'
check "version"                    allow 'kubectl version --client'
check "api-resources"              allow 'kubectl api-resources'
check "cluster-info"               allow 'kubectl cluster-info'
check "wait"                       allow 'kubectl wait --for=condition=Ready pod/foo -n vm'
check "label selector says delete" allow 'kubectl get pods -n vm -l app=delete'

echo ""
echo "=== the bypasses that permission rules cannot express (expect: deny) ==="
check "plain delete"               deny 'kubectl delete pod foo -n vm'
check "--namespace, not -n"        deny 'kubectl --namespace vm delete pod foo'
check "--context= equals form"     deny 'kubectl --context=prodn1 delete pod foo'
check "--kubeconfig first"         deny 'kubectl --kubeconfig /tmp/kc delete pod foo'
check "-n then --context"          deny 'kubectl -n vm --context prodn1 delete pod foo'
check "context+ns before delete"   deny 'kubectl --context prodn1 -n vm delete deploy/incident-builder'

echo ""
echo "=== other destructive verbs, none of them covered by a delete deny (expect: deny) ==="
check "drain"        deny 'kubectl drain node-1 --ignore-daemonsets'
check "cordon"       deny 'kubectl cordon node-1'
check "scale to 0"   deny 'kubectl -n vm scale deploy/vmselect --replicas=0'
check "apply -f"     deny 'kubectl apply -f manifest.yaml'
check "patch"        deny 'kubectl -n vm patch deploy foo -p {}'
check "replace"      deny 'kubectl replace -f manifest.yaml'
check "edit"         deny 'kubectl -n vm edit deploy foo'
check "exec"         deny 'kubectl --context X -n vm exec -it pod/foo -- sh'
check "cp"           deny 'kubectl -n vm cp pod/foo:/etc/passwd /tmp/p'
check "run"          deny 'kubectl run tmp --image=curlimages/curl --rm -i --restart=Never'
check "debug"        deny 'kubectl debug -n vm pod/foo --image=busybox'
check "proxy"        deny 'kubectl proxy --port 8001'
check "taint"        deny 'kubectl taint nodes node-1 key=value:NoSchedule'
check "annotate"     deny 'kubectl -n vm annotate pod foo bar=baz'
check "label"        deny 'kubectl -n vm label pod foo bar=baz'
check "expose"       deny 'kubectl -n vm expose deploy foo --port 80'
check "autoscale"    deny 'kubectl -n vm autoscale deploy foo --max 5'
check "set image"    deny 'kubectl -n vm set image deploy/foo c=img:2'
check "certificate"  deny 'kubectl certificate approve csr-1'

echo ""
echo "=== subcommand-sensitive verbs ==="
check "rollout status is read"   allow 'kubectl -n vm rollout status deploy/foo'
check "rollout history is read"  allow 'kubectl rollout history deploy/foo -n vm'
check "rollout undo mutates"     deny   'kubectl -n vm rollout undo deploy/foo'
check "rollout restart mutates"  deny   'kubectl --context X -n vm rollout restart deploy/foo'
check "auth can-i is read"       allow 'kubectl auth can-i delete pods -n vm'
check "auth reconcile mutates"   deny   'kubectl auth reconcile -f rbac.yaml'
check "config view is read"      allow 'kubectl config view --minify'
check "config get-contexts read" allow 'kubectl config get-contexts -o name'
check "config use-context sets"  deny   'kubectl config use-context prodn1'

echo ""
echo "=== flag VALUES must not be read as the verb (expect: allow) ==="
check "context literally named delete-me" allow 'kubectl --context delete-me get pods -n vm'
check "-n value named delete"             allow 'kubectl -n delete get pods'
check "--user value named drain"          allow 'kubectl --user drain get svc'

echo ""
echo "=== runners, chains and paths still resolve the verb (expect: deny) ==="
check "sudo prefix"        deny 'sudo kubectl delete pod foo'
check "timeout prefix"     deny 'timeout 30 kubectl --context X drain node-1'
check "after tsh login"    deny 'tsh kube login prod-prodn1 >/dev/null 2>&1; kubectl -n vm delete pod foo'
check "absolute path"      deny '/usr/local/bin/kubectl delete pod foo'
check "xargs"              deny 'echo foo | xargs kubectl delete pod'

echo ""
echo "=== unknown / absent verbs ==="
check "unknown subcommand fails closed" ask    'kubectl frobnicate widgets'
check "bare kubectl"                    allow 'kubectl'
check "kubectl --help"                  allow 'kubectl --help'
check "no kubectl at all"               allow 'git status --short'
check "read-only chain, both sides"     allow 'kubectl -n vm get svc && kubectl -n vm get pods'
check "read then mutate in one chain"   deny   'kubectl -n vm get svc && kubectl -n vm delete pod foo'

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
