#!/usr/bin/env python3
"""What moved in a channel since the last committed snapshot.

  slack_diff.py LISTING --channel NAME                      NEW, MOVED and GONE threads
  slack_diff.py LISTING --channel NAME --commit --read TS…  merge the page into the snapshot
  slack_diff.py LISTING --channel NAME --commit --baseline  first run only: accept the page unread

LISTING is slack_listing.py output for a fresh first page (read without
`oldest`). NEW is a ts the snapshot lacks, MOVED a reply count that changed, GONE
a snapshot line inside the page's window that the page no longer has. --commit
refuses unless --read names every NEW and MOVED ts, because the protocol commits
only after reading each of those threads in full; it then says what it wrote.
The snapshot is <state_dir>/slack/<channel>.tsv unless --snapshot names one.
Exit 0, or 2 when the diff cannot be trusted or the commit is refused.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402
import slack_listing as sl  # noqa: E402


def diff(snapshot: dict[str, int], page: dict[str, int]):
    new = [ts for ts in page if ts not in snapshot]
    moved = [ts for ts in page if ts in snapshot and snapshot[ts] != page[ts]]
    oldest = min(map(sl.ts_key, page)) if page else None
    gone = [ts for ts in snapshot if oldest and sl.ts_key(ts) >= oldest and ts not in page]
    order = lambda xs: sorted(xs, key=sl.ts_key)  # noqa: E731
    return order(new), order(moved), order(gone)


def snapshot_path(args) -> str:
    if args.snapshot:
        return args.snapshot
    cfg = None
    try:
        cfg = hub.load_config(args.config)
    except hub.ConfigError:
        pass
    d = hub.state_dir(cfg) / "slack"
    d.mkdir(exist_ok=True)
    return str(d / (re.sub(r"[^\w.-]", "_", args.channel) + ".tsv"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("listing")
    ap.add_argument("--channel", required=True)
    ap.add_argument("--snapshot")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--read", nargs="*", default=[], metavar="TS")
    ap.add_argument("--baseline", action="store_true")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    path = snapshot_path(args)
    try:
        page = sl.read_listing(args.listing)
        snap = sl.read_listing(path)
    except sl.Unreadable as e:
        print(f"UNREADABLE: {e}")
        return 2
    if not page:
        print(f"UNTRUSTED: the page is empty against a snapshot of {len(snap)}: "
              "the read failed or the parser missed its format. Nothing committed." if snap
              else "UNTRUSTED: the page is empty. Nothing committed.")
        return 2
    new, moved, gone = diff(snap, page)
    first = sorted(page, key=sl.ts_key)
    print(f"snapshot: {path} ({len(snap)} lines)" if snap else f"snapshot: none yet at {path}")
    print(f"page: {len(page)} messages, {first[0]} .. {first[-1]}")
    for ts in new:
        print(f"NEW {ts} replies={page[ts]}")
    for ts in moved:
        print(f"MOVED {ts} replies {snap[ts]} -> {page[ts]}")
    for ts in gone:
        print(f"GONE {ts} (in the snapshot inside this page's window; deleted, or the page is short)")
    print(f"summary: new={len(new)} moved={len(moved)} gone={len(gone)}")
    if not args.commit:
        return 0
    read = {t for arg in args.read for t in re.split(r"[,\s]+", arg) if t}
    if args.baseline:
        if snap:
            print("REFUSED: --baseline is for the first run; this channel has a snapshot")
            return 2
        read |= set(new)
        print(f"BASELINE: {len(new)} messages accepted unread; nothing before this tick was checked")
    unread = [ts for ts in new + moved if ts not in read]
    if unread:
        print(f"REFUSED: read these threads in full first, then pass them to --read: {' '.join(unread)}")
        return 2
    merged = sl.merge(snap, page)
    kept = len(merged) - len(page)
    tmp = path + ".next"
    with open(tmp, "w") as f:
        f.write(sl.render(merged))
    os.replace(tmp, path)
    print(f"committed: kept {kept} older lines, replaced the rest with the page's {len(page)}; "
          f"snapshot now {len(merged)} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
