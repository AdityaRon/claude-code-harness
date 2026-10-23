#!/usr/bin/env bash
# Git operations that the deny rules miss or that lose work:
#   deny: force pushes (--force, an f in any short cluster, a + refspec,
#         --mirror), broad staging (., -A, :/, $(pwd)), staging credential
#         files, core.hooksPath by -c or git config, a ! alias, any mention of
#         .git/hooks, history rewrites, reset --hard, clean -f, branch -d/-D,
#         and checkout or restore of the whole tree
#   ask:  glob staging, stash drop/clear, worktree remove --force outside this
#         session's scratch, remote branch deletion whose tip no other ref
#         holds, remote set-url/add, any other alias, identity and signing
#         config, and a subcommand held in a variable or a function's arguments
# Most patterns start at a command boundary, but matching is textual: the same
# words in a heredoc, or in a message this cannot prove is text, can still match.
source "$(dirname "$0")/lib.sh"

# The command without message heredoc bodies or quoted messages (lib.sh).
strip_messages() { strip_message_args "$(strip_inert_heredocs "$1")"; }

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
# A script's shell-outs are checked as commands (lib.sh). The .git/hooks check
# still reads the script's text: open('.git/hooks/x', 'w') writes there too.
INLINE_TEXT=$CMD
check_inline_shellouts git flat
# The .git/hooks check still reads a quoted message, as it always has.
MSG_FREE=$(strip_message_args "$CMD")
HOOKS_TEXT=""
[[ "$MSG_FREE" != "$CMD" ]] && HOOKS_TEXT=$(printf '%s\n%s' "$CMD" "$(normalize_command "$CMD")")
CMD=$MSG_FREE

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

# --- A subcommand this cannot read --------------------------------------
# Every check below names its subcommand, so `X=push; git $X --force origin
# main` and `g() { git "$@"; }; g push --force` passed all of them while the
# typed form was denied. A backtick is read in the command as typed: the
# normalized one spaces backticks out, so a Markdown code span naming git in a
# heredoc read as git running one. Most git commands hold neither character,
# and the globs skip both greps for them.
if { [[ "$CMD" == *'$'* ]] && printf '%s\n' "$CMD" | grep -qE "${A}${GIT}[\"']?\\\$"; } \
   || { [[ "$MSG_FREE" == *'`'* ]] && printf '%s\n' "$MSG_FREE" | grep -qE "(^|[|&;]|&&|\|\||\\\$\()\s*${GIT}\`"; }; then
  emit_ask "git's subcommand here comes from a variable or a function's arguments, so this guard cannot tell which git command runs. Confirm what it expands to."
  exit 0
fi

# Each check below contains one of these, so one grep stands in for all of them
# when none is present: git status, log, diff, show and commit skip the rest.
printf '%s\n%s\n' "$CMD" "$SCAN" | grep -qiE "core\.hookspath|\.git/hooks|${GIT}(push|reset|clean|branch|checkout|restore|stash|worktree|add|config|remote|filter-branch|filter-repo|update-ref|reflog)" \
  || printf '%s\n%s\n' "$HOOKS_TEXT" "$INLINE_TEXT" | grep -qE '\.git/hooks' || exit 0

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
# git takes any prefix of --mirror down to --m.
if printf '%s\n' "$CMD" | grep -qE "${A}${GIT}push\b[^|;&]*([[:space:]]['\"]?\+[A-Za-z0-9_./*-]|--mirror\b|[[:space:]]['\"]?--m(i|ir|irr|irro)?\b)"; then
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

# The gates read the normalized line, where `/usr/bin/git`, `"git"`, `GIT`, `\git`
# and a function's "$@" all become git; the parsers read the command as typed. A
# segment only the gate saw went unchecked while the one beside it passed the
# call. Prints how many segments of subcommand $1 match $2 in the gate's view.
gate_segments() {
  normalize_command "$(strip_messages "$(jq_get '.tool_input.command')")" | tr -d '"'\''\\' \
    | grep -oE "${A}${GIT}$1\s+[^|;&]*" | grep -cE "$2"
}

# --- Branch deletion ----------------------------------------------------
# A branch whose tip a remote-tracking ref contains loses nothing when deleted,
# so it runs. Sessions make a branch per worktree and could never remove one:
# 398 piled up in one repo. Anything this cannot prove asks: a name in a
# variable, xargs, a cd first, an unknown flag, a tip only this branch holds.
# The raw command, not $CMD: its second line is lower-cased, and refs are not.
BRANCH_DEL='(-[A-Za-z]*[dD][A-Za-z]*|--de(l|le|let|lete)?)\b'   # -qD bundles; git takes --del
branch_on_remote() {
  local tip
  [[ "$2" =~ ^[A-Za-z0-9._/@+-]+$ && "$2" != -* ]] || return 1
  tip=$(git -C "$1" rev-parse -q --verify "refs/heads/$2^{commit}" 2>/dev/null) || return 1
  [[ -n $(git -C "$1" for-each-ref --count=1 --contains "$tip" --format=x refs/remotes 2>/dev/null) ]]
}
branch_delete_safe() {
  local raw segs seg t i b repo cwd n=0 names force
  cwd=$(jq_get '.cwd')
  raw=$(separate_groups "$(strip_messages "$(jq_get '.tool_input.command')")")
  # xargs appends names the command does not show; normalize_wrappers hides it.
  printf '%s\n' "$raw" | grep -qiE '(^|[^A-Za-z0-9_])xargs([^A-Za-z0-9_]|$)' && return 1
  raw=$(normalize_wrappers "$raw")
  printf '%s\n' "$raw" | grep -qE "${A}(cd|pushd)\b" && return 1
  segs=$(printf '%s\n' "$raw" | grep -oE "${A}${GIT}branch\s+[^|;&]*" | sed -E 's/^[|&;`$( ]*//')
  while IFS= read -r seg; do
    printf '%s\n' "$seg" | grep -qE "\s${BRANCH_DEL}" || continue
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
    names=(); force=0
    for ((i = i + 1; i < ${#t[@]}; i++)); do
      case "${t[i]}" in
        [0-9]\>*|\>*|[0-9]\<*|\<*) break ;;
        --force|-*[Df]*) [[ "${t[i]}" =~ ^(--force|-[dDfq]|-[dDfq][dDfq])$ ]] || return 1; force=1 ;;
        -[dq]|-[dq][dq]|--delete|--quiet) ;;
        -*) return 1 ;;
        *) names+=("${t[i]}") ;;
      esac
    done
    [[ ${#names[@]} -gt 0 ]] || return 1
    # A plain -d loses nothing: git itself refuses a branch not merged into HEAD or its upstream.
    for b in "${names[@]}"; do
      if [[ $force -eq 1 ]]; then branch_on_remote "$repo" "$b" || return 1
      else [[ "$b" =~ ^[A-Za-z0-9._/@+-]+$ && "$b" != -* ]] || return 1; fi
    done
    n=$((n + 1))
  done <<<"$segs"
  [[ $n -gt 0 && $n -eq $(gate_segments branch "\s${BRANCH_DEL}") ]]
}
if printf '%s\n' "$CMD" | tr -d '"'\''\\' | grep -qE "${A}${GIT}branch\s([^|;&]*\s)?${BRANCH_DEL}" && ! branch_delete_safe; then
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
  SCRATCH=$(session_scratch "$(jq_get '.tool_input.command')"$'\n'"$(jq_get '.cwd')")
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

# --- Remote branch deletion (push --delete, -d, <remote> :branch) -------
# Runs when a ref this push leaves in place holds the tip the remote reports.
# ls-remote, not the tracking ref: that is stale once someone else pushes.
# git accepts --del and -qd, so the gate does.
PUSH_DEL='(--de(l|le|let|lete)?\b|-[A-Za-z0-9]*d[A-Za-z0-9]*\b|\+?:[^[:space:]|;&])'
remote_tips_held() {   # $1 repo  $2 remote  $3 refs to leave out, one per line  $4.. names
  local repo="$1" remote="$2" out def sha held b x
  local -a pats=() skip=()
  while IFS= read -r x; do skip+=(-e "$x"); done <<<"$3"
  shift 3
  for b in "$@"; do pats+=("refs/heads/$b"); done
  # Capped: past Claude Code's hook timeout, onFailure: block would deny.
  out=$(run_bounded 10 env GIT_TERMINAL_PROMPT=0 git -C "$repo" ls-remote --symref "$remote" HEAD "${pats[@]}" 2>/dev/null </dev/null) || return 1
  def=$(printf '%s\n' "$out" | awk '$1=="ref:" && $3=="HEAD" {print $2}')
  [[ -n "$def" ]] || return 1
  for b in "$@"; do
    [[ "refs/heads/$b" != "$def" ]] || return 1
    sha=$(printf '%s\n' "$out" | awk -v r="refs/heads/$b" '$1!="ref:" && $2==r {print $1}')
    [[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] || return 1
    held=$(git -C "$repo" for-each-ref --contains "$sha" --format='%(refname)' refs/heads refs/tags refs/remotes 2>/dev/null) || return 1
    printf '%s\n' "$held" | grep -vxF "${skip[@]}" | grep -q . || return 1
  done
}
push_delete_safe() {
  local cmd raw segs seg t i k r repo cwd n=0 del b fu pu gone=""
  local -a refs names s_repo=() s_remote=() s_names=()
  cwd=$(jq_get '.cwd')
  cmd=$(strip_messages "$(jq_get '.tool_input.command')")
  raw=$(separate_groups "$cmd")
  printf '%s\n' "$raw" | grep -qiE '(^|[^A-Za-z0-9_])xargs([^A-Za-z0-9_]|$)' && return 1
  raw=$(normalize_wrappers "$raw")
  printf '%s\n' "$raw" | grep -qE "${A}(cd|pushd)\b" && return 1
  # A local delete in the same call: each check would count the ref the other removes.
  [[ $(gate_segments branch "\s${BRANCH_DEL}") -eq 0 ]] || return 1
  segs=$(printf '%s\n' "$raw" | grep -oE "${A}${GIT}push\s+[^|;&]*" | sed -E 's/^[|&;`$( ]*//')
  while IFS= read -r seg; do
    printf '%s\n' "$seg" | grep -qE "\s${PUSH_DEL}" || continue
    read -ra t <<<"$seg"
    [[ "${t[0]}" == git ]] || return 1
    repo="$cwd"; i=1
    while [[ "${t[i]:-}" != push ]]; do
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
    del=0; refs=()
    for ((i = i + 1; i < ${#t[@]}; i++)); do
      case "${t[i]}" in
        [0-9]\>*|\>*|[0-9]\<*|\<*) break ;;
        -d|--delete) del=1 ;;
        -q|--quiet|-v|--verbose|-n|--dry-run|--no-verify|--porcelain) ;;
        -*) return 1 ;;
        *) refs+=("${t[i]}") ;;
      esac
    done
    r="${refs[0]:-}"
    [[ "$r" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    # The delete goes to the push URL; ls-remote reads the fetch URL.
    fu=$(git -C "$repo" remote get-url --all "$r" 2>/dev/null) || return 1
    pu=$(git -C "$repo" remote get-url --push --all "$r" 2>/dev/null) || return 1
    [[ -n "$fu" && "$fu" == "$pu" && "$fu" != *$'\n'* ]] || return 1
    names=()
    for b in "${refs[@]:1}"; do
      if [[ $del -eq 0 ]]; then [[ "$b" == :?* ]] || continue; b="${b#:}"; fi
      b="${b#refs/heads/}"
      [[ "$b" =~ ^[A-Za-z0-9._/@+-]+$ && "$b" != -* && "$b" != refs/* ]] || return 1
      names+=("$b"); gone+="refs/remotes/$r/$b"$'\n'
    done
    [[ ${#names[@]} -gt 0 ]] || return 1
    gone+="refs/remotes/$r/HEAD"$'\n'
    s_repo+=("$repo"); s_remote+=("$r"); s_names+=("${names[*]}")
    n=$((n + 1))
  done <<<"$segs"
  [[ $n -gt 0 && $n -eq $(gate_segments push "\s${PUSH_DEL}") ]] || return 1
  # Every name in the call is left out of every check, or two branches at one
  # commit would each count the other's tracking ref.
  for ((k = 0; k < n; k++)); do
    read -ra names <<<"${s_names[k]}"
    remote_tips_held "${s_repo[k]}" "${s_remote[k]}" "${gone%$'\n'}" "${names[@]}" || return 1
  done
}
if printf '%s\n' "$CMD" | tr -d '"'\''\\' | grep -qE "${A}${GIT}push\s([^|;&]*\s)?${PUSH_DEL}" && ! push_delete_safe; then
  emit_ask "This deletes a remote branch whose tip no other ref holds (a local branch, a tag, or another remote-tracking ref), or one this guard could not check. Confirm the work is merged or no longer needed."
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
BROAD="['\"]?(-[A-Za-z]*A[A-Za-z]*|--a(l|ll)?|\.{1,2}/?|:/|\\$\(\s*pwd\s*\)|\\$\{?PWD\}?)['\"]?"   # -vA bundles; git takes --al
# What a broad add would stage, git status lists (porcelain paths are always
# repo-relative, so a subdirectory's `.` is covered by a superset). Deny only
# when one of those paths is a credential file; a clean broad add runs. -f adds
# ignored files status does not list, and a cd, xargs, or a path in a variable
# hides the repo: each keeps the deny. Named paths are not checked here.
SENSITIVE_PATH="$(IFS='|'; printf '%s' "${CREDENTIAL_FILES[*]}")|\.env[.-]|id_rsa|id_ed25519|\.aws/credentials"
FOUND=""
broad_add_safe() {
  local raw segs seg t i repo cwd n=0 p out
  cwd=$(jq_get '.cwd')
  raw=$(separate_groups "$(strip_messages "$(jq_get '.tool_input.command')")")
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
        # -f, -fA, -vf and --f through --force, all of which git takes as force.
        --f|--fo|--for|--forc|--force) return 1 ;;
        --*) ;;
        -*f*) return 1 ;;
        [0-9]\>*|\>*|\<*) break ;;
      esac
    done
    out=$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null) || return 1
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      p=${p:3}; p=${p#* -> }; p=${p%\"}; p=${p#\"}
      if printf '%s\n' "$p" | grep -qiE "$SENSITIVE_PATH" && ! printf '%s\n' "$p" | grep -qE '\.(example|sample|template|dist|tpl)$'; then
        FOUND=$p; return 1
      fi
    done <<<"$out"
    n=$((n + 1))
  done <<<"$segs"
  [[ $n -gt 0 && $n -eq $(gate_segments add "\s(--\s+)?${BROAD}([[:space:]]|$)") ]]
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
# Identity and signing keys: setting one asks, reading one does not (`git config
# --global user.name`, `--get`, `--list`, `git config get …`). Judged one command at
# a time: a `.*` here once spanned the `;` in `git config user.name; ls`.
ID_KEY='(user\.(name|email|signingkey)|gpg\.signingkey|commit\.gpgsign|tag\.gpgsign)'
while IFS= read -r seg; do
  printf '%s\n' "$seg" | grep -qE "$ID_KEY" || continue
  if ! printf '%s\n' "$seg" | grep -qE -- "\s(--(unset|unset-all|replace-all|add|edit|rename-section|remove-section)|-e|set|unset|edit)(\s|=|$)"; then
    printf '%s\n' "$seg" | grep -qE -- "\s(--(get|get-all|get-regexp|get-urlmatch|list)|-l|get|list)(\s|$)" && continue
    rest=$(printf '%s\n' "$seg" | sed -E "s/^.*${ID_KEY}[\"']?//"); read -r first _ <<<"$rest"
    [[ -z "$first" || "$first" =~ ^([0-9]*[\<\>]|[\)\&]) ]] && continue
  fi
  emit_ask "git config is changing identity or signing settings. Confirm this is intended."
  exit 0
done < <(printf '%s\n' "$CMD" | grep -oE "${A}${GIT}config\s+[^|;&]*")

# --- Writes into .git/hooks/* ------------------------------------------
# The directory counts, not just a path through it: `cd .git/hooks && cat >
# pre-commit` installs the same payload and carries no trailing slash, so the
# old pattern never saw it. This check is deliberately unanchored (it fires
# wherever the path appears, a commit message included) — dropping the
# required slash widens that, it does not change its shape.
if printf '%s\n%s\n%s\n' "$CMD" "$HOOKS_TEXT" "$INLINE_TEXT" | grep -qE "\.git/hooks(/|\b)"; then
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
