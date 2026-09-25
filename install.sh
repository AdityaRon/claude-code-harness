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
# Glob the directory rather than listing names. The list held 15 entries and so
# does hooks/ once lib.sh is counted — but they were different fifteens: the
# array carried lib.sh, which settings.json never references, and omitted
# memory-lint.sh, which settings.json registers as a PostToolUse hook. So a hook
# this repo ships and wires up was never installed, the copy in ~/.claude sat two
# weeks stale, and re-running install.sh fixed nothing. The matching counts are
# why it survived review: a count check passes on two lists that disagree.
#
# The same failure had already happened once here with the memory tools — see the
# note below. Naming files by hand is the shape of the bug, so the shape is gone.
# tests/install-merge.test.sh now asserts the invariant that actually matters:
# every hook settings.json names exists in hooks/, and so gets installed.
for f in "$REPO"/hooks/*.sh; do
  b=$(basename "$f")
  cp "$f" ~/.claude/hooks/"$b"
  chmod +x ~/.claude/hooks/"$b"
  echo "  ✓ hooks/$b"
done

# ---- Statusline -------------------------------------------------------
cp "$REPO/bin/statusline.sh" ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
echo "  ✓ statusline.sh"

# ---- Memory tools -----------------------------------------------------
# Not a hook: checking memories against GitHub costs a network call, which has
# no business running on every session start. Invoked on demand instead.
# All three, together: memory-audit invokes them as a set, and installing only
# some of them is what left the skill resolving one script from ~/.claude and
# another from a hardcoded checkout path — so the ~/.claude copy went stale by a
# day without anything noticing.
for t in memory-verify memory-fix memory-index memory-provenance; do
  cp "$REPO/bin/$t.sh" ~/.claude/"$t.sh"
  chmod +x ~/.claude/"$t.sh"
  echo "  ✓ $t.sh"
done

# ---- Session routing --------------------------------------------------
# Also not a hook, and for the same reason as the memory tools: it answers a
# question you ask at a decision point ("which session owns this PR?"), not one
# worth answering on every session start. Reads only local transcripts and job
# records, so no network call and nothing to configure.
cp "$REPO/bin/session-route.sh" ~/.claude/session-route.sh
chmod +x ~/.claude/session-route.sh
echo "  ✓ session-route.sh"

# ---- Contract pin -----------------------------------------------------
# session-start.sh compares this with `claude --version`, so a session says when
# the CLI has moved past the release the harness was checked against.
sed -n 's/.*"last_verified_version": *"\([^ "]*\).*/\1/p' "$REPO/config/upstream-contract.json" \
  > ~/.claude/harness-contract.version
echo "  ✓ harness-contract.version"

for skill in "$REPO"/skills/*/; do
  [[ -d "$skill" ]] || continue
  name=$(basename "$skill")
  mkdir -p ~/.claude/skills/"$name"
  cp "$skill"SKILL.md ~/.claude/skills/"$name"/SKILL.md
  echo "  ✓ skills/$name"
done

# ---- Personal rules --------------------------------------------------
# ~/.claude/rules/ is user scope: every file here loads in every session, in
# every project on this machine, and needs no per-project approval the way an
# external import into a project CLAUDE.md does.
#
# Copied by GLOB, never from an explicit list. The hooks block used to name its
# files and the list drifted out of sync with the directory, so a wired-up hook
# silently stopped shipping; there is no reason to repeat that here.
#
# ADDITIVE on purpose. A file already in ~/.claude/rules that this repo does not
# carry is left alone, because that is where machine-local rules live — the ones
# naming people, clusters or customers, which must never enter this repo, since
# it is PUBLIC. Those are named `local-*.md`, a prefix nothing here may ship (a
# test enforces it), so no upgrade can overwrite one.
mkdir -p ~/.claude/rules
for rule in "$REPO"/rules/*.md; do
  [[ -f "$rule" ]] || continue
  cp "$rule" ~/.claude/rules/"$(basename "$rule")"
  echo "  ✓ rules/$(basename "$rule")"
done

# ---- Settings (merge-safe) -------------------------------------------
TARGET=~/.claude/settings.json
SOURCE="$REPO/config/settings.json"

# Machine-local rules: ~/.claude/local-settings/*.json, the settings side of
# rules/local-*.md, for work tools a public repo cannot name. Only
# permissions.allow and .deny are read, so a fragment can add rules but never
# change the mode, hooks or anything else; the guards still run first.
LOCAL_SETTINGS=~/.claude/local-settings
if compgen -G "$LOCAL_SETTINGS/*.json" >/dev/null && command -v jq &>/dev/null; then
  COMBINED=$(mktemp)
  cp "$SOURCE" "$COMBINED"
  for frag in "$LOCAL_SETTINGS"/*.json; do
    if jq -e '(.permissions.allow // []) + (.permissions.deny // []) | all(type == "string")' "$frag" >/dev/null 2>&1 \
       && jq --slurpfile f "$frag" '.permissions.allow += ($f[0].permissions.allow // [])
                                   | .permissions.deny  += ($f[0].permissions.deny  // [])' \
            "$COMBINED" > "$COMBINED.next"; then
      mv "$COMBINED.next" "$COMBINED"
      echo "  ✓ local-settings/$(basename "$frag") ($(jq '(.permissions.allow // []) + (.permissions.deny // []) | length' "$frag") rules)"
    else
      rm -f "$COMBINED.next"
      echo "  ⚠ local-settings/$(basename "$frag") skipped: not JSON, or allow/deny not lists of strings."
    fi
  done
  SOURCE="$COMBINED"
fi

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

  # The harness owns the hook entries IT installed. Anything else in the block —
  # an iTerm2 status hook, say — is carried across by merge-settings.jq. Say how
  # many, so a machine that loses one has a number to notice it by. Ownership is
  # by file name, so a user's own script in ~/.claude/hooks is foreign too.
  OWNED=$(cd "$REPO/hooks" && printf '%s\n' *.sh | jq -R . | jq -sc .)
  FOREIGN=$(jq --arg home "$HOME" --argjson owned "$OWNED" '[(.hooks // {})[] | .[]? | (.hooks // [])[]?
                 | (.command // "") as $c
                 | select([("~/.claude/hooks/", $home + "/.claude/hooks/") as $p | select($c | startswith($p))
                           | $c | ltrimstr($p) | split(" ")[0] | . as $n | any($owned[]; . == $n)] | any | not)] | length' \
            "$TARGET" 2>/dev/null || echo 0)
  if [[ "${FOREIGN:-0}" -gt 0 ]]; then
    echo "  ℹ $FOREIGN hook entr$([[ "$FOREIGN" == 1 ]] && echo y || echo ies) not installed by the harness — preserved."
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
  if ! jq -s --arg home "$HOME" --argjson owned "$OWNED" -f "$REPO/config/merge-settings.jq" "$TARGET" "$SOURCE" > "$TMP"; then
    rm -f "$TMP"
    echo "  ✗ settings.json merge failed — left untouched (backup: $BACKUP)"
    exit 1
  fi
  mv "$TMP" "$TARGET"
  echo "  ✓ settings.json (merged; backup: $BACKUP)"
fi
[[ -n "${COMBINED:-}" ]] && rm -f "$COMBINED"

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
# CCH_SKIP_SELFTEST exists so a test can run this installer. doctor.sh runs every
# suite in tests/, and one of those suites installs into a temp HOME to prove the
# install preserves local-*.md — without the guard that suite would re-enter the
# installer through doctor and recurse until something gave way.
if [[ -z "${CCH_SKIP_SELFTEST:-}" && -x "$REPO/doctor.sh" ]]; then
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
