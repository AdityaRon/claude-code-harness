#!/usr/bin/env bash
# Blocks bash commands that would print, read, or transmit env variable values
# and dotfile secrets. All patterns are anchored to command boundaries
# (line start, pipe, chain, heredoc, $(…), backticks) so that occurrences
# inside commit messages, single-quoted strings, and literal arguments to
# unrelated programs do not false-positive.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

# Committed template files (.env.example / .sample / .template / .dist / .tpl)
# are safe to read, copy, and commit — neutralize them before matching so they
# don't trip the patterns below.
#
# The whole token goes, not just the .env prefix, because sensitive-file-guard
# allows ANY path with these suffixes and the two must agree: secrets.yaml.example
# is a template on both paths or on neither. Only the matched token is replaced,
# so `cat .env.example && cat .env` still denies on the second half.
# The second line is the normalized form (lib.sh): `/bin/cat`, `CAT` and `\cat`
# all run cat.
NCMD=$(neutralize_quoted_separators "$CMD")
SCAN=$(printf '%s\n%s' "$NCMD" "$(normalize_command "$NCMD")" \
  | sed -E 's#[^[:space:]]*\.(example|sample|template|dist|tpl)([[:space:]]|$)#TEMPLATEFILE\2#g')
# `.ENV` is `.env` on the default macOS filesystem, so patterns naming a file
# also run on a lower-cased copy, as sensitive-file-guard matches without case.
SCAN_LC=$(printf '%s\n%s' "$SCAN" "$(printf '%s' "$SCAN" | tr 'A-Z' 'a-z')")

# Command boundary: start-of-line, pipe, logical chain, subshell, semicolon, &.
A='(^|[|&;]|&&|\|\||\$\(|`)\s*'
# Commands that run their arguments as a command: `nice -n 10 cat .env` is cat.
# Greedy up to the last space, so stacked wrappers and their options go too.
WRAP='((env|command|builtin|exec|nice|ionice|time|nohup|sudo|doas|timeout|stdbuf|caffeinate|xargs)\b[^|;&]*\s)?'

# Readers / dumpers targeting .env* or ~/.aws/credentials or ~/.netrc.
READERS='(cat|less|more|head|tail|xxd|od|hexdump|strings|nl|awk|sed|grep|rg|base64|gpg|openssl\s+enc|source|tac|cut|paste|sort|uniq|diff|comm|bat|git\s+show)'
# Copy/move/duplicate a dotfile elsewhere (stage-then-exfil in a later command).
COPIERS='(cp|mv|install|tee|ln|tar|zip|rsync|scp)'
# Bash dot-source shortcut: `. <file>`
DOTSOURCE='\.'
# Credential files. Must block the same set as sensitive-file-guard, so that
# `cat secrets.yaml` is not allowed while reading the same file with the Read
# tool is denied. The claim of parity was false for 9 of them until 2026-09-18,
# so the "parity with sensitive-file-guard" block in tests/env-guard.test.sh
# now enforces it rather than a comment asserting it. Add to both lists or
# neither. The extension list on `secrets.` is explicit to keep source files
# (secrets.py, secrets.ts) readable.
DOTFILES='(\.env(\b|\.)|\.envrc\b|\.aws(/|\b)|\.netrc\b|id_(rsa|dsa|ecdsa|ed25519)\b'
DOTFILES="${DOTFILES}|\.pem\b|\.key\b|\.git-credentials\b|\.npmrc\b|\.pgpass\b"
DOTFILES="${DOTFILES}|\.kube/config|\.docker/config\.json|\.pypirc\b|\.ssh(/|\b)|\.gnupg(/|\b)"
DOTFILES="${DOTFILES}|\.config/gcloud(/|\b)|\.azure(/|\b)|kubeconfig\b|\.claude\.json\b"
DOTFILES="${DOTFILES}|credentials\.json\b|service[_-]account[^|;&[:space:]]*\.json\b"
DOTFILES="${DOTFILES}|terraform\.tfstate\b|\.tfvars\b|\.(p12|pfx|jks|keystore)\b|gh/hosts\.yml\b"
DOTFILES="${DOTFILES}|secrets\.(ya?ml|json|txt|env|cfg|conf|ini|properties|toml|enc)([^.[:alnum:]_]|$))"

# Env dumpers. Used after the boundary A, so a bare `env`, `export -p` or `set`
# counts anywhere in a chain. The old form anchored each to ^ inside the
# alternation, so `cd /tmp && env` and `set | head` were allowed.
ENV_END='\s*($|[|;&>)`])'
ENV_DUMP="(printenv|env(\s+-[0-9A-Za-z]+)*${ENV_END}|export(\s+-p)?${ENV_END}|set${ENV_END}|declare\s+-(p|x)\b|compgen\s+-e)"

# jq's env builtin and $ENV, and awk's ENVIRON, print variables with no dotfile
# or $VAR in the command. A key (.env, .["env"]) is not the builtin.
JQ_ENV='jq\b[^|;&]*(\$ENV|([^.$A-Za-z0-9_"]|[^[]")env\b)'
AWK_ENV='[gm]?awk\b.*ENVIRON'

# A $VAR whose NAME signals a secret: contains SECRET/PASSWORD anywhere, or ends
# in KEY/TOKEN/CREDENTIAL(S) as a trailing segment (preceded by _ or var start).
# Deliberately does NOT treat bare API/AUTH/KEY substrings as secret, so common
# vars like $API_URL, $SSH_AUTH_SOCK, $DONKEY are not flagged.
SECRET_VAR_CONTAINS='\$\{?[A-Za-z0-9_]*(SECRET|PASSWORD|PASSWD)'
SECRET_VAR_SUFFIX='\$\{?([A-Za-z0-9_]*_)?(KEY|TOKEN|CREDENTIALS?)([^A-Za-z0-9_]|$)'

# Reading a dotfile via input redirection, with no reader command at all.
#   while read l; do …; done < .env      cmd < .aws/credentials
#   Not <( … ), a process substitution: its command is scanned as a segment.
REDIR_READ="<\s*['\"]?[^|;&<>(]*${DOTFILES}"

# dd reading a dotfile:  dd if=.env of=/tmp/x
DD_READ="\bdd\b[^|;&]*if=[^|;&]*${DOTFILES}"

# curl/wget uploading a LOCAL FILE as the body (@file) or via -T/--upload-file.
# Plain POSTs (-d name=foo) are left to network-guard's "ask"; only the exfil
# shapes are hard-denied here. Secret-var exfil is caught by the VAR rules.
NET_EXFIL_FILE='(curl|wget)\b[^|;&]*((-d|--data|--data-binary|--data-urlencode|--data-raw|--json|--post-data)(=|\s)*@|(-F|--form)\s+[^|;&@]*@|(-T|--upload-file|--post-file|--body-file)\b|--data-urlencode(=|\s)+["'"'"']?[^=@"'"'"'[:space:]]*@)'

# Sockets.
SOCKETS='\b(nc|ncat|socat)\b'

# Eval / indirect execution of env-dumping content.
EVAL_ENV='\beval\b[^|;&]*\$\(.*(printenv|env\b|cat\b)'

# Each pattern with what it means, so a deny can say what it matched and why.
BLOCKED=(); WHY=()
add() { WHY+=("$1"); BLOCKED+=("$2"); }
add "reads a credential file"               "${A}${WRAP}${READERS}\s+[^|;&]*${DOTFILES}"
add "copies a credential file"              "${A}${WRAP}${COPIERS}\s+[^|;&]*${DOTFILES}"
# find hands its matches to -exec, and a pipe hands them to xargs, so the
# file and the reader sit apart.
add "reads a credential file through find"  "${A}find\b[^|;&]*${DOTFILES}[^|;&]*-(exec|execdir|ok|okdir)\s+${READERS}\b"
add "reads a credential file through find"  "${A}find\b[^|;&]*-(exec|execdir|ok|okdir)\s+${READERS}\s+[^|;&]*${DOTFILES}"
add "reads a credential file through xargs" "${DOTFILES}[^;&]*\|\s*xargs\b[^|;&]*\s${READERS}\b"
add "sources a credential file"             "${A}${DOTSOURCE}\s+[^|;&]*${DOTFILES}"
add "prints the environment"                "${A}${ENV_DUMP}"
add "prints the environment"                "${A}${JQ_ENV}"
add "prints the environment"                "${A}${AWK_ENV}"
add "prints a secret variable"              "(echo|printf)\b[^|;&]*${SECRET_VAR_CONTAINS}"
add "prints a secret variable"              "(echo|printf)\b[^|;&]*${SECRET_VAR_SUFFIX}"
add "reads a credential file"               "${REDIR_READ}"
add "reads a credential file"               "${DD_READ}"
add "uploads a local file"                  "${A}${NET_EXFIL_FILE}"
add "sends a secret variable"               "(curl|wget)\b[^|;&]*${SECRET_VAR_CONTAINS}"
add "sends a secret variable"               "(curl|wget)\b[^|;&]*${SECRET_VAR_SUFFIX}"
add "opens a raw socket"                    "${A}${SOCKETS}"
add "evaluates an environment dump"         "${A}${EVAL_ENV}"

block() {   # block WHY MATCH
  local m
  m=$(printf '%s' "$2" | head -1 | sed -E 's/^[|&;`$([:space:]]+//; s/[|&;`)>[:space:]]+$//' | cut -c1-80)
  emit_deny "Blocked: \`$m\` $1. Reference variables by name in code; do not print, dump, or transmit their values."
  exit 0
}

for i in "${!BLOCKED[@]}"; do
  P=${BLOCKED[$i]}
  T=$SCAN; [[ "$P" == *"$DOTFILES"* ]] && T=$SCAN_LC
  M=$(printf '%s\n' "$T" | grep -oE "$P") && block "${WHY[$i]}" "$M"
done

# jq and yq read files like any reader, but their first operand is a filter,
# and `.env.X` there is a key: `jq -r '.env.FOO' settings.json` is how this
# harness's own env block gets read. Drop options and the filter, then test
# only the file operands. Words split as the shell would (xargs), so a quoted
# filter is one word; naive splitting if its quotes do not balance.
case "$SCAN" in *jq*|*yq*)
  while IFS= read -r seg; do
    # Each segment opens with its boundary (| ; && $( or a backtick), then jq.
    rest=$(printf '%s' "$seg" | sed -E 's/^[^a-z]*(jq|yq)[[:space:]]+//')
    W=()
    if toks=$(printf '%s' "$rest" | xargs printf '%s\n' 2>/dev/null); then
      while IFS= read -r w; do W+=("$w"); done <<<"$toks"
    else
      set -f; read -ra W <<<"$rest"; set +f
    fi
    i=0; from_file=0
    while [[ $i -lt ${#W[@]} ]]; do
      case "${W[$i]}" in
        --arg|--argjson|--slurpfile|--rawfile) i=$((i+3)) ;;
        --indent|-L) i=$((i+2)) ;;
        -f|--from-file) from_file=1; i=$((i+2)) ;;
        --args|--jsonargs) i=${#W[@]} ;;
        -*) i=$((i+1)) ;;
        *) break ;;
      esac
    done
    [[ $from_file == 0 ]] && i=$((i+1))
    for w in "${W[@]:$i}"; do
      # Spaces plus filter syntax: a nested filter, as in <(jq '… ["~/.ssh"]'), not a path.
      case "$w" in *[[:space:]]*) case "$w" in *'{'*|*'['*|*'('*|*'='*|*'|'*|*%7C*) continue ;; esac ;; esac
      printf '%s\n' "$w" | grep -qE "$DOTFILES" && block "reads a credential file" "jq … $w"
    done
  done < <(printf '%s\n' "$SCAN" | grep -oE "${A}(jq|yq)\s[^|;&]*")
esac

exit 0
