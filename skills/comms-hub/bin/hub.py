"""Shared pieces of the comms-hub scripts: config, state paths, the gh runner,
review state and CI state. Imported by the scripts beside it; run directly:

  hub.py config       the config path, the state dir, or what is wrong with the config
  hub.py log TEXT     append a line to today's log in the state dir
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


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from _strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from _strings(v)


def load_config(explicit: str | None = None) -> dict:
    """The config with defaults filled in. Raises ConfigError naming the key."""
    path = config_path(explicit)
    if not path.is_file():
        raise ConfigError(f"no config at {path}: copy config.example.toml there and fill it in")
    try:
        cfg = _toml().loads(path.read_text())
    except Exception as e:  # tomllib.TOMLDecodeError, or tomli's
        raise ConfigError(f"{path}: not valid TOML: {e}")
    left = [s for s in _strings(cfg) if PLACEHOLDER in s]
    if left:
        raise ConfigError(f"{path}: {len(left)} value(s) still read {PLACEHOLDER}")
    gh = cfg.setdefault("github", {})
    if not gh.get("login"):
        raise ConfigError(f"{path}: github.login is required")
    if not gh.get("owners"):
        raise ConfigError(f"{path}: github.owners needs at least one org or user")
    gh.setdefault("watch_repos", [])
    gh.setdefault("watch_authors", [])
    gh.setdefault("merged_days", 7)
    cfg.setdefault("slack", {})
    q = cfg.setdefault("quiet_hours", {})
    q.setdefault("start", "19:00")
    q.setdefault("post_at", "08:00")
    for k in ("start", "post_at"):
        if not re.fullmatch(r"\d{2}:\d{2}", str(q[k])):
            raise ConfigError(f"{path}: quiet_hours.{k} must be HH:MM, not {q[k]!r}")
    if q.get("tz"):
        from zoneinfo import ZoneInfo
        try:
            ZoneInfo(q["tz"])
        except (KeyError, ValueError) as e:  # ZoneInfoNotFoundError is a KeyError
            raise ConfigError(f"{path}: quiet_hours.tz {q['tz']!r} is not an IANA zone: {e}")
    cfg.setdefault("routing", [])
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
    name = cfg.get("quiet_hours", {}).get("tz")
    return ZoneInfo(name) if name else dt.datetime.now().astimezone().tzinfo


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
    return "schedule", dt.datetime.combine(day, post, tzinfo=tz)


def append_log(cfg: dict | None, line: str) -> Path:
    d = state_dir(cfg) / "log"
    d.mkdir(exist_ok=True)
    stamp = now().astimezone()
    p = d / f"{stamp:%Y-%m-%d}.md"
    with p.open("a") as f:
        f.write(f"- {stamp:%H:%M} {line}\n")
    return p


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


def is_bot(actor) -> bool:
    a = actor or {}
    return a.get("__typename") == "Bot" or (a.get("login") or "").endswith("[bot]")


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


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] not in (["config"], ["log"]) or (argv[0] == "log" and len(argv) < 2):
        print(__doc__.split("run directly:", 1)[1].rstrip())
        return 2
    try:
        cfg = load_config()
    except ConfigError as e:
        print(f"config: {e}")
        return 2
    if argv[0] == "config":
        print(f"config: {cfg['_path']}")
        print(f"state: {state_dir(cfg)}")
        print(f"login: {cfg['github']['login']} owners: {','.join(cfg['github']['owners'])} "
              f"routing: {len(cfg['routing'])} session(s)")
        return 0
    print(f"logged to {append_log(cfg, ' '.join(argv[1:]))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
