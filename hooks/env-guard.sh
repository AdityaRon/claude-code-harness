#!/usr/bin/env bash
# Blocks bash commands that would print, read, or transmit env variable values
# and dotfile secrets. Most patterns start at a command boundary (line start,
# pipe, chain, $(…), backticks), so a word in another program's arguments does
# not match. A grep pattern or a sed or awk script that opens no file is text.
# Matching is still textual: the same words in another quoted string can match.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0
# Every pattern below needs one of these words. Normalizing drops quotes,
# backslashes and case but never adds a letter, so a command without any of
# them once those are gone cannot match, and is done before ~65 ms of work.
# 91% of 5,919 logged commands on one Mac exit here.
printf '%s\n' "$CMD" | tr -d '"'\''\\' | grep -qiE '\.env|environ|(^|[^a-z0-9_])(env|printenv|export|set|declare|compgen|nc|ncat|socat|eval|dd)([^a-z0-9_]|$)|\.aws|\.netrc|id_(rsa|dsa|ecdsa|ed25519)|\.pem|\.key|credential|\.npmrc|\.pgpass|\.kube|\.docker|\.pypirc|\.ssh|\.gnupg|gcloud|\.azure|kubeconfig|\.claude\.json|service[_-]account|tfstate|tfvars|\.(p12|pfx|jks|keystore)|hosts\.yml|secret|passw|[$_{]key|token|curl|wget' || exit 0
# A commit message or a notes file is text, not a command (lib.sh).
CMD=$(strip_inert_heredocs "$CMD")

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
# grep and rg take a pattern first, and sed and awk a script: `grep -rn '\.env'
# src/` searches for text and `sed -i 's/cert.pem/tls.pem/' f` edits it. For the
# reader check that operand becomes PATTERN, after a wrapper (`| xargs -0 grep`)
# and options that take no value; -e, -f, --include and the rest keep the line.
GOPT='(-[cFHhiLlnoqsvwxrREPIaZz]+|--colou?r(=[a-z]+)?|--(line-number|ignore-case|count|files-with-matches|no-heading|with-filename|no-filename|recursive|fixed-strings|word-regexp|only-matching|smart-case|hidden|invert-match|extended-regexp))'
SOPT="(-[nErsuz]+|-[nErsuz]*i(\\.[A-Za-z0-9_~-]+)?([[:space:]]+(''|\"\"))?|--(quiet|silent|posix|regexp-extended|separate|unbuffered|null-data|debug)|--in-place(=[^[:space:]]*)?)"
AOPT=$'(-F[[:space:]]*(\'[^\']*\'|"[^"]*"|[^[:space:]\'"]+)|-v[[:space:]]*(\'[^\']*\'|"[^"]*"|[^[:space:]\'"]+)|--)'
GPAT=$'\'[^\']*\'|"[^"$`]*"|[^-[:space:]\'"|;&$`<>()][^[:space:]\'"|;&$`<>()]*'
OP_WRAP='((env|command|builtin|exec|nice|ionice|time|nohup|sudo|doas|timeout|stdbuf|caffeinate|xargs)[[:space:]]([^|;&]*[[:space:]])?)?'
AWK_IO='getline|system|ARGV|ARGC|ENVIRON|@include|@load|[|]'
SED_LEAD='[![:space:];{}!]'

# Drop s up to and past the first $1 that no backslash escapes.
skip_to() {
  local pre bs rest=$s
  [[ -n "$1" ]] || return 1
  while [[ "$rest" == *"$1"* ]]; do
    pre=${rest%%"$1"*}; rest=${rest#*"$1"}
    bs=${pre##*[!\\]}
    (( ${#bs} % 2 == 0 )) && { s=$rest; return 0; }
  done
  return 1
}

# 0 when script $2 of a $1 (sed or awk) cannot open a file. sed: addresses,
# s and y without a w or e flag, { and p d n N g G h H x l q =; r R w W e or
# anything else keeps the deny. awk: none of getline, system, ARGV, a pipe ….
text_only() {
  local s=$2 c d k
  s=${s//%3B/;}; s=${s//%7C/|}; s=${s//%26/&}
  [[ "$1" == awk ]] && { [[ ! "$s" =~ $AWK_IO ]]; return; }
  while :; do
    s=${s#"${s%%$SED_LEAD*}"}
    [[ -z "$s" ]] && return 0
    while :; do
      case "$s" in
        [0-9\$]*) s=${s#"${s%%[!0-9\$]*}"} ;;
        /*) s=${s:1}; skip_to / || return 1 ;;
        \\?*) d=${s:1:1}; s=${s:2}; skip_to "$d" || return 1 ;;
        *) break ;;
      esac
      case "$s" in [,~]*) s=${s:1} ;; *) break ;; esac
    done
    s=${s#"${s%%[![:space:]!]*}"}
    c=${s:0:1}; s=${s:1}
    case "$c" in
      s|y) d=${s:0:1}; s=${s:1}; skip_to "$d" && skip_to "$d" || return 1
           [[ "$c" == s ]] && { k=${s%%[!gpiImM0-9we]*}; [[ "$k" == *[we]* ]] && return 1; s=${s:${#k}}; } ;;
      [pdnNgGhHxlq=\{]) ;;
      *) return 1 ;;
    esac
  done
}

# Set LINE to LINE with each text operand of tools $1 (options $2, kind $3) as
# PATTERN. The greedy prefix finds the last one first, then the loop moves left.
drop_operands() {
  local cur=$LINE out="" re m n tok q trail head
  re="^((.*([|&;]|\\\$\\(|\`))?)([[:space:]]*${OP_WRAP}($1)([[:space:]]+$2)*[[:space:]]+)(${GPAT})([[:space:]]|\$)"
  while [[ "$cur" =~ $re ]]; do
    m=${BASH_REMATCH[0]}; n=${#BASH_REMATCH[@]}
    tok=${BASH_REMATCH[$((n - 2))]}; trail=${BASH_REMATCH[$((n - 1))]}
    head=${m:${#BASH_REMATCH[1]}}; head=${head:0:$(( ${#head} - ${#tok} - ${#trail} ))}
    q=$tok; [[ "$q" == [\'\"]* ]] && q=${q:1:${#q}-2}
    if [[ "$3" == grep ]] || text_only "$3" "$q"; then tok=PATTERN; fi
    out=$head$tok$trail${cur:${#m}}$out
    cur=${BASH_REMATCH[1]}
  done
  LINE=$cur$out
}

# Set SCAN_R_LC, SCAN_LC with the operands dropped. Run only for a reader that
# already matched: dropping text never adds a match.
SCAN_R_LC=""
drop_text_operands() {
  local SCAN_R="" LINE
  while IFS= read -r LINE; do
    case "$LINE" in *grep*|*rg*) drop_operands 'grep|egrep|fgrep|rg' "$GOPT" grep ;; esac
    case "$LINE" in *sed*) drop_operands 'sed|gsed' "$SOPT" sed ;; esac
    case "$LINE" in *awk*) drop_operands 'awk|gawk|mawk|nawk' "$AOPT" awk ;; esac
    SCAN_R+=$LINE$'\n'
  done <<<"$SCAN"
  SCAN_R_LC=$(printf '%s\n%s' "$SCAN_R" "$(printf '%s' "$SCAN_R" | tr 'A-Z' 'a-z')")
}

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
# `xargs -a FILE` turns each line of FILE into an argument, which any command prints.
add "reads a credential file through xargs" "${A}${WRAP}xargs\b[^|;&]*\s(-a|--arg-file)(=|\s*)['\"]?[^|;&[:space:]'\"]*${DOTFILES}"
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

# One grep over every pattern first: SCAN_LC holds the other two texts (the
# operand rewrite only removes tokens), so a miss here is a miss for all
# twenty, which otherwise cost a fork each.
ALLP=""; for P in "${BLOCKED[@]}"; do ALLP="${ALLP:+$ALLP|}$P"; done
if printf '%s\n' "$SCAN_LC" | grep -qE "$ALLP"; then
  for i in "${!BLOCKED[@]}"; do
    P=${BLOCKED[$i]}
    T=$SCAN; [[ "$P" == *"$DOTFILES"* ]] && T=$SCAN_LC
    if [[ "$P" == "${A}${WRAP}${READERS}"* ]]; then
      printf '%s\n' "$SCAN_LC" | grep -qE "$P" || continue
      [[ -n "$SCAN_R_LC" ]] || drop_text_operands
      T=$SCAN_R_LC
    fi
    M=$(printf '%s\n' "$T" | grep -oE "$P") && block "${WHY[$i]}" "$M"
  done
fi

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
