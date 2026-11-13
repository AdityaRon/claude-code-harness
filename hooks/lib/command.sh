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
  # shellcheck disable=SC2034  # a counter only: four passes
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
# Run it on text whose quotes are intact; hd_scan says which brackets are code
# (sh_classify). A heredoc body is another program's input (python parens, a
# comment's apostrophe), so it is left alone, except what a shell reads: the
# whole body under `| bash`, and $( ) or backticks in an unquoted one.
separate_groups() {
  case "$1" in *'('*|*')'*|*'{'*|*'}'*) ;; *) printf '%s' "$1"; return ;; esac
  printf '%s\n' "$1" | awk "$HEREDOC_AWK"'
    { line[NR] = $0 }
    END {
      # From a line hd_scan cannot read, quotes are not tracked at all: a quote
      # misread could hide a group. Converting every ( can split a span instead,
      # so each guard asks there (unreadable_check).
      sh_classify(NR)
      for (k = 1; k <= NR; k++) {
        s = line[k]; out = ""; n = length(s)
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1); p = (i > 1) ? substr(s, i - 1, 1) : ""; x = substr(s, i + 1, 1)
          if (SH_BAD) { if (c == "\\") { out = out c x; i++; continue } t = "c" }
          else t = ((k, i) in CLS) ? CLS[k, i] : (DATA[k] ? "d" : "c")
          if (t == "c") {
            if ((c == "(" && p != "$") || c == ")") c = ";"
            else if ((c == "{" || c == "}") && (p == "" || p ~ /[ \t;&|]/) && (x == "" || x ~ /[ \t;&|]/)) c = ";"
          }
          out = out c
        }
        print out
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
# Where the (( at i closes, or 0. bash reads `((cmd) )` as two subshells, so
# a (( that does not close as one `))` is not arithmetic and is not skipped.
function hd_arith(s, i,    d, n, c, p) {
  d = 0; n = length(s)
  for (; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "(") d++
    else if (c == ")") { if (--d == 1) p = i; else if (d == 0) return (p == i - 1) ? i : 0 }
  }
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
  HD_POS = i; HD_LEN = j - i; HD_TERM = w; HB_Q = ""; HB_DEP = 0
  return 1
}
# With HD_CLS set, hd_scan also records in HCLS the class of each ( ) { } ; & |
# on the line: c code, q quoted or escaped, d heredoc data. One it skips (in
# arithmetic or a comment) has none and reads as code, or as data in a body.
# hq "H" is an unquoted heredoc body: its quotes are text, but $( ) and
# backticks run.
function hd_cls(i, cls,    ch) { ch = substr(HDS, i, 1); if (ch != "" && index("();&|{}", ch)) HCLS[i] = cls }
function hd_span(a, b, cls,    k) { if (HD_CLS) for (k = a; k <= b; k++) hd_cls(k, cls) }
function hd_ctx(q) { return q == "" ? "c" : q == "H" ? "d" : "q" }
# How many unescaped $ come just before i, e being the escaped position. After
# an odd run a quote opens ANSI-C quoting; $$ is the pid, and its quote is plain.
function hd_dollars(s, i, e,    j) { for (j = i - 1; j > 0 && substr(s, j, 1) == "$" && e != j; j--); return i - 1 - j }
# Inside backticks bash ends the substitution at the next backtick, even one a
# quote would hide, so a quote there that holds one is unreadable.
function hd_btq(s, i, c,    j, d, n) {
  n = length(s)
  for (j = i + 1; j <= n; j++) { d = substr(s, j, 1); if (d == "\\" && c == "\"") j++; else if (d == c) return 0; else if (d == "`") return 1 }
  return 0
}
# Open substitutions: hsp frames, hbt, and hpd (parens of an unquoted $(, <( or >(
# and inside it). One left open past the << of an opener line makes the next line code.
# hd_after: inside one opened after the <<, where its end is not sure to be read.
# HD_INSUB, an opener inside a substitution: one is open at its << (hd_in), or
# HD_DOUBT, set for the rest of the command once where one ends is not sure.
function hd_after() { return HD_POS && (hpd > HD_PD0 || hsp > HD_SP0 || hbt) }
function hd_in() { return hpd || hsp || hbt }
function hd_scan(s,    i, n, c, j, w) {
  HD_POS = 0; HD_LEN = 0; HD_BAD = 0; n = length(s); hesc = -1
  if (HB_TAIL != "" && index(s, HB_TAIL)) { HD_BAD = 1; return }
  if (HD_CLS) { split("", HCLS); HDS = s }
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (HD_CLS) hd_cls(i, hd_ctx(hq))
    if (hq == "\047") { if (c == "\047") hq = ""; continue }
    if (hq == "A") { if (c == "\\") { i++; hd_span(i, i, "q") } else if (c == "\047") hq = ""; continue }
    if (c == "\\") { if (hd_after()) { HD_BAD = 1; return } if (hd_in()) HD_DOUBT = 1; hesc = i + 1; i++; hd_span(i, i, hq == "H" ? "d" : "q"); continue }
    # A ${ } is one word: a ; ( or | inside it separates nothing, except in a
    # <( ) or >( ) there, which bash runs. Inside a $( ), bash 3.2 counts a paren
    # in it and zsh does not, so the substitution may end there or not.
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      j = index(substr(s, i + 2), "}"); if (!j) { HD_BAD = 1; return }
      w = substr(s, i + 2, j - 1)
      if (hq == "H" ? (w ~ /`|\$\(/) : (w ~ /[\047"`{]|<<|\$\(/)) { HD_BAD = 1; return }
      if (w ~ /[()]/ && (hd_after() || (hsp > 0 && !hbtf[hsp]))) { HD_BAD = 1; return }
      if (w ~ /[(){}\047"`$\\<>]/) HD_DOUBT = 1
      hd_span(i, i + j + 1, hq == "H" ? "d" : (hq == "" && w ~ /[<>]\(/) ? "c" : "q"); i += j + 1; continue
    }
    # In double quotes or a heredoc body, $( ) and backticks start code again.
    if (hq == "\"" || hq == "H") {
      if (c == "\"" && hq == "\"") hq = ""
      else if (c == "`") { if (hd_after()) { HD_BAD = 1; return } HD_DOUBT = 1; hup[++hsp] = hq; hdep[hsp] = 0; hbtf[hsp] = 1; hq = "" }
      else if (c == "$" && substr(s, i + 1, 2) == "((") { if (hd_after()) { HD_BAD = 1; return } HD_DOUBT = 1; j = hd_arith(s, i + 1); if (!j) { HD_BAD = 1; return } i = j }
      else if (c == "$" && substr(s, i + 1, 1) == "(") { hup[++hsp] = hq; hdep[hsp] = 1; hbtf[hsp] = 0; hq = ""; i++ }
      continue
    }
    if (hsp > 0 && hbtf[hsp] && c == "`") { hq = hup[hsp--]; continue }
    if ((hbt || (hsp > 0 && hbtf[hsp])) && (c == "\"" || c == "\047") && hd_btq(s, i, c)) { HD_BAD = 1; return }
    if (c == "\047") { hq = hd_dollars(s, i, hesc) % 2 ? "A" : "\047"; if (hq == "A" && hd_after()) { HD_BAD = 1; return } if (hq == "A" && hd_in()) HD_DOUBT = 1; continue }
    if (c == "\"") { hq = "\""; continue }
    if (c == "`") { if (!hbt && hd_after()) { HD_BAD = 1; return } if (!hbt && (hpd || hsp)) HD_DOUBT = 1; hbt = !hbt; continue }
    if (c == "#" && hesc != i - 1 && (i == 1 ? !hcont : substr(s, i - 1, 1) ~ /[ \t;&|()]/)) {
      # In a $( ) frame, bash 3.2 reads a comment as text where zsh skips it, so one
      # holding a paren, quote, backtick or backslash is unreadable, as in hd_body.
      if (hd_after() || (!hbt && hsp > 0 && !hbtf[hsp] && substr(s, i + 1) ~ /[()\047"`\\]/)) { HD_BAD = 1; return }
      if (hd_in()) HD_DOUBT = 1
      # Inside backticks a comment ends at the backtick that ends the substitution.
      if (!hbt && !(hsp > 0 && hbtf[hsp])) break
      j = index(substr(s, i + 1), "`"); if (!j) { HD_BAD = 1; return }
      i += j - 1; continue
    }
    if (c == "(" && substr(s, i + 1, 1) == "(") { if (hd_after()) { HD_BAD = 1; return } if (hd_in() || substr(s, i - 1, 1) == "$") HD_DOUBT = 1; j = hd_arith(s, i); if (!j) { HD_BAD = 1; return } i = j; continue }
    if (c == "$" && substr(s, i + 1, 1) == "[") { if (hd_in()) HD_DOUBT = 1; j = index(substr(s, i), "]"); if (!j) { HD_BAD = 1; return } i += j - 1; continue }
    # x=$(cat <<EOF) ends the substitution on the opener line, in zsh too.
    if (HD_POS && HD_INSUB && c == ")") { HD_BAD = 1; return }
    if ((c == "(" || c == ")") && HD_POS && (hbt || (hsp > HD_SP0 && hbtf[hsp]))) { HD_BAD = 1; return }
    if ((c == "(" || c == ")") && (hbt || (hsp > 0 && hbtf[hsp]))) HD_DOUBT = 1
    if (hsp > 0 && !hbtf[hsp] && c == "(") hdep[hsp]++
    if (hsp > 0 && !hbtf[hsp] && c == ")" && --hdep[hsp] == 0) { hd_span(i, i, hd_ctx(hup[hsp])); hq = hup[hsp--]; continue }
    # A case pattern ) would close the $( ) early (bash 3.2 rejects it, zsh runs on).
    if (c == "c" && substr(s, i, 5) ~ /^case[ \t]/ && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|(]/)) {
      if (hsp > 0 && !hbtf[hsp] || hd_after()) { HD_BAD = 1; return }
      if (hd_in()) HD_DOUBT = 1
    }
    if (!hsp && !hbt) {
      if (c == "(" && (hpd || (substr(s, i - 1, 1) ~ /[$<>]/ && hesc != i - 1))) hpd++
      else if (c == ")" && hpd) hpd--
    }
    if (c == "<" && substr(s, i + 1, 1) == "<") {
      if (substr(s, i + 2, 1) == "<") { i += 2; continue }
      if (hbt || HD_POS || (hsp > 0 && hbtf[hsp])) { HD_BAD = 1; return }
      if (!hd_word(s, i)) { HD_BAD = 1; return }
      HD_PD0 = hpd; HD_SP0 = hsp
      HD_INSUB = hd_in() || HD_DOUBT; if (HD_INSUB) HD_DOUBT = 1
      # In a substitution its scanner reads the delimiter and the rest of this line
      # too: a paren, quote or backslash in either is read as the body lines are.
      if (HD_INSUB && (HD_TERM ~ /[()\047"`\\]/ || hd_body(substr(s, i + HD_LEN)))) { HD_BAD = 1; return }
      hd_span(i, i + HD_LEN - 1, "q"); i += HD_LEN - 1
    }
  }
  hcont = (hesc == n + 1)
  # $\ then ( on the next line is $( once bash joins them.
  if (hcont && s ~ /[$<>]\\$/) HD_DOUBT = 1
  if (HD_POS && (hq != "" || hcont || hpd > HD_PD0 || hsp > HD_SP0 || hbt)) HD_BAD = 1
}
# The classes of a whole command held in line[1..nl]: CLS[k, i] for line k, and
# DATA[k] for a line of a heredoc body no shell reads. SH_BAD: a line hd_scan
# cannot read. The quote state around a body is kept for the line after it
# (`-m "$(cat <<EOF` ... `)"`); a body fed to a shell starts fresh. An opener with
# no terminator line (a caller dropped the body) leaves the lines after it code.
# BODY[k] numbers the lines of each body no shell reads, data or not scanned.
function sh_save(   k) { sq = hq; ssp = hsp; sbt = hbt; scont = hcont; spd = hpd; sdoubt = HD_DOUBT; for (k = 1; k <= hsp; k++) { sup[k] = hup[k]; sdep[k] = hdep[k]; sbtf[k] = hbtf[k] } }
function sh_restore(   k) { hq = sq; hsp = ssp; hbt = sbt; hcont = scont; hpd = spd; HD_DOUBT = sdoubt; for (k = 1; k <= ssp; k++) { hup[k] = sup[k]; hdep[k] = sdep[k]; hbtf[k] = sbtf[k] } }
function sh_classify(nl,    k, t, i, body, lit, shell, found, insub, nb) {
  SH_BAD = 0; split("", CLS); split("", DATA); split("", BODY); HD_CLS = 1; HB_TAIL = ""
  hq = ""; hsp = 0; hbt = 0; hcont = 0; hpd = 0; HD_DOUBT = 0
  for (k = 1; k <= nl; k++) {
    if (body) {
      if (hd_bad_end(line[k])) { SH_BAD = 1; return }
      if (hd_end(line[k])) { body = 0; sh_restore(); continue }
      if (!shell) BODY[k] = nb
      # After a $( or backtick, bash 3.2 can end the substitution at a ) in the
      # body and run the rest, so such a body is code, and is not scanned.
      if (insub && !shell) continue
      if (!shell) DATA[k] = 1
      if (lit && !shell) continue
      hd_scan(line[k]); for (i in HCLS) CLS[k, i] = HCLS[i]
      if (HD_BAD || HD_POS) { SH_BAD = 1; return }
      continue
    }
    hd_scan(line[k]); for (i in HCLS) CLS[k, i] = HCLS[i]
    if (HD_BAD) { SH_BAD = 1; return }
    if (!HD_POS) continue
    found = 0; for (t = k + 1; t <= nl; t++) if (hd_end(line[t])) { found = 1; break }
    if (!found) continue
    body = 1; nb++; lit = HD_LIT; shell = hd_shell(line[k]); insub = HD_INSUB; sh_save()
    hq = (shell || lit) ? "" : "H"; hsp = 0; hbt = 0; hcont = 0; hpd = 0
  }
}
function hd_end(s) { if (HD_DASH) sub(/^\t+/, "", s); return s == HD_TERM }
# bash 3.2, not zsh, reads a body inside $( ), <( ) or backticks with the substitution
# scanner: EOF), a ) past the parens it opened, or a quote open at the terminator
# change what runs, so each is unreadable (1). Call it before hd_end, terminator too.
function hd_bad_end(s,    t) {
  if (HB_TAIL != "" && index(s, HB_TAIL)) return 1
  if (!HD_INSUB) return 0
  t = s; if (HD_DASH) sub(/^\t+/, "", t)
  if (t == HD_TERM) {
    if (HB_Q != "") { HB_TAIL = HB_Q == "B" ? "`" : HB_Q; return 0 }
    return HB_DEP != 0
  }
  return t == HD_TERM ")" || hd_body(s)
}
# One body line through that scanner: HB_Q its open quote (B a backtick in
# double quotes), HB_DEP its open parens. A comment holding a paren, quote,
# backtick or backslash is unreadable: bash honours it in some frames only.
function hd_body(s,    i, n, c) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (HB_Q == "\047") { if (c == "\047") HB_Q = ""; continue }
    if (HB_Q == "`" || HB_Q == "B") { if (c == "\\") i++; else if (c == "`") HB_Q = HB_Q == "B" ? "\"" : ""; continue }
    if (HB_Q == "\"") {
      if (c == "\\") i++
      else if (c == "\"") HB_Q = ""
      else if (c == "`") HB_Q = "B"
      else if (c == "$" && substr(s, i + 1, 1) ~ /[({[]/) return 1
      continue
    }
    if (c == "\\") { i++; continue }
    if (c == "\047") { if (i > 1 && substr(s, i - 1, 1) == "$") return 1; HB_Q = "\047"; continue }
    if (c == "\"" || c == "`") { HB_Q = c; continue }
    if (c == "(") { HB_DEP++; continue }
    if (c == ")") { if (--HB_DEP < 0) return 1; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) return substr(s, i + 1) ~ /[()\047"`\\]/
  }
  return 0
}
# A body some shell reads: a shell named on the line, $SHELL, or eval, source
# or . in command position.
function hd_shell(s) { return s ~ /(^|[^A-Za-z0-9_.-])(ba|z|da|k|fi|s)?sh([^A-Za-z0-9_.-]|$)|\$\{?SHELL([^A-Za-z0-9_]|$)|(^|[;&|(])[ \t]*(eval|source|\.)[ \t]/ }
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
    body && hd_bad_end($0) { bad = 1; exit }
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
    body && hd_bad_end($0) { bad = 1; exit }
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
    body && hd_bad_end($0) { bad = 1; exit }
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
# The classes are hd_scan's (sh_classify), so a quote in a comment, in heredoc
# data or in ${ } inside quotes no longer runs on over the lines after it. On a
# command hd_scan cannot read it prints the old reading and returns 3: a guard
# asks, since neither hiding nor keeping a separator is safe there.
# A body no shell reads may be a script run later, where a quote spans lines:
# the reading carried from the body's first line is printed after the command
# where it differs, so the lines a guard replays in order (cd) stay in order.
neutralize_quoted_separators() {
  case "$1" in *'&'*|*';'*|*'|'*) ;; *) printf '%s' "$1"; return ;; esac
  printf '%s\n' "$1" | awk "$HEREDOC_AWK"'
    function hide(ch) { return ch == "&" ? "%26" : ch == ";" ? "%3B" : ch == "|" ? "%7C" : ch }
    # The reading before hd_scan: quotes and $( only. Kept for heredoc data and
    # for a command hd_scan cannot read; a separator hd_scan marked as code (in
    # a $( ) of an unquoted body) is never hidden.
    function naive(s,    out, n, i, c, esc) {
      out = ""; n = length(s); esc = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && oq != "\047") { esc = i + 1; out = out c hide(substr(s, i + 1, 1)); i++; continue }
        if (oq == "\"" && c == "$" && substr(s, i + 1, 1) == "(") { oup[++osp] = oq; odep[osp] = 1; oq = ""; out = out "$("; i++; continue }
        if (oq == "" && osp > 0 && c == "(") odep[osp]++
        if (oq == "" && osp > 0 && c == ")" && --odep[osp] == 0) { oq = oup[osp--]; out = out c; continue }
        if (oq == "") {
          if (c == "\047") oq = hd_dollars(s, i, esc) % 2 ? "A" : "\047"
          else if (c == "\"") oq = "\""
        } else if (c == "\047" && (oq == "\047" || oq == "A")) oq = ""
        else if (c == "\"" && oq == "\"") oq = ""
        else if (CLS[k, i] != "c") c = hide(c)
        out = out c
      }
      return out
    }
    { line[NR] = $0 }
    END {
      sh_classify(NR)
      if (!SH_BAD) for (k = 1; k <= NR; k++) if (k in BODY) {
        if (!((k - 1) in BODY) || BODY[k - 1] != BODY[k]) { oq = ""; osp = 0 }
        alt[k] = naive(line[k])
      }
      oq = ""; osp = 0; extra = ""
      for (k = 1; k <= NR; k++) {
        if (SH_BAD) { print naive(line[k]); continue }
        if (DATA[k]) { oq = ""; osp = 0; out = naive(line[k]) }
        else {
          s = line[k]; out = ""; n = length(s)
          for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (index(";&|", c) && CLS[k, i] == "q") c = hide(c)
            out = out c
          }
        }
        print out
        if ((k in BODY) && alt[k] != out) extra = extra alt[k] "\n"
      }
      printf "%s", extra
      if (SH_BAD) exit 3
    }'
}
