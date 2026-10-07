#!/usr/bin/env bash
# Blocks Read/Edit/Write/Grep tool calls targeting .env files and credentials.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
FILE=$(jq_get '.tool_input.file_path')
[[ -z "$FILE" ]] && FILE=$(jq_get '.tool_input.path')
[[ -z "$FILE" ]] && FILE=$(jq_get '.tool_input.notebook_path')

# Grep names its target differently from the file tools: `path` (a file OR a
# directory, read above) and `glob` (which files under it to search). Its
# third field, `pattern`, is the text being searched FOR — never a target, so
# grepping source for the string `process.env.API_KEY` stays an ordinary read.
GLOB=$(jq_get '.tool_input.glob')

TOOL=$(jq_get '.tool_name')

[[ -z "$FILE" && -z "$GLOB" && "$TOOL" != Grep ]] && exit 0

BLOCKED=(
  '\.env$'                     # .env, prod.env, local.env (any *.env)
  '(^|/)\.env\.'               # .env.local, .env.production
  '(^|/)\.envrc$'
  '\.pem$'
  '\.key$'
  '(^|/)id_(rsa|dsa|ecdsa|ed25519)'
  # Whole folders: ~/.ssh holds keys under any name, ~/.aws keeps SSO and CLI
  # token caches beside credentials, and gcloud and Azure keep tokens in theirs.
  '(^|/)\.ssh/'
  '(^|/)\.aws/'
  '(^|/)\.gnupg/'
  '(^|/)\.config/gcloud/'
  '(^|/)\.azure/'
  '(^|/)\.netrc$'
  # Config-shaped secret files only — not secrets.py / secrets.ts (source code).
  '(^|/)secrets\.(ya?ml|json|txt|env|cfg|conf|ini|properties|toml|enc)$'
  '(^|/)\.npmrc$'
  '(^|/)\.pypirc$'
  '(^|/)\.git-credentials$'
  '(^|/)\.pgpass$'
  '(^|/)\.kube/config$'
  '(^|/)kubeconfig(\.ya?ml)?$'
  '\.kubeconfig$'
  '(^|/)\.docker/config\.json$'
  '(^|/)credentials\.json$'
  'service[_-]account.*\.json$'
  '(^|/)\.credentials\.json$'   # ~/.claude: the Claude Code OAuth token
  '(^|/)\.claude\.json$'        # can hold an API key and MCP server tokens
  'terraform\.tfstate(\.backup)?$'
  '\.tfvars$'
  '\.(p12|pfx|jks|keystore)$'
  '(^|/)gh/hosts\.yml$'
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
  '(^|/)\.config/gcloud/?$'
  '(^|/)\.azure/?$'
)

# Committed template files (.env.example, credentials.json.sample, …) are safe
# to read/edit/commit — never a real secret.
is_template() {
  printf '%s\n' "$1" | grep -qE '\.(example|sample|template|dist|tpl)$'
}

# Without case: `.ENV` opens `.env` on the default macOS filesystem. is_template
# keeps its case, so `.env.EXAMPLE` stays blocked as it was.
# One grep over the alternation, not one per pattern: each fork cost ~2.5 ms, and
# this runs up to four times on every Read, Edit, Write and Grep.
matches_any() {
  local target="$1"; shift
  local IFS='|'
  printf '%s\n' "$target" | grep -qiE "($*)"
}

# --- The path (file_path / path / notebook_path) ------------------------
# Canonicalize first: a template name is safe only if what it resolves to is
# one too, so a link named x.env.example pointing at .env is not.
[[ -n "$FILE" ]] && CANON=$(canonical_path "$FILE")
if [[ -n "$FILE" ]] && ! { is_template "$FILE" && is_template "$CANON"; }; then
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

# --- Grep's reach -------------------------------------------------------
# A content search at or above $HOME reads every dotfile and key under it. The
# glob check above reads * and one level of braces; ? and [..] it cannot, so a
# glob using them asks rather than passes.
if [[ "$TOOL" == Grep ]]; then
  WHERE=${FILE:-$(jq_get '.cwd')}
  if [[ -n "$WHERE" ]]; then
    W=$(canonical_path "$WHERE"); HC=$(canonical_path "$HOME")
    case "$HC/" in "${W%/}/"*)
      emit_ask "Grep over ${WHERE} searches everything under your home folder, dotfiles and keys included. Point it at the folder you mean."
      exit 0 ;;
    esac
  fi
  case "$GLOB" in *'?'*|*'['*|*'{'*'{'*)
    emit_ask "The glob $GLOB uses ?, [..] or more than one brace group, which the credential check cannot read. Use * and plain names."
    exit 0 ;;
  esac
fi

exit 0
