#!/usr/bin/env python3
"""flat-tool: how many widgets a region holds.

  tool.py --region R           the count
  tool.py --region R --move    move the region's widgets (no dry run: a fixture's violation)
"""
import argparse
import json
import urllib.request

API = "https://widgets.example/api"


def count(region: str) -> int:
    with urllib.request.urlopen(f"{API}/count?region={region}") as r:
        return json.load(r)["count"]


def move(region: str) -> int:
    req = urllib.request.Request(f"{API}/move?region={region}", method="POST")
    with urllib.request.urlopen(req) as r:
        return r.status


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--region", required=True)
    p.add_argument("--move", action="store_true")
    a = p.parse_args(argv)
    print(move(a.region) if a.move else count(a.region))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
