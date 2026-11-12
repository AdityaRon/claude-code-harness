#!/usr/bin/env python3
"""The output path every engine prints through: a masker for identifiers that
embed customer or user names, the provenance header, windows and exit codes.
skill-forge copies this file into every skill it drafts, unchanged.

  mask.py --test TEXT     print TEXT as the configured masker leaves it
  mask.py --patterns      list the active patterns and the file each came from
  mask.py --filter        mask stdin line by line: a shell engine's output path

Patterns are regexes in the [mask] table of a TOML file:

  [mask]
  patterns = ['\\bcust-[a-z0-9-]+', '(?i)\\btenant[-_][a-z0-9]+']

read from $SKILL_FORGE_CONFIG (else ~/.config/skill-forge/config.toml) and from
the skill's own forge.toml. Built in: e-mail addresses, the user:password part
of a URL, and a bearer token. A match prints as <masked-N>, with N stable for
one run so equal identifiers still line up. No hash of the original is
printed, so nobody can confirm a guessed name against the output.
A pattern that does not compile stops the program: output that skipped the
masker is worse than no output.
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    import tomli as tomllib  # type: ignore[no-redef]

SKILL = Path(__file__).resolve().parent.parent

EXIT_OK, EXIT_USAGE, EXIT_ABSENT, EXIT_PARTIAL, EXIT_AUTH, EXIT_REFUSED = 0, 1, 2, 3, 4, 5

BUILTIN = [
    ("url userinfo", r"(?<=://)[^/\s@]+(?=@)"),
    ("e-mail", r"(?<![\w.%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?![\w.:-])"),
    ("bearer token", r"(?i)(?<=bearer )[A-Za-z0-9._~+/=-]{8,}"),
]


def config_path() -> Path:
    env = os.environ.get("SKILL_FORGE_CONFIG")
    if env:
        return Path(env).expanduser()
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return Path(base) / "skill-forge" / "config.toml"


def state_dir() -> Path:
    env = os.environ.get("SKILL_FORGE_STATE")
    if env:
        return Path(env).expanduser()
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return Path(base) / "skill-forge"


def read_toml(path: Path) -> dict:
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}


class Masker:
    def __init__(self, patterns=(), builtins: bool = True):
        self.rules: list[tuple[str, re.Pattern]] = []
        self.seen: dict[str, int] = {}
        for label, rx in (BUILTIN if builtins else []):
            self.rules.append((label, re.compile(rx)))
        for label, rx in patterns:
            try:
                self.rules.append((label, re.compile(rx)))
            except re.error as e:
                raise SystemExit(f"mask: pattern {rx!r} from {label} does not compile ({e}); fix it before anything prints")

    def _sub(self, m: re.Match) -> str:
        key = m.group(0)
        if key not in self.seen:
            self.seen[key] = len(self.seen) + 1
        return f"<masked-{self.seen[key]}>"

    def __call__(self, text: str) -> str:
        for _, rx in self.rules:
            text = rx.sub(self._sub, text)
        return text


def load_masker(skill: Path | None = None) -> Masker:
    skill = skill or SKILL
    patterns = []
    for src in (config_path(), skill / "forge.toml"):
        for rx in read_toml(src).get("mask", {}).get("patterns", []):
            patterns.append((str(src), rx))
    return Masker(patterns)


_MASKER: Masker | None = None


def masker() -> Masker:
    global _MASKER
    if _MASKER is None:
        _MASKER = load_masker()
    return _MASKER


def emit(text: object = "", err: bool = False) -> None:
    """The one way an engine prints. stderr too: an error message quotes ids."""
    stream = sys.stderr if err else sys.stdout
    stream.write(masker()(str(text)) + "\n")
    stream.flush()


def iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Window:
    """A query window, always aware and printed in UTC with its bounds."""

    def __init__(self, start: datetime, end: datetime, step: str | None = None, bounds: str = "[start, end]"):
        if start.tzinfo is None or end.tzinfo is None:
            raise ValueError("a window needs timezone-aware times")
        if end < start:
            raise ValueError(f"window ends before it starts: {iso(start)} .. {iso(end)}")
        self.start, self.end, self.step, self.bounds = start, end, step, bounds

    def __str__(self) -> str:
        step = f", step {self.step}" if self.step else ""
        return f"{iso(self.start)} .. {iso(self.end)} (UTC, bounds {self.bounds}{step})"


_DUR = re.compile(r"(\d+)(ms|s|m|h|d|w)")
_UNIT = {"ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def parse_duration(text: str) -> timedelta:
    parts = _DUR.findall(text)
    if not parts or "".join(n + u for n, u in parts) != text:
        raise ValueError(f"not a duration: {text!r} (use 90s, 5m, 1h30m, 2d)")
    return timedelta(seconds=sum(int(n) * _UNIT[u] for n, u in parts))


def parse_time(text: str, now: datetime | None = None) -> datetime:
    """`now`, `now-1h`, or ISO 8601 with a zone. A bare local time is refused:
    the window is the part of an answer people paste without checking."""
    now = now or datetime.now(timezone.utc)
    if text == "now":
        return now
    if text.startswith("now-"):
        return now - parse_duration(text[4:])
    t = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if t.tzinfo is None:
        raise ValueError(f"{text!r} has no timezone; write it as {text}Z or with an offset")
    return t


def header(target: str, window: object, command=None, rows: object = "?", partial: str | None = None) -> str:
    """The provenance block that opens every output. `partial` is None or empty
    for a complete answer, else the reason it is not."""
    if not str(window).strip():
        raise ValueError("the window is required; say `n/a: <why>` when there is none")
    cmd = command if command is not None else sys.argv
    if not isinstance(cmd, str):
        cmd = shlex.join(str(c) for c in cmd)
    return "\n".join([
        f"# target:  {target}",
        f"# window:  {window}",
        f"# command: {cmd}",
        f"# rows:    {rows}",
        f"# partial: {'YES: ' + partial if partial else 'no'}",
    ])


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--test", metavar="TEXT", help="print TEXT masked")
    p.add_argument("--patterns", action="store_true", help="list the active patterns")
    p.add_argument("--filter", action="store_true", help="mask stdin to stdout, line by line")
    a = p.parse_args(argv)
    if a.filter:
        for line in sys.stdin:
            emit(line.rstrip("\n"))
        return EXIT_OK
    if a.patterns:
        for label, rx in masker().rules:
            # The pattern is config, not data; print it raw or a reader cannot fix it.
            sys.stdout.write(f"{label}\t{rx.pattern}\n")
        return EXIT_OK
    if a.test is not None:
        emit(a.test)
        return EXIT_OK
    p.print_help()
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
