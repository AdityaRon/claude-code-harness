#!/usr/bin/env bash
# Moves this machine to the newest harness release: fetches tags from the
# clone's origin, checks the tag out detached, runs doctor.sh, installs on green.
#   harness-update.sh [--repo DIR] [--check]
#   harness-update.sh --schedule | --unschedule     daily, 09:17 local
#   harness-update.sh --newer A B                   exit 0 when tag A is newer
# Refuses a clone with uncommitted changes or with commits the release lacks;
# nothing is ever reset. The clone is the one install.sh ran from
# (repo= in ~/.claude/harness.version) unless --repo says otherwise.
set -uo pipefail
# launchd and cron start with a PATH that has no Homebrew; appended, so a
# caller's own PATH still wins.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION_FILE="$HOME/.claude/harness.version"
LATEST_FILE="$HOME/.claude/state/harness-latest"
LOG="$HOME/.claude/logs/harness-update.log"
LABEL=com.claude-code-harness.update
RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

usage() { sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 2; }
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

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

update() {
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
  local target="$HOME/.claude/harness-update.sh" plist unit
  [[ -x "$target" ]] || { say "no $target: run bash install.sh first"; exit 1; }
  mkdir -p "$(dirname "$LOG")"
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
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>17</integer></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
      launchctl bootstrap "gui/$(id -u)" "$plist" || { say "launchctl bootstrap failed; agent file is $plist"; exit 1; }
      say "scheduled daily at 09:17 via launchd ($plist); log: $LOG" ;;
    systemd)
      unit="$HOME/.config/systemd/user"; mkdir -p "$unit"
      printf '[Unit]\nDescription=Claude Code harness update\n[Service]\nType=oneshot\nExecStart=/bin/bash %s\nStandardOutput=append:%s\nStandardError=append:%s\n' \
        "$target" "$LOG" "$LOG" > "$unit/$LABEL.service"
      printf '[Unit]\nDescription=Claude Code harness update, daily\n[Timer]\nOnCalendar=*-*-* 09:17:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' \
        > "$unit/$LABEL.timer"
      systemctl --user daemon-reload && systemctl --user enable --now "$LABEL.timer" || { say "systemctl failed"; exit 1; }
      say "scheduled daily at 09:17 via a systemd user timer; log: $LOG" ;;
    cron)
      { crontab -l 2>/dev/null | grep -vF "# $LABEL"; echo "17 9 * * * /bin/bash $target >> $LOG 2>&1 # $LABEL"; } | crontab - \
        || { say "crontab failed"; exit 1; }
      say "scheduled daily at 09:17 via crontab; log: $LOG" ;;
  esac
}

unschedule() {
  case "$(scheduler)" in
    launchd)
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
      rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"; say "launchd agent removed" ;;
    systemd)
      systemctl --user disable --now "$LABEL.timer" >/dev/null 2>&1
      rm -f "$HOME/.config/systemd/user/$LABEL.service" "$HOME/.config/systemd/user/$LABEL.timer"
      systemctl --user daemon-reload >/dev/null 2>&1; say "systemd timer removed" ;;
    cron)
      crontab -l 2>/dev/null | grep -vF "# $LABEL" | crontab - ; say "crontab line removed" ;;
  esac
}

REPO="" CHECK=0 MODE=update
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --schedule) MODE=schedule; shift ;;
    --unschedule) MODE=unschedule; shift ;;
    --newer) newer "${2:-}" "${3:-}"; exit $? ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
mkdir -p "$(dirname "$LOG")"
case "$MODE" in
  update) update ;;
  schedule) schedule ;;
  unschedule) unschedule ;;
esac
