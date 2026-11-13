#!/usr/bin/env python3
"""Hook wall times from Claude Code's own transcripts: n, p50, p95 and max per hook per day.

Claude Code writes a hook record (an attachment with durationMs) only when the hook printed
something or failed. A guard that allowed in silence leaves none, so n counts the runs that
answered, and the report says how many records it read and which it could not count.

A record from Claude Code 2.1.319 on names its hook only as "command hook N", read here through
settings.json as it is now (hooknames.py), so a record from before a settings change can be misnamed.

  tools/hook-latency.py                      last 30 days, per hook per day
  tools/hook-latency.py --days 8 --total     one row per hook for the window
  tools/hook-latency.py --hook session-start
  bash doctor.sh --latency [ARGS]            the same

hooks/bash-guards.sh runs the seven Bash guards as one hook, so its record is one row. Its
timing log has each guard's seconds for every call, answered or not; the second table reads it,
dated by joining each line's tool_use_id to the call in the transcripts. Those seconds are wall
time with the seven running at once, so they overstate a guard's own cost.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import sys


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # hooknames.py, also when loaded by path
from hooknames import label, numbered, read_timing, settings_hooks

HOME = os.path.expanduser("~")


def pct(xs, p):
    """Nearest rank on a sorted list."""
    k = max(0, min(len(xs) - 1, -(-len(xs) * p // 100) - 1))
    return xs[k]


def fmt(ms):
    return f"{ms:.0f} ms" if ms < 1000 else f"{ms / 1000:.1f} s"


def parse_ts(s):
    try:
        return dt.datetime.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=float, default=30)
    ap.add_argument("--projects", default=os.path.join(HOME, ".claude", "projects"))
    ap.add_argument("--settings", default=os.path.join(HOME, ".claude", "settings.json"))
    ap.add_argument("--total", action="store_true", help="one row per hook for the whole window")
    ap.add_argument("--hook", default="", help="only hooks whose event or name contains this")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--timing-log", default=None, help="bash-guards' timing log (default $CLAUDE_GUARD_TIMING_LOG or ~/.claude/logs/guard-timing.log)")
    a = ap.parse_args()

    now = dt.datetime.now(dt.timezone.utc)
    cut = now - dt.timedelta(days=a.days)
    hooks = settings_hooks(a.settings)
    files = glob.glob(os.path.join(a.projects, "*", "*.jsonl")) + glob.glob(os.path.join(a.projects, "*", "*", "subagents", "*.jsonl"))
    # A file last written before the window holds nothing in it; each record is still
    # judged by its own timestamp, since a resumed transcript spans months.
    files = [f for f in files if os.path.getmtime(f) >= cut.timestamp()]
    runs = collections.defaultdict(list)
    skipped = collections.Counter()
    counted = 0
    any_nth = False
    timing = read_timing(a.timing_log)
    called = {}   # tool_use_id in the timing log -> when the transcript says the call was made
    first = last = None
    for f in files:
        try:
            fh = open(f, errors="replace")
        except OSError:
            continue
        with fh:
            for ln in fh:
                use = timing and '"tool_use"' in ln and '"assistant"' in ln
                if not use and ('"attachment"' not in ln or '"hook' not in ln):
                    continue
                try:
                    d = json.loads(ln)
                except ValueError:
                    continue
                if use:
                    for c in (d.get("message") or {}).get("content") or []:
                        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("id") in timing:
                            called[c["id"]] = parse_ts(d.get("timestamp"))
                    continue
                at = d.get("attachment") or {}
                kind = str(at.get("type", ""))
                if not kind.startswith("hook") or not at.get("hookName"):
                    continue
                t = parse_ts(d.get("timestamp"))
                if t is None or t < cut:
                    continue
                name = str(at["hookName"])
                hook = label(at.get("command", ""), name.split(":")[0], hooks)
                if a.hook and a.hook not in name and a.hook not in hook:
                    continue
                ms = at.get("durationMs")
                if not isinstance(ms, (int, float)):
                    skipped[kind] += 1
                    continue
                counted += 1
                any_nth = any_nth or numbered(at.get("command", ""))
                first = min(first or t, t)
                last = max(last or t, t)
                day = "" if a.total else t.strftime("%Y-%m-%d")
                runs[(day, name, hook)].append(ms)

    rows = []
    for (day, name, hook), xs in runs.items():
        xs.sort()
        rows.append(dict(day=day, event=name, hook=hook, n=len(xs), p50=pct(xs, 50), p95=pct(xs, 95), max=xs[-1]))
    rows.sort(key=lambda r: (r["day"], -r["p95"]) if not a.total else (-r["p95"], r["event"]))

    # Each Bash guard inside bash-guards: every call, from the timing log, dated by the transcript.
    per = collections.defaultdict(list)
    failed = collections.Counter()
    in_window = 0
    for uid, guards in timing.items():
        t = called.get(uid)
        if t is None or t < cut:
            continue
        in_window += 1
        for g, secs, status, _ in guards:
            if a.hook and a.hook not in g and a.hook not in "bash-guards":
                continue
            key = ("" if a.total else t.strftime("%Y-%m-%d"), g)
            if status != "0":
                failed[key] += 1
            if secs is not None:
                per[key].append(secs * 1000)
    grows = []
    for (day, g), xs in per.items():
        xs.sort()
        grows.append(dict(day=day, guard=g, n=len(xs), p50=pct(xs, 50), p95=pct(xs, 95), max=xs[-1], not_zero=failed[(day, g)]))
    grows.sort(key=lambda r: (r["day"], -r["p95"]) if not a.total else (-r["p95"], r["guard"]))
    undated = sum(1 for uid in timing if uid not in called)

    if a.json:
        json.dump(dict(transcripts=len(files), counted=counted, not_counted=dict(skipped), rows=rows,
                       timing=dict(lines=len(timing), in_window=in_window, no_call_found=undated), guards=grows), sys.stdout, indent=1)
        print()
        return 0
    span = f"{first:%Y-%m-%d} to {last:%Y-%m-%d}" if first else "no records"
    print(f"Hook wall time (durationMs) from {len(files)} transcripts under {a.projects}, last {a.days:g} days: {span}, UTC days.")
    nc = ", ".join(f"{v} {k}" for k, v in skipped.most_common()) or "none"
    print(f"Counted {counted} hook records. Not counted, no durationMs: {nc}.")
    print("Claude Code records a hook only when it printed output or failed, so n counts the runs that answered, not every run.")
    if any_nth:
        print(f"\"command hook N\" is named through {a.settings} as it is now.")
    if rows:
        w = max(len(r["hook"]) for r in rows)
        e = max(len(r["event"]) for r in rows)
        print()
        print(("" if a.total else f"{'day':<11} ") + f"{'event':<{e}}  {'hook':<{w}}  {'n':>5}  {'p50':>7}  {'p95':>7}  {'max':>7}")
        for r in rows:
            print(("" if a.total else f"{r['day']:<11} ") + f"{r['event']:<{e}}  {r['hook']:<{w}}  {r['n']:>5}  {fmt(r['p50']):>7}  {fmt(r['p95']):>7}  {fmt(r['max']):>7}")
    if timing:
        print()
        print(f"Bash guards inside bash-guards, from its timing log: {len(timing)} calls logged, {in_window} in the window, "
              f"{undated} with no call found in these transcripts. Every call counts, answered or not; the seconds")
        print("are each guard's wall time with the seven running at once, so they overstate its own cost.")
        if grows:
            w = max(len(r["guard"]) for r in grows)
            print(("" if a.total else f"{'day':<11} ") + f"{'guard':<{w}}  {'n':>5}  {'p50':>7}  {'p95':>7}  {'max':>7}  {'not 0':>5}")
            for r in grows:
                print(("" if a.total else f"{r['day']:<11} ") + f"{r['guard']:<{w}}  {r['n']:>5}  {fmt(r['p50']):>7}  {fmt(r['p95']):>7}  {fmt(r['max']):>7}  {r['not_zero']:>5}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
