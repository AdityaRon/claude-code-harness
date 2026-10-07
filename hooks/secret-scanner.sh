#!/usr/bin/env bash
# Scans Write / Edit payloads for high-confidence secret shapes before they
# hit disk. Denies on match and nudges Claude to use an env var instead.
#
# Only high-signal patterns are included — entropy-based "is this an AWS
# secret access key" heuristics false-positive too often on source code.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
TOOL=$(jq_get '.tool_name')
FILE=$(jq_get '.tool_input.file_path')

case "$TOOL" in
  # Claude Code 2.1.280 accepts file_text and file_content as aliases for content.
  Write)         CONTENT=$(jq_get '.tool_input.content // .tool_input.file_text // .tool_input.file_content') ;;
  Edit)          CONTENT=$(jq_get '.tool_input.new_string') ;;
  MultiEdit)     CONTENT=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.edits[]?.new_string // ""' 2>/dev/null) ;;
  NotebookEdit)  CONTENT=$(jq_get '.tool_input.new_source') ;;
  *)             exit 0 ;;
esac

[[ -z "$CONTENT" ]] && exit 0

# Each entry: "label::regex" or "label::regex::exempt". A match passes when every
# string it matched also matches exempt: the samples vendors publish in docs.
# Keep regexes ERE-compatible.
B='(^|[^A-Za-z0-9_-])'   # a key's start: `sk-` inside base64 or a longer word is not one
PATTERNS=(
  'AWS Access Key ID::AKIA[0-9A-Z]{16}::EXAMPLE$'
  'AWS Session/Temp Key::ASIA[0-9A-Z]{16}::EXAMPLE$'
  "AWS secret access key::(aws_secret_access_key|AWS_SECRET_ACCESS_KEY|[Ss]ecretAccessKey)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+=]{40}::EXAMPLEKEY"
  'GitHub PAT (classic)::ghp_[A-Za-z0-9]{36}'
  'GitHub fine-grained PAT::github_pat_[A-Za-z0-9_]{50,}'
  'GitHub OAuth token::gho_[A-Za-z0-9]{36}'
  'GitHub user-server token::ghu_[A-Za-z0-9]{36}'
  'GitHub server-server token::ghs_[A-Za-z0-9]{36}'
  'GitHub refresh token::ghr_[A-Za-z0-9]{36}'
  'GitLab token::glpat-[A-Za-z0-9_-]{20,}'
  'npm token::npm_[A-Za-z0-9]{36}'
  'Slack bot/app token::xox[baprs]-[A-Za-z0-9-]{10,}'
  'Slack app-level token::xapp-[0-9]+-[A-Za-z0-9-]{10,}'
  'Google API key::AIza[0-9A-Za-z_-]{35}'
  'Stripe live key::sk_live_[A-Za-z0-9]{24,}'
  'Stripe test key::sk_test_[A-Za-z0-9]{24,}'
  # The exempt signature is jwt.io's published sample, the one in every auth test.
  'JWT::eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}::SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c$'
  'PEM private key header::-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'
  'PGP private key block::-----BEGIN PGP PRIVATE KEY BLOC[K]-----'   # [K]: so this line is not one
  "Anthropic API key::${B}sk-ant-[A-Za-z0-9-]{20,}"
  "OpenAI API key::${B}sk-[A-Za-z0-9]{40,}"
  "OpenAI project key::${B}sk-proj-[A-Za-z0-9_-]{20,}"
  'Slack incoming webhook::https://hooks\.slack\.com/services/[A-Za-z0-9/_+-]{20,}'
  'GCP private key field::"private_key":[[:space:]]*"-----BEGIN'
  'Database URL with a password::(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?|rediss?|amqps?)://[^:/@[:space:]]+:[^@/[:space:]]{3,}@::://[^:/@[:space:]]+:(password|pass|passwd|secret|changeme|example|xxx+|\*+|<[^>]*>|\\?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)@'
)

ALL=""
for entry in "${PATTERNS[@]}"; do r=${entry#*::}; ALL="${ALL:+$ALL|}${r%%::*}"; done

hit() {   # hit TEXT: print the first label TEXT matches outside its exemption
  local entry label rest regex exempt m
  # One grep for the usual case, where nothing matches: twenty cost ~60 ms.
  printf '%s' "$1" | grep -qE -- "$ALL" || return 1
  for entry in "${PATTERNS[@]}"; do
    label=${entry%%::*}; rest=${entry#*::}; regex=${rest%%::*}; exempt=""
    [[ "$rest" == *::* ]] && exempt=${rest#*::}
    m=$(printf '%s' "$1" | grep -oE -- "$regex") || continue
    [[ -n "$exempt" ]] && m=$(printf '%s\n' "$m" | grep -vE -- "$exempt")
    [[ -n "$m" ]] && { printf '%s' "$label"; return 0; }
  done
  return 1
}

deny() {
  emit_deny "Blocked: content being written contains what looks like a $1. Do not paste secrets into files — reference them via environment variables (process.env / os.environ) and add the variable name to .env.example without a value."
  exit 0
}

L=$(hit "$CONTENT") && deny "$L"

# An Edit can finish a secret the file already starts: AKIA in one edit, the
# tail in the next. Scan each change with 120 characters either side, as it
# will be, and flag only what that text did not already hold.
if [[ "$TOOL" == Edit || "$TOOL" == MultiEdit ]] && [[ -f "$FILE" ]]; then
  while IFS= read -r -d '' was && IFS= read -r -d '' will; do
    L=$(hit "$will") && ! hit "$was" >/dev/null && deny "$L"
  done < <(printf '%s' "$INPUT" | jq -j --rawfile f "$FILE" '
      .tool_input | (if .edits then .edits[] else . end) | select((.old_string // "") != "")
      | .old_string as $o | (.new_string // "") as $n | ($f | split($o)) as $p | select(($p | length) > 1)
      | ($p[0][-120:]) as $pre | (($p[1:] | join($o))[:120]) as $post
      | ($pre + $o + $post), "\u0000", ($pre + $n + $post), "\u0000"' 2>/dev/null)
fi

exit 0
