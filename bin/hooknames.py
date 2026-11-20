#!/usr/bin/env python3
"""The hook a transcript's hook record names, for hook-latency.py and permission-friction.py,
and what each Bash guard did inside hooks/bash-guards.sh, from its timing log.

Up to Claude Code 2.1.314 a record's `command` is the hook's command line. From 2.1.319 it is
"command hook N": the Nth distinct command among that event's hooks in settings.json, every
matcher in order, a repeated command counted once. Records whose output names the hook agree:
config-guard is 7 on Edit as on Bash, and with audit.sh three times first on PostToolUse,
tcc-check is 4 and memory-lint 2.

That is settings.json as it is now, so a record from before a change can be named for the
hook now at its number. name_from_output names a numbered record by the guard whose words
are in the decision reason on its own stdout instead, and never reads its stderr.

  bin/hooknames.py PreToolUse 4 [--settings PATH]   the hook a record calls "command hook 4"

Also the --days or --since window the report tools share (add_window, window).
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess

NTH = re.compile(r"command hook (\d+)")


def settings_hooks(path):
    """{event: [command, ...]}, the command hooks of each event in settings order."""
    try:
        with open(path) as f:
            s = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    for ev, groups in (s.get("hooks") or {}).items():
        if not isinstance(groups, list):
            continue
        cmds = []
        for g in groups:
            for h in (g or {}).get("hooks") or []:
                if isinstance(h, dict) and h.get("type", "command") == "command" and h.get("command"):
                    cmds.append(h["command"])
        out[ev] = cmds
    return out


def script_name(cmd):
    toks = str(cmd).split()
    if not toks:
        return "?"
    pick = next((t for t in toks if re.search(r"\.(sh|py)$", t)), toks[0])
    return os.path.basename(pick.strip("\"'"))


def numbered(cmd):
    return bool(NTH.fullmatch(str(cmd)))


def label(cmd, event, hooks):
    """The script a record's command names; `event` is hookName's part before the colon."""
    m = NTH.fullmatch(str(cmd))
    if not m:
        return script_name(cmd)
    n = int(m[1])
    uniq = list(dict.fromkeys(hooks.get(event) or []))
    return script_name(uniq[n - 1]) if 0 < n <= len(uniq) else f"hook {n}"


def read_timing(path=None, stamps=None):
    """bash-guards' timing log and its rotated copy: tool_use_id -> [(guard, seconds, status, decision)].

    One line a call: the id, the tool, then guard=seconds:status:decision for each guard that
    ran. seconds is None where the hook wrote '-' (an answer that went missing); status is the
    guard's exit status, 'lost', or 'late' (no answer by bash-guards' deadline). A line written since the dispatcher's jq stamped it ends in
    at=EPOCH, the second it read the call; pass a dict as stamps to get tool_use_id -> that epoch.
    An older line has no time of day: join its id to a transcript.
    """
    path = os.path.expanduser(path or os.environ.get("CLAUDE_GUARD_TIMING_LOG") or "~/.claude/logs/guard-timing.log")
    out = {}
    for p in (path + ".1", path):
        try:
            f = open(p, errors="replace")
        except OSError:
            continue
        with f:
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 3 or cols[0] == "-":
                    continue
                per = []
                for c in cols[2:]:
                    if c.startswith("at="):
                        if stamps is not None and c[3:].isdigit():
                            stamps[cols[0]] = int(c[3:])
                        continue
                    g, _, v = c.partition("=")
                    secs, _, rest = v.partition(":")
                    status, _, decision = rest.partition(":")
                    if not g or not status:
                        continue   # not a column the hook writes
                    try:
                        s = float(secs)
                    except ValueError:
                        s = None
                    per.append((g, s, status, decision))
                out[cols[0]] = per
    return out


# ---- the window a report reads ------------------------------------------------
def parse_since(s):
    """An ISO 8601 date or time as an aware UTC datetime. One with no zone is UTC, and a
    trailing Z is +00:00: Python 3.9's fromisoformat, macOS's /usr/bin/python3, rejects Z."""
    t = str(s).strip()
    if t[-1:] in ("Z", "z"):
        t = t[:-1] + "+00:00"
    try:
        d = dt.datetime.fromisoformat(t)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an ISO 8601 date or time: {s!r}") from None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone(dt.timezone.utc)


def add_window(ap, days, kind=float):
    """--days N or --since WHEN, not both."""
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--days", type=kind, default=None, help=f"the last N days (default {days:g})")
    g.add_argument("--since", type=parse_since, default=None,
                   help="from this ISO 8601 date or time on, e.g. 2026-10-19 or 2026-10-19T08:00:00Z; one with no zone is UTC")
    ap.set_defaults(window_days=days)


def window(a, now):
    """(start, words): where the window starts, and how a report names it. Sets a.days."""
    if a.since is not None:
        return a.since, f"since {a.since:%Y-%m-%d %H:%M} UTC"
    if a.days is None:
        a.days = a.window_days
    return now - dt.timedelta(days=a.days), f"last {a.days:g} days"


# ---- the guard a reason names -------------------------------------------------
# A "command hook N" record names today's Nth hook, so after a settings.json change
# it can name the wrong one: an ask from kubectl-guard read as mod-gate's. A guard's
# own message does not move with the layout. GuardReasons reads every message each
# hooks/*.sh has held in the clone's history (a removed rule's too), keeps the
# literal runs only one guard ever wrote, and names the guards a reason holds.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAGMENT_MIN = 20   # shorter runs ("Mod '") are shared or say nothing
_PIECES = re.compile(r"\$\{[^}]*\}|\$\(|\$\w+|\\.")


def _hook_texts(repo, hooks_dir):
    """[(guard, file text)] for every version of hooks/*.sh in repo's history, else the files in hooks_dir."""
    out = []
    try:
        if not os.path.isdir(os.path.join(repo, "hooks")):   # installed flat in ~/.claude: no clone above it
            raise OSError("no clone")
        objs = subprocess.run(["git", "-C", repo, "rev-list", "--objects", "--all", "--", "hooks"],
                              capture_output=True, text=True, timeout=120, check=True).stdout.splitlines()
        # Not lib.sh: every guard sourced it, so its words are no one guard's.
        blobs = [ln.split(" ", 1) for ln in objs if re.fullmatch(r"[0-9a-f]+ hooks/[^/]+\.sh", ln) and not ln.endswith(" hooks/lib.sh")]
        raw = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], input="".join(b + "\n" for b, _ in blobs).encode(),
                             capture_output=True, timeout=120, check=True).stdout
        pos = 0
        for _, path in blobs:
            end = raw.index(b"\n", pos)
            size = int(raw[pos:end].split()[2])
            out.append((os.path.basename(path)[:-3], raw[end + 1:end + 1 + size].decode("utf-8", "replace")))
            pos = end + 1 + size + 1
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        out = []
    if not out:
        for f in (f for f in glob.glob(os.path.join(hooks_dir, "*.sh")) if not f.endswith("/lib.sh")):
            try:
                with open(f, errors="replace") as fh:
                    out.append((os.path.basename(f)[:-3], fh.read()))
            except OSError:
                pass
    return out


class GuardReasons:
    def __init__(self, repo=REPO, hooks_dir=os.path.expanduser("~/.claude/hooks")):
        self.repo, self.hooks_dir, self.table, self.names = repo, hooks_dir, None, set()

    def _build(self):
        owners = {}
        for g, text in _hook_texts(self.repo, self.hooks_dir):
            self.names.add(g)
            # Quotes pair within a line: a stray one elsewhere would shift every pair after it.
            for line in text.split("\n"):
                for s in re.findall(r'"((?:[^"\\]|\\.)*)"', line):
                    for piece in _PIECES.split(s):
                        piece = piece.strip()
                        if len(piece) >= FRAGMENT_MIN and " " in piece:
                            owners.setdefault(piece, set()).add(g)
        self.table = [(p, next(iter(gs))) for p, gs in owners.items() if len(gs) == 1]

    def guards(self, reason):
        """The guards whose own words are in reason: a leading "<guard>: " names one outright."""
        if self.table is None:
            self._build()
        m = re.match(r"([a-z][a-z-]*):", reason or "")
        if m and m.group(1) in self.names:
            return {m.group(1)}
        return {g for p, g in self.table if p in (reason or "")}


# ---- the guard a record's own output names ------------------------------------
# Only the hook's stdout. Its stderr carries whatever ran under it: bash's
# "shell-init: ... Operation not permitted" holds words tcc-check.sh quotes, so
# matching stderr named 216 records tcc-check that another hook wrote (records
# that carry their command, 30 days on the maintainer's Mac, 2026-11-16).
def output_reason(at):
    """The decision reason in a hook record's own stdout, else "".

    hook_success and hook_non_blocking_error keep stdout apart: the reason is its JSON
    hookSpecificOutput.permissionDecisionReason. hook_blocking_error keeps one text. An exit
    2's stderr comes labelled "[<command>]: " and is not read: 85 of the 87 on the maintainer's
    Mac are labelled, and tcc-check, memory-lint and comment-budget, the hooks here that exit 2,
    put their message on stderr. Unlabelled, it is taken as the reason a {"decision": "block"}
    put on stdout: inferred from the other two, not measured.
    """
    if at.get("type") == "hook_blocking_error":
        be = at.get("blockingError") or {}
        text, cmd = be.get("blockingError"), be.get("command")
        if not isinstance(text, str) or not cmd or text.startswith(f"[{cmd}]: "):
            return ""
        return text
    try:
        out = json.loads(at.get("stdout") or "")
    except (TypeError, ValueError):
        return ""
    hs = out.get("hookSpecificOutput") if isinstance(out, dict) else None
    why = hs.get("permissionDecisionReason") if isinstance(hs, dict) else None
    return why if isinstance(why, str) else ""


def name_from_output(at, reasons):
    """The guards a GuardReasons finds in the record's own stdout reason, a set; None when it names none."""
    why = output_reason(at)
    return (reasons.guards(why) or None) if why.strip() else None


def bash_guards(dirs=(os.path.join(REPO, "hooks"), os.path.expanduser("~/.claude/hooks"))):
    """The guards hooks/bash-guards.sh runs in one hook, from its BG_GUARDS line."""
    for d in dirs:
        try:
            with open(os.path.join(d, "bash-guards.sh"), errors="replace") as f:
                m = re.search(r"^BG_GUARDS=\(([^)]*)\)", f.read(), re.M)
        except OSError:
            continue
        if m:
            return set(m.group(1).split())
    return set()


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="the hook a transcript record calls \"command hook N\"")
    ap.add_argument("event")
    ap.add_argument("n", type=int)
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    a = ap.parse_args()
    print(label(f"command hook {a.n}", a.event, settings_hooks(a.settings)))
