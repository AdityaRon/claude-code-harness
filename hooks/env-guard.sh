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

# Committed template files (.env.example / .sample / .template / .dist / .tpl)
# are safe to read, copy, and commit — neutralize them before matching so they
# don't trip the .env patterns below.
SCAN=$(printf '%s' "$CMD" | sed -E 's/\.env\.(example|sample|template|dist|tpl)/.envTEMPLATE/g')

# Command boundary: start-of-line, pipe, logical chain, subshell, semicolon, &.
A='(^|[|&;]|&&|\|\||\$\(|`)\s*'

# Readers / dumpers targeting .env* or ~/.aws/credentials or ~/.netrc.
READERS='(cat|less|more|head|tail|xxd|od|strings|nl|awk|sed|grep|rg|base64|gpg|openssl\s+enc|source|tac|cut|paste)'
# Copy/move/duplicate a dotfile elsewhere (stage-then-exfil in a later command).
COPIERS='(cp|mv|install|tee|ln)'
# Bash dot-source shortcut: `. <file>`
DOTSOURCE='\.'
# Credential files. Kept in sync with sensitive-file-guard so the Read/Edit/Write
# path and the Bash path block the same set (cat ~/.git-credentials etc.).
DOTFILES='(\.env(\b|\.)|\.envrc\b|\.aws/credentials|\.netrc\b|id_rsa\b|id_ed25519\b|\.pem\b|\.key\b|\.git-credentials\b|\.npmrc\b|\.pgpass\b|\.kube/config|\.docker/config\.json)'

# Env dumpers (whole-command or chained).
ENV_DUMP='(printenv|^env$|^env\b[^=]*$|^export\s*$|^set\s*$|declare\s+-(p|x)\b|compgen\s+-e)'

# A $VAR whose NAME signals a secret: contains SECRET/PASSWORD anywhere, or ends
# in KEY/TOKEN/CREDENTIAL(S) as a trailing segment (preceded by _ or var start).
# Deliberately does NOT treat bare API/AUTH/KEY substrings as secret, so common
# vars like $API_URL, $SSH_AUTH_SOCK, $DONKEY are not flagged.
SECRET_VAR_CONTAINS='\$\{?[A-Za-z0-9_]*(SECRET|PASSWORD|PASSWD)'
SECRET_VAR_SUFFIX='\$\{?([A-Za-z0-9_]*_)?(KEY|TOKEN|CREDENTIALS?)([^A-Za-z0-9_]|$)'

# Reading a dotfile via input redirection, with no reader command at all.
#   while read l; do …; done < .env      cmd < .aws/credentials
REDIR_READ="<\s*['\"]?[^|;&<>]*${DOTFILES}"

# dd reading a dotfile:  dd if=.env of=/tmp/x
DD_READ="\bdd\b[^|;&]*if=[^|;&]*${DOTFILES}"

# curl/wget uploading a LOCAL FILE as the body (@file) or via -T/--upload-file.
# Plain POSTs (-d name=foo) are left to network-guard's "ask"; only the exfil
# shapes are hard-denied here. Secret-var exfil is caught by the VAR rules.
NET_EXFIL_FILE='(curl|wget)\b[^|;&]*((-d|--data|--data-binary|--data-urlencode|--data-raw|--post-data)(=|\s)*@|(-F|--form|--post-file)\s+[^|;&@]*@|(-T|--upload-file)\b)'

# Sockets.
SOCKETS='\b(nc|ncat|socat)\b'

# Eval / indirect execution of env-dumping content.
EVAL_ENV='\beval\b[^|;&]*\$\(.*(printenv|env\b|cat\b)'

BLOCKED=(
  "${A}${READERS}\s+[^|;&]*${DOTFILES}"
  "${A}${COPIERS}\s+[^|;&]*${DOTFILES}"
  "${A}${DOTSOURCE}\s+[^|;&]*${DOTFILES}"
  "${A}${ENV_DUMP}"
  "(echo|printf)\b[^|;&]*${SECRET_VAR_CONTAINS}"
  "(echo|printf)\b[^|;&]*${SECRET_VAR_SUFFIX}"
  "${REDIR_READ}"
  "${DD_READ}"
  "${A}${NET_EXFIL_FILE}"
  "(curl|wget)\b[^|;&]*${SECRET_VAR_CONTAINS}"
  "(curl|wget)\b[^|;&]*${SECRET_VAR_SUFFIX}"
  "${A}${SOCKETS}"
  "${A}${EVAL_ENV}"
)

for P in "${BLOCKED[@]}"; do
  if printf '%s\n' "$SCAN" | grep -qE "$P"; then
    emit_deny "Blocked: command may read or exfiltrate sensitive env values / dotfiles. Reference variables by name in code; do not print, dump, or transmit their values."
    exit 0
  fi
done

exit 0
