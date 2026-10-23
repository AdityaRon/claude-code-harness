#!/usr/bin/env python3
"""Lint a review body and confirm the PR before the review posts, as a COMMENT.

  review_lint.py FILE --pr owner/repo#N --head SHA   pass: prints the post command; else refuses

Shape: no em dash, no token-shaped string, no bullet under three words, at most
github.review_max_chars characters. Live: the PR is open, not a draft, and its
head is still SHA, the commit the reviewer read (pr_transcript.py prints it);
a head that moved may have answered the findings, so review again. On a pass
it prints the exact `gh pr review ... --comment --body-file FILE` to run next,
chained with &&: a `;` once let a refused body go out. A review from this
session is a COMMENT and nothing else: it never approves or requests changes,
since approval is the human's.
Exit 0 pass, 1 refused, 2 usage or config, 3 live state unknown.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_draft as cd  # noqa: E402
import hub  # noqa: E402


def lint(text: str, cap: int) -> list[str]:
    out = []
    if not text.strip():
        out.append("the body is empty")
    if len(text) > cap:
        out.append(f"{len(text)} characters, over the {cap} cap (github.review_max_chars): lead with what matters")
    out += cd.thin_bullets(text)
    for n, line in enumerate(text.splitlines(), 1):
        if cd.EM_DASH in line:
            out.append(f"line {n}: em dash")
    if cd.TOKEN.search(text):
        out.append("a token-shaped string: no secrets in a review")
    return out


def live(gh: hub.Gh, owner: str, repo: str, n: int, head: str) -> tuple[list[str], bool]:
    """What stops the review from posting, and whether the state was readable."""
    ref = f"{owner}/{repo}#{n}"
    try:
        d = gh.json(["pr", "view", str(n), "--repo", f"{owner}/{repo}", "--json", "state,isDraft,headRefOid"])
    except hub.GhError as e:
        return [f"{ref} live state unknown ({e})"], False
    out = []
    if d.get("state") != "OPEN":
        out.append(f"{ref} is {d.get('state')}: nothing to review")
    if d.get("isDraft"):
        out.append(f"{ref} is a draft: a review was not asked for")
    now = d.get("headRefOid") or "?"
    if now != head:
        out.append(f"{ref} head is {now[:7]}, the review read {head[:7]}: review again from the new head")
    return out, True


def main(argv=None, gh=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file")
    ap.add_argument("--pr", required=True, metavar="owner/repo#N")
    ap.add_argument("--head", required=True, metavar="SHA", help="the head the reviewer read")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        cfg = hub.load_config(args.config)
        owner, repo, n = hub.split_pr(args.pr)
    except (hub.ConfigError, ValueError) as e:
        print(f"config: {e}")
        return 2
    if not os.path.isfile(args.file):
        print(f"no such file: {args.file}")
        return 2
    problems = lint(open(args.file, encoding="utf-8").read(), int(cfg["github"]["review_max_chars"]))
    stops, known = live(gh or hub.Gh(), owner, repo, n, args.head)
    for p in problems + stops:
        print(f"{'FAIL' if known else 'BLOCKED'}: {p}")
    if not known:
        return 3
    if problems or stops:
        return 1
    print(f"PASS: post it as a comment, in one command with && (never ;):")
    print(f"post: gh pr review {n} --repo {owner}/{repo} --comment --body-file {args.file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
