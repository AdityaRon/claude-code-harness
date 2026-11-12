#!/usr/bin/env bash
# hooks/lib.sh sources this: normalizing a command, and the heredoc and message strippers the guards scan through.

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
  # shellcheck disable=SC2034  # a bare count of passes; another part's i made it look used
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
  printf '%s\n' "$1" | awk "$HEREDOC_AWK"'
    { line[NR] = $0 }
    END {
      # Which lines are heredoc data, left as typed. From a line holding a << that
      # hd_scan cannot read, quotes are not tracked either: a quote in a body read
      # as commands could hide a group, while converting every ( only adds segments.
      for (k = 1; k <= NR; k++) {
        if (body) { if (hd_end(line[k])) { body = 0; edge[k] = 1 } else data[k] = !shell; continue }
        hd_scan(line[k])
        if (HD_BAD) { raw = 1; break }
        if (HD_POS) { body = 1; shell = hd_shell(line[k]); edge[k] = 1 }
      }
      q = ""
      for (k = 1; k <= NR; k++) {
        if (data[k]) { print line[k]; continue }
        s = line[k]; out = ""; n = length(s); esc = 0
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1); p = (i > 1) ? substr(s, i - 1, 1) : ""; x = substr(s, i + 1, 1)
          if (c == "\\" && q != "\047") { esc = i + 1; out = out c x; i++; continue }
          if (q == "") {
            if (c == "\047" && !raw) q = (p == "$" && esc != i - 1) ? "A" : "\047"
            else if (c == "\"" && !raw) q = "\""
            else if ((c == "(" && p != "$") || c == ")") c = ";"
            else if ((c == "{" || c == "}") && (p == "" || p ~ /[ \t;&|]/) && (x == "" || x ~ /[ \t;&|]/)) c = ";"
          } else if (c == "\047" && (q == "\047" || q == "A")) q = ""
          else if (c == "\"" && q == "\"") q = ""
          out = out c
        }
        print out
        if (edge[k]) q = ""
      }
    }'
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

# Where a heredoc really starts, as bash reads the line. Not inside quotes (a
# quoted string may span lines), ${ }, a # comment, (( )), $(( )), $[ ],
# backticks or a <<< here-string. hd_scan sets HD_POS (0: none), HD_LEN, HD_TERM,
# HD_DASH, HD_LIT; HD_BAD when the line holds a << it cannot read for certain:
# a caller then keeps the command as typed. Call it only outside a body, and
# hd_end only inside one. A missed real opener is as unsafe as a false one.
HEREDOC_AWK='
function hd_arith(s, i,    d, n, c) {
  d = 0; n = length(s)
  for (; i <= n; i++) { c = substr(s, i, 1); if (c == "(") d++; else if (c == ")" && --d == 0) return i }
  return 0
}
function hd_word(s, i,    j, c, k, w) {
  j = i + 2; HD_DASH = 0; HD_LIT = 0
  if (substr(s, j, 1) == "-") { HD_DASH = 1; j++ }
  while (substr(s, j, 1) ~ /[ \t]/) j++
  c = substr(s, j, 1)
  if (c == "\047" || c == "\"") {
    k = index(substr(s, j + 1), c); if (!k) return 0
    w = substr(s, j + 1, k - 1); j += k + 1; HD_LIT = 1
    if (w == "" || (c == "\"" && w ~ /[\\$`]/)) return 0
  } else {
    if (c == "\\") { HD_LIT = 1; j++ }
    if (!match(substr(s, j), /^[A-Za-z0-9_.-]+/)) return 0
    w = substr(s, j, RLENGTH); j += RLENGTH
  }
  c = substr(s, j, 1)
  if (c != "" && c !~ /[ \t;&|()<>]/) return 0
  HD_POS = i; HD_LEN = j - i; HD_TERM = w
  return 1
}
function hd_scan(s,    i, n, c, j, w) {
  HD_POS = 0; HD_LEN = 0; HD_BAD = 0; n = length(s); hesc = -1
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (hq == "\047") { if (c == "\047") hq = ""; continue }
    if (hq == "A") { if (c == "\\") i++; else if (c == "\047") hq = ""; continue }
    if (c == "\\") { hesc = i + 1; i++; continue }
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      j = index(substr(s, i + 2), "}"); if (!j) { HD_BAD = 1; return }
      w = substr(s, i + 2, j - 1); if (w ~ /[\047"`{]|<<|\$\(/) { HD_BAD = 1; return }
      i += j + 1; continue
    }
    if (hq == "\"") {
      if (c == "\"") hq = ""
      else if (c == "`") hbt = !hbt
      else if (c == "$" && substr(s, i + 1, 2) == "((") { j = hd_arith(s, i + 1); if (!j) { HD_BAD = 1; return } i = j }
      else if (c == "$" && substr(s, i + 1, 1) == "(") { hup[++hsp] = "\""; hdep[hsp] = 1; hq = ""; i++ }
      continue
    }
    if (c == "\047") { hq = (i > 1 && substr(s, i - 1, 1) == "$" && hesc != i - 1) ? "A" : "\047"; continue }
    if (c == "\"") { hq = "\""; continue }
    if (c == "`") { hbt = !hbt; continue }
    if (c == "#" && hesc != i - 1 && (i == 1 ? !hcont : substr(s, i - 1, 1) ~ /[ \t;&|()]/)) break
    if (c == "(" && substr(s, i + 1, 1) == "(") { j = hd_arith(s, i); if (!j) { HD_BAD = 1; return } i = j; continue }
    if (c == "$" && substr(s, i + 1, 1) == "[") { j = index(substr(s, i), "]"); if (!j) { HD_BAD = 1; return } i += j - 1; continue }
    if (hsp > 0 && c == "(") hdep[hsp]++
    if (hsp > 0 && c == ")" && --hdep[hsp] == 0) { hq = hup[hsp--]; continue }
    if (c == "<" && substr(s, i + 1, 1) == "<") {
      if (substr(s, i + 2, 1) == "<") { i += 2; continue }
      if (hbt || HD_POS) { HD_BAD = 1; return }
      if (!hd_word(s, i)) { HD_BAD = 1; return }
      i += HD_LEN - 1
    }
  }
  hcont = (hesc == n + 1)
  if (HD_POS && (hq != "" || hcont)) HD_BAD = 1
}
function hd_end(s) { if (HD_DASH) sub(/^\t+/, "", s); return s == HD_TERM }
function hd_shell(s) { return s ~ /(^|[^A-Za-z0-9_.-])(ba|z|da|k|fi|s)?sh([^A-Za-z0-9_.-]|$)/ }
'

# A heredoc fed to `git commit -F -` or `gh pr|issue … --body-file -` is a
# commit message or PR body: nothing runs it, whatever else the line does. The
# body goes; the opener and terminator stay, so the command itself is scanned
# and a later pass still sees a balanced heredoc. An unquoted delimiter has the
# shell run $(...) and backticks in the body, so such a body holding $ or ` stays.
# `-m "$(cat <<'EOF'` is the same message when the line ends at the delimiter:
# anything after it (`| bash`) would run the body.
strip_message_heredocs() {
  local out
  case "$1" in *'<<'*) ;; *) printf '%s' "$1"; return ;; esac
  out=$(printf '%s\n' "$1" | awk "$HEREDOC_AWK"'
    body { if (hd_end($0)) { if (buf ~ /[$`]/) printf "%s", buf; body = 0; buf = ""; print; next }
           if (keep) print; else if (!lit) buf = buf $0 "\n"
           next }
    { print; hd_scan($0)
      if (HD_BAD) { bad = 1; exit }
      if (HD_POS) {
        pre = substr($0, 1, HD_POS - 1); n = split(pre, seg, /\|\||&&|[|;&]/); last = seg[n]
        post = substr($0, HD_POS + HD_LEN)
        keep = !(last ~ /^[ \t]*(git[ \t]+(-[^ \t]+[ \t]+)*commit|gh[ \t]+(pr|issue))[ \t]/ \
            && (last ~ /(^|[ \t])(-F|--file|--body-file)[ \t]*=?[ \t]*-([ \t]|$)/ \
                || (last ~ /(^|[ \t])(-[A-Za-z]*m|--message|-[tb]|--title|--body)[ \t]*=?[ \t]*"\$\([ \t]*cat[ \t]*$/ \
                    && post ~ /^[ \t]*$/)))
        lit = HD_LIT; buf = ""; body = 1 } }
    END { if (bad) exit 3; if (body && !keep && buf ~ /[$`]/) printf "%s", buf }') || { printf '%s' "$1"; return; }
  printf '%s' "$out"
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
  rest=$(printf '%s\n' "$s" | awk "$HEREDOC_AWK"'
    body { if (hd_end($0)) { if (buf ~ /[$`]/) printf "%s", buf; body = 0; buf = "" }
           else if (!lit) buf = buf $0 "\n"
           next }
    { hd_scan($0); if (HD_BAD) { bad = 1; exit }
      if (HD_POS) { lit = HD_LIT; buf = ""; body = 1 } }
    { print }
    END { if (bad) exit 3; if (body && buf ~ /[$`]/) printf "%s", buf }') || { printf '%s' "$s"; return; }
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

# A heredoc body is the data a command reads, unless its line names a shell
# anywhere (`| bash`, `sudo bash`, `/bin/sh`): config-guard. Unterminated, or
# an opener hd_scan cannot read, it is all kept.
drop_data_heredocs() {
  local out
  case "$1" in *'<<'*) ;; *) printf '%s' "$1"; return ;; esac
  out=$(printf '%s\n' "$1" | awk "$HEREDOC_AWK"'
    body { if (hd_end($0)) { body = 0; print; next }
           if (shell) print
           next }
    { print; hd_scan($0)
      if (HD_BAD) { bad = 1; exit }
      if (HD_POS) { shell = hd_shell($0); body = 1 } }
    END { if (bad || body) exit 3 }') || { printf '%s' "$1"; return; }
  printf '%s' "$out"
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
    { out = ""; n = length($0); esc = 0
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\" && q != "\047") { esc = i + 1; out = out c hide(substr($0, i + 1, 1)); i++; continue }
        if (q == "\"" && c == "$" && substr($0, i + 1, 1) == "(") { up[++sp] = q; depth[sp] = 1; q = ""; out = out "$("; i++; continue }
        if (q == "" && sp > 0 && c == "(") depth[sp]++
        if (q == "" && sp > 0 && c == ")" && --depth[sp] == 0) { q = up[sp--]; out = out c; continue }
        if (q == "") {
          if (c == "\047") q = (i > 1 && substr($0, i - 1, 1) == "$" && esc != i - 1) ? "A" : "\047"
          else if (c == "\"") q = "\""
        } else if (c == "\047" && (q == "\047" || q == "A")) q = ""
        else if (c == "\"" && q == "\"") q = ""
        else c = hide(c)
        out = out c
      }
      print out }'
}
