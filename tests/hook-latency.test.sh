#!/usr/bin/env bash
# Tests for tools/hook-latency.py, tools/hooknames.py and tools/session-census.py on
# fixture transcripts, settings, ps output and job folders; and doctor.sh's
# --latency and --census, which run them.
# shellcheck disable=SC2088  # records carry a literal ~, as Claude Code writes them
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
command -v python3 >/dev/null || { echo "  SKIP: no python3"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
REPO=$PWD
P="$TMP/projects"
# doctor.sh run from a copy whose tests/ is empty: if a flag were not handled it
# would run every suite, this one included, and never return.
DOC="$TMP/doc"; mkdir -p "$DOC/tests"; cp doctor.sh "$DOC/"; ln -s "$REPO/tools" "$DOC/tools"; ln -s "$REPO/hooks" "$DOC/hooks"
mkdir -p "$P/proj/sess1/subagents"

# Settings: Bash has env (1), git (2), config (3); Edit has mod-gate (4), config again
# (5, a repeat) and plan (6). "command hook 5" then names config-guard if repeats
# count and plan if they do not, so the report names both.
cat > "$TMP/settings.json" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [
    {"type": "command", "command": "~/.claude/hooks/env-guard.sh"},
    {"type": "command", "command": "~/.claude/hooks/git-guard.sh"},
    {"type": "command", "command": "~/.claude/hooks/config-guard.sh"}]},
  {"matcher": "Edit", "hooks": [
    {"type": "command", "command": "bash ~/.claude/hooks/mod-gate.sh"},
    {"type": "command", "command": "~/.claude/hooks/config-guard.sh"},
    {"type": "command", "command": "~/.claude/hooks/plan.sh"}]}]}}
JSON

# rec FILE DAYS_AGO HOOKNAME COMMAND [MS] [TYPE]: one attachment record.
rec() {
  python3 - "$@" <<'PY'
import datetime as dt, json, sys
f, ago, name, cmd = sys.argv[1:5]
ms = sys.argv[5] if len(sys.argv) > 5 else ""
kind = sys.argv[6] if len(sys.argv) > 6 else "hook_success"
t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=float(ago))
at = {"type": kind, "hookName": name, "hookEvent": name.split(":")[0], "command": cmd, "toolUseID": "t"}
if ms:
    at["durationMs"] = int(ms)
with open(f, "a") as fh:
    fh.write(json.dumps({"type": "attachment", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "attachment": at}) + "\n")
PY
}
T="$P/proj/sess1.jsonl"
for ms in 100 200 300 400 5000; do rec "$T" 1 SessionStart:resume "~/.claude/hooks/session-start.sh" "$ms"; done
rec "$T" 1 PreToolUse:Bash "command hook 2" 1800
rec "$T" 1 PreToolUse:Bash "command hook 2" 3400
rec "$T" 2 PreToolUse:Bash "command hook 2" 900
rec "$T" 1 PreToolUse:Edit "command hook 4" 700
rec "$T" 1 PreToolUse:Edit "command hook 3" 60
rec "$T" 1 PreToolUse:Edit "command hook 5" 61
rec "$T" 1 PreToolUse:Bash "command hook 9" 62
rec "$T" 40 PreToolUse:Bash "~/.claude/hooks/rm-guard.sh" 63
rec "$T" 1 PostToolUse:Bash "~/.claude/hooks/tcc-check.sh" "" hook_blocking_error
rec "$P/proj/sess1/subagents/agent-a.jsonl" 1 PreToolUse:Bash "~/.claude/hooks/network-guard.sh" 250

lat() { python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" "$@"; }
lat --json > "$TMP/day.json" 2>"$TMP/err"; RC=$?
row() { jq -c --arg e "$1" --arg h "$2" '[.rows[] | select(.event == $e and .hook == $h)] | map([.n, .p50, .p95, .max])' "$3"; }

echo "=== planted durations come back as n, p50, p95, max ==="
[ "$RC" = 0 ] && pass "exit 0" || fail "exit 0" "rc=$RC $(cat "$TMP/err")"
[ "$(row SessionStart:resume session-start.sh "$TMP/day.json")" = '[[5,300,5000,5000]]' ] \
  && pass "session-start on resume: n 5, p50 300, p95 and max 5000 (nearest rank)" \
  || fail "session-start row" "$(row SessionStart:resume session-start.sh "$TMP/day.json")"

echo ""
echo "=== \"command hook N\" is named through settings.json ==="
[ "$(row PreToolUse:Bash git-guard.sh "$TMP/day.json")" = '[[1,900,900,900],[2,1800,3400,3400]]' ] \
  && pass "hook 2 on Bash is git-guard, one row per day" || fail "git-guard rows" "$(row PreToolUse:Bash git-guard.sh "$TMP/day.json")"
[ "$(row PreToolUse:Edit mod-gate.sh "$TMP/day.json")" = '[[1,700,700,700]]' ] \
  && pass "a command line with an interpreter names its script (bash mod-gate.sh)" || fail "mod-gate" "$(jq -c '.rows' "$TMP/day.json")"
[ "$(row PreToolUse:Edit config-guard.sh "$TMP/day.json")" = '[[1,60,60,60]]' ] \
  && pass "an entry repeated later keeps its first number (hook 3 on Edit)" || fail "repeat" "$(jq -c '.rows' "$TMP/day.json")"
[ "$(row PreToolUse:Edit 'hook 5 (config-guard.sh or plan.sh)' "$TMP/day.json")" = '[[1,61,61,61]]' ] \
  && pass "a number past a repeat names both readings" || fail "ambiguous" "$(jq -c '[.rows[].hook]' "$TMP/day.json")"
[ "$(row PreToolUse:Bash 'hook 9' "$TMP/day.json")" = '[[1,62,62,62]]' ] \
  && pass "a number past the settings stays a number" || fail "out of range" "$(jq -c '[.rows[].hook]' "$TMP/day.json")"

[ "$(python3 "$REPO/tools/hooknames.py" PreToolUse 2 --settings "$TMP/settings.json")" = git-guard.sh ] \
  && pass "tools/hooknames.py PreToolUse 2 names the hook from the command line" || fail "hooknames CLI" ""

echo ""
echo "=== what is read and what is not counted ==="
[ "$(row PreToolUse:Bash network-guard.sh "$TMP/day.json")" = '[[1,250,250,250]]' ] \
  && pass "subagent transcripts are read" || fail "subagents" "$(jq -c '[.rows[].hook]' "$TMP/day.json")"
[ "$(row PreToolUse:Bash rm-guard.sh "$TMP/day.json")" = '[]' ] \
  && pass "a record older than --days is left out by its own timestamp, in a file written today" || fail "window" "$(jq -c '.rows' "$TMP/day.json")"
[ "$(jq -c '.not_counted' "$TMP/day.json")" = '{"hook_blocking_error":1}' ] && [ "$(jq '.counted' "$TMP/day.json")" = 13 ] \
  && pass "13 counted; a record with no durationMs is listed as not counted" || fail "counts" "$(jq -c '{counted, not_counted}' "$TMP/day.json")"
TXT=$(lat 2>&1)
[[ "$TXT" == *"only when it printed output or failed"* && "$TXT" == *"Not counted, no durationMs: 1 hook_blocking_error"* ]] \
  && pass "the text report says which records it could not count, and why n is not every run" || fail "caveats" "$TXT"
[[ "$TXT" == *"\"command hook N\" is named through $TMP/settings.json"* ]] \
  && pass "the report names the settings file it read numbers through" || fail "settings line" "$TXT"
[ "$(lat --days 60 --json | jq '[.rows[] | select(.hook == "rm-guard.sh")] | length')" = 1 ] \
  && pass "--days 60 takes the 40-day-old record" || fail "--days" ""

echo ""
echo "=== --total and --hook ==="
lat --total --json > "$TMP/tot.json"
[ "$(row PreToolUse:Bash git-guard.sh "$TMP/tot.json")" = '[[3,1800,3400,3400]]' ] \
  && pass "--total folds the days into one row" || fail "--total" "$(row PreToolUse:Bash git-guard.sh "$TMP/tot.json")"
[ "$(lat --hook session-start --json | jq -c '[.rows[].hook] | unique')" = '["session-start.sh"]' ] \
  && pass "--hook keeps only matching hooks" || fail "--hook" ""
[ "$(python3 "$REPO/tools/hook-latency.py" --projects "$TMP/none" --settings "$TMP/none.json" --json | jq -c '[.counted, (.rows|length)]')" = '[0,0]' ] \
  && pass "no transcripts: an empty report, exit 0" || fail "empty" ""

echo ""
echo "=== doctor.sh --latency passes its arguments through ==="
OUT=$(bash "$DOC/doctor.sh" --latency --projects "$P" --settings "$TMP/settings.json" --total --json 2>&1)
[ "$(printf '%s' "$OUT" | jq '.counted' 2>/dev/null)" = 13 ] && pass "doctor.sh --latency runs hook-latency.py" || fail "doctor --latency" "$OUT"

echo ""
echo "=== session-census.py: processes from ps, jobs from their folders ==="
cat > "$TMP/ps.txt" <<'PS'
  101 102400 /opt/homebrew/bin/claude daemon run --origin transient
  102  51200 claude bg-pty-host --bg-pty-host /tmp/x.pty.sock 200 50 -- /x/claude --bg-spare
  103 204800 claude bg-spare --bg-spare /tmp/x.claim.sock
  104 307200 /x/claude --session-id abc --agent claude
  105  10240 /usr/bin/vim claude.txt
  106  20480 /bin/zsh -c claude
PS
J="$TMP/jobs"
mkdir -p "$J/aaa" "$J/bbb" "$J/ccc" "$J/ddd"
echo '{"state": "working"}' > "$J/aaa/state.json"; : > "$J/aaa/timeline.jsonl"
echo '{"state": "done"}' > "$J/bbb/state.json"
echo '{"state": "blocked"}' > "$J/ccc/state.json"
python3 - "$J" <<'PY'
import os, sys, time
j = sys.argv[1]
old = time.time() - 20 * 3600
for p in ("aaa/state.json", "aaa/timeline.jsonl", "bbb/state.json"):
    os.utime(os.path.join(j, p), (old, old))
PY
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$J" 2>&1)
[[ "$OUT" == *"claude processes (ps): 4, 0.63 GB resident: "* ]] \
  && pass "four claude processes, 650 MB summed; vim and zsh with claude in their arguments are not counted" || fail "processes" "$OUT"
for r in "1 daemon" "1 pty host" "1 spare or session" "1 session"; do
  [[ "$OUT" == *"$r"* ]] || { fail "role $r" "$OUT"; continue; }
done
[[ "$OUT" == *"1 daemon"* && "$OUT" == *"1 pty host"* && "$OUT" == *"1 session"* ]] && pass "each process by its role" || true
[[ "$OUT" == *"background jobs ($J): 3: "* ]] && pass "three jobs; a folder with no state.json is skipped" || fail "job count" "$OUT"
[[ "$OUT" == *"not done and idle over 12 h: 1"* && "$OUT" == *"  aaa  working, last activity 20 h ago"* ]] \
  && pass "the working job quiet for 20 h is named; the old done job and the fresh blocked one are not" || fail "idle" "$OUT"
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$J" --idle-hours 24 2>&1)
[[ "$OUT" == *"idle over 24 h: 0"* ]] && pass "--idle-hours moves the line" || fail "--idle-hours" "$OUT"
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$TMP/nojobs" 2>&1)
[[ "$OUT" == *"background jobs: no $TMP/nojobs"* ]] && pass "no jobs folder says so" || fail "no jobs" "$OUT"
OUT=$(bash "$DOC/doctor.sh" --census --ps "$TMP/ps.txt" --jobs "$J" 2>&1)
[[ "$OUT" == *"claude processes (ps): 4"* ]] && pass "doctor.sh --census runs session-census.py" || fail "doctor --census" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
