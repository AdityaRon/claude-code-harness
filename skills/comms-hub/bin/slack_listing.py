#!/usr/bin/env python3
"""Turn a Slack read_channel dump into one line per top-level message,
`ts<TAB>reply_count`, oldest first.

  slack_listing.py DUMP [-o LISTING]           the page's listing
  slack_listing.py DUMP --merge SNAPSHOT [-o]  that page merged into a snapshot

Accepted dumps: Slack API JSON (a `messages` list, or any list of objects with a
string `ts`; `reply_count` absent means 0, a reply whose `thread_ts` differs from
its `ts` is skipped), or text whose messages carry a labelled ts line such as
`ts: 1712345678.123456` and, when threaded, a reply count such as `replies: 3`.
Another text shape: pass --ts-pattern and --replies-pattern (one group each), or
set slack.listing_ts_pattern and slack.listing_replies_pattern in the config.

Input it cannot read is an error, never an empty listing: an empty page reads as
"nothing new", and that is the answer a failed read must not give.
Exit 0, or 2 when the dump is unreadable.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402

TS_RE = r"(?im)^[\s*_>|-]*(?:message[ _]?)?(?:ts|timestamp)\**\s*[:=]\s*\**\s*[\"'`]?(\d{9,10}\.\d{6})"
REPLIES_RE = r"(?im)(?:reply[ _]count|replies|thread replies)\**\s*[:=]\s*\**\s*(\d+)|\b(\d+) repl(?:y|ies)\b"


class Unreadable(Exception):
    pass


def ts_key(ts: str) -> tuple[int, int]:
    sec, _, frac = ts.partition(".")
    return int(sec), int(frac or 0)


def _message_list(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("messages"), list):
            return obj["messages"]
        for v in obj.values():
            found = _message_list(v)
            if found is not None:
                return found
    if isinstance(obj, list) and obj and all(isinstance(m, dict) for m in obj) and any("ts" in m for m in obj):
        return obj
    if isinstance(obj, list):
        for v in obj:
            found = _message_list(v)
            if found is not None:
                return found
    return None


def parse_json(obj) -> dict[str, int]:
    msgs = _message_list(obj)
    if msgs is None:
        raise Unreadable("JSON with no list of messages carrying a ts")
    out = {}
    for m in msgs:
        ts = m.get("ts")
        if not isinstance(ts, str):
            raise Unreadable(f"a ts that is not a string ({ts!r}): a float loses the digits that make it unique")
        if m.get("thread_ts") not in (None, ts):
            continue
        out[ts] = int(m.get("reply_count") or 0)
    return out


def parse_text(text: str, ts_re: str, replies_re: str) -> dict[str, int]:
    starts = list(re.finditer(ts_re, text))
    out = {}
    for i, m in enumerate(starts):
        block = text[m.end(): starts[i + 1].start() if i + 1 < len(starts) else len(text)]
        r = re.search(replies_re, block)
        count = next((g for g in r.groups() if g), "0") if r else "0"
        out[m.group(1)] = int(count)
    return out


def parse(text: str, ts_re: str = TS_RE, replies_re: str = REPLIES_RE) -> dict[str, int]:
    if not text.strip():
        raise Unreadable("the dump is empty")
    try:
        obj = json.loads(text)
    except ValueError:
        obj = None
    found = parse_json(obj) if obj is not None else parse_text(text, ts_re, replies_re)
    if not found:
        raise Unreadable(f"no messages recognised in {len(text)} bytes")
    return found


def read_listing(path: str) -> dict[str, int]:
    out = {}
    if not os.path.exists(path):
        return out
    for n, line in enumerate(open(path), 1):
        line = line.rstrip("\n")
        if not line:
            continue
        ts, _, count = line.partition("\t")
        if not re.fullmatch(r"\d{9,10}\.\d{6}", ts) or not count.isdigit():
            raise Unreadable(f"{path}:{n}: not ts<TAB>reply_count: {line[:60]!r}")
        out[ts] = int(count)
    return out


def merge(snapshot: dict[str, int], page: dict[str, int]) -> dict[str, int]:
    """Keep the snapshot's lines older than the page; the page replaces the rest."""
    if not page:
        return dict(snapshot)
    oldest = min(map(ts_key, page))
    kept = {ts: c for ts, c in snapshot.items() if ts_key(ts) < oldest}
    kept.update(page)
    return kept


def render(listing: dict[str, int]) -> str:
    return "".join(f"{ts}\t{listing[ts]}\n" for ts in sorted(listing, key=ts_key))


def patterns(args) -> tuple[str, str]:
    ts_re, replies_re = args.ts_pattern, args.replies_pattern
    if not (ts_re and replies_re):
        try:
            s = hub.load_config(args.config).get("slack", {})
        except hub.ConfigError:
            s = {}
        ts_re = ts_re or s.get("listing_ts_pattern") or TS_RE
        replies_re = replies_re or s.get("listing_replies_pattern") or REPLIES_RE
    return ts_re, replies_re


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dump")
    ap.add_argument("--merge", metavar="SNAPSHOT")
    ap.add_argument("-o", "--out")
    ap.add_argument("--ts-pattern")
    ap.add_argument("--replies-pattern")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        page = parse(open(args.dump).read(), *patterns(args))
        listing = merge(read_listing(args.merge), page) if args.merge else page
    except (Unreadable, OSError) as e:
        print(f"UNREADABLE: {e}", file=sys.stderr)
        return 2
    out = render(listing)
    if args.out:
        with open(args.out, "w") as f:
            f.write(out)
        print(f"{len(listing)} lines ({len(page)} from the page) -> {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
