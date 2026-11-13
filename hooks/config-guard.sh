#!/usr/bin/env bash
# Guards what the harness runs from and what runs at every shell start.
# A write into ~/.claude/hooks, or to a script directly in ~/.claude, asks: the
# hooks check every call and statusline.sh runs outside the sandbox. Ask, not
# deny, because people extend these, and the repo plus install.sh reaches them
# anyway. Moving or emptying ~/.claude itself is denied. A write to a Claude Code
# settings file, the installed-plugin cache ~/.claude/plugins, a shell startup
# file, ~/.gitconfig or ~/Library/LaunchAgents asks first, as does a Bash write
# into a mod Claude Code loads by itself, which mod-gate.sh never sees, and a
# write to ~/.claude/hooks/bash-guards.skip. A copy or extraction into a .claude
# folder asks too, since the names it writes are not in the command. Names match
# case-folded, and what follows an expansion the guard does not resolve ($d,
# ${x}, ~user) is also read as under ~. Reads pass; interpreter writes are not seen.
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
# Library/ lets a glob there in (~/Library/LaunchAgen*). Case-folded, as
# level_of matches: macOS formats APFS case-insensitive, so ~/.CLAUDE/HOOKS is
# ~/.claude/hooks there.
shopt -s nocasematch
[[ "$TOOL" == Bash || "$TOOL" == Monitor ]] && case "$TARGET" in
  *.claude*|*.zsh*|*.zprofile*|*.zlog*|*.bashrc*|*.bash_profile*|*.bash_login*|*.profile*|*gitconfig*|*git/config*|*LaunchAgents*|*Library/*|*--global*) ;;
  *) case "$CWD" in "$H/.claude"|"$H/.claude/"*|*/.claude|*/.claude/skills/*|"$H/Library/LaunchAgents") ;; *) exit 0 ;; esac ;;
esac
shopt -u nocasematch
WORST=""; REASON=""; REMOVING=""; BASES=()

note() {   # note LEVEL WORD
  local why
  case "$1" in
    deny) why="Blocked: $2 holds the installed harness, whose hooks check every command. Move or empty it yourself if you mean to." ;;
    harness) why="$2 is part of the installed harness, which checks every command. Approve only if you asked for this. bash install.sh overwrites the files it ships; a hook of your own under a new name is kept." ;;
    settings) why="$2 is a Claude Code settings file: a change there can grant permissions or add hooks. Approve only if you asked for this." ;;
    plugins) why="$2 is in the installed-plugin cache, whose hooks and commands load in every session. Approve only if you asked for this; /plugin install from your own prompt is unaffected." ;;
    startup) why="$2 runs at every shell start or login, or sets git's behaviour everywhere. Approve only if you asked for this." ;;
    mods) why="$2 is in a mod Claude Code loads by itself, in auto mode with no question, and a write from Bash skips mod-gate's review. Write the mod's files with Write or Edit instead, so mod-gate reviews them; approve this only if you asked for it." ;;
    skip) why="$2 lists Bash guards to switch off: a guard named there stops checking every Bash and Monitor call. Approve only if you asked for this." ;;
    tree) why="$2 is a Claude Code folder (hooks, settings.json), and this copy or extraction writes names the command does not show, so it can replace them. Approve only if you asked for this." ;;
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
    # The session's folder and the project's, read only in a command with no cd.
    '$PWD'|'$PWD/'*|'${PWD}'|'${PWD}/'*|'$CLAUDE_PROJECT_DIR'|'$CLAUDE_PROJECT_DIR/'*|'${CLAUDE_PROJECT_DIR}'|'${CLAUDE_PROJECT_DIR}/'*)
      if [[ ${#BASES[@]} -eq 0 ]]; then
        part=${p#\$}; part=${part#\{}; part=${part#PWD}; part=${part#CLAUDE_PROJECT_DIR}; part=${part#\}}
        case "$p" in '$PWD'*|'${PWD}'*) p="${CWD:-$PWD}$part" ;; *) p="${CLAUDE_PROJECT_DIR:-${CWD:-$PWD}}$part" ;; esac
      else p="${CWD:-$PWD}/$p"; fi ;;
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

# Case-folded: on a case-insensitive volume, as macOS formats APFS, ~/.CLAUDE/HOOKS
# is ~/.claude/hooks. On a case-sensitive one a folded name is another file, and
# asking about it costs one question.
level_of() {   # level_of PATH DESTRUCTIVE [TREE]
  shopt -s nocasematch
  level_folded "$@"
  shopt -u nocasematch
}

# deny, harness, settings, plugins, startup, mods, skip, tree or nothing. TREE:
# a copy or extraction into PATH writes names the command does not show.
level_folded() {
  local p="$1" h c s d
  case "$p" in */.claude/settings.json|*/.claude/settings.local.json) echo settings; return ;; esac
  # The file tools reach mod-gate.sh, which reviews the mod; a removal adds no code.
  local mods=""
  [[ ("$TOOL" == Bash || "$TOOL" == Monitor) && -z "$REMOVING" ]] && mods=1
  if [[ -n "$mods" ]]; then
    case "$p" in
      */.claude/skills/?*/.claude-plugin/plugin.json) echo mods; return ;;
      */.claude/skills/?*)   # the nearest manifest, as mod-gate.sh finds the mod
        s=${p%%/.claude/skills/*}
        if [[ "$s" != "$p" ]]; then s="$s/.claude/skills"
        else   # a case variant, which ${p%%...} does not fold: the nearest skills/ above
          s=$p; while [[ "$s" == */.claude/skills/?* ]]; do s=${s%/*}; done
        fi
        d=$p
        while [[ "$d" == "$s/"?* ]]; do
          [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo mods; return; }
          d=${d%/*}
        done ;;
    esac
  fi
  for h in "$H" "$HR"; do
    c="$h/.claude"
    case "$p" in
      "$c/hooks/bash-guards.skip") echo skip; return ;;   # read by hooks/bash-guards.sh
      "$c/hooks"|"$c/hooks/"*) echo harness; return ;;
      "$c/dev-mods"|"$c/dev-mods/"*) [[ -n "$mods" ]] && { echo mods; return; } ;;
      # The Edit deny rules cover the file tools and, since 2.1.309, a redirect;
      # cp, tee and the rest reached the cache with nothing asking.
      "$c/plugins"|"$c/plugins/"*) echo plugins; return ;;
      "$c/"*.sh) [[ "${p:${#c}+1}" != */* ]] && { echo harness; return; } ;;   # by length: ${p#..} does not fold
      "$c") [[ "$2" == 1 ]] && { echo deny; return; } ;;
      "$h/.zshrc"|"$h/.zshenv"|"$h/.zprofile"|"$h/.zlogin"|"$h/.zlogout"|"$h/.bashrc"|"$h/.bash_profile"|"$h/.bash_login"|"$h/.profile"|"$h/.gitconfig"|"$h/.config/git/config"|"$h/Library/LaunchAgents/"*)
        echo startup; return ;;
    esac
  done
  # A tree into any .claude folder can write its settings.json, matched by suffix above.
  [[ -n "${3:-}" ]] && case "$p" in */.claude) echo tree ;; esac
}

# As written first, then with its folder resolved, so a symlink into
# ~/.claude/hooks counts as the real path.
classify_one() {   # classify_one ABS DESTRUCTIVE [TREE]
  local p="$1" d l
  l=$(level_of "$p" "$2" "${3:-}")
  if [[ -z "$l" ]]; then
    if [[ -d "$p" ]]; then d=$(cd "$p" 2>/dev/null && pwd -P) && l=$(level_of "$d" "$2" "${3:-}")
    else d=$(cd "${p%/*}" 2>/dev/null && pwd -P) && l=$(level_of "$d/${p##*/}" "$2" "${3:-}"); fi
  fi
  printf '%s' "$l"
}

# What the shell expands only when the command runs ($d, ${x:-y}, ~user) can be
# ~, so the part of WORD after the last such expansion is read as under ~ too:
# `d=$HOME; echo x > $d/.claude/hooks/lib.sh`. UNDER_HOME is that path, or
# empty for a word with none. $HOME and ~/ are resolved by abs_path instead.
under_home() {   # under_home WORD
  local u=${1//\"/}
  u=${u//\'/}; UNDER_HOME=""
  # $PWD and $CLAUDE_PROJECT_DIR at the start of a word abs_path resolved.
  [[ ${#BASES[@]} -eq 0 ]] && case "$u" in
    '$PWD'|'$PWD/'*|'${PWD}'|'${PWD}/'*|'$CLAUDE_PROJECT_DIR'|'$CLAUDE_PROJECT_DIR/'*|'${CLAUDE_PROJECT_DIR}'|'${CLAUDE_PROJECT_DIR}/'*)
      [[ "${u#?}" != *'$'* ]] && return ;;
  esac
  # shellcheck disable=SC2088  # '~' is the tilde as typed
  case "$u" in
    *'$'*) u=${u##*\$}
           case "$u" in HOME|HOME/*|'{HOME}'|'{HOME}/'*) return ;; '{'*) u=${u#*\}} ;; esac ;;
    '~'|'~/'*) return ;;
    '~'*) ;;
    *) return ;;
  esac
  case "$u" in */*) UNDER_HOME="$H/${u#*/}" ;; *) UNDER_HOME=$H ;; esac
}

check_word() {   # check_word WORD DESTRUCTIVE [TREE]
  local w="$1" p m l
  [[ -z "$w" ]] && return
  p=$(abs_path "$w")
  note "$(classify_one "$p" "$2" "${3:-}")" "$w"
  case "$p" in
    *'*'*|*'?'*|*'['*)   # a glob writes whatever it matches now
      while IFS= read -r m; do note "$(classify_one "$m" "$2" "${3:-}")" "$w"; done < <(compgen -G "$p" 2>/dev/null) ;;
  esac
  # Where an expansion this guard does not resolve ends, ~ is read too: it stops at ask.
  under_home "$w"
  if [[ -n "$UNDER_HOME" ]]; then
    l=$(classify_one "$(abs_path "$UNDER_HOME")" "$2" "${3:-}"); [[ "$l" == deny ]] && l=harness
    note "$l" "$w"
  fi
  # `cd DIR && cat > x` writes DIR/x: a relative word is read in each such DIR too.
  # shellcheck disable=SC2088  # '~' is the tilde as typed
  case "$w" in /*|'~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) return ;; esac
  # Which cd a word follows is not tracked, so what one raises stops at ask.
  for m in ${BASES[@]+"${BASES[@]}"}; do
    l=$(classify_one "$(CWD=$m; abs_path "$w")" "$2" "${3:-}"); [[ "$l" == deny ]] && l=harness
    note "$l" "$w"
  done
}

# A copy or move into folder DEST writes DEST/NAME for each source. A source
# whose names the command does not show (dir/, dir/., a glob, $f, {a,b}) can
# write any name there, so DEST itself is the target. Either way the target is
# checked as a tree: `cp -R x/.claude ~/` merges into ~/.claude. One source to a
# name that is not a folder yet (no trailing /) is copied to that name
# (`mv .claude .claude.bak`), but only where the guard knows that name: no
# expansion, ~user, glob or brace in it, and no cd in the command.
check_into() {   # check_into DEST SOURCE...
  local dest=$1 s b m
  shift
  s=${dest//\"/}; s=${s//\'/}
  # shellcheck disable=SC2088  # '~' is the tilde as typed
  case "$s" in
    *'$'*|*'{'*|*'*'*|*'?'*|*'['*|'~'[!/]*) ;;
    *) if [[ $# -eq 1 && "$s" != */ && ${#BASES[@]} -eq 0 && ! -d "$(abs_path "$s")" ]]; then
         check_word "$dest" 0 tree; return
       fi ;;
  esac
  case "$s" in *'*'*|*'?'*|*'['*)   # a folder a glob matches now
    while IFS= read -r m; do [[ -d "$m" ]] && check_into "$m/" "$@"; done < <(compgen -G "$(abs_path "$s")" 2>/dev/null) ;;
  esac
  for s in "$@"; do
    s=${s//\"/}; s=${s//\'/}
    case "$s" in [!/]*:*) s=${s#*:} ;; esac   # host:path, as scp and rsync take it
    b=${s##*/}
    case "$s" in *'$'*|*'{'*) b='*' ;; esac
    case "$b" in
      ''|.|..|*'*'*|*'?'*|*'['*) check_word "$dest" 0 tree ;;
      *) check_word "$dest/$b" 0 tree ;;
    esac
  done
}

# A later relative -C is read from the one before it, as bsdtar does:
# `-C ~ -C .claude/hooks` extracts into ~/.claude/hooks. An absolute or ~ one
# starts again. Each is also kept as written. It sets scan_segment's xdirs, xcur.
add_xdir() {   # add_xdir DIR
  local u=${1//\"/}
  u=${u//\'/}
  xdirs+=("$1")
  # shellcheck disable=SC2088  # '~' is the tilde as typed
  case "$u" in
    /*|'~'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) xcur=$1 ;;
    *) if [[ -n "$xcur" ]]; then xcur="$xcur/$1"; xdirs+=("$xcur"); else xcur=$1; fi ;;
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

# A tar or unzip option bundle, as getopt reads one: x extracts (tar), and l, t,
# p, v, z or Z only list or test (unzip). A letter that takes an argument takes
# the rest of the bundle (-C~/.claude), or else the next word; in tar's old form
# (xfC a.tar dir) each such letter takes the next word in turn. It sets
# scan_segment's extract, listing, xdirs and argq.
opt_bundle() {   # opt_bundle LETTERS [old]
  local b=$1 l
  while [[ -n "$b" ]]; do
    l=${b:0:1}; b=${b:1}
    case "$c:$l" in
      tar:x) extract=1 ;;
      unzip:[ltpvzZ]) listing=1 ;;
      tar:[CbfgTXs]|unzip:[dP])
        if [[ "$l" == C || "$l" == d ]]; then l=x; else l=s; fi
        if [[ -n "$b" && -z "${2:-}" ]]; then [[ "$l" == x ]] && add_xdir "$b"; return; fi
        argq="$argq$l" ;;
    esac
  done
}

scan_segment() {
  local words=() ops=() xdirs=() w i c n r destr=0 inplace=0 tdir="" next="" sub="" extract="" listing="" argq="" xcur=""
  set -f; read -ra words <<<"$1"; set +f
  [[ ${#words[@]} -eq 0 ]] && return
  c=${words[0]##*/}
  case "$c" in gtar|bsdtar) c=tar ;; esac
  for ((i = 1; i < ${#words[@]}; i++)); do
    w=${words[$i]}
    if [[ -n "$argq" ]]; then [[ "${argq:0:1}" == x ]] && add_xdir "$w"; argq=${argq:1}; continue; fi
    if [[ -n "$next" ]]; then
      if [[ "$next" == x && "$w" == -* ]]; then next=""   # a --di... that takes no folder
      else
        case "$next" in t) tdir=$w ;; o) check_word "$w" 0 ;; x) add_xdir "$w" ;; esac
        next=""; continue
      fi
    fi
    case "$c:$w" in
      cp:-t|mv:-t|install:-t|ln:-t|cp:--target-directory|mv:--target-directory|install:--target-directory|ln:--target-directory) next=t; continue ;;
      cp:-t?*|mv:-t?*|ln:-t?*) tdir=${w#-t}; continue ;;
      cp:-[!-]*t*|mv:-[!-]*t*|ln:-[!-]*t*)   # -vt DIR, -vtDIR
        r=${w#*t}; if [[ -n "$r" ]]; then tdir=$r; else next=t; fi; continue ;;
      # rsync's options that take a value: the value is no source or destination.
      rsync:--exclude|rsync:--include|rsync:--filter|rsync:-f|rsync:-e|rsync:--rsh|rsync:--exclude-from|rsync:--include-from|rsync:--files-from|\
      rsync:--log-file|rsync:--chmod|rsync:-T|rsync:--temp-dir|rsync:--compare-dest|rsync:--copy-dest|rsync:--link-dest|rsync:--backup-dir|\
      rsync:--partial-dir|rsync:--suffix|rsync:--max-size|rsync:--min-size|rsync:--timeout|rsync:--port|rsync:--password-file|rsync:--out-format|\
      rsync:--bwlimit|rsync:-[!-]*[efT]) next=s; continue ;;
      *:--target-directory=*) tdir=${w#*=}; continue ;;
      curl:-[a-zA-Z]*o|curl:--output|wget:-[a-zA-Z]*O|wget:--output-document) next=o; continue ;;
      curl:--output=*|wget:--output-document=*) check_word "${w#*=}" 0; continue ;;
      curl:-o?*) check_word "${w#-o}" 0; continue ;;
      dd:of=*) check_word "${w#of=}" 1; continue ;;
      sed:-i*|sed:-I*|sed:--in-place*|gsed:-i*|gsed:--in-place*|perl:-*i*|ruby:-*i*) inplace=1 ;;
      # Where tar and unzip extract to, and whether they do.
      tar:--cd=*|tar:--di*=*) add_xdir "${w#*=}"; continue ;;   # bsdtar takes --dir for --directory
      tar:--cd|tar:--di*) next=x; continue ;;
      tar:--extr*|tar:--get) extract=1 ;;
      tar:--*|unzip:--*) ;;
      tar:-?*|unzip:-?*) opt_bundle "${w#-}"; continue ;;
      tar:*) [[ $i == 1 ]] && { opt_bundle "$w" old; continue; } ;;   # tar xfC a.tar dir
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
        REMOVING=1; for w in "${ops[@]}"; do check_word "$w" 1; done; REMOVING="" ;;
    touch|tee|patch) for w in "${ops[@]}"; do check_word "$w" 0; done ;;
    chmod|chown|chgrp|chflags|xattr|setfacl)
        for w in "${ops[@]}"; do check_word "$w" "$destr"; done ;;
    sed|gsed|perl|ruby) [[ $inplace == 1 ]] && for w in "${ops[@]}"; do check_word "$w" 0; done ;;
    find) [[ "$sub" == destroy ]] && for w in "${ops[@]}"; do check_word "$w" 1; done ;;
    git) for ((i = 1; i < ${#words[@]}; i++)); do
           [[ "${words[$i]}" == config ]] && { git_config "${words[@]:$((i + 1))}"; break; }
         done ;;
  esac
  # What lands inside the folder written to: check_into. A tree written into a
  # .claude folder can hold hooks/ and settings.json, which the command never names.
  n=${#ops[@]}
  case "$c" in
    ln|cp|install|rsync|scp|mv)
      if [[ -n "$tdir" ]]; then [[ $n -gt 0 ]] && check_into "$tdir/" "${ops[@]}"
      elif [[ $n -gt 1 ]]; then check_into "${ops[n-1]}" "${ops[@]:0:n-1}"
      elif [[ "$c" == ln && $n == 1 ]]; then check_into ./ "${ops[0]}"; fi ;;
    ditto) [[ $n -gt 0 ]] && check_word "${ops[n-1]}" 0 tree ;;   # copies each source's contents
    tar) [[ -n "$extract" ]] && for w in "${xdirs[@]:-.}"; do check_word "$w" 0 tree; done ;;
    unzip) [[ -z "$listing" ]] && for w in "${xdirs[@]:-.}"; do check_word "$w" 0 tree; done ;;
  esac
}

case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit) check_word "$TARGET" 0 ;;
  Bash|Monitor)
    # Quoted separators hidden, groups opened, wrappers and /bin/ paths gone (lib.sh).
    DD=$(drop_data_heredocs "$TARGET"); unreadable_check config-guard "$DD"
    NQS=$(neutralize_quoted_separators "$DD")
    NORM=$(normalize_command "$NQS")
    REDIR='[0-9&]*>>?\|?[[:space:]]*[^[:space:];&|<>()]+'
    SEGS=()
    while IFS= read -r seg; do SEGS+=("$seg"); done < <(
      printf '%s\n' "$NORM" | sed -E "s/$REDIR//g; s/<[[:space:]]*[^[:space:];&|<>()]+//g" \
        | tr '\n' ';' | sed -E 's/\$\(/;/g; s/`/;/g; s/\|\||&&/;/g; s/[|;&]/\n/g')
    # hh follows the same cds from ~, once one went to an unresolved $d or ~user.
    here=${CWD:-$PWD}; hh=""
    for seg in ${SEGS[@]+"${SEGS[@]}"}; do
      set -f; read -ra words <<<"$seg"; set +f
      case "${words[0]:-}" in
        cd|pushd) if [[ ${#words[@]} -gt 1 ]]; then
                    w=${words[$((${#words[@]} - 1))]}; here=$(CWD=$here; abs_path "$w"); under_home "$w"
                    if [[ -n "$UNDER_HOME" ]]; then hh=$UNDER_HOME
                    elif [[ -n "$hh" ]]; then case "$w" in /*|'~'*|'$'*) hh="" ;; *) hh=$(CWD=$hh; abs_path "$w") ;; esac; fi
                  else here=$H; hh=""; fi
                  BASES+=("$here"); [[ -n "$hh" ]] && BASES+=("$hh") ;;
      esac
    done
    while IFS= read -r w; do
      [[ "$w" == '&'* ]] || check_word "$w" 0
    done < <(printf '%s\n' "$NORM" | grep -oE "$REDIR" | sed -E 's/^[0-9&]*>>?\|?[[:space:]]*//')
    for seg in ${SEGS[@]+"${SEGS[@]}"}; do
      scan_segment "$seg"
    done
    ;;
esac

case "$WORST" in
  deny) emit_deny "$REASON" ;;
  ask) emit_ask "$REASON" ;;
esac
exit 0
