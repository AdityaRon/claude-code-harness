#!/usr/bin/env bash
# Tests for bin/relocate-clones.sh against a fake HOME: real repos and
# worktrees under $HOME/Desktop, a stand-in lsof first on PATH, and the
# ~/.claude/projects records under CLAUDE_MEMORY_PROJECTS_DIR. The real
# ~/Desktop and ~/.claude/projects are never read or written.
set -u
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "missing: $2 in [$3]"; fi; }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "unexpected: $2 in [$3]"; else pass "$1"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd)
export HOME="$TMP/home"
export CLAUDE_MEMORY_PROJECTS_DIR="$HOME/.claude/projects"
export CLAUDE_STATE_DIR="$TMP/state" CLAUDE_AUDIT_LOG="$TMP/audit.log"
export CLAUDE_CONTRACT_PIN="$TMP/no-pin" CLAUDE_HARNESS_LATEST="$TMP/no-latest" CLAUDE_HARNESS_VERSION="$TMP/no-version"
export CLAUDE_HOST_BIN=/bin/sh    # the host check in session-start: a binary that exists
P="$CLAUDE_MEMORY_PROJECTS_DIR"; D="$HOME/Desktop"
mkdir -p "$D" "$P" "$TMP/bin" "$CLAUDE_STATE_DIR" "$HOME/.claude"
export PATH="$TMP/bin:$PATH"
printf '#!/usr/bin/env bash\ncat "%s/lsof.txt" 2>/dev/null\n' "$TMP" > "$TMP/bin/lsof"; chmod +x "$TMP/bin/lsof"
[ "$(command -v lsof)" = "$TMP/bin/lsof" ] || { echo "  FAIL: the stand-in lsof is not first on PATH; stopping"; exit 1; }
REL="$PWD/bin/relocate-clones.sh"
G="git -c user.email=t@example.com -c user.name=t"
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
mk_repo() { git init -q "$1" && $G -C "$1" commit -q --allow-empty -m init; }

# repoA: a worktree inside (.claude/worktrees/wt1) and one outside ($HOME/elsewhere);
# parent is not a repo but holds child; repoA-2 is a sibling whose record must stay.
mk_repo "$D/repoA"
git -C "$D/repoA" worktree add -q "$D/repoA/.claude/worktrees/wt1" -b wt1
mkdir -p "$HOME/elsewhere"; git -C "$D/repoA" worktree add -q "$HOME/elsewhere/wt-out" -b wt-out
mkdir -p "$D/parent"; mk_repo "$D/parent/child"; mk_repo "$D/repoA-2"
for p in "$D" "$D/repoA" "$D/repoA/.claude/worktrees/wt1" "$D/parent/child" "$D/repoA-2"; do
  mkdir -p "$P/$(slug "$p")/memory"; printf -- '- [x](x.md) from %s\n' "$p" > "$P/$(slug "$p")/memory/MEMORY.md"
done
mkdir -p "$P/$(slug "$D/repoA/.claude/worktrees/gone")"    # a worktree that no longer exists
printf 'version=v1.0.0\nrepo=%s\n' "$D/repoA" > "$HOME/.claude/harness.version"
intact() { [ -d "$D/repoA" ] && [ -d "$D/parent/child" ] && [ ! -e "$HOME/code" ] && [ -d "$P/$(slug "$D/repoA")" ]; }

echo "=== dry run: every action printed as 'would', nothing moved ==="
OUT=$(bash "$REL" "$D/repoA" "$D/parent/child" 2>&1); RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $OUT"
has "would move repoA to ~/code" "would mv $D/repoA $HOME/code/repoA" "$OUT"
has "would move the nested repo" "would mv $D/parent/child $HOME/code/child" "$OUT"
REPAIR=$(printf '%s\n' "$OUT" | grep "would git -C $HOME/code/repoA worktree repair")
has "would repair repoA's worktrees: the moved one at its new path" "$HOME/code/repoA/.claude/worktrees/wt1" "$REPAIR"
has "and the one that stays put" "elsewhere/wt-out" "$REPAIR"
has "would rename repoA's record" "would mv $P/$(slug "$D/repoA") $P/$(slug "$HOME/code/repoA")" "$OUT"
has "and the worktree's" "would mv $P/$(slug "$D/repoA/.claude/worktrees/wt1") $P/$(slug "$HOME/code/repoA/.claude/worktrees/wt1")" "$OUT"
has "and the nested repo's" "would mv $P/$(slug "$D/parent/child") $P/$(slug "$HOME/code/child")" "$OUT"
lacks "the sibling repoA-2's record is not touched" "would mv $P/$(slug "$D/repoA-2")" "$OUT"
has "a record with no directory behind it is named, not renamed" "not renamed: $P/$(slug "$D/repoA/.claude/worktrees/gone")" "$OUT"
has "harness.version pointing inside is noted" "harness.version has repo= inside $D/repoA" "$OUT"
has "says it is a dry run" "dry run: add --apply" "$OUT"
intact && pass "nothing moved" || fail "nothing moved" ""

echo ""
echo "=== refusals leave everything in place ==="
printf 'p4242\nfcwd\nn%s\np4243\nfcwd\nn%s\np9\nfcwd\nn/\n' "$D/repoA/.claude/worktrees/wt1" "$D/repoA-2" > "$TMP/lsof.txt"
OUT=$(bash "$REL" --apply "$D/repoA" 2>&1); RC=$?
[ "$RC" = 1 ] && pass "a process inside: exit 1" || fail "cwd inside" "rc=$RC $OUT"
has "names the pid, not the sibling's" "cwd inside $D/repoA: pid 4242." "$OUT"
has "and says nothing moved" "nothing moved" "$OUT"
intact && pass "nothing moved" || fail "nothing moved" ""
: > "$TMP/lsof.txt"
mkdir -p "$P/$(slug "$HOME/code/repoA")"
OUT=$(bash "$REL" --apply "$D/repoA" "$D/parent/child" 2>&1); RC=$?
[ "$RC" = 1 ] && has "a target record exists: refused, named" "refuse: record $P/$(slug "$HOME/code/repoA") exists" "$OUT" || fail "record exists" "rc=$RC $OUT"
intact && [ ! -e "$HOME/code/child" ] && pass "neither source moved" || fail "neither moved" ""
rmdir "$P/$(slug "$HOME/code/repoA")"
mkdir -p "$HOME/code/repoA"
OUT=$(bash "$REL" --apply "$D/repoA" 2>&1); RC=$?
[ "$RC" = 1 ] && has "the destination exists: refused" "refuse: $HOME/code/repoA exists" "$OUT" || fail "dest exists" "rc=$RC $OUT"
rmdir "$HOME/code/repoA" "$HOME/code"
OUT=$(bash "$REL" --apply "$D/nope" 2>&1); RC=$?
[ "$RC" = 1 ] && has "a missing source: refused" "refuse: $D/nope is not a directory" "$OUT" || fail "missing" "rc=$RC $OUT"
OUT=$(bash "$REL" --apply --to "$D/repoA/inside" "$D/repoA" 2>&1); RC=$?
[ "$RC" = 1 ] && has "a destination inside the source: refused" "is inside $D/repoA" "$OUT" || fail "inside" "rc=$RC $OUT"

echo ""
echo "=== --apply: moved, every worktree repaired, records renamed ==="
OUT=$(bash "$REL" --apply "$D/repoA" "$D/parent/child" 2>&1); RC=$?
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $OUT"
[ -d "$HOME/code/repoA" ] && [ ! -e "$D/repoA" ] && pass "repoA moved" || fail "repoA moved" ""
[ -d "$HOME/code/child" ] && [ ! -e "$D/parent/child" ] && pass "child moved; parent, not a repo, stays" || fail "child moved" ""
git -C "$HOME/code/repoA" status >/dev/null 2>&1 && pass "git status in the moved repo" || fail "repo status" "$(git -C "$HOME/code/repoA" status 2>&1)"
WT1="$HOME/code/repoA/.claude/worktrees/wt1"
git -C "$WT1" status >/dev/null 2>&1 && pass "git status in the moved worktree" || fail "wt1 status" "$(git -C "$WT1" status 2>&1)"
[ "$(git -C "$WT1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$WT1" && pwd -P)" ] && pass "the worktree knows its new path" || fail "wt1 toplevel" "$(git -C "$WT1" rev-parse --show-toplevel 2>&1)"
[ "$(git -C "$WT1" branch --show-current 2>/dev/null)" = wt1 ] && pass "on its branch" || fail "wt1 branch" ""
git -C "$HOME/elsewhere/wt-out" status >/dev/null 2>&1 && pass "git status in the worktree that stayed put" || fail "wt-out status" "$(git -C "$HOME/elsewhere/wt-out" status 2>&1)"
LIST=$(git -C "$HOME/code/repoA" worktree list 2>/dev/null)
has "the repo lists the moved worktree at its new path" "$WT1 " "$LIST"
lacks "and no old path" "$D/repoA" "$LIST"
git -C "$HOME/code/child" status >/dev/null 2>&1 && pass "git status in the moved nested repo" || fail "child status" ""
[ -d "$P/$(slug "$HOME/code/repoA")" ] && [ ! -e "$P/$(slug "$D/repoA")" ] && pass "repoA's record renamed" || fail "record repoA" "$(ls "$P")"
[ "$(cat "$P/$(slug "$HOME/code/repoA")/memory/MEMORY.md")" = "- [x](x.md) from $D/repoA" ] && pass "with its memory intact" || fail "memory" ""
[ -d "$P/$(slug "$HOME/code/repoA/.claude/worktrees/wt1")" ] && pass "the worktree's record renamed" || fail "record wt1" "$(ls "$P")"
[ -d "$P/$(slug "$HOME/code/child")" ] && [ ! -e "$P/$(slug "$D/parent/child")" ] && pass "the nested repo's record renamed" || fail "record child" "$(ls "$P")"
[ -d "$P/$(slug "$D/repoA-2")" ] && [ -d "$P/$(slug "$D")" ] && pass "the sibling's and Desktop's own records stay" || fail "untouched records" "$(ls "$P")"
[ -d "$P/$(slug "$D/repoA/.claude/worktrees/gone")" ] && pass "the orphan record stays" || fail "orphan record" ""
has "every action printed" "renamed record $(slug "$D/repoA") -> $(slug "$HOME/code/repoA")" "$OUT"

echo ""
echo "=== --launch-dir: one memory for sessions started in two places ==="
printf -- '- [x](x.md) desktop\n' > "$P/$(slug "$D")/memory/MEMORY.md"
OUT=$(bash "$REL" --launch-dir "$HOME/code" 2>&1); RC=$?
[ "$RC" = 0 ] && has "dry run says what it would link" "would ln -s ../$(slug "$D")/memory $P/$(slug "$HOME/code")/memory" "$OUT" || fail "launch dry" "rc=$RC $OUT"
[ ! -e "$P/$(slug "$HOME/code")" ] && pass "and makes nothing" || fail "dry made" ""
OUT=$(bash "$REL" --apply --launch-dir "$HOME/code" 2>&1); RC=$?
LINK="$P/$(slug "$HOME/code")/memory"
[ "$RC" = 0 ] && [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "../$(slug "$D")/memory" ] && pass "relative link made (~/Desktop is the default source)" || fail "link" "rc=$RC $OUT $(readlink "$LINK" 2>&1)"
[ "$(cat "$LINK/MEMORY.md")" = "- [x](x.md) desktop" ] && pass "reads Desktop's index through it" || fail "read through" ""
OUT=$(bash "$REL" --apply --launch-dir "$HOME/code" 2>&1); RC=$?
[ "$RC" = 0 ] && has "a second run: already linked" "already linked" "$OUT" || fail "idempotent" "rc=$RC $OUT"
mkdir -p "$P/$(slug "$HOME/other")/memory"
OUT=$(bash "$REL" --apply --launch-dir "$HOME/other" 2>&1); RC=$?
[ "$RC" = 1 ] && has "a real memory dir at the target: refused" "exists; merge it" "$OUT" || fail "refuse existing" "rc=$RC $OUT"
OUT=$(bash "$REL" --apply --launch-dir "$HOME/x" --memory-from "$HOME/nowhere" 2>&1); RC=$?
[ "$RC" = 1 ] && has "no source store: refused" "no memory store at" "$OUT" || fail "no source" "rc=$RC $OUT"

echo ""
echo "=== the hooks work through the link: memory-lint and session-start ==="
# memory-lint on a file written by its linked path finds the same defects as by
# its real path (it reads MEMORY.md beside the file).
MEM="$LINK/project_x.md"
printf -- '---\nname: project_x\ndescription: d\nmetadata:\n  type: project\n  originSessionId: s\n---\nbody\n' > "$MEM"
lint() { jq -nc --arg f "$1" '{tool_name:"Write", tool_input:{file_path:$f}, session_id:"s"}' | bash hooks/memory-lint.sh 2>&1 >/dev/null; echo "rc=$?"; }
VIA_LINK=$(lint "$MEM"); VIA_REAL=$(lint "$P/$(slug "$D")/memory/project_x.md")
has "memory-lint reads the index through the link" "no line in MEMORY.md points at project_x.md" "$VIA_LINK"
[ "$VIA_LINK" = "$VIA_REAL" ] && pass "and says the same as by the real path" || fail "same findings" "[$VIA_LINK] vs [$VIA_REAL]"
# session-start reorders an index under pressure for the launch directory's
# store; through the link it rewrites Desktop's file and stamps the link's slug.
mk() { printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: %s\n  modified: 2026-01-01\n---\n\nbody\n' "$1" "$2" > "$LINK/$1.md"; }
mk project_old project; mk feedback_one feedback
printf -- '- [P](project_old.md) — hook\n- [F](feedback_one.md) — hook\n' > "$LINK/MEMORY.md"
jq -nc --arg d "$HOME/code" '{source:"resume", session_id:"sess-link", cwd:$d, hook_event_name:"SessionStart"}' \
  | MEMORY_INDEX_PRESSURE_LINES=1 bash hooks/session-start.sh >/dev/null 2>&1
[ "$(grep -o 'feedback_one\|project_old' "$P/$(slug "$D")/memory/MEMORY.md" | head -1)" = feedback_one ] \
  && pass "session-start reordered Desktop's index through the link" || fail "reorder through link" "$(cat "$P/$(slug "$D")/memory/MEMORY.md")"
[ -f "$CLAUDE_STATE_DIR/memory-index/$(slug "$HOME/code")" ] && pass "stamped under the launch directory's slug" || fail "stamp" "$(ls "$CLAUDE_STATE_DIR/memory-index" 2>&1)"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
