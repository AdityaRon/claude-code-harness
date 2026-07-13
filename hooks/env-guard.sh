#!/usr/bin/env bash
# Blocks bash commands that would print, read, or transmit env variable values
# and dotfile secrets. All patterns are anchored to command boundaries
# (line start, pipe, chain, heredoc, $(…), backticks) so that occurrences
# inside commit messages, single-quoted strings, and literal arguments to
# unrelated programs do not false-positive.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

# Command boundary: start-of-line, pipe, logical chain, subshell, semicolon, &.
A='(^|[|&;]|&&|\|\||\$\(|`)\s*'

# Readers / dumpers targeting .env* or ~/.aws/credentials or ~/.netrc.
READERS='(cat|less|more|head|tail|xxd|od|strings|nl|awk|sed|grep|rg|base64|gpg|openssl\s+enc|source|tac|cut|paste)'
# Copy/move/duplicate a dotfile elsewhere (stage-then-exfil in a later command).
COPIERS='(cp|mv|install|tee|ln)'
# Bash dot-source shortcut: `. <file>`
DOTSOURCE='\.'
DOTFILES='(\.env(\b|\.)|\.envrc\b|\.aws/credentials|\.netrc\b|id_rsa\b|id_ed25519\b|\.pem\b|\.key\b)'

# Env dumpers (whole-command or chained).
ENV_DUMP='(printenv|^env$|^env\b[^=]*$|^export\s*$|^set\s*$|declare\s+-(p|x)\b|compgen\s+-e)'

# Printing a secret-ish env var value to stdout (leaks it into the transcript).
#   echo $AWS_SECRET_ACCESS_KEY   printf %s "$OPENAI_API_KEY"
PRINT_VAR='(echo|printf)\b[^|;&]*\$\{?[A-Za-z_]*(TOKEN|KEY|SECRET|PASSWORD|PASSWD|API|AUTH|CREDENTIAL)'

# Reading a dotfile via input redirection, with no reader command at all.
#   while read l; do …; done < .env      cmd < .aws/credentials
REDIR_READ="<\s*['\"]?[^|;&<>]*${DOTFILES}"

# dd reading a dotfile:  dd if=.env of=/tmp/x
DD_READ="\bdd\b[^|;&]*if=[^|;&]*${DOTFILES}"

# curl/wget exfil: body/data flags OR URL containing a KEY/TOKEN/SECRET/PASSWORD-ish var expansion.
NET_EXFIL_BODY='(curl|wget)\b[^|;&]*(--data-binary|--data-urlencode|--data|--data-raw|-d\b|-F\b|--form|--upload-file|--post-data|-T\b)'
NET_EXFIL_VAR='(curl|wget)\b[^|;&]*\$\{?[A-Z_]*(TOKEN|KEY|SECRET|PASSWORD|PASSWD|API|AUTH)'

# Sockets.
SOCKETS='\b(nc|ncat|socat)\b'

# Eval / indirect execution of env-dumping content.
EVAL_ENV='\beval\b[^|;&]*\$\(.*(printenv|env\b|cat\b)'

BLOCKED=(
  "${A}${READERS}\s+[^|;&]*${DOTFILES}"
  "${A}${COPIERS}\s+[^|;&]*${DOTFILES}"
  "${A}${DOTSOURCE}\s+[^|;&]*${DOTFILES}"
  "${A}${ENV_DUMP}"
  "${A}${PRINT_VAR}"
  "${REDIR_READ}"
  "${DD_READ}"
  "${A}${NET_EXFIL_BODY}"
  "${A}${NET_EXFIL_VAR}"
  "${A}${SOCKETS}"
  "${A}${EVAL_ENV}"
)

for P in "${BLOCKED[@]}"; do
  if printf '%s\n' "$CMD" | grep -qE "$P"; then
    emit_deny "Blocked: command may read or exfiltrate sensitive env values / dotfiles. Reference variables by name in code; do not print, dump, or transmit their values."
    exit 0
  fi
done

exit 0
