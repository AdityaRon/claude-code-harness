#!/usr/bin/env bash
# Blocks Read/Edit/Write/Grep tool calls targeting .env files and credentials.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
FILE=$(jq_get '.tool_input.file_path')
[[ -z "$FILE" ]] && FILE=$(jq_get '.tool_input.path')
[[ -z "$FILE" ]] && FILE=$(jq_get '.tool_input.notebook_path')

# Grep names its target differently from the file tools: `path` (a file OR a
# directory, read above) and `glob` (which files under it to search). Its
# third field, `pattern`, is the text being searched FOR — never a target, so
# grepping source for the string `process.env.API_KEY` stays an ordinary read.
GLOB=$(jq_get '.tool_input.glob')

[[ -z "$FILE" && -z "$GLOB" ]] && exit 0

BLOCKED=(
  '\.env$'                     # .env, prod.env, local.env (any *.env)
  '(^|/)\.env\.'               # .env.local, .env.production
  '(^|/)\.envrc$'
  '\.pem$'
  '\.key$'
  '(^|/)id_rsa'
  '(^|/)id_ed25519'
  '\.aws/credentials'
  '(^|/)\.netrc$'
  # Config-shaped secret files only — not secrets.py / secrets.ts (source code).
  '(^|/)secrets\.(ya?ml|json|txt|env|cfg|conf|ini|properties|toml|enc)'
  '(^|/)\.npmrc$'
  '(^|/)\.pypirc$'
  '(^|/)\.git-credentials$'
  '(^|/)\.pgpass$'
  '(^|/)\.kube/config$'
  '(^|/)\.ssh/config$'
  '(^|/)\.docker/config\.json$'
  '(^|/)credentials\.json$'
  'service[_-]account.*\.json$'
)

# Directories whose whole purpose is credentials. A Read of a directory is not
# a thing, but a Grep of one prints every file inside it, which is the same
# disclosure by a different route — each of these holds a file already on the
# blocklist above.
CRED_DIRS=(
  '(^|/)\.ssh/?$'
  '(^|/)\.aws/?$'
  '(^|/)\.gnupg/?$'
  '(^|/)\.kube/?$'
)

# Committed template files (.env.example, credentials.json.sample, …) are safe
# to read/edit/commit — never a real secret.
is_template() {
  printf '%s\n' "$1" | grep -qE '\.(example|sample|template|dist|tpl)$'
}

matches_any() {
  local target="$1"; shift
  local p
  for p in "$@"; do
    printf '%s\n' "$target" | grep -qE "$p" && return 0
  done
  return 1
}

# --- The path (file_path / path / notebook_path) ------------------------
if [[ -n "$FILE" ]] && ! is_template "$FILE"; then
  # Canonicalize to defeat symlink / /private/var bypass attempts.
  CANON=$(canonical_path "$FILE")
  if matches_any "$FILE" "${BLOCKED[@]}" || matches_any "$CANON" "${BLOCKED[@]}"; then
    emit_deny "Blocked: $FILE is a sensitive credentials file. Read env values from process.env in code — do not open the file directly."
    exit 0
  fi
  if matches_any "$FILE" "${CRED_DIRS[@]}" || matches_any "$CANON" "${CRED_DIRS[@]}"; then
    emit_deny "Blocked: $FILE is a credentials directory, and searching it prints the keys inside. Name the specific non-secret file you need."
    exit 0
  fi
fi

# --- The glob (Grep) ----------------------------------------------------
# A glob is a pattern, not a path, so it is matched in de-globbed form:
# `*.env` and `**/.env*` both reduce to something ending in `.env`, which the
# blocklist already knows. Brace groups are expanded first, one level, which
# is all a real glob carries — otherwise `*.{env,ts}` reduces to `.{env,ts}`
# and matches nothing. Canonicalization is meaningless here and is skipped.
if [[ -n "$GLOB" ]]; then
  CANDIDATES=("$GLOB")
  if [[ "$GLOB" == *"{"*"}"* ]]; then
    PRE="${GLOB%%\{*}"
    BODY="${GLOB#*\{}"; BODY="${BODY%%\}*}"
    POST="${GLOB#*\}}"
    CANDIDATES=()
    OPTS=()
    IFS=',' read -ra OPTS <<<"$BODY"
    for O in "${OPTS[@]}"; do CANDIDATES+=("${PRE}${O}${POST}"); done
  fi
  for C in "${CANDIDATES[@]}"; do
    DEGLOB=$(printf '%s' "$C" | tr -d '*?')
    [[ -z "$DEGLOB" ]] && continue
    is_template "$DEGLOB" && continue
    if matches_any "$DEGLOB" "${BLOCKED[@]}"; then
      emit_deny "Blocked: the glob $C selects credential files, and a content search prints them. Narrow the glob to the source files you mean."
      exit 0
    fi
  done
fi

exit 0
