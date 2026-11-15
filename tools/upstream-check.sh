#!/usr/bin/env bash
# Detects when Claude Code has changed something this harness relies on.
#
# The harness hard-codes upstream facts: which hook events exist, which
# permission modes are valid, what the CLI accepts in settings.json, how large a
# memory index it loads. Claude Code auto-updates and those facts move. A
# push-triggered CI run can never catch it, because upstream changes when this
# repo does not, so this runs on a schedule (.github/workflows/upstream-drift.yml).
# Breakage only: it does not assess what a release added.
#
# Auth-free by design: `claude doctor` and `claude --version` need no login, so
# CI runs them without credentials.
#
# Usage:  bash upstream-check.sh
# Exit:   0 nothing relied on has moved · 1 BREAKAGE · 2 could not confirm
#         something (a settings key the CLI no longer mentions, memory limits
#         unreadable) · 3 could not run the checks
#
# Testing seam: CLAUDE_DOCTOR_CMD overrides how doctor is invoked so
# tests/upstream-check.test.sh can feed canned output with no CLI installed.
#
# Portability: no mapfile/associative arrays — macOS ships bash 3.2.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS=${CLAUDE_UPSTREAM_SETTINGS:-$REPO/config/settings.json}  # test seam
CONTRACT=${CLAUDE_UPSTREAM_CONTRACT:-$REPO/config/upstream-contract.json}  # test seam
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
TMP=$(cd "$TMP" && pwd)   # macOS TMPDIR ends in /; the CLI prints the path without the //
# Deliberately NO EXIT trap: an EXIT trap also fires when a *subshell* exits, and
# the doctor probes below run inside $( ), so it would delete the temp directory
# out from under the rest of the run. bash 3.2 (macOS) has no BASHPID to guard on,
# so clean up explicitly through finish() instead.
trap 'rm -rf "$TMP"; exit 130' INT TERM
finish(){ rm -rf "$TMP"; exit "$1"; }

strip_ansi(){ sed $'s/\033\\[[0-9;]*m//g'; }

# Each probe writes settings.json into a directory nobody has trusted, and since
# 2.1.311 the CLI ignores permissions.allow there and says so ("this workspace has
# not been trusted"), which section 1 read as a rejection. This harness ships
# settings.json at user scope, which the trust gate does not apply to. So every
# probe runs with a Claude config dir of its own, under $TMP, that trusts the probe
# directory. Trusting it in the user's ~/.claude.json instead (#142) raced the
# sessions that write that file, and, set from inside $( ), was never undone.
# The CLI keys trust by the physical path: on macOS $TMP is /var/..., which it
# reads as /private/var/..., so the logical path alone left the warning.
PROBE_CONFIG="$TMP/config"
mkdir -p "$PROBE_CONFIG"
printf '{}\n' > "$PROBE_CONFIG/.claude.json"
trust_dir(){
  local cfg="$PROBE_CONFIG/.claude.json" real
  real=$(cd "$1" && pwd -P) || return
  jq --arg d "$real" '.projects[$d].hasTrustDialogAccepted = true' "$cfg" > "$cfg.next" && mv "$cfg.next" "$cfg"
}

# `claude doctor` validates the settings file in its *current directory*
# (the global --settings flag does not retarget it), so each probe needs its own
# directory. The caller owns the directory so it can grep for that exact path.
doctor_run(){
  local dir=$1 json=$2
  mkdir -p "$dir/.claude"
  printf '%s' "$json" > "$dir/.claude/settings.json"
  trust_dir "$dir"
  ( cd "$dir" && export CLAUDE_CONFIG_DIR="$PROBE_CONFIG" && eval "$DOCTOR_CMD" 2>&1 ) | strip_ansi
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

say "Claude Code breakage check"
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
say "CLI now:       $VERSION"
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
say "3. shipped permissions.defaultMode is the expected one and still valid"
WANT_MODE=$(jq -r '.permissions.defaultMode // empty' "$SETTINGS")
EXPECT_MODE=$(jq -r '.expected_default_mode // empty' "$CONTRACT")
MODES=$(live_modes)
MODES_ONELINE=$(printf '%s\n' "$MODES" | tr '\n' ' ')
if [ -z "$MODES" ]; then
  warn "could not read the valid-mode list from doctor"
elif [ -z "$WANT_MODE" ]; then
  warn "settings.json sets no defaultMode"
elif [ "$WANT_MODE" != "$EXPECT_MODE" ]; then
  fail "settings.json sets defaultMode \"$WANT_MODE\" but upstream-contract.json expects \"${EXPECT_MODE:-unset}\""
elif printf '%s\n' "$MODES" | grep -qxF "$WANT_MODE"; then
  ok "\"$WANT_MODE\" accepted (upstream offers: $MODES_ONELINE)"
else
  fail "\"$WANT_MODE\" is no longer a valid defaultMode (upstream offers: $MODES_ONELINE)"
fi
say ""

# ---- 4. do the settings keys the harness sets still exist? ------------
# `claude doctor` validates hook events and enumerated values, but it does NOT
# flag unknown top-level keys — a renamed setting silently becomes a no-op with
# no warning anywhere. There is no oracle for this, so fall back to asking
# whether the CLI still mentions the key at all. Advisory only: a bundled build
# could legitimately mangle a string, so this must never be a hard failure.
say "4. settings keys the harness sets are still known to the CLI"
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

# ---- 5. are the memory index limits still what we enforce? ------------
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
say "5. memory index limits match the CLI"
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
    # A minified name can hold `$` (P$ in the Linux 2.1.283 build). Bare in a
    # regex it is an end-of-line anchor and the name never matches.
    re_name() { printf '%s' "$1" | sed 's/[$]/[$]/g'; }
    LLIM=$(printf '%s' "$FRAG" | sed -n "s/.*=$(re_name "$LV")>\([A-Za-z_\$][A-Za-z0-9_\$]*\).*/\1/p")
    BLIM=$(printf '%s' "$FRAG" | sed -n "s/.*=$(re_name "$BV")>\([A-Za-z_\$][A-Za-z0-9_\$]*\).*/\1/p")
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
    #
    # Minified names are also reused across scopes: the 2.1.282 native binary
    # binds the line-limit name to 3600000 before its real `=200`. So prefer the
    # declaration that binds both names together, and when a name alone has
    # more than one value, report nothing.
    const_value() {
      _v=$(grep -aoE "(^|[^A-Za-z0-9_\$])$(re_name "$1")=[0-9]+" "$CLI_BIN" 2>/dev/null \
           | grep -aoE '[0-9]+$' | sort -u)
      case "$_v" in
        ''|*[!0-9]*) printf '' ;;
        *)           printf '%s' "$_v" ;;
      esac
    }
    PAIR=$(grep -aoE "(^|[^A-Za-z0-9_\$])$(re_name "$LLIM")=[0-9]+,$(re_name "$BLIM")=[0-9]+" "$CLI_BIN" 2>/dev/null \
           | grep -aoE '[0-9]+,[^,]*=[0-9]+$' | sort -u)
    case "$PAIR" in
      *$'\n'*) GOT_LINES=""; GOT_BYTES="" ;;
      [0-9]*,*=[0-9]*) GOT_LINES=${PAIR%%,*}; GOT_BYTES=${PAIR##*=}
                       case "$GOT_LINES$GOT_BYTES" in *[!0-9]*) GOT_LINES=""; GOT_BYTES="" ;; esac ;;
      *) GOT_LINES=$(const_value "$LLIM"); GOT_BYTES=$(const_value "$BLIM") ;;
    esac
    if [ -z "$GOT_LINES" ] || [ -z "$GOT_BYTES" ]; then
      warn "found the truncation expression but not both constants (lines='${GOT_LINES:-?}' bytes='${GOT_BYTES:-?}')"
      warn "the thresholds went UNVERIFIED on this run."
    else
      [ "$GOT_LINES" = "$WANT_LINES" ] \
        && ok "index line limit $GOT_LINES matches the contract" \
        || fail "index LINE limit is $GOT_LINES upstream, contract says ${WANT_LINES:-unset} — memory-lint and memory-verify are gating on the wrong number."
      [ "$GOT_BYTES" = "$WANT_BYTES" ] \
        && ok "index byte limit $GOT_BYTES matches the contract" \
        || fail "index BYTE limit is $GOT_BYTES upstream, contract says ${WANT_BYTES:-unset} — memory-lint and memory-verify are gating on the wrong number."
      # The unit, not just the number. "byteCount" is why this harness reports
      # bytes; if upstream ever switched to a character count, every threshold
      # here would be measuring the wrong thing while still matching on value.
      say "      upstream compares byteCount (bytes, not characters) and truncates lines first."
    fi
  fi
fi
say ""

# ---- 6. the mods the harness ships still pass their own tests ---------
# The mod API is early access, the surface a release is most likely to move, and
# a moved API shows only as a blank or erroring pane: nothing else reports it.
# `claude plugin test` runs a mod's *.test.tsx on this CLI's engine with no login
# (0.27 s for the comms panel on 2.1.312, empty config dir). Seam:
# CLAUDE_PLUGIN_TEST_CMD; under a stubbed doctor without it, the CLI is not spawned.
say "6. mods the harness ships pass their tests on this CLI"
MODS=$(cd "$REPO" && find skills -path '*/.claude-plugin/plugin.json' 2>/dev/null \
       | sed 's|/\.claude-plugin/plugin\.json$||' | sort)
if [ -n "${CLAUDE_PLUGIN_TEST_CMD:-}" ]; then
  PLUGIN_TEST_CMD=$CLAUDE_PLUGIN_TEST_CMD
elif [ -n "${CLAUDE_DOCTOR_CMD:-}" ]; then
  PLUGIN_TEST_CMD=""
else
  PLUGIN_TEST_CMD="claude plugin test"
fi
if [ -z "$MODS" ]; then
  say "      (no mods shipped)"
elif [ -z "$PLUGIN_TEST_CMD" ]; then
  say "      (skipped: doctor is stubbed and CLAUDE_PLUGIN_TEST_CMD is not set)"
else
  for m in $MODS; do
    if MOD_OUT=$(cd "$REPO" && export CLAUDE_CONFIG_DIR="$PROBE_CONFIG" && eval "$PLUGIN_TEST_CMD \"\$m\"" 2>&1); then
      ok "$m"
    else
      fail "$m fails claude plugin test; the mod API it uses may have moved:"
      printf '%s\n' "$MOD_OUT" | strip_ansi | grep -v '^ *$' | tail -15 | sed 's/^/      /'
    fi
  done
fi
say ""

# ---- 7. the tools the guards attach to still exist ---------------------
# A hook matcher names a tool. If upstream renames the tool, the matcher matches
# nothing and the guard is silently off. Substring match against the CLI file, as
# for section 4; the regex matcher mcp__.* and the empty matcher are skipped.
say "7. tool names in settings.json hook matchers still exist in the CLI"
if [ ! -e "${CLI_BIN:-}" ] || [ -d "${CLI_BIN:-/}" ]; then
  say "      (skipped — cannot locate the CLI files)"
else
  TOOLS=$(jq -r '[.hooks[][]?.matcher // empty | split("|")[] | select(test("^[A-Za-z]+$"))] | unique[]' "$SETTINGS")
  TOOLS_N=0
  for t in $TOOLS; do
    TOOLS_N=$((TOOLS_N+1))
    if grep -qF "$t" "$CLI_BIN" 2>/dev/null; then ok "$t"
    else fail "$t is named in a hook matcher but the CLI no longer mentions it; the guard on it is off"; fi
  done
  [ "$TOOLS_N" -gt 0 ] || fail "found no tool names in the hook matchers (settings.json layout changed?)"
fi
say ""

if [ "$BREAKAGE" -eq 1 ]; then
  say "RESULT: BREAKAGE — the harness relies on something upstream changed."
  finish 1
elif [ "$ADVISORY" -eq 1 ]; then
  say "RESULT: could not confirm everything the harness relies on. Verify by hand."
  finish 2
fi
say "RESULT: nothing the harness relies on has moved."
finish 0
