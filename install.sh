#!/usr/bin/env bash
# Installs the Claude Code harness to ~/.claude
# Run once per machine: bash install.sh
#
# Safe to re-run: existing settings.json is backed up; custom keys are
# preserved when the user has jq installed and a mergeable file.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Claude Code harness..."

# ---- Directories ------------------------------------------------------
mkdir -p ~/.claude/hooks ~/.claude/logs ~/.claude/transcripts ~/.claude/state/sessions ~/.claude/plans-html
echo "  ✓ directories"

# ---- Hooks + lib ------------------------------------------------------
HOOKS=(
  lib.sh
  env-guard.sh
  sensitive-file-guard.sh
  git-guard.sh
  interpreter-guard.sh
  network-guard.sh
  secret-scanner.sh
  audit.sh
  notify.sh
  session-start.sh
  session-snapshot.sh
  pre-compact.sh
  plan-to-html.sh
)
for f in "${HOOKS[@]}"; do
  cp "$REPO/hooks/$f" ~/.claude/hooks/"$f"
  chmod +x ~/.claude/hooks/"$f"
  echo "  ✓ hooks/$f"
done

# ---- Statusline -------------------------------------------------------
cp "$REPO/statusline.sh" ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
echo "  ✓ statusline.sh"

# ---- Settings (merge-safe) -------------------------------------------
TARGET=~/.claude/settings.json
SOURCE="$REPO/settings.json"

if [[ ! -f "$TARGET" ]]; then
  cp "$SOURCE" "$TARGET"
  echo "  ✓ settings.json (installed fresh)"
elif ! command -v jq &>/dev/null; then
  cp "$TARGET" "$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SOURCE" "$TARGET"
  echo "  ⚠ settings.json (jq not found — overwrote; backup saved with timestamp)"
else
  # Merge: harness owns hooks + deny + the status line; existing user keys
  # (env, custom allow entries, unrelated top-level keys) are preserved.
  # Allow entries are unioned so projects / users can extend.
  BACKUP="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TARGET" "$BACKUP"
  TMP=$(mktemp)
  jq -s '
    .[0] as $old | .[1] as $new |
    $new
    * $old                                                      # user wins for overlapping top-level keys
    | .permissions.allow = (($old.permissions.allow // []) + ($new.permissions.allow // []) | unique)
    | .permissions.deny  = (($old.permissions.deny  // []) + ($new.permissions.deny  // []) | unique)
    | .hooks             = $new.hooks                           # harness fully owns hooks
    | .statusLine        = $new.statusLine                      # harness owns statusline
  ' "$TARGET" "$SOURCE" > "$TMP"
  mv "$TMP" "$TARGET"
  echo "  ✓ settings.json (merged; backup: $BACKUP)"
fi

# ---- Sanity checks ----------------------------------------------------
echo ""
if command -v jq &>/dev/null; then
  echo "  ✓ jq installed"
else
  echo "  ✗ jq not installed — hooks require jq. Run: brew install jq"
fi

if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  echo "  ✓ gh CLI authenticated"
else
  echo "  ✗ gh CLI not set up — run: gh auth login"
fi

# ---- Self-test --------------------------------------------------------
if [[ -x "$REPO/doctor.sh" ]]; then
  echo ""
  echo "Running doctor.sh to verify hooks..."
  if bash "$REPO/doctor.sh" > /tmp/cch-doctor.log 2>&1; then
    summary=$(grep '^SUMMARY:' /tmp/cch-doctor.log || echo "(no summary)")
    echo "  ✓ $summary"
  else
    echo "  ✗ doctor.sh reported failures. See /tmp/cch-doctor.log"
  fi
fi

echo ""
echo "Done. Open Claude Code and run /hooks to verify."
echo "Audit log:   ~/.claude/logs/audit.log"
echo "Transcripts: ~/.claude/transcripts/"
