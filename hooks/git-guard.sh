#!/usr/bin/env bash
# Blocks dangerous git operations that bypass other guards:
#   1. force-push variants
#   2. indiscriminate staging (git add . / -A / --all / '*')
#   3. staging sensitive file patterns
#   4. git config tampering (core.hooksPath, user.email, etc.)
#   5. writes into .git/hooks/*
#   6. remote redirection (git remote set-url / add origin)
#   7. push --delete / push :branch (remote branch deletion)
#   8. history rewrites (filter-branch, update-ref)
#   9. glob staging ('*.env'-style patterns)
#
# All regexes are anchored to command boundaries so text inside commit
# messages, heredocs, and single-quoted strings does not false-positive.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

A='(^|[|&;]|&&|\|\||\$\(|`)\s*'

# Global options that git accepts BETWEEN `git` and the subcommand. Left
# unhandled, any of these (e.g. `git -c k=v push --force`, `git -C dir add .`)
# breaks the `git\s+<subcmd>` adjacency and slips past every check below —
# and `-c core.hooksPath=…` is itself a code-exec vector. GOPT matches one
# such option (with its argument); GIT allows zero or more before the subcommand.
GOPT='(-c[= ][^ ]+|-C[= ][^ ]+|--git-dir[= ][^ ]+|--work-tree[= ][^ ]+|--namespace[= ][^ ]+|--exec-path([= ][^ ]+)?|--no-pager|--bare|--literal-pathspecs|-p|-P)'
GIT="git(\s+${GOPT})*\s+"

# --- core.hooksPath via -c on ANY subcommand ----------------------------
# `git -c core.hooksPath=/tmp/evil <anything>` points hooks at an attacker
# dir for that invocation, running arbitrary code on the next hook trigger.
# Config keys are case-insensitive, so match case-insensitively.
if printf '%s\n' "$CMD" | grep -qiE "${A}git\b[^|;&]*-c[= ]core\.hookspath"; then
  emit_deny "Blocked: -c core.hooksPath redirects git hooks to an arbitrary directory (code-execution vector). Not permitted."
  exit 0
fi

# --- Force-push guard ---------------------------------------------------
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}push\s.*(-f\b|--force\b|--force-with-lease\b)"; then
  emit_deny "Blocked: force-push is not allowed. Use regular git push, or ask the user to run this manually."
  exit 0
fi

# --- Remote branch deletion (push --delete OR push <remote> :branch) ----
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}push\s.*(--delete\b|\s:[A-Za-z0-9._/-]+)"; then
  emit_ask "Deleting a remote branch with git push. Confirm the branch name is correct before proceeding."
  exit 0
fi

# --- Indiscriminate staging --------------------------------------------
# Catches: git add . | ./ | -A | --all | -- . (and with -C/-c prefixes).
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}add\s+(--\s+)?(-A|--all|\.\/?)([[:space:]]|;|&|\||$)"; then
  emit_deny "Blocked: broad git add (., ./, -A, --all) may stage sensitive files. Stage files by name instead."
  exit 0
fi

# --- Glob staging ('*', '*.env', etc.) ---------------------------------
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}add\s+[^|;&]*['\"]?\*"; then
  emit_ask "git add uses a glob pattern. This may unintentionally stage secrets — confirm the expanded file list first."
  exit 0
fi

# --- Sensitive file staging --------------------------------------------
SENSITIVE=(
  '\.env(\s|$)'
  '\.env\.'
  '\.envrc(\s|$)'
  '\.pem(\s|$)'
  '\.key(\s|$)'
  'id_rsa'
  'id_ed25519'
  '\.aws/credentials'
  '\.netrc(\s|$)'
  'secrets\.'
)
for P in "${SENSITIVE[@]}"; do
  if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}add\s.*${P}"; then
    emit_deny "Blocked: git add targets a sensitive file. Do not stage credentials or secret files."
    exit 0
  fi
done

# --- Git config tampering ----------------------------------------------
# core.hooksPath redirection, user.name/email spoofing, gpg.signingkey swap.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}config\s+.*core\.hooksPath"; then
  emit_deny "Blocked: changing core.hooksPath disables or redirects git hooks. Not permitted."
  exit 0
fi
# Malicious alias: a `!`-prefixed alias value is arbitrary shell run on the
# next `git <alias>` — a persistence/exec vector as dangerous as .git/hooks.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}config\s+[^|;&]*alias\.[A-Za-z0-9_.-]+\s+['\"]?[[:space:]]*!"; then
  emit_deny "Blocked: git alias defined with a shell-command (!) body executes arbitrary code on the next git invocation. Not permitted."
  exit 0
fi
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}config\s+[^|;&]*alias\."; then
  emit_ask "git config is defining an alias. Confirm the alias body is safe (a leading '!' would run a shell command)."
  exit 0
fi
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}config\s+.*(user\.(name|email|signingkey)|gpg\.signingkey|commit\.gpgsign|tag\.gpgsign)"; then
  emit_ask "git config is changing identity or signing settings. Confirm this is intended."
  exit 0
fi

# --- Writes into .git/hooks/* ------------------------------------------
if printf '%s\n' "$CMD" | grep -qE "(\.git/hooks/|/\.git/hooks/)"; then
  emit_deny "Blocked: writing into .git/hooks can install a persistent payload. Not permitted."
  exit 0
fi

# --- Remote redirection ------------------------------------------------
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}remote\s+(set-url|add)\b"; then
  emit_ask "git remote is being set or added. Confirm the URL points where you expect — redirecting origin is a common exfiltration vector."
  exit 0
fi

# --- History rewrites --------------------------------------------------
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}(filter-branch|filter-repo|update-ref|reflog\s+expire)\b"; then
  emit_deny "Blocked: history-rewriting or ref-deleting commands. Run manually if truly needed."
  exit 0
fi

exit 0
