#!/usr/bin/env python3
"""Lint a review and confirm the PR before the review posts, as a COMMENT.

  review_lint.py --post REVIEW.json --pr owner/repo#N   lint, then post it, inline comments included
  review_lint.py FILE --pr owner/repo#N --head SHA      lint a body; pass: prints the post command

REVIEW.json, which the reviewer writes:
  {"head": "<the 40-character sha it read>", "body": "...",
   "comments": [{"path": "src/a.py", "line": 3, "side": "RIGHT", "body": "..."}],
   "findings": [{"kind": "nit|consider|question|blocking"}], "escalate": "<why, or absent>"}

Shape: no em dash, no token-shaped string, no bullet under three words, the body
at most github.review_max_chars characters; each inline comment too. Live: the
PR is open, not a draft, and its head is still the one the reviewer read
(pr_transcript.py prints it); a head that moved may have answered the findings,
so review again. --post then posts through the reviews API, which a hand-typed
`gh pr review --body-file` could not: it dropped the inline comments, and a
piped lint once let three refused reviews go out. It logs the review under
Needs you with its verdict: approvable when every finding is a nit or a
consider, else needs your read. The scan turns that into a re-look when the
head moves, and closes it when the user approves or it merges.
A review from this session is a COMMENT and nothing else: it never approves or
requests changes, since approval is the human's.
Exit 0 pass (posted, with --post), 1 refused, 2 usage or config, 3 live state
unknown or the post failed: nothing was logged, so the review is still to do.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile

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


KINDS = ("nit", "consider", "question", "blocking")


def review_problems(r) -> list[str]:
    """What makes REVIEW.json unpostable as written."""
    if not isinstance(r, dict):
        return ["the review is not a JSON object"]
    out = []
    if not re.fullmatch(r"[0-9a-f]{40}", str(r.get("head") or "")):
        out.append("head must be the full 40-character sha the reviewer read: a short one can name another commit")
    if not isinstance(r.get("body"), str):
        out.append("body must be text")
    for i, c in enumerate(r.get("comments") or [], 1):
        if not (isinstance(c, dict) and c.get("path") and isinstance(c.get("line"), int) and isinstance(c.get("body"), str)):
            out.append(f"comment {i} needs path, an integer line and body")
    for i, f in enumerate(r.get("findings") or [], 1):
        if not isinstance(f, dict) or f.get("kind") not in KINDS:
            out.append(f"finding {i} needs a kind, one of {', '.join(KINDS)}")
    return out


def verdict(r: dict) -> str:
    """approvable: nothing but nits and considers; else the user reads it first."""
    if r.get("escalate") or any(f.get("kind") not in ("nit", "consider") for f in r.get("findings") or []):
        return "needs your read"
    return "approvable"


def post(cfg: dict, gh: hub.Gh, owner: str, repo: str, n: int, r: dict) -> int:
    """Post as a COMMENT through the reviews API, then log it for Needs you."""
    payload = {"commit_id": r["head"], "event": "COMMENT", "body": r["body"],
               "comments": [{"path": c["path"], "line": c["line"], "side": c.get("side") or "RIGHT", "body": c["body"]}
                            for c in r.get("comments") or []]}
    # A file, not stdin: gh runs with this process's stdin, which is not the payload.
    fd, path = tempfile.mkstemp(prefix="review-", suffix=".json", dir=hub.tmp_dir(cfg))
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f)
    try:
        res = gh.json(["api", "-X", "POST", f"repos/{owner}/{repo}/pulls/{n}/reviews", "--input", path])
    except hub.GhError as e:
        print(f"BLOCKED: the post failed, so nothing was logged and the review is still to do: {e}")
        return 3
    finally:
        os.unlink(path)
    ref = f"{owner}/{repo}#{n}"
    url = res.get("html_url") or f"https://github.com/{owner}/{repo}/pull/{n}"
    print(f"POSTED: review {res.get('id')} on {ref} at {r['head'][:7]} as {res.get('state')}: {url}")
    # One review row per PR: a new review replaces the last one's.
    old = next((x for x in hub.open_items(cfg)[0] if x["kind"] == "reviewed" and same_pr(x["ref"], ref)), None)
    row = hub.log_event(cfg, "reviewed", verdict(r), ref=f"https://github.com/{owner}/{repo}/pull/{n}",
                        needs_user=True, corrects=old["id"] if old else "",
                        detail=f"sha={r['head']} review={res.get('id')} findings={len(r.get('findings') or [])}")
    print(f"logged {row['id']}: reviewed {row['text']}")
    for t in hub.folded(cfg, hub.OPEN_DAYS):
        if t["kind"] == "todo" and re.search(rf"\bkey=review:{re.escape(ref)}@", t.get("detail") or ""):
            hub.log_event(cfg, "done", "review posted", ref=row["ref"], corrects=t["id"])
            print(f"closed {t['id']}: the review it was waiting on")
    return 0


def same_pr(link: str, ref: str) -> bool:
    o, r_, n = hub.split_pr(ref)
    return bool(re.search(rf"github\.com/{re.escape(o)}/{re.escape(r_)}/pull/{n}\b", link or "")) or link == ref


def main(argv=None, gh=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file", nargs="?", help="a review body, for the lint alone")
    ap.add_argument("--post", metavar="REVIEW.json", help="lint the review, then post it with its inline comments")
    ap.add_argument("--pr", required=True, metavar="owner/repo#N")
    ap.add_argument("--head", metavar="SHA", help="the head the reviewer read (FILE only; REVIEW.json carries it)")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        cfg = hub.load_config(args.config)
        owner, repo, n = hub.split_pr(args.pr)
    except (hub.ConfigError, ValueError) as e:
        print(f"config: {e}")
        return 2
    if bool(args.post) == bool(args.file) or (args.file and not args.head):
        print("usage: review_lint.py --post REVIEW.json --pr owner/repo#N, or FILE --pr owner/repo#N --head SHA")
        return 2
    if args.post:
        try:
            with open(args.post, encoding="utf-8") as f:
                r = json.load(f)
        except (OSError, ValueError) as e:
            print(f"cannot read {args.post}: {e}")
            return 2
        bad = review_problems(r)
        cap = int(cfg["github"]["review_max_chars"])
        if not bad:
            bad = lint(r["body"], cap) + [f"comment {i} ({c['path']}:{c['line']}): {p}"
                                          for i, c in enumerate(r.get("comments") or [], 1)
                                          for p in lint(c["body"], cap)]
        gh = gh or hub.Gh()
        stops, known = live(gh, owner, repo, n, r["head"]) if not review_problems(r) else ([], True)
        for p in bad + stops:
            print(f"{'FAIL' if known else 'BLOCKED'}: {p}")
        if not known:
            return 3
        if bad or stops:
            return 1
        return post(cfg, gh, owner, repo, n, r)
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
