#!/usr/bin/env bash
# Detects when Claude Code has drifted away from what this harness assumes.
#
# The harness hard-codes upstream facts: which hook events exist, which
# permission modes are valid, what the CLI accepts in settings.json. Claude Code
# auto-updates and those facts move. A push-triggered CI run can never catch it,
# because upstream changes when this repo does not — so this is built to run on a
# schedule (.github/workflows/upstream-drift.yml) and to fail loudly when reality
# and upstream-contract.json disagree.
#
# Auth-free by design: `claude doctor` and `claude --version` need no login, so
# CI runs them without credentials.
#
# Usage:  bash upstream-check.sh
# Exit:   0 contract holds · 1 BREAKAGE · 2 upstream grew (needs acknowledging)
#         3 could not run the checks
#
# Testing seam: CLAUDE_DOCTOR_CMD overrides how doctor is invoked so
# tests/upstream-check.test.sh can feed canned output with no CLI installed.
#
# Portability: no mapfile/associative arrays — macOS ships bash 3.2.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$REPO/settings.json"
CONTRACT="$REPO/upstream-contract.json"
DOCTOR_CMD=${CLAUDE_DOCTOR_CMD:-"claude doctor"}
SENTINEL_EVENT="HarnessDriftSentinel"
SENTINEL_MODE="harness-drift-sentinel"

BREAKAGE=0
ADVISORY=0

say(){ printf '%s\n' "$*"; }
fail(){ printf '  ✗ %s\n' "$*"; BREAKAGE=1; }
warn(){ printf '  ⚠ %s\n' "$*"; ADVISORY=1; }
ok(){   printf '  ✓ %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { say "FATAL: jq is required."; exit 3; }
for f in "$SETTINGS" "$CONTRACT"; do
  [ -f "$f" ] || { say "FATAL: missing $f"; exit 3; }
done

# `claude` absent (a contributor's laptop) is a skip, not a failure. CI installs it.
if [ -z "${CLAUDE_DOCTOR_CMD:-}" ] && ! command -v claude >/dev/null 2>&1; then
  say "SKIP: claude not on PATH — upstream drift cannot be checked here."
  exit 0
fi

TMP=$(mktemp -d)
# Deliberately NO EXIT trap: an EXIT trap also fires when a *subshell* exits, and
# the doctor probes below run inside $( ), so it would delete the temp directory
# out from under the rest of the run. bash 3.2 (macOS) has no BASHPID to guard on,
# so clean up explicitly through finish() instead.
trap 'rm -rf "$TMP"; exit 130' INT TERM
finish(){ rm -rf "$TMP"; exit "$1"; }

strip_ansi(){ sed $'s/\033\\[[0-9;]*m//g'; }

# `claude doctor` validates the settings file in its *current directory*
# (the global --settings flag does not retarget it), so each probe needs its own
# directory. The caller owns the directory so it can grep for that exact path.
doctor_run(){
  local dir=$1 json=$2
  mkdir -p "$dir/.claude"
  printf '%s' "$json" > "$dir/.claude/settings.json"
  ( cd "$dir" && eval "$DOCTOR_CMD" 2>&1 ) | strip_ansi
}

# Upstream prints the full list of valid hook events only inside the warning for
# an *unknown* event — so ask an impossible question to get the answer.
live_events(){
  local d="$TMP/ev"
  doctor_run "$d" "{\"hooks\":{\"$SENTINEL_EVENT\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"true\"}]}]}}" \
    | grep -o 'Valid events:.*' | head -1 | sed 's/^Valid events: *//' \
    | tr ',' '\n' | sed 's/^ *//; s/ *$//; s/\.$//' | grep -v '^$' | sort -u
}

# Same trick for permission modes.
live_modes(){
  local d="$TMP/md"
  doctor_run "$d" "{\"permissions\":{\"defaultMode\":\"$SENTINEL_MODE\"}}" \
    | grep -o 'Expected one of:.*' | head -1 \
    | grep -o '"[a-zA-Z]*"' | tr -d '"' | sort -u
}

say "Claude Code upstream drift check"
say ""

if command -v claude >/dev/null 2>&1; then
  VERSION=$(claude --version 2>/dev/null || echo unknown)
else
  VERSION="(stubbed)"
fi
PINNED=$(jq -r '.last_verified_version // "unknown"' "$CONTRACT")
say "CLI now:       $VERSION"
say "Last verified: $PINNED"
say ""

# ---- 1. the shipped settings.json still validates ----------------------
say "1. shipped settings.json validates against this CLI"
PROBE1="$TMP/live"
CLEAN_OUT=$(doctor_run "$PROBE1" "$(cat "$SETTINGS")")
# Only complaints about *our* copy matter; the user's own settings may be dirty.
OURS=$(printf '%s\n' "$CLEAN_OUT" | grep -F "$PROBE1" || true)
if [ -n "$OURS" ]; then
  fail "the CLI rejects part of settings.json:"
  printf '%s\n' "$OURS" | sed 's/^/      /'
else
  ok "no complaints"
fi
say ""

# ---- 2. every hook event the harness registers still exists ------------
say "2. hook events the harness registers still exist upstream"
LIVE=$(live_events)
USED=$(jq -r '.hooks | keys[]' "$SETTINGS" | sort -u)
if [ -z "$LIVE" ]; then
  fail "could not read the valid-event list from doctor (output format changed?)"
else
  ok "upstream reports $(printf '%s\n' "$LIVE" | wc -l | tr -d ' ') valid events"
  while IFS= read -r ev; do
    [ -z "$ev" ] && continue
    if printf '%s\n' "$LIVE" | grep -qxF "$ev"; then
      ok "$ev"
    else
      fail "$ev is registered in settings.json but is NOT a valid event any more"
    fi
  done <<EOF
$USED
EOF
fi
say ""

# ---- 3. the permission mode we ship is still accepted ------------------
say "3. shipped permissions.defaultMode is still valid"
WANT_MODE=$(jq -r '.permissions.defaultMode // empty' "$SETTINGS")
MODES=$(live_modes)
MODES_ONELINE=$(printf '%s\n' "$MODES" | tr '\n' ' ')
if [ -z "$MODES" ]; then
  warn "could not read the valid-mode list from doctor"
elif [ -z "$WANT_MODE" ]; then
  warn "settings.json sets no defaultMode"
elif printf '%s\n' "$MODES" | grep -qxF "$WANT_MODE"; then
  ok "\"$WANT_MODE\" accepted (upstream offers: $MODES_ONELINE)"
else
  fail "\"$WANT_MODE\" is no longer a valid defaultMode (upstream offers: $MODES_ONELINE)"
fi
say ""

# ---- 4. did upstream grow capabilities we have not looked at? ----------
say "4. upstream capabilities not yet acknowledged in upstream-contract.json"
if [ -n "$LIVE" ]; then
  KNOWN=$(jq -r '.acknowledged_hook_events[]' "$CONTRACT" | sort -u)
  NEW=$(comm -23 <(printf '%s\n' "$LIVE") <(printf '%s\n' "$KNOWN") || true)
  GONE=$(comm -13 <(printf '%s\n' "$LIVE") <(printf '%s\n' "$KNOWN") || true)
  if [ -n "$NEW" ]; then
    warn "new hook events exist upstream — adopt them, or record them as considered:"
    printf '%s\n' "$NEW" | sed 's/^/      + /'
  else
    ok "no unacknowledged events"
  fi
  if [ -n "$GONE" ]; then
    warn "events in the contract are no longer offered upstream (contract is stale):"
    printf '%s\n' "$GONE" | sed 's/^/      - /'
  fi
fi
say ""

# ---- 4b. do the settings keys the harness sets still exist? ------------
# `claude doctor` validates hook events and enumerated values, but it does NOT
# flag unknown top-level keys — a renamed setting silently becomes a no-op with
# no warning anywhere. There is no oracle for this, so fall back to asking
# whether the CLI still mentions the key at all. Advisory only: a bundled build
# could legitimately mangle a string, so this must never be a hard failure.
say "4b. settings keys the harness sets are still known to the CLI"
CLI_BIN=""
if [ -n "${CLAUDE_CLI_BIN:-}" ]; then
  CLI_BIN=$CLAUDE_CLI_BIN            # testing seam, mirrors CLAUDE_DOCTOR_CMD
elif command -v claude >/dev/null 2>&1; then
  CLI_BIN=$(command -v claude)
  # Follow one level of symlink (the native installer points ~/.local/bin at a
  # versioned binary); readlink -f is GNU-only, so keep it simple.
  if [ -L "$CLI_BIN" ]; then
    CLI_TARGET=$(readlink "$CLI_BIN")
    case "$CLI_TARGET" in
      /*) CLI_BIN="$CLI_TARGET" ;;
      *)  CLI_BIN="$(dirname "$CLI_BIN")/$CLI_TARGET" ;;
    esac
  fi
fi
if [ -z "$CLI_BIN" ] || [ ! -e "$CLI_BIN" ]; then
  say "      (skipped — cannot locate the CLI files)"
elif [ -d "$CLI_BIN" ]; then
  say "      (skipped — CLI path is a directory)"
else
  KEY_MISSING=""
  for key in $(jq -r 'keys[] | select(. != "hooks" and . != "permissions" and . != "env" and . != "sandbox" and . != "statusLine")' "$SETTINGS"); do
    if grep -qF "$key" "$CLI_BIN" 2>/dev/null; then
      ok "$key"
    else
      KEY_MISSING="$KEY_MISSING $key"
    fi
  done
  if [ -n "$KEY_MISSING" ]; then
    warn "the CLI no longer mentions these keys — renamed or removed?$KEY_MISSING"
    warn "verify by hand before trusting this: string matching in a bundled build is not authoritative."
  fi
fi
say ""

# ---- 5. informational: which live events the harness leaves unused -----
if [ -n "$LIVE" ]; then
  say "5. valid events the harness does not hook (informational)"
  UNUSED=$(comm -23 <(printf '%s\n' "$LIVE") <(printf '%s\n' "$USED") || true)
  if [ -n "$UNUSED" ]; then
    printf '%s\n' "$UNUSED" | tr '\n' ' ' | fold -s -w 74 | sed 's/^/      /'
  else
    say "      (none — the harness hooks everything)"
  fi
  say ""
fi

if [ "$VERSION" != "$PINNED" ] && [ "$VERSION" != "(stubbed)" ]; then
  say "NOTE: the CLI moved since last verification ($PINNED → $VERSION)."
  say "      After reviewing, bump last_verified_version in upstream-contract.json."
  say ""
fi

if [ "$BREAKAGE" -eq 1 ]; then
  say "RESULT: BREAKAGE — the harness relies on something upstream changed."
  finish 1
elif [ "$ADVISORY" -eq 1 ]; then
  say "RESULT: upstream grew. Review, then acknowledge in upstream-contract.json."
  finish 2
fi
say "RESULT: contract holds."
finish 0
