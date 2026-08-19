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
mkdir -p ~/.claude/hooks ~/.claude/logs ~/.claude/transcripts ~/.claude/state/sessions ~/.claude/state/plans ~/.claude/state/workflows ~/.claude/plans-html ~/.claude/skills
echo "  ✓ directories"

# ---- Hooks + lib ------------------------------------------------------
HOOKS=(
  lib.sh
  env-guard.sh
  sensitive-file-guard.sh
  git-guard.sh
  interpreter-guard.sh
  kubectl-guard.sh
  network-guard.sh
  secret-scanner.sh
  audit.sh
  notify.sh
  session-start.sh
  session-snapshot.sh
  pre-compact.sh
  plan-to-html.sh
  workflow-record.sh
)
for f in "${HOOKS[@]}"; do
  cp "$REPO/hooks/$f" ~/.claude/hooks/"$f"
  chmod +x ~/.claude/hooks/"$f"
  echo "  ✓ hooks/$f"
done

# ---- Statusline -------------------------------------------------------
cp "$REPO/bin/statusline.sh" ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
echo "  ✓ statusline.sh"

# ---- Memory tools -----------------------------------------------------
# Not a hook: checking memories against GitHub costs a network call, which has
# no business running on every session start. Invoked on demand instead.
cp "$REPO/bin/memory-verify.sh" ~/.claude/memory-verify.sh
chmod +x ~/.claude/memory-verify.sh
echo "  ✓ memory-verify.sh"

for skill in "$REPO"/skills/*/; do
  [[ -d "$skill" ]] || continue
  name=$(basename "$skill")
  mkdir -p ~/.claude/skills/"$name"
  cp "$skill"SKILL.md ~/.claude/skills/"$name"/SKILL.md
  echo "  ✓ skills/$name"
done

# ---- Settings (merge-safe) -------------------------------------------
TARGET=~/.claude/settings.json
SOURCE="$REPO/config/settings.json"

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

  # The harness fully owns the hooks block (below). Warn loudly if the user had
  # their own hooks so they aren't silently dropped — they're preserved in the
  # timestamped backup and can be merged back by hand.
  if jq -e '(.hooks // {}) | length > 0' "$TARGET" >/dev/null 2>&1; then
    echo "  ⚠ existing 'hooks' block found — the harness replaces it. Your previous"
    echo "     hooks are preserved in: $BACKUP  (merge any custom ones back manually)."
  fi

  # permissions.defaultMode is harness-owned (see below), so an existing value
  # gets replaced rather than winning the merge. Say so before it happens.
  OLD_MODE=$(jq -r '.permissions.defaultMode // empty' "$TARGET" 2>/dev/null)
  NEW_MODE=$(jq -r '.permissions.defaultMode // empty' "$SOURCE" 2>/dev/null)
  if [[ -n "$OLD_MODE" && "$OLD_MODE" != "$NEW_MODE" ]]; then
    echo "  ⚠ permissions.defaultMode: \"$OLD_MODE\" → \"$NEW_MODE\" (harness-owned)."
    echo "     Keep your own with: jq '.permissions.defaultMode=\"$OLD_MODE\"' ~/.claude/settings.json"
  fi

  if [[ ! -f "$REPO/config/merge-settings.jq" ]]; then
    echo "  ✗ config/merge-settings.jq missing from $REPO — settings.json left untouched."
    echo "     Re-clone the repo, or copy settings.json into place by hand."
    exit 1
  fi

  TMP=$(mktemp)
  if ! jq -s -f "$REPO/config/merge-settings.jq" "$TARGET" "$SOURCE" > "$TMP"; then
    rm -f "$TMP"
    echo "  ✗ settings.json merge failed — left untouched (backup: $BACKUP)"
    exit 1
  fi
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
