#!/usr/bin/env python3
"""The hook a transcript's hook record names, for hook-latency.py and permission-friction.py.

Up to Claude Code 2.1.314 a record's `command` is the hook's command line. From 2.1.319 it is
"command hook N": the Nth distinct command among that event's hooks in settings.json, every
matcher in order, a repeated command counted once. Records whose output names the hook agree:
config-guard is 7 on Edit as on Bash, and with audit.sh three times first on PostToolUse,
tcc-check is 4 and memory-lint 2.

  tools/hooknames.py PreToolUse 4 [--settings PATH]   the hook a record calls "command hook 4"
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
    uniq = list(dict.fromkeys(hooks.get(event) or []))
    return script_name(uniq[n - 1]) if 0 < n <= len(uniq) else f"hook {n}"


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="the hook a transcript record calls \"command hook N\"")
    ap.add_argument("event")
    ap.add_argument("n", type=int)
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    a = ap.parse_args()
    print(label(f"command hook {a.n}", a.event, settings_hooks(a.settings)))
