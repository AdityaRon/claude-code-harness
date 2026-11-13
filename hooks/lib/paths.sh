#!/usr/bin/env bash
# hooks/lib.sh sources this: paths: ~ expansion, canonical paths, file hashes, credential file names.

# Expand leading ~ in a path; needed because the hook runtime passes env
# values verbatim without shell expansion.
expand_tilde() {
  local p="$1"
  printf '%s\n' "${p/#\~/$HOME}"
}

# SHA-256 of a file's contents. Empty output if file is missing or unreadable.
# Prefers shasum (macOS default), falls back to sha256sum (Linux default).
# sha256_files PATH...: "HASH  PATH" for each readable file, from one process.
sha256_files() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 -- "$@" 2>/dev/null
  elif command -v sha256sum &>/dev/null; then
    sha256sum -- "$@" 2>/dev/null
  fi
  return 0
}

sha256_file() {
  local p="$1"
  [[ -z "$p" || ! -f "$p" ]] && return 0
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$p" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$p" 2>/dev/null | awk '{print $1}'
  fi
}

# Credential file paths, as extended regexes matched without case. One list for
# sensitive-file-guard and git-guard's broad add, so the two cannot drift.
# shellcheck disable=SC2034  # read by the hooks that source this file
CREDENTIAL_FILES=(
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
  # Config-shaped secret files only, not secrets.py / secrets.ts (source code).
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

# Resolve a path to its canonical form (symlinks, /private/var aliases).
# Falls back gracefully when the path does not exist.
canonical_path() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  p=$(expand_tilde "$p")
  local out=""
  # GNU realpath: accepts nonexistent paths. BSD realpath (macOS default): does not,
  # but resolves symlinks when the target exists. Fall back to python3 for the
  # nonexistent case — python's os.path.realpath always returns a normalized path.
  if command -v realpath &>/dev/null; then
    out=$(realpath "$p" 2>/dev/null) || out=""
  fi
  if [[ -z "$out" ]] && command -v python3 &>/dev/null; then
    out=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null) || out=""
  fi
  [[ -z "$out" ]] && out="$p"
  printf '%s\n' "$out"
}
