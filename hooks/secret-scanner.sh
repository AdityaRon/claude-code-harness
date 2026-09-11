#!/usr/bin/env bash
# Scans Write / Edit payloads for high-confidence secret shapes before they
# hit disk. Denies on match and nudges Claude to use an env var instead.
#
# Only high-signal patterns are included — entropy-based "is this an AWS
# secret access key" heuristics false-positive too often on source code.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
TOOL=$(jq_get '.tool_name')

case "$TOOL" in
  Write)         CONTENT=$(jq_get '.tool_input.content') ;;
  Edit)          CONTENT=$(jq_get '.tool_input.new_string') ;;
  MultiEdit)     CONTENT=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.edits[]?.new_string // ""' 2>/dev/null) ;;
  NotebookEdit)  CONTENT=$(jq_get '.tool_input.new_source') ;;
  *)             exit 0 ;;
esac

[[ -z "$CONTENT" ]] && exit 0

# Each entry: "label::regex". Keep regexes ERE-compatible.
PATTERNS=(
  'AWS Access Key ID::AKIA[0-9A-Z]{16}'
  'AWS Session/Temp Key::ASIA[0-9A-Z]{16}'
  'GitHub PAT (classic)::ghp_[A-Za-z0-9]{36}'
  'GitHub OAuth token::gho_[A-Za-z0-9]{36}'
  'GitHub user-server token::ghu_[A-Za-z0-9]{36}'
  'GitHub server-server token::ghs_[A-Za-z0-9]{36}'
  'GitHub refresh token::ghr_[A-Za-z0-9]{36}'
  'Slack bot/app token::xox[baprs]-[A-Za-z0-9-]{10,}'
  'Google API key::AIza[0-9A-Za-z_-]{35}'
  'Stripe live key::sk_live_[A-Za-z0-9]{24,}'
  'Stripe test key::sk_test_[A-Za-z0-9]{24,}'
  'JWT::eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  'PEM private key header::-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY-----'
  'SSH private key header::-----BEGIN OPENSSH PRIVATE KEY-----'
  'Anthropic API key::sk-ant-[A-Za-z0-9-]{20,}'
  'OpenAI API key::sk-[A-Za-z0-9]{40,}'
  'OpenAI project key::sk-proj-[A-Za-z0-9_-]{20,}'
  'Slack incoming webhook::https://hooks\.slack\.com/services/[A-Za-z0-9/_+-]{20,}'
  'GCP service account key::"type":\s*"service_account"'
  'GCP private key field::"private_key":\s*"-----BEGIN'
)

for entry in "${PATTERNS[@]}"; do
  label="${entry%%::*}"
  regex="${entry##*::}"
  if printf '%s' "$CONTENT" | grep -qE -- "$regex"; then
    emit_deny "Blocked: content being written contains what looks like a $label. Do not paste secrets into files — reference them via environment variables (process.env / os.environ) and add the variable name to .env.example without a value."
    exit 0
  fi
done

exit 0
