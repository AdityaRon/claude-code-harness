#!/usr/bin/env python3
"""hand-metrics: request rates by job, from the metrics API at $HAND_PROM_URL.

  tool.py query EXPR        each series' value, one per line: JOB VALUE
  tool.py top EXPR --k N    the N largest
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def fetch(expr: str) -> list:
    url = os.environ["HAND_PROM_URL"].rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return json.load(r)["data"]["result"]
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            print("AUTH: the session expired; re-login with: tsh login")
            sys.exit(4)
        raise


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    q = sub.add_parser("query")
    q.add_argument("expr")
    t = sub.add_parser("top")
    t.add_argument("expr")
    t.add_argument("--k", type=int, default=5)
    a = p.parse_args(argv)
    rows = [(s["metric"].get("job", "?"), float(s["value"][1])) for s in fetch(a.expr)]
    if not rows:
        print("no data")
        return 0
    if a.cmd == "top":
        rows = sorted(rows, key=lambda r: -r[1])[:a.k]
    for job, v in rows:
        print(f"{job} {v:g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
