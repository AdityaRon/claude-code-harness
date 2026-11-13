#!/usr/bin/env bash
# hooks/lib.sh sources this: inline scripts: the view of python -c, heredocs and the like a guard reads.

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
# Under hooks/bash-guards.sh $0 is the dispatcher, and GUARD_SELF this guard.
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
        | HARNESS_SHELLOUT_DEPTH=$((depth + 1)) CLAUDE_AUDIT_LOG=/dev/null bash "${GUARD_SELF:-$0}"); then
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
