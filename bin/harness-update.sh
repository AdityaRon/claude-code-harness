#!/usr/bin/env bash
# Moves this machine to the newest harness release: fetches tags from the
# clone's origin, checks the tag out detached, runs doctor.sh, installs on green.
#   harness-update.sh [--repo DIR] [--check] [--with-cli | --no-cli]
#   harness-update.sh --schedule | --unschedule   01:17, 07:17, 13:17, 19:17 local
#   harness-update.sh --newer A B                 exit 0 when tag A is newer
# --with-cli first upgrades a Homebrew-cask Claude Code, on later runs too, until
# --no-cli. Refuses a clone with local changes or commits the release lacks;
# never resets. The clone is install.sh's (repo= in ~/.claude/harness.version).
set -uo pipefail
# launchd and cron start with a PATH that has no Homebrew; appended, so a
# caller's own PATH still wins.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION_FILE="$HOME/.claude/harness.version"
LATEST_FILE="$HOME/.claude/state/harness-latest"
LOG="$HOME/.claude/logs/harness-update.log"
CONF="$HOME/.claude/harness-update.conf"
LABEL=com.claude-code-harness.update
RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
# Local time, minute 17: a tag is installed within six hours.
HOURS="1 7 13 19"

usage() { sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 2; }
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
slots() {   # 01:17, 07:17, 13:17 and 19:17
  local h s=""
  for h in $HOURS; do s="$s, $(printf '%02d:17' "$h")"; done
  s=${s#, }; echo "${s%, *} and ${s##*, }"
}
with_cli() {   # with_cli [kept]: a clause for the schedule messages
  [[ "$CLI" == 1 ]] || return 0
  if [[ "${1:-}" == kept ]]; then echo "; the CLI upgrade stays on for runs by hand (--no-cli turns it off)"
  else echo ", with the CLI upgrade"; fi
}

# newer A B: is release tag A newer than B? 2 when either is not a release tag.
newer() {
  [[ "$1" =~ $RE && "$2" =~ $RE ]] || return 2
  local a b i
  IFS=. read -r -a a <<< "${1#v}"; IFS=. read -r -a b <<< "${2#v}"
  for i in 0 1 2; do
    (( ${a[$i]} > ${b[$i]} )) && return 0
    (( ${a[$i]} < ${b[$i]} )) && return 1
  done
  return 1
}

latest_tag() {   # newest release tag the clone knows
  git -C "$1" tag -l 'v*' | grep -E "$RE" | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | sed 's/^/v/'
}

find_repo() {
  if [[ -n "$REPO" ]]; then :
  elif [[ -f "$HERE/../install.sh" ]]; then REPO=$(cd "$HERE/.." && pwd)
  elif [[ -f "$VERSION_FILE" ]]; then REPO=$(sed -n 's/^repo=//p' "$VERSION_FILE" | head -1)
  fi
  [[ -n "$REPO" && -f "$REPO/install.sh" ]] || { say "no harness clone found; pass --repo DIR"; exit 1; }
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { say "$REPO is not a git clone"; exit 1; }
}

installed_version() { sed -n 's/^version=//p' "$VERSION_FILE" 2>/dev/null | head -1; }

# Before the harness, so a release that needs a newer CLI finds it. Never
# fails the run. CLAUDE_CLI_BIN is a testing seam, as in upstream-check.sh.
cli_update() {
  local bin real cask before after
  bin=${CLAUDE_CLI_BIN:-$(command -v claude 2>/dev/null)}
  [[ -n "$bin" && -x "$bin" ]] || { say "claude: not on PATH; nothing to upgrade"; return 0; }
  real=$(readlink -f "$bin" 2>/dev/null || echo "$bin")
  case "$real" in
    */Caskroom/*/*) cask=${real#*/Caskroom/}; cask=${cask%%/*} ;;
    */node_modules/@anthropic-ai/claude-code/*)
      say "claude: npm install at $real; not touched (npm i -g @anthropic-ai/claude-code updates it)"; return 0 ;;
    */.local/share/claude/versions/*) say "claude: native install at $real; Claude Code updates itself"; return 0 ;;
    *) say "claude: unrecognised install at $real; not touched"; return 0 ;;
  esac
  command -v brew >/dev/null || { say "claude: Homebrew cask $cask, but no brew on PATH; not touched"; return 0; }
  before=$("$bin" --version 2>/dev/null | cut -d' ' -f1)
  if [[ "$CHECK" == 1 ]]; then
    say "claude: Homebrew cask $cask ($before) at $real; a run without --check upgrades it"; return 0
  fi
  say "claude: Homebrew cask $cask ($before) at $real; running brew upgrade"
  if HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew update --quiet >>"$LOG" 2>&1 \
     && HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade --cask "$cask" >>"$LOG" 2>&1; then
    after=$("$bin" --version 2>/dev/null | cut -d' ' -f1)
    if [[ "$after" == "$before" ]]; then say "claude: $cask up to date ($after)"; else say "claude: $cask $before -> $after"; fi
  else
    # brew's lock, held by a session's own upgrade, lands here too; the next slot retries.
    say "claude: brew update or upgrade --cask $cask failed (see $LOG); the harness update continues"
  fi
}

update() {
  if [[ "$CLI" == 1 ]]; then cli_update; fi
  find_repo
  if ! git -C "$REPO" fetch --tags --quiet origin 2>>"$LOG"; then
    say "fetch from origin failed (see $LOG)"; exit 1
  fi
  LATEST=$(latest_tag "$REPO")
  [[ -n "$LATEST" ]] || { say "origin has no release tags yet"; exit 0; }
  mkdir -p "$(dirname "$LATEST_FILE")" && printf '%s %s\n' "$LATEST" "$(date -u +%Y-%m-%d)" > "$LATEST_FILE"
  INSTALLED=$(installed_version)
  if [[ "$INSTALLED" =~ $RE ]] && ! newer "$LATEST" "$INSTALLED"; then
    say "up to date: $INSTALLED"; exit 0
  fi
  # A clone installed from a branch past the tag (v1.0.0-11-gabc1234) is not a
  # release tag, but already holds LATEST; moving it to LATEST would go back.
  INSTALLED_COMMIT=$(sed -n 's/^commit=//p' "$VERSION_FILE" 2>/dev/null | head -1)
  [[ -n "$INSTALLED_COMMIT" ]] || INSTALLED_COMMIT=$(sed -nE 's/^v[0-9.]+-[0-9]+-g([0-9a-f]+)(-dirty)?$/\1/p' <<< "$INSTALLED")
  if [[ -n "$INSTALLED_COMMIT" ]] && git -C "$REPO" merge-base --is-ancestor "$LATEST" "$INSTALLED_COMMIT" 2>/dev/null; then
    say "up to date: $INSTALLED already includes $LATEST"; exit 0
  fi
  if [[ "$CHECK" == 1 ]]; then
    say "$LATEST is available (installed: ${INSTALLED:-none}); run $0 to install it"; exit 0
  fi
  if [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]; then
    say "refusing: $REPO has uncommitted changes; commit or stash them first"; exit 1
  fi
  if ! git -C "$REPO" merge-base --is-ancestor HEAD "$LATEST"; then
    say "refusing: $REPO has commits $LATEST does not ($(git -C "$REPO" rev-parse --short HEAD)); check the tag out yourself"; exit 1
  fi
  PREV=$(git -C "$REPO" symbolic-ref --short -q HEAD || git -C "$REPO" rev-parse HEAD)
  if [[ "$(git -C "$REPO" rev-parse HEAD)" != "$(git -C "$REPO" rev-parse "$LATEST^{commit}")" ]]; then
    git -C "$REPO" checkout --quiet --detach "$LATEST" || { say "checkout of $LATEST failed"; exit 1; }
  fi
  say "checked out $LATEST (was $PREV); running doctor.sh"
  DOC=$(mktemp "${TMPDIR:-/tmp}/cch-update.XXXXXX")
  if ! bash "$REPO/doctor.sh" > "$DOC" 2>&1; then
    git -C "$REPO" checkout --quiet "$PREV" 2>/dev/null
    say "doctor.sh failed on $LATEST; back on $PREV, nothing installed: $(grep '^SUMMARY:' "$DOC" || echo "see $DOC")"
    exit 1
  fi
  say "$(grep '^SUMMARY:' "$DOC")"; rm -f "$DOC"
  if ! CCH_SKIP_SELFTEST=1 bash "$REPO/install.sh"; then
    say "install.sh failed on $LATEST; the clone stays at $LATEST, ~/.claude may hold a mix"; exit 1
  fi
  say "installed $LATEST (was ${INSTALLED:-none}); to work on the clone again: git -C $REPO checkout $PREV"
}

scheduler() {
  if [[ -n "${HARNESS_SCHEDULER:-}" ]]; then echo "$HARNESS_SCHEDULER"
  elif [[ "$(uname -s)" == Darwin ]]; then echo launchd
  elif command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then echo systemd
  else echo cron; fi
}

schedule() {
  local target="$HOME/.claude/harness-update.sh" plist unit h cal="" hh="" h2=""
  [[ -x "$target" ]] || { say "no $target: run bash install.sh first"; exit 1; }
  mkdir -p "$(dirname "$LOG")"
  for h in $HOURS; do
    cal="$cal<dict><key>Hour</key><integer>$h</integer><key>Minute</key><integer>17</integer></dict>"
    hh="$hh,$h"; h2="$h2,$(printf '%02d' "$h")"
  done
  hh=${hh#,} h2=${h2#,}
  # The job runs with no arguments, so a reinstall keeps --with-cli: it is in $CONF.
  case "$(scheduler)" in
    launchd)
      plist="$HOME/Library/LaunchAgents/$LABEL.plist"
      mkdir -p "$(dirname "$plist")"
      cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$target</string></array>
  <key>StartCalendarInterval</key><array>$cal</array>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
      launchctl bootstrap "gui/$(id -u)" "$plist" || { say "launchctl bootstrap failed; agent file is $plist"; exit 1; }
      say "scheduled at $(slots) local$(with_cli) via launchd ($plist); log: $LOG" ;;
    systemd)
      unit="$HOME/.config/systemd/user"; mkdir -p "$unit"
      printf '[Unit]\nDescription=Claude Code harness update\n[Service]\nType=oneshot\nExecStart=/bin/bash %s\nStandardOutput=append:%s\nStandardError=append:%s\n' \
        "$target" "$LOG" "$LOG" > "$unit/$LABEL.service"
      printf '[Unit]\nDescription=Claude Code harness update, four times a day\n[Timer]\nOnCalendar=*-*-* %s:17:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' \
        "$h2" > "$unit/$LABEL.timer"
      systemctl --user daemon-reload && systemctl --user enable --now "$LABEL.timer" || { say "systemctl failed"; exit 1; }
      say "scheduled at $(slots) local$(with_cli) via a systemd user timer; log: $LOG" ;;
    cron)
      { crontab -l 2>/dev/null | grep -vF "# $LABEL"; echo "17 $hh * * * /bin/bash $target >> $LOG 2>&1 # $LABEL"; } | crontab - \
        || { say "crontab failed"; exit 1; }
      say "scheduled at $(slots) local$(with_cli) via crontab; log: $LOG" ;;
  esac
}

unschedule() {
  case "$(scheduler)" in
    launchd)
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
      rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"; say "launchd agent removed$(with_cli kept)" ;;
    systemd)
      systemctl --user disable --now "$LABEL.timer" >/dev/null 2>&1
      rm -f "$HOME/.config/systemd/user/$LABEL.service" "$HOME/.config/systemd/user/$LABEL.timer"
      systemctl --user daemon-reload >/dev/null 2>&1; say "systemd timer removed$(with_cli kept)" ;;
    cron)
      crontab -l 2>/dev/null | grep -vF "# $LABEL" | crontab - ; say "crontab line removed$(with_cli kept)" ;;
  esac
}

REPO="" CHECK=0 MODE=update CLI=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --with-cli) CLI=1; shift ;;
    --no-cli) CLI=0; shift ;;
    --schedule) MODE=schedule; shift ;;
    --unschedule) MODE=unschedule; shift ;;
    --newer) newer "${2:-}" "${3:-}"; exit $? ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
mkdir -p "$(dirname "$LOG")"
if [[ -n "$CLI" ]]; then
  printf 'with_cli=%s\n' "$CLI" > "$CONF"
else
  CLI=$(sed -n 's/^with_cli=//p' "$CONF" 2>/dev/null | tail -1)
fi
case "$MODE" in
  update) update ;;
  schedule) schedule ;;
  unschedule) unschedule ;;
esac
