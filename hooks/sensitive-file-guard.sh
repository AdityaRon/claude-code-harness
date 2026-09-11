#!/usr/bin/env bash
# Blocks Read/Edit/Write tool calls targeting .env files and credentials.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
FILE=$(jq_get '.tool_input.file_path')
[[ -z "$FILE" ]] && FILE=$(jq_get '.tool_input.path')
[[ -z "$FILE" ]] && FILE=$(jq_get '.tool_input.notebook_path')
[[ -z "$FILE" ]] && exit 0

# Canonicalize to defeat symlink / /private/var bypass attempts.
CANON=$(canonical_path "$FILE")

# Committed template files (.env.example, credentials.json.sample, …) are safe
# to read/edit/commit — never a real secret. Allow them before the blocklist.
if printf '%s\n' "$FILE" | grep -qE '\.(example|sample|template|dist|tpl)$'; then
  exit 0
fi

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

for P in "${BLOCKED[@]}"; do
  if printf '%s\n' "$FILE" | grep -qE "$P" || printf '%s\n' "$CANON" | grep -qE "$P"; then
    emit_deny "Blocked: $FILE is a sensitive credentials file. Read env values from process.env in code — do not open the file directly."
    exit 0
  fi
done

exit 0
