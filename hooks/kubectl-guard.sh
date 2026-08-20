#!/usr/bin/env bash
# kubectl escalation guard.
#
# Fires on: PreToolUse → Bash.
#
# Why this exists: Bash permission rules are prefix-matched on the literal
# command string, and kubectl takes its global flags BEFORE the verb. So a
# verb-scoped rule never matches a real invocation — `Bash(kubectl get:*)`
# misses `kubectl --context X -n vm get svc`. That cuts both ways: a
# `Bash(kubectl delete:*)` in *deny* misses `kubectl --namespace vm delete pod`
# just as reliably, so "allow kubectl broadly, deny the dangerous verbs" cannot
# be expressed in settings.json at all.
#
# This hook sees the whole command string, so it finds the verb wherever it
# sits. Policy:
#   • read-only verb (get/describe/logs/…)   → silent allow
#   • `get secret`                           → ask (credential materialisation)
#   • mutating verb (delete/apply/drain/…)   → ask
#   • verb absent (bare `kubectl`, --help)   → silent allow (does nothing)
#   • anything it cannot classify            → ask (fail closed)
#
# ASK, not DENY, and the distinction matters. Claude Code's auto-mode classifier
# already ships ~10 kubectl-specific soft_deny rules (Shared Cluster Mutation,
# Interfere With Workloads, Node Lifecycle Operations, Protected-Scope IaC Apply,
# Remote Shell Writes, Sensitive Remote Exec, Production Reads, Credential
# Materialization, …). Those are far more nuanced than a verb list: they clear
# when the user named the specific target, and block when the agent picked it.
# A hook `deny` runs BEFORE the permission system and would preempt every one of
# them — a wall instead of a reviewable decision. Escalating to `ask` hands the
# command to those rules with the verb named in the reason.
#
# The silent-allow path is what the `Bash(kubectl:*)` allow entry buys: reads
# stay quiet, everything else is escalated here. Unknown verbs ask, so a verb
# missing from the lists below fails closed rather than riding the allow entry.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

# Cheap bail-out: no kubectl anywhere, nothing to do.
printf '%s\n' "$CMD" | grep -qE '(^|[[:space:]/])kubectl([[:space:]]|$)' || exit 0

# Global flags that consume the NEXT token as their value. Without this,
# `kubectl --context delete-me get pods` would read "delete-me" as the verb.
# Flags in --flag=value form are self-contained and need no entry here.
VALUE_FLAGS=(
  -n --namespace --context --kubeconfig --cluster --user --as --as-group
  --as-uid --token --server -s --cache-dir --certificate-authority
  --client-certificate --client-key --request-timeout --tls-server-name
  --password --username --log-flush-frequency -v --v --profile --profile-output
  --chunk-size --field-manager
)

is_value_flag() {
  local t="$1" f
  for f in "${VALUE_FLAGS[@]}"; do
    [[ "$t" = "$f" ]] && return 0
  done
  return 1
}

# Verbs that only read. Anything not listed is mutating or unknown, and both
# escalate — the list is the allowlist, deliberately.
READONLY_VERBS=(
  get describe logs top explain api-resources api-versions version
  cluster-info events wait diff kustomize port-forward completion
  options help
)

# Verbs that change cluster or local state.
MUTATING_VERBS=(
  delete apply create replace patch edit scale autoscale expose set
  label annotate taint drain cordon uncordon run exec attach cp debug
  evict proxy certificate import
)

# Verbs whose safety depends on their SUBcommand; the read-only ones are listed.
SUBVERB_READONLY_rollout=(status history)
SUBVERB_READONLY_auth=(can-i)
SUBVERB_READONLY_config=(view current-context get-contexts get-clusters get-users)

in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" = "$needle" ]] && return 0
  done
  return 1
}

# Shell operators that end a command; a kubectl parse stops here.
is_operator() {
  case "$1" in
    '|'|'||'|'&&'|';'|'&'|'>'|'>>'|'<'|'<<') return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the next bare (non-flag) token at or after index $1, skipping global
# flags and the values they consume. Empty if the command ends first.
next_bare_token() {
  local k="$1" t
  while (( k < n )); do
    t="${TOKENS[$k]}"
    if is_operator "$t"; then
      return 0
    elif [[ "$t" == -* ]]; then
      if [[ "$t" != *=* ]] && is_value_flag "$t"; then (( k += 2 )); else (( k++ )); fi
    else
      printf '%s' "$t"
      return 0
    fi
  done
}

# Tokenize on whitespace. Quoting is not honoured, deliberately: a quoted flag
# value that splits into several tokens yields an unrecognised verb, which
# escalates. Failing closed on ambiguity is the intended behaviour.
read -ra TOKENS <<<"$CMD"

i=0
n=${#TOKENS[@]}
while (( i < n )); do
  tok="${TOKENS[$i]}"
  # Match `kubectl` and any path ending in /kubectl.
  if [[ "$tok" = "kubectl" || "$tok" = */kubectl ]]; then
    (( i++ ))
    verb=$(next_bare_token "$i")

    # Bare `kubectl` with no verb does nothing but print help.
    [[ -z "$verb" ]] && continue

    # Advance past the verb so the subcommand lookup starts after it.
    while (( i < n )) && [[ "${TOKENS[$i]}" != "$verb" ]]; do (( i++ )); done
    (( i++ ))

    case "$verb" in
      get)
        # `kubectl get secret -o yaml` materialises live credentials into the
        # transcript and debug logs. Every other `get` is an ordinary read.
        sub=$(next_bare_token "$i")
        case "$sub" in
          secret|secrets)
            emit_ask "kubectl get $sub reads live credentials into the transcript. Confirm this is intended and scoped to the secret you need."
            exit 0
            ;;
        esac
        continue
        ;;
      rollout|auth|config)
        sub=$(next_bare_token "$i")
        case "$verb" in
          rollout) in_list "$sub" "${SUBVERB_READONLY_rollout[@]}" && continue ;;
          auth)    in_list "$sub" "${SUBVERB_READONLY_auth[@]}"    && continue ;;
          config)  in_list "$sub" "${SUBVERB_READONLY_config[@]}"  && continue ;;
        esac
        emit_ask "kubectl $verb ${sub:-<subcommand>} changes cluster or kubeconfig state. Name the target context/namespace and the specific change."
        exit 0
        ;;
    esac

    if in_list "$verb" "${READONLY_VERBS[@]}"; then
      continue
    fi

    if in_list "$verb" "${MUTATING_VERBS[@]}"; then
      emit_ask "kubectl $verb mutates the cluster. Name the specific target (context, namespace, resource) — a permission rule cannot gate this verb, because kubectl takes its global flags before the verb."
      exit 0
    fi

    emit_ask "kubectl subcommand '$verb' is not on the read-only list, so it is treated as potentially mutating. Confirm before running."
    exit 0
  fi
  (( i++ ))
done

exit 0
