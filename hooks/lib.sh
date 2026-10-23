#!/usr/bin/env bash
# Shared helpers for Claude Code harness hooks.
# Source from every hook: source "$(dirname "$0")/lib.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Expand leading ~ in a path; needed because the hook runtime passes env
# values verbatim without shell expansion.
expand_tilde() {
  local p="$1"
  printf '%s\n' "${p/#\~/$HOME}"
}

# Strip tokens that sit in front of a command without changing what runs:
# env assignments (FOO=bar), `env`, and the wrapper commands Claude Code itself
# strips before matching a permission rule (timeout/time/nice/nohup/stdbuf/
# command/builtin/noglob).
#
# Why this is shared: guards that anchor their regexes to a command boundary
# only admit ^, |, &, ;, &&, ||, $( and a backtick. A leading assignment or
# wrapper is none of those, so `VAR=1 git push -f` and `nohup git push -f`
# matched nothing and were allowed silently, while the bare form was denied.
# kubectl-guard was immune only because it tokenises and scans for the binary
# anywhere; git-guard is regex-anchored and was not. Normalising here keeps one
# implementation instead of two divergent ones.
#
# Stripping is applied per segment so a boundary is preserved:
#   `cd /x && VAR=1 nohup git push -f`  ->  `cd /x && git push -f`
# Four passes handle stacked prefixes (`env A=1 B=2 nohup timeout 60 git …`);
# a fixed count avoids sed label/branch syntax, which differs on BSD and GNU.
# Every expression works within one line, so the passes run as one sed: each
# Bash guard calls this, and five sed processes cost ~12 ms against one.
# Output feeds pattern matching only — never execution — so a mangled quote is
# harmless, and ambiguity makes the guards fail closed by design.
normalize_wrappers() {
  local s i e=()
  # Give a command-substitution opener its own whitespace BEFORE the assignment
  # rule runs. Without this the assignment pattern swallows the substitution
  # body — `X=$(kubectl delete pod foo)` normalised to `delete pod foo)`, and
  # the kubectl scan then found nothing at all. The openers are separated, not
  # removed: git-guard anchors on `$(` as a command boundary.
  e=(-e 's/\$\(/ $( /g; s/`/ ` /g')
  # A value ends at an unquoted `;`, `&` or `|`: `X=1;git push -f` lost its git.
  # Quoted or escaped, it keeps them (`X='a b' git push -f`, `X=a\;b git …`).
  for i in 1 2 3 4; do
    e+=(
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)[A-Za-z_][A-Za-z0-9_]*=([^[:space:];\&|"'\'']|\\.|'\''[^'\'']*'\''|"[^"]*")*[[:space:]]+/\1\2/g'
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)(command|builtin|noglob|nohup|time|if|then|else|elif|do|while|until|function|!)[[:space:]]+/\1\2/g'
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)(nice([[:space:]]+-n[[:space:]]*[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|stdbuf([[:space:]]+-[ioe][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|env([[:space:]]+-[uSCP][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|sudo([[:space:]]+-[ugCph][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|doas([[:space:]]+-[uC][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|ionice([[:space:]]+-[cnp][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|exec([[:space:]]+-a[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|caffeinate([[:space:]]+-[tw][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*|xargs([[:space:]]+-[IndPLsEa][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*)[[:space:]]+/\1\2/g'
      -e 's/(^|[|&;`]|&&|\|\||\$\()([[:space:]]*)timeout[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[0-9]+[smhd]?[[:space:]]+/\1\2/g')
  done
  s=$(printf '%s' "$1" | sed -E "${e[@]}")
  printf '%s' "$s"
}

# `{ git push -f; }`, `(printenv)`, `if X; then`, `! X` and a case arm put the
# command after a character or word no boundary pattern admitted, and four
# guards went silent. Outside quotes, `(` (not `$(`), `)`, and a `{` or `}`
# standing alone become `;`; normalize_wrappers strips the reserved words.
# Run it on text whose quotes are intact. A heredoc body is another program's
# input (python parens, a comment's apostrophe), so it is left alone unless a
# shell reads it.
separate_groups() {
  case "$1" in *'('*|*')'*|*'{'*|*'}'*) ;; *) printf '%s' "$1"; return ;; esac
  printf '%s\n' "$1" | awk '
    BEGIN { q = ""; body = 0 }
    body { t = $0; if (dash) sub(/^\t+/, "", t)
           if (t == term) { body = 0; q = ""; print; next }
           if (!shell) { print; next } }
    { out = ""; n = length($0); hd = ""
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1); p = (i > 1) ? substr($0, i - 1, 1) : ""; x = substr($0, i + 1, 1)
        if (c == "\\" && q != "\047") { out = out c x; i++; continue }
        if (q == "" && c == "<" && x == "<" && p != "<" && hd == "" \
            && match(substr($0, i + 2), /^-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
          hd = substr($0, i + 2, RLENGTH); hdash = (hd ~ /^-/); sub(/^-?[ \t]*["\047]?/, "", hd)
          hshell = (substr($0, 1, i - 1) ~ /(^|[;&|])[ \t]*(bash|sh|zsh|dash|ksh)([ \t][^;&|]*)?$/)
        }
        if (q == "") {
          if (c == "\047") q = (p == "$") ? "A" : "\047"
          else if (c == "\"") q = "\""
          else if ((c == "(" && p != "$") || c == ")") c = ";"
          else if ((c == "{" || c == "}") && (p == "" || p ~ /[ \t;&|]/) && (x == "" || x ~ /[ \t;&|]/)) c = ";"
        } else if (c == "\047" && (q == "\047" || q == "A")) q = ""
        else if (c == "\"" && q == "\"") q = ""
        out = out c
      }
      print out
      if (hd != "") { body = 1; term = hd; dash = hdash; shell = hshell; q = "" } }'
}

# A function that runs "$@" makes its arguments a command: after
# `probe() { …; "$@"; }`, `probe "label" python3 -c …` runs python3 where no
# boundary pattern looks. Print each call's argument suffixes, one per line.
exec_fn_suffixes() {
  case "$1" in *'$@'*|*'$*'*) ;; *) return ;; esac
  local names
  names=$(printf '%s\n' "$1" \
    | grep -oE '(^|[^A-Za-z0-9_-])[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\([[:space:]]*\)|function[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*' \
    | sed -E 's/^function[[:space:]]+//; s/[[:space:]]*\([[:space:]]*\)$//; s/^[^A-Za-z_]//' | sort -u | tr '\n' ' ')
  [[ -n "${names// /}" ]] || return
  separate_groups "$1" | tr '\n' ';' | sed -E 's/\|\||&&/;/g; s/[|;&]/\n/g' | awk -v names=" $names" '
    { n = split($0, w, /[ \t]+/); i = (w[1] == "") ? 2 : 1
      if (i > n || index(names, " " w[i] " ") == 0) next
      for (k = i + 1; k <= n && k <= i + 5; k++) { s = w[k]; for (j = k + 1; j <= n; j++) s = s " " w[j]; print s } }'
}

# The shell runs `/usr/bin/git`, `"git"`, `\git` and, on the default
# case-insensitive macOS filesystem, `GIT` as git. Rewrite the first word of
# each command to its bare lower-case name; arguments are never touched, and
# neither is an assignment (`X=/usr/bin/git` is not a command).
# A word can end in a quote that closes text around it: `"$(ENV)"`, or the tail
# of a quoted jq filter after a `(`. Dropping that quote left the line unbalanced
# and env-guard's jq check read the filter as file names, so the last unpaired
# quote of each kind goes back after the name, in its order.
normalize_binaries() {
  printf '%s' "$1" | awk '
    function last(s, c,   i) { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == c) return i; return 0 }
    function fix(seg,   pre, tok, t, n, q, d, a, keep) {
      match(seg, /^[ \t]*/); pre = substr(seg, 1, RLENGTH); seg = substr(seg, RLENGTH + 1)
      if (!match(seg, /^[^ \t]+/)) return pre seg
      n = RLENGTH; tok = substr(seg, 1, n)
      if (tok ~ /=/) return pre seg
      t = tok; sub(/^\\/, "", t); gsub(/["\047]/, "", t); sub(/.*\//, "", t)
      if (t == "") return pre seg
      q = tok; d = (gsub(/"/, "", q) % 2) ? last(tok, "\"") : 0; a = (gsub(/\047/, "", q) % 2) ? last(tok, "\047") : 0
      keep = (d && a) ? (d < a ? "\"\047" : "\047\"") : (d ? "\"" : (a ? "\047" : ""))
      return pre tolower(t) keep substr(seg, n + 1)
    }
    { out = ""; s = $0   # fix() calls match(), so keep RSTART and RLENGTH first
      while (match(s, /&&|[|][|]|[|&;`(]|[$][(]/)) {
        a = RSTART; b = RLENGTH
        out = out fix(substr(s, 1, a - 1)) substr(s, a, b)
        s = substr(s, a + b)
      }
      print out fix(s) }'
}

# Binaries, then wrappers, then binaries again: `sudo /usr/bin/git` needs the
# wrapper gone before its binary is at a boundary. Guards scan this alongside
# the original, never instead of it, so a rewrite can only add a match.
# separate_groups goes first: normalize_binaries drops quotes from a first word,
# and the group pass needs them to tell `"a (b)"` from `(b)`.
normalize_command() {
  local s x
  s=$(separate_groups "$1"); x=$(exec_fn_suffixes "$1")
  [[ -n "$x" ]] && s="$s"$'\n'"$x"
  s=$(normalize_binaries "$s"); s=$(normalize_wrappers "$s"); s=$(normalize_binaries "$s")
  printf '%s' "${s:-$1}"
}

# A heredoc fed to `git commit -F -` or `gh pr|issue … --body-file -` is a
# commit message or PR body: nothing runs it, whatever else the line does. The
# body goes; the opener and terminator stay, so the command itself is scanned
# and a later pass still sees a balanced heredoc. An unquoted delimiter has the
# shell run $(...) and backticks in the body, so such a body holding $ or ` stays.
# `-m "$(cat <<'EOF'` is the same message when the line ends at the delimiter:
# anything after it (`| bash`) would run the body.
strip_message_heredocs() {
  case "$1" in *'<<'*) ;; *) printf '%s' "$1"; return ;; esac
  printf '%s\n' "$1" | awk '
    body { t = $0; if (dash) sub(/^\t+/, "", t)
           if (t == term) { if (buf ~ /[$`]/) printf "%s", buf; body = 0; buf = ""; print }
           else if (!lit) buf = buf $0 "\n"
           next }
    { print
      if (match($0, /<<-?[ \t]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
        pre = substr($0, 1, RSTART - 1); n = split(pre, seg, /\|\||&&|[|;&]/); last = seg[n]
        oq = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", oq); oq = substr(oq, 1, 1)
        post = substr($0, RSTART + RLENGTH); if (oq == "\047" || oq == "\"") sub("^" oq, "", post)
        if (last ~ /^[ \t]*(git[ \t]+(-[^ \t]+[ \t]+)*commit|gh[ \t]+(pr|issue))[ \t]/ \
            && (last ~ /(^|[ \t])(-F|--file|--body-file)[ \t]*=?[ \t]*-([ \t]|$)/ \
                || (last ~ /(^|[ \t])(-[A-Za-z]*m|--message|-[tb]|--title|--body)[ \t]*=?[ \t]*"\$\([ \t]*cat[ \t]*$/ \
                    && post ~ /^[ \t]*$/))) {
          term = substr($0, RSTART + 2, RLENGTH - 2); dash = (term ~ /^-/)
          lit = (term ~ /^-?[ \t]*["\047\\]/); buf = ""
          sub(/^-?[ \t]*["\047\\]?/, "", term); body = 1 } } }
    END { if (body && buf ~ /[$`]/) printf "%s", buf }'
}

# A quoted -m or --message to git commit, or -t, -b, --title or --body to gh
# pr|issue, is text git or gh stores and nothing runs, so its words become `msg`:
# `git commit -m 'note; git push --force is denied'` is not a force push. A
# double-quoted one holding $ or ` stays. Anything this does not model (a heredoc,
# a backtick, $', a # comment, $( or ${ in double quotes, an unclosed quote)
# leaves the whole command as typed.
strip_message_args() {
  case "$1" in *commit*|*gh*) ;; *) printf '%s' "$1"; return ;; esac
  case "$1" in *\'*|*\"*) ;; *) printf '%s' "$1"; return ;; esac
  printf '%s\n' "$1" | awk '
    function msgflag(    g) {
      if (seg ~ /^[ \t]*git[ \t]+((-[cC][ \t]+[^ \t]+|-[^ \t]+)[ \t]+)*commit[ \t]/) g = "(-[A-Za-z]*m|--message)"
      else if (seg ~ /^[ \t]*gh[ \t]+(pr|issue)[ \t]+[a-z-]+[ \t]/) g = "(-[tb]|--title|--body)"
      else return 0
      return (word == "" && prev ~ ("^" g "$")) || word ~ ("^" g "=?$")
    }
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
      n = length(s); out = ""; seg = ""; word = ""; prev = ""; q = ""; i = 1
      while (i <= n) {
        c = substr(s, i, 1); t = c
        if (q == "\047") { if (c == q) q = "" }
        else if (q == "\"") {
          if (c == "`" || substr(s, i, 2) ~ /^\$[({]$/) { print s; exit }
          if (c == "\\") t = substr(s, i, 2); else if (c == q) q = ""
        } else if (c == "\\") t = substr(s, i, 2)
        else if (substr(s, i, 3) == "<<<") t = "<<<"
        else if (c == "`" || substr(s, i, 2) == "<<" || substr(s, i, 2) == "$\047" || (c == "#" && word == "")) { print s; exit }
        else if (c == "\047" || c == "\"") {
          if (msgflag()) {
            j = i + 1; ok = 1
            while (j <= n && substr(s, j, 1) != c) {
              if (c == "\"" && substr(s, j, 1) == "\\") j++
              else if (c == "\"" && substr(s, j, 1) ~ /[$`]/) ok = 0
              j++
            }
            if (j > n) { print s; exit }
            if (ok) { t = c "msg" c; out = out t; seg = seg t; word = word t; i = j + 1; continue }
          }
          q = c
        } else if (c ~ /[;&|()\n]/) { out = out c; seg = ""; word = ""; prev = ""; i++; continue }
        else if (c == " " || c == "\t") { if (word != "") prev = word; word = ""; out = out c; seg = seg c; i++; continue }
        out = out t; seg = seg t; word = word t; i += length(t)
      }
      if (q != "") { print s; exit }
      print out
    }'
}

# Text written to a notes file is not a command. Drop heredoc bodies from the
# scan only when every segment is an inert writer or reader, or only assignments,
# and every redirect target is a prose file; anything else keeps the body in.
# A value may name a $VAR but run nothing. `X=1 bash` is bash, not an assignment:
# read as one, its heredoc ran unscanned.
INERT_WORD='("([^"$`]|\$[{]?[A-Za-z_])*"|'"'[^']*'"'|([^[:space:]$`'"'"'"]|\$[{]?[A-Za-z_])*)'
INERT_SEG='^((cat|tee|cd|mkdir|echo|printf|true|wc|ls|head|tail|stat|file|du|grep|pwd)([[:space:]]|$)|([A-Za-z_][A-Za-z0-9_]*='"$INERT_WORD"'([[:space:]]+|$))+$)'
strip_inert_heredocs() {
  local s="$1" rest
  case "$s" in *'<<'*) ;; *) printf '%s' "$s"; return ;; esac
  s=$(strip_message_heredocs "$s")
  # An unquoted body holding $ or ` is expanded by the shell, so it stays (lib.sh above).
  rest=$(printf '%s\n' "$s" | awk '
    body { if ($0 ~ ("^[ \t]*" term "[ \t]*$")) { if (buf ~ /[$`]/) printf "%s", buf; body = 0; buf = "" }
           else if (!lit) buf = buf $0 "\n"
           next }
    match($0, /<<-?[ \t]*["'"'"'\\]?[A-Za-z_][A-Za-z0-9_]*/) {
      term = substr($0, RSTART, RLENGTH); lit = (term ~ /^<<-?[ \t]*["'"'"'\\]/); buf = ""
      sub(/^<<-?[ \t]*["'"'"'\\]?/, "", term); body = 1 }
    { print }
    END { if (body && buf ~ /[$`]/) printf "%s", buf }')
  if printf '%s\n' "$rest" | tr '\n' ';' | sed -E 's/\|\||&&/;/g; s/[|;&]/\n/g' | sed -E 's/^[[:space:]]+//' \
       | grep -vE '^[[:space:]]*$' | grep -qvE "$INERT_SEG"; then
    printf '%s' "$s"; return
  fi
  # Every target must be prose: each > or >> target, and every file tee is given
  # (`tee a.md b.sh` writes both; reading only the first let a script through).
  # A whole-word "$F" assigned once in this command is its value.
  if { printf '%s\n' "$rest" | grep -oE '>>?[[:space:]]*[^[:space:];&|<]+' | sed -E 's/^>>?[[:space:]]*//'
       printf '%s\n' "$rest" | tr '\n' ';' | sed -E 's/\|\||&&/;/g; s/[|;&]/\n/g; s/>>?[[:space:]]*[^[:space:];&|<]+//g' \
         | sed -E 's/^[[:space:]]+//' | grep -E '^tee([[:space:]]|$)' | tr -s ' \t' '\n' | grep -vxE 'tee|-.*'
     } | grep -v '^$' | awk '
       function unq(t) { if (t ~ /^".*"$/ || t ~ /^\047.*\047$/) t = substr(t, 2, length(t) - 2); return t }
       NR == FNR { if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) { k = substr($0, 1, RLENGTH - 1); n[k]++; v[k] = unq(substr($0, RLENGTH + 1)) } next }
       { t = unq($0); k = t; gsub(/^\$[{]?|[}]$/, "", k)
         if (t ~ /^\$[{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/ && n[k] == 1) t = v[k]
         print t }' <(printf '%s\n' "$rest" | tr '\n' ';' | sed -E 's/\|\||&&/;/g; s/[|;&]/\n/g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//') - \
       | grep -qvE '\.(md|txt|rst|log|csv)$'; then
    printf '%s' "$s"; return
  fi
  printf '%s' "$rest"
}

# A quoted or backslash-escaped `&`, `;` or `|` is text, not a separator, but the
# guards' [^|;&] spans stop at it and hid the flags after it. Rewritten to %26,
# %3B, %7C for matching only. An unquoted one, URL or not, still separates.
# A $( inside double quotes starts unquoted text again, until its own ).
neutralize_quoted_separators() {
  case "$1" in *'&'*|*';'*|*'|'*) ;; *) printf '%s' "$1"; return ;; esac
  printf '%s\n' "$1" | awk '
    function hide(ch) { return ch == "&" ? "%26" : ch == ";" ? "%3B" : ch == "|" ? "%7C" : ch }
    BEGIN { q = ""; sp = 0 }
    { out = ""; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\" && q != "\047") { out = out c hide(substr($0, i + 1, 1)); i++; continue }
        if (q == "\"" && c == "$" && substr($0, i + 1, 1) == "(") { up[++sp] = q; depth[sp] = 1; q = ""; out = out "$("; i++; continue }
        if (q == "" && sp > 0 && c == "(") depth[sp]++
        if (q == "" && sp > 0 && c == ")" && --depth[sp] == 0) { q = up[sp--]; out = out c; continue }
        if (q == "") {
          if (c == "\047") q = (i > 1 && substr($0, i - 1, 1) == "$") ? "A" : "\047"
          else if (c == "\"") q = "\""
        } else if (c == "\047" && (q == "\047" || q == "A")) q = ""
        else if (c == "\"" && q == "\"") q = ""
        else c = hide(c)
        out = out c
      }
      print out }'
}

# This session's scratch folder. A background session gets ~/.claude/jobs/<the
# first 8 characters of its session id>/tmp, and a hook's environment has no
# CLAUDE_JOB_DIR, so it is derived. Empty for an interactive session.
session_scratch() {   # $1: the command and cwd, when the caller has them
  local sid d re='jobs/|CLAUDE_JOB_DIR|claude-[0-9]'
  sid=$(jq_get '.session_id')
  [[ "$sid" =~ ^[0-9a-f]{8}- ]] || return 0
  [[ -d "$HOME/.claude/jobs/${sid:0:8}" ]] && { printf '%s\n' "$HOME/.claude/jobs/${sid:0:8}/tmp"; return 0; }
  # A resumed job keeps its folder under the first session's id and runs under
  # a new one; its state.json names the new id. Measured: every rm-guard deny
  # on one Mac (2026-09-24 to 2026-10-15) was a resumed job's own scratch.
  # Only a path naming a job folder can land in one, so skip the scan otherwise.
  [[ $# -eq 0 || "$1" =~ $re ]] || return 0
  for d in "$HOME"/.claude/jobs/*/; do
    [[ -f "$d/state.json" ]] || continue
    grep -qE "\"(sessionId|resumeSessionId)\":[[:space:]]*\"$sid\"" "$d/state.json" 2>/dev/null \
      && { printf '%s\n' "${d%/}/tmp"; return 0; }
  done
  return 0
}

# Run a command under a wall-clock cap. perl's alarm is on every macOS and Linux
# this runs on (tests/guard-latency.test.sh relies on it); without perl the
# command runs uncapped and Claude Code's own hook timeout applies.
run_bounded() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"; else "$@"; fi
}

# Is path $1, as typed, inside scratch folder $2 (or strictly inside TMPDIR)?
# Understands quotes, ~, $HOME, $CLAUDE_JOB_DIR and $TMPDIR; any other
# expansion or a `..` is never inside. $3 resolves a relative path; empty, never.
# Prints the resolved path when it is inside.
in_scratch() {
  local p="$1" scratch="$2" base="$3" t="${TMPDIR:-}"
  p="${p//\"/}"; p="${p//\'/}"; t="${t%/}"
  [[ -n "$p" ]] || return 1
  case "$p" in *..*) return 1 ;; esac
  # shellcheck disable=SC2088  # '~/' is the tilde as typed; it is expanded below
  case "$p" in
    '$CLAUDE_JOB_DIR/'*|'${CLAUDE_JOB_DIR}/'*) [[ -n "$scratch" ]] || return 1; p="${scratch%/tmp}/${p#*/}" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    '$HOME/'*|'${HOME}/'*) p="$HOME/${p#*/}" ;;
    '$TMPDIR/'*|'${TMPDIR}/'*) [[ -n "$t" ]] || return 1; p="$t/${p#*/}" ;;
    /*) ;;
    *) [[ -n "$base" ]] || return 1; p="${base%/}/$p" ;;
  esac
  case "$p" in *'$'*|*'`'*) return 1 ;; esac
  if [[ -n "$scratch" && ( "$p" == "$scratch" || "$p" == "$scratch/"* ) ]] || [[ -n "$t" && "$p" == "$t/"?* ]]; then
    printf '%s\n' "$p"; return 0
  fi
  # Sandboxed commands get TMPDIR=/tmp/claude-<uid>, and a job's Bash temp files
  # can sit in $TMPDIR/<job id>, accepted below. Hooks run outside the sandbox.
  local sb
  if [[ -n "$scratch" ]]; then
    sb="${scratch%/tmp}"; sb="/tmp/claude-$UID/${sb##*/}"
    case "$p" in "$sb"|"$sb/"*|"/private$sb"|"/private$sb/"*) printf '%s\n' "$p"; return 0 ;; esac
  fi
  return 1
}

# Read full stdin once into $INPUT. Safe to call with no stdin.
read_input() {
  if [[ -t 0 ]]; then
    INPUT=""
  else
    INPUT=$(cat)
  fi
  export INPUT
}

# Fail closed for PreToolUse guards: without jq we cannot reliably parse the
# tool input to make a security decision, so deny rather than silently allow.
# Call this immediately after read_input in every deny-capable Bash/file guard.
# Only denies when there is actually input to evaluate (a real tool call).
require_jq_or_deny() {
  command -v jq &>/dev/null && return 0
  [[ -z "$INPUT" ]] && return 0
  emit_deny "Blocked: the security harness cannot parse this tool call because jq is not installed, and it will not allow commands it cannot inspect. Install jq (brew install jq) and retry."
  exit 0
}

# Fail closed when the payload will not parse. require_jq_or_deny covers jq
# being absent; this covers jq being present and failing on the input. jq_get
# sends that failure to /dev/null and returns "", which every guard reads as
# "no command in this payload" and exits 0 on — so a truncated or corrupted
# payload was a full allow, not a smaller block, and the call went on to the
# permissions list or the auto-mode classifier with no guard opinion at all.
# Call immediately after require_jq_or_deny in every deny-capable guard.
#
# An absent or empty FIELD on parseable input is a different thing and stays
# legitimate: every guard is registered on tools it does not inspect. So this
# tests the document, not the field. No stdin is not a tool call either (hooks
# get run by hand and by the tests), so it is left alone.
require_parsable_or_deny() {
  [[ -z "$INPUT" ]] && return 0
  command -v jq &>/dev/null || return 0
  printf '%s' "$INPUT" | jq empty 2>/dev/null && return 0
  emit_deny "Blocked: the security harness could not parse this tool call as JSON, and it will not allow a command it cannot inspect. Retry the call; if it repeats, the hook input is malformed."
  exit 0
}

# Extract a field from $INPUT using jq. Empty if jq is missing or field absent.
jq_get() {
  local expr="$1"
  if command -v jq &>/dev/null; then
    printf '%s\n' "$INPUT" | jq -r "$expr // \"\"" 2>/dev/null
  fi
}

# First N bytes of stdin, minus a character the cut split. head -c and GNU
# cut -c both count bytes, so either can leave half a multibyte character and an
# audit line no UTF-8 reader accepts; iconv -c drops the partial one.
head_utf8() {
  head -c "$1" | if command -v iconv >/dev/null; then iconv -f UTF-8 -t UTF-8 -c 2>/dev/null; else cat; fi
}

# One audit line per guard decision. The PostToolUse audit only sees calls that
# ran, so without this a deny left no record at all. The target is the command,
# path or URL, never file content: secret-scanner denies on content.
log_decision() {
  local target=""
  command -v jq &>/dev/null && target=$(printf '%s' "$INPUT" \
    | jq -j '.tool_input | .command // .file_path // .path // .notebook_path // .url // ""' 2>/dev/null \
    | tr '\n\t' '  ' | head_utf8 200)
  log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ) | GUARD | $1 | $(basename "$0" .sh) | ${target:-unknown} | $PWD"
}

# Emit a PreToolUse deny decision with a reason. Safe against quotes/backslashes.
emit_deny() {
  local reason="$1"
  log_decision deny
  if command -v jq &>/dev/null; then
    jq -nc --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
      "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# --- Inline scripts ---------------------------------------------------------
# An inline script (-c, -e, a heredoc an interpreter reads) is text, but what it
# hands a shell-out runs. inline_script_view TOOL OPQMODE CMD prints each such
# line that names TOOL, ended by \002, then \001, then CMD without the scripts'
# text. OPQMODE "ask" marks a shell-out it cannot rebuild; "flat" reads its words.
# Not read: a script file, `cat <<EOF | python3`, a heredoc under a wrapper.
inline_script_view() {
  printf '%s\n' "$3" | awk -v TOOL="$1" -v OPQMODE="$2" '
    BEGIN { NO = "\003"; OPQ = "__OPAQUE_SHELLOUT__\002"; KRE = "(^|[^A-Za-z0-9_.-])" TOOL "([^A-Za-z0-9_.-]|$)"
            SAFE = "^(head|tail|grep|egrep|fgrep|rg|wc|sort|uniq|cut|tr|cat|less|more|jq|column|fold|nl)$" }
    function langof(w) { return w ~ /python/ ? "py" : w ~ /ruby/ ? "rb" : w ~ /perl/ ? "pl" : w ~ /php/ ? "php" : "js" }
    function trim(s) { sub(/^[ \t\n]+/, "", s); sub(/[ \t\n]+$/, "", s); return s }
    function shellouts(p, lang,    out, rest, a, st, j, d, q, c, names, call, cm, mode) {
      gsub(/(^|\n)[ \t]*(#|\/\/)[^\n]*/, "\n", p)
      names = p ~ KRE
      call = "(subprocess\\.[A-Za-z_]+|os\\.(system|popen|exec[a-z]*|spawn[a-z]*)|Popen|check_output|check_call|getoutput|getstatusoutput|execSync|execFileSync|spawnSync|execFile|execa|IO\\.popen|Open3\\.[A-Za-z0-9_]+|(^|[^A-Za-z0-9_])(system|exec|spawn|qx|%x))[ \t]*\\("
      if (p ~ /from[ \t]+subprocess[ \t]+import/) call = "(" call "|(^|[^A-Za-z0-9_.])(run|call)[ \t]*\\()"
      out = ""; rest = p
      while (match(rest, call)) {
        cm = substr(rest, RSTART, RLENGTH); st = RSTART + RLENGTH; d = 1; q = ""; j = st
        while (j <= length(rest) && d > 0) {
          c = substr(rest, j, 1)
          if (q != "") { if (c == "\\") j++; else if (c == q) q = "" }
          else if (c == "\"" || c == "\047" || c == "`") q = c
          else if (c == "(") d++
          else if (c == ")") d--
          j++
        }
        a = substr(rest, st, j - st - 1); rest = substr(rest, j)
        mode = cm ~ /(qx|%x)[ \t]*\($/ ? "shell" : (lang == "py" && cm ~ /(^|[^A-Za-z0-9_.])exec[ \t]*\($/) ? "code" : "args"
        out = out view(a, names, mode, lang)
      }
      # Backticks and a bare `system "..."` run a shell in ruby, perl and php only.
      if (lang !~ /^(rb|pl|php)$/) return out
      rest = p
      while (match(rest, /`[^`]*`|(^|[^A-Za-z0-9_.])(system|exec)[ \t]+["\047][^\n;]*/)) {
        a = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (a ~ /^`/) out = out view(substr(a, 2, length(a) - 2), names, "shell", lang)
        else { sub(/^[^A-Za-z0-9_.]?(system|exec)[ \t]+/, "", a); out = out view(a, names, "args", lang) }
      }
      return out
    }
    # Top-level split on sep, outside quotes and brackets.
    function splitargs(a, arr, sep,    n, i, c, q, d, cur) {
      n = 0; q = ""; d = 0; cur = ""
      for (i = 1; i <= length(a); i++) {
        c = substr(a, i, 1)
        if (q != "") { cur = cur c; if (c == "\\") { i++; cur = cur substr(a, i, 1) } else if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047" || c == "`") q = c
        else if (c == "(" || c == "[" || c == "{") d++
        else if (c == ")" || c == "]" || c == "}") d--
        else if (c == sep && d == 0) { arr[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      arr[++n] = cur
      return n
    }
    # A string literal (r, b, f or u prefix, triple quotes) and nothing else: its
    # text. An f-string field is a value, so it reads as an unset $var.
    function str(x,    p, q, i, c, out, f) {
      if (!match(x, /^[rRbBfFuU]?[rRbBfFuU]?["\047`]/)) return NO
      f = substr(x, 1, RLENGTH) ~ /[fF]/; q = substr(x, RLENGTH, 1); p = substr(x, RLENGTH + 1)
      if (substr(p, 1, 2) == q q) out = substr(x, length(x) - 2) == q q q ? substr(p, 3, length(p) - 5) : NO
      else {
        out = NO
        for (i = 1; i <= length(p); i++) {
          c = substr(p, i, 1)
          if (c == "\\") { i++; continue }
          if (c == q) { if (i == length(p)) out = dropesc(substr(p, 1, i - 1)); break }
        }
      }
      if (f && out != NO) gsub(/\{[^{}]*\}/, "$__shellout_value", out)
      return out
    }
    function dropesc(s,    i, c, out) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\") { i++; c = substr(s, i, 1) } out = out c }
      return out
    }
    # Strings, lists and names joined by +, and " ".join([...]): as shell words.
    # A name is an unset $var, so a verb or kind it supplies asks as it does typed.
    function literal(x,    np, parts, i, v, out, list, prev) {
      x = trim(x)
      if (x ~ /^["\047][^"\047]*["\047]\.join\(\[.*\]\)$/) { i = index(x, ".join("); x = substr(x, i + 6, length(x) - i - 6) }
      np = splitargs(x, parts, "+")
      if (np == 1) return words(x)
      out = ""; prev = 0
      for (i = 1; i <= np; i++) {
        v = trim(parts[i]); list = v ~ /^\[/
        v = v ~ /^[A-Za-z_][A-Za-z0-9_.]*$/ ? "$__shellout_value" : words(v)
        if (v == NO) return NO
        out = out ((i > 1 && (list || prev)) ? " " : "") v; prev = list
      }
      return out
    }
    function words(x,    n, el, i, v, out) {
      if (x !~ /^\[.*\]$/) return str(x)
      n = splitargs(substr(x, 2, length(x) - 2), el, ","); out = ""
      for (i = 1; i <= n; i++) {
        v = trim(el[i]); if (v == "" && i == n) continue
        if (v ~ /^[A-Za-z_][A-Za-z0-9_.]*$/) v = "$__shellout_value"
        else {
          v = str(v); if (v == NO) return NO
          if (v !~ /^[A-Za-z0-9_.\/:=@%+,-]+$/) { gsub(/\047/, "", v); v = "\047" v "\047" }
        }
        out = out (out == "" ? "" : " ") v
      }
      return out
    }
    # Printed to a text command or /dev/null, the script stays text. Printed to a
    # shell, a file or anything else, its output may run, so it stays in the scan.
    function outsafe(t,    n, p, i, w) {
      gsub(/[0-9]*>&[0-9-]+/, "", t); gsub(/[0-9]*>>?[ \t]*\/dev\/null/, "", t)
      sub(/(;|&&|\|\||&|\n).*/, "", t)
      if (t ~ />/) return 0
      n = split(t, p, "|")
      for (i = 2; i <= n; i++) { w = trim(p[i]); sub(/[ \t].*/, "", w); sub(/.*\//, "", w); if (w !~ SAFE) return 0 }
      return 1
    }
    # Output that may run: each string literal that names TOOL is a line to check.
    function strviews(p,    out, m) {
      out = ""
      while (match(p, /"[^"\n]*"|\047[^\047\n]*\047/)) {
        m = substr(p, RSTART + 1, RLENGTH - 2); p = substr(p, RSTART + RLENGTH)
        if (m ~ KRE) out = out m "\002"
      }
      return out
    }
    function flat(s) { s = substr(s, match(s, KRE)); gsub(/[][(){}"\047,`+\\\n]/, " ", s); return s "\002" }
    # The shell line a shell-out runs. Keyword arguments and option objects are
    # skipped. One it cannot rebuild, or whose command word is a value, is marked
    # in "ask" mode when it or the script names TOOL; "flat" reads its words.
    function view(a, names, mode, lang,    n, arg, i, x, v, line) {
      line = ""
      if (mode == "shell") line = a
      else {
        n = splitargs(a, arg, ",")
        for (i = 1; i <= n; i++) {
          x = trim(arg[i])
          if (x == "" || x ~ /^(\{|\*\*)/ || x ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*(=[^=]|:[^:])/ && x !~ /^args[ \t]*=/) continue
          sub(/^args[ \t]*=/, "", x)
          v = literal(x); if (v == NO) { line = NO; break }
          line = line (line == "" ? "" : " ") v
        }
        if (mode == "code" && line != NO) return line != "" ? shellouts(line, lang) : ""
      }
      if (line == NO) {
        if (OPQMODE != "ask") return a ~ KRE ? flat(a) : ""
        return (a ~ KRE || names && a !~ /["\047`]/) ? OPQ : ""
      }
      if (OPQMODE == "ask" && names && line ~ /^[ \t\n]*\$__shellout_value/) return OPQ
      return line ~ KRE ? line "\002" : ""
    }
    function dq(s,    i, c, n, out) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); n = substr(s, i + 1, 1)
        if (c == "\\" && (n == "\"" || n == "\\" || n == "$" || n == "`")) { out = out n; i++ } else out = out c
      }
      return out
    }
    { gsub("\001", ""); gsub("\002", ""); L[++nl] = $0 }
    # Prints the shell-outs, each ended by \002, then \001, then the command
    # with the text of each inline script taken out.
    END {
      all = ""; for (i = 1; i <= nl; i++) all = all L[i] "\n"
      rest = all; t = ""
      while (match(rest, /(^|[^A-Za-z0-9_.\/-])([^ \t;&|()]*\/)?(python[0-9.]*|node|nodejs|ruby|perl|php|bun)([ \t]+-[A-Za-z-]+)*[ \t]+-(c|e|E|r|p|-eval|-print)[ \t]*["\047]/)) {
        m = substr(rest, RSTART, RLENGTH); q = substr(m, RLENGTH, 1); st = RSTART + RLENGTH; j = st
        sub(/^[^A-Za-z0-9_.\/-]/, "", m); sub(/[ \t].*/, "", m); sub(/.*\//, "", m)
        while (j <= length(rest) && substr(rest, j, 1) != q) { if (q == "\"" && substr(rest, j, 1) == "\\") j++; j++ }
        raw = substr(rest, st, j - st); pl = q == "\"" ? dq(raw) : raw; views = views shellouts(pl, langof(m))
        uo = !outsafe(substr(rest, j + 1)); if (uo) views = views strviews(pl)
        keep = (q == "\"" && raw ~ /(^|[^\\])[$`]/) || uo
        t = t substr(rest, 1, st - 1) (keep ? raw : ""); rest = substr(rest, j)
      }
      t = t rest
      n = split(t, L, "\n"); out = ""
      for (i = 1; i < n; i++) {
        l = L[i]
        if (body) {
          tt = l; if (dash) sub(/^\t+/, "", tt)
          if (tt != term) { buf = buf l "\n"; continue }
          views = views shellouts(buf, hl) (keep ? strviews(buf) : "")
          out = out ((keep || !lit && buf ~ /[$`]/) ? buf : "") l "\n"; body = 0; buf = ""; continue
        }
        out = out l "\n"
        if (match(l, /<<-?[ \t]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
          tm = substr(l, RSTART, RLENGTH); tl = substr(l, RSTART + RLENGTH)
          k = split(substr(l, 1, RSTART - 1), seg, /\|\||&&|[|;&]/)
          w = seg[k]; sub(/^[ \t]+/, "", w); sub(/[ \t].*/, "", w); sub(/.*\//, "", w)
          if (w ~ /^(python[0-9.]*|node|nodejs|ruby|perl|php|bun|deno)$/) {
            dash = (tm ~ /^<<-/); lit = (tm ~ /^<<-?[ \t]*["\047\\]/); term = tm; hl = langof(w); keep = !outsafe(tl)
            sub(/^<<-?[ \t]*["\047\\]?/, "", term); body = 1; buf = "" } }
      }
      if (body) out = out buf
      printf "%s\001%s", views, out
    }'
}

# check_inline_shellouts TOOL OPQMODE runs this guard on each shell-out as a
# command of its own, with the payload it was given, and answers as that run
# does. Otherwise CMD becomes the command with the scripts' text taken out.
check_inline_shellouts() {
  local tool="$1" mode="$2" iv views v r d reason depth=${HARNESS_SHELLOUT_DEPTH:-0}
  case "$CMD" in *python*|*node*|*ruby*|*perl*|*php*|*bun*|*deno*) ;; *) return 0 ;; esac
  # An awk error prints nothing, which would read as an empty, allowed command.
  if ! iv=$(inline_script_view "$tool" "$mode" "$CMD") || [[ "$iv" != *$'\001'* ]]; then
    emit_ask "This guard could not read the command's inline script, so it asks rather than allow it unread."
    exit 0
  fi
  CMD=${iv#*$'\001'}; views=${iv%%$'\001'*}
  while [[ -n "$views" ]]; do
    v=${views%%$'\002'*}; views=${views#"$v"}; views=${views#$'\002'}
    [[ -z "$v" ]] && continue
    if [[ "$v" == __OPAQUE_SHELLOUT__ ]]; then
      emit_ask "An inline script names $tool and hands a shell-out a command built from a value this guard cannot read (os.system(cmd), subprocess.run(args)). Put the $tool command in the shell-out as a literal, or run $tool directly."
      exit 0
    fi
    if (( depth >= 4 )) || ! r=$(printf '%s' "$INPUT" | jq -c --arg c "$v" '.tool_input.command = $c' \
        | HARNESS_SHELLOUT_DEPTH=$((depth + 1)) CLAUDE_AUDIT_LOG=/dev/null bash "$0"); then
      emit_ask "This guard could not check what an inline script hands a shell-out: $v"
      exit 0
    fi
    d=$(printf '%s' "$r" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    reason=$(printf '%s' "$r" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
    case "$d" in
      deny) emit_deny "An inline script runs this through a shell-out: $v. $reason"; exit 0 ;;
      ask) emit_ask "An inline script runs this through a shell-out: $v. $reason"; exit 0 ;;
    esac
  done
}

# Emit a PreToolUse ask decision (prompt the user) with a reason.
emit_ask() {
  local reason="$1"
  log_decision ask
  if command -v jq &>/dev/null; then
    jq -nc --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
      "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# Secret-shaped values out of an audit line: URL credentials, well-known token
# prefixes, and the value after a key-like word. The line keeps its shape.
redact_secrets() {
  sed -E \
    -e 's#(://[^/@[:space:]:]+):[^/@[:space:]]+@#\1:***@#g' \
    -e 's/((ghp|gho|ghu|ghs|ghr)_|github_pat_|glpat-|xox[abprs]-|sk-(ant-)?|AKIA)[A-Za-z0-9_-]{8,}/\1***/g' \
    -e "s/([Aa]uthorization|[Bb]earer|[Tt]oken|TOKEN|[Ss]ecret|SECRET|[Pp]assword|PASSWORD|[Pp]asswd|[Aa]pi[_-]?[Kk]ey|API[_-]?KEY)([\"']?[=:[:space:]]+[\"']?)([Bb]earer[[:space:]]+)?[^[:space:]\"'&]+/\1\2\3***/g"
}

# Append to the audit log. Creates parent dir, rotates at 10MB, keeps 5 backups,
# and restricts perms to 0600. Never fails the hook on error.
log_audit() {
  local line="$1"
  local log
  log=$(expand_tilde "${CLAUDE_AUDIT_LOG:-$HOME/.claude/logs/audit.log}")
  local dir
  dir=$(dirname "$log")
  mkdir -p "$dir" 2>/dev/null || return 0

  # Rotate if >10MB
  if [[ -f "$log" ]]; then
    local size
    size=$(stat -c%s "$log" 2>/dev/null || stat -f%z "$log" 2>/dev/null || echo 0)
    if [[ "$size" -gt 10485760 ]]; then
      for i in 4 3 2 1; do
        [[ -f "${log}.${i}" ]] && mv -f "${log}.${i}" "${log}.$((i+1))" 2>/dev/null
      done
      mv -f "$log" "${log}.1" 2>/dev/null
    fi
  fi

  printf '%s\n' "$line" | redact_secrets >> "$log" 2>/dev/null || return 0
  chmod 600 "$log" 2>/dev/null || true
}

# SHA-256 of a file's contents. Empty output if file is missing or unreadable.
# Prefers shasum (macOS default), falls back to sha256sum (Linux default).
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

# Can this name go on the machine-local network allowlist? network-guard allows
# an entry AND every subdomain of it, so `com` would allow the internet and a
# tunnel or request-capture service would allow a host anyone can stand up to
# collect a query string. Prints why when refused; silent when fine. The lists
# are the common cases, not every one.
net_host_problem() {
  local h="$1" s
  local sinks=(webhook.site requestbin.com requestbin.net pipedream.net beeceptor.com mockbin.org
    mockbin.io hookbin.com requestcatcher.com interact.sh oast.fun oast.live oast.me oast.online
    oast.pro oast.site oastify.com burpcollaborator.net canarytokens.com ngrok.io ngrok.app
    ngrok.dev ngrok-free.app ngrok-free.dev loca.lt localtunnel.me trycloudflare.com serveo.net
    localhost.run pastebin.com transfer.sh paste.ee hastebin.com dpaste.org 0x0.st termbin.com
    ntfy.sh api.telegram.org script.google.com script.googleusercontent.com hooks.slack.com
    discord.com discordapp.com webhook.office.com zapier.com make.com ifttt.com)
  local shared=(github.io githubusercontent.com pages.dev workers.dev vercel.app netlify.app
    herokuapp.com appspot.com web.app firebaseapp.com run.app cloudfunctions.net
    azurewebsites.net blob.core.windows.net cloudfront.net amazonaws.com s3.amazonaws.com
    glitch.me repl.co replit.dev onrender.com fly.dev railway.app gitlab.io bitbucket.io
    surge.sh deno.dev val.run pythonanywhere.com ondigitalocean.app azurestaticapps.net
    r2.dev supabase.co firebaseio.com herokudns.com codeberg.page)
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { echo "not a lower-case host name with a dot (no scheme, port, path or wildcard)"; return 1; }
  [[ "$h" =~ ^[0-9.]+$ ]] && { echo "an IP address: subdomain matching would stretch it to others"; return 1; }
  [[ "$h" =~ ^(co|com|net|org|gov|edu|ac|ne|or|go)\.[a-z]{2}$ ]] && { echo "a public suffix"; return 1; }
  [[ "$h" =~ ^(uk|us|eu|gb|br|cn|de|jpn|ru|sa|se|za|kr|hu|no|ae|qc|uy|mex)\.(com|net|org)$ ]] && { echo "a public suffix"; return 1; }
  for s in "${sinks[@]}"; do
    [[ "$h" == "$s" || "$h" == *".$s" ]] && { echo "a tunnel or request-capture service ($s)"; return 1; }
  done
  for s in "${shared[@]}"; do
    [[ "$h" == "$s" ]] && { echo "shared hosting: name the full host instead"; return 1; }
  done
  return 0
}

# `netAllowlist` entries from ~/.claude/local-settings/*.json that pass
# net_host_problem. Read on every call, so an edit applies without a reinstall;
# a file that will not parse contributes nothing, and the guard asks as before.
# Regular files only: jq blocks on a FIFO, and a hook that times out is not a
# deny, the call goes on to the permission flow. Arrays only, as install.sh counts.
local_net_hosts() {   # keys to read: netAllowlist (default), netAllowBody
  local dir f h
  dir=$(expand_tilde "${CLAUDE_LOCAL_SETTINGS_DIR:-$HOME/.claude/local-settings}")
  compgen -G "$dir/*.json" >/dev/null || return 0
  [[ $# -gt 0 ]] || set -- netAllowlist
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    jq -r --args '. as $o | $ARGS.positional[] | $o[.] | arrays | .[] | strings' "$@" < "$f" 2>/dev/null
  done | while IFS= read -r h; do
    net_host_problem "$h" >/dev/null && printf '%s\n' "$h"
  done
}
