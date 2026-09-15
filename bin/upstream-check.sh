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

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$REPO/config/settings.json"
CONTRACT="$REPO/config/upstream-contract.json"
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

# When doctor is stubbed we are under test: don't spawn the real CLI just to read
# a version string. It is a ~150MB binary and the suite invokes this script
# repeatedly, which turned a 1s suite into a 24s one.
if [ -n "${CLAUDE_DOCTOR_CMD:-}" ]; then
  VERSION="(stubbed)"
elif command -v claude >/dev/null 2>&1; then
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

# ---- 4c. does the acknowledged non-hook surface still exist? -----------
# Section 4 can catch an unacknowledged hook EVENT because `claude doctor`
# enumerates them. Nothing enumerates tools or settings keys, so cross-session
# messaging — two tools and two settings keys — shipped in 2.1.224 while this
# check reported "contract holds". This section closes the verification half of
# that gap: every capability a human wrote into acknowledged_surface is
# confirmed to still exist, so a rename cannot silently strand a recorded
# decision. It does NOT close the discovery half, and says so, because a green
# section that implies coverage it does not have is worse than no section.
say "4c. acknowledged tools and settings keys still exist upstream"
if [ ! -e "${CLI_BIN:-}" ] || [ -d "${CLI_BIN:-/}" ]; then
  say "      (skipped — cannot locate the CLI files)"
else
  SURFACE=$(jq -r '(.acknowledged_surface // {})
                   | (((.tools // {}) | keys[]?), ((.settings_keys // {}) | keys[]?))' \
            "$CONTRACT" 2>/dev/null | grep -v '^_comment$' || true)
  if [ -z "$SURFACE" ]; then
    warn "acknowledged_surface is empty — nothing outside hook events is being tracked."
  else
    SURFACE_N=0; SURFACE_GONE=""
    for cap in $SURFACE; do
      SURFACE_N=$((SURFACE_N+1))
      grep -qF "$cap" "$CLI_BIN" 2>/dev/null || SURFACE_GONE="$SURFACE_GONE $cap"
    done
    if [ -n "$SURFACE_GONE" ]; then
      warn "acknowledged but no longer present in the CLI — renamed or removed?$SURFACE_GONE"
      warn "the recorded decision for each is now stranded; re-read it before trusting it."
    else
      ok "all $SURFACE_N acknowledged capabilities still present"
    fi
    # Print the denominator. A count a human can compare against the docs is the
    # difference between "we checked everything" and "we checked these N".
    say "      verified $SURFACE_N acknowledged capabilit$([ "$SURFACE_N" = 1 ] && echo y || echo ies); this section CANNOT"
    say "      discover an unacknowledged one — nothing enumerates tools or settings keys."
  fi
fi
say ""

# ---- 4d. are the memory index limits still what we enforce? ------------
# memory-lint and memory-verify both gate on 200 lines / 25,000 bytes, and for a
# while those numbers were folklore: this repo's own research doc said the line
# cap was "unsubstantiated" while two tools enforced it as fact. Both readings
# were unverified, and a wrong threshold here fails silently in the worst
# direction -- the index quietly stops loading its tail and nothing reports it.
#
# So read them out of the CLI instead of asserting them. Upstream destructures
# {trimmed, lineCount, byteCount} and compares each against a constant; this
# extracts the two identifiers from that expression and then resolves their
# values, so a minifier rename moves the check with the code rather than
# stranding it.
say "4d. memory index limits match the CLI"
if [ ! -e "${CLI_BIN:-}" ] || [ -d "${CLI_BIN:-/}" ]; then
  say "      (skipped — cannot locate the CLI files)"
else
  WANT_LINES=$(jq -r '.memory_index_limits.lines // empty' "$CONTRACT" 2>/dev/null)
  WANT_BYTES=$(jq -r '.memory_index_limits.bytes // empty' "$CONTRACT" 2>/dev/null)
  FRAG=$(grep -aoE 'lineCount:[A-Za-z_$][A-Za-z0-9_$]*,byteCount:[A-Za-z_$][A-Za-z0-9_$]*\}=[^;]{0,120};' \
         "$CLI_BIN" 2>/dev/null | head -1)
  if [ -z "$FRAG" ]; then
    # Not a pass. The limits may be unchanged, but this run did not check them.
    warn "could not locate the index-truncation expression in the CLI — the 200/25000"
    warn "thresholds this harness enforces went UNVERIFIED on this run, not confirmed."
  else
    LV=$(printf '%s' "$FRAG" | sed -n 's/.*lineCount:\([A-Za-z_$][A-Za-z0-9_$]*\),.*/\1/p')
    BV=$(printf '%s' "$FRAG" | sed -n 's/.*byteCount:\([A-Za-z_$][A-Za-z0-9_$]*\)}.*/\1/p')
    LLIM=$(printf '%s' "$FRAG" | sed -n "s/.*=${LV}>\([A-Za-z_\$][A-Za-z0-9_\$]*\).*/\1/p")
    BLIM=$(printf '%s' "$FRAG" | sed -n "s/.*=${BV}>\([A-Za-z_\$][A-Za-z0-9_\$]*\).*/\1/p")
    # Resolve a minified constant to its value. Two hazards, and on 2.1.272 they
    # combined to produce a WRONG answer rather than no answer:
    #
    #   1. the leading character class can match a NUL byte, so stage 1 emits
    #      ",t6=25000\n\0t6=3\n". Every stage of the pipe therefore needs -a;
    #      without it stage 2 calls its own stdin binary and prints the literal
    #      "Binary file (standard input) matches" INSTEAD of the number.
    #   2. that string is NON-EMPTY, so the -z guard below waved it through to
    #      the value comparison, which then warned that memory-lint was gating
    #      on the wrong byte limit -- crying wolf about the number it was in
    #      fact confirming. An emptiness guard cannot catch a failure that
    #      returns a value.
    #
    # So validate the SHAPE here rather than trusting the pipe: anything that is
    # not all digits comes back empty, and the caller reports UNVERIFIED. Every
    # extraction added here must keep that property -- report nothing, never a
    # value you did not prove is a value.
    const_value() {
      _v=$(grep -aoE "(^|[^A-Za-z0-9_\$])$1=[0-9]+" "$CLI_BIN" 2>/dev/null \
           | grep -aoE '[0-9]+$' | head -1)
      case "$_v" in
        ''|*[!0-9]*) printf '' ;;
        *)           printf '%s' "$_v" ;;
      esac
    }
    GOT_LINES=$(const_value "$LLIM")
    GOT_BYTES=$(const_value "$BLIM")
    if [ -z "$GOT_LINES" ] || [ -z "$GOT_BYTES" ]; then
      warn "found the truncation expression but not both constants (lines='${GOT_LINES:-?}' bytes='${GOT_BYTES:-?}')"
      warn "the thresholds went UNVERIFIED on this run."
    else
      [ "$GOT_LINES" = "$WANT_LINES" ] \
        && ok "index line limit $GOT_LINES matches the contract" \
        || warn "index LINE limit is $GOT_LINES upstream, contract says ${WANT_LINES:-unset} — memory-lint and memory-verify are gating on the wrong number."
      [ "$GOT_BYTES" = "$WANT_BYTES" ] \
        && ok "index byte limit $GOT_BYTES matches the contract" \
        || warn "index BYTE limit is $GOT_BYTES upstream, contract says ${WANT_BYTES:-unset} — memory-lint and memory-verify are gating on the wrong number."
      # The unit, not just the number. "byteCount" is why this harness reports
      # bytes; if upstream ever switched to a character count, every threshold
      # here would be measuring the wrong thing while still matching on value.
      say "      upstream compares byteCount (bytes, not characters) and truncates lines first."
    fi
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
