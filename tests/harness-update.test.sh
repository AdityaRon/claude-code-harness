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
# A stand-in brew, first on PATH before any case runs: the updater appends
# /opt/homebrew/bin, where the real one may be. It logs its arguments and, on a
# good upgrade, moves the fake Caskroom claude to 2.1.302.
CASK="$TMP/Caskroom/claude-code@latest/2.1.300"
cat > "$TMP/bin/brew" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/brew.log"; echo brew >> "$HOME/order.log"
RC=\$(cat "$TMP/brew.rc" 2>/dev/null || echo 0)
[ "\$1 \$RC" = "upgrade 0" ] && printf '#!/usr/bin/env bash\necho "2.1.302 (Claude Code)"\n' > "$CASK/claude"
exit "\$RC"
SH
chmod +x "$TMP/bin/brew"
[ "$(command -v brew)" = "$TMP/bin/brew" ] || { echo "  FAIL: the stand-in brew is not first on PATH; stopping"; exit 1; }
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
touch "$HOME/.claude/installed-$VER"; echo install >> "$HOME/order.log"
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
echo "=== --with-cli: a Homebrew-cask Claude Code is upgraded first, then the harness ==="
fake_claude() { printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "$2" > "$1"; chmod +x "$1"; ln -sfn "$1" "$TMP/bin/claude"; }
mkdir -p "$CASK"; fake_claude "$CASK/claude" 2.1.300
CONF="$HOME/.claude/harness-update.conf"
rm -f "$TMP/brew.log" "$HOME/order.log"; push_tag v1.0.5 0
OUT=$(bash "$UPD" --with-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.5 ] && pass "exit 0, v1.0.5 installed" || fail "with-cli run" "rc=$RC $OUT"
[ "$(cat "$TMP/brew.log" 2>/dev/null)" = "$(printf 'update --quiet\nupgrade --cask claude-code@latest')" ] \
  && pass "brew update, then upgrade --cask claude-code@latest" || fail "brew calls" "$(cat "$TMP/brew.log" 2>/dev/null)"
[[ "$OUT" == *"Homebrew cask claude-code@latest (2.1.300) at "*"/Caskroom/"* && "$OUT" == *"claude-code@latest 2.1.300 -> 2.1.302"* ]] \
  && pass "names the cask, its path and both versions" || fail "cli message" "$OUT"
[ "$(tr '\n' ' ' < "$HOME/order.log")" = "brew brew install " ] && pass "brew runs before install.sh" || fail "order" "$(cat "$HOME/order.log")"
grep -qx 'with_cli=1' "$CONF" && pass "recorded in harness-update.conf" || fail "conf" "$(cat "$CONF" 2>/dev/null)"

echo ""
echo "=== the choice holds for argument-free runs until --no-cli ==="
fake_claude "$CASK/claude" 2.1.300; rm -f "$TMP/brew.log"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -qx 'upgrade --cask claude-code@latest' "$TMP/brew.log" 2>/dev/null \
  && pass "a later plain run still upgrades the CLI" || fail "plain run" "rc=$RC $OUT"
rm -f "$TMP/brew.log"
OUT=$(bash "$UPD" --no-cli 2>&1)
[ ! -e "$TMP/brew.log" ] && grep -qx 'with_cli=0' "$CONF" && pass "--no-cli: brew not called, recorded" || fail "--no-cli" "$OUT"
bash "$UPD" >/dev/null 2>&1
[ ! -e "$TMP/brew.log" ] && pass "a plain run after --no-cli leaves brew alone" || fail "after --no-cli" "$(cat "$TMP/brew.log")"

echo ""
echo "=== a failed brew is reported and the harness update goes on ==="
echo 1 > "$TMP/brew.rc"; rm -f "$TMP/brew.log"; push_tag v1.0.6 0
OUT=$(bash "$UPD" --with-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"claude-code@latest failed (see "* ]] && pass "exit 0 and says brew failed" || fail "brew failed" "rc=$RC $OUT"
[ "$(installed)" = v1.0.6 ] && pass "v1.0.6 installed anyway" || fail "installed after brew failure" "$(installed)"
rm -f "$TMP/brew.rc"

echo ""
echo "=== npm and native installs, or none, are left alone ==="
NPM="$TMP/npm/lib/node_modules/@anthropic-ai/claude-code"; mkdir -p "$NPM"; fake_claude "$NPM/cli.js" 2.1.300
rm -f "$TMP/brew.log"
OUT=$(bash "$UPD" 2>&1)
[[ "$OUT" == *"claude: npm install at "* ]] && [ ! -e "$TMP/brew.log" ] && pass "npm: named, brew not called" || fail "npm" "$OUT"
NAT="$HOME/.local/share/claude/versions"; mkdir -p "$NAT"; fake_claude "$NAT/2.1.296" 2.1.296
OUT=$(bash "$UPD" 2>&1)
[[ "$OUT" == *"claude: native install at "* ]] && [ ! -e "$TMP/brew.log" ] && pass "native: named, brew not called" || fail "native" "$OUT"
# CLAUDE_CLI_BIN: the updater's appended PATH may hold a real claude here.
OUT=$(CLAUDE_CLI_BIN="$TMP/none/claude" bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"claude: not on PATH"* ]] && [ ! -e "$TMP/brew.log" ] && pass "no claude: says so, exit 0" || fail "no claude" "rc=$RC $OUT"

echo ""
echo "=== --check --with-cli reports the cask and changes nothing ==="
fake_claude "$CASK/claude" 2.1.300; push_tag v1.0.7 0
OUT=$(bash "$UPD" --check --with-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"Homebrew cask claude-code@latest (2.1.300)"*"a run without --check upgrades it"* ]] \
  && pass "names the cask" || fail "--check cli" "rc=$RC $OUT"
[ ! -e "$TMP/brew.log" ] && [ "$(installed)" = v1.0.6 ] && [ ! -e "$HOME/.claude/installed-v1.0.7" ] \
  && pass "brew not called, nothing installed" || fail "--check touched" "$(installed) $(cat "$TMP/brew.log" 2>/dev/null)"

echo ""
echo "=== --schedule: launchd, four slots ==="
printf '#!/usr/bin/env bash\necho "$*" >> "%s/launchctl.log"\n' "$TMP" > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"
PLIST="$HOME/Library/LaunchAgents/com.claude-code-harness.update.plist"
OUT=$(HARNESS_SCHEDULER=launchd bash "$UPD" --schedule 2>&1); RC=$?
[ "$RC" = 0 ] && [ -f "$PLIST" ] && pass "agent file written" || fail "plist" "rc=$RC $OUT"
grep -qF "<array><string>/bin/bash</string><string>$HOME/.claude/harness-update.sh</string></array>" "$PLIST" \
  && pass "runs the installed copy, no arguments" || fail "program" "$(cat "$PLIST")"
H=$(grep -oE '<key>Hour</key><integer>[0-9]+</integer><key>Minute</key><integer>17</integer>' "$PLIST" | sed -E 's/.*Hour<\/key><integer>([0-9]+).*/\1/' | tr '\n' ' ')
[ "$H" = "1 7 13 19 " ] && pass "Hour 1, 7, 13, 19 at Minute 17" || fail "calendar" "[$H] $(cat "$PLIST")"
if command -v plutil >/dev/null; then plutil -lint -s "$PLIST" >/dev/null && pass "plist lints" || fail "plist lints" "$(plutil -lint "$PLIST")"; fi
[[ "$OUT" == *"at 01:17, 07:17, 13:17 and 19:17 local, with the CLI upgrade via launchd"* ]] \
  && pass "names the four times and the CLI upgrade" || fail "schedule message" "$OUT"
grep -q "^bootstrap gui/" "$TMP/launchctl.log" && pass "launchctl bootstrap called" || fail "bootstrap" "$(cat "$TMP/launchctl.log")"
OUT=$(HARNESS_SCHEDULER=launchd bash "$UPD" --unschedule 2>&1)
[ ! -f "$PLIST" ] && grep -q "^bootout gui/" "$TMP/launchctl.log" && pass "--unschedule removes the agent" || fail "unschedule" ""
[[ "$OUT" == *"the CLI upgrade stays on for runs by hand"* ]] && pass "and says the CLI choice stays" || fail "unschedule message" "$OUT"

echo ""
echo "=== --schedule: systemd timer ==="
printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemctl.log"\n' "$TMP" > "$TMP/bin/systemctl"; chmod +x "$TMP/bin/systemctl"
HARNESS_SCHEDULER=systemd bash "$UPD" --schedule >/dev/null 2>&1
grep -qx 'OnCalendar=\*-\*-\* 01,07,13,19:17:00' "$HOME/.config/systemd/user/com.claude-code-harness.update.timer" 2>/dev/null \
  && grep -qx 'Persistent=true' "$HOME/.config/systemd/user/com.claude-code-harness.update.timer" \
  && pass "OnCalendar at 01,07,13,19:17, Persistent" || fail "timer" "$(cat "$HOME/.config/systemd/user/com.claude-code-harness.update.timer" 2>/dev/null)"
grep -q 'enable --now com.claude-code-harness.update.timer' "$TMP/systemctl.log" && pass "timer enabled" || fail "systemctl" "$(cat "$TMP/systemctl.log")"
HARNESS_SCHEDULER=systemd bash "$UPD" --unschedule >/dev/null 2>&1

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
grep -q "^17 1,7,13,19 \* \* \* /bin/bash $HOME/.claude/harness-update.sh >> " "$TMP/crontab.txt" \
  && pass "at 17 past 1, 7, 13 and 19, no arguments" || fail "cron entry" "$(cat "$TMP/crontab.txt")"
HARNESS_SCHEDULER=cron bash "$UPD" --unschedule >/dev/null 2>&1
[ "$(grep -c 'com.claude-code-harness.update' "$TMP/crontab.txt")" = 0 ] && grep -q '/bin/true' "$TMP/crontab.txt" \
  && pass "--unschedule removes only its line" || fail "cron unschedule" "$(cat "$TMP/crontab.txt")"

echo ""
echo "=== a clone installed past the newest tag is up to date, not moved back ==="
git -C "$CLONE" fetch -q --tags origin
TOP=$(git -C "$CLONE" tag -l 'v*' | sort -V | tail -1)
git -C "$CLONE" checkout -q --detach "$TOP" && $G -C "$CLONE" commit -q --allow-empty -m past
PAST=$(git -C "$CLONE" rev-parse HEAD)
printf 'version=%s-1-g%s\ncommit=%s\nrepo=%s\n' "$TOP" "${PAST:0:7}" "$PAST" "$CLONE" > "$HOME/.claude/harness.version"
OUT=$(bash "$UPD" --no-cli --check 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"already includes $TOP"* ]] && [[ "$OUT" != *"is available"* ]] \
  && pass "--check: up to date, $TOP not offered" || fail "past-tag check" "rc=$RC $OUT"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(git -C "$CLONE" rev-parse HEAD)" = "$PAST" ] && pass "a run leaves the clone where it is" || fail "past-tag run" "rc=$RC $OUT"
printf 'version=%s-1-g%s\nrepo=%s\n' "$TOP" "${PAST:0:7}" "$CLONE" > "$HOME/.claude/harness.version"
OUT=$(bash "$UPD" --no-cli --check 2>&1); RC=$?
[[ "$OUT" == *"already includes $TOP"* ]] && pass "no commit= line: the describe suffix is enough" || fail "describe fallback" "rc=$RC $OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
