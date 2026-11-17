#!/usr/bin/env python3
"""What Claude Code's job folders and Bazel's output bases hold on this machine. Reads only.

  disk-space.py report [--jobs DIR] [--json]   each job folder: size with tmp, tmp entries, activity
  disk-space.py bazel [--root DIR] [--json]    each Bazel output base: its workspace, size, server
  disk-space.py stamp [--out FILE]             the totals session-start warns from; harness-update.sh
                                               runs it once a day

Sizes come from one `du -k -d 1` over each root, so they are allocated space, and a GB is 10^9
bytes. A job is live when `claude agents --json --all` gives it a pid; when that command is
missing or fails, liveness is unknown, never "not live". state.json's own `state` field is shown
as reported and is not used for liveness. An output base's workspace counts as gone only when
stat says it does not exist: an unmounted /Volumes/<name>, or a path this process may not read
(a launchd job and ~/Desktop), is "unknown". CLAUDE_BAZEL_ROOT and CLAUDE_CLI_BIN override the
output root and the claude binary.
"""
import argparse
import errno
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
JOB_RE = re.compile(r"^[0-9a-f]{8}$")
GB = 1e9
DU_TIMEOUT = 900  # seconds per du: 11.8 s for 6 GB of job folders on an Apple M2


def user_name():
    return os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name


def default_bazel_root():
    """Bazel's own default --output_user_root, unless CLAUDE_BAZEL_ROOT names another."""
    if os.environ.get("CLAUDE_BAZEL_ROOT"):
        return os.environ["CLAUDE_BAZEL_ROOT"]
    if sys.platform == "darwin":
        return "/private/var/tmp/_bazel_" + user_name()
    return os.path.join(HOME, ".cache", "bazel", "_bazel_" + user_name())


def fmt(n):
    if n is None:
        return "?"
    if n >= GB:
        return "%.2f GB" % (n / GB)
    if n >= 1e6:
        return "%.1f MB" % (n / 1e6)
    return "%d KB" % (n // 1000)


def du_children(root, timeout=DU_TIMEOUT):
    """One `du -k -d 1 ROOT`: ({name: bytes} for each directory under ROOT, ROOT's total, note).

    du's last line, ROOT itself, is the terminal marker: without it the total is None. A du that
    exited non-zero with it (an unreadable folder) leaves a floor, and the note says so."""
    try:
        p = subprocess.run(["du", "-k", "-d", "1", root], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {}, None, "du timed out after %d s" % timeout
    except OSError as e:
        return {}, None, "du did not run: %s" % e
    sizes, total = {}, None
    for ln in p.stdout.splitlines():
        kb, _, path = ln.partition("\t")
        if not kb.isdigit():
            continue
        path = os.path.normpath(path)
        if path == root:
            total = int(kb) * 1024
        elif os.path.dirname(path) == root:
            sizes[os.path.basename(path)] = int(kb) * 1024
    if total is None:
        return sizes, None, "du exited %d with no total for %s" % (p.returncode, root)
    note = "" if p.returncode == 0 else "du exited %d (%s): sizes are a floor" % (
        p.returncode, (p.stderr.strip().splitlines() or ["no message"])[0])
    return sizes, total, note


def claude_agents():
    """({job id: pid or None}, "") from `claude agents --json --all`, or (None, why) when unreadable."""
    exe = os.environ.get("CLAUDE_CLI_BIN") or shutil.which("claude")
    if not exe:
        return None, "no claude on PATH"
    try:
        p = subprocess.run([exe, "agents", "--json", "--all"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return None, "claude agents did not run: %s" % e
    if p.returncode != 0:
        return None, "claude agents exited %d" % p.returncode
    try:
        data = json.loads(p.stdout)
    except ValueError:
        return None, "claude agents printed no JSON"
    if not isinstance(data, list):
        return None, "claude agents printed no list"
    pids = {}
    for a in data:
        if isinstance(a, dict) and isinstance(a.get("id"), str):
            pid = a.get("pid")
            pids[a["id"]] = pid if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 else None
    return pids, ""


def lstat(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def kind(st):
    if st is None:
        return "missing"
    if stat.S_ISLNK(st.st_mode):
        return "symlink"
    if stat.S_ISDIR(st.st_mode):
        return "dir"
    if stat.S_ISREG(st.st_mode):
        return "file"
    return "other"


def is_job(root, name):
    """An 8-hex folder, not a link, holding a state.json file: what Claude Code makes."""
    if not JOB_RE.match(name) or kind(lstat(os.path.join(root, name))) != "dir":
        return False
    return kind(lstat(os.path.join(root, name, "state.json"))) == "file"


def activity(job_dir):
    """The newer mtime of state.json and timeline.jsonl."""
    ts = [st.st_mtime for st in (lstat(os.path.join(job_dir, f)) for f in ("state.json", "timeline.jsonl")) if st]
    return max(ts) if ts else None


def reported_state(job_dir):
    try:
        with open(os.path.join(job_dir, "state.json")) as f:
            s = json.load(f)
    except (OSError, ValueError):
        return "?"
    return str(s.get("state") or s.get("status") or "?") if isinstance(s, dict) else "?"


def tmp_summary(job_dir, now):
    """What tmp is, how many top-level entries it holds, and the oldest and newest entry's own mtime."""
    tmp = os.path.join(job_dir, "tmp")
    k = kind(lstat(tmp))
    out = {"tmp": k, "tmp_entries": None, "oldest_entry_days": None, "newest_entry_days": None}
    if k != "dir":
        return out
    try:
        names = os.listdir(tmp)
    except OSError:
        return out
    ages = [(now - st.st_mtime) / 86400 for st in (lstat(os.path.join(tmp, n)) for n in names) if st]
    out["tmp_entries"] = len(names)
    if ages:
        out["oldest_entry_days"], out["newest_entry_days"] = round(max(ages), 1), round(min(ages), 1)
    return out


def jobs_report(root, now, with_live=True):
    root = os.path.normpath(root)
    out = {"jobs_dir": root, "exists": os.path.isdir(root), "jobs": [], "other": [], "total_bytes": None,
           "du_note": "", "live_note": ""}
    if not out["exists"]:
        return out
    names = sorted(os.listdir(root))
    sizes, out["total_bytes"], out["du_note"] = du_children(root)
    pids, out["live_note"] = claude_agents() if with_live else (None, "not asked")
    for n in names:
        p = os.path.join(root, n)
        if not is_job(root, n):
            out["other"].append({"name": n, "kind": kind(lstat(p))})
            continue
        seen = activity(p)
        j = {"id": n, "bytes": sizes.get(n), "state": reported_state(p),
             "idle_hours": round(max(0.0, now - seen) / 3600, 1) if seen else None,
             "pid": pids.get(n) if pids is not None else None,
             "live": (pids.get(n) is not None) if pids is not None else None}
        j.update(tmp_summary(p, now))
        out["jobs"].append(j)
    out["jobs"].sort(key=lambda j: -(j["bytes"] or 0))
    return out


def days(d):
    return "-" if d is None else "%.1f d" % d


def print_jobs(r):
    if not r["exists"]:
        print("No job folders: %s does not exist." % r["jobs_dir"])
        return
    print("Job folders in %s: %d, %s in all (`du -k -d 1`: allocated size, tmp included)%s"
          % (r["jobs_dir"], len(r["jobs"]), fmt(r["total_bytes"]), "; " + r["du_note"] if r["du_note"] else ""))
    print("Live: the pid `claude agents --json --all` gives the job" +
          ("." if not r["live_note"] else "; unknown here (%s), shown as ?." % r["live_note"]))
    print("Idle: hours since state.json or timeline.jsonl last changed. Tmp entry ages: each top-level")
    print("entry's own mtime, in days; something deeper inside may be newer. State: as state.json reports it.")
    print("")
    print("%-9s %10s %11s %9s %9s %8s %8s  %s" % ("job", "size", "tmp entries", "oldest", "newest", "live pid", "idle h", "state"))
    for j in r["jobs"]:
        if j["tmp"] == "dir":
            ent = str(j["tmp_entries"]) if j["tmp_entries"] is not None else "?"
        else:
            ent = {"missing": "no tmp", "symlink": "tmp->link"}.get(j["tmp"], "tmp: " + j["tmp"])
        live = "?" if j["live"] is None else (str(j["pid"]) if j["live"] else "-")
        idle = "?" if j["idle_hours"] is None else "%.1f" % j["idle_hours"]
        print("%-9s %10s %11s %9s %9s %8s %8s  %s" % (j["id"], fmt(j["bytes"]), ent, days(j["oldest_entry_days"]),
                                                     days(j["newest_entry_days"]), live, idle, j["state"]))
    if r["other"]:
        print("")
        print("Not job folders, left alone: " + ", ".join("%s (%s)" % (o["name"], o["kind"]) for o in r["other"]))


# ---- Bazel ------------------------------------------------------------------

def workspace_state(path):
    """exists, gone, or unknown. Only a missing path is gone; an unmounted volume or a refusal is unknown."""
    if not path.startswith("/"):
        return "unknown"
    try:
        os.lstat(path)
        return "exists"
    except OSError as e:
        if e.errno not in (errno.ENOENT, errno.ENOTDIR):
            return "unknown"
    parts = path.split("/")
    if len(parts) > 2 and parts[1] == "Volumes" and not os.path.ismount("/Volumes/" + parts[2]):
        return "unknown"
    return "gone"


def processes():
    """{pid: command line} from one `ps`, or None when ps fails."""
    try:
        p = subprocess.run(["ps", "-ax", "-ww", "-o", "pid=,command="], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    procs = {}
    for ln in p.stdout.splitlines():
        pid, _, cmd = ln.strip().partition(" ")
        if pid.isdigit():
            procs[int(pid)] = cmd.strip()
    return procs


def spellings(path):
    """The ways a command line may name PATH: as given, resolved, and without macOS's /private."""
    s = {path, os.path.realpath(path)}
    s |= {p[len("/private"):] for p in s if p.startswith("/private/")}
    return s


def server_state(base, procs):
    """(running | not running | unknown, pid). Running only when the pid in server/server.pid.txt is
    alive and its command line names this output base: a reused pid is not this server."""
    try:
        with open(os.path.join(base, "server", "server.pid.txt")) as f:
            txt = f.read(64).strip()
    except FileNotFoundError:
        return "not running", None
    except OSError:
        return "unknown", None
    if not txt.isdigit() or int(txt) <= 0:
        return "unknown", None
    pid = int(txt)
    if procs is None:
        return "unknown", pid
    cmd = procs.get(pid)
    if cmd is None:
        return "not running", pid
    return ("running" if any(s in cmd for s in spellings(base)) else "not running"), pid


def read_marker(base):
    """The workspace path DO_NOT_BUILD_HERE names, less one trailing newline; None when there is none."""
    p = os.path.join(base, "DO_NOT_BUILD_HERE")
    if kind(lstat(p)) != "file":
        return None
    try:
        with open(p, encoding="utf-8", errors="surrogateescape") as f:
            txt = f.read(65536)
    except OSError:
        return None
    return txt[:-1] if txt.endswith("\n") else txt


def bazel_report(root, procs="ps"):
    """Every child of ROOT with a DO_NOT_BUILD_HERE file. cache/ and install/ are never output bases."""
    root = os.path.normpath(root)
    out = {"root": root, "exists": os.path.isdir(root), "bases": [], "total_bytes": None, "du_note": "",
           "orphans": 0, "orphan_bytes": 0, "ps_ok": True}
    if not out["exists"]:
        return out
    sizes, out["total_bytes"], out["du_note"] = du_children(root)
    if procs == "ps":
        procs = processes()
    out["ps_ok"] = procs is not None
    for n in sorted(os.listdir(root)):
        if n in ("cache", "install"):
            continue
        base = os.path.join(root, n)
        if kind(lstat(base)) != "dir":
            continue
        ws = read_marker(base)
        if ws is None:
            continue
        server, pid = server_state(base, procs)
        b = {"name": n, "path": base, "workspace": ws, "workspace_state": workspace_state(ws),
             "bytes": sizes.get(n), "server": server, "pid": pid}
        b["orphan"] = b["workspace_state"] == "gone" and server == "not running"
        if b["orphan"]:
            out["orphans"] += 1
            out["orphan_bytes"] += b["bytes"] or 0
        out["bases"].append(b)
    out["bases"].sort(key=lambda b: -(b["bytes"] or 0))
    return out


def print_bazel(r):
    if not r["exists"]:
        print("No Bazel output root at %s." % r["root"])
        return
    print("Bazel output bases in %s: %d, the root %s in all (`du -k -d 1`)%s; cache/ and install/ not listed"
          % (r["root"], len(r["bases"]), fmt(r["total_bytes"]), "; " + r["du_note"] if r["du_note"] else ""))
    print("Workspace: what DO_NOT_BUILD_HERE names. Unknown: an unmounted volume or a path this process may")
    print("not read; never counted as gone. Server: running only when server.pid.txt's pid is alive and its")
    print("command line names the base" + ("." if r["ps_ok"] else "; ps failed, so unknown."))
    print("")
    print("%-32s %10s %-9s %-11s %s" % ("output base", "size", "workspace", "server", "workspace path"))
    for b in r["bases"]:
        print("%-32s %10s %-9s %-11s %s" % (b["name"], fmt(b["bytes"]), b["workspace_state"], b["server"], b["workspace"]))
    print("")
    print("Orphaned (workspace gone, no server running): %d output bases, %s" % (r["orphans"], fmt(r["orphan_bytes"])))


# ---- stamp ------------------------------------------------------------------

def cmd_stamp(a):
    """Totals only, never `claude`: the updater's launchd PATH may not have it. A du that failed or
    timed out writes nothing, so a warning never reads a zero that was not measured."""
    now = time.time()
    jobs = os.path.normpath(a.jobs)
    jobs_bytes, partial = 0, False
    if os.path.isdir(jobs):
        _, jobs_bytes, note = du_children(jobs)
        if jobs_bytes is None:
            print("disk-space: not stamped: %s" % note, file=sys.stderr)
            return 1
        partial = partial or bool(note)
    r = bazel_report(a.root)
    if r["exists"] and r["total_bytes"] is None:
        print("disk-space: not stamped: %s" % r["du_note"], file=sys.stderr)
        return 1
    partial = partial or bool(r["du_note"])
    lines = ["jobs_bytes=%d" % jobs_bytes, "bazel_bytes=%d" % (r["total_bytes"] or 0),
             "orphan_bytes=%d" % r["orphan_bytes"], "orphans=%d" % r["orphans"], "partial=%d" % partial,
             "measured=%d" % now, "date=%s" % time.strftime("%Y-%m-%d", time.localtime(now)),
             "jobs_dir=%s" % jobs, "bazel_root=%s" % r["root"]]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    new = a.out + ".new"
    with open(new, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(new, a.out)
    print("disk: %s holds %s; the Bazel root %s, %s of it in %d orphaned output bases%s"
          % (jobs, fmt(jobs_bytes), fmt(r["total_bytes"] or 0), fmt(r["orphan_bytes"]), r["orphans"],
             " (sizes are a floor: du could not read everything)" if partial else ""))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    jobs_default = os.path.join(HOME, ".claude", "jobs")
    p = sub.add_parser("report", help="each job folder")
    p.add_argument("--jobs", default=jobs_default)
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("bazel", help="each Bazel output base")
    p.add_argument("--root", default=None)
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("stamp", help="the totals, for session-start")
    p.add_argument("--jobs", default=jobs_default)
    p.add_argument("--root", default=None)
    p.add_argument("--out", default=os.path.join(HOME, ".claude", "state", "disk-usage"))
    a = ap.parse_args(argv)
    if getattr(a, "root", None) is None and a.cmd in ("bazel", "stamp"):
        a.root = default_bazel_root()
    now = time.time()
    if a.cmd == "report":
        r = jobs_report(a.jobs, now)
        if a.json:
            print(json.dumps(r, indent=1))
        else:
            print_jobs(r)
        return 0
    if a.cmd == "bazel":
        r = bazel_report(a.root)
        if a.json:
            print(json.dumps(r, indent=1))
        else:
            print_bazel(r)
        return 0
    if a.cmd == "stamp":
        return cmd_stamp(a)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
