#!/usr/bin/env bash
# kubectl mutation guard.
#
# Fires on: PreToolUse → Bash.
#
# Why this exists: Bash permission rules are prefix-matched on the literal
# command string, so a verb-scoped rule like `Bash(kubectl get:*)` never
# matches a real invocation — kubectl takes its global flags BEFORE the verb
# (`kubectl --context X -n vm get svc`). The same is true of deny rules, so
# "allow kubectl broadly, deny the dangerous verbs" cannot be expressed in
# settings.json at all: `Bash(kubectl delete:*)` misses
# `kubectl --namespace vm delete pod foo`, and no finite list of flag
# spellings closes that.
#
# This hook sees the whole command string, so it finds the verb wherever it
# sits. Policy:
#   • read-only verb (get/describe/logs/…)   → silent allow
#   • mutating verb (delete/apply/drain/…)   → deny
#   • verb absent (bare `kubectl`, --help)   → silent allow (does nothing)
#   • anything it cannot classify            → ask (fail closed)
#
# Mutating verbs DENY rather than ask, because under `permissions.defaultMode:
# auto` an `ask` is adjudicated by the model classifier rather than by a human —
# only `deny` reliably stops the call in every mode. Cluster mutation is a
# run-it-yourself operation: the message tells the operator to do exactly that.
# To soften a verb, move it from MUTATING_VERBS into READONLY_VERBS (allow) or
# handle it in the subcommand-sensitive block (ask).
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

# Cheap bail-out: no kubectl anywhere, nothing to do.
printf '%s\n' "$CMD" | grep -qE '(^|[[:space:]/])kubectl([[:space:]]|$)' || exit 0

# Global flags that consume the NEXT token as their value. If we did not skip
# the value too, `kubectl --context delete-me get pods` would read "delete-me"
# as the verb. Flags using the --flag=value form are self-contained and need
# no entry here (they are skipped as a single token).
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

# Verbs that only read. Everything not listed here is treated as mutating or
# unknown, and both prompt — the list is the allowlist, deliberately.
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

# Verbs whose safety depends on their SUBcommand. Read-only subcommands are
# listed; anything else under the same verb prompts.
#   rollout status|history   — read;  rollout undo|restart|pause — mutating
#   auth can-i               — read;  auth reconcile             — mutating
#   config view|get-*|current-context — read; config set-*|use-context — mutating
declare -a SUBVERB_READONLY_rollout=(status history)
declare -a SUBVERB_READONLY_auth=(can-i)
declare -a SUBVERB_READONLY_config=(view current-context get-contexts get-clusters get-users)

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

# Tokenize on whitespace. Quoting is not honoured, deliberately: a quoted flag
# value that splits into several tokens yields an unrecognised verb, which
# prompts. Failing closed on ambiguity is the intended behaviour.
read -ra TOKENS <<<"$CMD"

i=0
n=${#TOKENS[@]}
while (( i < n )); do
  tok="${TOKENS[$i]}"
  # Match `kubectl` and any path ending in /kubectl.
  if [[ "$tok" = "kubectl" || "$tok" = */kubectl ]]; then
    (( i++ ))
    verb=""
    # Walk forward past global flags to the first bare token — the verb.
    while (( i < n )); do
      t="${TOKENS[$i]}"
      if is_operator "$t"; then
        break
      elif [[ "$t" == -* ]]; then
        if [[ "$t" != *=* ]] && is_value_flag "$t"; then
          (( i += 2 ))          # flag and its value
        else
          (( i++ ))             # boolean flag, or --flag=value
        fi
      else
        verb="$t"
        (( i++ ))
        break
      fi
    done

    # Bare `kubectl` with no verb does nothing but print help.
    [[ -z "$verb" ]] && continue

    # Subcommand-sensitive verbs: find the next bare token as the subverb.
    subverb=""
    if [[ "$verb" = rollout || "$verb" = auth || "$verb" = config ]]; then
      j=$i
      while (( j < n )); do
        t="${TOKENS[$j]}"
        if is_operator "$t"; then break; fi
        if [[ "$t" == -* ]]; then
          if [[ "$t" != *=* ]] && is_value_flag "$t"; then (( j += 2 )); else (( j++ )); fi
        else
          subverb="$t"; break
        fi
      done
      case "$verb" in
        rollout) in_list "$subverb" "${SUBVERB_READONLY_rollout[@]}" && continue ;;
        auth)    in_list "$subverb" "${SUBVERB_READONLY_auth[@]}"    && continue ;;
        config)  in_list "$subverb" "${SUBVERB_READONLY_config[@]}"  && continue ;;
      esac
      emit_deny "Blocked: kubectl $verb ${subverb:-<subcommand>} changes cluster or kubeconfig state. Run it yourself if it is intended — permission rules cannot gate it, because kubectl takes its global flags before the verb."
      exit 0
    fi

    if in_list "$verb" "${READONLY_VERBS[@]}"; then
      continue
    fi

    if in_list "$verb" "${MUTATING_VERBS[@]}"; then
      emit_deny "Blocked: kubectl $verb mutates the cluster. Run it yourself if it is intended — permission rules cannot gate this verb, because kubectl takes its global flags before the verb, so a deny rule can never match reliably."
      exit 0
    fi

    emit_ask "kubectl subcommand '$verb' is not on the read-only list, so it is treated as potentially mutating. Confirm before running."
    exit 0
  fi
  (( i++ ))
done

exit 0
