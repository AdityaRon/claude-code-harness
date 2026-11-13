"""The hook a transcript's hook record names, for hook-latency.py and permission-friction.py.

Up to Claude Code 2.1.314 a record's `command` is the hook's command line. From 2.1.319 it is
"command hook N": the Nth command hook of that event in settings.json, every matcher in order,
an entry repeated later keeping its first number (config-guard is 7 on Edit as on Bash, network-
guard 5 on WebFetch). No record here numbers an entry after a repeat, so where counting repeats
or skipping them gives different hooks, both are named.
"""
import json
import os
import re

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
    flat = hooks.get(event) or []
    uniq = list(dict.fromkeys(flat))
    a = script_name(flat[n - 1]) if n <= len(flat) else None
    b = script_name(uniq[n - 1]) if n <= len(uniq) else None
    if a and b and a != b:
        return f"hook {n} ({a} or {b})"
    return a or b or f"hook {n}"
