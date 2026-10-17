#!/usr/bin/env bash
# Tests for bin/harness-update.sh against a bare repo standing in for origin:
# it moves a clean clone to the newest release tag, installs only when doctor
# is green, refuses local changes and local commits, and schedules through
# stand-in launchctl and crontab binaries.
set -u
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/state" "$HOME/.claude/logs" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
G="git -c user.email=t@example.com -c user.name=t"
# The installed copy, as launchd runs it: it finds the clone through
# harness.version. Run from a clone's bin/ it would use that clone instead.
UPD="$HOME/.claude/harness-update.sh"
cp "$PWD/bin/harness-update.sh" "$UPD"; chmod +x "$UPD"

echo "=== --newer compares release tags numerically ==="
bash "$UPD" --newer v1.0.10 v1.0.9  && pass "v1.0.10 > v1.0.9" || fail "v1.0.10 > v1.0.9" ""
if bash "$UPD" --newer v1.0.9 v1.0.10; then fail "v1.0.9 < v1.0.10" ""; else pass "v1.0.9 < v1.0.10"; fi
bash "$UPD" --newer v2.0.0 v1.9.9   && pass "v2.0.0 > v1.9.9" || fail "v2.0.0 > v1.9.9" ""
if bash "$UPD" --newer v1.0.0 v1.0.0; then fail "equal" ""; else pass "equal is not newer"; fi
bash "$UPD" --newer v1.0.0 abc; [ $? = 2 ] && pass "a non-release tag exits 2" || fail "non-release" ""

# A stand-in harness: install.sh records the version like the real one and
# leaves a marker; doctor.sh exits with the number in DOCTOR_RC.
SRC="$TMP/src"; mkdir -p "$SRC"
# It also replaces the installed updater by rename, as the real one does, while
# that updater is the script running it.
cat > "$SRC/install.sh" <<'SH'
#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER=$(git -C "$REPO" describe --tags --match 'v[0-9]*' --always --dirty)
printf 'version=%s\nrepo=%s\n' "$VER" "$REPO" > "$HOME/.claude/harness.version"
touch "$HOME/.claude/installed-$VER"
{ echo "#!/usr/bin/env bash"; echo "# installed at $VER"; cat "$HOME/.claude/harness-update.sh"; } > "$HOME/.claude/harness-update.sh.new"
chmod +x "$HOME/.claude/harness-update.sh.new"; mv -f "$HOME/.claude/harness-update.sh.new" "$HOME/.claude/harness-update.sh"
SH
printf '#!/usr/bin/env bash\necho "SUMMARY: stub"; exit "$(cat "$(dirname "$0")/DOCTOR_RC")"\n' > "$SRC/doctor.sh"
echo 0 > "$SRC/DOCTOR_RC"; echo one > "$SRC/README"
( cd "$SRC" && git init -q && $G add -A && $G commit -qm v1.0.0 && git tag v1.0.0 \
  && echo two > README && $G commit -qam v1.0.1 && git tag v1.0.1 && git tag nightly ) || { echo "fixture failed"; exit 1; }
git clone -q --bare "$SRC" "$TMP/origin.git"
git -C "$SRC" remote add origin "$TMP/origin.git"
CLONE="$TMP/clone"
git clone -q "$TMP/origin.git" "$CLONE" && ( cd "$CLONE" && git checkout -q --detach v1.0.0 )
printf 'version=v1.0.0\nrepo=%s\n' "$CLONE" > "$HOME/.claude/harness.version"
head_is() { [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse "$1^{commit}")" ]; }
installed() { sed -n 's/^version=//p' "$HOME/.claude/harness.version"; }
push_tag() {   # push_tag TAG DOCTOR_RC
  ( cd "$SRC" && echo "$2" > DOCTOR_RC && echo "$1" >> README && $G commit -qam "$1" && git tag "$1" && git push -q origin HEAD "$1" )
}

echo ""
echo "=== --check reports and installs nothing ==="
OUT=$(bash "$UPD" --check 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"v1.0.1 is available"* ]] && pass "names the newer tag" || fail "--check" "rc=$RC $OUT"
head_is v1.0.0 && [ ! -e "$HOME/.claude/installed-v1.0.1" ] && pass "clone and install untouched" || fail "--check touched" ""
[ "$(cut -d' ' -f1 "$HOME/.claude/state/harness-latest")" = v1.0.1 ] && pass "harness-latest written for session-start" \
  || fail "harness-latest" "$(cat "$HOME/.claude/state/harness-latest" 2>/dev/null)"

echo ""
echo "=== a clean clone moves to the newest tag and installs on green ==="
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $OUT"
head_is v1.0.1 && pass "clone at v1.0.1" || fail "clone at v1.0.1" "$(git -C "$CLONE" describe --tags)"
[ "$(installed)" = v1.0.1 ] && [ -e "$HOME/.claude/installed-v1.0.1" ] && pass "install.sh ran and recorded v1.0.1" || fail "install" "$(installed)"
[[ "$OUT" == *"installed v1.0.1 (was v1.0.0)"* ]] && pass "says what changed" || fail "message" "$OUT"
[ "$(sed -n 2p "$UPD")" = "# installed at v1.0.1" ] && pass "the updater replaced itself mid-run and finished" || fail "self-replace" "$(sed -n 2p "$UPD")"
[ -z "$(git -C "$CLONE" symbolic-ref -q HEAD)" ] && pass "detached, no branch moved" || fail "detached" "$(git -C "$CLONE" symbolic-ref HEAD)"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"up to date: v1.0.1"* ]] && pass "a second run is a no-op" || fail "no-op" "rc=$RC $OUT"
[ "$(ls "$HOME/.claude" | grep -c '^installed-')" = 1 ] && pass "install.sh not run again" || fail "reinstalled" ""

echo ""
echo "=== red doctor: nothing installed, clone back where it was ==="
push_tag v1.0.2 1
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"doctor.sh failed on v1.0.2"* ]] && pass "exit 1 and says why" || fail "red doctor" "rc=$RC $OUT"
head_is v1.0.1 && pass "back at v1.0.1" || fail "back at v1.0.1" "$(git -C "$CLONE" describe --tags)"
[ "$(installed)" = v1.0.1 ] && [ ! -e "$HOME/.claude/installed-v1.0.2" ] && pass "v1.0.1 still installed" || fail "installed" "$(installed)"
[ "$(cut -d' ' -f1 "$HOME/.claude/state/harness-latest")" = v1.0.2 ] && pass "harness-latest still names v1.0.2" || fail "latest" ""
push_tag v1.0.3 0
bash "$UPD" >/dev/null 2>&1; head_is v1.0.3 && [ "$(installed)" = v1.0.3 ] && pass "the next green tag installs" || fail "v1.0.3" "$(installed)"

echo ""
echo "=== refusals: uncommitted changes, local commits ==="
push_tag v1.0.4 0
echo dirty >> "$CLONE/README"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"uncommitted changes"* ]] && head_is v1.0.3 && pass "dirty clone refused, untouched" || fail "dirty" "rc=$RC $OUT"
[ "$(installed)" = v1.0.3 ] && pass "nothing installed" || fail "installed" "$(installed)"
( cd "$CLONE" && git checkout -q -- README && git checkout -q -b local && echo mine > mine && $G add mine && $G commit -qm mine )
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"commits v1.0.4 does not"* ]] && pass "local commits refused" || fail "local commits" "rc=$RC $OUT"
[ "$(git -C "$CLONE" symbolic-ref --short HEAD)" = local ] && pass "branch left alone" || fail "branch" ""
( cd "$CLONE" && git checkout -q --detach v1.0.3 )
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && head_is v1.0.4 && pass "clean again: v1.0.4 installs" || fail "v1.0.4" "rc=$RC $OUT"
rm "$HOME/.claude/harness.version"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"no harness clone found"* ]] && pass "no record, no --repo: says so" || fail "no record" "rc=$RC $OUT"
OUT=$(bash "$UPD" --repo "$CLONE" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.4 ] && pass "--repo with no record installs the tag it sits on" || fail "--repo" "rc=$RC $OUT"

echo ""
echo "=== --schedule: launchd ==="
printf '#!/usr/bin/env bash\necho "$*" >> "%s/launchctl.log"\n' "$TMP" > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"
PLIST="$HOME/Library/LaunchAgents/com.claude-code-harness.update.plist"
OUT=$(HARNESS_SCHEDULER=launchd bash "$UPD" --schedule 2>&1); RC=$?
[ "$RC" = 0 ] && [ -f "$PLIST" ] && pass "agent file written" || fail "plist" "rc=$RC $OUT"
grep -qF "<string>$HOME/.claude/harness-update.sh</string>" "$PLIST" && pass "runs the installed copy" || fail "program" "$(cat "$PLIST")"
if command -v plutil >/dev/null; then plutil -lint -s "$PLIST" >/dev/null && pass "plist lints" || fail "plist lints" "$(plutil -lint "$PLIST")"; fi
grep -q "^bootstrap gui/" "$TMP/launchctl.log" && pass "launchctl bootstrap called" || fail "bootstrap" "$(cat "$TMP/launchctl.log")"
HARNESS_SCHEDULER=launchd bash "$UPD" --unschedule >/dev/null 2>&1
[ ! -f "$PLIST" ] && grep -q "^bootout gui/" "$TMP/launchctl.log" && pass "--unschedule removes the agent" || fail "unschedule" ""

echo ""
echo "=== --schedule: cron, idempotent, other lines kept ==="
cat > "$TMP/bin/crontab" <<SH
#!/usr/bin/env bash
case "\$1" in -l) cat "$TMP/crontab.txt" 2>/dev/null ;; -) cat > "$TMP/crontab.new" && mv "$TMP/crontab.new" "$TMP/crontab.txt" ;; esac
SH
chmod +x "$TMP/bin/crontab"
echo "0 0 * * * /bin/true" > "$TMP/crontab.txt"
HARNESS_SCHEDULER=cron bash "$UPD" --schedule >/dev/null 2>&1
HARNESS_SCHEDULER=cron bash "$UPD" --schedule >/dev/null 2>&1
[ "$(grep -c 'com.claude-code-harness.update' "$TMP/crontab.txt")" = 1 ] && pass "one line after two runs" || fail "cron lines" "$(cat "$TMP/crontab.txt")"
grep -q '^0 0 \* \* \* /bin/true$' "$TMP/crontab.txt" && pass "the existing line survives" || fail "existing line" "$(cat "$TMP/crontab.txt")"
grep -q "^17 9 \* \* \* /bin/bash $HOME/.claude/harness-update.sh" "$TMP/crontab.txt" && pass "daily at 09:17" || fail "cron entry" "$(cat "$TMP/crontab.txt")"
HARNESS_SCHEDULER=cron bash "$UPD" --unschedule >/dev/null 2>&1
[ "$(grep -c 'com.claude-code-harness.update' "$TMP/crontab.txt")" = 0 ] && grep -q '/bin/true' "$TMP/crontab.txt" \
  && pass "--unschedule removes only its line" || fail "cron unschedule" "$(cat "$TMP/crontab.txt")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
