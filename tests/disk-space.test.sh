#!/usr/bin/env bash
# Tests for bin/disk-space.py, tools/session-census.py --sizes and doctor.sh
# --disk, against a fixture HOME, a fixture Bazel root and a stand-in claude.
# Mutations that turn this red: tmp left out of the du; the live-server check
# dropped; the cache/ skip dropped; the detached-HEAD check dropped; a symlink
# followed; the entry's own mtime only; no re-check, digest check or live cwd keep.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The script under test; a mutation run points this at a changed copy.
DS=${CCH_DISK_SPACE_PY:-$REPO/bin/disk-space.py}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); TMP_RAW=$TMP; TMP=$(cd "$TMP" && pwd -P)
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
if ! command -v lsof >/dev/null; then   # a Linux runner with no lsof: the same answer, from /proc
  printf '%s\n' '#!/usr/bin/env bash' 'for d in /proc/[0-9]*; do c=$(readlink "$d/cwd" 2>/dev/null) && printf "p%s\nn%s\n" "${d#/proc/}" "$c"; done' > "$TMP/bin/lsof"
  chmod +x "$TMP/bin/lsof"
fi

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
[[ "$TXT" == *"Orphaned (workspace gone, no server running, no process using it): 2 output bases"* && "$TXT" == *"cache/ and install/ not listed"* ]] \
  && pass "text: the orphan count, and what is not listed" || fail "bazel text" "$TXT"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/ps"; chmod +x "$TMP/bin/ps"
OUT=$(ds bazel --json)
[ "$(bb $B3 server) $(bb $B4 server) $(jqr "$OUT" .orphans)" = "unknown unknown 0" ] \
  && pass "ps failing: a pid file's server is unknown, and nothing is orphaned" || fail "ps fails" "$(bb $B3 server) $(bb $B4 server) $(jqr "$OUT" .orphans)"
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
echo "=== prune: old tmp entries no git work, live job, process or server holds ==="
# Ages count from CLAUDE_DISK_SPACE_NOW, ten days ahead: a ctime cannot be set back, so the fixture
# is old because the clock is late, and a fresh file is one whose mtime is set ahead.
FUT=$(( $(date +%s) + 10 * 86400 ))
dsf() { CLAUDE_DISK_SPACE_NOW=$FUT python3 "$DS" "$@"; }
PJ="$TMP/pj" PB="$TMP/pb" E="$TMP/pj/e0000001/tmp" F="$TMP/pj/f0000002/tmp" H="$TMP/pj/a0000003/tmp" C5="$TMP/pj/c0000005/tmp"
G="git -c user.email=t@example.com -c user.name=t -c init.defaultBranch=main -c commit.gpgsign=false"
$G init -q --bare "$TMP/remote.git"
$G clone -q "$TMP/remote.git" "$TMP/tpl" 2>/dev/null
( cd "$TMP/tpl" && echo one > f && $G add f && $G commit -qm one && git push -q origin HEAD:main ) || fail "git fixture" "push"
clone() { cp -Rp "$TMP/tpl" "$1"; }   # clone DEST: a clean clone with nothing unpushed
in_() { local d=$1; shift; ( cd "$d" && "$@" ) >/dev/null 2>&1; }
pjob() {  # pjob ID JSON-FIELDS: a job folder whose state.json holds them
  mkdir -p "$PJ/$1/tmp"; printf '{"state":"working",%s}\n' "$2" > "$PJ/$1/state.json"; : > "$PJ/$1/timeline.jsonl"
}
mkdir -p "$PJ"; $G init -q "$PJ"   # the jobs folder sits in a repo: no entry may be judged by it
pjob e0000001 '"cwd":"/"'
pjob f0000002 "\"cwd\":\"$F/work/sub\",\"worktreePath\":\"$E/xjob/sub\",\"originCwd\":\"$HOME/code/busyclone\""
pjob a0000003 "\"cwd\":\"$H/hcwd\""; pjob c0000005 '"cwd":"/"'
clone "$E/clean"; mkdir -p "$E/clean/ws"
clone "$E/dirty"; echo two >> "$E/dirty/f"
clone "$E/ahead"; in_ "$E/ahead" $G commit -q --allow-empty -m ahead
clone "$E/detached"; in_ "$E/detached" git checkout -q --detach; in_ "$E/detached" $G commit -q --allow-empty -m detached
clone "$E/tagonly"; in_ "$E/tagonly" git checkout -q --detach; in_ "$E/tagonly" $G commit -q --allow-empty -m tagged
in_ "$E/tagonly" git tag t1; in_ "$E/tagonly" git checkout -q main
clone "$E/stash"; echo two >> "$E/stash/f"; in_ "$E/stash" $G stash -q
clone "$E/hidden-au"; in_ "$E/hidden-au" git update-index --assume-unchanged f; echo two >> "$E/hidden-au/f"
clone "$E/hidden-sw"; in_ "$E/hidden-sw" git update-index --skip-worktree f; echo two >> "$E/hidden-sw/f"
mkdir -p "$E/noremote"; in_ "$E/noremote" $G init -q; in_ "$E/noremote" $G commit -q --allow-empty -m solo
clone "$TMP/mainrepo"; mkdir -p "$E/worktree"; in_ "$TMP/mainrepo" git worktree add -q --detach "$E/worktree/wt"
mkdir -p "$E/nested/a/b"; clone "$E/nested/a/b/c"; echo two >> "$E/nested/a/b/c/f"
clone "$E/untracked"; echo new > "$E/untracked/new.txt"
cp -Rp "$TMP/remote.git" "$E/bare.git"
mkdir -p "$E/badgit/.git"; : > "$E/badgit/file"   # an empty .git: git would walk up to the repo around
# A clean filter git status would run, and a signed stash gpg.program would verify: code a repo brings.
clone "$E/filtered"; printf '* filter=x\n' > "$E/filtered/.git/info/attributes"
in_ "$E/filtered" git config filter.x.clean "sh -c 'touch $TMP/pwned-filter; cat'"; age 1 "$E/filtered/f"
clone "$E/signed"; printf '#!/bin/sh\ntouch %s/pwned-gpg\nexit 1\n' "$TMP" > "$TMP/fakegpg"; chmod +x "$TMP/fakegpg"
SIGNED=$(cd "$E/signed" && git cat-file commit HEAD | awk '/^committer /{print; print "gpgsig -----BEGIN PGP SIGNATURE-----"; print " "; print " iQ=="; print " -----END PGP SIGNATURE-----"; next} {print}' | git hash-object -t commit -w --stdin)
mkdir -p "$E/signed/.git/logs/refs"; echo "$SIGNED" > "$E/signed/.git/refs/stash"
printf '%040d %s t <t@example.com> 1700000000 +0000\tOn main: x\n' 0 "$SIGNED" > "$E/signed/.git/logs/refs/stash"
in_ "$E/signed" git config log.showSignature true; in_ "$E/signed" git config gpg.program "$TMP/fakegpg"
mkdir -p "$E/linkout" "$TMP/outside2"; fill "$TMP/outside2/keep" 4096; ln -s "$TMP/outside2" "$E/linkout/to-outside"
mkdir -p "$E/freshinside/sub"; : > "$E/freshinside/sub/fresh.txt"
mkdir -p "$E/young" "$TMP/outside3"; : > "$TMP/outside3/keep"; ln -s "$TMP/outside3" "$E/linkentry"
fill "$E/plainfile" 4096; mkfifo "$E/fifo"; mkdir -p "$E/fifodir"; mkfifo "$E/fifodir/pipe"
clone "$E/raced"; clone "$E/xjob"; mkdir -p "$E/xjob/sub"
clone "$E/bazelbusy"; mkdir -p "$E/bazelbusy/ws"
mkdir -p "$E/procdir/inner"
clone "$F/work"; mkdir -p "$F/work/sub"; clone "$F/other"; clone "$H/hcwd"
FORGE=$'forge\nkeep               e0000001/tmp/clean: forged'
mkdir -p "$C5/$FORGE" "$C5/café" "$C5/deep"
(cd "$C5/deep" && mkdir -p "$(printf 'a/%.0s' $(seq 1 140))")
mkdir -p "$PJ/b0000004" "$TMP/outside4/old"; printf '{}' > "$PJ/b0000004/state.json"; ln -s "$TMP/outside4" "$PJ/b0000004/tmp"
: > "$PJ/notes.txt"; mkdir -p "$PJ/deadbeef"
P1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa P2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb P3=cccccccccccccccccccccccccccccccc
P4=dddddddddddddddddddddddddddddddd P5=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee P6=ffffffffffffffffffffffffffffffff
P7=abababababababababababababababab P8=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
pbase() {  # pbase NAME WORKSPACE: an output base with a read-only tree, as Bazel leaves one
  mkdir -p "$PB/$1/execroot/ro" "$PB/$1/server"; printf '%s' "$2" > "$PB/$1/DO_NOT_BUILD_HERE"
  fill "$PB/$1/execroot/ro/blob" 65536; chmod 444 "$PB/$1/execroot/ro/blob"; chmod 555 "$PB/$1/execroot/ro"
}
server() {  # server BASE: a live process whose command line names BASE, in its pid file
  (exec -a "bazel-server --output_base=$PB/$1" sleep 300) & SLEEPERS="$SLEEPERS $!"; printf '%s' "$!" > "$PB/$1/server/server.pid.txt"
}
pbase $P1 "$TMP_RAW/pj/e0000001/tmp/clean/ws"   # the unresolved spelling: matched by realpath
pbase $P2 "$E/bazelbusy/ws"; server $P2
pbase $P3 "$TMP/gone-ws"; mkdir -p "$PB/$P3/locked/deep"; : > "$PB/$P3/locked/deep/f"; chmod 000 "$PB/$P3/locked"
pbase $P4 "/Volumes/cch-not-mounted-$$/ws"
pbase $P5 "$TMP/gone-ws2"; server $P5
pbase $P6 "$TMP/gone-ws4"; (cd "$PB/$P6/execroot" && exec sleep 300) & SLEEPERS="$SLEEPERS $!"; P6PID=$!
pbase $P7 "$TMP/gone-ws5"; (exec -a "some-tool --cache=$PB/$P7" sleep 300) & SLEEPERS="$SLEEPERS $!"; P7PID=$!
for d in cache install; do mkdir -p "$PB/$d/x"; printf '%s' "$TMP/gone-ws3" > "$PB/$d/DO_NOT_BUILD_HERE"; done
age -9 "$E/young"; age -10 "$E/freshinside/sub/fresh.txt"; age -10 "$PJ/a0000003/timeline.jsonl"
(cd "$E/procdir/inner" && exec sleep 300) & SLEEPERS="$SLEEPERS $!"; CWDPID=$!
printf '[{"id":"f0000002","pid":4343},{"id":"e0000001","state":"done"},{"id":"a0000003","state":"done"}]' > "$TMP/agents.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do lsof -n -P -d cwd -p "$CWDPID" 2>/dev/null | grep -q procdir && break; sleep 0.2; done

OUT=$(dsf prune --jobs "$PJ" --root "$PB" --json); RC=$?
[ "$RC" = 0 ] && pass "prune --json exits 0" || fail "prune rc" "$RC $OUT"
DIG=$(jqr "$OUT" .digest)
TARGETS="e0000001/tmp/clean e0000001/tmp/linkentry e0000001/tmp/linkout e0000001/tmp/plainfile e0000001/tmp/raced f0000002/tmp/other"
[ "$(jqr "$OUT" '[.targets[].rel | select(startswith("c0000005") | not)] | sort | join(" ")')" = "$TARGETS" ] \
  && pass "listed to delete: clean and pushed clones, a dir holding a link out, a link, a file, in a live job too" \
  || fail "targets" "$(jqr "$OUT" '[.targets[].rel] | join(" ")')"
[ "$(jqr "$OUT" '.targets[] | select(.rel == "e0000001/tmp/clean") | [.bases[].name] | join(" ")')" = $P1 ] \
  && pass "the clone's Bazel output base goes with it, matched by realpath" || fail "clean's base" "$(jqr "$OUT" '.targets[0]')"
kr() { jqr "$OUT" ".kept[] | select(.path == \"$1\") | .reason"; }
GONE_ON_ALL="commits no remote has, on a branch, a tag or a detached HEAD"
while IFS='|' read -r path want; do
  got=$(kr "$path")
  [[ "$got" == *"$want"* ]] && pass "kept $path: $want" || fail "kept $path" "want *$want* got: $got"
done <<ROWS
e0000001/tmp/dirty|dirty: tracked files changed
e0000001/tmp/ahead|ahead: $GONE_ON_ALL
e0000001/tmp/detached|detached: $GONE_ON_ALL
e0000001/tmp/tagonly|tagonly: $GONE_ON_ALL
e0000001/tmp/stash|stash: a stash
e0000001/tmp/hidden-au|hidden-au: files marked skip-worktree or assume-unchanged
e0000001/tmp/hidden-sw|hidden-sw: files marked skip-worktree or assume-unchanged
e0000001/tmp/noremote|noremote: commits and no remote
e0000001/tmp/worktree|worktree/wt: a worktree outside the entry: $TMP/mainrepo
e0000001/tmp/nested|nested/a/b/c: tracked files changed
e0000001/tmp/untracked|untracked: untracked files
e0000001/tmp/bare.git|bare.git: commits and no remote
e0000001/tmp/badgit|badgit: git status --porcelain --untracked-files=normal --ignore-submodules=all failed: fatal: not a git repository
e0000001/tmp/filtered|filtered: a git filter is configured
e0000001/tmp/signed|signed: a stash
e0000001/tmp/freshinside|freshinside/sub/fresh.txt changed 0.0 days ago
e0000001/tmp/bazelbusy|Bazel output base $P2: its server is running
e0000001/tmp/procdir|pid $CWDPID's working folder is inside
e0000001/tmp/fifo|a socket, fifo or device
e0000001/tmp/fifodir|fifodir/pipe is a socket, fifo or device
e0000001/tmp/xjob|live job f0000002's worktreePath is inside
f0000002/tmp/work|live job f0000002's cwd is inside
a0000003/tmp/hcwd|live job a0000003's cwd is inside
c0000005/tmp/deep|is nested deeper than 128 folders
ROWS
[ ! -e "$TMP/pwned-filter" ] && [ ! -e "$TMP/pwned-gpg" ] && pass "listing ran no repo's clean filter and no gpg.program" \
  || fail "repo code ran" "$(ls "$TMP" | grep pwned)"
[ "$(jqr "$OUT" .young)" = 1 ] && pass "an entry newer than 7 days by its own mtime is only counted" || fail "young" "$(jqr "$OUT" .young)"
[ "$(jqr "$OUT" '.skipped_jobs | map(join(": ")) | join(";")')" = "b0000004: tmp is a symlink, not a folder" ] \
  && pass "a job whose tmp is a link is skipped" || fail "skipped" "$(jqr "$OUT" .skipped_jobs)"
[[ "$(jqr "$OUT" '.live_jobs | map(join(" ")) | join(";")')" == "a0000003 active 0.0 h ago;f0000002 pid 4343" ]] \
  && pass "live: a pid from claude agents, or activity within 24 h" || fail "live jobs" "$(jqr "$OUT" .live_jobs)"
TXT=$(dsf prune --jobs "$PJ" --root "$PB")
[[ "$TXT" == *"Digest $DIG."* && "$TXT" == *"To delete exactly these: python3 "*" prune --apply $DIG --jobs $PJ --root $PB" ]] \
  && pass "the text names the digest and the exact command, --apply right after prune" || fail "prune text" "$TXT"
[ "$(printf '%s\n' "$TXT" | grep -c '^keep .*e0000001/tmp/clean: forged$')" = 0 ] && [[ "$TXT" == *"c0000005/tmp/forge\\nkeep"* ]] \
  && pass "a name holding a newline prints as a literal on its own line: no forged row" || fail "forged row" "$TXT"
OUT3=$(PYTHONIOENCODING=ascii dsf prune --jobs "$PJ" --root "$PB" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$OUT3" == *'caf\'* && "$OUT3" != *Traceback* ]] \
  && pass "a name stdout cannot encode prints escaped, with no traceback" || fail "unencodable name" "rc=$RC $(printf '%s' "$OUT3" | tail -3)"
rule_prefix() {  # rule_prefix VERB: the shipped ask rule's command prefix for that verb
  local r; r=$(jq -r --arg v "$1" '.permissions.ask[] | select(startswith("Bash(python3 ~/.claude/disk-space.py " + $v))' "$REPO/config/settings.json")
  r=${r#Bash(}; printf '%s' "${r%:\*)}"
}
mkdir -p "$HOME/.claude"; cp "$DS" "$HOME/.claude/disk-space.py"
CMD=$(CLAUDE_DISK_SPACE_NOW=$FUT python3 "$HOME/.claude/disk-space.py" prune --jobs "$PJ" --root "$PB" | sed -n 's/^To delete exactly these: //p')
RP=$(rule_prefix "prune --apply")
[[ -n "$RP" && "$CMD" == "$RP $DIG "* ]] && pass "installed, the printed command is one the ask rule names: $RP" || fail "rule prefix" "rule=$RP cmd=$CMD"
OUT2=$(dsf prune --jobs "$PJ" --root "$PB" --allow-untracked --json)
[[ " $(jqr "$OUT2" '[.targets[].rel] | join(" ")') " == *" e0000001/tmp/untracked "* && "$(jqr "$OUT2" .digest)" != "$DIG" ]] \
  && pass "--allow-untracked lists the untracked clone, under another digest" || fail "allow-untracked" "$(jqr "$OUT2" '[.targets[].rel]')"

echo ""
echo "=== prune: ctime counts, since tar -x, cp -p and rsync -a set mtime back ==="
PJ2="$TMP/pj2"; mkdir -p "$PJ2/d0000007/tmp/extracted/sub"; printf '{"cwd":"/"}' > "$PJ2/d0000007/state.json"
: > "$PJ2/d0000007/tmp/extracted/sub/f"; age 30 "$PJ2/d0000007/tmp/extracted/sub/f" "$PJ2/d0000007/tmp/extracted/sub" "$PJ2/d0000007/tmp/extracted"
OUT2=$(ds prune --jobs "$PJ2" --root "$PB" --json)
[ "$(jqr "$OUT2" '.targets | length') $(jqr "$OUT2" .young)" = "0 1" ] \
  && pass "an entry whose mtimes are 30 days back but which was made today is young" || fail "ctime" "$(jqr "$OUT2" '[.targets[].rel, .young]')"
pym() {  # pym CODE: run CODE with the script under test imported as m
  python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("ds", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
exec(sys.argv[2])' "$DS" "$1"
}
OUT2=$(E2="$PJ2/d0000007/tmp/extracted" pym 'import os, time
e = os.environ["E2"]; st = os.lstat(e); now = time.time()
try:
    m.survey(e, st.st_dev, now - 7 * 86400, now, "x"); print("passed")
except m.Keep as k:
    print("keep:", k)')
[[ "$OUT2" == "keep: x/sub changed 0.0 days ago" ]] && pass "inside an entry too: a ctime from today keeps it" || fail "ctime inside" "$OUT2"

echo ""
echo "=== deletion helpers: chmod never through a link; a tree too deep is an error, not a crash ==="
mkdir -p "$TMP/cm/real" "$TMP/cm/target"; chmod 000 "$TMP/cm/target"; ln -s "$TMP/cm/target" "$TMP/cm/lnk"
OUT2=$(CM="$TMP/cm" pym 'import os
d = os.environ["CM"]; fd = os.open(d, os.O_RDONLY); st = os.lstat(os.path.join(d, "real"))
try:
    m.chmod_dir(fd, "lnk", st); print("chmodded")
except OSError as e:
    print("refused")')
[ "$OUT2" = refused ] && [ "$(stat -f %Lp "$TMP/cm/target" 2>/dev/null || stat -c %a "$TMP/cm/target")" = 0 ] \
  && pass "chmod_dir refuses a name that is now a link, and its target keeps mode 000" || fail "chmod through link" "$OUT2"
chmod 700 "$TMP/cm/target"
mkdir -p "$TMP/rt/deep"; (cd "$TMP/rt/deep" && mkdir -p "$(printf 'a/%.0s' $(seq 1 100))")
OUT2=$(RT="$TMP/rt" pym 'import os, sys
d = os.environ["RT"]; fd = os.open(d, os.O_RDONLY); st = os.lstat(os.path.join(d, "deep"))
sys.setrecursionlimit(80)
try:
    m.delete_at(fd, "deep", (st.st_dev, st.st_ino)); print("deleted")
except OSError as e:
    print("error:", e.strerror)' 2>&1)
[[ "$OUT2" == "error: nested too deep to delete" ]] && pass "a tree deeper than the stack: an error naming why, no RecursionError" || fail "recursion" "$OUT2"

echo ""
echo "=== prune --apply: only with the listing's digest; each entry quarantined and checked again ==="
exists_all() { local p; for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] || { echo "$p"; return 1; }; done; }
ALL_TARGETS="$E/clean $E/linkentry $E/linkout $E/plainfile $E/raced $F/other $PB/$P1"
OUT=$(dsf prune --apply 0000000000000000 --jobs "$PJ" --root "$PB" 2>&1); RC=$?
# shellcheck disable=SC2086
[ "$RC" = 1 ] && [[ "$OUT" == *"Nothing deleted: this listing's digest is $DIG, not 0000000000000000"* ]] && exists_all $ALL_TARGETS >/dev/null \
  && pass "a wrong digest deletes nothing" || fail "wrong digest" "rc=$RC $(exists_all $ALL_TARGETS) $OUT"
for args in "prune --jobs $PJ --root $PB --apply $DIG" "prune --apply=$DIG --jobs $PJ --root $PB" "prune --app $DIG --jobs $PJ --root $PB"; do
  # shellcheck disable=SC2086
  OUT=$(dsf $args 2>&1); RC=$?
  # shellcheck disable=SC2086
  [ "$RC" = 2 ] && [[ "$OUT" == *"--apply goes right after"* ]] && exists_all $ALL_TARGETS >/dev/null \
    && pass "refused, nothing deleted: ${args%% --jobs*}${args##*"$PB"}" || fail "misplaced --apply" "rc=$RC $OUT"
done
GO="$TMP/go"
CLAUDE_DISK_SPACE_NOW=$FUT CLAUDE_DISK_SPACE_TEST_PAUSE="$GO" python3 "$DS" prune --apply "$DIG" --jobs "$PJ" --root "$PB" > "$TMP/apply.out" 2>&1 & APID=$!
for _ in $(seq 1200); do [ -e "$GO.ready" ] && break; sleep 0.1; done
echo three >> "$E/raced/f"   # after the digest matched: only the re-check can see it
: > "$GO"; wait $APID; RC=$?; OUT=$(cat "$TMP/apply.out")
[ "$RC" = 0 ] && pass "apply exits 0" || fail "apply rc" "rc=$RC $OUT"
[[ "$OUT" == *"kept at the re-check: e0000001/tmp/raced: raced: tracked files changed"* && -d "$E/raced" ]] \
  && pass "an entry made dirty after the listing is kept at the re-check, under its own name again" || fail "re-check" "$OUT"
[[ "$OUT" == *"unlinked e0000001/tmp/linkentry (a link; its target stays)"* ]] && pass "a link entry is reported unlinked" || fail "unlinked" "$OUT"
GONE=""; for p in "$E/clean" "$E/linkentry" "$E/linkout" "$E/plainfile" "$F/other" "$PB/$P1"; do { [ -e "$p" ] || [ -L "$p" ]; } && GONE="$GONE $p"; done
[ -z "$GONE" ] && [[ "$OUT" == *"deleted Bazel output base $P1"* ]] \
  && pass "the eligible entries and the clone's read-only output base are gone" || fail "deleted" "left:$GONE $OUT"
LEFT=$(exists_all "$E/dirty" "$E/ahead" "$E/detached" "$E/tagonly" "$E/stash" "$E/hidden-au/f" "$E/hidden-sw/f" "$E/noremote" \
  "$E/worktree/wt" "$E/nested/a/b/c/f" "$E/untracked" "$E/bare.git" "$E/badgit/file" "$E/filtered" "$E/signed" "$E/xjob/sub" \
  "$E/freshinside/sub/fresh.txt" "$E/bazelbusy/ws" "$E/procdir/inner" "$E/young" "$F/work/sub" "$H/hcwd" "$C5/deep" \
  "$TMP/outside2/keep" "$TMP/outside3/keep" "$TMP/outside4/old" "$PJ/notes.txt" "$PJ/deadbeef" "$PJ/b0000004/tmp" \
  "$PB/$P2" "$PB/$P3" "$PB/$P4" "$PB/$P5" "$PB/$P6" "$PB/$P7" "$PB/cache/x" "$PB/install/x" "$TMP/mainrepo/f" "$E/fifo" "$E/fifodir/pipe")
[ -z "$LEFT" ] && pass "every kept entry, each link's target, the strays, the other bases, cache/ and install/ are still there" || fail "kept" "missing: $LEFT"
LEFT=$(for j in e0000001 f0000002 a0000003 c0000005; do exists_all "$PJ/$j/state.json" "$PJ/$j/timeline.jsonl" "$PJ/$j/tmp"; done)
[ -z "$LEFT" ] && pass "state.json, timeline.jsonl and every job folder stay" || fail "job files" "missing: $LEFT"
[ -z "$(find "$PJ" "$PB" -name '.disk-space-quarantine-*' 2>/dev/null)" ] && pass "no quarantine name is left behind" \
  || fail "quarantine left" "$(find "$PJ" "$PB" -name '.disk-space-quarantine-*')"
[ ! -e "$TMP/pwned-filter" ] && [ ! -e "$TMP/pwned-gpg" ] && pass "nor did the apply run a repo's filter or gpg.program" || fail "repo code ran at apply" ""

echo ""
echo "=== prune --apply: a folder swapped in during the git check is not deleted (A1) ==="
# A stand-in git that, once the digest has matched, swaps the folder it is asked about for a clone
# holding unpushed work, as the review's reproduction did.
PJ4="$TMP/pj4" E4="$TMP/pj4/d0000006/tmp"; mkdir -p "$E4"; printf '{"cwd":"/"}' > "$PJ4/d0000006/state.json"
clone "$E4/victim"; clone "$TMP/dirtyclone"; in_ "$TMP/dirtyclone" $G commit -q --allow-empty -m unpushed; echo mine > "$TMP/dirtyclone/precious.txt"
REALGIT=$(command -v git); GO4="$TMP/go4"; mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<SH
#!/usr/bin/env bash
if [ -e "$GO4.ready" ] && [ ! -e "$TMP/shim.done" ] && [[ " \$* " == *" worktree list "* ]]; then
  d=""; p=""; for a in "\$@"; do [ "\$p" = -C ] && d=\$a; p=\$a; done
  if [ -n "\$d" ]; then : > "$TMP/shim.done"; mv "\$d" "$TMP/away"; mv "$TMP/dirtyclone" "\$d"; fi
fi
exec "$REALGIT" "\$@"
SH
chmod +x "$TMP/shim/git"
D4=$(dsf prune --jobs "$PJ4" --root "$PB" --json | jq -r .digest)
CLAUDE_DISK_SPACE_NOW=$FUT CLAUDE_DISK_SPACE_TEST_PAUSE="$GO4" PATH="$TMP/shim:$PATH" python3 "$DS" prune --apply "$D4" --jobs "$PJ4" --root "$PB" > "$TMP/apply4.out" 2>&1 & APID=$!
for _ in $(seq 1200); do [ -e "$GO4.ready" ] && break; sleep 0.1; done
: > "$GO4"; wait $APID; OUT=$(cat "$TMP/apply4.out")
[ -e "$TMP/shim.done" ] && [ -f "$E4/victim/precious.txt" ] && [ -f "$TMP/away/f" ] && [[ "$OUT" == *"not the inode that was checked"* ]] \
  && pass "the swapped-in clone survives, back under the entry's name, and the checked one too" || fail "A1 swap" "$(ls "$E4" "$E4/victim" 2>&1) $OUT"

echo ""
echo "=== bazel --sweep: output bases whose workspace is gone, whose server is not running, no process uses ==="
OUT=$(ds bazel --sweep --root "$PB" --json); SD=$(jqr "$OUT" .digest)
[ "$(jqr "$OUT" '[.targets[].name] | join(" ")')" = $P3 ] \
  && pass "only the orphan: not a live workspace, an unknown one, a running server, cache/ or install/" || fail "sweep targets" "$(jqr "$OUT" .targets)"
OUT=$(ds bazel --root "$PB" --json)
bu() { jqr "$OUT" ".bases[] | select(.name == \"$1\") | .users"; }
[ "$(bu $P6)" = "pid $P6PID's working folder is inside" ] && [ "$(bu $P7)" = "pid $P7PID's command line names it" ] \
  && pass "a base a process works in, or whose path a command line names, is in use, whatever server.pid.txt says" || fail "base users" "$(bu $P6) / $(bu $P7)"
CMD=$(python3 "$HOME/.claude/disk-space.py" bazel --sweep --root "$PB" | sed -n 's/^To delete exactly these: //p')
RP=$(rule_prefix "bazel --sweep --apply")
[[ -n "$RP" && "$CMD" == "$RP $SD "* ]] && pass "installed, the sweep command is one the ask rule names: $RP" || fail "sweep rule prefix" "rule=$RP cmd=$CMD"
OUT=$(ds bazel --sweep --apply 0000000000000000 --root "$PB" 2>&1); RC=$?
[ "$RC" = 1 ] && [ -d "$PB/$P3" ] && pass "a wrong digest sweeps nothing" || fail "sweep wrong digest" "rc=$RC $OUT"
OUT=$(ds bazel --root "$PB" --sweep --apply "$SD" 2>&1); RC=$?
[ "$RC" = 2 ] && [ -d "$PB/$P3" ] && pass "--apply not right after bazel --sweep: refused" || fail "sweep misplaced" "rc=$RC $OUT"
GO="$TMP/go2"
CLAUDE_DISK_SPACE_TEST_PAUSE="$GO" python3 "$DS" bazel --sweep --apply "$SD" --root "$PB" > "$TMP/sweep.out" 2>&1 & APID=$!
for _ in $(seq 1200); do [ -e "$GO.ready" ] && break; sleep 0.1; done
mkdir "$TMP/gone-ws"; : > "$GO"; wait $APID; OUT=$(cat "$TMP/sweep.out"); rmdir "$TMP/gone-ws"
[[ "$OUT" == *"kept at the re-check: Bazel output base $P3: its workspace is exists"* ]] && [ -d "$PB/$P3" ] \
  && pass "a workspace back after the listing keeps its base at the re-check" || fail "sweep re-check" "$OUT"
if [ -r "$PB/$P3/locked" ]; then fail "a mode 000 folder is still readable (root?): the sweep below proves nothing about it" ""; fi
OUT=$(ds bazel --sweep --apply "$SD" --root "$PB" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$PB/$P3" ] && [ -z "$(exists_all "$PB/$P2" "$PB/$P4" "$PB/$P5" "$PB/$P6" "$PB/$P7" "$PB/cache/x" "$PB/install/x")" ] \
  && pass "the orphan's read-only and mode 000 folders are gone; nothing else is" || fail "sweep" "rc=$RC $OUT"

echo ""
echo "=== clone: a clone in your home folder and its output bases, the same checks, no age test ==="
CL="$HOME/code"; mkdir -p "$CL"
clone "$CL/prclone"; pbase $P8 "$CL/prclone"
clone "$CL/dirtyclone"; echo two >> "$CL/dirtyclone/f"
clone "$CL/busyclone"
clone "$CL/cwdclone"; mkdir -p "$CL/cwdclone/sub"; (cd "$CL/cwdclone/sub" && exec sleep 300) & SLEEPERS="$SLEEPERS $!"; CLPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do lsof -n -P -d cwd -p "$CLPID" 2>/dev/null | grep -q cwdclone && break; sleep 0.2; done
cl() { ds clone "$@" --jobs "$PJ" --root "$PB"; }
OUT=$(cl "$CL/prclone" --json)
CD=$(jqr "$OUT" .digest)
[ "$(jqr "$OUT" '[.targets[].path, (.targets[].bases[].name)] | join(" ")')" = "$CL/prclone $P8" ] \
  && pass "made today and clean: listed, with the output base whose DO_NOT_BUILD_HERE names it" || fail "clone list" "$OUT"
for row in "dirtyclone|dirtyclone: tracked files changed" "busyclone|live job f0000002's originCwd is inside" "cwdclone|pid $CLPID's working folder is inside"; do
  n=${row%%|*}; want=${row#*|}; got=$(cl "$CL/$n" --json | jq -r '.kept[0].reason')
  [[ "$got" == *"$want"* ]] && pass "clone kept: $want" || fail "clone $n" "want *$want* got: $got"
done
mkdir -p "$CL/notaclone" "$HOME/.claude/jobs/abcdef01/tmp/x/.git"; ln -s "$CL/prclone" "$CL/linkclone"
for row in "$TMP/tpl|is not inside your home folder" "$HOME|is not inside your home folder" "$HOME/.claude|holds ~/.claude" \
           "$HOME/.claude/jobs|is in ~/.claude, outside a job's tmp" "$CL/notaclone|holds no .git" "$CL/linkclone|is not a folder"; do
  p=${row%%|*}; want=${row#*|}; OUT=$(cl "$p" 2>&1); RC=$?
  [ "$RC" = 1 ] && [[ "$OUT" == *"$want"* ]] && pass "refused: ${p#"$TMP/"} $want" || fail "clone refusal $p" "rc=$RC $OUT"
done
OUT=$(cl "$HOME/.claude/jobs/abcdef01/tmp/x" 2>&1)
[[ "$OUT" != *"not a clone this deletes"* ]] && pass "a clone in a job's tmp is one it takes" || fail "job tmp clone" "$OUT"
CMD=$(python3 "$HOME/.claude/disk-space.py" clone "$CL/prclone" --jobs "$PJ" --root "$PB" | sed -n 's/^To delete exactly these: //p')
RP=$(rule_prefix "clone --apply")
[[ -n "$RP" && "$CMD" == "$RP $CD $CL/prclone "* ]] && pass "installed, the clone command is one the ask rule names: $RP" || fail "clone rule prefix" "rule=$RP cmd=$CMD"
OUT=$(ds clone --apply 0000000000000000 "$CL/prclone" --jobs "$PJ" --root "$PB" 2>&1); RC=$?
[ "$RC" = 1 ] && [ -d "$CL/prclone" ] && [ -d "$PB/$P8" ] && pass "a wrong digest deletes no clone" || fail "clone wrong digest" "rc=$RC $OUT"
OUT=$(ds clone "$CL/prclone" --apply "$CD" --jobs "$PJ" --root "$PB" 2>&1); RC=$?
[ "$RC" = 2 ] && [ -d "$CL/prclone" ] && pass "--apply not right after clone: refused" || fail "clone misplaced" "rc=$RC $OUT"
OUT=$(ds clone --apply "$CD" "$CL/prclone" --jobs "$PJ" --root "$PB" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$CL/prclone" ] && [ ! -e "$PB/$P8" ] && [ -z "$(exists_all "$CL/dirtyclone/f" "$CL/busyclone" "$CL/cwdclone/sub")" ] \
  && pass "the clone and its output base are gone; the kept clones stay" || fail "clone apply" "rc=$RC $OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
