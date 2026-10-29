"""Test doubles: a gh runner that never touches the network, and a config in a
temp dir. Shared by the test files; not a test file itself."""
from __future__ import annotations

import contextlib
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path
from unittest import mock

BIN = Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))

ME = "me-login"

CONFIG = f"""
[github]
login = "{ME}"
owners = ["acme"]
watch_repos = ["acme/app"]
watch_authors = ["teammate"]
merged_days = 7

[slack]
primary_dm = "dm-primary"
watched_channels = ["chan-one"]
my_user_id = "user-me"

[quiet_hours]
start = "19:00"
post_at = "08:30"
tz = "America/Los_Angeles"
"""


class Fail:
    """A handler result that makes gh exit non-zero."""

    def __init__(self, msg="HTTP 502"):
        self.msg = msg


class FakeGh:
    """Answers `gh api graphql` by operation name and other calls by `rest` key:
    "rate_limit", "user", "search" (called with q and page), "pr view" (number, repo).
    A handler is a value or a callable; a list is consumed one item per call."""

    def __init__(self, graphql=None, rest=None):
        self.graphql = graphql or {}
        self.rest = rest or {}
        self.calls: list[list[str]] = []

    @staticmethod
    def _vars(args):
        out = {}
        for flag, kv in zip(args, args[1:]):
            if flag in ("-f", "-F") and not kv.startswith("query="):
                k, _, v = kv.partition("=")
                out[k] = int(v) if flag == "-F" and v.lstrip("-").isdigit() else v
        return out

    def _answer(self, key, *a):
        if key not in self.handlers_for(key):
            raise AssertionError(f"unexpected gh call: {key}")
        h = self.handlers_for(key)[key]
        if isinstance(h, list):
            if not h:
                raise AssertionError(f"gh {key} called more often than the test expected")
            h = h.pop(0)
        return h(*a) if callable(h) else h

    def handlers_for(self, key):
        return self.graphql if key in self.graphql else self.rest

    def __call__(self, args, timeout):
        self.calls.append(list(args))
        if args[:2] == ["api", "graphql"]:
            q = next(a[len("query="):] for a in args if a.startswith("query="))
            key = re.search(r"(?:query|mutation)\s+(\w+)", q).group(1)
            res = self._answer(key, self._vars(args))
            wrap = (lambda d: {"data": d}) if not isinstance(res, Fail) else None
        elif args[:2] == ["api", "rate_limit"]:
            res, wrap = self._answer("rate_limit"), None
        elif args[:2] == ["api", "user"]:
            res, wrap = self._answer("user"), None
        elif "search/issues" in args:
            v = self._vars(args)
            res, wrap = self._answer("search", v["q"], int(v["page"])), None
        elif args[:2] == ["pr", "view"]:
            res, wrap = self._answer("pr view", int(args[2]), args[args.index("--repo") + 1]), None
        elif args[:3] == ["api", "-X", "POST"]:
            # The payload is in the --input file, read now: the caller deletes it after.
            with open(args[args.index("--input") + 1]) as f:
                res, wrap = self._answer("post", args[3], json.load(f)), None
        else:
            raise AssertionError(f"unexpected gh call: {args}")
        if isinstance(res, BaseException):
            raise res
        if isinstance(res, Fail):
            return subprocess.CompletedProcess(args, 1, "", res.msg)
        body = wrap(res) if wrap else res
        return subprocess.CompletedProcess(args, 0, json.dumps(body), "")

    def count(self, needle):
        return sum(1 for c in self.calls if any(needle in a for a in c))


class Env:
    """A temp config and state dir, wired in through the environment."""

    def __init__(self, config=CONFIG, now=None):
        self.dir = Path(tempfile.mkdtemp(prefix="comms-hub-test."))
        self.config = self.dir / "config.toml"
        self.config.write_text(textwrap.dedent(config))
        self.state = self.dir / "state"
        env = {"COMMS_HUB_CONFIG": str(self.config), "COMMS_HUB_STATE_DIR": str(self.state)}
        if now:
            env["COMMS_HUB_NOW"] = now
        self.patch = mock.patch.dict(os.environ, env)

    def __enter__(self):
        self.patch.start()
        return self

    def __exit__(self, *exc):
        self.patch.stop()
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)


@contextlib.contextmanager
def machine_zone(name):
    """This process's local zone, the one astimezone() with no argument uses."""
    try:
        with mock.patch.dict(os.environ, {"TZ": name}):
            time.tzset()
            yield
    finally:
        time.tzset()


def page(nodes, more=False, cursor="c1"):
    return {"pageInfo": {"hasNextPage": more, "endCursor": cursor}, "nodes": nodes}


def actor(name, bot=False):
    return {"login": name, "__typename": "Bot" if bot else "User"}
