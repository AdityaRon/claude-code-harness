#!/usr/bin/env bash
# The heredoc opener lib.sh's strippers share (hd_scan), with bash as the oracle:
# whenever bash runs a case's marker line, every stripper must keep that line in
# what the guards scan. A << in quotes, a comment, (( )) or a <<< here-string
# once made all six heredoc-aware guards drop the commands after it.
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
  "(( that closes as ) ), two subshells" $'((cat <<EOF) )\nit\'s\nEOF\necho \'<<x \\\'\n'"$M"$'\nx'
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
# A command hd_scan cannot read is grouped as before hd_scan (separate_groups_typed),
# never worse than that: converting every ( split git-guard's spans.
G='(echo HDMARK)'
unreadable() {
  printf '%s\n' "$1" | awk "$HEREDOC_AWK"'
    body { if (hd_end($0)) body = 0; next }
    { hd_scan($0); if (HD_BAD) exit 3; if (HD_POS) body = 1 }'
  [ $? = 3 ]
}
u=0
for ((i = 0; i < ${#CASES[@]}; i += 2)); do
  label=${CASES[$i]}; cmd=${CASES[$((i + 1))]//"$M"/$G}
  runs_in_bash "$cmd" || continue
  out=$(separate_groups "$cmd")
  if unreadable "$cmd"; then
    u=$((u + 1))
    [ "$out" = "$(separate_groups_typed "$cmd")" ] && pass "$label: unreadable, grouped as before hd_scan" \
      || fail "$label: unreadable, but not grouped as before hd_scan" "[$out]"
    continue
  fi
  printf '%s\n' "$out" | grep -qF ';echo HDMARK;' && pass "$label: separate_groups opens it" \
    || fail "$label: separate_groups left a group bash runs" "[$out]"
done
[ "$u" -ge 5 ] && pass "$u unreadable cases" || fail "unreadable cases" "only $u: the check above may not run"

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
PREFIXES=('cat <<<x' 'echo "<<x"' 'true # <<x' 'echo $((1<<x))')
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

v=$(verdict git-guard 'git push origin "a(b)" --force "${x:-"y"}"')
[ "$v" = deny ] && pass "git-guard, a quoted ( before --force in an unreadable command: deny" \
  || fail "git-guard, a quoted ( before --force in an unreadable command" "$v"

GROUPED="(kubectl delete ns prod)"
GCTL=$(verdict kubectl-guard "$GROUPED")
for p in "${PREFIXES[@]}"; do
  v=$(verdict kubectl-guard "$(printf '%s\n%s\nx' "$p" "$GROUPED")")
  [ "$v" = "$GCTL" ] && pass "kubectl-guard, a group after '$p': $v" || fail "kubectl-guard, a group after '$p'" "$v, alone: $GCTL"
done

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
