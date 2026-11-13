#!/usr/bin/env python3
"""How many Claude Code processes and background jobs this machine holds, and their memory.

Two sources, reported apart because neither maps onto the other:
  - ps: every claude process and its resident memory, by role from its arguments. A spare is
    a process started ahead of a session; once claimed it is the session, and ps cannot tell.
  - ~/.claude/jobs/*/state.json: each background job's state, and its last activity (the newer
    of state.json and timeline.jsonl). A job that is not done and idle past --idle-hours is named.

  tools/session-census.py [--idle-hours 12]
  bash doctor.sh --census [ARGS]
"""
import argparse
import collections
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")


def ps_lines(path):
    if path:
        with open(path) as f:
            return f.read().splitlines()
    try:
        return subprocess.run(["ps", "-ax", "-o", "pid=,rss=,command="], capture_output=True, text=True, timeout=20).stdout.splitlines()
    except (OSError, subprocess.SubprocessError):
        return []


def role(args):
    a = " " + args + " "
    if " daemon " in a:
        return "daemon"
    if "--bg-pty-host" in a:
        return "pty host"
    if "--bg-spare" in a:
        return "spare or session"
    if "--session-id" in a:
        return "session"
    return "other"


def processes(lines):
    roles, rss = collections.Counter(), 0
    for ln in lines:
        parts = ln.split(None, 2)
        if len(parts) < 3 or not parts[1].isdigit():
            continue
        cmd = parts[2]
        exe = os.path.basename(cmd.split()[0])
        if exe not in ("claude", "claude.exe"):
            continue
        roles[role(cmd)] += 1
        rss += int(parts[1])
    return roles, rss


def jobs(root, idle_hours, now):
    status, idle = collections.Counter(), []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return None, []
    for j in names:
        st = os.path.join(root, j, "state.json")
        try:
            with open(st) as f:
                s = json.load(f)
        except (OSError, ValueError):
            continue
        k = str(s.get("state") or s.get("status") or "unknown")
        status[k] += 1
        seen = max(os.path.getmtime(p) for p in (st, os.path.join(root, j, "timeline.jsonl")) if os.path.exists(p))
        h = (now - seen) / 3600
        if k != "done" and h > idle_hours:
            idle.append((j, k, h))
    return status, idle


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--idle-hours", type=float, default=12)
    ap.add_argument("--jobs", default=os.path.join(HOME, ".claude", "jobs"))
    ap.add_argument("--ps", default="", help="read `ps -ax -o pid=,rss=,command=` output from this file")
    a = ap.parse_args()
    now = time.time()

    roles, rss = processes(ps_lines(a.ps))
    n = sum(roles.values())
    parts = ", ".join(f"{v} {k}" for k, v in roles.most_common())
    print(f"claude processes (ps): {n}, {rss / 1048576:.2f} GB resident" + (f": {parts}" if parts else ""))

    status, idle = jobs(a.jobs, a.idle_hours, now)
    if status is None:
        print(f"background jobs: no {a.jobs}")
        return 0
    parts = ", ".join(f"{v} {k}" for k, v in status.most_common())
    print(f"background jobs ({a.jobs}): {sum(status.values())}" + (f": {parts}" if parts else ""))
    print(f"not done and idle over {a.idle_hours:g} h: {len(idle)}")
    for j, k, h in sorted(idle, key=lambda x: -x[2]):
        print(f"  {j}  {k}, last activity {h:.0f} h ago")
    return 0


if __name__ == "__main__":
    sys.exit(main())
