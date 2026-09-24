#!/usr/bin/env bash
# Tests for session-start.sh — resume-drift branch. Stages snapshots at
# $CLAUDE_STATE_DIR, feeds SessionStart payloads on stdin, and asserts the
# drift classifications surfaced in stdout.
set -u
HOOK="hooks/session-start.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_STATE_DIR="$TMP/state"
mkdir -p "$CLAUDE_STATE_DIR"
# The hook reorders the memory index for the store matching its launch
# directory. Without this the suite would resolve the REAL store for whatever
# directory it runs from and rewrite a live MEMORY.md — a test that edits the
# user's memory is worse than no test.
export CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
mkdir -p "$CLAUDE_MEMORY_PROJECTS_DIR"
# Keep the real pin and CLI out of every case but the ones below.
export CLAUDE_CONTRACT_PIN="$TMP/no-pin"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label" "missing needle: $needle"; fi
}
check_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label" "unexpected needle: $needle"; fi
}
check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }

write_snap() {
  local sid="$1" path="$2" hash="$3" exists="$4"
  jq -n --arg p "$path" --arg h "$hash" --argjson e "$exists" \
    '{session_id:"'"$sid"'", ended_at:"2026-04-17T00:00:00Z", cwd:"/tmp",
      git_head:"", git_dirty:[],
      edited_files:[{path:$p, sha256:$h, exists:$e}]}' \
    > "$CLAUDE_STATE_DIR/${sid}.json"
}

run_resume() {
  local sid="$1"
  local payload
  payload=$(jq -nc --arg sid "$sid" '{source:"resume", session_id:$sid, hook_event_name:"SessionStart"}')
  printf '%s' "$payload" | bash "$HOOK" 2>/dev/null
}

TARGET="$TMP/target.txt"
printf 'original content\n' > "$TARGET"
CURRENT_HASH=$(shasum -a 256 "$TARGET" | awk '{print $1}')
STALE_HASH="0000000000000000000000000000000000000000000000000000000000000000"

echo "=== Drifted content → 'Resume drift detected' + 'drifted:' line ==="
write_snap "sess-drift" "$TARGET" "$STALE_HASH" "true"
OUT=$(run_resume "sess-drift")
check_contains "drift heading"      "Resume drift detected" "$OUT"
check_contains "drifted file named" "drifted: $TARGET"      "$OUT"

echo ""
echo "=== Matching hash → 'Resume drift: none' ==="
write_snap "sess-clean" "$TARGET" "$CURRENT_HASH" "true"
OUT=$(run_resume "sess-clean")
check_contains "no-drift banner"  "Resume drift: none"     "$OUT"
check_not_contains "no heading"   "Resume drift detected"  "$OUT"

echo ""
echo "=== File deleted since last session → 'missing:' line ==="
rm "$TARGET"
write_snap "sess-missing" "$TARGET" "$CURRENT_HASH" "true"
OUT=$(run_resume "sess-missing")
check_contains "missing heading"      "Resume drift detected" "$OUT"
check_contains "missing file named"   "missing: $TARGET"      "$OUT"
printf 'original content\n' > "$TARGET"  # restore for later cases

echo ""
echo "=== No snapshot on disk → silent fallback ==="
OUT=$(run_resume "sess-nonexistent-id")
check_not_contains "no drift output" "Resume drift" "$OUT"
check_contains    "git context still printed" "## Git context" "$OUT"

echo ""
echo "=== Non-resume sources skip drift check ==="
write_snap "sess-clean2" "$TARGET" "$CURRENT_HASH" "true"
payload=$(jq -nc '{source:"startup", session_id:"sess-clean2", hook_event_name:"SessionStart"}')
OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
check_not_contains "startup skips drift"  "Resume drift" "$OUT"
payload=$(jq -nc '{source:"clear", session_id:"sess-clean2", hook_event_name:"SessionStart"}')
OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
check_not_contains "clear skips drift"    "Resume drift" "$OUT"

echo ""
echo "=== HEAD change surfaced ==="
# Use the real repo HEAD as CUR_HEAD; stage a snapshot with a different head.
REAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$REAL_HEAD" ]]; then
  SNAP="$CLAUDE_STATE_DIR/sess-head.json"
  FAKE_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  jq -n --arg p "$TARGET" --arg h "$CURRENT_HASH" --arg head "$FAKE_HEAD" \
    '{session_id:"sess-head", ended_at:"2026-04-17T00:00:00Z", cwd:"/tmp",
      git_head:$head, git_dirty:[],
      edited_files:[{path:$p, sha256:$h, exists:true}]}' > "$SNAP"
  OUT=$(run_resume "sess-head")
  check_contains "HEAD change heading" "Resume drift detected" "$OUT"
  check_contains "HEAD change line"    "HEAD changed: deadbeefdead" "$OUT"
else
  echo "  SKIP: HEAD-change test (not in a git repo)"
fi

echo ""
echo "=== memory index: out of tier order → reordered and announced ==="
# The store slug is the launch directory with separators turned to dashes.
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/$(printf '%s' "$PWD" | tr '/' '-')/memory"
mkdir -p "$STORE"
mkmem() {  # mkmem <stem> <type>
  { echo "---"; echo "name: $1"; echo "description: d"
    echo "metadata:"; echo "  type: $2"; echo "  modified: 2026-01-01"; echo "---"
    echo ""; echo "body"; } > "$STORE/$1.md"
}
mkmem project_old  project
mkmem feedback_one feedback
# Tier order is feedback → reference → project, so this file is inverted.
{ echo "- [P](project_old.md) — hook"
  echo "- [F](feedback_one.md) — hook"; } > "$STORE/MEMORY.md"
OUT=$(run_resume "sess-clean")
check_contains "reorder announced"   "Memory index reordered" "$OUT"
check_contains "names the store"     "reordered"              "$OUT"
# The tool also writes tier markers, so assert the ORDER of the entries rather
# than which line is first.
check_eq "feedback sorts above project" "feedback_one" \
  "$(grep -o 'feedback_one\|project_old' "$STORE/MEMORY.md" | head -1)"
check_eq "entry count unchanged" "2" "$(grep -c '^- \[' "$STORE/MEMORY.md")"

echo ""
echo "=== memory index: already ordered → silent ==="
OUT=$(run_resume "sess-clean")
check_not_contains "no reorder banner" "Memory index reordered" "$OUT"

echo ""
echo "=== no store for this launch directory → silent, and nothing created ==="
rm -rf "$CLAUDE_MEMORY_PROJECTS_DIR"
mkdir -p "$CLAUDE_MEMORY_PROJECTS_DIR"
OUT=$(run_resume "sess-clean")
check_not_contains "silent without a store" "Memory index reordered" "$OUT"
check_eq "created nothing" "0" "$(ls -1 "$CLAUDE_MEMORY_PROJECTS_DIR" | wc -l | tr -d ' ')"

echo ""
echo "=== git context: skipped on startup (the CLI's own gitStatus has it), kept on resume ==="
if git rev-parse --git-dir &>/dev/null 2>&1; then
  payload=$(jq -nc '{source:"startup", session_id:"sess-git", hook_event_name:"SessionStart"}')
  OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  check_not_contains "startup prints no git block" "## Git context" "$OUT"
  OUT=$(run_resume "sess-git")
  check_contains     "resume still prints it"     "## Git context" "$OUT"
else
  echo "  SKIP: git-context test (not in a git repo)"
fi

echo ""
echo "=== CLI past the contract pin → one nudge; same version or no pin → silent ==="
printf '2.1.280\n' > "$TMP/pin"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.281 run_resume "sess-clean")
check_contains "nudge names both versions" "Installed 2.1.281; the harness was verified at 2.1.280" "$OUT"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.280 run_resume "sess-clean")
check_not_contains "silent at the pinned version" "past the harness contract" "$OUT"
OUT=$(CLAUDE_CLI_VERSION=2.1.281 run_resume "sess-clean")
check_not_contains "silent without a pin file" "past the harness contract" "$OUT"

echo ""
echo "=== the nudge is stamped: once per CLI version per day, not every session ==="
# It fired in every session in every repo while the CLI was ahead of the pin,
# and nothing the reader can do changes between two sessions on the same day.
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.281 run_resume "sess-clean")
check_not_contains "second session the same day is silent" "past the harness contract" "$OUT"
check_eq "stamp lives in the state dir" "2.1.281 $(date +%Y-%m-%d)" "$(head -1 "$CLAUDE_STATE_DIR/contract-nudge")"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.282 run_resume "sess-clean")
check_contains "a newer CLI nudges again" "Installed 2.1.282; the harness was verified at 2.1.280" "$OUT"
printf '2.1.282 2000-01-01\n' > "$CLAUDE_STATE_DIR/contract-nudge"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.282 run_resume "sess-clean")
check_contains "and so does a stale stamp from another day" "Installed 2.1.282" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
