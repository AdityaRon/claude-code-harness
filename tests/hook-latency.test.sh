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
# (a repeat, not counted) and plan (5). Counting the repeat would make 5 config-guard.
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

lat() { python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TMP/no-timing.log" "$@"; }
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
  && pass "hook 3 on Edit is config-guard, its first place" || fail "first place" "$(jq -c '.rows' "$TMP/day.json")"
[ "$(row PreToolUse:Edit plan.sh "$TMP/day.json")" = '[[1,61,61,61]]' ] \
  && pass "a repeated command is counted once: hook 5 is plan.sh, past the repeat" || fail "repeat" "$(jq -c '[.rows[].hook]' "$TMP/day.json")"
[ "$(row PreToolUse:Bash 'hook 9' "$TMP/day.json")" = '[[1,62,62,62]]' ] \
  && pass "a number past the settings stays a number" || fail "out of range" "$(jq -c '[.rows[].hook]' "$TMP/day.json")"

touch "$TMP/settings.json"
lat --days 7 > "$TMP/now.txt"
touch -t 200001010000 "$TMP/settings.json"
lat --days 7 > "$TMP/old.txt"
grep -q 'inside the window: a numbered record from before then may be named for the hook now at its number' "$TMP/now.txt" \
  && ! grep -q 'inside the window' "$TMP/old.txt" \
  && pass "a settings.json changed inside the window is named as a reason a number may mislead" || fail "changed caveat" "$(grep -c window "$TMP/now.txt") $(grep -c window "$TMP/old.txt")"
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
[ "$(jq -c '.numbered' "$TMP/day.json")" = '{"from_output":0,"from_map":7}' ] \
  && [ "$(jq -c '[.rows[] | select(.hook == "git-guard.sh") | .unconfirmed] | unique' "$TMP/day.json")" = '[true]' ] \
  && pass "a numbered record with no reason on stdout is named by the map, and its row is unconfirmed" || fail "unconfirmed" "$(jq -c '{numbered, rows: [.rows[] | {hook, unconfirmed}]}' "$TMP/day.json")"
[[ "$TXT" == *"git-guard.sh ?"* && "$TXT" == *"7 records name their hook only as \"command hook N\": 0 are named by the guard"*"7 by their number, marked ?"* ]] \
  && pass "the text marks an unconfirmed row ? and counts how each numbered record was named" || fail "? in text" "$TXT"

echo ""
echo "=== a numbered record is named by the reason on its own stdout, never its stderr ==="
P2="$TMP/projects2"; mkdir -p "$P2/proj"; T2="$P2/proj/s.jsonl"
# orec HOOKNAME COMMAND MS STDOUT_REASON STDERR: one hook_success record in $T2.
orec() {
  python3 - "$T2" "$@" <<'PY'
import datetime as dt, json, sys
f, name, cmd, ms, why, err = sys.argv[1:7]
t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)
out = json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": why}}) if why else ""
at = {"type": "hook_success", "hookName": name, "hookEvent": name.split(":")[0], "command": cmd, "toolUseID": "t",
      "durationMs": int(ms), "exitCode": 0, "stdout": out, "stderr": err, "content": ""}
with open(f, "a") as fh:
    fh.write(json.dumps({"type": "attachment", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "attachment": at}) + "\n")
PY
}
# Words from hooks/network-guard.sh; the stderr line is bash's, and holds
# "Operation not permitted", which hooks/tcc-check.sh quotes.
NET="curl/wget request to example.invalid is outside the default allowlist. Confirm this endpoint is safe."
SHELLINIT="shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted"
orec PreToolUse:Bash "command hook 3" 410 "$NET" ""          # today's hook 3 on Bash is config-guard
orec PreToolUse:WebFetch "command hook 3" 420 "$NET" ""      # not a call bash-guards runs on
orec PreToolUse:Bash "command hook 3" 430 "" "$SHELLINIT"
orec PreToolUse:Bash "command hook 1" 440 "$SHELLINIT" ""    # the same words on stdout: tcc-check's, as a control
L2=$(python3 "$REPO/tools/hook-latency.py" --projects "$P2" --settings "$TMP/settings.json" --timing-log "$TMP/no-timing.log" --total --json)
orow() { jq -c --arg e "$1" --arg h "$2" '[.rows[] | select(.event == $e and .hook == $h)] | map([.n, .max, .unconfirmed])' <<<"$L2"; }
[ "$(orow PreToolUse:Bash 'bash-guards.sh (network-guard)')" = '[[1,410,false]]' ] \
  && pass "network-guard's reason on a Bash call is the bash-guards (network-guard) row, though settings.json says config-guard" \
  || fail "named from output" "$(jq -c '[.rows[] | {event, hook, max, unconfirmed}]' <<<"$L2")"
[ "$(orow PreToolUse:WebFetch network-guard.sh)" = '[[1,420,false]]' ] \
  && pass "on a tool bash-guards does not run on, it is network-guard's own row" || fail "WebFetch" "$(jq -c '[.rows[] | {event, hook}]' <<<"$L2")"
[ "$(jq -c '[.rows[] | select(.hook | test("tcc-check")) | [.n, .max]]' <<<"$L2")" = '[[1,440]]' ] && [ "$(orow PreToolUse:Bash config-guard.sh)" = '[[1,430,true]]' ] \
  && pass "a shell-init line on stderr is not named tcc-check, so the map names it; on stdout it is tcc-check's" || fail "stderr" "$(jq -c '[.rows[] | {hook, n, max}]' <<<"$L2")"
[ "$(jq -c '.numbered' <<<"$L2")" = '{"from_output":3,"from_map":1}' ] \
  && pass "3 named from output, 1 by the map" || fail "named counts" "$(jq -c '.numbered' <<<"$L2")"
rm "$T2"; orec PreToolUse:Bash "command hook 3" 410 "$NET" ""
TXT2=$(python3 "$REPO/tools/hook-latency.py" --projects "$P2" --settings "$TMP/settings.json" --timing-log "$TMP/no-timing.log" --total 2>&1)
[[ "$TXT2" == *"1 are named by the guard"*"0 by their number."* && "$TXT2" != *"is named through"* && "$TXT2" != *"?"* ]] \
  && pass "with every numbered record named from output, no settings caveat and no ?" || fail "no caveat" "$TXT2"

echo ""
echo "=== each Bash guard inside bash-guards, from its timing log, dated by the transcript ==="
use() {   # use FILE DAYS_AGO ID: the assistant record of one Bash call
  python3 - "$@" <<'PY'
import datetime as dt, json, sys
f, ago, uid = sys.argv[1:4]
t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=float(ago))
with open(f, "a") as fh:
    fh.write(json.dumps({"type": "assistant", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                         "message": {"content": [{"type": "tool_use", "id": uid, "name": "Bash", "input": {"command": "ls"}}]}}) + "\n")
PY
}
use "$T" 1 g1; use "$T" 1 g2; use "$T" 40 g3
TL="$TMP/timing.log"
printf 'g1\tBash\tgit-guard=0.020:0:allow\trm-guard=0.010:0:allow\tkubectl-guard=-:lost:deny\tbad=0.5\n' > "$TL"
printf 'g2\tBash\tgit-guard=0.040:0:ask\trm-guard=-:lost:deny\n' >> "$TL"
printf 'g3\tBash\tgit-guard=0.900:0:allow\n' >> "$TL"
printf 'g4\tBash\tgit-guard=0.900:0:allow\n' >> "$TL"
G=$(python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TL" --total --json)
grow() { jq -c --arg g "$1" '[.guards[] | select(.guard == $g)] | map([.n, (.p50|round), (.p95|round), (.max|round), .not_zero])' <<<"$G"; }
[ "$(grow git-guard)" = '[[2,20,40,40,0]]' ] \
  && pass "git-guard: two calls in the window, 20 and 40 ms" || fail "git-guard in bash-guards" "$(grow git-guard)"
[ "$(grow rm-guard)" = '[[2,10,10,10,1]]' ] \
  && pass "rm-guard: two runs, one lost: no seconds for it, and it counts as not 0" || fail "rm-guard in bash-guards" "$(grow rm-guard)"
[ "$(jq -c '[.guards[] | select(.guard == "kubectl-guard")] | map([.n, .p50, .not_zero])' <<<"$G")" = '[[1,null,1]]' ] \
  && pass "a guard lost every time keeps its row" || fail "always lost" "$(jq -c '.guards' <<<"$G")"
[ "$(jq -c '[.guards[] | select(.guard == "bad")] | length' <<<"$G")" = 0 ] \
  && pass "a column the hook never writes is skipped, not counted as a failure" || fail "malformed column" "$(jq -c '.guards' <<<"$G")"
[ "$(jq -c '.timing' <<<"$G")" = '{"lines":4,"in_window":2,"no_call_found":1,"dated_by_at":0}' ] \
  && pass "a call older than --days is left out; a line with no call in the transcripts is counted apart" || fail "timing counts" "$(jq -c '.timing' <<<"$G")"
[ "$(python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TL" --total --hook rm-guard --json | jq -c '[.guards[].guard]')" = '["rm-guard"]' ] \
  && pass "--hook keeps one guard" || fail "--hook on guards" ""
TXT=$(python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TL" --total 2>&1)
[[ "$TXT" == *"wall time with the seven running at once"* && "$TXT" == *"4 calls logged, 2 in the window (0 dated by their at= column"*"1 with no at= and no call found"* ]] \
  && pass "the text says what the seconds are and what was left out" || fail "guard table text" "$TXT"
[ "$(jq -c '[(.guards | length), .timing.lines]' "$TMP/day.json")" = '[0,0]' ] \
  && pass "no timing log: no guard rows" || fail "no timing log" "$(jq -c '.timing' "$TMP/day.json")"

echo ""
echo "=== a timing line's at= dates it; the timing table comes first ==="
# g5 and g6 are in no transcript: their at= dates them. g6's is 40 days old. g1 to g4
# are the lines above, which have no at= and are dated through the transcripts as before.
TL2="$TMP/timing2.log"; cp "$TL" "$TL2"
NOW=$(date +%s)
printf 'g5\tBash\tgit-guard=0.070:0:allow\tat=%s\n' "$((NOW - 86400))" >> "$TL2"
printf 'g6\tBash\tgit-guard=0.080:0:allow\tat=%s\n' "$((NOW - 40 * 86400))" >> "$TL2"
G2=$(python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TL2" --total --json)
[ "$(jq -c '.timing' <<<"$G2")" = '{"lines":6,"in_window":3,"no_call_found":1,"dated_by_at":1}' ] \
  && pass "an at= line in the window counts with no call in the transcripts; one older than --days does not" \
  || fail "at= dating" "$(jq -c '.timing' <<<"$G2")"
[ "$(jq -c '[.guards[] | select(.guard == "git-guard")] | map([.n, (.max|round)])' <<<"$G2")" = '[[3,70]]' ] \
  && pass "git-guard: the two old-format lines and the at= one, 20, 40 and 70 ms" || fail "at= row" "$(jq -c '.guards' <<<"$G2")"
TXT3=$(python3 "$REPO/tools/hook-latency.py" --projects "$P" --settings "$TMP/settings.json" --timing-log "$TL2" --total 2>&1)
ORDER=$(printf '%s\n' "$TXT3" | grep -nE '^Bash guards inside bash-guards|^A tool call.s hooks run together|^Hook wall time' | cut -d: -f2- | cut -c1-12 | tr '\n' '|')
[ "$ORDER" = "Bash guards |A tool call'|Hook wall ti|" ] \
  && pass "the timing-log table, then the line on hooks running together, then the transcript table" || fail "order" "$ORDER"
[[ "$TXT3" == *"A tool call's hooks run together, so it waits for its slowest hook: on Bash, bash-guards' fixed start plus its slowest guard, or subagent-cache-guard, which runs alongside."* ]] \
  && pass "the line says a call costs its slowest hook" || fail "together line" "$TXT3"
[[ "$(lat --total 2>&1)" == *"A tool call's hooks run together"* ]] && pass "the line is there with no timing log too" || fail "together line, no log" ""

echo ""
echo "=== a week whose hook records fall under a tenth of the weeks before is flagged ==="
# Monday-to-Monday UTC weeks from --since, six full ones before this week: 20, 20, 3
# (15% of 20: not flagged), 20, 0 (flagged: a week with none is still a week) and 1
# (flagged, against the median of 20, 20, 3, 20 and 0).
P3="$TMP/projects3"; mkdir -p "$P3/proj"
SINCE=$(python3 - "$P3/proj/w.jsonl" <<'PY2'
import datetime as dt, json, sys
now = dt.datetime.now(dt.timezone.utc)
mon = (now - dt.timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0) - dt.timedelta(weeks=6)
with open(sys.argv[1], "w") as fh:
    for wk, n in enumerate([20, 20, 3, 20, 0, 1]):
        for i in range(n):
            t = mon + dt.timedelta(weeks=wk, days=3, minutes=i)
            at = {"type": "hook_success", "hookName": "PreToolUse:Bash", "command": "~/.claude/hooks/x.sh", "durationMs": 5}
            fh.write(json.dumps({"type": "attachment", "timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "attachment": at}) + "\n")
print(mon.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY2
)
W=$(python3 "$REPO/tools/hook-latency.py" --projects "$P3" --settings "$TMP/settings.json" --timing-log "$TMP/no-timing.log" --since "$SINCE" --json)
[ "$(jq -c '[.weeks[:6][] | [.records, .flagged]]' <<<"$W")" = '[[20,false],[20,false],[3,false],[20,false],[0,true],[1,true]]' ] \
  && pass "20, 20, 3 and 20 pass; the week with none and the week with 1 are flagged" || fail "weeks" "$(jq -c '.weeks' <<<"$W")"
[ "$(jq -c '[.weeks[:6][] | .prior_median]' <<<"$W")" = '[null,null,20,20,20,20]' ] \
  && pass "no week is judged on fewer than two before it; then the median of those before" || fail "median" "$(jq -c '[.weeks[].prior_median]' <<<"$W")"
TXTW=$(python3 "$REPO/tools/hook-latency.py" --projects "$P3" --settings "$TMP/settings.json" --timing-log "$TMP/no-timing.log" --since "$SINCE" 2>&1)
WK5=$(jq -r '.weeks[5].week' <<<"$W")
[[ "$TXTW" == *"Week of $WK5: 1 hook records"*"under 10% of the prior weeks' median of 20"* && "$TXTW" == *"since ${SINCE:0:10} 00:00 UTC"* ]] \
  && pass "the text names the flagged week and the window it read" || fail "week text" "$TXTW"
# weeks() on a fixed clock: the window opens on a Sunday and closes on a Tuesday, so the
# first and last weeks have one day each and no record. Neither is judged or a baseline:
# the full weeks hold 50 and then 2, and one week before the 2 is too few to judge it on.
PW=$(python3 - "$REPO/tools/hook-latency.py" <<'PY2'
import datetime as dt, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("hl", sys.argv[1]); hl = importlib.util.module_from_spec(spec); spec.loader.exec_module(hl)
u = dt.timezone.utc
out = hl.weeks({"2026-10-05": 50, "2026-10-12": 2}, dt.datetime(2026, 10, 4, tzinfo=u), dt.datetime(2026, 10, 20, tzinfo=u))
print(json.dumps([[w["week"], w["days"], w["flagged"]] for w in out]))
PY2
)
[ "$PW" = '[["2026-09-28", 1.0, false], ["2026-10-05", 7.0, false], ["2026-10-12", 7.0, false], ["2026-10-19", 1.0, false]]' ] \
  && pass "a week with under two days in the window is neither judged nor a baseline" \
  || fail "partial weeks" "$PW"

echo ""
echo "=== --since is --days from a time of day ==="
SEVEN=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
A=$(lat --days 7 --total --timing-log "$TL" --json | jq -c 'del(.weeks)')
B=$(lat --since "$SEVEN" --total --timing-log "$TL" --json | jq -c 'del(.weeks)')
[ -n "$A" ] && [ "$A" = "$B" ] && pass "--since a week ago reads what --days 7 reads" || fail "--since = --days" "$A vs $B"
ONE=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=36)).strftime("%Y-%m-%dT%H:%M:%S"))')
# Under UTC+14 a time with no zone read as local would start 14 hours earlier, and take it in.
[ "$(TZ=Etc/GMT-14 lat --since "$ONE" --total --json | jq -c '[.rows[] | select(.hook == "git-guard.sh") | .n, .max]')" = '[2,3400]' ] \
  && pass "a record from before --since is left out (git-guard's 2-day-old 900 ms), and no zone is UTC" || fail "--since cut" "$(lat --since "$ONE" --total --json | jq -c '.rows')"
lat --days 7 --since "$SEVEN" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "--days and --since together: a usage error" || fail "exclusive" "rc=$RC"

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
  107   8192 /Users/u/.local/share/claude/versions/2.1.330 -p restart the daemon
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
[[ "$OUT" != *"vim"* && "$OUT" != *"zsh"* ]] \
  && pass "vim and zsh with claude in their arguments are not counted" || fail "processes" "$OUT"
MISSING=""; for r in "1 daemon" "1 pty host" "1 spare or session" "1 session" "1 other"; do [[ "$OUT" == *"$r"* ]] || MISSING="$MISSING [$r]"; done
[ -z "$MISSING" ] && pass "each process by its role; a prompt saying daemon is not one" || fail "roles" "missing$MISSING in $OUT"
[[ "$OUT" == *"claude processes (ps): 5, 0.64 GB resident"* ]] \
  && pass "a native install named by its version counts" || fail "native install" "$OUT"
[[ "$OUT" == *"background jobs ($J): 3: "* ]] && pass "three jobs; a folder with no state.json is skipped" || fail "job count" "$OUT"
[[ "$OUT" == *"not done and idle over 12 h: 1"* && "$OUT" == *"  aaa  working, last activity 20 h ago"* ]] \
  && pass "the working job quiet for 20 h is named; the old done job and the fresh blocked one are not" || fail "idle" "$OUT"
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$J" --idle-hours 24 2>&1)
[[ "$OUT" == *"idle over 24 h: 0"* ]] && pass "--idle-hours moves the line" || fail "--idle-hours" "$OUT"
OUT=$(python3 "$REPO/tools/session-census.py" --ps "$TMP/ps.txt" --jobs "$TMP/nojobs" 2>&1)
[[ "$OUT" == *"background jobs: no $TMP/nojobs"* ]] && pass "no jobs folder says so" || fail "no jobs" "$OUT"
OUT=$(bash "$DOC/doctor.sh" --census --ps "$TMP/ps.txt" --jobs "$J" 2>&1)
[[ "$OUT" == *"claude processes (ps): 5"* ]] && pass "doctor.sh --census runs session-census.py" || fail "doctor --census" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
