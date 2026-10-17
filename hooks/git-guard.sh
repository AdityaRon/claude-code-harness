#!/usr/bin/env bash
# Git operations that the deny rules miss or that lose work:
#   deny: force pushes (--force, an f in any short cluster, a + refspec,
#         --mirror), broad staging (., -A, :/, $(pwd)), staging credential
#         files, core.hooksPath by -c or git config, a ! alias, any mention of
#         .git/hooks, history rewrites, reset --hard, clean -f, branch -d/-D,
#         and checkout or restore of the whole tree
#   ask:  glob staging, stash drop/clear, worktree remove --force outside this
#         session's scratch, remote branch deletion, remote set-url/add, any
#         other alias, identity and signing config
# Most patterns start at a command boundary, but matching is textual: the same
# words in a commit message or heredoc can still match.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
CMD=$(jq_get '.tool_input.command')
[[ -z "$CMD" ]] && exit 0
# Every check below names git. Normalizing drops quotes and backslashes, lowers
# case, and removes paths and prefixes, but never adds a letter, so a command
# with no git once quotes and backslashes are gone is done, before ~35 ms of it.
# tr, not ${CMD//…}: bash 3.2's substitution took 30 s on an 8,000-byte command.
R=$(printf '%s' "$CMD" | tr -d '"'\''\\')
[[ "$R" == *[Gg][Ii][Tt]* ]] || exit 0
CMD=$(strip_inert_heredocs "$CMD")

# Strip assignment/wrapper prefixes before anything below matches. The anchor A
# admits only real command boundaries, so `VAR=1 git push -f`, `env FOO=bar git
# push -f`, `nohup git push -f` and `timeout 60 git push -f` each defeated every
# check in this file while the bare form was denied. `/usr/bin/git` and `GIT`
# did the same. The second line is the fully normalized form; see lib.sh.
CMD=$(printf '%s\n%s' "$(normalize_wrappers "$(separate_groups "$CMD")")" "$(normalize_command "$CMD")")

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
# xargs runs git with stdin appended, so `echo main | xargs git push --force`
# reaches git from behind a word that is not a command boundary.
XARGS='(xargs(\s+-[A-Za-z0-9]+(\s+\{\})?)*\s+)?'
GIT="${XARGS}git(\s+${GOPT})*\s+"

# Each check below contains one of these, so one grep stands in for all of them
# when none is present: git status, log, diff, show and commit skip the rest.
printf '%s\n%s\n' "$CMD" "$SCAN" | grep -qiE "core\.hookspath|\.git/hooks|${GIT}(push|reset|clean|branch|checkout|restore|stash|worktree|add|config|remote|filter-branch|filter-repo|update-ref|reflog)" || exit 0

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

# --- Branch deletion ----------------------------------------------------
# A branch whose tip a remote-tracking ref contains loses nothing when deleted,
# so it runs. Sessions make a branch per worktree and could never remove one:
# 398 piled up in one repo. Anything this cannot prove asks: a name in a
# variable, xargs, a cd first, an unknown flag, a tip only this branch holds.
# The raw command, not $CMD: its second line is lower-cased, and refs are not.
branch_on_remote() {
  local tip
  [[ "$2" =~ ^[A-Za-z0-9._/@+-]+$ && "$2" != -* ]] || return 1
  tip=$(git -C "$1" rev-parse -q --verify "refs/heads/$2^{commit}" 2>/dev/null) || return 1
  [[ -n $(git -C "$1" for-each-ref --count=1 --contains "$tip" --format=x refs/remotes 2>/dev/null) ]]
}
branch_delete_safe() {
  local raw segs seg t i b repo cwd n=0 names
  cwd=$(jq_get '.cwd')
  raw=$(normalize_wrappers "$(separate_groups "$(strip_inert_heredocs "$(jq_get '.tool_input.command')")")")
  printf '%s\n' "$raw" | grep -qE "${A}(cd|pushd)\b" && return 1
  segs=$(printf '%s\n' "$raw" | grep -oE "${A}${GIT}branch\s+[^|;&]*" | sed -E 's/^[|&;`$( ]*//')
  while IFS= read -r seg; do
    printf '%s\n' "$seg" | grep -qE "\s(-[a-zA-Z]*[dD][a-zA-Z]*|--delete)\b" || continue
    read -ra t <<<"$seg"
    [[ "${t[0]}" == git ]] || return 1
    repo="$cwd"; i=1
    while [[ "${t[i]:-}" != branch ]]; do
      case "${t[i]:-}" in
        -C) repo="${t[i+1]:-}"; i=$((i + 2)) ;;
        -C?*) repo="${t[i]#-C}"; i=$((i + 1)) ;;
        --no-pager) i=$((i + 1)) ;;
        *) return 1 ;;
      esac
    done
    # shellcheck disable=SC2088  # '~/' is the tilde as typed; it is expanded here
    case "$repo" in
      ''|*'$'*|*'`'*) return 1 ;;
      '~/'*) repo="$HOME/${repo#\~/}" ;;
      /*) ;;
      *) [[ -n "$cwd" ]] || return 1; repo="$cwd/$repo" ;;
    esac
    names=()
    for ((i = i + 1; i < ${#t[@]}; i++)); do
      case "${t[i]}" in
        [0-9]\>*|\>*|[0-9]\<*|\<*) break ;;
        -[dDfq]|-[dDfq][dDfq]|--delete|--force|--quiet) ;;
        -*) return 1 ;;
        *) names+=("${t[i]}") ;;
      esac
    done
    [[ ${#names[@]} -gt 0 ]] || return 1
    for b in "${names[@]}"; do branch_on_remote "$repo" "$b" || return 1; done
    n=$((n + 1))
  done <<<"$segs"
  [[ $n -gt 0 ]]
}
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}branch\s+[^|;&]*(-D\b|-d\b|--delete\b)" && ! branch_delete_safe; then
  emit_ask "This deletes a branch whose commits no remote-tracking ref holds, or one this guard could not check. Confirm the work is merged or no longer needed."
  exit 0
fi

# Discarding the whole working tree is reset --hard for uncommitted work, and
# `Bash(git checkout:*)` is on the allow list, so nothing else stops it.
# `git restore --staged .` only unstages and stays allowed; `git checkout -`
# (switch back) is not a pathspec.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}(checkout|restore)\s+([^|;&]*[[:space:]])?(--\s+)?(\.{1,2}/?|:/)([[:space:]]|;|&|\||$)" \
   && ! { printf '%s\n' "$CMD" | grep -qE "${A}${GIT}restore\s[^|;&]*(--staged|-S)\b" \
          && ! printf '%s\n' "$CMD" | grep -qE "${A}${GIT}restore\s[^|;&]*(--worktree|-W)\b"; }; then
  emit_deny "Blocked: this discards every uncommitted change in the tree with no recovery path. Restore the files you mean by name, or ask the user to run this manually."
  exit 0
fi
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}stash\s+(drop|clear)\b"; then
  emit_ask "This deletes a stash with its uncommitted changes. Confirm nothing in it is needed."
  exit 0
fi
# A forced worktree removal asks, unless every path is a scratch worktree this
# session made (git needs --force there whenever the tree is dirty), or a
# worktree with nothing to lose: git removes one whose status is empty without
# --force, ignored files included, so --force there deletes nothing more.
clean_worktree() {
  local p="${1//\"/}" s
  p="${p//\'/}"
  case "$p" in ''|*'$'*) return 1 ;; esac
  # shellcheck disable=SC2088  # '~/' is the tilde as typed; it is expanded here
  case "$p" in
    '~/'*) p="$HOME/${p#\~/}" ;;
    /*) ;;
    *) [[ -n "$RELBASE" ]] || return 1; p="$RELBASE/$p" ;;
  esac
  [[ -d "$p" ]] && s=$(git -C "$p" status --porcelain 2>/dev/null) && [[ -z "$s" ]]
}
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}worktree\s+remove\s[^|;&]*(--force|-f)\b"; then
  SCRATCH=$(session_scratch)
  # The raw command: normalizing strips the `CLAUDE_JOB_DIR=/x` prefix this looks for.
  jq_get '.tool_input.command' | grep -qE '(^|[^A-Za-z0-9_])(CLAUDE_JOB_DIR|HOME|TMPDIR)[[:space:]]*=' && SCRATCH=""
  BASE=$(in_scratch "$(jq_get '.cwd')" "$SCRATCH" "") || BASE=""
  # A relative path means the session's cwd only when nothing moves it first.
  RELBASE=$(jq_get '.cwd')
  printf '%s\n' "$CMD" | grep -qE "${A}(cd|pushd)\b|\s(-C|--git-dir|--work-tree)\b" && RELBASE=""
  PATHS=$(printf '%s\n' "$CMD" | grep -oE "${GIT}worktree\s+remove\s[^|;&]*" | sed -E 's/^.*worktree[[:space:]]+remove[[:space:]]+//' \
    | tr -s ' \t' '\n' | grep -vE '^-' | grep -v '^$')
  ALL=1
  while IFS= read -r wp; do
    in_scratch "$wp" "$SCRATCH" "$BASE" >/dev/null || clean_worktree "$wp" || { ALL=0; break; }
  done <<<"$PATHS"
  if [[ -z "$PATHS" || $ALL -eq 0 ]]; then
    emit_ask "This deletes a worktree with its uncommitted changes. Confirm nothing in it is needed."
    exit 0
  fi
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
# Quoting does not narrow a pathspec, and `..` or `$(pwd)` name a tree at least
# as wide as `.`; each of those was a silent allow. normalize_wrappers pads
# `$(` to ` $( `, hence the spaces inside the $(pwd) form.
BROAD="['\"]?(-A|--all|\.{1,2}/?|:/|\\$\(\s*pwd\s*\)|\\$\{?PWD\}?)['\"]?"
# What a broad add would stage, git status lists (porcelain paths are always
# repo-relative, so a subdirectory's `.` is covered by a superset). Deny only
# when one of those paths is a credential file; a clean broad add runs. -f adds
# ignored files status does not list, and a cd, xargs, or a path in a variable
# hides the repo: each keeps the deny. Named paths are not checked here.
SENSITIVE_PATH='\.env$|\.env\.|(^|/)\.envrc$|\.pem$|\.key$|id_rsa|id_ed25519|\.aws/credentials|(^|/)\.netrc$|(^|/)\.git-credentials$|(^|/)\.pgpass$|secrets\.(ya?ml|json|txt|env|cfg|conf|ini|properties|toml|enc)$'
FOUND=""
broad_add_safe() {
  local raw segs seg t i repo cwd n=0 p out
  cwd=$(jq_get '.cwd')
  raw=$(separate_groups "$(strip_inert_heredocs "$(jq_get '.tool_input.command')")")
  # xargs appends stdin, which can hold -f; normalize_wrappers would hide it.
  printf '%s\n' "$raw" | grep -qiE '(^|[^A-Za-z0-9_])xargs([^A-Za-z0-9_]|$)' && return 1
  raw=$(normalize_wrappers "$raw")
  printf '%s\n' "$raw" | grep -qE "${A}(cd|pushd)\b" && return 1
  segs=$(printf '%s\n' "$raw" | grep -oE "${A}${GIT}add\s+[^|;&]*" | sed -E 's/^[|&;`$( ]*//')
  while IFS= read -r seg; do
    printf '%s\n' "$seg" | grep -qE "\s(--\s+)?${BROAD}([[:space:]]|$)" || continue
    read -ra t <<<"$seg"
    [[ "${t[0]}" == git ]] || return 1
    repo="$cwd"; i=1
    while [[ "${t[i]:-}" != add ]]; do
      case "${t[i]:-}" in
        -C) repo="${t[i+1]:-}"; i=$((i + 2)) ;;
        -C?*) repo="${t[i]#-C}"; i=$((i + 1)) ;;
        --no-pager) i=$((i + 1)) ;;
        *) return 1 ;;
      esac
    done
    # shellcheck disable=SC2088  # '~/' is the tilde as typed; it is expanded here
    case "$repo" in
      ''|*'$'*|*'`'*) return 1 ;;
      '~/'*) repo="$HOME/${repo#\~/}" ;;
      /*) ;;
      *) [[ -n "$cwd" ]] || return 1; repo="$cwd/$repo" ;;
    esac
    for ((i = i + 1; i < ${#t[@]}; i++)); do
      case "${t[i]}" in
        --force|-[A-Za-z]*f*) return 1 ;;
        [0-9]\>*|\>*|\<*) break ;;
      esac
    done
    out=$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null) || return 1
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      p=${p:3}; p=${p#* -> }; p=${p%\"}; p=${p#\"}
      if printf '%s\n' "$p" | grep -qE "$SENSITIVE_PATH" && ! printf '%s\n' "$p" | grep -qE '\.(example|sample|template|dist|tpl)$'; then
        FOUND=$p; return 1
      fi
    done <<<"$out"
    n=$((n + 1))
  done <<<"$segs"
  [[ $n -gt 0 ]]
}
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}add\s+([^|;&]*[[:space:]])?(--\s+)?${BROAD}([[:space:]]|;|&|\||$)" && ! broad_add_safe; then
  if [[ -n "$FOUND" ]]; then
    emit_deny "Blocked: this broad git add would stage $FOUND, a credential file. Stage files by name instead."
  else
    emit_deny "Blocked: broad git add (., ./, -A, --all) may stage sensitive files, and this guard could not list what it would stage (a cd first, -f, or a repo it cannot find). Stage files by name instead."
  fi
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
