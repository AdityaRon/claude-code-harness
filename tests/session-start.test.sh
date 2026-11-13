#!/usr/bin/env bash
# Tests for session-start.sh — resume-drift branch. Stages snapshots at
# $CLAUDE_STATE_DIR, feeds SessionStart payloads on stdin, and asserts the
# drift classifications surfaced in stdout.
set -u
HOOK="hooks/session-start.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
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
# And the real release record, which harness-update.sh writes on this machine.
export CLAUDE_HARNESS_LATEST="$TMP/no-latest"
export CLAUDE_HARNESS_VERSION="$TMP/no-version"

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

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
echo "=== Matching hash → silent ==="
write_snap "sess-clean" "$TARGET" "$CURRENT_HASH" "true"
OUT=$(run_resume "sess-clean")
check_not_contains "no drift line" "Resume drift" "$OUT"

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
  check_not_contains "HEAD only: no file intro" "files below" "$OUT"
else
  echo "  SKIP: HEAD-change test (not in a git repo)"
fi

echo ""
echo "=== memory index: far from the cap → left alone, even out of order ==="
# The reorder only matters near the 200-line cut, and it was most of session
# start on a small store. The store slug is the launch directory with every
# non-alphanumeric a dash.
SLUG=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/$SLUG/memory"
mkdir -p "$STORE"
mkmem() {  # mkmem <stem> <type>
  { echo "---"; echo "name: $1"; echo "description: d"
    echo "metadata:"; echo "  type: $2"; echo "  modified: 2026-01-01"; echo "---"
    echo ""; echo "body"; } > "$STORE/$1.md"
}
inverted_index() {  # tier order is feedback → reference → project; this is backwards
  { echo "- [P](project_old.md) — hook"
    echo "- [F](feedback_one.md) — hook"; } > "$STORE/MEMORY.md"
}
first_entry() { grep -o 'feedback_one\|project_old' "$STORE/MEMORY.md" | head -1; }
mkmem project_old  project
mkmem feedback_one feedback
inverted_index
BEFORE=$(shasum "$STORE/MEMORY.md")
run_resume "sess-clean" >/dev/null
check_eq "a small index is not rewritten" "$BEFORE" "$(shasum "$STORE/MEMORY.md")"
check_eq "and no stamp is written" "0" "$(ls -1 "$CLAUDE_STATE_DIR/memory-index" 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "=== memory index: under pressure and out of order → reordered, silently ==="
# Pressure starts where memory-lint says it does; the same variable moves both.
export MEMORY_INDEX_PRESSURE_LINES=1
OUT=$(run_resume "sess-clean")
check_not_contains "nothing in context" "eordered" "$OUT"
# The tool also writes tier markers, so assert the ORDER of the entries rather
# than which line is first.
check_eq "feedback sorts above project" "feedback_one" "$(first_entry)"
check_eq "entry count unchanged" "2" "$(grep -c '^- \[' "$STORE/MEMORY.md")"
check_eq "stamped with the index's mtime and size" \
  "$(date -r "$STORE/MEMORY.md" +%s) $(wc -c < "$STORE/MEMORY.md" | tr -d ' ')" \
  "$(cat "$CLAUDE_STATE_DIR/memory-index/$SLUG")"

echo ""
echo "=== memory index: unchanged since the stamp → the tool does not run ==="
# Same mtime and size as the stamp, but two entries swapped: a run would reorder
# it, so a still-swapped index proves the run was skipped.
cp -p "$STORE/MEMORY.md" "$TMP/stamped-index"
awk '/^- \[/ { held[++n] = $0; next } { print } END { for (i = n; i >= 1; i--) print held[i] }' \
  "$TMP/stamped-index" > "$STORE/MEMORY.md"
touch -r "$TMP/stamped-index" "$STORE/MEMORY.md"
check_eq "fixture is out of order" "project_old" "$(first_entry)"
run_resume "sess-clean" >/dev/null
check_eq "skipped: still out of order" "project_old" "$(first_entry)"
# A new write to the index changes its mtime, so the next start runs again.
# (An explicit time: the stamp has one-second resolution and a bare touch can
# land in the same second it was written.)
touch -t 202601020000 "$STORE/MEMORY.md"
run_resume "sess-clean" >/dev/null
check_eq "a changed index is reordered" "feedback_one" "$(first_entry)"

echo ""
echo "=== memory index: auto-dream's lock is fresh → not touched ==="
# The CLI holds .consolidate-lock for up to an hour while it consolidates a
# store; a harness rewrite under it would race the CLI's own.
inverted_index
touch "$STORE/.consolidate-lock"
run_resume "sess-clean" >/dev/null
check_eq "fresh lock: left out of order" "project_old" "$(first_entry)"
# The lock stays on disk after a run as the last-consolidated stamp; once past
# its TTL it no longer means held.
touch -t 202601010000 "$STORE/.consolidate-lock"
run_resume "sess-clean" >/dev/null
check_eq "stale lock: reordered" "feedback_one" "$(first_entry)"

echo ""
echo "=== a worktree path: every non-alphanumeric becomes a dash (issue #2, G) ==="
# The CLI builds the store name with replace(/[^a-zA-Z0-9]/g,"-") (2.1.282), so
# `.claude/worktrees/v0_build` lands in `--claude-worktrees-v0-build`.
WT="/tmp/prep-lanes/.claude/worktrees/v0_build"
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/-tmp-prep-lanes--claude-worktrees-v0-build/memory"
mkdir -p "$STORE"
mkmem project_old  project
mkmem feedback_one feedback
inverted_index
OUT=$(jq -nc --arg d "$WT" '{source:"resume", session_id:"sess-wt", hook_event_name:"SessionStart", cwd:$d}' \
  | bash "$HOOK" 2>/dev/null)
check_eq "worktree store reordered" "feedback_one" "$(first_entry)"
unset MEMORY_INDEX_PRESSURE_LINES

echo ""
echo "=== no store for this launch directory → silent, and nothing created ==="
rm -rf "$CLAUDE_MEMORY_PROJECTS_DIR"
mkdir -p "$CLAUDE_MEMORY_PROJECTS_DIR"
run_resume "sess-clean" >/dev/null
check_eq "created nothing" "0" "$(ls -1 "$CLAUDE_MEMORY_PROJECTS_DIR" | wc -l | tr -d ' ')"

echo ""
echo "=== git context: skipped on startup and clear (the CLI's own gitStatus has it), kept on resume and compact ==="
if git rev-parse --git-dir &>/dev/null 2>&1; then
  payload=$(jq -nc '{source:"startup", session_id:"sess-git", hook_event_name:"SessionStart"}')
  OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  check_not_contains "startup prints no git block" "## Git context" "$OUT"
  # After /clear the conversation carried this block and the CLI's fresh
  # gitStatus, listing the same 5 commits.
  payload=$(jq -nc '{source:"clear", session_id:"sess-git", hook_event_name:"SessionStart"}')
  OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  check_not_contains "clear prints no git block"   "## Git context" "$OUT"
  OUT=$(run_resume "sess-git")
  check_contains     "resume still prints it"     "## Git context" "$OUT"
  payload=$(jq -nc '{source:"compact", session_id:"sess-git", hook_event_name:"SessionStart"}')
  OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  check_contains     "compact still prints it"    "## Git context" "$OUT"
else
  echo "  SKIP: git-context test (not in a git repo)"
fi

echo ""
echo "=== CLI past the contract pin → one nudge; same version or no pin → silent ==="
printf '2.1.280\n' > "$TMP/pin"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.281 run_resume "sess-clean")
check_contains "nudge names both versions" "Installed 2.1.281; the harness was verified at 2.1.280" "$OUT"
check_contains "and says the release chain installs it" "the scheduled harness-update installs it" "$OUT"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.280 run_resume "sess-clean")
check_not_contains "silent at the pinned version" "past the harness contract" "$OUT"
OUT=$(CLAUDE_CLI_VERSION=2.1.281 run_resume "sess-clean")
check_not_contains "silent without a pin file" "past the harness contract" "$OUT"
rm -f "$CLAUDE_STATE_DIR/contract-nudge"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.99 run_resume "sess-clean")
check_contains     "an older CLI is told to update" "older than the harness contract" "$OUT"
check_not_contains "and is not called past it"      "past the harness contract" "$OUT"
printf '2.1.281 %s\n' "$(date +%Y-%m-%d)" > "$CLAUDE_STATE_DIR/contract-nudge"

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
echo "=== a newer harness release was fetched → one nudge a day; otherwise silent ==="
LATEST="$TMP/harness-latest"; VERSION="$TMP/harness.version"
nudge() { CLAUDE_HARNESS_LATEST="$LATEST" CLAUDE_HARNESS_VERSION="$VERSION" run_resume "sess-clean"; }
printf 'v1.0.2 2026-10-20\n' > "$LATEST"
printf 'version=v1.0.1\nrepo=/x\n' > "$VERSION"
OUT=$(nudge)
check_contains "names both versions" "Harness v1.0.2 is available; v1.0.1 is installed" "$OUT"
OUT=$(nudge)
check_not_contains "second session the same day is silent" "is available" "$OUT"
check_eq "stamped in the state dir" "v1.0.2 $(date +%Y-%m-%d)" "$(head -1 "$CLAUDE_STATE_DIR/release-nudge")"
rm -f "$CLAUDE_STATE_DIR/release-nudge"
printf 'version=v1.0.2\n' > "$VERSION"
check_not_contains "silent at the newest release" "is available" "$(nudge)"
printf 'version=v1.0.3\n' > "$VERSION"
check_not_contains "silent when the install is ahead of the fetched tag" "is available" "$(nudge)"
printf 'version=v1.0.1-3-gabc1234\n' > "$VERSION"
check_not_contains "a clone past a tag is being worked on: silent" "is available" "$(nudge)"
printf 'v1.0.10 2026-10-20\n' > "$LATEST"; printf 'version=v1.0.9\n' > "$VERSION"
check_contains "versions compare numerically" "Harness v1.0.10 is available" "$(nudge)"
rm -f "$CLAUDE_STATE_DIR/release-nudge" "$LATEST"
check_not_contains "no fetch record: silent" "is available" "$(nudge)"

echo ""
echo "=== Resume names the mods this session wrote ==="
export CLAUDE_DEV_MODS_DIR="$TMP/dev-mods"
mkdir -p "$CLAUDE_DEV_MODS_DIR/sess-mods/branch/.claude-plugin" "$CLAUDE_DEV_MODS_DIR/sess-mods/notamod"
printf '{"name":"branch"}' > "$CLAUDE_DEV_MODS_DIR/sess-mods/branch/.claude-plugin/plugin.json"
OUT=$(run_resume "sess-mods")
case "$OUT" in *"Mod loading from this session: $CLAUDE_DEV_MODS_DIR/sess-mods/branch "*) echo "  OK: names a mod the session wrote"; PASS=$((PASS+1)) ;; *) echo "  FAIL: names a mod the session wrote  [$OUT]"; FAIL=$((FAIL+1)) ;; esac
case "$OUT" in *notamod*) echo "  FAIL: skips a folder with no manifest  [$OUT]"; FAIL=$((FAIL+1)) ;; *) echo "  OK: skips a folder with no manifest"; PASS=$((PASS+1)) ;; esac
OUT=$(run_resume "sess-clean")
case "$OUT" in *"Mod loading"*) echo "  FAIL: silent for a session with no mods  [$OUT]"; FAIL=$((FAIL+1)) ;; *) echo "  OK: silent for a session with no mods"; PASS=$((PASS+1)) ;; esac

echo ""
echo "=== Start prunes worktree records whose folder is gone ==="
L="$TMP/launch"; mkdir -p "$L"
git init -q "$L/repo" && git -C "$L/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$L/repo" worktree add -q "$TMP/wt-live" -b live && git -C "$L/repo" worktree add -q "$TMP/wt-gone" -b gone
rm -rf "$TMP/wt-gone"
jq -nc --arg d "$L" '{source:"startup",session_id:"sess-prune",cwd:$d}' | bash "$HOOK" >/dev/null 2>&1
# The prune is detached; give it up to 10 s.
for _ in $(seq 50); do git -C "$L/repo" worktree list | grep -q wt-gone || break; sleep 0.2; done
WT=$(git -C "$L/repo" worktree list)
check_not_contains "stale record pruned" "wt-gone" "$WT"
check_contains "live worktree kept" "wt-live" "$WT"

echo ""
echo "=== input: one jq reads all three fields, and a value is data, never code ==="
# The hook evals jq's @sh output, so a field built to break out of the quoting
# must arrive whole and run nothing.
EV="$TMP/ev"; mkdir -p "$EV"
SID="x'; touch pwned1; '\$(touch pwned2)\`touch pwned3\` \"q"
jq -n --arg p "$TARGET" --arg h "$STALE_HASH" '{git_head:"", edited_files:[{path:$p, sha256:$h, exists:true}]}' \
  > "$CLAUDE_STATE_DIR/$SID.json"
OUT=$(cd "$EV" && jq -nc --arg sid "$SID" --arg cwd "$EV/it's \$(touch pwned4)" '{source:"resume", session_id:$sid, cwd:$cwd}' \
  | bash "$OLDPWD/$HOOK" 2>/dev/null)
check_contains "the exact session id finds its snapshot" "drifted: $TARGET" "$OUT"
check_eq "no field ran as code" "" "$(ls "$EV")"

echo ""
echo "=== store_slug: the same slug sed gives, in this locale and in C ==="
lib() { bash -c "source hooks/lib.sh; $*"; }
for s in '/Users/someone/Desktop' '/tmp/a b/c.d_e-f' '/x/é/ü/日本/🙂' '/A-Z/[x]/*?/\q'; do
  check_eq "store_slug: $s" "$(printf '%s' "$s" | sed 's/[^A-Za-z0-9]/-/g')" "$(lib "store_slug '$s'")"
  check_eq "store_slug, C locale: $s" "$(printf '%s' "$s" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')" "$(LC_ALL=C lib "store_slug '$s'")"
done

echo ""
echo "=== cli_version: read from the path claude resolves to, else asked ==="
C="$TMP/cli"; mkdir -p "$C/Caskroom/claude-code@latest/2.1.322" "$C/versions" "$C/bin" "$C/npm"
touch "$C/Caskroom/claude-code@latest/2.1.322/claude" "$C/versions/2.1.330"
ln -s "$C/versions/2.1.330" "$C/bin/claude"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$C/npm/cli"; chmod +x "$C/npm/cli"
check_eq "a cask install: its folder names the version" "2.1.322" "$(CLAUDE_CLI_PATH="$C/Caskroom/claude-code@latest/2.1.322/claude" lib cli_version)"
check_eq "a link into versions/: resolved, then named" "2.1.330" "$(CLAUDE_CLI_PATH="$C/bin/claude" lib cli_version)"
check_eq "no version in the path: the binary is asked" "9.9.9" "$(CLAUDE_CLI_PATH="$C/npm/cli" lib cli_version)"
printf '2.1.331\n' > "$TMP/pin"
OUT=$(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_PATH="$C/bin/claude" CLAUDE_STATE_DIR="$TMP/state-cli" run_resume "sess-clean")
check_contains "the contract nudge uses it" "Installed 2.1.330; the harness was verified at 2.1.331" "$OUT"

# A copy of the hook beside a stub memory-index.sh that records each run and takes
# STUB_SLEEP seconds (lib.sh puts the system folders first on PATH, so a stub has
# to be one the hook finds beside itself).
TREE="$TMP/tree"; mkdir -p "$TREE/hooks" "$TREE/bin"
cp hooks/session-start.sh hooks/lib.sh "$TREE/hooks/"
export RUNS="$TMP/index-runs"
printf '#!/usr/bin/env bash\necho run >> "$RUNS"\nsleep "${STUB_SLEEP:-1}"\n' > "$TREE/bin/memory-index.sh"
printf '2.1.280\n' > "$TMP/pin"
IDX="$CLAUDE_MEMORY_PROJECTS_DIR/$SLUG/memory/MEMORY.md"
run_tree() {  # sid [VAR=value...]: the copied hook on a resume payload
  local sid="$1"; shift
  jq -nc --arg sid "$sid" '{source:"resume", session_id:$sid, hook_event_name:"SessionStart"}' \
    | env "$@" bash "$TREE/hooks/session-start.sh" 2>/dev/null
}
due() {  # every optional section has work: the index changed, both nudges are due
  mkdir -p "${IDX%/*}"; [ -f "$IDX" ] || printf -- '- [P](p.md) - h\n' > "$IDX"
  touch -t "20260103$(printf '%02d' $((RANDOM % 60)))00" "$IDX"
  rm -f "$CLAUDE_STATE_DIR/contract-nudge" "$CLAUDE_STATE_DIR/release-nudge" "$CLAUDE_STATE_DIR"/*.lock \
    "$CLAUDE_STATE_DIR/memory-index/$SLUG" "$RUNS"
  printf 'v1.0.3\n' > "$LATEST"; printf 'version=v1.0.2\n' > "$VERSION"
}
NUDGES=(CLAUDE_CONTRACT_PIN="$TMP/pin" CLAUDE_CLI_VERSION=2.1.281 CLAUDE_HARNESS_LATEST="$LATEST"
        CLAUDE_HARNESS_VERSION="$VERSION" MEMORY_INDEX_PRESSURE_LINES=1)

echo ""
echo "=== a slow section: the ones after it are not started, and are named ==="
due
S0=$SECONDS
# Whole seconds: SECONDS can tick over just after the hook starts, so a budget
# of 2 is between one and two seconds, and the section that takes 3 starts inside it.
OUT=$(run_tree sess-clean "${NUDGES[@]}" STUB_SLEEP=3 CLAUDE_SESSION_START_BUDGET=2)
EL=$((SECONDS - S0))
check_contains "one line names each section it skipped" \
  "session-start: past its 2 s budget, skipped: worktree-prune contract-nudge release-nudge resume-drift" "$OUT"
check_not_contains "no nudge from a skipped section" "Harness v1.0.3 is available" "$OUT"
check_eq "the slow section ran once, started in budget" "1" "$(cat "$RUNS" 2>/dev/null | wc -l | tr -d ' ')"
[ "$EL" -le 5 ] && pass "back in ${EL}s: the 3 s section it was in, nothing after" || fail "elapsed" "${EL}s"
due
OUT=$(run_tree sess-clean "${NUDGES[@]}" CLAUDE_SESSION_START_BUDGET=0)
check_contains "a budget already spent names every section" \
  "skipped: git-context memory-index worktree-prune contract-nudge release-nudge resume-drift" "$OUT"
OUT=$(run_tree sess-clean "${NUDGES[@]}")
check_not_contains "under budget nothing is named" "past its" "$OUT"
check_contains "and the sections run" "Harness v1.0.3 is available" "$OUT"
check_eq "settings.json stops it at 30 s, not Claude Code's default 10 minutes" "30" \
  "$(jq '.hooks.SessionStart[0].hooks[0].timeout' config/settings.json)"

echo ""
echo "=== 14 sessions resuming together: the per-machine work runs once ==="
due
for i in $(seq 1 14); do run_tree "storm-$i" "${NUDGES[@]}" > "$TMP/storm-$i.out" & done
wait
check_eq "the index tool ran once" "1" "$(cat "$RUNS" 2>/dev/null | wc -l | tr -d ' ')"
check_eq "one session showed the contract nudge" "1" "$(cat "$TMP"/storm-*.out | grep -c 'past the harness contract')"
check_eq "one session showed the release nudge" "1" "$(cat "$TMP"/storm-*.out | grep -c 'Harness v1.0.3 is available')"
check_eq "no lock left behind" "" "$(ls "$CLAUDE_STATE_DIR"/*.lock "$CLAUDE_STATE_DIR"/memory-index/*.lock 2>/dev/null)"

echo ""
echo "=== a lock left by a killed run expires after 10 minutes ==="
due
printf '0\n' > "$CLAUDE_STATE_DIR/contract-nudge.lock"
OUT=$(run_tree sess-clean "${NUDGES[@]}")
check_contains "an old lock is taken over" "past the harness contract" "$OUT"
check_eq "and removed" "" "$(ls "$CLAUDE_STATE_DIR"/contract-nudge.lock* 2>/dev/null)"
due
date +%s > "$CLAUDE_STATE_DIR/contract-nudge.lock"
OUT=$(run_tree sess-clean "${NUDGES[@]}")
check_not_contains "a fresh one means another session has it" "past the harness contract" "$OUT"
rm -f "$CLAUDE_STATE_DIR/contract-nudge.lock" "$LATEST" "$VERSION"

echo ""
echo "=== resume drift hashes every edited file in one process ==="
SAME="$TMP/same.txt" MOVED="$TMP/with space.txt" SHUT="$TMP/shut.txt" LAST="$TMP/last.txt"
printf 'a\n' > "$SAME"; printf 'b\n' > "$MOVED"; printf 'c\n' > "$SHUT"; printf 'd\n' > "$LAST"
H_SAME=$(shasum -a 256 "$SAME" | awk '{print $1}'); H_SHUT=$(shasum -a 256 "$SHUT" | awk '{print $1}')
H_LAST=$(shasum -a 256 "$LAST" | awk '{print $1}')
# The unreadable file sits between two unchanged ones: hashes are matched by path, not by position.
jq -n --arg a "$SAME" --arg ha "$H_SAME" --arg b "$MOVED" --arg c "$SHUT" --arg hc "$H_SHUT" --arg d "$LAST" --arg hd "$H_LAST" \
  '{session_id:"sess-many", git_head:"", edited_files:[{path:$a, sha256:$ha, exists:true},
    {path:$b, sha256:"0000", exists:true}, {path:$c, sha256:$hc, exists:true}, {path:$d, sha256:$hd, exists:true}]}' > "$CLAUDE_STATE_DIR/sess-many.json"
chmod 000 "$SHUT"
OUT=$(run_resume "sess-many")
chmod 644 "$SHUT"
check_contains "a changed file with a space in its name" "drifted: $MOVED" "$OUT"
check_not_contains "an unchanged file is not named" "drifted: $SAME" "$OUT"
check_contains "a file the hasher cannot read has drifted" "drifted: $SHUT" "$OUT"
check_not_contains "an unchanged file after it is not named" "drifted: $LAST" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
