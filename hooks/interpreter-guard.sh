#!/usr/bin/env bash
# Interpreter-bypass guard.
#
# Wildcard allows for python/node/ruby/perl/php/bash -c let Claude sidestep
# every regex-based guard by writing a tiny script that reads env vars or
# dotfiles. This hook inspects inline-code flags (-c, -e, --eval, combined
# short flags like -ne, -r, a trailing -, and heredoc payloads) and denies
# when the payload references env vars, dotfile paths, raw sockets, or
# network exfil APIs.
#
# The hook is conservative: only triggers when BOTH an interpreter is used
# AND the payload contains a sensitive token. Running "python script.py"
# or "node server.js" is untouched.
#
# This raises the bar but is NOT airtight: string-obfuscated payloads
# (getattr(os, "en"+"viron"), base64/hex-encoded source) can still evade a
# token list. The OS sandbox is the real containment for that class — see
# README "Enable the OS sandbox".
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

A='(^|[|&;]|&&|\|\||\$\(|`)\s*'

# Interpreters that commonly accept inline code.
INTERP='(python3?|node|ruby|perl|php|bash|sh|zsh|deno|bun)'

# Inline-code flags. The `-[A-Za-z]*[ce]` form catches combined short flags
# (perl -ne, perl -pe, ruby -ne) that would evade a bare -c/-e. -r is php/ruby
# inline. A trailing "-" means "read from stdin".
INLINE='(-[A-Za-z]*[ce]\b|--eval\b|--exec\b|-r\b|\s-(\s|$))'

# Sensitive tokens that should not appear inside inline code payloads.
# (Matches both source-code references and network exfil APIs.)
SENSITIVE_TOKENS=(
  # env-var lookup APIs
  'os\.environ'
  'os\.getenv'
  'process\.env'
  'ENV\['
  'getenv\s*\('
  '\$ENV\{'
  # dotfile / credential paths
  '\.env\b'
  '\.envrc\b'
  '\.aws/credentials'
  '\.netrc\b'
  'id_rsa\b'
  'id_ed25519\b'
  # raw sockets / exfil
  'socket\.socket'
  'http\.client'
  'urllib\.request'
  'requests\.(post|put|patch)'
  'net\.Socket'
  'https?\.request'
  'fetch\s*\('
  # subprocess that re-invokes a shell (used to chain around the guard)
  'subprocess\.(Popen|run|call|check_output)'
  'child_process\b[^|;&]{0,40}(exec|spawn|fork)'
  'os\.system'
  'Kernel\.`'
  'IO\.popen'
  # bare commands that leak env, even when invoked via bash/sh -c
  '\bprintenv\b'
  '\bcompgen\s+-e\b'
  '\benv\b\s*$'
  '\bset\b\s*$'
  # base64 is a common wrapper for obfuscated payloads
  'base64\.(b64decode|decode)'
  'Buffer\.from\([^)]*[\x27"]base64'
)

# Does the command invoke an interpreter with inline code (flag) or a heredoc?
# Heredocs (python3 <<EOF … EOF) carry a payload with no -c flag, so match them
# too and let the token scan below inspect the heredoc body.
INTERP_INLINE_RE="${A}${INTERP}\s+[^|;&]*${INLINE}"
INTERP_HEREDOC_RE="${A}${INTERP}\b[^|;&]*<<-?"
if ! printf '%s\n' "$CMD" | grep -qE "$INTERP_INLINE_RE" \
   && ! printf '%s\n' "$CMD" | grep -qE "$INTERP_HEREDOC_RE"; then
  exit 0
fi

# Yes — scan the payload for sensitive tokens.
for T in "${SENSITIVE_TOKENS[@]}"; do
  if printf '%s\n' "$CMD" | grep -qE "$T"; then
    emit_deny "Blocked: interpreter invoked with inline code that references env vars, dotfiles, sockets, or subprocess-spawning APIs. Put the logic in a committed script so it can be reviewed."
    exit 0
  fi
done

# Interpreter with inline code but no obvious sensitive token — ask.
# This catches novel payloads without producing false positives on trivial
# one-liners like `python -c "print(1)"`.
if printf '%s\n' "$CMD" | grep -qE "${A}${INTERP}\s+.{120,}${INLINE}|${A}${INTERP}\s+[^|;&]*${INLINE}[^|;&]{200,}"; then
  emit_ask "Long inline script passed to an interpreter. Review the payload before running — inline code bypasses file-based review."
  exit 0
fi

exit 0
