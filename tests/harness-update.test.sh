#!/usr/bin/env bash
# Tests for bin/harness-update.sh against a bare repo standing in for origin:
# it clones its own copy, moves it to the newest release tag, installs only when
# doctor is green, refuses local changes and commits, leaves an install the tag
# lacks alone, and schedules through stand-in launchctl and crontab binaries.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
# chmod first: a case makes a directory unreadable, which rm cannot recurse into.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'chmod -R u+rwx "$TMP"; rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd)   # macOS TMPDIR ends in /; install.sh records repo= without the //
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
# The installed copy, as launchd runs it.
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
printf 'version=%s\ncommit=%s\nrepo=%s\norigin=%s\n' "$VER" "$(git -C "$REPO" rev-parse HEAD)" "$REPO" \
  "$(git -C "$REPO" remote get-url origin)" > "$HOME/.claude/harness.version"
touch "$HOME/.claude/installed-$VER"; echo install >> "$HOME/order.log"
{ echo "#!/usr/bin/env bash"; echo "# installed at $VER"; cat "$HOME/.claude/harness-update.sh"; } > "$HOME/.claude/harness-update.sh.new"
chmod +x "$HOME/.claude/harness-update.sh.new"; mv -f "$HOME/.claude/harness-update.sh.new" "$HOME/.claude/harness-update.sh"
SH
# The stand-in doctor logs its arguments, and on red names a suite as doctor.sh does.
cat > "$SRC/doctor.sh" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$HOME/doctor.args"; rc=$(cat "$(dirname "$0")/DOCTOR_RC"); echo "SUMMARY: stub"
[ "$rc" = 0 ] || echo "FAILED: tests/stub.test.sh, 1 case(s); first: FAIL (expected=ask got=allow): stub case"
exit "$rc"
SH
echo 0 > "$SRC/DOCTOR_RC"; echo one > "$SRC/README"
# main ends past the newest tag, as the release workflow's CHANGELOG PR leaves it.
( cd "$SRC" && git init -q && $G add -A && $G commit -qm v1.0.0 && git tag v1.0.0 \
  && echo two > README && $G commit -qam v1.0.1 && git tag v1.0.1 && git tag nightly \
  && echo changelog >> README && $G commit -qam changelog ) || { echo "fixture failed"; exit 1; }
git clone -q --bare "$SRC" "$TMP/origin.git"
git -C "$SRC" remote add origin "$TMP/origin.git"
# The updater's default URL reaches the stand-in origin in every case, never GitHub.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$TMP/origin.git.insteadOf" \
  GIT_CONFIG_VALUE_0=https://github.com/AdityaRon/claude-code-harness.git
# CLONE is the clone install.sh ran from; U is the updater's own.
CLONE="$TMP/clone" U="$HOME/.claude/harness-src" HV="$HOME/.claude/harness.version"
git clone -q "$TMP/origin.git" "$CLONE" && ( cd "$CLONE" && git checkout -q --detach v1.0.0 )
printf 'version=v1.0.0\ncommit=%s\nrepo=%s\norigin=%s\n' "$(git -C "$CLONE" rev-parse HEAD)" "$CLONE" "$TMP/origin.git" > "$HV"
head_is() { [ "$(git -C "$U" rev-parse HEAD)" = "$(git -C "$U" rev-parse "$1^{commit}")" ]; }
sha() { git -C "$TMP/origin.git" rev-parse "$1^{commit}"; }
installed() { sed -n 's/^version=//p' "$HV"; }
push_tag() {   # push_tag TAG DOCTOR_RC
  ( cd "$SRC" && echo "$2" > DOCTOR_RC && echo "$1" >> README && $G commit -qam "$1" && git tag "$1" && git push -q origin HEAD "$1" )
}

echo ""
echo "=== first run: clones its own copy from origin= and installs the newest tag ==="
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $OUT"
[ "$(git -C "$U" remote get-url origin 2>/dev/null)" = "$TMP/origin.git" ] && [[ "$OUT" == *"cloning $TMP/origin.git into $U (origin= in "* ]] \
  && pass "cloned ~/.claude/harness-src from origin=, and says so" || fail "clone" "$OUT"
head_is v1.0.1 && pass "update clone at v1.0.1, though origin's main is past it" || fail "at v1.0.1" "$(git -C "$U" describe --tags 2>&1)"
[ "$(installed)" = v1.0.1 ] && [ -e "$HOME/.claude/installed-v1.0.1" ] && pass "install.sh ran and recorded v1.0.1" || fail "install" "$(installed)"
[[ "$OUT" == *"installed v1.0.1 (was v1.0.0) from $U"* ]] && pass "says what changed" || fail "message" "$OUT"
[ "$(sed -n 2p "$UPD")" = "# installed at v1.0.1" ] && pass "the updater replaced itself mid-run and finished" || fail "self-replace" "$(sed -n 2p "$UPD")"
[ -z "$(git -C "$U" symbolic-ref -q HEAD)" ] && pass "detached, no branch moved" || fail "detached" "$(git -C "$U" symbolic-ref HEAD)"
[ "$(git -C "$CLONE" rev-parse HEAD)" = "$(sha v1.0.0)" ] && [ -z "$(git -C "$CLONE" status --porcelain)" ] \
  && pass "the clone install.sh ran from is untouched" || fail "dev clone moved" "$(git -C "$CLONE" describe --tags)"
grep -qx "repo=$U" "$HV" && pass "harness.version now names the update clone" || fail "repo=" "$(cat "$HV")"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"up to date: v1.0.1"* ]] && pass "a second run is a no-op" || fail "no-op" "rc=$RC $OUT"
[ "$(ls "$HOME/.claude" | grep -c '^installed-')" = 1 ] && pass "install.sh not run again" || fail "reinstalled" ""

echo ""
echo "=== up to date, a skills fetch an install left behind is retried from the installed pin ==="
# A stand-in skills-sync.sh where install.sh puts the real one: it logs its arguments and fails.
printf 'url=x\ntag=v1.0.0\ncommit=%s\n' "$(printf '0%.0s' $(seq 1 40))" > "$HOME/.claude/skills.pin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\necho "  ⚠ skills: stand-in failure"; exit 1\n' "$TMP/sync.log" > "$HOME/.claude/skills-sync.sh"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(cat "$TMP/sync.log" 2>/dev/null)" = "--if-behind" ] && [[ "$OUT" == *"skills: still behind the pin; the next run retries:"*"stand-in failure"* ]] \
  && pass "an up-to-date run retries the skills; a failure there is named and still exit 0" || fail "skills retry" "rc=$RC $OUT"
bash "$UPD" --check >/dev/null 2>&1
[ "$(wc -l < "$TMP/sync.log" | tr -d ' ')" = 1 ] && pass "--check retries nothing" || fail "--check retried" "$(cat "$TMP/sync.log")"
rm -f "$HOME/.claude/skills.pin" "$HOME/.claude/skills-sync.sh"

echo ""
echo "=== --check reports and installs nothing ==="
push_tag v1.0.2 1   # doctor goes red on it, for the next case
OUT=$(bash "$UPD" --check 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"v1.0.2 is available"* ]] && pass "names the newer tag" || fail "--check" "rc=$RC $OUT"
head_is v1.0.1 && [ ! -e "$HOME/.claude/installed-v1.0.2" ] && pass "clone and install untouched" || fail "--check touched" ""
[ "$(cut -d' ' -f1 "$HOME/.claude/state/harness-latest")" = v1.0.2 ] && pass "harness-latest written for session-start" \
  || fail "harness-latest" "$(cat "$HOME/.claude/state/harness-latest" 2>/dev/null)"

echo ""
echo "=== red doctor: nothing installed, clone back where it was ==="
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"doctor.sh failed on v1.0.2"* ]] && pass "exit 1 and says why" || fail "red doctor" "rc=$RC $OUT"
DL="$HOME/.claude/logs/harness-update-doctor.log"
[[ "$OUT" == *"SUMMARY: stub; FAILED: tests/stub.test.sh, 1 case(s); first: FAIL (expected=ask got=allow): stub case; log: $DL"* ]] \
  && pass "names the failed suite and its first case, and where the log is" || fail "names the suite" "$OUT"
grep -q '^FAILED: tests/stub.test.sh' "$DL" && pass "the log is kept under ~/.claude/logs, which a reboot keeps" || fail "kept log" "$(ls "$HOME/.claude/logs")"
[ "$(cat "$HOME/doctor.args")" = --smoke ] && pass "gated on the smoke set" || fail "smoke set" "$(cat "$HOME/doctor.args")"
head_is v1.0.1 && pass "back at v1.0.1" || fail "back at v1.0.1" "$(git -C "$U" describe --tags)"
[ "$(installed)" = v1.0.1 ] && [ ! -e "$HOME/.claude/installed-v1.0.2" ] && pass "v1.0.1 still installed" || fail "installed" "$(installed)"
[ "$(cut -d' ' -f1 "$HOME/.claude/state/harness-latest")" = v1.0.2 ] && pass "harness-latest still names v1.0.2" || fail "latest" ""
push_tag v1.0.3 0
bash "$UPD" --full >/dev/null 2>&1; head_is v1.0.3 && [ "$(installed)" = v1.0.3 ] && pass "the next green tag installs" || fail "v1.0.3" "$(installed)"
[ -z "$(cat "$HOME/doctor.args")" ] && pass "--full gates on every suite" || fail "--full" "$(cat "$HOME/doctor.args")"

echo ""
echo "=== refusals: uncommitted changes, local commits in the update clone ==="
push_tag v1.0.4 0
echo dirty >> "$U/README"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"uncommitted changes"* ]] && head_is v1.0.3 && pass "dirty clone refused, untouched" || fail "dirty" "rc=$RC $OUT"
[ "$(installed)" = v1.0.3 ] && pass "nothing installed" || fail "installed" "$(installed)"
( cd "$U" && git checkout -q -- README && git checkout -q -b local && echo mine > mine && $G add mine && $G commit -qm mine )
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"commits origin does not"* ]] && pass "local commits refused" || fail "local commits" "rc=$RC $OUT"
[ "$(git -C "$U" symbolic-ref --short HEAD)" = local ] && pass "branch left alone" || fail "branch" ""
( cd "$U" && git checkout -q --detach v1.0.3 )
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && head_is v1.0.4 && pass "clean again: v1.0.4 installs" || fail "v1.0.4" "rc=$RC $OUT"
rm "$HV"
OUT=$(bash "$UPD" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"installed v1.0.4 (was none) from $U"* ]] && pass "no record: installs from the update clone" || fail "no record" "rc=$RC $OUT"
rm "$HV"; BYHAND="$TMP/byhand"
git clone -q "$TMP/origin.git" "$BYHAND" && git -C "$BYHAND" checkout -q --detach v1.0.3
OUT=$(bash "$UPD" --repo "$BYHAND" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.4 ] && grep -qx "repo=$BYHAND" "$HV" && [[ "$OUT" == *"git -C $BYHAND checkout"* ]] \
  && pass "--repo DIR updates DIR instead" || fail "--repo" "rc=$RC $OUT"

echo ""
echo "=== --with-cli: a Homebrew-cask Claude Code is upgraded first, then the harness ==="
fake_claude() { printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "$2" > "$1"; chmod +x "$1"; ln -sfn "$1" "$TMP/bin/claude"; }
mkdir -p "$CASK"; fake_claude "$CASK/claude" 2.1.300
CONF="$HOME/.claude/harness-update.conf"
# A stand-in ps: two processes run from the cask binary brew is about to delete.
printf '#!/usr/bin/env bash\ncat "%s/ps.txt" 2>/dev/null\n' "$TMP" > "$TMP/bin/ps"; chmod +x "$TMP/bin/ps"
# ps shows the binary's real path, as readlink -f gives it (/private/var here).
REALCASK=$(readlink -f "$CASK/claude")
printf '4242 %s\n4243 %s\n4300 /bin/zsh\n' "$REALCASK" "$REALCASK" > "$TMP/ps.txt"
UPGRADED="$HOME/.claude/state/cli-upgraded"
rm -f "$TMP/brew.log" "$HOME/order.log"; push_tag v1.0.5 0
OUT=$(bash "$UPD" --with-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.5 ] && pass "exit 0, v1.0.5 installed" || fail "with-cli run" "rc=$RC $OUT"
[[ "$OUT" == *"claude: running from $REALCASK: pids 4242 4243; after the upgrade each runs on a deleted binary"* ]] \
  && pass "names the pids running the binary brew deletes" || fail "pids" "$OUT"
grep -q "^claude-code@latest 2.1.300 -> 2.1.302 at 20[0-9][0-9]-.*; pids running the old binary: 4242 4243$" "$UPGRADED" 2>/dev/null \
  && pass "state/cli-upgraded records the upgrade and the pids, for session-start" || fail "cli-upgraded" "$(cat "$UPGRADED" 2>/dev/null)"
: > "$TMP/ps.txt"
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
PAST=$(git -C "$CLONE" rev-parse HEAD) UHEAD=$(git -C "$U" rev-parse HEAD)
git -C "$CLONE" push -q origin "$PAST:refs/heads/past"   # so the update clone can tell it holds TOP
printf 'version=%s-1-g%s\ncommit=%s\nrepo=%s\n' "$TOP" "${PAST:0:7}" "$PAST" "$CLONE" > "$HV"
OUT=$(bash "$UPD" --no-cli --check 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"already includes $TOP"* ]] && [[ "$OUT" != *"is available"* ]] \
  && pass "--check: up to date, $TOP not offered" || fail "past-tag check" "rc=$RC $OUT"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(git -C "$U" rev-parse HEAD)" = "$UHEAD" ] && [ ! -e "$HOME/.claude/installed-$TOP" ] \
  && pass "a run installs nothing and leaves the update clone where it is" || fail "past-tag run" "rc=$RC $OUT"
printf 'version=%s-1-g%s\nrepo=%s\n' "$TOP" "${PAST:0:7}" "$CLONE" > "$HV"
OUT=$(bash "$UPD" --no-cli --check 2>&1); RC=$?
[[ "$OUT" == *"already includes $TOP"* ]] && pass "no commit= line: the describe suffix is enough" || fail "describe fallback" "rc=$RC $OUT"

# Each case below has v1.0.8 to offer; only the guard under test keeps it out.
push_tag v1.0.8 0
unchanged() {   # unchanged RC: exit 0, harness.version as written, v1.0.8 not installed
  [ "$1" = 0 ] && [ "$(cat "$HV")" = "$REC" ] && [ ! -e "$HOME/.claude/installed-v1.0.8" ]
}

echo ""
echo "=== an install from a commit origin does not have is left alone ==="
$G -C "$CLONE" commit -q --allow-empty -m unpushed
LOCAL=$(git -C "$CLONE" rev-parse HEAD)
REC=$(printf 'version=%s-2-g%s\ncommit=%s\nrepo=%s' "$TOP" "${LOCAL:0:7}" "$LOCAL" "$CLONE"); echo "$REC" > "$HV"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
unchanged "$RC" && [[ "$OUT" == *"installed from ${LOCAL:0:12}, which origin does not have; not changing it"* ]] \
  && pass "says so, exit 0, nothing installed" || fail "unpushed" "rc=$RC $OUT"
OUT=$(bash "$UPD" --no-cli --check 2>&1); RC=$?
unchanged "$RC" && [[ "$OUT" == *"not changing it"* && "$OUT" != *"is available"* ]] \
  && pass "--check says the same" || fail "unpushed --check" "rc=$RC $OUT"

echo ""
echo "=== an install from a pushed commit the newest tag lacks is left alone ==="
REC=$(printf 'version=%s-1-g%s\ncommit=%s\nrepo=%s' "$TOP" "${PAST:0:7}" "$PAST" "$CLONE"); echo "$REC" > "$HV"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
unchanged "$RC" && [[ "$OUT" == *"installed from ${PAST:0:12}, which v1.0.8 does not include; not changing it"* ]] \
  && pass "says so, exit 0, nothing installed" || fail "diverged" "rc=$RC $OUT"

echo ""
echo "=== an install with uncommitted changes is left alone ==="
REC=$(printf 'version=v1.0.6-dirty\ncommit=%s\nrepo=%s' "$(sha v1.0.6)" "$CLONE"); echo "$REC" > "$HV"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
unchanged "$RC" && [[ "$OUT" == *"with uncommitted changes; not changing it"* ]] \
  && pass "says so, exit 0, nothing installed" || fail "dirty install" "rc=$RC $OUT"

echo ""
echo "=== an unreadable repo= does not stop the update (macOS denies launchd ~/Desktop) ==="
old_record() { printf 'version=v1.0.6\ncommit=%s\nrepo=%s\n' "$(sha v1.0.6)" "$CLONE" > "$HV"; }
old_record; echo "origin=$TMP/origin.git" >> "$HV"
chmod 000 "$CLONE"
if git -C "$CLONE" rev-parse HEAD >/dev/null 2>&1; then fail "chmod 000 still lets git read the clone; the cases below prove nothing" ""; fi
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
chmod 755 "$CLONE"
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.8 ] && pass "update clone present: v1.0.8 installs" || fail "unreadable repo=" "rc=$RC $OUT"
old_record   # no origin=, as written before this change
OUT=$(HARNESS_UPDATE_CLONE="$TMP/middle-src" bash "$UPD" --no-cli --check 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == *"cloning $TMP/origin.git into $TMP/middle-src (the origin of $CLONE)"* && "$OUT" == *"v1.0.8 is available"* ]] \
  && pass "no origin=, readable repo=: clones from that clone's origin" || fail "repo= origin" "rc=$RC $OUT"
chmod 000 "$CLONE"
OUT=$(HARNESS_UPDATE_CLONE="$TMP/fallback-src" bash "$UPD" --no-cli 2>&1); RC=$?
chmod 755 "$CLONE"
[ "$RC" = 0 ] && [[ "$OUT" == *"cloning https://github.com/AdityaRon/claude-code-harness.git into $TMP/fallback-src (the default"* ]] \
  && [ "$(installed)" = v1.0.8 ] && grep -qx "repo=$TMP/fallback-src" "$HV" \
  && pass "no origin=, unreadable repo=: clones the default URL and installs" || fail "default URL" "rc=$RC $OUT"
old_record; chmod 000 "$CLONE"
OUT=$(HARNESS_UPDATE_URL="$TMP/origin.git" HARNESS_UPDATE_CLONE="$TMP/env-src" bash "$UPD" --no-cli --check 2>&1); RC=$?
chmod 755 "$CLONE"
[ "$RC" = 0 ] && [[ "$OUT" == *"cloning $TMP/origin.git into $TMP/env-src (the default"*"v1.0.8 is available"* ]] \
  && pass "HARNESS_UPDATE_URL replaces the default URL, for a fork" || fail "HARNESS_UPDATE_URL" "rc=$RC $OUT"

echo ""
echo "=== once a day, before any early exit, disk-space.py stamps disk use for session-start ==="
# A stand-in where install.sh puts the real one: it logs its arguments and writes today's stamp.
DSP="$HOME/.claude/disk-space.py" DST="$HOME/.claude/state/disk-usage"
cat > "$DSP" <<'PY'
import os, sys, time
h = os.environ["HOME"]
open(h + "/disk.calls", "a").write(" ".join(sys.argv[1:]) + "\n")
if os.path.exists(h + "/disk.fail"):
    print("not stamped: du timed out")
    sys.exit(1)
extra = open(h + "/disk.extra").read() if os.path.exists(h + "/disk.extra") else ""
open(sys.argv[sys.argv.index("--out") + 1], "w").write("date=%s\n" % time.strftime("%Y-%m-%d") + extra)
print("disk: stand-in measured")
PY
calls() { wc -l < "$HOME/disk.calls" 2>/dev/null | tr -d ' '; }
printf 'version=v1.0.6\norigin=%s\n' "$TMP/no-origin.git" > "$HV"
OUT=$(HARNESS_UPDATE_CLONE="$TMP/no-src" bash "$UPD" --no-cli 2>&1); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *"git clone of $TMP/no-origin.git failed"* && "$OUT" == *"disk: stand-in measured"* ]] \
  && [ "$(cat "$HOME/disk.calls")" = "stamp --out $DST" ] && pass "a run that stops at a failed clone has stamped first" || fail "stamp first" "rc=$RC $OUT"
HARNESS_UPDATE_CLONE="$TMP/no-src" bash "$UPD" --no-cli >/dev/null 2>&1
[ "$(calls)" = 1 ] && pass "a second run the same day measures nothing" || fail "once a day" "$(cat "$HOME/disk.calls")"
echo date=2000-01-01 > "$DST"; touch "$HOME/disk.fail"; old_record; echo "origin=$TMP/origin.git" >> "$HV"
OUT=$(bash "$UPD" --no-cli --check 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 2 ] && [[ "$OUT" == *"disk-space: not stamped: du timed out"* && "$OUT" == *"v1.0.8 is available"* ]] \
  && pass "an older stamp is measured again; a failure is named and changes no exit status" || fail "stamp fails" "rc=$RC $(calls) $OUT"
cp "$DSP" "$TMP/dsp.stand"; rm -f "$DSP" "$HOME/disk.fail"
bash "$UPD" --no-cli --check >/dev/null 2>&1
[ "$(calls)" = 2 ] && [ "$(cat "$DST")" = date=2000-01-01 ] && pass "no disk-space.py installed: nothing runs" || fail "no tool" "$(calls)"

echo ""
echo "=== a tool newer than today's stamp stamps again; a release install stamps with the installed tool ==="
cp "$TMP/dsp.stand" "$DSP"; : > "$HOME/disk.calls"
printf 'date=%s\n' "$(date +%Y-%m-%d)" > "$DST"; touch -t 202001010000 "$DSP"
old_record; echo "origin=$TMP/origin.git" >> "$HV"
bash "$UPD" --no-cli --check >/dev/null 2>&1
[ "$(calls)" = 0 ] && pass "today's stamp and an older tool: nothing is measured" || fail "older tool" "$(calls)"
touch -t 202301010000 "$DST"; touch -t 202401010000 "$DSP"
bash "$UPD" --no-cli --check >/dev/null 2>&1
[ "$(calls)" = 1 ] && pass "a tool newer than today's stamp is stamped again (stamp calls 0 to 1)" || fail "newer tool" "$(calls)"
bash "$UPD" --no-cli --check >/dev/null 2>&1
[ "$(calls)" = 1 ] && pass "once stamped by that tool, the next run measures nothing" || fail "newer tool twice" "$(calls)"
# The stand-in install.sh runs $HOME/post-install.sh, which installs a tool with a later mtime, as cp -p of a newer checkout does.
printf '%s\n' '[ ! -f "$HOME/post-install.sh" ] || bash "$HOME/post-install.sh"' >> "$SRC/install.sh"
printf '%s\n' 'cp -p "$HOME/new-tool.py" "$HOME/.claude/disk-space.py"' > "$HOME/post-install.sh"
cp "$TMP/dsp.stand" "$HOME/new-tool.py"; touch -t 203001010000 "$HOME/new-tool.py"
push_tag v1.0.9 0
: > "$HOME/disk.calls"; old_record; echo "origin=$TMP/origin.git" >> "$HV"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.9 ] && [ "$(calls)" = 1 ] && [[ "$OUT" == *"installed v1.0.9"*"disk: stand-in measured"* ]] \
  && pass "an install that changes the tool stamps once more, after the install (first call early, second measures)" || fail "stamp after install" "rc=$RC $(calls) $OUT"
# The clone already held the new tool before today's first stamp: cp -p installs a file dated before that stamp.
printf 'date=%s\n' "$(date +%Y-%m-%d)" > "$DST"; touch -t 202001010000 "$DSP" "$HOME/new-tool.py"
push_tag v1.0.10 0
: > "$HOME/disk.calls"; old_record; echo "origin=$TMP/origin.git" >> "$HV"
OUT=$(bash "$UPD" --no-cli 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(installed)" = v1.0.10 ] && [ "$DSP" -ot "$DST" ] && [ "$(calls)" = 1 ] && [[ "$OUT" == *"installed v1.0.10"*"disk: stand-in measured"* ]] \
  && pass "an installed tool dated before today's stamp is still stamped after the install" || fail "stamp after old-dated install" "rc=$RC $(calls) $OUT"

echo ""
echo "=== a stamp that crosses a disk limit posts one desktop notification, once per crossing ==="
FLAGS="$HOME/.claude/state/disk-notified" SET_JSON="$HOME/.claude/settings.json"
rm -f "$FLAGS" "$SET_JSON" "$HOME/disk.fail"; cp "$TMP/dsp.stand" "$DSP"
# Each run starts from an old stamp, so the stand-in writes a new one from disk.extra.
nrun() {
  printf '%s\n' "$1" > "$HOME/disk.extra"; echo date=2000-01-01 > "$DST"; old_record; echo "origin=$TMP/origin.git" >> "$HV"
  shift; NOUT=$(env -u CLAUDE_DISK_WARN_JOBS_GB -u CLAUDE_DISK_WARN_BAZEL_GB CLAUDE_NOTIFY_DRY_RUN=1 "$@" bash "$UPD" --no-cli --check 2>&1)
  NN=$(grep -cx 'Claude Code harness' <<< "$NOUT")
}
flags() { tr '\n' ' ' < "$FLAGS" 2>/dev/null; }
nrun $'jobs_bytes=60000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
[ "$NN" = 1 ] && [[ "$NOUT" == *"Job folders in ~/.claude/jobs hold 60.0 GB (past 50 GB): python3 ~/.claude/disk-space.py report"* ]] \
  && [ "$(flags)" = "jobs=1 bazel=0 idle=0 " ] && pass "first run, jobs over: one notification, jobs=1 written" || fail "first crossing" "$NN $(flags) $NOUT"
nrun $'jobs_bytes=61000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
[ "$NN" = 0 ] && [ "$(flags)" = "jobs=1 bazel=0 idle=0 " ] && pass "the same condition on the next stamp: no notification" || fail "level-triggered" "$NN $NOUT"
nrun $'jobs_bytes=1000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
[ "$NN" = 0 ] && [ "$(flags)" = "jobs=0 bazel=0 idle=0 " ] && pass "back under: jobs=0 written, nothing posted" || fail "back under" "$NN $(flags) $NOUT"
nrun $'jobs_bytes=60000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
[ "$NN" = 1 ] && [ "$(flags)" = "jobs=1 bazel=0 idle=0 " ] && pass "over again after a clear: posts again" || fail "re-cross" "$NN $NOUT"
nrun $'jobs_bytes=60000000000\nbazel_bytes=1000\ntranscripts_idle=3 3000000000 30'
[ "$NN" = 1 ] && [[ "$NOUT" == *"3 idle session transcripts hold 3.0 GB: python3 ~/.claude/disk-space.py transcripts"* ]] && [ "$(flags)" = "jobs=1 bazel=0 idle=1 " ] \
  && pass "idle transcripts appear: one notification" || fail "idle appears" "$NN $NOUT"
nrun $'jobs_bytes=60000000000\nbazel_bytes=1000\ntranscripts_idle=5 5000000000 30'
[ "$NN" = 0 ] && pass "idle count 3 to 5: no notification" || fail "idle count change" "$NN $NOUT"
nrun $'jobs_bytes=1000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
nrun $'jobs_bytes=60000000000\nbazel_bytes=120000000000\ntranscripts_idle=0 0 0'
[ "$NN" = 2 ] && [[ "$NOUT" == *"The Bazel output root holds 120.0 GB (past 100 GB): python3 ~/.claude/disk-space.py bazel"* ]] \
  && pass "jobs and bazel crossing together: two notifications" || fail "two crossings" "$NN $NOUT"
nrun $'jobs_bytes=1000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
printf '{"env":{"CLAUDE_DISK_WARN_JOBS_GB":"5"}}\n' > "$SET_JSON"
nrun $'jobs_bytes=6000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
[ "$NN" = 1 ] && [[ "$NOUT" == *"(past 5 GB)"* ]] && pass "a limit in settings.json env applies though the process env is unset" || fail "settings.json limit" "$NN $NOUT"
printf '{"env":{"CLAUDE_DISK_WARN_JOBS_GB":"5"}}\n' > "$SET_JSON"
nrun $'jobs_bytes=1000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
nrun $'jobs_bytes=6000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0' CLAUDE_DISK_WARN_JOBS_GB=1
[ "$NN" = 1 ] && [[ "$NOUT" == *"(past 5 GB)"* ]] && pass "settings.json wins over the process env" || fail "settings over env" "$NN $NOUT"
printf '{"env":{"CLAUDE_DISK_WARN_JOBS_GB":"lots"}}\n' > "$SET_JSON"
nrun $'jobs_bytes=1000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
nrun $'jobs_bytes=60000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
[ "$NN" = 1 ] && [[ "$NOUT" == *"(past 50 GB)"* ]] && pass "a non-digit limit falls back to the default" || fail "non-digit limit" "$NN $NOUT"
rm -f "$SET_JSON"
nrun $'jobs_bytes=60000000000\nbazel_bytes=1000\ntranscripts_idle=0 0 0'
nrun $'jobs_bytes=1000\nbazel_bytes=500000000000\ntranscripts_idle=0 0 0'; : > "$HOME/disk.calls"
printf '%s\n' 'x=1' > "$HOME/disk.extra"; echo date=2000-01-01 > "$DST"; touch "$HOME/disk.fail"
NOUT=$(CLAUDE_NOTIFY_DRY_RUN=1 bash "$UPD" --no-cli --check 2>&1); NN=$(grep -cx 'Claude Code harness' <<< "$NOUT"); rm -f "$HOME/disk.fail"
[ "$NN" = 0 ] && [ "$(flags)" = "jobs=0 bazel=1 idle=0 " ] && pass "a failed stamp posts nothing and leaves the flag file" || fail "failed stamp" "$NN $(flags) $NOUT"
# Today's stamp and an older tool: nothing is re-measured, so nothing is notified, whatever the flags say.
printf '%s\n' 'jobs_bytes=900000000000' > "$HOME/disk.extra"; printf 'date=%s\njobs_bytes=900000000000\n' "$(date +%Y-%m-%d)" > "$DST"
touch -t 202301010000 "$DSP"; touch -t 202401010000 "$DST"; printf 'jobs=0\nbazel=0\nidle=0\n' > "$FLAGS"
OUT=$(CLAUDE_NOTIFY_DRY_RUN=1 bash "$UPD" --no-cli --check 2>&1); NN=$(grep -cx 'Claude Code harness' <<< "$OUT")
[ "$NN" = 0 ] && [ "$(flags)" = "jobs=0 bazel=0 idle=0 " ] && pass "a skipped stamp (today's, tool older) posts nothing" || fail "skipped stamp" "$NN $OUT"
nrun $'jobs_bytes=1000\nbazel_bytes=1000\ntranscripts_idle=0 0 0\nguard_p90_ms=99999\nguard_calls=200'
[ "$NN" = 0 ] && pass "guard latency over its line is never notified" || fail "guard latency" "$NN $NOUT"
rm -f "$HOME/disk.extra" "$FLAGS"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
