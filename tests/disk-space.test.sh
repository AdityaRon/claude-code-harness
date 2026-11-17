#!/usr/bin/env bash
# Tests for bin/disk-space.py, tools/session-census.py --sizes and doctor.sh
# --disk, against a fixture HOME, a fixture Bazel root and a stand-in claude.
# Mutations that turn this red: tmp left out of the du; the live-server check
# dropped (a running base reads as orphaned); the cache/ skip dropped.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The script under test; a mutation run points this at a changed copy.
DS=${CCH_DISK_SPACE_PY:-$REPO/bin/disk-space.py}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
SLEEPERS=""
# chmod first: a fixture holds read-only folders, as a Bazel output base does.
cleanup() { [ -z "$SLEEPERS" ] || { kill $SLEEPERS; wait $SLEEPERS; } 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
J="$HOME/.claude/jobs" R="$TMP/bazel"
export CLAUDE_BAZEL_ROOT="$R"
unset CLAUDE_CLI_BIN
mkdir -p "$J" "$R" "$TMP/bin" "$TMP/ws/present"
export PATH="$TMP/bin:$PATH"

age() {  # age DAYS PATH...: each path's mtime DAYS ago; a link's own, not its target's
  python3 -c 'import os, sys, time
t = time.time() - float(sys.argv[1]) * 86400
for p in sys.argv[2:]:
    os.utime(p, (t, t), follow_symlinks=False)' "$@"
}
fill() { head -c "$2" /dev/urandom > "$1"; }   # fill FILE BYTES: real blocks, not a sparse file
job() {  # job ID STATE: a job folder as Claude Code makes one
  mkdir -p "$J/$1"; printf '{"state":"%s","cwd":"/"}\n' "$2" > "$J/$1/state.json"; : > "$J/$1/timeline.jsonl"
}
ds() { python3 "$DS" "$@"; }
jqr() { printf '%s' "$1" | jq -r "$2"; }
between() { awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(x != "" && x != "null" && x >= lo && x < hi) }'; }

# A stand-in claude: prints $TMP/agents.json, exits with $TMP/agents.rc, logs each call.
cat > "$TMP/bin/claude" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/claude.calls"
cat "$TMP/agents.json" 2>/dev/null
exit "\$(cat "$TMP/agents.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$TMP/bin/claude"
[ "$(command -v claude)" = "$TMP/bin/claude" ] || { echo "  FAIL: the stand-in claude is not first on PATH; stopping"; exit 1; }

# ---- job fixtures ----
MiB=1048576
job a0000001 working          # live: the stand-in gives it a pid
mkdir -p "$J/a0000001/tmp/big"; fill "$J/a0000001/tmp/big/blob" $((3 * MiB)); : > "$J/a0000001/tmp/recent.txt"
age 10 "$J/a0000001/tmp/big"; age 1 "$J/a0000001/tmp/recent.txt"
age 2 "$J/a0000001/state.json" "$J/a0000001/timeline.jsonl"
job b0000002 done             # no tmp at all
job c0000003 done             # tmp is a link to a folder outside the job
mkdir -p "$TMP/outside"; fill "$TMP/outside/blob" $((2 * MiB)); ln -s "$TMP/outside" "$J/c0000003/tmp"
job d0000004 working          # state.json says working, but no process: not live
: > "$J/notes.txt"; mkdir -p "$J/deadbeef" "$J/Zzzzzzzz"; printf '{}' > "$J/Zzzzzzzz/state.json"
printf '[{"id":"a0000001","pid":4242,"state":"working"},{"id":"b0000002","state":"done"},{"id":"d0000004","state":"working"}]' > "$TMP/agents.json"

echo "=== report: sizes with tmp, the link not followed, strays named ==="
OUT=$(ds report --json); RC=$?
[ "$RC" = 0 ] && pass "report --json exits 0" || fail "report rc" "$RC $OUT"
jb() { jqr "$OUT" ".jobs[] | select(.id == \"$1\") | .$2"; }
between "$(jb a0000001 bytes)" $((3 * MiB)) $((4 * MiB)) \
  && pass "a job's size counts its tmp: 3 MiB in tmp, $(jb a0000001 bytes) bytes" || fail "tmp in the size" "$(jb a0000001 bytes)"
between "$(jb b0000002 bytes)" 0 100000 && pass "a job with no tmp is small" || fail "no-tmp size" "$(jb b0000002 bytes)"
[ "$(jb c0000003 tmp)" = symlink ] && between "$(jb c0000003 bytes)" 0 $MiB \
  && pass "a symlinked tmp is named and its 2 MiB target not counted" || fail "symlinked tmp" "$(jb c0000003 tmp) $(jb c0000003 bytes)"
between "$(jqr "$OUT" .total_bytes)" $((3 * MiB)) $((5 * MiB)) && pass "the total is du's own line for the root" || fail "total" "$(jqr "$OUT" .total_bytes)"
[ "$(jb a0000001 tmp_entries)" = 2 ] && between "$(jb a0000001 oldest_entry_days)" 9.9 10.1 && between "$(jb a0000001 newest_entry_days)" 0.9 1.1 \
  && pass "tmp: 2 entries, oldest 10 d and newest 1 d by their own mtime" \
  || fail "tmp entries" "$(jb a0000001 tmp_entries) $(jb a0000001 oldest_entry_days) $(jb a0000001 newest_entry_days)"
between "$(jb a0000001 idle_hours)" 47.9 48.1 && pass "idle: hours since state.json or timeline.jsonl changed" || fail "idle" "$(jb a0000001 idle_hours)"
[ "$(jqr "$OUT" '[.jobs[].id] | sort | join(" ")')" = "a0000001 b0000002 c0000003 d0000004" ] \
  && pass "job folders are 8-hex names with a state.json" || fail "jobs" "$(jqr "$OUT" '[.jobs[].id] | join(" ")')"
[ "$(jqr "$OUT" '[.other[] | .name + ":" + .kind] | sort | join(" ")')" = "Zzzzzzzz:dir deadbeef:dir notes.txt:file" ] \
  && pass "a stray file, a folder with no state.json and a non-hex name are named, not counted as jobs" \
  || fail "strays" "$(jqr "$OUT" '.other')"

echo ""
echo "=== report: liveness from claude agents, never from state.json ==="
[ "$(jb a0000001 live) $(jb a0000001 pid)" = "true 4242" ] && pass "the pid claude agents gives makes a job live" || fail "live" "$(jb a0000001 live) $(jb a0000001 pid)"
[ "$(jb d0000004 live) $(jb d0000004 state)" = "false working" ] \
  && pass "state.json's working, with no pid, is not live; the state is shown as reported" || fail "state is not liveness" "$(jb d0000004 live) $(jb d0000004 state)"
[ "$(cat "$TMP/claude.calls")" = "agents --json --all" ] && pass "one claude call: agents --json --all" || fail "claude calls" "$(cat "$TMP/claude.calls")"
TXT=$(ds report)
for want in "tmp included" "own mtime" "Not job folders, left alone: Zzzzzzzz (dir), deadbeef (dir), notes.txt (file)" "4242" "tmp->link"; do
  [[ "$TXT" == *"$want"* ]] && pass "text names: $want" || fail "text: $want" "$TXT"
done
echo 1 > "$TMP/agents.rc"
OUT=$(ds report --json)
[ "$(jqr "$OUT" '[.jobs[].live] | unique | map(tostring) | join(" ")')" = null ] && [[ "$(jqr "$OUT" .live_note)" == *"exited 1"* ]] \
  && pass "claude agents failing: liveness unknown, and why" || fail "agents failing" "$(jqr "$OUT" '[.jobs[].live]') $(jqr "$OUT" .live_note)"
rm -f "$TMP/agents.rc"
OUT=$(CLAUDE_CLI_BIN="$TMP/no-claude" ds report --json); TXT=$(CLAUDE_CLI_BIN="$TMP/no-claude" ds report)
[ "$(jqr "$OUT" '[.jobs[].live] | unique | map(tostring) | join(" ")')" = null ] && [[ "$TXT" == *"unknown here"* ]] \
  && pass "no claude binary: liveness unknown, shown as ?" || fail "no claude" "$TXT"

echo ""
echo "=== bazel: workspace, size, a live server, cache/ and install/ skipped ==="
B1=11111111111111111111111111111111 B2=22222222222222222222222222222222 B3=33333333333333333333333333333333
B4=44444444444444444444444444444444 B5=55555555555555555555555555555555 B6=66666666666666666666666666666666
base() { mkdir -p "$R/$1/execroot"; printf '%s' "$2" > "$R/$1/DO_NOT_BUILD_HERE"; }   # base NAME WORKSPACE
base $B1 "$TMP/ws/present"
base $B2 "$TMP/ws/gone-a"            # orphaned: a read-only tree, as Bazel leaves one
mkdir -p "$R/$B2/execroot/ro"; fill "$R/$B2/execroot/ro/blob" $MiB; chmod 444 "$R/$B2/execroot/ro/blob"; chmod 555 "$R/$B2/execroot/ro"
base $B3 "$TMP/ws/gone-b"            # workspace gone, server running
(exec -a "bazel-server --output_base=$R/$B3" sleep 300) & SLEEPERS="$SLEEPERS $!"; SPID=$!
mkdir -p "$R/$B3/server" "$R/$B4/server"; printf '%s' "$SPID" > "$R/$B3/server/server.pid.txt"
base $B4 "$TMP/ws/gone-c"            # its pid file names a live process that is not its server
printf '%s' "$SPID" > "$R/$B4/server/server.pid.txt"
base $B5 "/Volumes/cch-not-mounted-$$/ws"
base $B6 "$TMP/ws/present
"                                    # one trailing newline, stripped
for d in cache install; do mkdir -p "$R/$d"; printf '%s' "$TMP/ws/gone-d" > "$R/$d/DO_NOT_BUILD_HERE"; done
mkdir -p "$R/77777777777777777777777777777777"; : > "$R/README"
for _ in 1 2 3 4 5 6 7 8 9 10; do ps -ax -ww -o pid=,command= | grep -q "^ *$SPID .*$R/$B3" && break; sleep 0.2; done
ps -ax -ww -o pid=,command= | grep -q "^ *$SPID .*$R/$B3" \
  && pass "the stand-in server is alive and its command line names its base" || fail "stand-in server" "$(ps -p "$SPID" -ww -o command=)"

OUT=$(ds bazel --json); RC=$?
[ "$RC" = 0 ] && pass "bazel --json exits 0" || fail "bazel rc" "$RC $OUT"
bb() { jqr "$OUT" ".bases[] | select(.name == \"$1\") | .$2"; }
[ "$(jqr "$OUT" '[.bases[].name] | sort | join(" ")')" = "$B1 $B2 $B3 $B4 $B5 $B6" ] \
  && pass "only children with DO_NOT_BUILD_HERE; cache/, install/, a bare folder and a file are not listed" \
  || fail "bases listed" "$(jqr "$OUT" '[.bases[].name] | join(" ")')"
[ "$(bb $B1 workspace_state) $(bb $B6 workspace_state)" = "exists exists" ] \
  && pass "a workspace that exists, with and without a trailing newline in the marker" || fail "exists" "$(bb $B1 workspace_state) $(bb $B6 workspace_state)"
[ "$(bb $B5 workspace_state) $(bb $B5 orphan)" = "unknown false" ] \
  && pass "a workspace on an unmounted /Volumes is unknown, not gone" || fail "unmounted" "$(bb $B5 workspace_state)"
[ "$(bb $B3 server) $(bb $B3 pid) $(bb $B3 orphan)" = "running $SPID false" ] \
  && pass "a gone workspace with its server running is not orphaned" || fail "live server" "$(bb $B3 server) $(bb $B3 pid) $(bb $B3 orphan)"
[ "$(bb $B4 server) $(bb $B4 orphan)" = "not running true" ] \
  && pass "a pid file naming a live process that is not its server: not running" || fail "pid reuse" "$(bb $B4 server)"
[ "$(jqr "$OUT" '[.bases[] | select(.orphan) | .name] | sort | join(" ")') $(jqr "$OUT" .orphans)" = "$B2 $B4 2" ] \
  && pass "orphans: the two whose workspace is gone and no server runs" || fail "orphans" "$(jqr "$OUT" '[.bases[] | select(.orphan) | .name]')"
between "$(bb $B2 bytes)" $MiB $((2 * MiB)) && between "$(jqr "$OUT" .orphan_bytes)" $MiB $((3 * MiB)) \
  && pass "a read-only tree is sized; orphan bytes add up" || fail "sizes" "$(bb $B2 bytes) $(jqr "$OUT" .orphan_bytes)"
TXT=$(ds bazel)
[[ "$TXT" == *"Orphaned (workspace gone, no server running): 2 output bases"* && "$TXT" == *"cache/ and install/ not listed"* ]] \
  && pass "text: the orphan count, and what is not listed" || fail "bazel text" "$TXT"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/ps"; chmod +x "$TMP/bin/ps"
OUT=$(ds bazel --json)
[ "$(bb $B3 server) $(bb $B4 server) $(jqr "$OUT" .orphans)" = "unknown unknown 1" ] \
  && pass "ps failing: a pid file's server is unknown, never orphaned" || fail "ps fails" "$(bb $B3 server) $(bb $B4 server) $(jqr "$OUT" .orphans)"
rm -f "$TMP/bin/ps"
[[ "$(CLAUDE_BAZEL_ROOT="$TMP/none" ds bazel)" == "No Bazel output root at $TMP/none." ]] && pass "no root: says so" || fail "no root" ""

echo ""
echo "=== stamp: the totals, no claude call, nothing written when du fails ==="
: > "$TMP/claude.calls"
OUT=$(ds stamp --out "$TMP/state/disk-usage" 2>&1); RC=$?
sv() { sed -n "s/^$1=//p" "$TMP/state/disk-usage"; }
[ "$RC" = 0 ] && [[ "$OUT" == "disk: $J holds"* ]] && pass "stamp exits 0 and says what it measured" || fail "stamp" "$RC $OUT"
between "$(sv jobs_bytes)" $((3 * MiB)) $((5 * MiB)) && between "$(sv orphan_bytes)" $MiB $((3 * MiB)) && [ "$(sv orphans)" = 2 ] \
  && between "$(sv bazel_bytes)" $MiB $((3 * MiB)) && pass "jobs, bazel root and orphan bytes" || fail "stamp fields" "$(cat "$TMP/state/disk-usage")"
NOW=$(date +%s)
between "$(sv measured)" $((NOW - 60)) $((NOW + 1)) && [ "$(sv date)" = "$(date +%Y-%m-%d)" ] \
  && pass "measured now, dated today" || fail "stamp time" "$(sv measured) $(sv date)"
[ ! -s "$TMP/claude.calls" ] && pass "stamp runs no claude (the updater's PATH may lack it)" || fail "stamp ran claude" "$(cat "$TMP/claude.calls")"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/du"; chmod +x "$TMP/bin/du"
OUT=$(ds stamp --out "$TMP/state/second" 2>&1); RC=$?
[ "$RC" != 0 ] && [ ! -e "$TMP/state/second" ] && [[ "$OUT" == *"not stamped"* ]] \
  && pass "a du with no total writes no stamp, and says so" || fail "du fails" "$RC $OUT"
rm -f "$TMP/bin/du"

echo ""
echo "=== session-census.py --sizes and doctor.sh --disk run the report ==="
: > "$TMP/ps.txt"
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$J" --sizes 2>&1)
[[ "$OUT" == *"background jobs ($J): "* && "$OUT" == *"Job folders in $J: 4"* ]] && pass "census --sizes adds the job folder report" || fail "census --sizes" "$OUT"
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$J" 2>&1)
[[ "$OUT" != *"Job folders in"* ]] && pass "census without --sizes runs no du" || fail "census" "$OUT"
OUT=$(bash "$REPO/doctor.sh" --disk 2>&1)
[[ "$OUT" == *"Job folders in $J: 4"* && "$OUT" == *"Bazel output bases in $R: 6"* ]] && pass "doctor.sh --disk: both reports" || fail "doctor --disk" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
