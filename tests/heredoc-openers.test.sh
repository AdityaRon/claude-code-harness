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
mkdir -p "$TMP/run" "$TMP/home/.claude"
M='echo HDMARK'

runs_in_bash() { (cd "$TMP/run" && bash -c "$1" 2>/dev/null) | grep -qx HDMARK; }
keeps() { printf '%s\n' "$1" | grep -qxF "$M"; }

# Each case: a label, then the command. The marker line is always a line of its own.
CASES=(
  "here-string"                 $'cat <<<x\n'"$M"$'\nx'
  "here-string, quoted word"    $'cat <<< "a b"\n'"$M"$'\nb'
  "<< in double quotes"         $'echo "<<x"\n'"$M"$'\nx'
  "<< in single quotes"         $'echo \'<<x\'\n'"$M"$'\nx'
  "<< in \$'...' after \\'"     $'echo $\'it\\\'s <<x\'\n'"$M"$'\nx'
  "<< after a comment"          $'true # <<x\n'"$M"$'\nx'
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
[ "$n" -ge 15 ] && pass "$n cases run the marker in bash" || fail "cases run the marker in bash" "only $n"

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
GUARDS=(git-guard config-guard kubectl-guard env-guard interpreter-guard network-guard)
RISK=("git push --force origin main" "cp /dev/null ~/.claude/settings.json" "kubectl delete ns prod"
      "cat .env" "python3 -c 'import os; print(os.environ)'" "curl -X DELETE https://example.com/x")
PREFIXES=('cat <<<x' 'echo "<<x"' 'true # <<x' 'echo $((1<<x))')
for g in "${!GUARDS[@]}"; do
  ctl=$(verdict "${GUARDS[$g]}" "${RISK[$g]}")
  [ "$ctl" != allow ] || { fail "${GUARDS[$g]} control" "allows '${RISK[$g]}' alone: pick another line"; continue; }
  for p in "${PREFIXES[@]}"; do
    v=$(verdict "${GUARDS[$g]}" "$(printf '%s\n%s\nx' "$p" "${RISK[$g]}")")
    [ "$v" = "$ctl" ] && pass "${GUARDS[$g]} after '$p': $v" || fail "${GUARDS[$g]} after '$p'" "$v, alone: $ctl"
  done
done

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
