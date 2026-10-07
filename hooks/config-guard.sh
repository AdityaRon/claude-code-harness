#!/usr/bin/env bash
# Guards what the harness runs from and what runs at every shell start.
# A write into ~/.claude/hooks, or to a script directly in ~/.claude, asks: the
# hooks check every call and statusline.sh runs outside the sandbox. Ask, not
# deny, because people extend these, and the repo plus install.sh reaches them
# anyway. Moving or emptying ~/.claude itself is denied. A write to a Claude Code
# settings file, a shell startup file, ~/.gitconfig or ~/Library/LaunchAgents
# asks first. Reads pass. Writes made from inside an interpreter are not seen.
source "$(dirname "$0")/lib.sh"

read_input
require_jq_or_deny
require_parsable_or_deny
{ IFS= read -r -d '' TOOL; IFS= read -r -d '' TARGET; IFS= read -r -d '' CWD; } < <(
  printf '%s' "$INPUT" | jq -j '(.tool_name // ""), "\u0000",
    (.tool_input | .command // .file_path // .notebook_path // ""), "\u0000", (.cwd // ""), "\u0000"' 2>/dev/null)
[[ -z "$TARGET" ]] && exit 0

H=$HOME
# Most commands name none of these and are not run from inside ~/.claude. A
# symlink into ~/.claude/hooks has to be made first, and ln is checked below.
[[ "$TOOL" == Bash ]] && case "$TARGET" in
  *.claude*|*.zsh*|*.zprofile*|*.zlog*|*.bashrc*|*.bash_profile*|*.bash_login*|*.profile*|*gitconfig*|*git/config*|*LaunchAgents*|*--global*) ;;
  *) case "$CWD" in "$H/.claude"|"$H/.claude/"*|*/.claude|"$H/Library/LaunchAgents") ;; *) exit 0 ;; esac ;;
esac
WORST=""; REASON=""

note() {   # note LEVEL WORD
  local why
  case "$1" in
    deny) why="Blocked: $2 holds the installed harness, whose hooks check every command. Move or empty it yourself if you mean to." ;;
    harness) why="$2 is part of the installed harness, which checks every command. Approve only if you asked for this. bash install.sh overwrites the files it ships; a hook of your own under a new name is kept." ;;
    settings) why="$2 is a Claude Code settings file: a change there can grant permissions or add hooks. Approve only if you asked for this." ;;
    startup) why="$2 runs at every shell start or login, or sets git's behaviour everywhere. Approve only if you asked for this." ;;
    *) return ;;
  esac
  if [[ "$1" == deny ]]; then
    [[ "$WORST" != deny ]] && { WORST=deny; REASON=$why; }
  elif [[ -z "$WORST" ]]; then
    WORST=ask; REASON=$why
  fi
}

# The path a word names: quotes and backslashes out, ~ and $HOME in, relative
# to the session's folder, with . and .. resolved as text.
abs_path() {
  local p="$1" part out=() IFS=/
  p=${p//\"/}; p=${p//\'/}; p=${p//\\/}
  # shellcheck disable=SC2088  # '~' is the tilde as typed; it is expanded here
  case "$p" in
    '~') p=$H ;; '~/'*) p="$H/${p#\~/}" ;;
    '$HOME'|'${HOME}') p=$H ;;
    '$HOME/'*) p="$H/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$H/${p#\$\{HOME\}/}" ;;
    /*) ;;
    *) p="${CWD:-$PWD}/$p" ;;
  esac
  set -f
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) [[ ${#out[@]} -gt 0 ]] && unset "out[$((${#out[@]} - 1))]" ;;
      *) out+=("$part") ;;
    esac
  done
  set +f
  [[ ${#out[@]} -eq 0 ]] && { printf '/'; return; }
  printf '/%s' "${out[@]}"
}

H=$(abs_path "$HOME")
HR=$(cd "$H" 2>/dev/null && pwd -P) || HR=$H

level_of() {   # level_of PATH DESTRUCTIVE: deny, harness, settings, startup or nothing
  local p="$1" h c
  case "$p" in */.claude/settings.json|*/.claude/settings.local.json) echo settings; return ;; esac
  for h in "$H" "$HR"; do
    c="$h/.claude"
    case "$p" in
      "$c/hooks"|"$c/hooks/"*) echo harness; return ;;
      "$c/"*.sh) [[ "${p#"$c"/}" != */* ]] && { echo harness; return; } ;;
      "$c") [[ "$2" == 1 ]] && { echo deny; return; } ;;
      "$h/.zshrc"|"$h/.zshenv"|"$h/.zprofile"|"$h/.zlogin"|"$h/.zlogout"|"$h/.bashrc"|"$h/.bash_profile"|"$h/.bash_login"|"$h/.profile"|"$h/.gitconfig"|"$h/.config/git/config"|"$h/Library/LaunchAgents/"*)
        echo startup; return ;;
    esac
  done
}

# As written first, then with its folder resolved, so a symlink into
# ~/.claude/hooks counts as the real path.
classify_one() {   # classify_one ABS DESTRUCTIVE
  local p="$1" d l
  l=$(level_of "$p" "$2")
  if [[ -z "$l" ]]; then
    if [[ -d "$p" ]]; then d=$(cd "$p" 2>/dev/null && pwd -P) && l=$(level_of "$d" "$2")
    else d=$(cd "${p%/*}" 2>/dev/null && pwd -P) && l=$(level_of "$d/${p##*/}" "$2"); fi
  fi
  printf '%s' "$l"
}

check_word() {   # check_word WORD DESTRUCTIVE
  local w="$1" p m
  [[ -z "$w" ]] && return
  p=$(abs_path "$w")
  note "$(classify_one "$p" "$2")" "$w"
  case "$p" in
    *'*'*|*'?'*|*'['*)   # a glob writes whatever it matches now
      while IFS= read -r m; do note "$(classify_one "$m" "$2")" "$w"; done < <(compgen -G "$p" 2>/dev/null) ;;
  esac
}

# git config writes ~/.gitconfig with --global, or the file after --file.
git_config() {
  local w global=0 file="" write=0 n=0 next=""
  for w in "$@"; do
    if [[ -n "$next" ]]; then [[ "$next" == file ]] && file=$w; next=""; continue; fi
    case "$w" in
      --global) global=1 ;;
      --file|-f) next="file" ;;
      --file=*) file=${w#--file=} ;;
      --type|--default|--blob|--comment) next="skip" ;;
      --unset|--unset-all|--add|--replace-all|--rename-section|--remove-section|-e|--edit) write=1 ;;
      -*) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  [[ $n -ge 2 ]] && write=1
  [[ $write == 1 ]] || return
  [[ $global == 1 ]] && note startup "git's global config (~/.gitconfig)"
  [[ -n "$file" ]] && check_word "$file" 0
}

scan_segment() {
  local words=() ops=() w i c destr=0 inplace=0 tdir="" next="" sub=""
  set -f; read -ra words <<<"$1"; set +f
  [[ ${#words[@]} -eq 0 ]] && return
  c=${words[0]##*/}
  for ((i = 1; i < ${#words[@]}; i++)); do
    w=${words[$i]}
    if [[ -n "$next" ]]; then
      case "$next" in t) tdir=$w ;; o) check_word "$w" 0 ;; esac
      next=""; continue
    fi
    case "$c:$w" in
      cp:-t|mv:-t|install:-t|ln:-t) next=t; continue ;;
      *:--target-directory=*) tdir=${w#*=}; continue ;;
      curl:-[a-zA-Z]*o|curl:--output|wget:-[a-zA-Z]*O|wget:--output-document) next=o; continue ;;
      curl:--output=*|wget:--output-document=*) check_word "${w#*=}" 0; continue ;;
      curl:-o?*) check_word "${w#-o}" 0; continue ;;
      dd:of=*) check_word "${w#of=}" 1; continue ;;
      sed:-i*|sed:-I*|sed:--in-place*|gsed:-i*|gsed:--in-place*|perl:-*i*|ruby:-*i*) inplace=1 ;;
      *:-R|*:-r|*:-*[Rr]*) [[ "$c" == chmod || "$c" == chown || "$c" == chgrp ]] && destr=1 ;;
      find:-delete|find:-exec|find:-execdir|find:-ok|find:-okdir) sub=destroy ;;
    esac
    case "$w" in -*) [[ "$c" == find ]] && [[ -z "$sub" ]] && sub=opts ;; *) [[ "$c" == find && -n "$sub" ]] || ops+=("$w") ;; esac
  done
  case "$c" in
    ln) for w in "${ops[@]}"; do check_word "$w" 0; done   # a link INTO the harness is a way in
        [[ -n "$tdir" ]] && check_word "$tdir" 0 ;;
    cp|install|rsync|scp|ditto)
      if [[ -n "$tdir" ]]; then check_word "$tdir" 0
      elif [[ ${#ops[@]} -gt 0 ]]; then check_word "${ops[$((${#ops[@]} - 1))]}" 0; fi ;;
    mv) [[ -n "$tdir" ]] && check_word "$tdir" 0
        for w in "${ops[@]}"; do check_word "$w" 1; done ;;
    rm|unlink|rmdir|shred|srm|trash|truncate)
        for w in "${ops[@]}"; do check_word "$w" 1; done ;;
    touch|tee|patch) for w in "${ops[@]}"; do check_word "$w" 0; done ;;
    chmod|chown|chgrp|chflags|xattr|setfacl)
        for w in "${ops[@]}"; do check_word "$w" "$destr"; done ;;
    sed|gsed|perl|ruby) [[ $inplace == 1 ]] && for w in "${ops[@]}"; do check_word "$w" 0; done ;;
    find) [[ "$sub" == destroy ]] && for w in "${ops[@]}"; do check_word "$w" 1; done ;;
    git) for ((i = 1; i < ${#words[@]}; i++)); do
           [[ "${words[$i]}" == config ]] && { git_config "${words[@]:$((i + 1))}"; break; }
         done ;;
  esac
}

# A heredoc body is the data a command reads, unless that command is a shell.
# Unterminated, it is all kept.
drop_data_heredocs() {
  local out
  case "$1" in *'<<'*) ;; *) printf '%s' "$1"; return ;; esac
  out=$(printf '%s\n' "$1" | awk '
    body { t = $0; if (dash) sub(/^\t+/, "", t)
           if (t == term) { body = 0; print; next }
           if (shell) print
           next }
    { print
      if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        h = substr($0, RSTART + 2, RLENGTH - 2); dash = (h ~ /^-/); sub(/^-?[ \t]*["\047]?/, "", h)
        shell = (substr($0, 1, RSTART - 1) ~ /(^|[;&|(])[ \t]*(bash|sh|zsh|dash|ksh)([ \t][^;&|]*)?$/)
        term = h; body = 1 } }
    END { if (body) exit 3 }') || { printf '%s' "$1"; return; }
  printf '%s' "$out"
}

case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit) check_word "$TARGET" 0 ;;
  Bash)
    # Quoted separators hidden, groups opened, wrappers and /bin/ paths gone (lib.sh).
    NORM=$(normalize_command "$(neutralize_quoted_separators "$(drop_data_heredocs "$TARGET")")")
    REDIR='[0-9&]*>>?\|?[[:space:]]*[^[:space:];&|<>()]+'
    while IFS= read -r w; do
      [[ "$w" == '&'* ]] || check_word "$w" 0
    done < <(printf '%s\n' "$NORM" | grep -oE "$REDIR" | sed -E 's/^[0-9&]*>>?\|?[[:space:]]*//')
    while IFS= read -r seg; do
      scan_segment "$seg"
    done < <(printf '%s\n' "$NORM" | sed -E "s/$REDIR//g; s/<[[:space:]]*[^[:space:];&|<>()]+//g" \
               | tr '\n' ';' | sed -E 's/\$\(/;/g; s/`/;/g; s/\|\||&&/;/g; s/[|;&]/\n/g')
    ;;
esac

case "$WORST" in
  deny) emit_deny "$REASON" ;;
  ask) emit_ask "$REASON" ;;
esac
exit 0
