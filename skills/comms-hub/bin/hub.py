"""Shared pieces of the comms-hub scripts: config, state paths, the gh runner,
review state and CI state. Imported by the scripts beside it; run directly:

  hub.py init         write the config from the example, with the login, owners and
                      zone this machine knows; refuses to touch an existing one
  hub.py config [--transcript FILE]
                      the config path, the state dir, the ids, or what is wrong with the config;
                      and how much context a compaction leaves the comms session, from its
                      transcript (found by its tick prompt, or FILE), with a WARN when the
                      compact window leaves under 100k tokens to work in
  hub.py log --kind KIND [--ref REF] [--target ID] [--who WHO] [--needs-user] [--corrects ID]
             [--at HH:MM] [--detail TEXT] TEXT
                      one event in today's log: a JSONL row the panel draws, and an .md line.
                      TEXT is what the panel shows: 80 characters, words only. A link is --ref,
                      a channel --target, the rest --detail. --needs-user puts it under Needs
                      you until a row --corrects it; --at is when it happened, if not now.
                      Without --kind, as a session on an older skill calls it: a note, with
                      what TEXT may not hold moved to the detail, and a warning on stderr
  hub.py panel        what the comms panel draws, as JSON
  hub.py queries [--control]
                      the three Slack mention searches, dated two days back; --control: the
                      same a week further back, which an empty search needs before it is quiet
  hub.py routed TEXT  the log lines of the last two days that mention TEXT (a link, a key); exit 1 if none
  hub.py feedback TEXT  append a dated correction to feedback.md, for the next change to the skill
  hub.py cron         the tick's cron expression, made from active_hours
  hub.py window [--margin MIN | --review] [--full-done]
                      open (exit 0) or closed (exit 1) for active_hours, and whether this tick
                      scans in full; --margin: closed too when it closes within MIN minutes,
                      --review within review_margin_minutes; --full-done records a full scan
  hub.py trigger [--live EXPR] [--created EXPR]
                      what is wrong with the tick's trigger: not the cron above, no record of
                      its creation, or due for renewal before Claude Code expires it (exit 1)
  hub.py launch [--check]
                      the command that starts the comms session, with the panel when it is
                      installed; --check: whether this session was started with it (exit 1 if not)
"""
from __future__ import annotations

import sys

if sys.version_info < (3, 10):
    sys.exit("comms-hub needs Python 3.10 or newer; this is %s. Run the script with "
             "python3.11 or newer (bash doctor.sh --skill comms-hub names one)." % sys.version.split()[0])

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path

PLACEHOLDER = "CHANGE-ME"
MAX_CHARS = 2500
DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
CADENCES = (10, 15, 20, 30, 60)
TICK_MINUTE = 7          # off the hour, when every other schedule fires
TRIGGER_RENEW_DAYS = 6   # Claude Code deletes a recurring task 7 days after it was created
KNOWN_BOTS: set[str] = set()  # github.bots from the config, lower-cased; load_config fills it


def _bind_stdlib_queue():
    """This directory holds queue.py and leads sys.path, so the stdlib `queue`
    that concurrent.futures imports would resolve to that script. Bind the real
    one first, with this directory out of the way."""
    here = os.path.dirname(os.path.abspath(__file__))
    saved = sys.path[:]
    sys.path[:] = [p for p in saved if os.path.abspath(p or os.curdir) != here]
    try:
        import queue  # noqa: F401
    finally:
        sys.path[:] = saved


_bind_stdlib_queue()


class ConfigError(Exception):
    pass


class GhError(Exception):
    pass


def _toml():
    try:
        import tomllib
        return tomllib
    except ModuleNotFoundError:
        try:
            import tomli
            return tomli
        except ModuleNotFoundError:
            sys.exit("comms-hub reads TOML: Python 3.11+ has tomllib; on 3.10 run "
                     "`python3 -m pip install --user tomli`.")


def config_path(explicit: str | None = None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    if os.environ.get("COMMS_HUB_CONFIG"):
        return Path(os.environ["COMMS_HUB_CONFIG"]).expanduser()
    base = os.environ.get("XDG_CONFIG_HOME") or "~/.config"
    return Path(base).expanduser() / "comms-hub" / "config.toml"


def placeholders(value, key: str = ""):
    """The dotted keys whose value still reads CHANGE-ME, each once."""
    if isinstance(value, str):
        if PLACEHOLDER in value:
            yield key
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from placeholders(v, f"{key}.{k}" if key else k)
    elif isinstance(value, list):
        seen = set()
        for v in value:
            for k in placeholders(v, key):
                if k not in seen:
                    seen.add(k)
                    yield k


def example_path() -> Path:
    return Path(__file__).resolve().parent.parent / "config.example.toml"


def load_config(explicit: str | None = None) -> dict:
    """The config with defaults filled in. Raises ConfigError naming the key."""
    path = config_path(explicit)
    if not path.is_file():
        raise ConfigError(f"no config at {path}: `{sys.executable} {os.path.abspath(__file__)} init` "
                          f"writes one from {example_path()}")
    try:
        cfg = _toml().loads(path.read_text())
    except Exception as e:  # tomllib.TOMLDecodeError, or tomli's
        raise ConfigError(f"{path}: not valid TOML: {e}")
    left = list(placeholders(cfg))
    if left:
        raise ConfigError(f"{path}: still {PLACEHOLDER}: {', '.join(left)}")
    gh = cfg.setdefault("github", {})
    if not gh.get("login"):
        raise ConfigError(f"{path}: github.login is required (`gh api user --jq .login` prints yours)")
    if not gh.get("owners"):
        raise ConfigError(f"{path}: github.owners needs at least one org or user, such as your login")
    gh.setdefault("watch_repos", [])
    gh.setdefault("watch_authors", [])
    gh.setdefault("merged_days", 7)
    gh.setdefault("bots", [])
    gh.setdefault("review_max_chars", MAX_CHARS)
    KNOWN_BOTS.clear()
    KNOWN_BOTS.update(str(b).lower() for b in gh["bots"])
    cfg.setdefault("slack", {}).setdefault("max_chars", MAX_CHARS)
    cfg["slack"].setdefault("github_logins", {})
    # The panel's names for what the log holds as ids and links.
    for table, key in ((gh, "repo_aliases"), (cfg["slack"], "channel_names")):
        names = table.setdefault(key, {})
        if not isinstance(names, dict) or not all(isinstance(v, str) for v in names.values()):
            raise ConfigError(f"{path}: {'github' if table is gh else 'slack'}.{key} must map strings to names")
    # Slack's API takes the name bare; a config copied from the client often has the colons.
    ack = str(cfg["slack"].setdefault("ack_reaction", "white_check_mark")).strip(":")
    if not re.fullmatch(r"[\w+'.-]+", ack):
        raise ConfigError(f"{path}: slack.ack_reaction must be an emoji name such as white_check_mark, "
                          f"not {cfg['slack']['ack_reaction']!r}")
    cfg["slack"]["ack_reaction"] = ack
    q = cfg.setdefault("quiet_hours", {})
    q.setdefault("start", "19:00")
    q.setdefault("post_at", "08:30")
    for k in ("start", "post_at"):
        try:
            if not re.fullmatch(r"\d{2}:\d{2}", str(q[k])):
                raise ValueError
            dt.time.fromisoformat(q[k])
        except ValueError:
            raise ConfigError(f"{path}: quiet_hours.{k} must be HH:MM, not {q[k]!r}")
    # A fixed UTC offset would schedule across a DST change an hour off.
    if not q.get("tz"):
        raise ConfigError(f'{path}: quiet_hours.tz is required, an IANA zone such as "Europe/Berlin"'
                          + (f" (this machine's is {system_zone()})" if system_zone() else ""))
    from zoneinfo import ZoneInfo
    try:
        ZoneInfo(q["tz"])
    except (KeyError, ValueError) as e:  # ZoneInfoNotFoundError is a KeyError
        raise ConfigError(f"{path}: quiet_hours.tz {q['tz']!r} is not an IANA zone: {e}")
    a = cfg.setdefault("active_hours", {})
    a.setdefault("days", list(DAYS[:5]))
    a.setdefault("start", "08:00")
    a.setdefault("end", "18:00")
    a.setdefault("every_minutes", 30)
    a.setdefault("review_margin_minutes", 120)
    a.setdefault("full_scan_minutes", 120)
    if not a["days"] or not isinstance(a["days"], list) or any(d not in DAYS for d in a["days"]):
        raise ConfigError(f"{path}: active_hours.days must list days from {', '.join(DAYS)}, not {a['days']!r}")
    for k in ("start", "end"):
        # The trigger's hour field cannot start or stop a window mid-hour.
        if not re.fullmatch(r"([01]\d|2[0-3]):00|24:00", str(a[k])) or (k == "start" and a[k] == "24:00"):
            raise ConfigError(f"{path}: active_hours.{k} must be a whole hour, HH:00, not {a[k]!r}")
    if a["start"] >= a["end"]:
        raise ConfigError(f"{path}: active_hours.start {a['start']} must come before end {a['end']}")
    if a["every_minutes"] not in CADENCES:
        raise ConfigError(f"{path}: active_hours.every_minutes must be one of {CADENCES}, not {a['every_minutes']!r}")
    # The Slack tools cannot delete a scheduled message, so the morning tick must
    # gate an overnight one again before it posts.
    first = f"{a['start'][:2]}:{TICK_MINUTE:02d}"
    if q["post_at"] <= first:
        raise ConfigError(f"{path}: quiet_hours.post_at {q['post_at']} must come after the first tick, {first}: "
                          "a message scheduled overnight would post before any tick could gate it again, "
                          "and the Slack tools cannot delete it")
    se = cfg.setdefault("session", {})
    # 150k compacted at ~118k with 77-94k back after each: 10 compactions in a day.
    se.setdefault("compact_window", 600_000)
    se.setdefault("mcp_timeout_ms", 120_000)
    if not isinstance(se["compact_window"], int) or not 100_000 <= se["compact_window"] <= 1_000_000:
        raise ConfigError(f"{path}: session.compact_window must be 100000 to 1000000 tokens, not {se['compact_window']!r}")
    if not isinstance(se["mcp_timeout_ms"], int) or se["mcp_timeout_ms"] < 1000:
        raise ConfigError(f"{path}: session.mcp_timeout_ms must be 1000 or more, not {se['mcp_timeout_ms']!r}")
    for r in cfg.setdefault("routing", []):
        for k in ("repos", "tickets", "channels"):
            r.setdefault(k, [])
    cfg["_path"] = str(path)
    return cfg


def state_dir(cfg: dict | None = None) -> Path:
    if os.environ.get("COMMS_HUB_STATE_DIR"):
        d = Path(os.environ["COMMS_HUB_STATE_DIR"])
    elif cfg and cfg.get("state_dir"):
        d = Path(cfg["state_dir"])
    else:
        d = Path(os.environ.get("XDG_STATE_HOME") or "~/.local/state") / "comms-hub"
    d = d.expanduser()
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def tmp_dir(cfg: dict | None = None) -> Path:
    """Where dumps, listings and drafts go: the session's job tmp when Claude
    Code set one, else under the state dir. Never /tmp, which every job shares."""
    if os.environ.get("CLAUDE_JOB_DIR"):
        d = Path(os.environ["CLAUDE_JOB_DIR"]) / "tmp"
    else:
        d = state_dir(cfg) / "tmp"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _valid_zone(name: str) -> bool:
    from zoneinfo import ZoneInfo
    try:
        ZoneInfo(name)
    except (KeyError, ValueError):  # ZoneInfoNotFoundError is a KeyError
        return False
    return True


def system_zone() -> str | None:
    """This machine's IANA zone, or None: $TZ, then the /etc/localtime link
    (macOS and most Linux), then /etc/timezone (Debian). A copied, unlinked
    /etc/localtime has no name, so the config has to say."""
    names = [os.environ.get("TZ") or ""]
    names.append(os.path.realpath("/etc/localtime").partition("zoneinfo/")[2])
    try:
        names.append(Path("/etc/timezone").read_text().strip())
    except OSError:
        pass
    for n in names:
        if re.fullmatch(r"[A-Za-z_]+(/[A-Za-z0-9_+-]+)+", n) and _valid_zone(n):
            return n
    return None


def now() -> dt.datetime:
    """Aware current time. COMMS_HUB_NOW (ISO 8601) pins it for tests."""
    pinned = os.environ.get("COMMS_HUB_NOW")
    if pinned:
        return parse_time(pinned)
    return dt.datetime.now(dt.timezone.utc)


def parse_time(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def zone(cfg: dict):
    from zoneinfo import ZoneInfo
    return ZoneInfo(cfg["quiet_hours"]["tz"])


def local_now(cfg: dict | None) -> dt.datetime:
    """Now in quiet_hours.tz, so a day's log and sent/ folder are the day the
    quiet hours count; the machine's own zone only when there is no config."""
    t = now()
    return t.astimezone(zone(cfg)) if cfg and cfg.get("quiet_hours", {}).get("tz") else t.astimezone()


def send_plan(cfg: dict, at: dt.datetime) -> tuple[str, dt.datetime | None]:
    """("live", None), or ("schedule", post_at) when `at` falls in quiet hours."""
    q = cfg["quiet_hours"]
    start = dt.time.fromisoformat(q["start"])
    post = dt.time.fromisoformat(q["post_at"])
    tz = zone(cfg)
    local = at.astimezone(tz)
    t = local.time()
    quiet = (start <= t < post) if start <= post else (t >= start or t < post)
    if not quiet:
        return "live", None
    day = local.date() if t < post else local.date() + dt.timedelta(days=1)
    # No tick runs on an inactive day to gate it again before it posts.
    while DAYS[day.weekday()] not in cfg["active_hours"]["days"]:
        day += dt.timedelta(days=1)
    return "schedule", dt.datetime.combine(day, post, tzinfo=tz)


def first_tick_after_quiet(cfg: dict, prev: dt.datetime | None, at: dt.datetime) -> bool:
    """True once a day: `at` is live and `prev` was before today's end of quiet
    hours, whether that was last evening or a tick the laptop slept through."""
    if prev is None or send_plan(cfg, at)[0] != "live":
        return False
    tz = zone(cfg)
    end = dt.datetime.combine(at.astimezone(tz).date(), dt.time.fromisoformat(cfg["quiet_hours"]["post_at"]), tzinfo=tz)
    return prev < end <= at


def _ranges(nums: list[int]) -> str:
    """[1, 2, 3, 5] -> "1-3,5"."""
    out, i = [], 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        out.append(str(nums[i]) if i == j else f"{nums[i]}-{nums[j]}")
        i = j + 1
    return ",".join(out)


def cron(cfg: dict) -> str:
    """The tick's trigger for active_hours, as standard 5-field cron. Claude Code
    reads it in this machine's zone, so trigger_problems() checks that zone."""
    a = cfg["active_hours"]
    minutes = ",".join(str(m) for m in range(TICK_MINUTE, 60, a["every_minutes"]))
    first, last = int(a["start"][:2]), int(a["end"][:2]) - 1
    hours = str(first) if first == last else f"{first}-{last}"
    days = sorted((DAYS.index(d) + 1) % 7 for d in a["days"])  # cron counts from Sunday, 0
    return f"{minutes} {hours} * * {_ranges(days)}"


def window(cfg: dict, at: dt.datetime) -> tuple[dt.datetime | None, dt.datetime | None]:
    """(today's close, None) while active_hours are open, else (None, the next opening)."""
    a, tz = cfg["active_hours"], zone(cfg)
    local = at.astimezone(tz)
    start = dt.time.fromisoformat(a["start"])
    end = dt.time(0) if a["end"] == "24:00" else dt.time.fromisoformat(a["end"])
    workday = lambda d: DAYS[d.weekday()] in a["days"]
    if workday(local.date()) and start <= local.time() and (a["end"] == "24:00" or local.time() < end):
        close = dt.datetime.combine(local.date() + dt.timedelta(days=a["end"] == "24:00"), end, tzinfo=tz)
        return close, None
    day = local.date()
    if not (workday(day) and local.time() < start):
        day += dt.timedelta(days=1)
        while not workday(day):
            day += dt.timedelta(days=1)
    return None, dt.datetime.combine(day, start, tzinfo=tz)


def _record(cfg: dict, name: str) -> dict:
    try:
        return json.loads((state_dir(cfg) / name).read_text())
    except (OSError, ValueError):
        return {}


def scan_plan(cfg: dict, at: dt.datetime) -> str:
    """"full" on the window's first tick and once full_scan_minutes have passed
    since the last full scan finished, else "quick"."""
    a, tz = cfg["active_hours"], zone(cfg)
    last = parse_time(_record(cfg, "tick.json").get("full"))
    opened = dt.datetime.combine(at.astimezone(tz).date(), dt.time.fromisoformat(a["start"]), tzinfo=tz)
    if last is None or last < opened or at - last >= dt.timedelta(minutes=a["full_scan_minutes"]):
        return "full"
    return "quick"


def trigger_problems(cfg: dict, at: dt.datetime, live: str | None = None) -> list[str]:
    """What is wrong with the tick's trigger, each line naming the fix; [] when nothing."""
    want, out = cron(cfg), []
    fix = f"delete it with CronDelete, create {want!r} with CronCreate, then `hub.py trigger --created {want!r}`"
    if live is not None and " ".join(live.split()) != want:
        out.append(f"MISMATCH: the live trigger is {' '.join(live.split())!r}, active_hours make {want!r}: {fix}")
    tz = zone(cfg)
    if at.astimezone().utcoffset() != at.astimezone(tz).utcoffset():
        out.append(f"ZONE: this machine's clock is UTC{at.astimezone():%z} and quiet_hours.tz {tz.key} is "
                   f"UTC{at.astimezone(tz):%z}; the trigger fires by the machine's clock, so its hours are off")
    rec = _record(cfg, "trigger.json")
    created = parse_time(rec.get("created"))
    if created is None:
        out.append(f"NONE: no record of when the trigger was created, so its 7-day expiry is unknown: {fix}")
    elif rec.get("expr") != want:
        out.append(f"MISMATCH: the trigger was created as {rec.get('expr')!r}, active_hours make {want!r}: {fix}")
    elif at - created >= dt.timedelta(days=TRIGGER_RENEW_DAYS):
        out.append(f"RENEW: created {created.astimezone(tz):%Y-%m-%d}, and Claude Code deletes a recurring task "
                   f"7 days after it was created: {fix}")
    return out


def launch_env(cfg: dict) -> dict[str, str]:
    """The comms session's own env. Passed with --settings: a value exported in the
    shell loses to ~/.claude/settings.json's env, which sets the compact window."""
    s = cfg["session"]
    return {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": str(s["compact_window"]), "MCP_TOOL_TIMEOUT": str(s["mcp_timeout_ms"])}


def panel_dir() -> Path | None:
    """The skill's panel mod beside bin/: held drafts and today's log in a pane.
    Only the comms session loads it, through the command `launch` prints."""
    p = Path(__file__).resolve().parent.parent / "panel"
    return p if (p / ".claude-plugin" / "plugin.json").is_file() else None


def _tokens(v: str | None) -> int | None:
    m = re.fullmatch(r"(\d+)([kKmM]?)", (v or "").strip())
    return int(m[1]) * {"": 1, "k": 1000, "m": 1_000_000}[m[2].lower()] if m else None


def launch_problems(cfg: dict, env) -> list[str]:
    """The window must match: a smaller one compacts every few ticks, which a
    `want or less` check let a session started at the old 150k pass."""
    out = []
    for k, want in launch_env(cfg).items():
        have = _tokens(env.get(k))
        exact = k == "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
        if have is None or (have != int(want) if exact else have > int(want)):
            out.append(f"{k} is {env.get(k) or 'unset'} in this session, want {want}" + ("" if exact else " or less"))
    return out


# Room a compaction must leave to work in: below it, the session compacts again within a tick or two.
ROOM_MIN = 100_000


def projects_root() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def tick_transcript(root: Path, prompt: str = "comms-hub tick", days: int = 2) -> Path | None:
    """The newest session transcript, not a subagent's, with a user turn that
    starts with the tick prompt. The prompt also appears in subagent
    transcripts and in tool calls that quote it, so only a user record counts."""
    cutoff = time.time() - days * 86400
    found = []
    for p in root.glob("*/*.jsonl") if root.is_dir() else []:
        try:
            if p.stat().st_mtime >= cutoff:
                found.append((p.stat().st_mtime, p))
        except OSError:
            continue
    for _, p in sorted(found, reverse=True):
        with p.open(errors="replace") as f:
            for line in f:
                if prompt not in line or '"user"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                c = (d.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                if d.get("type") == "user" and isinstance(c, str) and c.strip().startswith(prompt):
                    return p
    return None


def compaction_baseline(path: Path) -> tuple[int, int | None, str]:
    """(compactions, tokens the latest left, when): the context the first call
    after the latest compact_boundary carried, input plus cache read and write."""
    count, base, when, after = 0, None, "", False
    with path.open(errors="replace") as f:
        for line in f:
            if "compact_boundary" in line:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
                    count, base, when, after = count + 1, None, d.get("timestamp") or "", True
                continue
            if after and '"assistant"' in line and '"usage"' in line:
                try:
                    u = ((json.loads(line).get("message") or {}).get("usage")) or {}
                except ValueError:
                    continue
                if u:
                    base = sum(int(u.get(k) or 0) for k in
                               ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                    after = False
    return count, base, when


def compaction_lines(cfg: dict, transcript: Path | None) -> list[str]:
    window = cfg["session"]["compact_window"]
    if transcript is None:
        return [f"compact: window {window}; no transcript with a 'comms-hub tick' prompt in the last 2 days, "
                "so what a compaction leaves is unknown (--transcript FILE names one)"]
    count, base, when = compaction_baseline(transcript)
    where = f"session {transcript.stem[:8]}"
    if not count:
        return [f"compact: window {window}; {where} has not compacted yet"]
    if base is None:
        return [f"compact: window {window}; {where} compacted {count}x, nothing has run since the latest"]
    lines = [f"compact: window {window}; {where} compacted {count}x, the latest at {when[:16]} left {base // 1000}k, "
             f"so {max(0, window - base) // 1000}k to work in"]
    if window - base < ROOM_MIN:
        lines.append(f"WARN: under {ROOM_MIN // 1000}k to work in after a compaction: the session compacts again "
                     "within a tick or two. Raise session.compact_window (600000 on a 1M-context model), then "
                     "restart the session with the command `hub.py launch` prints")
    return lines


def mention_queries(uid: str, since: dt.date) -> list[str]:
    """The three Slack searches that together find what names me: the mention
    itself, a message or reply sent to me, and a thread I am in. One search
    missed replies each of the other two caught, one under a week-old thread.
    `after:` is exclusive, so the day is the one before the window starts."""
    day = f"after:{since:%Y-%m-%d}"
    return [f"<@{uid}> {day}", f"to:<@{uid}> {day}", f"with:<@{uid}> is:thread {day}"]


# An empty search is quiet only if the same query, reaching further back, finds
# rows: a filter Slack cannot read also returns nothing (an epoch filter once
# returned 0). A week, so a Monday's control reaches past the weekend.
CONTROL_DAYS = 7


def append_log(cfg: dict | None, line: str) -> Path:
    d = state_dir(cfg) / "log"
    d.mkdir(exist_ok=True)
    stamp = local_now(cfg)
    p = d / f"{stamp:%Y-%m-%d}.md"
    with p.open("a") as f:
        f.write(f"- {stamp:%H:%M} {line}\n")
    return p


# ---- log events, and what the panel shows -----------------------------------

# Each event is a JSONL row in log/<day>.jsonl, beside the .md line people read.
# The panel draws the rows: as prose, with urls, channel ids, thread ts and
# hashes, about 11 lines filled the pane and none could be scanned (2026-10-28).
LOG_KINDS = ("sent", "scheduled", "withdrawn", "reacted", "routed", "returned", "resolved", "reviewed",
             "held", "released", "asked", "answered", "blocked", "scan", "tick", "setup", "note", "todo", "done")
# The scan's own bookkeeping: work in flight (todo) and what closed it (done).
# Shown, they would fill the day's events and make a quiet tick read "3 items".
UNSHOWN = ("scan", "todo", "done")
TEXT_MAX = 80
NOT_TEXT = (
    (re.compile(r"\b[CDGU](?=[A-Z0-9]*\d)[A-Z0-9]{8,}\b"), "a Slack id (pass it as --target)"),
    (re.compile(r"\b\d{10}\.\d{6}\b"), "a thread ts"),
    (re.compile(r"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{12,}\b"), "a hash"),
    (re.compile(r"https?://"), "a link (pass it as --ref)"),
    (re.compile(r"^\d{1,2}:\d{2}\b"), "a time (pass it as --at)"),
)
OPEN_DAYS = 7   # how far back a question or a routed item stays open


def text_problem(text: str) -> str:
    """Why `text` cannot be an event's text, or '' when it can."""
    if not text:
        return "the text is empty"
    if len(text) > TEXT_MAX:
        return f"the text is {len(text)} characters, over {TEXT_MAX}: put the rest in --detail"
    for rx, what in NOT_TEXT:
        if rx.search(text):
            return f"the text holds {what}; name people and places in words"
    return ""


def _log_paths(cfg: dict | None, day: dt.date) -> tuple[Path, Path]:
    d = state_dir(cfg) / "log"
    return d / f"{day:%Y-%m-%d}.md", d / f"{day:%Y-%m-%d}.jsonl"


def log_event(cfg: dict, kind: str, text: str, ref: str = "", target: str = "", who: str = "",
              needs_user: bool = False, corrects: str = "", at: str = "", detail: str = "") -> dict:
    """Append one event: a JSONL row the panel reads and the .md line people read."""
    stamp = local_now(cfg)
    md, jl = _log_paths(cfg, stamp.date())
    md.parent.mkdir(exist_ok=True)
    n = len(jl.read_text().splitlines()) + 1 if jl.is_file() else 1
    row = {"id": f"{stamp:%m%d}.{n}", "ts": now().isoformat(), "at": at or f"{stamp:%H:%M}", "kind": kind,
           "text": " ".join(text.split()), "ref": ref, "target": target, "who": who,
           "needs_user": needs_user, "corrects": corrects or None, "detail": " ".join(detail.split())}
    with jl.open("a") as f:
        f.write(json.dumps(row) + "\n")
    with md.open("a") as f:
        f.write(f"- {row['at']} {kind}" + "".join(f" {v}" for v in (ref, target) if v)
                + (f" ({who})" if who else "") + f": {row['text']}" + (f" | {row['detail']}" if row["detail"] else "")
                + f" [{row['id']}" + (f", corrects {corrects}" if corrects else "") + "]\n")
    return row


# What the panel never shows (spec, 2026-10-28): ids, ts, hashes, paths. Only
# the .md lines from before the JSONL need it; a JSONL row's text is checked.
_SCRUB = (
    re.compile(r"\b(?:sha256|target|epoch|id|copy)=\S+"),
    re.compile(r"\b\d{10}\.\d{6}\b"),
    re.compile(r"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{12,}\b"),
    re.compile(r"\b(?=\w*[A-Z])(?=\w*[a-z])(?=\w*\d)[A-Za-z0-9]{10,}\b"),   # a scheduled message's id
    re.compile(r"(?:~|/)[\w.-]*(?:/[\w.@-]+){2,}"),
)
_URL = re.compile(r"https?://\S+")
_CHANNEL = re.compile(r"\b[CDG](?=[A-Z0-9]*\d)[A-Z0-9]{8,}\b")


def short_ref(cfg: dict, ref: str) -> str:
    """A PR as `<repo> #N` (github.repo_aliases, else the repo's name), a ticket as its key."""
    ref = ref.strip().rstrip(".,;)")
    m = re.search(r"github\.com/([\w.-]+)/([\w.-]+)/(?:pull|issues)/(\d+)", ref) \
        or re.fullmatch(r"([\w.-]+)/([\w.-]+)#(\d+)", ref)
    if m:
        return f"{cfg['github']['repo_aliases'].get(f'{m.group(1)}/{m.group(2)}', m.group(2))} #{m.group(3)}"
    m = re.search(r"/browse/([A-Z][A-Z0-9]+-\d+)", ref)
    if m:
        return m.group(1)
    if ref.startswith("http"):
        return ref.rstrip("/").rsplit("/", 1)[-1][:40]
    return ref


def target_label(cfg: dict, target: str) -> str:
    """A channel id as its name from slack.channel_names: `#name`, or `<name> DM` for a DM."""
    cid = (target.split() or [""])[0]
    name = cfg["slack"]["channel_names"].get(cid)
    if name:
        return f"{name} DM" if cid.startswith("D") else f"#{name}"
    if cid and cid == cfg["slack"].get("primary_dm"):
        return "primary DM"
    return cid


def scrub(cfg: dict, text: str) -> str:
    text = _URL.sub(lambda m: short_ref(cfg, m.group(0)), text)
    text = _CHANNEL.sub(lambda m: target_label(cfg, m.group(0)), text)
    for rx in _SCRUB:
        text = rx.sub("", text)
    return re.sub(r"\s+([,;:.)])", r"\1", " ".join(text.split()))


_LEGACY = re.compile(r"(\d{2}:\d{2}) (.*)")
_LEGACY_SENT = re.compile(r"(sent|scheduled) \S+ target=\S+ sha256=\w+(?:: (.*))?")
_LEGACY_WORD = re.compile(r"([A-Za-z]+)[:,]?\s+(.*)")


def _legacy_row(cfg: dict, day: dt.date, i: int, line: str) -> dict:
    """A .md line from a day with no JSONL, read as well as prose allows."""
    m = _LEGACY.fullmatch(line[2:])
    at, rest = (m.group(1), m.group(2)) if m else ("", line[2:])
    s = _LEGACY_SENT.fullmatch(rest)
    w = _LEGACY_WORD.fullmatch(rest)
    if s:
        kind, text = s.group(1), s.group(2) or s.group(1)
    elif w and w.group(1).lower() in LOG_KINDS:
        kind, text = w.group(1).lower(), w.group(2)
    else:
        kind, text = "note", rest
    when = dt.datetime.combine(day, dt.time.fromisoformat(at) if at else dt.time(0), tzinfo=zone(cfg))
    return {"id": f"{day:%m%d}.md{i}", "ts": when.isoformat(), "at": at, "kind": kind, "text": scrub(cfg, text),
            "ref": "", "target": "", "who": "", "needs_user": False, "corrects": None, "detail": ""}


def day_rows(cfg: dict, day: dt.date) -> list[dict]:
    md, jl = _log_paths(cfg, day)
    if jl.is_file():
        rows = [json.loads(ln) for ln in jl.read_text().splitlines() if ln.strip()]
    elif md.is_file():
        rows = [_legacy_row(cfg, day, i, ln) for i, ln in enumerate(md.read_text().splitlines()) if ln.startswith("- ")]
    else:
        rows = []
    return [{**r, "day": f"{day:%Y-%m-%d}"} for r in rows]


def folded(cfg: dict, days: int) -> list[dict]:
    """The last `days` days' rows, oldest first, each correction folded into the
    row it corrects: it takes that row's place, marked corrected, never a new line."""
    today = local_now(cfg).date()
    rows = [r for back in reversed(range(days)) for r in day_rows(cfg, today - dt.timedelta(days=back))]
    by_id: dict[str, dict] = {}
    alias: dict[str, str] = {}
    order = []
    for r in rows:
        target = alias.get(r.get("corrects") or "", r.get("corrects"))
        if target and target in by_id:
            old = by_id[target]
            by_id[target] = {**r, "id": target, "at": old["at"], "day": old["day"], "corrected": True}
            alias[r["id"]] = target
        else:
            by_id[r["id"]] = r
            order.append(r["id"])
    return [by_id[i] for i in order]


def open_items(cfg: dict) -> tuple[list[dict], list[dict]]:
    """Rows still needing the user, and items routed to a session not yet back."""
    rows = folded(cfg, OPEN_DAYS)
    return [r for r in rows if r.get("needs_user")], [r for r in rows if r["kind"] == "routed"]


def _age(at: dt.datetime) -> str:
    s = max(0, int((now() - at).total_seconds()))
    return f"{s // 60}m" if s < 3600 else f"{s // 3600}h" if s < 86400 else f"{s // 86400}d"


def _when(cfg: dict, at: dt.datetime) -> str:
    """HH:MM within a day of now, else the weekday too, in quiet_hours.tz."""
    t = at.astimezone(zone(cfg))
    return f"{t:%H:%M}" if abs(at - now()) < dt.timedelta(hours=24) else f"{t:%a %H:%M}"


def _draft(path: str) -> dict:
    """A draft or sent copy's header fields, and its message's first line."""
    p = Path(path or "")
    text = p.read_text() if p.is_file() else ""
    head, sep, body = text.partition("\n---\n")
    if not sep:
        head, body = text, ""
    fields = dict(re.findall(r"^(to|kind|reason|needs):\s*(.+)$", head, re.M))
    claim = re.search(r"^- (\S+)", head.split("claims:", 1)[1], re.M) if "claims:" in head else None
    first = next((ln.strip() for ln in body.splitlines() if ln.strip()), "")
    return {**fields, "claim": claim.group(1) if claim else "", "first": first}


def next_tick(cfg: dict, at: dt.datetime) -> dt.datetime | None:
    a, tz = cfg["active_hours"], zone(cfg)
    local = at.astimezone(tz)
    for d in range(8):
        day = local.date() + dt.timedelta(days=d)
        if DAYS[day.weekday()] not in a["days"]:
            continue
        for h in range(int(a["start"][:2]), int(a["end"][:2])):
            for m in range(TICK_MINUTE, 60, a["every_minutes"]):
                t = dt.datetime.combine(day, dt.time(h, m), tzinfo=tz)
                if t > local:
                    return t
    return None


def going_out(cfg: dict) -> list[dict]:
    """Scheduled messages still ahead of post_at, from the gate's records: one the
    session has not recorded yet (no sent_id) is going out all the same."""
    at = now()
    last_scan = parse_time((state_dir(cfg) / "last-scan").read_text().strip()) \
        if (state_dir(cfg) / "last-scan").is_file() else None
    out = []
    for p in sorted((state_dir(cfg) / "gate").glob("*.json")) if (state_dir(cfg) / "gate").is_dir() else []:
        s = json.loads(p.read_text())
        if s.get("send") != "schedule" or s.get("withdrawn_at") or s.get("regate_of") or not s.get("post_at"):
            continue
        post = parse_time(s["post_at"])
        if post <= at:
            continue
        d = _draft(s.get("sent_copy") or s.get("path"))
        checked = parse_time(s["regated_at"]) if s.get("regated_at") else \
            dt.datetime.fromtimestamp(s.get("passed_at") or 0, dt.timezone.utc)
        if s.get("claim_moved_at"):
            status, warn = "claim moved ⚠", True
        elif last_scan and last_scan > checked:
            status, warn = "re-check due", False
        else:
            status, warn = f"gated {checked.astimezone(zone(cfg)):%H:%M} ✓", False
        ref = (s.get("prs") or [""])[0].split(" ")[0]
        out.append({"key": f"going:{p.stem}", "post": _when(cfg, post), "target": target_label(cfg, d.get("to", "")),
                    "ref": short_ref(cfg, ref), "text": clip(s.get("headline") or d["first"]), "status": status,
                    "warn": warn})
    return sorted(out, key=lambda g: g["post"])


def clip(text: str) -> str:
    """A draft's first line at the 80 characters a log row's text may hold: a
    draft written as one paragraph once put ~700 characters in a held row."""
    text = " ".join((text or "").split())
    return text if len(text) <= TEXT_MAX else text[:TEXT_MAX - 1].rstrip() + "…"


STATE_WORDS = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes requested", "COMMENTED": "commented",
               "DISMISSED": "dismissed"}
DECISION_WORDS = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes requested", "REVIEW_REQUIRED": "review required"}
MERGEABLE = ("CLEAN", "HAS_HOOKS", "UNSTABLE")
STRIP_DAYS = 5


def prs_panel(cfg: dict, verdicts: dict[str, str]) -> dict:
    """The PRS section from the last prs.json, which a scan that did not end
    BLOCKED writes: what needs the user first, a count per repo, and how old it
    is. A file older than two ticks, or one a later scan did not replace, is
    stale and says so: never shown as live. `verdicts` maps owner/repo#N to an
    open review row's text (approvable, needs your read, re-look)."""
    d = state_dir(cfg)
    try:
        data = json.loads((d / "prs.json").read_text())
        written = parse_time(data["written_at"])
    except (OSError, ValueError, KeyError, TypeError):
        data, written = None, None
    rows = []
    for p in (data or {}).get("reviewing", []):
        moved = bool(p.get("my_sha")) and p["my_sha"] != p["head"]
        verdict = verdicts.get(p["ref"], "")
        asked = p.get("requested_me") and not p.get("my_sha")
        parts = [f"{STATE_WORDS.get(p.get('my_state'), 'reviewed')}@{p['my_sha'][:7]}" if p.get("my_sha")
                 else "not reviewed", "new commits" if moved else verdict, f"CI {p['ci']}",
                 f"approved by {','.join(p['approvals'])}" if p.get("approvals") else ""]
        rows.append({"ref": p["ref"], "group": "reviewing", "needs": bool(moved or verdict or asked),
                     "line": f"{short_ref(cfg, p['ref'])}  {p['author']}  " + " · ".join(x for x in parts if x)})
    for p in (data or {}).get("authored", []):
        merge_me = p.get("decision") == "APPROVED" and p.get("merge") in MERGEABLE
        conflicts = p.get("merge") == "DIRTY"
        parts = ["approved, needs your merge" if merge_me else DECISION_WORDS.get(p.get("decision"), "no decision"),
                 f"CI {p['ci']}", f"{p['unresolved']} unresolved" if p.get("unresolved") else "",
                 "conflicts" if conflicts else ""]
        needs = merge_me or conflicts or p.get("decision") == "CHANGES_REQUESTED" or p["ci"] == "red" \
            or bool(p.get("unresolved"))
        rows.append({"ref": p["ref"], "group": "authored", "needs": needs,
                     "line": f"{short_ref(cfg, p['ref'])}  " + " · ".join(x for x in parts if x)})
    rows.sort(key=lambda r: (not r["needs"], r["group"] != "reviewing", short_ref(cfg, r["ref"])))
    repos: dict[str, list[int]] = {}
    for r in rows:
        c = repos.setdefault(short_ref(cfg, r["ref"]).rsplit(" #", 1)[0], [0, 0])
        c[0] += r["needs"]
        c[1] += 1
    last_scan = parse_time((d / "last-scan").read_text().strip()) if (d / "last-scan").is_file() else None
    every = cfg["active_hours"]["every_minutes"]
    stale = written is None or now() - written > dt.timedelta(minutes=2 * every) \
        or bool(last_scan and last_scan - written > dt.timedelta(minutes=1))
    return {"as_of": _when(cfg, written) if written else "", "age": _age(written) if written else "", "stale": stale,
            "repos": [{"repo": k, "needs": v[0], "total": v[1]} for k, v in sorted(repos.items(), key=lambda kv: (-kv[1][0], kv[0]))],
            "rows": [{"key": f"pr:{r['ref']}", **{k: r[k] for k in ("group", "needs", "line")}} for r in rows],
            "days": strip(cfg)}


def strip(cfg: dict) -> list[dict]:
    """Reviewed, approved and merged per day over the last STRIP_DAYS active
    days (a weekend is two zeros), oldest first, from prs-history.jsonl; days
    before it began count zero."""
    path = state_dir(cfg) / "prs-history.jsonl"
    counts: dict[str, dict[str, int]] = {}
    for ln in path.read_text().splitlines() if path.is_file() else []:
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        counts.setdefault(r.get("day", ""), {}).setdefault(r.get("event", ""), 0)
        counts[r["day"]][r["event"]] += 1
    day, out = local_now(cfg).date(), []
    while len(out) < STRIP_DAYS:
        if DAYS[day.weekday()] in cfg["active_hours"]["days"]:
            c = counts.get(f"{day:%Y-%m-%d}", {})
            out.append({"day": f"{day:%a %d}", **{e: c.get(e, 0) for e in ("reviewed", "approved", "merged")}})
        day -= dt.timedelta(days=1)
    return out[::-1]


def panel(cfg: dict) -> dict:
    """What the panel draws, sorted here so run.py --mutate can test it."""
    d, tz = state_dir(cfg), zone(cfg)
    needs, held = [], []
    for p in sorted((d / "held").glob("*.md")) if (d / "held").is_dir() else []:
        h = _draft(str(p))
        since = dt.datetime.fromtimestamp(p.stat().st_mtime, dt.timezone.utc)
        row = {"key": f"held:{p.stem}", "ref": short_ref(cfg, h["claim"]), "target": target_label(cfg, h.get("to", "")),
               "text": clip(h["first"])}
        if h.get("needs", "").strip() == "user":
            needs.append({**row, "note": "needs your go", "age": _age(since)})
        else:
            held.append({**row, "reason": h.get("reason", "")})
    asks, routed_ = open_items(cfg)
    needs += [{"key": f"row:{r['id']}", "ref": short_ref(cfg, r["ref"]), "target": target_label(cfg, r["target"]),
               "text": r["text"], "note": "" if r["kind"] == "asked" else r["kind"], "age": _age(parse_time(r["ts"]))}
              for r in asks]
    sessions = [{"key": f"row:{r['id']}", "who": r["who"], "ref": short_ref(cfg, r["ref"]), "text": r["text"],
                 "since": _when(cfg, parse_time(r["ts"]))} for r in routed_]
    logs = sorted(p.stem for p in (d / "log").glob("*.md") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.stem)) \
        if (d / "log").is_dir() else []
    newest = logs[-1] if logs else ""
    today = [r for r in folded(cfg, OPEN_DAYS) if r["day"] == newest]
    events = [{"key": f"row:{r['id']}", "ts": r["ts"], "at": r["at"], "kind": r["kind"],
               "ref": short_ref(cfg, r["ref"]), "target": target_label(cfg, r["target"]), "text": r["text"],
               "corrected": bool(r.get("corrected"))} for r in reversed(today) if r["kind"] not in UNSHOWN]
    raw = day_rows(cfg, dt.date.fromisoformat(newest)) if newest else []
    scans = [i for i, r in enumerate(raw) if r["kind"] == "scan"]
    since_scan = [r for r in raw[scans[-1] + 1:] if r["kind"] not in UNSHOWN + ("tick", "setup")] if scans else []
    nxt = next_tick(cfg, now())
    verdicts = {}
    for r in asks:
        m = re.search(r"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)", r["ref"] or "") \
            or re.fullmatch(r"([\w.-]+)/([\w.-]+)#(\d+)", (r["ref"] or "").strip())
        if r["kind"] == "reviewed" and m:
            verdicts[f"{m.group(1)}/{m.group(2)}#{m.group(3)}"] = r["text"]
    return {"state": str(d), "day": f"{dt.date.fromisoformat(newest):%a %d %b}" if newest else "",
            "prs": prs_panel(cfg, verdicts),
            "needs": needs, "going": going_out(cfg), "sessions": sessions, "held": held, "events": events,
            "next_tick": _when(cfg, nxt) if nxt else "none scheduled",
            "last_tick": ("quiet" if not since_scan else f"{len(since_scan)} item{'s' * (len(since_scan) != 1)}")
            if scans else "none yet", "read": f"{local_now(cfg):%H:%M}"}


def pending_scheduled(cfg: dict) -> list[dict]:
    """The gate's records of scheduled messages whose post_at is still ahead:
    each can be gated again from its sent copy and withdrawn before it posts."""
    now_ = now()
    out = []
    for p in sorted((state_dir(cfg) / "gate").glob("*.json")):
        s = json.loads(p.read_text())
        # A withdrawn one was deleted in Slack: gating it again would check a message that will never post.
        if s.get("send") != "schedule" or not s.get("sent_id") or s.get("withdrawn_at"):
            continue
        if parse_time(s.get("post_at")) <= now_:
            continue
        out.append(s)
    return out


def append_feedback(cfg: dict, text: str) -> Path:
    """A correction the user made, dated, in feedback.md: the backlog for the next change to this skill."""
    p = state_dir(cfg) / "feedback.md"
    with p.open("a") as f:
        f.write(f"- {local_now(cfg):%Y-%m-%d %H:%M} {text}\n")
    return p


def routed(cfg: dict, text: str, days: int = 2) -> list[str]:
    """Log lines from the last `days` days that mention `text`: what was already
    routed, held or asked about, so an item is not sent to its owner twice."""
    d = state_dir(cfg) / "log"
    today = local_now(cfg).date()
    out = []
    for back in range(days):
        day = today - dt.timedelta(days=back)
        p = d / f"{day:%Y-%m-%d}.md"
        if p.is_file():
            out += [f"{day:%Y-%m-%d} {line}" for line in p.read_text().splitlines() if text in line]
    return out


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ---- gh ---------------------------------------------------------------------

def _run_gh(args: list[str], timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=timeout)


class Gh:
    """Every gh call: a timeout and one retry. Tests pass `runner`."""

    def __init__(self, runner=None, timeout: float = 45, retries: int = 1, pause: float | None = None):
        self.runner = runner or _run_gh
        self.timeout = timeout
        self.retries = retries
        self.pause = float(os.environ.get("COMMS_HUB_GH_RETRY_PAUSE", "2")) if pause is None else pause

    def run(self, args: list[str]) -> str:
        why = ""
        for attempt in range(self.retries + 1):
            try:
                p = self.runner(args, self.timeout)
            except subprocess.TimeoutExpired:
                why = f"timed out after {self.timeout:g}s"
            except OSError as e:
                raise GhError(f"gh did not start: {e}")
            else:
                if p.returncode == 0:
                    return p.stdout
                why = (p.stderr or p.stdout or "").strip().splitlines()[-1:] or [f"exit {p.returncode}"]
                why = why[0][:300]
            if attempt < self.retries:
                time.sleep(self.pause)
        raise GhError(f"gh {' '.join(args[:2])}: {why} (tried {self.retries + 1}x)")

    def json(self, args: list[str]):
        out = self.run(args)
        try:
            return json.loads(out)
        except ValueError:
            raise GhError(f"gh {' '.join(args[:2])}: not JSON: {out[:120]!r}")

    def graphql(self, query: str, **variables) -> dict:
        args = ["api", "graphql", "-f", f"query={query}"]
        for k, v in variables.items():
            if v is None:
                continue
            args += ["-F" if isinstance(v, (int, bool)) else "-f", f"{k}={v}"]
        data = self.json(args)
        if data.get("errors"):
            raise GhError("graphql: " + "; ".join(e.get("message", "?") for e in data["errors"])[:300])
        return data["data"]


def split_pr(ref: str) -> tuple[str, str, int]:
    m = re.fullmatch(r"([\w.-]+)/([\w.-]+)#(\d+)", ref)
    if not m:
        raise ValueError(f"not owner/repo#N: {ref!r}")
    return m.group(1), m.group(2), int(m.group(3))


# ---- review and CI state ----------------------------------------------------

def login(actor) -> str | None:
    return (actor or {}).get("login")


def is_me(actor, me: str) -> bool:
    """Logins compare case-insensitively, as GitHub does; the config may spell mine differently."""
    return (login(actor) or "").lower() == me.lower()


def is_bot(actor) -> bool:
    """A Bot account, a [bot] login, or a login github.bots names: some bots run as plain users."""
    a = actor or {}
    name = a.get("login") or ""
    return a.get("__typename") == "Bot" or name.endswith("[bot]") or name.lower() in KNOWN_BOTS


def standing_reviews(reviews: list[dict]) -> dict[str, dict]:
    """Each reviewer's standing review: their last review that is not COMMENTED.
    A COMMENTED review, which a thread reply also creates, never revokes an
    approval; a later CHANGES_REQUESTED, or the approval's own DISMISSED, does.
    Read from `reviews`: `latestReviews` came back [] on a PR with three."""
    out: dict[str, dict] = {}
    for r in sorted(reviews, key=lambda r: r.get("submittedAt") or ""):
        if r.get("state") in ("COMMENTED", "PENDING"):
            continue
        who = login(r.get("author"))
        if who:
            out[who] = r
    return out


GREEN = ("SUCCESS", "NEUTRAL", "SKIPPED")


def ci_summary(nodes: list[dict]) -> tuple[str, list[str]]:
    """("green"|"pending"|"red"|"none", names behind the verdict). Per check name
    the latest run by start time decides, so a CANCELLED run a later SUCCESS
    superseded is not red; a CANCELLED that is the latest is."""
    latest: dict[str, tuple[str, str]] = {}
    for n in nodes:
        if n.get("__typename") == "StatusContext":
            name, started, state = n.get("context"), n.get("createdAt") or "", n.get("state")
            verdict = "green" if state == "SUCCESS" else "pending" if state in ("PENDING", "EXPECTED") else "red"
        else:
            name, started = n.get("name"), n.get("startedAt") or n.get("completedAt") or ""
            if n.get("status") != "COMPLETED":
                verdict = "pending"
                started = started or "~"  # queued, not started: newer than any run that has
            else:
                verdict = "green" if n.get("conclusion") in GREEN else "red"
        if name not in latest or started >= latest[name][0]:
            latest[name] = (started, verdict)
    if not latest:
        return "none", []
    for v in ("red", "pending"):
        names = sorted(k for k, (_, x) in latest.items() if x == v)
        if names:
            return v, names
    return "green", []


def init(gh: Gh | None = None, example: Path | None = None) -> int:
    """The example config at config_path(), with what this machine already
    knows filled in. An existing file is never touched: it holds ids by hand."""
    path = config_path()
    if path.exists():
        print(f"refusing: {path} exists; edit it, or move it away first")
        return 1
    text = (example or example_path()).read_text()
    filled = []
    try:
        login = (gh or Gh()).json(["api", "user"])["login"]
        if not re.fullmatch(r"[\w-]+", str(login)):
            raise ValueError(f"login {login!r}")
    except (GhError, KeyError, TypeError, ValueError) as e:
        login = None
        filled.append(f"github.login: not read from gh ({e}); gh auth login, then fill it in")
    if login:
        text = (text.replace(f'login = "{PLACEHOLDER}"', f'login = "{login}"', 1)
                    .replace(f'owners = ["{PLACEHOLDER}"]', f'owners = ["{login}"]', 1))
        filled.append(f"github.login and github.owners from gh: {login} (add your org to owners)")
    tz = system_zone()
    if tz:
        text = text.replace(f'tz = "{PLACEHOLDER}"', f'tz = "{tz}"', 1)
        filled.append(f"quiet_hours.tz from this machine: {tz}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        f.write(text)
    print(f"wrote {path}")
    for line in filled:
        print(f"  {line}")
    left = list(placeholders(_toml().loads(text)))
    print(f"  still {PLACEHOLDER}, fill in by hand: {', '.join(left)}" if left else "  nothing left to fill in")
    return 0


def main(argv=None, gh: Gh | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if (argv[:1] not in (["init"], ["config"], ["log"], ["panel"], ["queries"], ["routed"], ["feedback"],
                         ["cron"], ["window"], ["trigger"], ["launch"])
            or (argv[0] in ("log", "routed", "feedback") and len(argv) < 2)):
        print(__doc__.split("run directly:", 1)[1].rstrip())
        return 2
    # `hub.py feedback --help` once wrote "--help" into feedback.md: these take text, no flags.
    if argv[0] in ("routed", "feedback") and argv[1].startswith("-"):
        print(f"usage: hub.py {argv[0]} TEXT; it takes no flags, so {argv[1]!r} would be read as the text")
        return 2
    if argv[0] == "init":
        return init(gh)
    try:
        cfg = load_config()
    except ConfigError as e:
        print(f"config: {e}")
        return 2
    if argv[0] == "config":
        s = cfg["slack"]
        print(f"config: {cfg['_path']}")
        print(f"state: {state_dir(cfg)}")
        print(f"tmp: {tmp_dir(cfg)}")
        print(f"login: {cfg['github']['login']} owners: {','.join(cfg['github']['owners'])}")
        print(f"bots: {','.join(cfg['github']['bots']) or '-'} max_chars: slack={s['max_chars']} "
              f"review={cfg['github']['review_max_chars']}")
        print(f"slack: primary_dm={s.get('primary_dm') or '-'} my_user_id={s.get('my_user_id') or '-'} "
              f"watched={','.join(s.get('watched_channels') or []) or '-'} ack={s['ack_reaction']}")
        print(f"quiet: {cfg['quiet_hours']['start']} to {cfg['quiet_hours']['post_at']} {cfg['quiet_hours']['tz']}")
        a = cfg["active_hours"]
        print(f"active: {','.join(a['days'])} {a['start']} to {a['end']}, every {a['every_minutes']} min: {cron(cfg)}")
        for r in cfg["routing"]:
            print(f"route: {r.get('session')} repos={','.join(r['repos']) or '-'} "
                  f"tickets={','.join(r['tickets']) or '-'} channels={','.join(r['channels']) or '-'}")
        if argv[1:2] == ["--transcript"] and len(argv) == 3:
            transcript = Path(argv[2])
        elif argv[1:]:
            print("usage: hub.py config [--transcript FILE]")
            return 2
        else:
            transcript = tick_transcript(projects_root())
        for line in compaction_lines(cfg, transcript):
            print(line)
        return 0
    if argv[0] == "queries":
        uid = cfg["slack"].get("my_user_id")
        if not uid:
            print("config: slack.my_user_id is required for the mention searches")
            return 2
        if argv[1:] not in ([], ["--control"]):
            print("usage: hub.py queries [--control]")
            return 2
        since = local_now(cfg).date() - dt.timedelta(days=2)
        if argv[1:] == ["--control"]:
            since -= dt.timedelta(days=CONTROL_DAYS)
        for q in mention_queries(uid, since):
            print(q)
        return 0
    if argv[0] == "routed":
        lines = routed(cfg, " ".join(argv[1:]))
        for line in lines:
            print(line)
        print(f"routed: {len(lines)} line(s) in the last 2 days mention {' '.join(argv[1:])!r}")
        return 0 if lines else 1
    if argv[0] == "feedback":
        print(f"noted in {append_feedback(cfg, ' '.join(argv[1:]))}")
        return 0
    if argv[0] in ("cron", "window", "trigger", "launch"):
        return schedule_cmd(cfg, argv)
    if argv[0] == "panel":
        print(json.dumps(panel(cfg)))
        return 0
    return log_cmd(cfg, argv[1:])


def log_cmd(cfg: dict, argv: list[str]) -> int:
    import argparse
    ap = argparse.ArgumentParser(prog="hub.py log")
    ap.add_argument("--kind", choices=LOG_KINDS, help="required; a call without it, from a session on an older "
                                                      "skill, logs a note rather than nothing")
    ap.add_argument("--ref", default="", help="the PR or ticket link")
    ap.add_argument("--target", default="", help="the channel id, which the panel names from slack.channel_names")
    ap.add_argument("--who", default="", help="the person or session")
    ap.add_argument("--needs-user", action="store_true", help="kept under Needs you until a row corrects it")
    ap.add_argument("--corrects", default="", metavar="ID", help="the row this one replaces")
    ap.add_argument("--at", default="", metavar="HH:MM", help="when it happened, if not now")
    ap.add_argument("--detail", default="", help="ids, links and the rest, kept off the panel")
    ap.add_argument("text", nargs="+")
    args = ap.parse_args(argv)
    text = " ".join(" ".join(args.text).split())
    if args.kind is None:
        # A comms session still on the skill from before --kind gets exit 2 and
        # logs nothing, all day, after an in-place install: keep what it said.
        args.kind = "note"
        if text_problem(text):
            args.detail = " ".join(x for x in (text, args.detail) if x)
            text = re.sub(r"^\d{1,2}:\d{2}\s*", "", scrub(cfg, text))[:TEXT_MAX].strip()
            if text_problem(text):
                text = "a note whose text is in the detail"
        print("log: no --kind, so logged as a note; re-read ~/.claude/skills/comms-hub/SKILL.md, "
              "whose step 5 names the kinds", file=sys.stderr)
    problem = text_problem(text)
    if not problem and args.at and not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", args.at):
        problem = f"--at {args.at!r} is not HH:MM"
    if problem:
        print(f"log: {problem}. Nothing logged.")
        return 2
    row = log_event(cfg, args.kind, text, ref=args.ref, target=args.target, who=args.who, needs_user=args.needs_user,
                    corrects=args.corrects, at=args.at, detail=args.detail)
    print(f"logged {row['id']}: {row['kind']} {row['text']}")
    return 0


def schedule_cmd(cfg: dict, argv: list[str]) -> int:
    """cron, window, trigger and launch; see the module docstring."""
    import argparse
    ap = argparse.ArgumentParser(prog=f"hub.py {argv[0]}")
    if argv[0] == "window":
        ap.add_argument("--margin", type=int, default=0, metavar="MIN")
        ap.add_argument("--review", action="store_true")
        ap.add_argument("--full-done", action="store_true")
    elif argv[0] == "trigger":
        ap.add_argument("--live", metavar="EXPR")
        ap.add_argument("--created", metavar="EXPR")
    elif argv[0] == "launch":
        ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv[1:])
    at, tz = now(), zone(cfg)
    if argv[0] == "cron":
        print(cron(cfg))
        return 0
    if argv[0] == "window":
        if args.full_done:
            p = state_dir(cfg) / "tick.json"
            p.write_text(json.dumps({**_record(cfg, "tick.json"), "full": at.isoformat()}) + "\n")
            print(f"full scan recorded at {at.astimezone(tz):%H:%M}")
            return 0
        margin = cfg["active_hours"]["review_margin_minutes"] if args.review else args.margin
        close, opens = window(cfg, at)
        if opens:
            print(f"window: closed, opens {opens:%a %Y-%m-%d %H:%M} {tz.key}")
            return 1
        if close - at < dt.timedelta(minutes=margin):
            print(f"window: closing at {close:%H:%M}, within {margin} min")
            return 1
        print(f"window: open until {close:%H:%M}")
        plan = scan_plan(cfg, at)
        last = parse_time(_record(cfg, "tick.json").get("full"))
        opened = dt.datetime.combine(at.astimezone(tz).date(), dt.time.fromisoformat(cfg["active_hours"]["start"]),
                                     tzinfo=tz)
        print(f"scan: {plan}" + (" (the window's first)" if last is None or last < opened else ""))
        return 0
    if argv[0] == "trigger":
        if args.created:
            expr = " ".join(args.created.split())
            (state_dir(cfg) / "trigger.json").write_text(json.dumps({"expr": expr, "created": at.isoformat()}) + "\n")
            print(f"trigger {expr!r} recorded as created {at.astimezone(tz):%Y-%m-%d %H:%M}")
        problems = trigger_problems(cfg, at, args.live)
        print(f"trigger: want {cron(cfg)!r}")
        for line in problems:
            print(line)
        return 1 if problems else 0
    if args.check:
        problems = launch_problems(cfg, os.environ)
        for line in problems:
            print(line)
        if problems:
            print("restart the comms session with the command `hub.py launch` prints")
            return 1
        print("launch: this session has the comms session's compact window and MCP timeout")
        return 0
    cmd = "claude --settings " + shlex_quote(json.dumps({"env": launch_env(cfg)}, separators=(",", ":")))
    panel = panel_dir()
    print(cmd + (f" --plugin-dir {shlex_quote(str(panel))}" if panel else ""))
    return 0


def shlex_quote(s: str) -> str:
    import shlex
    return shlex.quote(s)


if __name__ == "__main__":
    sys.exit(main())
