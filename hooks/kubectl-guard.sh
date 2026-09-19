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

# Normalise BEFORE the bail-out, not after. The bail-out's own pattern requires
# whitespace or a slash in front of `kubectl`, and `$(` is neither — so
# `echo "$(kubectl delete pod foo)"` exited here and was allowed silently, no
# matter what the scan below did. See the tokenizer note further down.
SCAN=$(normalize_wrappers "$CMD" | sed -E 's/\$\(/ /g; s/`/ /g')

# Cheap bail-out: no kubectl anywhere, nothing to do.
# Both sides use "not a word character" rather than "whitespace": a quote can
# sit on either side (`'kubectl' delete …`), and requiring whitespace after the
# binary let that form skip the scan. `.` and `-` stay in the word class so
# this does not fire on `kubectl-guard.sh` or a `kubectl.exe`-style name.
printf '%s\n' "$SCAN" | grep -qE '(^|[^A-Za-z0-9_.-])kubectl([^A-Za-z0-9_.-]|$)' || exit 0

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

# Does a `kubectl get` target name the secrets resource? The kind is what
# decides, and kubectl accepts it in more spellings than the two literals this
# used to compare against — each of the following dumps the same data:
#
#   secret/db-creds        resource/name
#   pods,secrets           a comma-joined list of kinds
#   Secret                 kinds are case-insensitive
#   secrets.v1.            fully qualified kind.version.group
#   /api/v1/…/secrets      the REST path behind --raw
#
# Only the KIND is compared, never a prefix of it, so a CRD that merely starts
# with the word (secretproviderclass, sealedsecrets) stays a silent read.
is_secret_target() {
  local raw="$1" part kind
  raw=$(printf '%s' "$raw" | tr -d "\"'" | tr '[:upper:]' '[:lower:]')
  [[ -z "$raw" ]] && return 1

  # A --raw value is an API path, not a kind: /api/v1/namespaces/vm/secrets,
  # optionally with a name or query string after it.
  if [[ "$raw" = /* ]]; then
    printf '%s' "$raw" | grep -qE '(^|/)secrets?(/|\?|$)'
    return
  fi

  local parts=()
  IFS=',' read -ra parts <<<"$raw"
  for part in "${parts[@]}"; do
    kind="${part%%/*}"   # drop /name
    kind="${kind%%.*}"   # drop .version.group
    [[ "$kind" = "secret" || "$kind" = "secrets" ]] && return 0
  done
  return 1
}

# Tokenize on whitespace. Quoting is not honoured, deliberately: a quoted flag
# value that splits into several tokens yields an unrecognised verb, which
# escalates. Failing closed on ambiguity is the intended behaviour.
#
# SCAN (built above, before the bail-out) turns `$(` and a backtick into
# separators. Without that the first token of `echo "$(kubectl delete pod foo)"`
# is the literal `"$(kubectl`, which equals neither `kubectl` nor */kubectl, so
# the body was never inspected. git-guard covers this case already because `$(`
# is one of its boundary alternatives.
read -ra TOKENS <<<"$SCAN"

i=0
n=${#TOKENS[@]}
while (( i < n )); do
  tok="${TOKENS[$i]}"
  # A quote can still cling to the token (`'kubectl'`, `"kubectl`). Strip quote
  # characters for the binary comparison only — the verb scan below keeps using
  # raw tokens, so flag parsing is unchanged.
  tok="${tok//[\"\']/}"
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
        if is_secret_target "$sub"; then
          emit_ask "kubectl get $sub reads live credentials into the transcript. Confirm this is intended and scoped to the secret you need."
          exit 0
        fi
        # --raw=<path> is self-contained, so next_bare_token skips it entirely
        # and the API path behind it never got looked at. Scan this command's
        # own tokens for it, stopping at the operator that ends the command.
        k=$i
        while (( k < n )) && ! is_operator "${TOKENS[$k]}"; do
          case "${TOKENS[$k]}" in
            --raw=*)
              if is_secret_target "${TOKENS[$k]#--raw=}"; then
                emit_ask "kubectl get --raw reads the secrets API directly, which returns the same credential data. Confirm this is intended and scoped to the secret you need."
                exit 0
              fi
              ;;
          esac
          (( k++ ))
        done
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
