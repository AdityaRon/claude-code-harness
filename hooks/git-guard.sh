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
#  10. destructive worktree ops (reset --hard, clean -f, branch -d/-D)
#
# All regexes are anchored to command boundaries so text inside commit
# messages, heredocs, and single-quoted strings does not false-positive.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0

# Strip assignment/wrapper prefixes before anything below matches. The anchor A
# admits only real command boundaries, so `VAR=1 git push -f`, `env FOO=bar git
# push -f`, `nohup git push -f` and `timeout 60 git push -f` each defeated every
# check in this file while the bare form was denied. See normalize_wrappers.
CMD=$(normalize_wrappers "$CMD")

# Committed template files (.env.example / .sample / .template / .dist / .tpl)
# are safe to stage; neutralize them so `git add .env.example` isn't blocked.
SCAN=$(printf '%s' "$CMD" | sed -E 's/\.env\.(example|sample|template|dist|tpl)/.envTEMPLATE/g')

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
# The short flag must be a whole option (hyphen, then letters, then a
# boundary) so a branch name ending in "-f" (e.g. `git push origin wip-f`)
# doesn't trip it. Short options bundle, so the f can sit anywhere in the
# cluster: `-fu` and `-qf` force-push exactly as `-f` does and matched nothing
# while the bare form was denied.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}push\b[^|;&]*([[:space:]]-[A-Za-z]*f[A-Za-z]*([[:space:]]|$)|--force\b|--force-with-lease\b)"; then
  emit_deny "Blocked: force-push is not allowed. Use regular git push, or ask the user to run this manually."
  exit 0
fi

# A leading + on a refspec IS the force flag — `git push origin +main` rewrites
# the remote branch with no --force anywhere in the command. --mirror is worse:
# it force-updates every ref and deletes the remote refs that are missing
# locally. Neither spelling appears in permissions.deny, so both were a full
# allow. Quoted forms count; a branch name containing + (feature-c++) does not,
# because the + has to open the token.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}push\b[^|;&]*([[:space:]]['\"]?\+[A-Za-z0-9_./*-]|--mirror\b)"; then
  emit_deny "Blocked: this push rewrites remote history without saying --force. A + on a refspec forces that ref, and --mirror force-updates every ref and deletes the ones missing locally. Push the refs you mean by name, or ask the user to run this manually."
  exit 0
fi

# --- Destructive worktree operations -----------------------------------
# These are already named in permissions.deny, but a deny RULE is prefix-shaped
# and never saw `git -C <path> reset --hard`: -C is not one of the wrappers
# Claude Code strips, so the rule text `git reset --hard` does not match. GOPT
# above DOES see it, which makes this hook the layer that closes the gap.
# Kept deliberately in lockstep with permissions.deny — relaxing one without
# the other leaves a rule that reads as protection but is not.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}reset\s+[^|;&]*--hard\b"; then
  emit_deny "Blocked: git reset --hard discards committed and uncommitted work with no recovery path. Use git checkout <file> or git revert, or ask the user to run this manually."
  exit 0
fi
# -[a-zA-Z]*f catches -f, -fd, -df, -xdf and --force; --dry-run has no f after
# a hyphen and so does not trip it.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}clean\s+[^|;&]*-[a-zA-Z]*f"; then
  emit_deny "Blocked: git clean -f permanently deletes untracked files. Remove the files you mean by name instead."
  exit 0
fi
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}branch\s+[^|;&]*(-D\b|-d\b|--delete\b)"; then
  emit_deny "Blocked: deleting a git branch. Both -d and -D are blocked, matching permissions.deny. Run it manually if the branch is really finished."
  exit 0
fi

# --- Remote branch deletion (push --delete OR push <remote> :branch) ----
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}push\s.*(--delete\b|\s:[A-Za-z0-9._/-]+)"; then
  emit_ask "Deleting a remote branch with git push. Confirm the branch name is correct before proceeding."
  exit 0
fi

# --- Indiscriminate staging --------------------------------------------
# Catches: git add . | ./ | :/ | -A | --all | -- . (and with -C/-c prefixes).
# The broad token no longer has to sit immediately after `add`: any flag in
# front of it (`git add -v .`, `git add -n -A`) hid it completely. `:/` is
# pathspec magic for the repository root and stages the whole tree like `.`.
# The trailing boundary still keeps a named path out of it, so `git add
# ./src/index.ts` and `git add -v src/main.py` stay silent.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}add\s+([^|;&]*[[:space:]])?(--\s+)?(-A|--all|\.\/?|:/)([[:space:]]|;|&|\||$)"; then
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
  '\.git-credentials(\s|$)'
  '\.pgpass(\s|$)'
  # Config-shaped secret files only — not secrets.py / secrets.ts (source code).
  'secrets\.(ya?ml|json|txt|env|cfg|conf|ini|properties|toml|enc)'
)
for P in "${SENSITIVE[@]}"; do
  if printf '%s\n' "$SCAN" | grep -qE "${A}${GIT}add\s.*${P}"; then
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
# The directory counts, not just a path through it: `cd .git/hooks && cat >
# pre-commit` installs the same payload and carries no trailing slash, so the
# old pattern never saw it. This check is deliberately unanchored (it fires
# wherever the path appears, a commit message included) — dropping the
# required slash widens that, it does not change its shape.
if printf '%s\n' "$CMD" | grep -qE "\.git/hooks(/|\b)"; then
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
