#!/usr/bin/env python3
"""Turn a Slack read_channel dump into one line per top-level message,
`ts<TAB>reply_count`, oldest first.

  slack_listing.py DUMP... [-o LISTING]           the page's listing (several dumps: one listing)
  slack_listing.py DUMP... --merge SNAPSHOT [-o]  that page merged into a snapshot

Accepted dumps: Slack API JSON (a `messages` list, or any list of objects with a
string `ts`; a reply whose `thread_ts` differs from its `ts` is skipped), the
tool's JSON envelope around a text dump, several JSON documents in one file,
and text: one message per line that starts with its ts, or blocks with a
labelled ts line such as `ts: 1712345678.123456` and, when threaded, a reply
count such as `replies: 3`. Another text shape: pass --ts-pattern and
--replies-pattern (one group each), or set slack.listing_ts_pattern and
slack.listing_replies_pattern in the config.

Input it cannot read is an error, never an empty listing: an empty page reads as
"nothing new", and that is the answer a failed read must not give. Two more
reads are refused for the same reason: a page where no message carries a reply
count or a thread marker, which is what the tool's short (concise) read looks
like, since a dropped count read as 0 hides a thread that moved (--no-threads
accepts it, only after reading that no message on the page has a thread); and
a page whose cursor points newer than its newest message, which is a page read
with `oldest`, oldest first, so the newest messages are missing.
Exit 0, or 2 when the dump is unreadable.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402

TS_RE = r"(?im)^[\s*_>|-]*(?:message[ _]?)?(?:ts|timestamp)\**\s*[:=]\s*\**\s*[\"'`]?(\d{9,10}\.\d{6})"
# A one-line dump: the ts leads the line, perhaps inside brackets.
TS_LINE_RE = r"(?m)^[\s*_>|(\[-]*(\d{9,10}\.\d{6})\b"
THREAD_TS_RE = r"(?im)(?:^|[\s(\[,*_>|-])thread[ _]?ts\**\s*[:=]\s*\**\s*[\"'`]?(\d{9,10}\.\d{6})"
# A labelled count wins over a bare "3 replies", which a message's own text can say.
REPLIES_LABELLED = r"(?im)(?:reply[ _]count|replies|thread replies)\**\s*[:=]\s*\**\s*(\d+)"
REPLIES_BARE = r"(?i)\b(\d+) repl(?:y|ies)\b"
CURSOR_RE = r"(?im)(?:next[_ ]?cursor|cursor)\**\s*[:=]\s*\**\s*[\"'`]?([\w+/=:]{6,})"
NO_THREADS = ("no message carries a reply count or a thread marker: a short (concise) read, which "
              "drops them; read the page in full, or pass --no-threads after reading that no "
              "message on the page has a thread")


class Unreadable(Exception):
    pass


def ts_key(ts: str) -> tuple[int, int]:
    sec, _, frac = ts.partition(".")
    return int(sec), int(frac or 0)


def cursor_ts(token: str | None) -> str | None:
    """The ts a page cursor points at, from `next_ts:<digits>` plain or base64."""
    if not token:
        return None
    m = re.fullmatch(r"next_ts:(\d{15,16})", token)
    if not m:
        try:
            m = re.fullmatch(r"next_ts:(\d{15,16})", base64.b64decode(token + "=" * (-len(token) % 4)).decode())
        except (ValueError, UnicodeDecodeError):
            return None
    if not m:
        return None
    d = m.group(1)
    return f"{d[:-6]}.{d[-6:]}"


def check_cursor(found: dict[str, int], cursor: str | None, where: str) -> None:
    if not found or not cursor:
        return
    newest = max(found, key=ts_key)
    if ts_key(cursor) > ts_key(newest):
        raise Unreadable(f"{where}: the page cursor points at {cursor}, newer than the newest message {newest}: "
                         "the page was read with oldest, so it starts at the oldest message and the newest "
                         "are missing; read it again without oldest")


def _documents(text: str) -> list:
    """The JSON documents in the dump in order, or [text] when it is not JSON."""
    dec = json.JSONDecoder()
    docs, i = [], 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return docs
        try:
            obj, i = dec.raw_decode(text, i)
        except ValueError:
            return [text]
        docs.append(obj)


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


def _find_key(obj, key: str):
    if isinstance(obj, dict):
        if isinstance(obj.get(key), str):
            return obj[key]
        for v in obj.values():
            found = _find_key(v, key)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _find_key(v, key)
            if found is not None:
                return found
    return None


def _strings(obj):
    """Every string in a JSON envelope, longest first: the tool wraps its text dump in one."""
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _strings(v)


def parse_json(obj, ts_re: str, replies_re: str | None) -> tuple[dict[str, int], bool]:
    msgs = _message_list(obj)
    if msgs is None:
        inner = [s for s in _strings(obj) if re.search(r"\d{9,10}\.\d{6}", s)]
        if not inner:
            raise Unreadable("JSON with no list of messages carrying a ts")
        return parse_text("\n".join(inner), ts_re, replies_re)
    out, signal = {}, False
    for m in msgs:
        ts = m.get("ts")
        if not isinstance(ts, str):
            raise Unreadable(f"a ts that is not a string ({ts!r}): a float loses the digits that make it unique")
        if "reply_count" in m or "thread_ts" in m:
            signal = True
        if m.get("thread_ts") not in (None, ts):
            continue
        out[ts] = int(m.get("reply_count") or 0)
    check_cursor(out, cursor_ts(_find_key(obj, "next_cursor")), "JSON")
    return out, signal


def parse_text(text: str, ts_re: str, replies_re: str | None) -> tuple[dict[str, int], bool]:
    starts = list(re.finditer(ts_re, text))
    if not starts and ts_re == TS_RE:
        starts = list(re.finditer(TS_LINE_RE, text))
    out, signal = {}, False
    for i, m in enumerate(starts):
        block = text[m.end(): starts[i + 1].start() if i + 1 < len(starts) else len(text)]
        th = re.search(THREAD_TS_RE, block)
        signal = signal or bool(th)
        if th and th.group(1) != m.group(1):
            continue
        if replies_re:
            r = re.search(replies_re, block)
        else:
            r = re.search(REPLIES_LABELLED, block) or re.search(REPLIES_BARE, block)
        signal = signal or bool(r)
        count = next((g for g in r.groups() if g), "0") if r else "0"
        out[m.group(1)] = int(count)
    cur = re.search(CURSOR_RE, text)
    check_cursor(out, cursor_ts(cur.group(1) if cur else None), "text")
    return out, signal


def parse(text: str, ts_re: str = TS_RE, replies_re: str | None = None, no_threads: bool = False) -> dict[str, int]:
    if not text.strip():
        raise Unreadable("the dump is empty")
    found: dict[str, int] = {}
    for doc in _documents(text):
        page, signal = parse_text(doc, ts_re, replies_re) if isinstance(doc, str) else parse_json(doc, ts_re, replies_re)
        if page and not signal and not no_threads:
            raise Unreadable(NO_THREADS)
        found.update(page)
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
        replies_re = replies_re or s.get("listing_replies_pattern")
    return ts_re, replies_re


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dump", nargs="+")
    ap.add_argument("--merge", metavar="SNAPSHOT")
    ap.add_argument("-o", "--out")
    ap.add_argument("--ts-pattern")
    ap.add_argument("--replies-pattern")
    ap.add_argument("--no-threads", action="store_true", help="accept a page with no reply count on any message")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        page: dict[str, int] = {}
        for dump in args.dump:
            page.update(parse(open(dump).read(), *patterns(args), no_threads=args.no_threads))
        listing = merge(read_listing(args.merge), page) if args.merge else page
    except (Unreadable, OSError) as e:
        print(f"UNREADABLE: {e}", file=sys.stderr)
        return 2
    out = render(listing)
    if args.out:
        with open(args.out, "w") as f:
            f.write(out)
        print(f"{len(listing)} lines ({len(page)} from {len(args.dump)} page{'s' if len(args.dump) > 1 else ''})"
              f" -> {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
