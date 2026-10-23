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
# be expressed in settings.json at all. That deny rule is retired; this hook
# asks on every spelling it reads, typed or handed to an inline script's
# shell-out. A script file and a heredoc under a wrapper it does not read.
#
# This hook sees the whole command string, so it finds the verb wherever it
# sits. Policy:
#   • read-only verb (get/describe/logs/…)   → silent allow
#   • `get secret`, `describe secret`        → ask (credential materialisation)
#   • mutating verb (delete/apply/drain/…)   → ask
#   • verb absent (bare `kubectl`, --help)   → silent allow (does nothing)
#   • verb or get's kind from a variable, a substitution or xargs's input that
#     the command does not spell out          → ask
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
require_parsable_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0
# Normalizing drops quotes, backslashes and case but never adds a letter, so a
# command with no kubectl once those are gone is done before ~15 ms of it. The
# precise bail-out below still runs on the normalized text.
printf '%s\n' "$CMD" | tr -d '"'\''\\' | grep -qi 'kubectl' || exit 0
CMD=$(strip_inert_heredocs "$CMD")
# A script's shell-outs are checked as commands of their own (lib.sh); "ask":
# one built from a value it cannot read asks, as `kubectl $verb` does.
check_inline_shellouts kubectl ask

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
# A command separator (not a redirection): starts a new segment. SCAN keeps a
# substitution opener as its own token, `$(` or a backtick: a separator, so the
# body's first word starts a segment, but not an operator, so kubectl whose verb
# is a substitution reads that marker as its verb rather than stopping bare.
is_separator() {
  case "$1" in '|'|'||'|'&&'|';'|'&'|'$('|'`') return 0 ;; *) return 1 ;; esac
}
# A redirection glued to its target: 2>&1, 2>/dev/null, >out, <in, &>x. Skipped, never the verb.
is_redirect() {
  case "$1" in [0-9]'>'*|[0-9][0-9]'>'*|'>'*|'<'*|'&>'*) return 0 ;; *) return 1 ;; esac
}

# Move K past the flag value at K. A substitution value spans several tokens,
# `-n "$(cat ns)"` four, and stepping one would read its body as the verb. With
# $1 = subst, only a substitution is skipped: `--context=` already holds its value
# unless SCAN split a `$(` off it.
skip_value() {
  local depth=0 t start=$K
  while (( K < n )) && [[ -z "${TOKENS[$K]//[\"\']/}" ]]; do (( K++ )); done
  if [[ "${1:-}" == subst && "${TOKENS[$K]:-}" != '$(' && "${TOKENS[$K]:-}" != '`' ]]; then K=$start; return 0; fi
  case "${TOKENS[$K]:-}" in
    '`') (( K++ )); while (( K < n )) && [[ "${TOKENS[$K]}" != '`' ]]; do (( K++ )); done; (( K++ )) ;;
    '$(')
      while (( K < n )); do
        t="${TOKENS[$K]}"; (( K++ ))
        if [[ "$t" == '$(' ]]; then (( depth++ )); continue; fi
        # lib.sh's separate_groups turned an unquoted `)` into `;`.
        if [[ "$t" == ';' ]]; then (( depth-- )); (( depth <= 0 )) && return 0; continue; fi
        t="${t//[\"\']/}"
        while [[ "$t" == *')' ]]; do (( depth-- )); t="${t%)}"; done
        (( depth <= 0 )) && return 0
      done ;;
    *) (( K++ )) ;;
  esac
}

# get's own flags that take a value: with $2 = get, `get -o yaml secret` finds
# the kind, not "yaml".
GET_VALUE_FLAGS=(-o --output -l --selector -L --label-columns --field-selector --sort-by --template -f --filename -k --kustomize)

# Set NB to the next bare (non-flag) token at or after index $1 and NB_IDX to its
# index, skipping global flags and the values they consume. NB is empty if the
# command ends first. A global rather than output: a $(…) call forks each time.
next_bare_token() {
  local t
  K="$1"; NB=""; NB_IDX=$n
  while (( K < n )); do
    t="${TOKENS[$K]}"
    if is_operator "$t"; then
      return 0
    elif is_redirect "$t" || [[ -z "${t//[\"\']/}" ]]; then
      (( K++ ))
    elif [[ "$t" == -* ]]; then
      (( K++ ))
      if [[ "$t" != *=* ]] && { is_value_flag "$t" || { [[ "${2:-}" == get ]] && in_list "$t" "${GET_VALUE_FLAGS[@]}"; }; }; then skip_value
      # `--context="$(…)"`: SCAN split the value off at the marker.
      elif [[ "${t//[\"\']/}" == *= ]]; then skip_value subst; fi
    else
      NB=$t; NB_IDX=$K
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
  local raw="$1" part kind rest hit=1 nocase=0
  # A quoted substitution keeps its `)` on the last word: "$(kubectl get secrets)".
  raw=${raw//[\"\')]/}
  [[ -z "$raw" ]] && return 1
  # Kinds are case-insensitive. nocasematch, not tr: a fork per word cost 1.8 s on
  # a script with 300 gets, and bash 3.2 has no ${raw,,}.
  shopt -q nocasematch && nocase=1; shopt -s nocasematch

  # A --raw value is an API path, not a kind: /api/v1/namespaces/vm/secrets,
  # optionally with a name or query string after it.
  if [[ "$raw" = /* ]]; then
    [[ "$raw" =~ $SECRET_PATH_RE ]] && hit=0
  else
    rest=$raw,
    while [[ -n "$rest" ]]; do
      part=${rest%%,*}; rest=${rest#*,}
      kind="${part%%/*}"   # drop /name
      kind="${kind%%.*}"   # drop .version.group
      [[ "$kind" = "secret" || "$kind" = "secrets" ]] && { hit=0; break; }
    done
  fi
  (( nocase )) || shopt -u nocasematch
  return $hit
}
SECRET_PATH_RE='(^|/)secrets?(/|\?|$)'

# A command whose arguments are only text: it searches, prints or lists them and
# runs none. `grep "kubectl delete"` and `which kubectl` name kubectl as text.
text_cmd() {
  case "$1" in
    grep|egrep|fgrep|rg|which|type|whereis|echo|printf|head|tail|wc|sort|uniq|cut|tr|cat|less|more|column|ls|cd|true|gh) return 0 ;;
    sed) sed_prints_only "${@:2}" && return 0 ;;
    # A PR title or commit message names kubectl as text. Only git subcommands
    # that never run an argument: `bisect run`, `rebase -x` and a `!` alias do.
    git) case "${2:-}" in commit|stash|tag|notes|log|status|diff|grep|add|branch|switch|show|ls-files|fetch|pull|push|worktree) return 0 ;; esac ;;
  esac
  return 1
}

# sed's arguments, quotes intact: true when every script only prints lines by
# number or pattern (`-n 1,9p`, `-n '/x/p;20p'`). -i, -f, e, w and r write or run.
sed_prints_only() {
  local a e=0 scripts=() seen=0 p
  local print_re='^[[:space:]]*((([0-9]+|\$)(,([0-9]+|\$|\+[0-9]+))?)|(/[^/]*/(,/[^/]*/)?))?p[[:space:]]*$'
  for a in "$@"; do
    a=${a//[\"\']/}
    if (( e )); then scripts+=("$a"); e=0; seen=1; continue; fi
    case "$a" in
      -e) e=1 ;;
      --quiet|--silent|--regexp-extended|--separate|--unbuffered) ;;
      -*) [[ "$a" =~ ^-[nErsuz]+$ ]] || return 1 ;;
      *) (( seen )) || { scripts+=("$a"); seen=1; } ;;
    esac
  done
  (( ${#scripts[@]} )) || return 1
  for a in "${scripts[@]}"; do
    IFS=';' read -ra parts <<<"$a"
    for p in "${parts[@]}"; do [[ "$p" =~ $print_re ]] || return 1; done
  done
}

# Does text command $1 (arguments after it) store text a later command can read
# back: a file (sort -o, uniq's OUTPUT operand, less's log, git --output), a
# variable (printf -v), the repository (git commit, tag, notes…) or GitHub (gh)?
writes_to() {
  local c="$1" a n=0 val=0 opts=1
  local sort_re='^(-[A-Za-z]*o|--o)' less_re='^(-[A-Za-z]*[oO]|--(log|LOG))'
  shift
  case "$c" in
    gh) return 0 ;;
    git) case "${1:-}" in log|status|diff|grep|show|ls-files) ;; *) return 0 ;; esac ;;
  esac
  for a in "$@"; do
    a="${a//[\"\']/}"
    case "$c" in
      sort) [[ "$a" =~ $sort_re ]] && return 0 ;;
      less|more) [[ "$a" =~ $less_re ]] && return 0 ;;
      printf) [[ "$a" == -v* ]] && return 0 ;;
      git) [[ "$a" == --output* ]] && return 0 ;;
      uniq)   # [OPTION]... [INPUT [OUTPUT]]; -f, -s and -w take a value
        if (( val )); then val=0
        elif (( opts )) && [[ "$a" == -- ]]; then opts=0
        elif (( opts )) && [[ "$a" == -[fsw] ]]; then val=1
        elif (( opts )) && [[ "$a" == -?* ]]; then :
        elif (( ++n > 1 )); then return 0; fi ;;
    esac
  done
  return 1
}

# The scan sees no word in `k=kubectl; "$k" delete`, `x='kubectl delete pod x';
# eval "$x"` or `$(which kubectl) delete`, so values set in this command go in
# place first, as the shell would put them.
SQ="'[^']*'"
ASSIGN_RE='(^|[[:space:];&|(`])((export|local|readonly|declare|typeset)([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)(\+?)=(\$\([^()]*\)|\$\{[^{}]*\}|\([^()]*\)|\$?'"$SQ"'|"[^"]*"|[^[:space:];&|]*)'
FOR_RE='(^|[[:space:];&|(`])for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in[[:space:]]+((\$\([^()]*\)|[^;&|'$'\n''])*)'
WORD_RE='^[[:space:]]*(\$\([^()]*\)|'"$SQ"'|"[^"]*"|[^[:space:]]+)'
BRACE_PART_RE='^\{([A-Za-z_][A-Za-z0-9_]*)([^{}]*)\}'
DEFAULT_RE='^:?[-=+](.*)$'
IDENT_RE='^[A-Za-z_][A-Za-z0-9_]*'
SUBST_PART_RE='^\(([^()`]*)\)'
TICK_RE='`([^`]*)`'
PRINTER_RE='(\$\(|`)[[:space:]]*["'"'"']?([^[:space:]]*/)?(echo|printf|print|which|command|type|whereis)["'"'"']?([[:space:]]|\)|`)'
KUBECTL_RE='(^|[^A-Za-z0-9_.-])kubectl([^A-Za-z0-9_.-]|$)'
US=$'\x1f'

# Every value this command gives a name (NAME=…, export/local/declare NAME=…, an
# array's words, each word of `for NAME in …`), kept in VV_<name> joined by US:
# bash 3.2 has no associative arrays. Order does not matter; see value_of.
add_value() { local r="VV_$1"; printf -v "$r" '%s' "${!r:-}$US$2"; }
# NAME+=: onto the last value, with a space for an array's words.
append_value() {
  local r="VV_$1" cur
  cur=${!r:-}
  [[ -z "$cur" ]] && { add_value "$1" "$2"; return; }
  printf -v "$r" '%s' "${cur%"$US"*}$US${cur##*"$US"}$3$2"
}
collect_values() {
  local s=$CMD name list v plus sep
  while [[ "$s" =~ $ASSIGN_RE ]]; do
    name=${BASH_REMATCH[5]}; plus=${BASH_REMATCH[6]}; v=${BASH_REMATCH[7]}; s=${s#*"${BASH_REMATCH[0]}"}
    [[ "$v" == "\$'"* ]] && v=${v#\$}
    sep=""; [[ "$v" == '('*')' ]] && { v=${v:1:${#v}-2}; sep=" "; }
    if [[ -n "$plus" ]]; then append_value "$name" "${v//[\"\']/}" "$sep"; else add_value "$name" "${v//[\"\']/}"; fi
  done
  s=$CMD
  while [[ "$s" =~ $FOR_RE ]]; do
    name=${BASH_REMATCH[2]}; list=${BASH_REMATCH[3]}; s=${s#*"${BASH_REMATCH[0]}"}
    while [[ "$list" =~ $WORD_RE ]]; do
      add_value "$name" "${BASH_REMATCH[1]//[\"\']/}"
      list=${list:${#BASH_REMATCH[0]}}
    done
  done
}

# Set VAL to the text $1 stands for ($2: a ${…:-word}'s word). Several single
# words join with a comma, keeping one token (`-n $ns`) and every kind (`get
# pods,secrets`). 2: several values, one naming kubectl, so ask. 1: leave it.
# `K=${K:-kubectl}` gives K one value, kubectl, not two.
value_of() {
  local r="VV_$1" rest v seen=$US cnt=0 spaced=0 named=0
  rest=${!r:-}; [[ $# -gt 1 ]] && rest+=$US$2
  VAL=""
  [[ -z "$rest" ]] && return 1
  rest=${rest#"$US"}$US
  while [[ -n "$rest" ]]; do
    v=${rest%%"$US"*}; rest=${rest#*"$US"}
    case "$v" in
      "\${$1:-"*"}"|"\${$1-"*"}"|"\${$1:="*"}"|"\${$1="*"}") v=${v#*[-=]}; v=${v%\}} ;;
      "\$$1"|"\${$1}") continue ;;
    esac
    [[ "$seen" == *"$US$v$US"* ]] && continue
    seen+=$v$US; cnt=$((cnt + 1)); VAL+=${VAL:+,}$v
    [[ "$v" == *[[:space:]]* ]] && spaced=1
    # A `$(kubectl get …)` value is that command's output, not a kubectl to run.
    [[ "$v" != '$('* && "$v" != '`'* && "${v//[\\]/}" =~ $KUBECTL_RE ]] && named=1
  done
  (( cnt == 0 )) && return 1
  (( cnt == 1 )) && return 0
  (( named )) && return 2
  (( spaced )) && return 1
  return 0
}

# value_of NAME once per name (VC_/VR_<name>): a script expands the same names often.
cached_value() {
  local r="VR_$1" c="VC_$1" rc
  if [[ -z "${!r:-}" ]]; then
    value_of "$1"; rc=$?
    printf -v "$r" '%s' "$rc"; printf -v "$c" '%s' "$VAL"
  fi
  VAL=${!c}; return "${!r}"
}

ask_ambiguous() {
  emit_ask "kubectl is reached through \$$1, which this command sets to more than one value, so the guard cannot tell which runs. Run kubectl by name."
  exit 0
}

# Put each expansion's value in place, in one walk over the text split at `$`: a
# part that starts `{NAME…}` is ${NAME…} (a default's word counts as a value, also
# for a NAME this command never sets), one that starts NAME is $NAME. A pass per
# name made a 160-line script take 108 s.
resolve_values() {
  local parts=() p name rest x rc out
  IFS='$' read -r -d '' -a parts <<<"$CMD"
  out=${parts[0]}
  for (( x = 1; x < ${#parts[@]}; x++ )); do
    p=${parts[$x]}
    if [[ "$p" =~ $BRACE_PART_RE ]]; then
      name=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[2]}
      if [[ "$rest" =~ $DEFAULT_RE ]]; then value_of "$name" "${BASH_REMATCH[1]//[\"\']/}"; rc=$?
      elif [[ -z "$rest" || "$rest" == [!A-Za-z0-9_]* ]]; then cached_value "$name"; rc=$?
      else rc=1; fi
      (( rc == 2 )) && ask_ambiguous "$name"
      if (( rc == 0 )); then out+=$VAL${p:${#name}+${#rest}+2}; continue; fi
    elif [[ "$p" =~ $IDENT_RE ]]; then
      name=${BASH_REMATCH[0]}
      cached_value "$name"; rc=$?
      (( rc == 2 )) && ask_ambiguous "$name"
      if (( rc == 0 )); then out+=$VAL${p:${#name}}; continue; fi
    fi
    out+=\$$p
  done
  CMD=${out%$'\n'}
}

# Set OUT to what a substitution body prints when it only prints: `which kubectl`,
# `command -v kubectl`, `echo kubectl delete`. 1 for anything else, which the scan
# reads as written.
printed_by() {
  local words=() c i=1
  [[ "$1" == *[\;\&\|\$]* ]] && return 1
  read -ra words <<<"$1"
  [[ ${#words[@]} -eq 0 ]] && return 1
  c=${words[0]//[\"\'\\]/}; c=${c##*/}
  case "$c" in echo|printf|print|which|command|type|whereis) ;; *) return 1 ;; esac
  while (( i < ${#words[@]} )) && [[ "${words[$i]}" == -* ]]; do (( i++ )); done
  OUT="${words[*]:$i}"; OUT=${OUT//[\"\']/}
}

# Replace each innermost $(…) that only prints, in one walk over the text split
# at `$` (a rescan per substitution took 1.5 s on a 100-substitution heredoc).
resolve_printers() {
  local parts=() p x out
  IFS='$' read -r -d '' -a parts <<<"$CMD"
  out=${parts[0]}
  for (( x = 1; x < ${#parts[@]}; x++ )); do
    p=${parts[$x]}
    if [[ "$p" =~ $SUBST_PART_RE ]] && printed_by "${BASH_REMATCH[1]}"; then
      out+=$OUT${p:${#BASH_REMATCH[0]}}
    else
      out+=\$$p
    fi
  done
  CMD=${out%$'\n'}
}

# Backticks do not nest, and are rare enough to scan as before.
resolve_ticks() {
  local s=$CMD out="" m
  while [[ "$s" =~ $TICK_RE ]]; do
    m=${BASH_REMATCH[0]}
    out+=${s%%"$m"*}; s=${s#*"$m"}
    if printed_by "${BASH_REMATCH[1]}"; then out+=$OUT; else out+=$m; fi
  done
  CMD=$out$s
}

if [[ "$CMD" == *[\$\`]* ]]; then
  collect_values
  # Twice: a value can name another (`a=kubectl; b="$a delete"; $b pod x`).
  resolve_values; resolve_values
  if [[ "$CMD" =~ $PRINTER_RE ]]; then
    for _ in 1 2; do
      [[ "$CMD" == *'$('* ]] && resolve_printers
      [[ "$CMD" == *'`'* ]] && resolve_ticks
    done
  fi
fi

# Set NK to KIND when tokens $1 up to $2 are `kubectl … get KIND … -o name`, whose
# output names that kind only (pod/api-0), so a get it feeds reads that kind. Line
# filters may follow (`| grep web | head -3`); anything that rewrites lines may not.
name_kind() {
  local i=$1 end=$2 t w named=0 all=$n first=$2
  NK=""
  w=${TOKENS[$i]:-}; w=${w//[\"\']/}
  [[ "$w" == kubectl || "$w" == */kubectl ]] || return 1
  for (( t = i; t < end; t++ )); do
    case "${TOKENS[$t]}" in
      ';') break ;;
      '|') (( t < first )) && first=$t
           w=${TOKENS[$((t + 1))]:-}; w=${w//[\"\']/}
           case "${w##*/}" in grep|egrep|fgrep|head|tail|sort|uniq) continue ;; *) return 1 ;; esac ;;
      '&&'|'||'|'&'|'|&') return 1 ;;
    esac
    (( t > first )) && continue
    case "${TOKENS[$t]//[\"\']/}" in
      -oname*|-o=name*|--output=name*) named=1 ;;
      -o|--output) [[ "${TOKENS[$((t + 1))]//[\"\']/}" == name* ]] && named=1 ;;
    esac
  done
  (( named )) || return 1
  n=$first; next_bare_token $((i + 1))
  if [[ "${NB//[\"\']/}" == get ]]; then next_bare_token $((NB_IDX + 1)) get; NK=${NB//[\"\']/}; NK=${NK%%)*}; fi
  n=$all
  [[ -n "$NK" && "$NK" != [\$\`]* ]]
}

# `… | xargs kubectl` takes kubectl's verb from its input, and normalize_wrappers
# drops xargs, so the scan below would see a bare `kubectl`. Ask when kubectl is
# the command xargs or parallel runs and its verb, or the kind it gets, is not on
# the line. kubectl as an argument (`xargs grep -l kubectl`) is not that command,
# and neither is `| xargs kubectl` inside a quoted commit message.
if [[ "$CMD" == *xargs* || "$CMD" == *parallel* ]]; then
  read -ra TOKENS <<<"$(neutralize_quoted_separators "$CMD" | tr '\n' ';' | sed -E 's/\|\||&&|\|&|[|;]/ & /g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1 \& \2/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1 \& \2/g')"
  n=${#TOKENS[@]}
  for (( j = 0; j < n; j++ )); do
    [[ "${TOKENS[$j]##*/}" == xargs || "${TOKENS[$j]##*/}" == parallel ]] || continue
    (( j == 0 )) || is_separator "${TOKENS[$((j - 1))]}" || [[ "${TOKENS[$((j - 1))]}" == sudo ]] || continue
    k=$((j + 1)); rep='{}'
    while (( k < n )) && [[ "${TOKENS[$k]}" == -* ]]; do
      case "${TOKENS[$k]}" in
        -I|--replace) rep=${TOKENS[$((k + 1))]:-}; (( k += 2 )) ;;
        -I?*|-i?*) rep=${TOKENS[$k]:2}; (( k++ )) ;;
        -[nLPsdEajSN]|--max-args|--max-lines|--max-procs|--max-chars|--delimiter|--eof|--arg-file|--jobs|--sshlogin|--colsep|--joblog) (( k += 2 )) ;;
        *) (( k++ )) ;;
      esac
    done
    w=${TOKENS[$k]:-}; w=${w//[\"\']/}
    [[ "$w" == kubectl || "$w" == */kubectl ]] || continue
    next_bare_token $((k + 1)); verb=${NB//[\"\']/}
    if [[ -z "$verb" ]]; then
      emit_ask "${TOKENS[$j]##*/} hands kubectl its subcommand from its input, which this guard cannot read. Put the subcommand on the command line."
      exit 0
    fi
    [[ "$verb" == get ]] || continue
    next_bare_token $((NB_IDX + 1)) get; kind=${NB%%/*}
    [[ -n "$kind" && "$kind" != *"$rep"* ]] && continue
    # Fed by `kubectl get pods -o name`, the input names pods only.
    s0=$((j - 2)); while (( s0 > 0 )) && { [[ "${TOKENS[$((s0 - 1))]}" == '|' ]] || ! is_separator "${TOKENS[$((s0 - 1))]}"; }; do (( s0-- )); done
    if [[ "${TOKENS[$((j - 1))]:-}" == '|' ]] && (( s0 >= 0 )) && name_kind "$s0" $((j - 1)) && ! is_secret_target "$NK"; then continue; fi
    emit_ask "${TOKENS[$j]##*/} hands kubectl get its resource kind from its input, which this guard cannot read, and a Secret's data would land in the transcript. Put the kind on the command line."
    exit 0
  done
fi

# A pipeline of text commands runs no kubectl, even beside one that runs something
# else (`make; grep -n "kubectl" x`), so it leaves CMD. Split where the shell does
# (lib.sh), and only where that split is sound: one line (no heredoc, `|` or `\`
# continuing onto the next), no group, substitution or compound command.
# A text pipeline that writes stays when something else here could run it.
# A quoted paren is text (`grep -E 'kubectl (cp|exec)'`); "$(…)" runs even in quotes.
BLANK=$(printf '%s' "$CMD" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
if [[ "$CMD" != *$'\n'* && "$CMD" == *[\;\&\|]* && "$CMD" != *'$('* && "$CMD" != *'`'* \
      && "$CMD" != *[\<\>]'('* && "$CMD" != *"\$'"* && "$CMD" != *\\[\"\']* && "$BLANK" != *[\(\)\{\}]* ]] \
   && ! printf '%s\n' "$CMD" | grep -qE '(^|[^[:alnum:]_])(fi|done|esac)([^[:alnum:]_]|$)'; then
  # A literal %7C must not come back as a `|`, so % is escaped first.
  PCMD=$CMD; [[ "$CMD" == *%* ]] && PCMD=$(printf '%s' "$CMD" | sed 's/%/%25/g')
  IFS=';' read -ra PIPES < <(neutralize_quoted_separators "$PCMD" | sed -E 's/\|&/|/g; s/\|\||&&/;/g; s/&([[:space:]]|$)/;\1/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1;\2/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1;\2/g')
  TEXT=(); WR=(); ANY_O=0
  for p in "${PIPES[@]}"; do
    t=1; wr=0; IFS='|' read -ra segs <<<"$p"
    for seg in "${segs[@]}"; do
      set -f; set -- $seg; set +f
      while [[ $# -gt 0 ]] && is_redirect "$1"; do shift; done
      [[ $# -eq 0 ]] && continue
      w="${1//[\"\']/}"; w="${w##*/}"
      text_cmd "$w" "${@:2}" || { t=0; ANY_O=1; continue; }
      writes_to "$w" "${@:2}" && wr=1
    done
    TEXT+=("$t"); WR+=("$wr")
  done
  KEPT=""; DROPPED=0
  for k in "${!PIPES[@]}"; do
    p="${PIPES[$k]}"
    if [[ ${TEXT[$k]} -eq 1 ]]; then
      w=$p; [[ $ANY_O -eq 1 && "$p" == *'>'* ]] && w=$(printf '%s\n' "$p" | sed -E 's/[0-9]*>&[0-9-]*//g; s#&?[0-9]*>>?[[:space:]]*/dev/null##g')
      if [[ $ANY_O -eq 0 ]] || [[ ${WR[$k]} -eq 0 && "$w" != *'>'* ]]; then DROPPED=1; continue; fi
    fi
    KEPT+="$p"$'\n'
  done
  [[ -z "$KEPT" ]] && exit 0
  if [[ $DROPPED -eq 1 ]]; then
    CMD=$KEPT; [[ "$KEPT" == *%* ]] && CMD=$(printf '%s' "$KEPT" | sed -E 's/%7C/|/g; s/%3B/;/g; s/%26/\&/g; s/%25/%/g')
  fi
fi

# The exemption below holds only when EVERY segment's command is a text command
# or kubectl, so `echo 'kubectl delete' | $SHELL` (or `| bash`, `| . /dev/stdin`,
# `| awk system`) is read as a command. Quoted spans are blanked for this
# structural check only.
TEXT_ONLY=1
while IFS= read -r seg; do
  set -f; set -- $seg; set +f
  while [[ $# -gt 0 ]] && is_redirect "$1"; do shift; done
  [[ $# -eq 0 ]] && continue
  w="${1//[\"\']/}"; w="${w##*/}"
  [[ "$w" == kubectl ]] || text_cmd "$w" "${2:-}" || { TEXT_ONLY=0; break; }
# Raw CMD, not SCAN: normalize_binaries strips a quote off a segment's first word,
# which unbalances the quote blanking. A wrapper first word just loses the exemption.
done < <(printf '%s\n' "$CMD" | tr '\n' ';' | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g" | sed -E 's/\$\(/;/g; s/`/;/g; s/\|\||&&/;/g; s/[|;]/\n/g; s/&([[:space:]]|$)/\n/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1\n\2/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1\n\2/g')

# When only text commands and kubectl run, a quoted `|` or `;` is text (lib.sh).
# Not with a substitution: the `;` in "$(a; b)" is real.
SRC=$CMD
if [[ $TEXT_ONLY -eq 1 && "$CMD" == *[\"\']* && "$CMD" != *'$('* && "$CMD" != *'`'* ]]; then
  SRC=$(neutralize_quoted_separators "$CMD")
fi

# Normalise BEFORE the bail-out, not after. The bail-out's own pattern requires
# whitespace or a slash in front of `kubectl`, and `$(` is neither — so
# `echo "$(kubectl delete pod foo)"` exited here and was allowed silently, no
# matter what the scan below did. See the tokenizer note further down.
# A `&` glued to a word (`true&kubectl`) splits too; `2>&1`, `&>` and `|&` do not.
SCAN=$(normalize_command "$SRC" | tr '\n' ';' | sed -E 's/\$\(/ $( /g; s/`/ ` /g; s/\|\||&&|[|;]/ & /g; s/&([[:space:]]|$)/ & \1/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1 \& \2/g; s/(^|[^<>&|\\])&([^>&[:space:]])/\1 \& \2/g')

# Cheap bail-out: no kubectl anywhere, nothing to do.
# Both sides use "not a word character" rather than "whitespace": a quote can
# sit on either side (`'kubectl' delete …`), and requiring whitespace after the
# binary let that form skip the scan. `.` and `-` stay in the word class so
# this does not fire on `kubectl-guard.sh` or a `kubectl.exe`-style name.
printf '%s\n' "$SCAN" | grep -qE '(^|[^A-Za-z0-9_.-])kubectl([^A-Za-z0-9_.-]|$)' || exit 0

# Tokenize on whitespace. Quoting is not honoured, deliberately: a quoted flag
# value that splits into several tokens yields an unrecognised verb, which
# escalates. Failing closed on ambiguity is the intended behaviour.
#
# SCAN (built above, before the bail-out) gives `$(` and a backtick tokens of
# their own (see is_separator). Glued on, the first token of
# `echo "$(kubectl delete pod foo)"` is the literal `"$(kubectl`, which equals
# neither `kubectl` nor */kubectl, so the body was never inspected. git-guard
# covers this case already because `$(` is one of its boundary alternatives.
read -ra TOKENS <<<"$SCAN"

i=0
n=${#TOKENS[@]}
SEG_FIRST=""; SEG_SECOND=""
while (( i < n )); do
  tok="${TOKENS[$i]}"
  if is_separator "$tok"; then SEG_FIRST=""; (( i++ )); continue; fi
  if [[ -z "$SEG_FIRST" ]] && ! is_redirect "$tok"; then
    SEG_FIRST="${tok//[\"\']/}"; SEG_SECOND="${TOKENS[$((i + 1))]:-}"; SEG_SECOND="${SEG_SECOND//[\"\']/}"
  fi
  if [[ $TEXT_ONLY -eq 1 ]] && text_cmd "$SEG_FIRST" "$SEG_SECOND"; then (( i++ )); continue; fi
  # A quote can still cling to the token (`'kubectl'`, `"kubectl`). Strip quote
  # characters for the binary comparison only — the verb scan below keeps using
  # raw tokens, so flag parsing is unchanged.
  tok="${tok//[\"\']/}"
  # Match `kubectl` and any path ending in /kubectl.
  if [[ "$tok" = "kubectl" || "$tok" = */kubectl ]]; then
    (( i++ ))
    next_bare_token "$i"; verb=$NB

    # Bare `kubectl` with no verb does nothing but print help.
    [[ -z "$verb" ]] && continue

    # Subcommand lookups start after the verb. A read resumes at i, so a
    # substitution skipped as a flag value (`-n "$(…)"`) is still scanned.
    a=$((NB_IDX + 1))

    verb=${verb//[\"\']/}
    case "$verb" in
      '$('*|'`'*|'$'*)
        emit_ask "kubectl's subcommand comes from a variable or a substitution ($verb …), which this guard cannot read. Put the subcommand on the command line."
        exit 0 ;;
    esac
    # Inside quotes a substitution keeps its `)` on the last word (lib.sh's
    # separate_groups splits only unquoted ones): "$(kubectl config current-context)".
    verb=${verb%%)*}

    case "$verb" in
      get|describe)
        # `kubectl get secret -o yaml` materialises live credentials into the
        # transcript and debug logs. `describe secret` prints key names and
        # annotations, not values. Every other `get` or `describe` is a read.
        next_bare_token "$a" get; sub=$NB; si=$NB_IDX
        if [[ "$verb" == get && "${sub//[\"\']/}" == [\$\`]* ]]; then
          # `get $(kubectl get pods -o name)` reads pods.
          ok=0
          if [[ "$sub" == '$(' ]]; then K=$si; skip_value; name_kind $((si + 1)) "$K" && ! is_secret_target "$NK" && ok=1; fi
          if (( ok == 0 )); then
            emit_ask "kubectl get's resource kind comes from a variable or a substitution (${sub//[\"\']/} …), which this guard cannot read, and a Secret's data would land in the transcript. Put the kind on the command line."
            exit 0
          fi
        fi
        if is_secret_target "$sub"; then
          emit_ask "kubectl $verb $sub puts Secret data into the transcript (values for get; key names and annotations for describe). Confirm this is intended and scoped to the secret you need."
          exit 0
        fi
        # --raw=<path> is self-contained, so next_bare_token skips it entirely
        # and the API path behind it never got looked at. Scan this command's
        # own tokens for it, stopping at the operator that ends the command.
        # The same scan checks every bare token as a kind: next_bare_token
        # stops at the first, so `get -o yaml secret` compared only "yaml".
        k=$a
        while (( k < n )) && ! is_operator "${TOKENS[$k]}"; do
          case "${TOKENS[$k]}" in
            --raw=*)
              if is_secret_target "${TOKENS[$k]#--raw=}"; then
                emit_ask "kubectl get --raw reads the secrets API directly, which returns the same credential data. Confirm this is intended and scoped to the secret you need."
                exit 0
              fi
              ;;
            -o|--output|-l|--selector|-L|--label-columns|--field-selector|--sort-by|--template)
              K=$((k + 1)); skip_value; k=$((K - 1)) ;;
            -*=*) ;;
            -*) if is_value_flag "${TOKENS[$k]}"; then K=$((k + 1)); skip_value; k=$((K - 1)); fi ;;
            *)
              if is_secret_target "${TOKENS[$k]}"; then
                emit_ask "kubectl $verb ${TOKENS[$k]} puts Secret data into the transcript (values for get; key names and annotations for describe). Confirm this is intended and scoped to the secret you need."
                exit 0
              fi
              ;;
          esac
          (( k++ ))
        done
        continue
        ;;
      exec)
        # A read-only probe needs no confirmation: no stdin or tty, and after `--`
        # a command that prints neither file contents nor the environment (cat,
        # env and printenv read pod secrets), or any command asked only for its
        # version or help. ps is left out: command lines can carry secrets.
        k=$a; tty=0; remote=()
        while (( k < n )) && ! is_operator "${TOKENS[$k]}"; do
          t="${TOKENS[$k]}"
          if [[ "$t" == -- ]]; then
            (( k++ ))
            while (( k < n )) && ! is_operator "${TOKENS[$k]}"; do remote+=("${TOKENS[$k]//[\"\']/}"); (( k++ )); done
            break
          fi
          case "$t" in --stdin|--stdin=true|--tty|--tty=true) tty=1 ;; --*) ;; -*[it]*) tty=1 ;; esac
          (( k++ ))
        done
        if [[ $tty -eq 0 && ${#remote[@]} -gt 0 ]]; then
          ok=0
          case "${remote[0]##*/}" in
            ls|hostname|id|uname|df|du|date|whoami|pwd|uptime|nproc|free) ok=1 ;;
          esac
          if [[ $ok -eq 0 && ${#remote[@]} -gt 1 ]]; then
            ok=1
            for a in "${remote[@]:1}"; do
              case "$a" in --version|version|-version|-v|-V|--help|-h) ;; *) ok=0 ;; esac
            done
          fi
          for a in "${remote[@]}"; do case "$a" in *'$'*|*'`'*|*'>'*|*'<'*) ok=0 ;; esac; done
          [[ $ok -eq 1 ]] && continue
        fi
        emit_ask "kubectl exec runs a command inside a pod; only a non-interactive version probe or ls, id, df and similar run without asking. Name the pod and the command."
        exit 0
        ;;
      rollout|auth|config)
        next_bare_token "$a"; sub=${NB//[\"\']/}; sub=${sub%%)*}
        case "$verb" in
          rollout) in_list "$sub" "${SUBVERB_READONLY_rollout[@]}" && continue ;;
          auth)    in_list "$sub" "${SUBVERB_READONLY_auth[@]}"    && continue ;;
          config)
            if in_list "$sub" "${SUBVERB_READONLY_config[@]}"; then
              # view --raw or --flatten prints the kubeconfig's tokens and client keys.
              k=$a; raw=0
              while (( k < n )) && ! is_operator "${TOKENS[$k]}"; do
                case "${TOKENS[$k]}" in --raw|--raw=true|--flatten|--flatten=true) raw=1 ;; esac
                k=$((k + 1))
              done
              [[ $raw -eq 0 ]] && continue
              emit_ask "kubectl config view --raw puts the kubeconfig's tokens and client keys into the transcript. Confirm this is intended."
              exit 0
            fi ;;
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
