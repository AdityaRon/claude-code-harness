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
runs_in_bash() {
  (cd "$TMP/run" && env -i HOME="$TMP/home" PATH="$TMP/stub:/usr/bin:/bin" /bin/bash -c "$1" 2>/dev/null) | grep -qx HDMARK
}
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
)

echo "=== bash runs the marker: every stripper keeps it ==="
n=0
for ((i = 0; i < ${#CASES[@]}; i += 2)); do
  label=${CASES[$i]}; cmd=${CASES[$((i + 1))]}
  if ! runs_in_bash "$cmd"; then fail "$label" "(bash did not run the marker: the case is wrong)"; continue; fi
  n=$((n + 1))
  for fn in strip_message_heredocs strip_inert_heredocs drop_data_heredocs; do
    out=$("$fn" "$cmd")
    keeps "$out" && pass "$label: $fn keeps it" || fail "$label: $fn dropped a line bash runs" "[$out]"
  done
done
[ "$n" -ge 25 ] && pass "$n cases run the marker in bash" || fail "cases run the marker in bash" "only $n"

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
done

GROUPED="(kubectl delete ns prod)"
GCTL=$(verdict kubectl-guard "$GROUPED")
for p in "${PREFIXES[@]}"; do
  v=$(verdict kubectl-guard "$(printf '%s\n%s\nx' "$p" "$GROUPED")")
  [ "$v" = "$GCTL" ] && pass "kubectl-guard, a group after '$p': $v" || fail "kubectl-guard, a group after '$p'" "$v, alone: $GCTL"
done


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
# A deny stands, alone: the floor adds no second decision after it.
out=$(jq -nc --arg c "printenv ; $UNREAD" --arg d "$TMP/run" '{tool_name:"Bash", hook_event_name:"PreToolUse", tool_input:{command:$c}, cwd:$d, session_id:"hd"}' \
      | HOME="$TMP/home" bash hooks/env-guard.sh 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
[ "$out" = deny ] && pass "env-guard denies once after an unreadable command" || fail "env-guard's decisions after an unreadable command" "[$out]"
[ "$(verdict env-guard 'echo "it'"'"'s" ; ls')" = allow ] && pass "a readable command still allows" \
  || fail "a readable command" "$(verdict env-guard 'echo "it'"'"'s" ; ls')"

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
