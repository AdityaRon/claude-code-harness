"""Shared pieces of the comms-hub scripts: config, state paths, the gh runner,
review state and CI state. Imported by the scripts beside it; run directly:

  hub.py init         write the config from the example, with the login, owners and
                      zone this machine knows; refuses to touch an existing one
  hub.py config       the config path, the state dir, the ids, or what is wrong with the config
  hub.py log TEXT     append a line to today's log in the state dir
  hub.py queries      the three Slack mention searches, dated two days back
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
    cfg.setdefault("slack", {})
    q = cfg.setdefault("quiet_hours", {})
    q.setdefault("start", "19:00")
    q.setdefault("post_at", "08:00")
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
    return "schedule", dt.datetime.combine(day, post, tzinfo=tz)


def first_tick_after_quiet(cfg: dict, prev: dt.datetime | None, at: dt.datetime) -> bool:
    """True once a day: `at` is live and `prev` was before today's end of quiet
    hours, whether that was last evening or a tick the laptop slept through."""
    if prev is None or send_plan(cfg, at)[0] != "live":
        return False
    tz = zone(cfg)
    end = dt.datetime.combine(at.astimezone(tz).date(), dt.time.fromisoformat(cfg["quiet_hours"]["post_at"]), tzinfo=tz)
    return prev < end <= at


def mention_queries(uid: str, since: dt.date) -> list[str]:
    """The three Slack searches that together find what names me: the mention
    itself, a message or reply sent to me, and a thread I am in. One search
    missed replies each of the other two caught, one under a week-old thread.
    `after:` is exclusive, so the day is the one before the window starts."""
    day = f"after:{since:%Y-%m-%d}"
    return [f"<@{uid}> {day}", f"to:<@{uid}> {day}", f"with:<@{uid}> is:thread {day}"]


def append_log(cfg: dict | None, line: str) -> Path:
    d = state_dir(cfg) / "log"
    d.mkdir(exist_ok=True)
    stamp = local_now(cfg)
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


def is_me(actor, me: str) -> bool:
    """Logins compare case-insensitively, as GitHub does; the config may spell mine differently."""
    return (login(actor) or "").lower() == me.lower()


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
    if argv[:1] not in (["init"], ["config"], ["log"], ["queries"]) or (argv[0] == "log" and len(argv) < 2):
        print(__doc__.split("run directly:", 1)[1].rstrip())
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
        print(f"slack: primary_dm={s.get('primary_dm') or '-'} my_user_id={s.get('my_user_id') or '-'} "
              f"watched={','.join(s.get('watched_channels') or []) or '-'}")
        print(f"quiet: {cfg['quiet_hours']['start']} to {cfg['quiet_hours']['post_at']} {cfg['quiet_hours']['tz']}")
        for r in cfg["routing"]:
            print(f"route: {r.get('session')} repos={','.join(r['repos']) or '-'} "
                  f"tickets={','.join(r['tickets']) or '-'} channels={','.join(r['channels']) or '-'}")
        return 0
    if argv[0] == "queries":
        uid = cfg["slack"].get("my_user_id")
        if not uid:
            print("config: slack.my_user_id is required for the mention searches")
            return 2
        for q in mention_queries(uid, local_now(cfg).date() - dt.timedelta(days=2)):
            print(q)
        return 0
    print(f"logged to {append_log(cfg, ' '.join(argv[1:]))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
