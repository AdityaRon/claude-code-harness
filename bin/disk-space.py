#!/usr/bin/env python3
"""What Claude Code's job folders and Bazel's output bases hold on this machine, and pruning them.

  disk-space.py report [--jobs DIR] [--json]   each job folder: size with tmp, tmp entries, activity;
                                               and each session transcript over CLAUDE_TRANSCRIPT_WARN_MB
                                               with who has it open, and when Claude Code removes it
  disk-space.py bazel [--root DIR] [--json]    each Bazel output base: its workspace, size, server
  disk-space.py stamp [--out FILE]             the totals session-start warns from; harness-update.sh
                                               runs it once a day
  disk-space.py prune [--days 7] [--live-hours 24] [--allow-untracked] [--now EPOCH]
                                               tmp entries old enough and safe to delete, and a digest;
                                               --now moves the time ages count from (tests)
  disk-space.py prune --apply DIGEST [FLAGS]   deletes exactly that listing, each entry checked again
  disk-space.py bazel --sweep [--apply DIGEST] output bases whose workspace is gone, the same way
  disk-space.py clone PATH                     a clone anywhere in your home folder and its output
                                               bases: the same checks, no age test
  disk-space.py clone --apply DIGEST PATH      deletes them

Only --apply deletes, and it must come right after prune, clone or bazel --sweep, where the ask
rules in settings.json look for it; rm-guard asks on any other spelling. Commits only a reflog
holds are not looked for. An apply stopped by TERM or HUP puts the entry it holds back; one stopped
harder leaves it under a quarantine name, which each listing names with the mv that restores it.

Sizes come from one `du -k -d 1` over each root, so they are allocated space, and a GB is 10^9
bytes. A job is live when `claude agents --json --all` gives it a pid; when that command is
missing or fails, liveness is unknown, never "not live". state.json's own `state` field is shown
as reported and is not used for liveness. An output base's workspace counts as gone only when
stat says it does not exist: an unmounted /Volumes/<name>, or a path this process may not read
(a launchd job and ~/Desktop), is "unknown", as is one holding whitespace. CLAUDE_BAZEL_ROOT and CLAUDE_CLI_BIN override the
output root and the claude binary.
"""
import argparse
import errno
import hashlib
import json
import math
import os
import pwd
import re
import shlex
import shutil
import signal
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
        print("Not job folders, left alone: " + ", ".join("%s (%s)" % (shown(o["name"]), o["kind"]) for o in r["other"]))


# ---- Bazel ------------------------------------------------------------------

def workspace_state(path):
    """exists, gone, or unknown. Only a missing path is gone; an unmounted volume, a refusal, or a
    path holding whitespace (a trailing space, a second line) is unknown."""
    if not path.startswith("/") or any(c.isspace() for c in path):
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


def server_state(base, procs, named=None):
    """(running | not running | unknown, pid). Running only when the pid in server/server.pid.txt is
    alive and its command line names this output base (NAMED, when BASE is its quarantine name): a
    reused pid is not this server."""
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
    return ("running" if any(s in cmd for s in spellings(named or base)) else "not running"), pid


def base_users(base, cwds, procs):
    """Why a process may be using output base BASE, whatever server.pid.txt says: a working folder
    inside it, or a command line naming it. None when neither; a reason too when lsof or ps failed."""
    if cwds is None or procs is None:
        return "process working folders or command lines unknown"
    real = os.path.realpath(base)
    for pid, cwd in cwds:
        if inside(cwd, real):
            return "pid %d's working folder is inside" % pid
    names = spellings(base)
    for pid, cmd in procs.items():
        if pid != os.getpid() and any(n in cmd for n in names):
            return "pid %d's command line names it" % pid
    return None


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


def bazel_report(root, procs="ps", sized=True, cwds="lsof"):
    """Every child of ROOT with a DO_NOT_BUILD_HERE file. cache/ and install/ are never output bases."""
    root = os.path.normpath(root)
    out = {"root": root, "exists": os.path.isdir(root), "bases": [], "total_bytes": None, "du_note": "",
           "orphans": 0, "orphan_bytes": 0, "ps_ok": True}
    if not out["exists"]:
        return out
    sizes, out["total_bytes"], out["du_note"] = du_children(root) if sized else ({}, None, "not sized")
    if procs == "ps":
        procs = processes()
    if cwds == "lsof":
        cwds = process_cwds()[0]
    out["ps_ok"] = procs is not None
    for n in sorted(os.listdir(root)):
        if n in ("cache", "install") or n.startswith(QUARANTINE):
            continue
        base = os.path.join(root, n)
        if kind(lstat(base)) != "dir":
            continue
        ws = read_marker(base)
        if ws is None:
            continue
        server, pid = server_state(base, procs)
        b = {"name": n, "path": base, "workspace": ws, "workspace_state": workspace_state(ws),
             "bytes": sizes.get(n), "server": server, "pid": pid, "users": base_users(base, cwds, procs)}
        b["orphan"] = b["workspace_state"] == "gone" and server == "not running" and not b["users"]
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
    print("command line names the base" + ("." if r["ps_ok"] else "; ps failed, so unknown.") + " In use: a process's")
    print("working folder is inside the base, or its command line names it.")
    print("")
    print("%-32s %10s %-9s %-11s %s" % ("output base", "size", "workspace", "server", "workspace path"))
    for b in r["bases"]:
        print("%-32s %10s %-9s %-11s %s%s" % (shown(b["name"]), fmt(b["bytes"]), b["workspace_state"], b["server"],
                                               shown(b["workspace"]), "  (in use: %s)" % b["users"] if b["users"] else ""))
    print("")
    print("Orphaned (workspace gone, no server running, no process using it): %d output bases, %s"
          % (r["orphans"], fmt(r["orphan_bytes"])))


# ---- deletion: prune, bazel --sweep and clone ---------------------------------
# Each lists by default, with a digest of what it would delete; only --apply with that digest
# deletes. A target is renamed to a quarantine name beside itself, checked again there, and
# deleted only while it is the inode it was before the rename; one kept goes back to its name.
# Nothing here follows a symlink, crosses a device, or touches state.json, timeline.jsonl, a job
# folder, cache/ or install/. Commits only a reflog holds are not looked for.

GIT = ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
       "-c", "core.untrackedCache=false", "-c", "log.showSignature=false"]
PAUSE_ENV = "CLAUDE_DISK_SPACE_TEST_PAUSE"  # tests only: hold between the digest check and the first delete
MAX_DEPTH = 128  # folders deep; deeper is kept, as rm_tree holds a descriptor a level
QUARANTINE = ".disk-space-quarantine-"
QUARANTINE_RE = re.compile(r"^\.disk-space-quarantine-\d+-[0-9a-f]{8}(?:-(.+))?$", re.S)


class Keep(Exception):
    """Why an entry stays."""


def changed(st):
    """When an inode last changed. ctime too: tar -x, cp -p, rsync -a and unzip set mtime back."""
    return max(st.st_mtime, st.st_ctime)


def shown(s):
    """S as printed: plain, or as a Python literal, so a name holding a newline stays on its line."""
    return s if re.match(r"^[A-Za-z0-9._+@%=:,/~-]*$", s) else repr(s)


def git_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_PAGER="cat", LC_ALL="C")
    return env


def inside(p, t):
    """Resolved path P is resolved path T or inside it."""
    return p == t or p.startswith(t.rstrip("/") + "/")


def under(path, top):
    """PATH is TOP or inside it, both resolved."""
    return inside(os.path.realpath(path), os.path.realpath(top))


def git_gate(repo, bare, tops, ceiling, allow_untracked, env):
    """Raise Keep when the repo at REPO holds work no remote has, or would run code of its own.
    TOPS: the names the entry has had (its own, its quarantine one). Git looks for no repo above
    CEILING, so a folder with a broken .git is never judged by a repo around the entry."""
    env = dict(env, GIT_CEILING_DIRECTORIES=ceiling)
    where = ["--git-dir=" + repo] if bare else ["-C", repo]

    def run(*args, ok=(0,)):
        try:
            p = subprocess.run(GIT + where + list(args), capture_output=True, text=True, errors="surrogateescape",
                               timeout=120, env=env, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as e:
            raise Keep("git %s did not run: %s" % (args[0], e))
        if p.returncode not in ok:
            raise Keep("git %s failed: %s" % (" ".join(args), (p.stderr.strip().splitlines() or ["exit %d" % p.returncode])[0]))
        return p.stdout

    # A clean or process filter runs while status hashes a changed file. One the repo's own config
    # sets (includes too) is the repo's code; system and global ones, git-lfs's, are the user's.
    for ln in run("config", "--show-scope", "--get-regexp", r"^filter\.", ok=(0, 1)).splitlines():
        scope, _, key = ln.partition("\t")
        if scope not in ("system", "global"):
            raise Keep("a git filter is configured in the repo (%s), which git status would run" % shown(key.split(" ")[0]))
    if not bare:
        lines = run("status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=all").splitlines()
        if any(not ln.startswith("??") for ln in lines):
            raise Keep("tracked files changed")
        if lines and not allow_untracked:
            raise Keep("untracked files (--allow-untracked deletes them)")
        if any(ln[:1] == "S" or ln[:1].islower() for ln in run("ls-files", "-v").splitlines()):
            raise Keep("files marked skip-worktree or assume-unchanged, whose edits status does not show")
    if not run("remote").strip() and run("rev-list", "-n", "1", "--all").strip():
        raise Keep("commits and no remote")
    if (run("for-each-ref", "refs/stash") if bare else run("stash", "list")).strip():
        raise Keep("a stash")
    if run("rev-list", "-n", "1", "--all", "--not", "--remotes").strip():
        raise Keep("commits no remote has, on a branch, a tag or a detached HEAD")
    for ln in run("worktree", "list", "--porcelain").splitlines():
        w = ln[len("worktree "):]
        if ln.startswith("worktree ") and not any(under(w, t) for t in tops):
            raise Keep("a worktree outside the entry: " + shown(w))


def bare_looking(names):
    h, o, r = names.get("HEAD"), names.get("objects"), names.get("refs")
    return bool(h and o and r and h.is_file(follow_symlinks=False) and o.is_dir(follow_symlinks=False)
                and r.is_dir(follow_symlinks=False))


def survey(entry, dev, cutoff, now, label):
    """One walk of ENTRY that follows no symlink: (bytes, [(repo, bare, name)]). Keep when anything
    inside changed (mtime or ctime) after CUTOFF, is a socket, fifo or device, sits on another
    device, is nested past MAX_DEPTH, or cannot be read. Repos: a folder holding .git (a folder or a
    file), and a bare-looking one, inside a .git folder too (a submodule's). LABEL names ENTRY."""
    size, repos = 0, []
    stack = [(entry, 0, 0)]  # path; 0 outside .git, 1 a .git folder itself, 2 inside one; depth

    def rel(p):
        r = os.path.relpath(p, entry)
        return shown(label if r == "." else label + "/" + r)

    while stack:
        d, g, depth = stack.pop()
        if depth > MAX_DEPTH:
            raise Keep("%s is nested deeper than %d folders" % (rel(d), MAX_DEPTH))
        try:
            with os.scandir(d) as it:
                ents = list(it)
            names = {e.name: e for e in ents}
            if g == 0 and ".git" in names:
                repos.append((d, False, rel(d)))
            elif g != 1 and bare_looking(names):
                repos.append((d, True, rel(d)))
            for e in ents:
                st = e.stat(follow_symlinks=False)
                size += st.st_blocks * 512
                if changed(st) >= cutoff:
                    raise Keep("%s changed %.1f days ago" % (rel(e.path), max(0.0, now - changed(st)) / 86400))
                if not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                    raise Keep("%s is a socket, fifo or device, which a process may use" % rel(e.path))
                if stat.S_ISDIR(st.st_mode):
                    if st.st_dev != dev:
                        raise Keep("%s is on another device" % rel(e.path))
                    stack.append((e.path, 1 if (g == 0 and e.name == ".git") else (2 if g else 0), depth + 1))
        except OSError as e:
            raise Keep("cannot read %s: %s" % (rel(d), e.strerror))
    return size, repos


def process_cwds():
    """[(pid, resolved working folder)] for every process lsof may see, from one lsof; None when it fails."""
    exe = shutil.which("lsof")
    if not exe:
        return None, "no lsof"
    try:
        p = subprocess.run([exe, "-n", "-P", "-d", "cwd", "-Fpn"], capture_output=True, text=True,
                           errors="surrogateescape", timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        return None, "lsof did not run: %s" % e
    cwds, pid = [], None
    for ln in p.stdout.splitlines():
        if ln.startswith("p"):
            pid = int(ln[1:]) if ln[1:].isdigit() else None
        elif ln.startswith("n/") and pid is not None:
            cwds.append((pid, os.path.realpath(ln[1:])))
    if not cwds:
        return None, "lsof listed no working folders (exit %d)" % p.returncode
    return cwds, ""


def state_paths(job_dir):
    """(key, folder, resolved) for each folder a job's state.json names; None when it cannot be read."""
    try:
        with open(os.path.join(job_dir, "state.json")) as f:
            s = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(s, dict):
        return None
    return [(k, s[k], os.path.realpath(s[k])) for k in ("cwd", "worktreePath", "originCwd")
            if isinstance(s.get(k), str) and s[k].startswith("/")]


class Ctx:
    """What a listing, and each re-check, reads about the machine. A re-check reads claude agents,
    lsof and ps again when the last read is over REFRESH seconds old: together they cost about a
    second on an Apple M2, and an apply may re-check thousands of entries."""
    REFRESH = 5

    def __init__(self, a, ages=True):
        self.a, self.ages, self.env = a, ages, git_env()
        self.refresh(sized=True)

    def recheck(self):
        if time.time() - self.read_at > self.REFRESH:
            self.refresh(sized=False)
        self.set_clock()

    def set_clock(self):
        """NOW, which liveness goes by, is the clock; ages count from --now when it is given."""
        self.now = time.time()
        self.age_now = getattr(self.a, "now", None) or self.now
        self.cutoff = self.age_now - self.a.days * 86400 if self.ages else float("inf")

    def refresh(self, sized):
        self.read_at = time.time()
        self.set_clock()
        self.pids, self.live_note = claude_agents()
        self.cwds, self.cwd_note = process_cwds()
        self.procs = processes()
        self.bases = bazel_report(self.a.root, procs=self.procs, sized=sized, cwds=self.cwds)["bases"]
        for b in self.bases:
            b["ws_real"] = os.path.realpath(b["workspace"]) if b["workspace"].startswith("/") else None
        self.jobs_note = ""
        self.live, self.protected, self.unreadable = live_jobs(self)


def live_jobs(ctx):
    """Every live job, with why; the folders their state.json files name, across all of them, since
    a session may work in another job's tmp; and the live jobs whose state.json cannot be read."""
    root = os.path.normpath(ctx.a.jobs)
    live, protected, unreadable = {}, [], []
    try:
        names = sorted(os.listdir(root))
    except OSError as e:
        try:  # only the default folder, missing, means no jobs; anything else, liveness is unknown
            os.lstat(root)
            missing = False
        except FileNotFoundError:
            missing = root == os.path.join(HOME, ".claude", "jobs")
        except OSError:
            missing = False
        if not missing:
            ctx.jobs_note = "the jobs folder %s cannot be read (%s)" % (shown(root), e.strerror)
        return live, protected, unreadable
    for n in names:
        if not is_job(root, n):
            continue
        jd = os.path.join(root, n)
        if ctx.pids is None:
            why = "liveness unknown: " + ctx.live_note
        elif ctx.pids.get(n):
            why = "pid %d" % ctx.pids[n]
        else:
            seen = activity(jd)
            if seen is None or ctx.now - seen >= ctx.a.live_hours * 3600:
                continue
            why = "active %.1f h ago" % (max(0.0, ctx.now - seen) / 3600)
        live[n] = why
        paths = state_paths(jd)
        if paths is None:
            unreadable.append(n)
        else:
            protected += [(n,) + p for p in paths]
    return live, protected, unreadable


def job_records(ctx, only=None):
    root = os.path.normpath(ctx.a.jobs)
    root_real = os.path.realpath(root)
    jobs, skipped = [], []
    try:
        names = [only] if only else sorted(os.listdir(root))
    except OSError as e:
        return [], [("-", "cannot read %s: %s" % (root, e.strerror))]
    for n in names:
        if not is_job(root, n):
            continue
        tmp = os.path.join(root, n, "tmp")
        tst = lstat(tmp)
        if kind(tst) == "missing":
            continue
        if kind(tst) != "dir":
            skipped.append((n, "tmp is a %s, not a folder" % kind(tst)))
            continue
        tmp_real = os.path.realpath(tmp)
        if tmp_real != os.path.join(root_real, n, "tmp"):
            skipped.append((n, "tmp resolves to " + shown(tmp_real)))
            continue
        jobs.append({"id": n, "tmp": tmp, "tmp_real": tmp_real, "dev": tst.st_dev, "ino": tst.st_ino,
                     "live": n in ctx.live})
    return jobs, skipped


def check_entry(ctx, job, name, at=None, top_st=None, cheap=False):
    """("delete", bytes, bases), ("keep", reason, None) or ("young", None, None) for entry NAME of
    folder JOB["tmp"]. AT: its quarantine name, once renamed; TOP_ST: its stat from before the
    rename, which set its ctime. CHEAP: only the checks that need no walk and no git."""
    phys = os.path.join(job["tmp"], at or name)
    st = top_st or lstat(phys)
    if st is None:
        return "keep", "gone", None
    if changed(st) >= ctx.cutoff:
        return "young", None, None
    logical = os.path.join(job["tmp_real"], name)
    reals = {logical, os.path.join(job["tmp_real"], at or name)}
    if kind(st) == "symlink":
        reals.add(os.path.realpath(phys))  # a working folder through the link counts
    try:
        if st.st_dev != job["dev"]:
            raise Keep("on another device")
        if ctx.jobs_note:
            raise Keep("%s, so which sessions are live is unknown" % ctx.jobs_note)
        if ctx.unreadable and kind(st) != "file":
            raise Keep("live job %s's state.json cannot be read, so the folders it works in are unknown"
                       % ctx.unreadable[0])
        for jid, key, path, path_real in ctx.protected:
            if any(inside(path_real, r) for r in reals):
                raise Keep("live job %s's %s is inside: %s" % (jid, key, shown(path)))
        for pid, cwd in ctx.cwds or ():
            if any(inside(cwd, r) for r in reals):
                raise Keep("pid %d's working folder is inside" % pid)
        if kind(st) == "other":
            raise Keep("a socket, fifo or device, which a process may use")
        if kind(st) != "dir":  # a file or a link goes by itself; a link's target is never touched
            return "delete", st.st_blocks * 512, []
        if ctx.cwds is None and job["live"]:
            raise Keep("live, and process working folders are unknown (%s)" % ctx.cwd_note)
        bases = []  # before the quarantine rename too: a server that started since the listing keeps it
        for b in ctx.bases:
            if b["ws_real"] and inside(b["ws_real"], logical):
                if b["server"] != "not running":
                    raise Keep("Bazel output base %s: its server is %s (pid %s)" % (shown(b["name"]), b["server"], b["pid"]))
                if b["users"]:
                    raise Keep("Bazel output base %s: %s" % (shown(b["name"]), b["users"]))
                bases.append(b)
        if cheap:
            return "delete", None, bases
        size, repos = survey(phys, st.st_dev, ctx.cutoff, ctx.age_now, name)
        for repo, bare, label in repos:
            try:
                git_gate(repo, bare, sorted(reals), job["tmp_real"], ctx.a.allow_untracked, ctx.env)
            except Keep as e:
                raise Keep("%s: %s" % (label, e))
    except Keep as e:
        return "keep", str(e), None
    return "delete", st.st_blocks * 512 + size, bases


def digest(targets, now=None):
    """sha256 over the sorted target paths with their sizes, output bases included, and --now."""
    rows = ["now\t%r" % now] if now else []
    for t in targets:
        rows.append("%s\t%s" % (t["path"], t["bytes"]))
        rows += ["%s\t%s" % (b["path"], b["bytes"]) for b in t.get("bases", [])]
    return hashlib.sha256("\n".join(sorted(rows)).encode("utf-8", "surrogateescape")).hexdigest()[:16]


def base_rows(bases):
    return [{k: b[k] for k in ("name", "path", "bytes", "workspace")} for b in bases]


def prune_plan(ctx):
    jobs, skipped = job_records(ctx)
    plan = {"jobs_dir": os.path.normpath(ctx.a.jobs), "days": ctx.a.days, "now": ctx.a.now, "targets": [], "kept": [], "young": 0,
            "skipped_jobs": skipped, "live_jobs": [[n, w] for n, w in sorted(ctx.live.items())],
            "cwd_note": ctx.cwd_note, "processes": len({p for p, _ in ctx.cwds or ()})}
    for j in jobs:
        try:
            names = sorted(os.listdir(j["tmp"]))
        except OSError as e:
            plan["skipped_jobs"].append((j["id"], "cannot read tmp: %s" % e.strerror))
            continue
        for n in names:
            if n.startswith(QUARANTINE):
                continue  # listed below, never deleted here
            verdict, val, bases = check_entry(ctx, j, n)
            rel = "%s/tmp/%s" % (j["id"], n)
            if verdict == "young":
                plan["young"] += 1
            elif verdict == "keep":
                plan["kept"].append({"path": rel, "reason": val})
            else:
                plan["targets"].append({"job": j["id"], "name": n, "rel": rel, "path": os.path.join(j["tmp"], n),
                                        "bytes": val, "link": kind(lstat(os.path.join(j["tmp"], n))) == "symlink",
                                        "bases": base_rows(bases)})
    plan["quarantined"] = leftovers([j["tmp"] for j in jobs] + [ctx.a.root])
    plan["digest"] = digest(plan["targets"], ctx.a.now)
    return plan


def chmod_dir(dir_fd, name, st):
    """u+rwx on folder NAME, which must still be the folder ST describes; never through a link."""
    now_st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if not stat.S_ISDIR(now_st.st_mode) or (now_st.st_dev, now_st.st_ino) != (st.st_dev, st.st_ino):
        raise OSError(errno.ESTALE, "changed while being deleted", name)
    mode = stat.S_IMODE(now_st.st_mode) | stat.S_IRWXU
    try:
        os.chmod(name, mode, dir_fd=dir_fd, follow_symlinks=False)
    except NotImplementedError:  # Linux has no lchmod: the stat just above is the check
        os.chmod(name, mode, dir_fd=dir_fd)


def rm_tree(dir_fd, name, dev, depth=0, expect=None):
    """Delete NAME in the folder open at DIR_FD: a link or file by itself, a folder after its contents.
    Opens each folder with O_NOFOLLOW, never leaves DEV, adds u+rwx where a folder lacks it, and
    with EXPECT, deletes NAME only while it is that (device, inode)."""
    st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if expect is not None and (st.st_dev, st.st_ino) != expect:
        raise OSError(errno.ESTALE, "not the inode that was checked", name)
    if not stat.S_ISDIR(st.st_mode):
        os.unlink(name, dir_fd=dir_fd)
        return
    if st.st_dev != dev:
        raise OSError(errno.EXDEV, "on another device", name)
    if depth > MAX_DEPTH + 8:
        raise OSError(errno.ELOOP, "nested deeper than %d folders" % MAX_DEPTH, name)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except PermissionError:
        chmod_dir(dir_fd, name, st)
        fd = os.open(name, flags, dir_fd=dir_fd)
    try:
        fst = os.fstat(fd)
        if (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
            raise OSError(errno.ESTALE, "changed while being deleted", name)
        if fst.st_mode & stat.S_IRWXU != stat.S_IRWXU:
            os.fchmod(fd, stat.S_IMODE(fst.st_mode) | stat.S_IRWXU)
        for child in os.listdir(fd):
            rm_tree(fd, child, dev, depth + 1)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=dir_fd)


def delete_at(dir_fd, name, expect):
    """rm_tree of NAME, the inode EXPECT names; a tree too deep for the stack is an OSError too."""
    try:
        rm_tree(dir_fd, name, expect[0], 0, expect)
    except RecursionError:
        raise OSError(errno.ELOOP, "nested too deep to delete", name)


def put_back(fd, q, name):
    """Rename quarantine name Q back to NAME: "" when it went back, else where it stays."""
    if lstat_at(fd, name) is not None:
        return "; left as %s, since %s exists again" % (shown(q), shown(name))
    try:
        os.rename(q, name, src_dir_fd=fd, dst_dir_fd=fd)
        return ""
    except OSError as e:
        return "; left as %s: %s" % (shown(q), e.strerror)


def lstat_at(fd, name):
    try:
        return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except OSError:
        return None


def quarantine_name(fd, name):
    """A quarantine name for NAME that nothing in the folder open at FD holds yet, carrying NAME when
    it fits, so a listing can print the mv that restores it. None when ten tries found none free."""
    for _ in range(10):
        q = "%s%d-%s" % (QUARANTINE, os.getpid(), os.urandom(4).hex())
        if len(("%s-%s" % (q, name)).encode("utf-8", "surrogateescape")) <= 255:
            q = "%s-%s" % (q, name)
        if lstat_at(fd, q) is None:
            return q
    return None


def leftovers(folders):
    """What an interrupted apply left under a quarantine name in FOLDERS, each with the mv that
    restores it when its first name is known, printable and free. Listed, never deleted."""
    out = []
    for d in folders:
        try:
            names = sorted(n for n in os.listdir(d) if n.startswith(QUARANTINE))
        except OSError:
            continue
        for n in names:
            m = QUARANTINE_RE.match(n)
            first = m.group(1) if m else None
            p, back = os.path.join(d, n), os.path.join(d, first or "")
            if not first or not (p + back).isprintable():
                how = "its first name is not in this one, or does not print: rename it back by hand"
            elif lstat(back) is not None:
                how = "%s exists again: rename it back by hand" % shown(first)
            else:
                how = "mv -n -- %s %s" % (shlex.quote(p), shlex.quote(back))
            out.append({"path": p, "restore": how})
    return out


def print_leftovers(lo):
    if not lo:
        return
    print("")
    print("Left under a quarantine name by an apply that was stopped; part may be gone if it was being")
    print("deleted. Never deleted here. To restore each:")
    for x in lo:
        print("  %s: %s" % (shown(x["path"]), x["restore"]))


def pinned_delete(parent, parent_id, name, recheck):
    """Rename NAME in folder PARENT to a quarantine name, ask RECHECK(qname, stat before) there, and
    delete it only while it is the inode it was. (deleted | kept | failed, why, RECHECK's value).
    Whatever stops it, an exception or TERM or HUP (main), puts back what is left under NAME."""
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    q = None
    try:
        pst = os.fstat(fd)
        if (pst.st_dev, pst.st_ino) != parent_id:
            return "kept", "%s changed since it was checked" % shown(parent), None
        st0 = lstat_at(fd, name)
        if st0 is None:
            return "kept", "gone", None
        q = quarantine_name(fd, name)
        if q is None:
            return "kept", "no free quarantine name beside it", None
        try:
            os.rename(name, q, src_dir_fd=fd, dst_dir_fd=fd)
        except OSError as e:
            q = None
            return "kept", "could not rename (%s)" % e.strerror, None
        stq = lstat_at(fd, q)
        if stq is None or (stq.st_dev, stq.st_ino) != (st0.st_dev, st0.st_ino):
            ok, why, val = False, "it changed as it was renamed", None
        else:
            ok, why, val = recheck(q, st0)
        if not ok:
            return "kept", why + put_back(fd, q, name), None
        try:
            delete_at(fd, q, (st0.st_dev, st0.st_ino))
        except OSError as e:
            return "failed", "%s, so it may be partly gone%s" % (e, put_back(fd, q, name)), None
        q = None
        return "deleted", "", val
    except BaseException:
        if q is not None and lstat_at(fd, q) is not None:
            put_back(fd, q, name)
        raise
    finally:
        os.close(fd)


def delete_base(root, name, workspace, want_gone):
    """(deleted | kept | failed, why) for output base NAME, pinned and checked again as an entry is:
    its marker, its workspace, its server, and any process using it."""
    real = os.path.realpath(os.path.normpath(root))
    rst = lstat(real)
    if rst is None or name in ("cache", "install"):
        return "kept", "not an output base"
    logical = os.path.join(real, name)

    def recheck(q, st0):
        phys = os.path.join(real, q)
        if not stat.S_ISDIR(st0.st_mode):
            return False, "not a folder", None
        if read_marker(phys) != workspace:
            return False, "its DO_NOT_BUILD_HERE changed", None
        if want_gone and workspace_state(workspace) != "gone":
            return False, "its workspace is %s" % workspace_state(workspace), None
        procs = processes()
        server, pid = server_state(phys, procs, named=logical)
        if server != "not running":
            return False, "its server is %s (pid %s)" % (server, pid), None
        cwds = process_cwds()[0]
        users = base_users(logical, cwds, procs) or base_users(phys, cwds, procs)
        if users:
            return False, users, None
        return True, "", None

    status, why, _ = pinned_delete(real, (rst.st_dev, rst.st_ino), name, recheck)
    return status, why


def pause():
    """Tests only: say the digest matched, then wait for the go-ahead file."""
    p = os.environ.get(PAUSE_ENV)
    if not p:
        return
    open(p + ".ready", "w").close()
    for _ in range(600):
        if os.path.exists(p):
            return
        time.sleep(0.1)
    raise SystemExit("disk-space: %s never appeared; nothing deleted" % p)


def report_base(status, why, b, sizes):
    if status == "deleted":
        print("deleted Bazel output base %s (%s)" % (shown(b["name"]), fmt(sizes.get(b["path"]))))
    elif status == "kept":
        print("kept at the re-check: Bazel output base %s: %s" % (shown(b["name"]), why))
    else:
        print("could not delete Bazel output base %s: %s" % (shown(b["name"]), why))
    return status == "failed"


def apply_targets(ctx, targets, job_for, days_note):
    """Delete each target pinned and checked again, then its output bases. 1 when any delete failed."""
    failed = 0
    for t in targets:
        ctx.recheck()
        j = job_for(t)
        verdict, val, _ = check_entry(ctx, j, t["name"], cheap=True) if j else ("keep", "its folder changed", None)
        if verdict != "delete":
            print("kept at the re-check: %s: %s" % (shown(t["rel"]), days_note if verdict == "young" else val))
            continue
        planned = {b["path"] for b in t["bases"]}

        def recheck(q, st0):
            verdict, val, bases = check_entry(ctx, j, t["name"], at=q, top_st=st0)
            if verdict == "young":
                return False, days_note, None
            if verdict != "delete":
                return False, val, None
            if any(b["path"] not in planned for b in bases):
                return False, "an output base the listing did not name now names it", None
            return True, "", bases

        status, why, bases = pinned_delete(j["tmp"], (j["dev"], j["ino"]), t["name"], recheck)
        if status == "kept":
            print("kept at the re-check: %s: %s" % (shown(t["rel"]), why))
            continue
        if status == "failed":
            failed += 1
            print("could not delete %s: %s" % (shown(t["rel"]), why))
            continue
        print(("unlinked %s (a link; its target stays)" % shown(t["rel"])) if t.get("link")
              else "deleted %s (%s)" % (shown(t["rel"]), fmt(t["bytes"])))
        sizes = {b["path"]: b["bytes"] for b in t["bases"]}
        for b in bases:
            status, why = delete_base(ctx.a.root, b["name"], b["workspace"], want_gone=False)
            failed += report_base(status, why, b, sizes)
    return 1 if failed else 0


def apply_prune(ctx, plan, want):
    if want != plan["digest"]:
        print("Nothing deleted: this listing's digest is %s, not %s. Read it, then run the command it prints."
              % (plan["digest"], want))
        return 1
    pause()

    def job_for(t):
        jobs, _ = job_records(ctx, only=t["job"])
        return next((x for x in jobs if x["tmp"] == os.path.dirname(t["path"])), None)

    return apply_targets(ctx, plan["targets"], job_for, "newer than %g days now" % ctx.a.days)


def shown_self():
    p = os.path.abspath(sys.argv[0])
    h = HOME.rstrip("/") + "/"
    return "~/" + p[len(h):] if p.startswith(h) and re.match(r"^[A-Za-z0-9._/-]+$", p[len(h):]) else shlex.quote(p)


def apply_command(a, verb, d, tail=()):
    parts = list(verb) + ["--apply", d] + list(tail)
    if verb in (["prune"], ["clone"]):
        if verb == ["prune"] and a.days != 7:
            parts += ["--days", "%g" % a.days]
        if verb == ["prune"] and a.now:
            parts += ["--now", repr(a.now)]
        if a.live_hours != 24:
            parts += ["--live-hours", "%g" % a.live_hours]
        if a.allow_untracked:
            parts.append("--allow-untracked")
        if os.path.normpath(a.jobs) != os.path.join(HOME, ".claude", "jobs"):
            parts += ["--jobs", a.jobs]
    if os.path.normpath(a.root) != os.path.normpath(default_bazel_root()):
        parts += ["--root", a.root]
    return "python3 %s %s" % (shown_self(), " ".join(shlex.quote(x) for x in parts))


def print_targets(targets, kept):
    for t in targets:
        print("delete %10s  %s" % ("a link" if t.get("link") else fmt(t["bytes"]), shown(t["rel"])))
        for b in t["bases"]:
            print("       %10s    with Bazel output base %s" % (fmt(b["bytes"]), shown(b["name"])))
    for k in kept:
        print("keep   %10s  %s: %s" % ("", shown(k["path"]), k["reason"]))


def print_total(targets, d, cmd):
    print("")
    if not targets:
        print("Nothing to delete.")
        return
    nb = sum(len(t["bases"]) for t in targets)
    print("To delete: %d, %s, with %d Bazel output bases, %s. Digest %s."
          % (len(targets), fmt(sum(t["bytes"] or 0 for t in targets)), nb,
             fmt(sum(b["bytes"] or 0 for t in targets for b in t["bases"])), d))
    print("To delete exactly these: " + cmd)


def print_prune(plan, cmd):
    print("Prune: the top-level entries of each job's tmp/ in %s whose own mtime and ctime, and every" % shown(plan["jobs_dir"]))
    print("mtime and ctime inside, are over %g days old. Kept: git work no remote has, any live job's or" % plan["days"])
    print("process's working folder, a Bazel output base in use. Never state.json, timeline.jsonl or a job folder.")
    live = ", ".join("%s (%s)" % (i, w) for i, w in plan["live_jobs"]) or "none"
    cwds = ("%d processes' working folders from lsof" % plan["processes"]) if not plan["cwd_note"] else \
        "process working folders unknown (%s): a live job's folders are kept" % plan["cwd_note"]
    print("Live jobs: %s. %s." % (live, cwds))
    if plan["now"]:
        print("Ages count from --now %r (%s UTC), not the clock; which jobs are live still goes by the clock."
              % (plan["now"], time.strftime("%Y-%m-%d %H:%M", time.gmtime(plan["now"]))))
    print("")
    print_targets(plan["targets"], plan["kept"])
    for n, why in plan["skipped_jobs"]:
        print("skipped job %s: %s" % (shown(n), why))
    print("Entries newer than %g days by their own mtime and ctime, not listed: %d." % (plan["days"], plan["young"]))
    print_leftovers(plan["quarantined"])
    print_total(plan["targets"], plan["digest"], cmd)


def cmd_prune(a):
    ctx = Ctx(a)
    plan = prune_plan(ctx)
    if a.json:
        print(json.dumps(plan, indent=1))
    else:
        print_prune(plan, apply_command(a, ["prune"], plan["digest"]))
    if a.apply is None:
        return 0
    print("")
    return apply_prune(ctx, plan, a.apply)


def cmd_sweep(a):
    r = bazel_report(a.root)
    targets = [{k: b[k] for k in ("name", "path", "bytes", "workspace")} for b in r["bases"] if b["orphan"]]
    d = digest(targets)
    lo = leftovers([r["root"]])
    if a.json:
        print(json.dumps({"root": r["root"], "targets": targets, "quarantined": lo, "digest": d}, indent=1))
    elif not r["exists"]:
        print("No Bazel output root at %s." % shown(r["root"]))
    else:
        print("Sweep: output bases in %s whose workspace is gone (not unknown), whose server is not" % shown(r["root"]))
        print("running and that no process uses. Never cache/ or install/, and never a server.")
        print("")
        for t in targets:
            print("delete %10s  %s  (workspace was %s)" % (fmt(t["bytes"]), shown(t["name"]), shown(t["workspace"])))
        print_leftovers(lo)
        print("")
        if targets:
            print("To delete: %d output bases, %s. Digest %s." % (len(targets), fmt(sum(t["bytes"] or 0 for t in targets)), d))
            print("To delete exactly these: " + apply_command(a, ["bazel", "--sweep"], d))
        else:
            print("Nothing to delete.")
    if a.apply is None:
        return 0
    print("")
    if a.apply != d:
        print("Nothing deleted: this listing's digest is %s, not %s. Read it, then run the command it prints." % (d, a.apply))
        return 1
    pause()
    failed = 0
    for t in targets:
        status, why = delete_base(r["root"], t["name"], t["workspace"], want_gone=True)
        failed += report_base(status, why, t, {t["path"]: t["bytes"]})
    return 1 if failed else 0


def same(x, y):
    try:
        return os.path.samefile(x, y)
    except OSError:
        return False


def lineage(p):
    """P and each folder above it, to /."""
    out = [p]
    while os.path.dirname(out[-1]) != out[-1]:
        out.append(os.path.dirname(out[-1]))
    return out


def clone_path(a):
    """The resolved clone A.path names, or raise SystemExit: a folder (not a link) holding .git,
    inside your home folder, inside ~/.claude only within a job's tmp, and holding none of ~/.claude,
    the jobs folder, the Bazel root or this script. Compared by inode (samefile), so a link such as
    ~/.claude -> dotfiles/claude, or ~/.CLAUDE on a case-blind disk, is seen for what it is."""
    path = os.path.abspath(os.path.expanduser(a.path))
    home = os.path.realpath(HOME)
    claude = os.path.join(HOME, ".claude")
    real = os.path.realpath(path)

    def refuse(why):
        raise SystemExit("disk-space: not a clone this deletes: %s %s. Nothing deleted." % (shown(path), why))

    if kind(lstat(path)) != "dir":
        # A clone whose apply was stopped sits beside its name under a quarantine one: say so
        # here, where the retry lands, as well as in a sibling's listing.
        print_leftovers(leftovers([os.path.dirname(path)]))
        refuse("is not a folder (a link is not followed)")
    if same(real, home) or not inside(real, home):
        refuse("is not inside your home folder")
    for label, g in (("~/.claude", claude), ("the jobs folder", a.jobs), ("the Bazel output root", a.root),
                     ("this script's folder", os.path.dirname(os.path.realpath(__file__)))):
        g = os.path.abspath(os.path.expanduser(g))
        if any(same(x, real) for x in lineage(os.path.realpath(g)) + lineage(g)):
            refuse("is or holds %s (%s)" % (label, shown(g)))
    for x in lineage(real):
        if same(x, claude):
            parts = os.path.relpath(real, x).split("/")
            if len(parts) < 4 or parts[0] != "jobs" or not JOB_RE.match(parts[1]) or parts[2] != "tmp":
                refuse("is in ~/.claude, outside a job's tmp")
            break
    if lstat(os.path.join(real, ".git")) is None:
        refuse("holds no .git")
    return real


def cmd_clone(a):
    real = clone_path(a)
    ctx = Ctx(a, ages=False)
    parent = os.path.dirname(real)
    pst = lstat(parent)
    folder = {"id": "-", "tmp": parent, "tmp_real": parent, "dev": pst.st_dev, "ino": pst.st_ino, "live": True}
    name = os.path.basename(real)
    verdict, val, bases = check_entry(ctx, folder, name)
    targets, kept = [], []
    if verdict == "delete":
        targets.append({"name": name, "rel": real, "path": real, "bytes": val, "bases": base_rows(bases)})
    else:
        kept.append({"path": real, "reason": val})
    d = digest(targets)
    lo = leftovers([parent, a.root])
    if a.json:
        print(json.dumps({"clone": real, "targets": targets, "kept": kept, "quarantined": lo, "digest": d}, indent=1))
    else:
        print("Clone: kept when a git repo in it holds work no remote has, any live job's or process's working")
        print("folder is inside, or a Bazel output base for it is in use; no age test. Its output bases go with it.")
        print("")
        print_targets(targets, kept)
        print_leftovers(lo)
        print_total(targets, d, apply_command(a, ["clone"], d, [real]))
    if a.apply is None:
        return 0
    print("")
    if a.apply != d:
        print("Nothing deleted: this listing's digest is %s, not %s. Read it, then run the command it prints." % (d, a.apply))
        return 1
    pause()
    return apply_targets(ctx, targets, lambda t: folder if lstat(parent) else None, "")


def apply_misplaced(argv):
    """--apply anywhere but right after `prune`, `clone` or `bazel --sweep`, where the ask rules look."""
    at = [i for i, t in enumerate(argv) if t.startswith("--app")]
    if not at:
        return False
    want = 1 if argv[:1] in (["prune"], ["clone"]) else 2 if argv[:2] == ["bazel", "--sweep"] else None
    return want is None or at != [want] or argv[want] != "--apply"


# ---- transcripts ------------------------------------------------------------

COMPACT_MARK = b'"subtype":"compact_boundary"'


def count_mark(path, mark=COMPACT_MARK, chunk=1 << 20):
    """How many times MARK occurs in PATH, read in chunks, as bytes.count counts it (left to right,
    no overlaps); None when it cannot be read. The carried tail is at most one byte short of MARK, so
    a mark across a chunk boundary counts once, and starts past the last match, so a mark that
    overlaps itself (b"aa" in b"aaa") is not counted twice. Any mark but an empty one."""
    if not mark:
        raise ValueError("count_mark: an empty mark")
    n, tail, k = 0, b"", len(mark)
    try:
        with open(path, "rb") as f:
            while True:
                b = f.read(chunk)
                if not b:
                    return n
                buf, i = tail + b, 0
                while True:
                    j = buf.find(mark, i)
                    if j < 0:
                        break
                    n, i = n + 1, j + k
                # buf[-(k - 1):] was the whole buffer for a 1-byte mark.
                tail = buf[max(i, len(buf) - (k - 1)):]
    except OSError:
        return None


def big_transcripts(projects, min_bytes, limit=10):
    """Session transcripts (PROJECT/SESSION.jsonl) of MIN_BYTES or more, largest first, each with
    its compaction count and mtime; LIMIT None for all. Every one is stat'ed; only those past the
    size are read."""
    out = []
    try:
        dirs = [d for d in os.scandir(projects) if d.is_dir(follow_symlinks=False)]
    except OSError:
        return out
    for d in dirs:
        try:
            ents = list(os.scandir(d.path))
        except OSError:
            continue
        for e in ents:
            if not e.name.endswith(".jsonl") or not e.is_file(follow_symlinks=False):
                continue
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if st.st_size >= min_bytes:
                n = count_mark(e.path)
                if n is not None:
                    out.append({"session": e.name[:-len(".jsonl")], "path": e.path, "bytes": st.st_size,
                                "compactions": n, "mtime": st.st_mtime})
    out.sort(key=lambda t: -t["bytes"])
    return out if limit is None else out[:limit]


def transcript_mb_default():
    """CLAUDE_TRANSCRIPT_WARN_MB, or 150 when unset or not a size."""
    try:
        return days_arg(os.environ.get("CLAUDE_TRANSCRIPT_WARN_MB") or "150")
    except (argparse.ArgumentTypeError, ValueError):
        return 150.0


def cleanup_days(settings):
    """(days, where): cleanupPeriodDays from the settings.json at SETTINGS when it is a number above 0,
    else 30 (Claude Code's default)."""
    try:
        with open(settings) as f:
            v = json.load(f).get("cleanupPeriodDays")
    except (OSError, ValueError, AttributeError):
        v = None
    if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v > 0:
        return float(v), "cleanupPeriodDays in " + shown(settings)
    return 30.0, "the default, no cleanupPeriodDays in " + shown(settings)


def open_holders(paths):
    """({path: [pids that have it open]}, "") from one `lsof` over PATHS (it exits 1 when some named file
    is open by nobody), or (None, why) when it cannot be told: no lsof, it did not run, or it exited
    with more than 1. When it also wrote to stderr, a file with no holder seen is None, not []. A
    failed lookup is never "nobody has it open"."""
    exe = shutil.which("lsof")
    if not exe:
        return None, "no lsof"
    if not paths:
        return {}, ""
    real = {}
    for x in paths:
        real.setdefault(os.path.realpath(x), []).append(x)
    try:
        p = subprocess.run([exe, "-n", "-P", "-Fpn", "--", *real], capture_output=True, text=True,
                           errors="surrogateescape", timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        return None, "lsof did not run: %s" % e
    if p.returncode not in (0, 1) or (p.returncode == 0 and not p.stdout.strip()):
        return None, "lsof exited %d" % p.returncode
    held, pid = {x: [] for x in paths}, None
    for ln in p.stdout.splitlines():
        if ln.startswith("p"):
            pid = int(ln[1:]) if ln[1:].isdigit() else None
        elif ln.startswith("n") and pid is not None:
            for x in real.get(os.path.realpath(ln[1:]), ()):
                if pid not in held[x]:
                    held[x].append(pid)
    if p.stderr.strip():   # lsof said something (a file it could not stat, a process it could not read): no holder seen is not none
        held = {x: v or None for x, v in held.items()}
        return held, "lsof warned: " + p.stderr.strip().splitlines()[0][:80]
    return held, ""


def annotate_transcripts(ts, settings, now):
    """Each transcript gets who holds it open (pids, or None when that cannot be told), idle days, and
    the time Claude Code removes it: last write plus cleanupPeriodDays. No job folder is consulted: most
    transcripts belong to interactive sessions that have none, so "no job" says nothing about one."""
    days_, where = cleanup_days(settings)
    held, why = open_holders([t["path"] for t in ts])
    for t in ts:
        t["holders"] = None if held is None else held[t["path"]]
        t["idle_days"] = max(0.0, (now - t["mtime"]) / 86400.0)
        t["removal_epoch"] = t["mtime"] + days_ * 86400.0
    return {"cleanup_days": days_, "cleanup_source": where, "liveness_unknown": why}


def store_sizes(projects, backups):
    """What ~/.claude/projects and pre-compact.sh's copies hold, on demand (du); None where du gave no total."""
    _, pb, _ = du_children(projects) if os.path.isdir(projects) else ({}, 0, "")
    try:
        copies = [e for e in os.scandir(backups) if e.name.startswith("transcript_") and e.name.endswith(".jsonl")]
    except OSError:
        copies = []
    bb = sum(e.stat(follow_symlinks=False).st_size for e in copies if e.is_file(follow_symlinks=False))
    return {"projects_dir": projects, "projects_bytes": pb, "backups_dir": backups, "backup_bytes": bb,
            "backup_files": len(copies)}


def print_transcripts(ts, mb, note=None):
    if not ts:
        return
    print("")
    print("Session transcripts of %g MB or more, largest first (CLAUDE_TRANSCRIPT_WARN_MB):" % mb)
    for t in ts:
        if "holders" not in t:
            print("  %s  %d compactions  %s" % (fmt(t["bytes"]), t["compactions"], shown(t["path"])))
            continue
        if t["holders"] is None:
            who = "?"
        elif t["holders"]:
            who = "open in pid " + ",".join(str(x) for x in t["holders"])
        else:
            who = "idle %.1f d" % t["idle_days"]
        print("  %s  %d compactions  last write %s  %s  Claude Code removes it %s  %s"
              % (fmt(t["bytes"]), t["compactions"], time.strftime("%Y-%m-%d", time.localtime(t["mtime"])), who,
                 time.strftime("%Y-%m-%d", time.localtime(t["removal_epoch"])), shown(t["path"])))
    if note:
        print("  Claude Code removes a session's transcript once it has been inactive %g days (%s). Nothing here"
              " deletes one: a transcript is still read after its session ends (`claude --resume`, and"
              " permission-friction, shadow-report, session-census and spend-report)." % (note["cleanup_days"], note["cleanup_source"]))
        print("  open in pid N: that process has the file open (lsof). idle: no process has it open, N days since"
              " its last write; that is not a claim that its session is over. ?: lsof could not tell%s."
              % (" (" + note["liveness_unknown"] + ")" if note["liveness_unknown"] else ""))


def guard_p90(log, calls=200, floor=50):
    """(ms, n): the p90 of each Bash call's slowest guard over the newest CALLS lines of bash-guards'
    timing log and its .1. A call's guards run together, so it waits for the slowest. ms is None
    under FLOOR calls. A column with no status (`at=EPOCH`) is not a guard's."""
    costs = []
    for p in (log, log + ".1"):
        try:
            with open(p, errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in reversed(lines):
            secs = []
            for c in line.rstrip("\n").split("\t")[2:]:
                v = c.partition("=")[2]
                t, _, rest = v.partition(":")
                if rest:
                    try:
                        secs.append(float(t))
                    except ValueError:
                        pass
            if secs:
                costs.append(max(secs))
                if len(costs) == calls:
                    break
        if len(costs) == calls:
            break
    if len(costs) < floor:
        return None, len(costs)
    costs.sort()
    return int(round(costs[math.ceil(0.9 * len(costs)) - 1] * 1000)), len(costs)


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
    # session-start names its own session from these; an older one skips them (not a number).
    big = big_transcripts(a.projects, a.transcript_mb * 1e6, limit=None)
    lines += ["transcript=%s %d %d" % (t["session"], t["bytes"], t["compactions"])
              for t in big[:10] if re.match(r"^[A-Za-z0-9_-]+$", t["session"])]
    # Written in the last 7 days: an idle one cannot be acted on from a new session.
    active = [t for t in big if now - t["mtime"] <= 7 * 86400]
    if active:
        lines.append("transcripts_active=%d %d %d" % (len(active), active[0]["bytes"], active[0]["compactions"]))
    lines.append("transcript_mb=%d" % round(a.transcript_mb))
    ms, n = guard_p90(a.timing_log)
    if ms is not None:
        lines += ["guard_p90_ms=%d" % ms, "guard_calls=%d" % n]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    new = a.out + ".new"
    with open(new, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(new, a.out)
    print("disk: %s holds %s; the Bazel root %s, %s of it in %d orphaned output bases%s"
          % (jobs, fmt(jobs_bytes), fmt(r["total_bytes"] or 0), fmt(r["orphan_bytes"]), r["orphans"],
             " (sizes are a floor: du could not read everything)" if partial else ""))
    return 0


def days_arg(v):
    f = float(v)
    if not f >= 0:
        raise argparse.ArgumentTypeError("not a number of days or hours: %s" % v)
    return f


def now_arg(v):
    try:
        f = float(v)
    except ValueError:
        f = float("nan")
    if not (math.isfinite(f) and f > 0):
        raise argparse.ArgumentTypeError("not a time in epoch seconds: %s" % v)
    return f


def stop(signum, frame):
    """TERM or HUP: unwind, so an entry under a quarantine name goes back (pinned_delete). A second
    signal is ignored, so it cannot cut that short."""
    for s in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN)
    raise SystemExit(128 + signum)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    for f in (sys.stdout, sys.stderr):
        f.reconfigure(errors="backslashreplace")  # a name or path no encoding can print still prints
    for s in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, stop)
    if apply_misplaced(argv):
        print("disk-space: --apply goes right after `prune`, `clone` or `bazel --sweep`, as the listing"
              " prints it, so the ask rule in settings.json sees it. Nothing deleted.", file=sys.stderr)
        return 2
    # No abbreviations: `--app` would be --apply where no ask rule looks.
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], allow_abbrev=False)
    sub = ap.add_subparsers(dest="cmd")
    jobs_default = os.path.join(HOME, ".claude", "jobs")
    projects_default = os.path.join(HOME, ".claude", "projects")
    p = sub.add_parser("report", help="each job folder", allow_abbrev=False)
    p.add_argument("--jobs", default=jobs_default)
    p.add_argument("--projects", default=projects_default)
    p.add_argument("--transcript-mb", type=days_arg, default=transcript_mb_default(),
                   help="list session transcripts this size or more (CLAUDE_TRANSCRIPT_WARN_MB, 150)")
    p.add_argument("--backups", default=os.path.expanduser(
        os.environ.get("CLAUDE_TRANSCRIPT_DIR") or os.path.join(HOME, ".claude", "transcripts")))
    p.add_argument("--settings", default=os.path.join(HOME, ".claude", "settings.json"),
                   help="where cleanupPeriodDays is read, for the date Claude Code removes a transcript (default 30 days)")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("bazel", help="each Bazel output base; --sweep for orphans", allow_abbrev=False)
    p.add_argument("--root", default=None)
    p.add_argument("--json", action="store_true")
    p.add_argument("--sweep", action="store_true", help="list orphaned output bases, with a digest")
    p.add_argument("--apply", metavar="DIGEST", help="with --sweep: delete exactly the listing with this digest")
    p = sub.add_parser("stamp", help="the totals, for session-start", allow_abbrev=False)
    p.add_argument("--jobs", default=jobs_default)
    p.add_argument("--root", default=None)
    p.add_argument("--out", default=os.path.join(HOME, ".claude", "state", "disk-usage"))
    p.add_argument("--projects", default=projects_default)
    p.add_argument("--transcript-mb", type=days_arg, default=transcript_mb_default(),
                   help="list session transcripts this size or more (CLAUDE_TRANSCRIPT_WARN_MB, 150)")
    p.add_argument("--timing-log", default=os.path.expanduser(
        os.environ.get("CLAUDE_GUARD_TIMING_LOG") or os.path.join(HOME, ".claude", "logs", "guard-timing.log")))
    p = sub.add_parser("prune", help="old job tmp entries safe to delete, with a digest", allow_abbrev=False)
    p.add_argument("--jobs", default=jobs_default)
    p.add_argument("--root", default=None, help="the Bazel output root, for output bases inside an entry")
    p.add_argument("--days", type=days_arg, default=7.0)
    p.add_argument("--live-hours", type=days_arg, default=24.0)
    p.add_argument("--allow-untracked", action="store_true")
    p.add_argument("--now", type=now_arg, metavar="EPOCH", help="count ages from this time, not the clock")
    p.add_argument("--json", action="store_true")
    p.add_argument("--apply", metavar="DIGEST", help="delete exactly the listing with this digest")
    p = sub.add_parser("clone", help="a clone and its Bazel output bases, with a digest", allow_abbrev=False)
    p.add_argument("--apply", metavar="DIGEST", help="delete exactly the listing with this digest")
    p.add_argument("path")
    p.add_argument("--jobs", default=jobs_default, help="the job folders whose live sessions keep their folders")
    p.add_argument("--root", default=None, help="the Bazel output root")
    p.add_argument("--live-hours", type=days_arg, default=24.0)
    p.add_argument("--allow-untracked", action="store_true")
    p.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if getattr(a, "root", None) is None and a.cmd in ("bazel", "stamp", "prune", "clone"):
        a.root = default_bazel_root()
    now = time.time()
    if a.cmd == "report":
        r = jobs_report(a.jobs, now)
        r["transcripts"] = big_transcripts(a.projects, a.transcript_mb * 1e6, limit=None)
        tnote = annotate_transcripts(r["transcripts"], a.settings, now)
        r.update(tnote)
        r.update(store_sizes(a.projects, a.backups))
        if a.json:
            print(json.dumps(r, indent=1))
        else:
            print_jobs(r)
            print("")
            print("Transcripts: %s holds %s (du); pre-compact.sh's copies in %s, %s in %d files"
                  % (shown(r["projects_dir"]), fmt(r["projects_bytes"]) if r["projects_bytes"] is not None else "an unknown size",
                     shown(r["backups_dir"]), fmt(r["backup_bytes"]), r["backup_files"]))
            print_transcripts(r["transcripts"], a.transcript_mb, tnote)
        return 0
    if a.cmd == "prune":
        return cmd_prune(a)
    if a.cmd == "clone":
        return cmd_clone(a)
    if a.cmd == "bazel" and a.sweep:
        return cmd_sweep(a)
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
