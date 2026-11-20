#!/usr/bin/env python3
"""Hook wall times from Claude Code's own transcripts: n, p50, p95 and max per hook per day.

Claude Code writes a hook record (an attachment with durationMs) only when the hook printed
something or failed. A guard that allowed in silence leaves none, so n counts the runs that
answered, and the report says how many records it read and which it could not count.

A record from Claude Code 2.1.319 on names its hook only as "command hook N". The guard whose words
are in the decision reason on its own stdout names it, never its stderr (hooknames.py). One with no
such reason is named through settings.json as it is now and marked ?: a record from before a settings
change can be named for the hook now at its number.

  bin/hook-latency.py                      last 30 days, per hook per day
  bin/hook-latency.py --days 8 --total     one row per hook for the window
  bin/hook-latency.py --since 2026-10-19   from that day on (UTC), in place of --days
  bin/hook-latency.py --hook session-start
  bash doctor.sh --latency [ARGS]            the same

hooks/bash-guards.sh runs the seven Bash guards as one hook, so a numbered record on a Bash or
Monitor call that one of them answered is on a "bash-guards.sh (<guard>)" row. A record from before
bash-guards was installed, when each guard was its own hook, lands there too, though its time is
that guard's alone. Its timing log has each guard's seconds for every call, answered or not, and
does not depend on Claude Code writing a record, so its table comes first. A line is dated by its
at= epoch, or, on a line from before that column, by joining its tool_use_id to the call in the
transcripts. Those seconds are wall time with the seven running at once, so they overstate a
guard's own cost.

A week whose hook records fall under a tenth of the prior weeks' median is flagged: one machine's
went from about 8,000 a week to about 200 from 2026-10-19, and the transcript table undercounts
from such a week on.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import sys


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # hooknames.py, also when loaded by path
from hooknames import GuardReasons, add_window, bash_guards, label, name_from_output, numbered, read_timing, settings_hooks, window

HOME = os.path.expanduser("~")
BASH_GUARDS_ON = ("Bash", "Monitor")   # bash-guards' matcher in config/settings.json
DROP = 0.10        # a week under this share of the prior weeks' median is flagged
WEEK_MIN_DAYS = 2  # a week with fewer days in the window is neither judged nor a baseline
# Claude Code starts a call's hooks together and waits for all of them: two PreToolUse
# command hooks on one Bash call started 15 us apart and both ended 2.07 s later, each
# sleeping 2 s (headless probe, Claude Code 2.1.327, the maintainer's Mac).
TOGETHER = ("A tool call's hooks run together, so it waits for its slowest hook: on Bash, bash-guards' "
            "fixed start plus its slowest guard, or subagent-cache-guard, which runs alongside.")


def pct(xs, p):
    """Nearest rank on a sorted list."""
    k = max(0, min(len(xs) - 1, -(-len(xs) * p // 100) - 1))
    return xs[k]


def fmt(ms):
    if ms is None:
        return "-"
    return f"{ms:.0f} ms" if ms < 1000 else f"{ms / 1000:.1f} s"


def parse_ts(s):
    try:
        return dt.datetime.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def weeks(counts, start, now):
    """Every Monday-to-Monday UTC week the window touches, zero-record weeks too: (week, days
    in the window, records, per 7 days, prior median, flagged). A week's records are scaled to
    7 days by its days in the window. One with fewer than WEEK_MIN_DAYS is not judged and is no
    baseline; a judged week is flagged when it is under DROP of the median of at least two
    judged weeks before it."""
    out, prior = [], []
    wk = (start - dt.timedelta(days=start.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    while wk < now:
        nxt = wk + dt.timedelta(days=7)
        days = (min(nxt, now) - max(wk, start)).total_seconds() / 86400
        n = counts.get(wk.strftime("%Y-%m-%d"), 0)
        rate = n / days * 7 if days > 0 else 0.0
        judged = days >= WEEK_MIN_DAYS
        med = sorted(prior)[len(prior) // 2] if len(prior) % 2 else (sum(sorted(prior)[len(prior) // 2 - 1:len(prior) // 2 + 1]) / 2 if prior else None)
        flag = bool(judged and len(prior) >= 2 and med and rate < DROP * med)
        out.append(dict(week=wk.strftime("%Y-%m-%d"), days=round(days, 2), records=n, per_week=round(rate),
                        prior_median=None if med is None or len(prior) < 2 else round(med), flagged=flag))
        if judged:
            prior.append(rate)
        wk = nxt
    return out


def output_hook(at, tool, reasons, bg):
    """The hook whose guard wrote the record's own stdout reason, or None."""
    gs = name_from_output(at, reasons)
    if not gs:
        return None
    if gs <= bg and tool in BASH_GUARDS_ON:
        return f"bash-guards.sh ({'+'.join(sorted(gs))})"
    return f"{next(iter(gs))}.sh" if len(gs) == 1 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    add_window(ap, 30)
    ap.add_argument("--projects", default=os.path.join(HOME, ".claude", "projects"))
    ap.add_argument("--settings", default=os.path.join(HOME, ".claude", "settings.json"))
    ap.add_argument("--total", action="store_true", help="one row per hook for the whole window")
    ap.add_argument("--hook", default="", help="only hooks whose event or name contains this")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--timing-log", default=None, help="bash-guards' timing log (default $CLAUDE_GUARD_TIMING_LOG or ~/.claude/logs/guard-timing.log)")
    a = ap.parse_args()

    now = dt.datetime.now(dt.timezone.utc)
    cut, span_words = window(a, now)
    hooks = settings_hooks(a.settings)
    files = glob.glob(os.path.join(a.projects, "*", "*.jsonl")) + glob.glob(os.path.join(a.projects, "*", "*", "subagents", "*.jsonl"))
    # A file last written before the window holds nothing in it; each record is still
    # judged by its own timestamp, since a resumed transcript spans months.
    files = [f for f in files if os.path.getmtime(f) >= cut.timestamp()]
    runs = collections.defaultdict(list)
    skipped = collections.Counter()
    counted = 0
    named = collections.Counter()   # numbered records: named from their output, or by the map
    reasons, bg = GuardReasons(), bash_guards()
    stamps = {}   # tool_use_id -> the at= epoch on its timing line
    timing = read_timing(a.timing_log, stamps)
    unstamped = {uid for uid in timing if uid not in stamps}
    called = {}   # tool_use_id on a line with no at= -> when the transcript says the call was made
    per_week = collections.Counter()   # hook records in the window by Monday, before --hook
    first = last = None
    for f in files:
        try:
            fh = open(f, errors="replace")
        except OSError:
            continue
        with fh:
            for ln in fh:
                use = unstamped and '"tool_use"' in ln and '"assistant"' in ln
                if not use and ('"attachment"' not in ln or '"hook' not in ln):
                    continue
                try:
                    d = json.loads(ln)
                except ValueError:
                    continue
                if use:
                    for c in (d.get("message") or {}).get("content") or []:
                        t = parse_ts(d.get("timestamp"))
                        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("id") in unstamped and t:
                            called[c["id"]] = t
                    continue
                at = d.get("attachment") or {}
                kind = str(at.get("type", ""))
                if not kind.startswith("hook") or not at.get("hookName"):
                    continue
                t = parse_ts(d.get("timestamp"))
                if t is None or t < cut:
                    continue
                per_week[(t - dt.timedelta(days=t.weekday())).strftime("%Y-%m-%d")] += 1
                name = str(at["hookName"])
                event, _, tool = name.partition(":")
                cmd = at.get("command", "")
                hook, by = label(cmd, event, hooks), None
                if numbered(cmd):
                    found = output_hook(at, tool, reasons, bg)
                    hook, by = (found, "output") if found else (hook, "map")
                if a.hook and a.hook not in name and a.hook not in hook:
                    continue
                ms = at.get("durationMs")
                if not isinstance(ms, (int, float)):
                    skipped[kind] += 1
                    continue
                counted += 1
                if by:
                    named[by] += 1
                first = min(first or t, t)
                last = max(last or t, t)
                day = "" if a.total else t.strftime("%Y-%m-%d")
                runs[(day, name, hook, by == "map")].append(ms)

    rows = []
    for (day, name, hook, unconfirmed), xs in runs.items():
        xs.sort()
        rows.append(dict(day=day, event=name, hook=hook, unconfirmed=unconfirmed, n=len(xs), p50=pct(xs, 50), p95=pct(xs, 95), max=xs[-1]))
    rows.sort(key=lambda r: (r["day"], -r["p95"]) if not a.total else (-r["p95"], r["event"]))

    # Each Bash guard inside bash-guards: every call, from the timing log, dated by the transcript.
    per = collections.defaultdict(list)
    ran = collections.Counter()
    failed = collections.Counter()
    in_window = 0
    by_at = 0
    for uid, guards in timing.items():
        t = dt.datetime.fromtimestamp(stamps[uid], dt.timezone.utc) if uid in stamps else called.get(uid)
        if t is None or t < cut:
            continue
        by_at += uid in stamps
        in_window += 1
        for g, secs, status, _ in guards:
            if a.hook and a.hook not in g and a.hook not in "bash-guards":
                continue
            key = ("" if a.total else t.strftime("%Y-%m-%d"), g)
            ran[key] += 1
            if status != "0":
                failed[key] += 1
            if secs is not None:
                per[key].append(secs * 1000)
    grows = []
    # n counts every run; a run whose answer was lost has no seconds, so a guard lost every
    # time still has its row, with no times and every run not 0.
    for (day, g), n in ran.items():
        xs = sorted(per.get((day, g), []))
        top = (lambda q: pct(xs, q)) if xs else (lambda q: None)
        grows.append(dict(day=day, guard=g, n=n, p50=top(50), p95=top(95), max=xs[-1] if xs else None, not_zero=failed[(day, g)]))
    grows.sort(key=lambda r: (r["day"], -(r["p95"] or 0)) if not a.total else (-(r["p95"] or 0), r["guard"]))
    undated = sum(1 for uid in timing if uid not in stamps and uid not in called)
    wks = weeks(per_week, cut, now)

    if a.json:
        json.dump(dict(transcripts=len(files), counted=counted, not_counted=dict(skipped),
                       numbered=dict(from_output=named["output"], from_map=named["map"]), rows=rows,
                       timing=dict(lines=len(timing), in_window=in_window, no_call_found=undated, dated_by_at=by_at),
                       guards=grows, weeks=wks), sys.stdout, indent=1)
        print()
        return 0
    if timing:
        print(f"Bash guards inside bash-guards, from its timing log: {len(timing)} calls logged, {in_window} in the window "
              f"({by_at} dated by their at= column, the rest by their call in the transcripts), "
              f"{undated} with no at= and no call found in these transcripts. Every call counts, answered or not; the seconds")
        print("are each guard's wall time with the seven running at once, so they overstate its own cost.")
        if grows:
            w = max(len(r["guard"]) for r in grows)
            print(("" if a.total else f"{'day':<11} ") + f"{'guard':<{w}}  {'n':>5}  {'p50':>7}  {'p95':>7}  {'max':>7}  {'not 0':>5}")
            for r in grows:
                print(("" if a.total else f"{r['day']:<11} ") + f"{r['guard']:<{w}}  {r['n']:>5}  {fmt(r['p50']):>7}  {fmt(r['p95']):>7}  {fmt(r['max']):>7}  {r['not_zero']:>5}")
        print()
    print(TOGETHER)
    print()
    span = f"{first:%Y-%m-%d} to {last:%Y-%m-%d}" if first else "no records"
    print(f"Hook wall time (durationMs) from {len(files)} transcripts under {a.projects}, {span_words}: {span}, UTC days.")
    nc = ", ".join(f"{v} {k}" for k, v in skipped.most_common()) or "none"
    print(f"Counted {counted} hook records. Not counted, no durationMs: {nc}.")
    print("Claude Code records a hook only when it printed output or failed, so n counts the runs that answered, not every run.")
    for w_ in wks:
        if w_["flagged"]:
            print(f"Week of {w_['week']}: {w_['records']} hook records ({w_['per_week']} a week over its {w_['days']:g} days in the window), "
                  f"under {DROP:.0%} of the prior weeks' median of {w_['prior_median']}. Claude Code wrote far fewer hook records, "
                  "or this machine was idle: the rows below undercount from that week; the timing-log table above does not depend on them.")
    if named["output"] or named["map"]:
        print(f"{named['output'] + named['map']} records name their hook only as \"command hook N\": {named['output']} are named by the guard "
              f"whose words are in the decision reason on their own stdout, {named['map']} by their number" + (", marked ?." if named["map"] else "."))
    if named["map"]:
        print(f"\"command hook N\" is named through {a.settings} as it is now.")
        try:
            changed = dt.datetime.fromtimestamp(os.path.getmtime(a.settings), dt.timezone.utc)
        except OSError:
            changed = None
        # An install rewrites it, and a hook added or dropped shifts every number after it.
        if changed and changed > cut:
            print(f"It changed at {changed:%Y-%m-%d %H:%M} UTC, inside the window: a numbered record from before then "
                  "may be named for the hook now at its number.")
    if rows:
        shown = lambda r: r["hook"] + (" ?" if r["unconfirmed"] else "")
        w = max(len(shown(r)) for r in rows)
        e = max(len(r["event"]) for r in rows)
        print()
        print(("" if a.total else f"{'day':<11} ") + f"{'event':<{e}}  {'hook':<{w}}  {'n':>5}  {'p50':>7}  {'p95':>7}  {'max':>7}")
        for r in rows:
            print(("" if a.total else f"{r['day']:<11} ") + f"{r['event']:<{e}}  {shown(r):<{w}}  {r['n']:>5}  {fmt(r['p50']):>7}  {fmt(r['p95']):>7}  {fmt(r['max']):>7}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
