#!/usr/bin/env python3
"""The conversation on a PR in time order, for a reviewer: the description,
every comment, every review with its body (an empty one says so) and every
inline thread with its path and line. The transcript half of reading a PR;
the diff is `gh pr diff`.

  pr_transcript.py owner/repo#N [-o FILE]

The first line is `head: <sha>`, the commit the review is of: pass it to
review_lint.py --head. A PR with more than one page of comments, reviews or
threads is refused: a partial transcript reads as complete.
Exit 0, or 3 when the PR could not be read in full.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402

TRANSCRIPT = """query CommsTranscript($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){
 pullRequest(number:$number){number url title state isDraft headRefOid createdAt body author{login}
  comments(first:100){pageInfo{hasNextPage} nodes{author{login} createdAt body}}
  reviews(first:100){pageInfo{hasNextPage} nodes{author{login} state submittedAt body commit{oid}}}
  reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved path line
   comments(first:50){pageInfo{hasNextPage} nodes{author{login} createdAt body}}}}}}}"""


def partial(pr: dict) -> str | None:
    """Which list has more than one page, or None."""
    for k in ("comments", "reviews", "reviewThreads"):
        if pr[k]["pageInfo"].get("hasNextPage"):
            return k
    for t in pr["reviewThreads"]["nodes"]:
        if t["comments"]["pageInfo"].get("hasNextPage"):
            return f"a thread at {t.get('path')}:{t.get('line')}"
    return None


def render(ref: str, pr: dict) -> str:
    who = lambda x: hub.login(x.get("author")) or "a deleted account"  # noqa: E731
    lines = [f"head: {pr['headRefOid']}", f"# {ref}: {pr['title']}",
             f"{pr['url']} {pr['state']}{' draft' if pr.get('isDraft') else ''} by {who(pr)} opened {pr['createdAt']}",
             "", "## Description", (pr.get("body") or "").strip() or "(no description)", "",
             "## Conversation, oldest first"]
    events = [(c["createdAt"], f"{who(c)} comment", c.get("body")) for c in pr["comments"]["nodes"]]
    for r in pr["reviews"]["nodes"]:
        if r.get("state") == "PENDING":
            continue
        oid = ((r.get("commit") or {}).get("oid") or "?")[:7]
        events.append((r["submittedAt"], f"{who(r)} review {r['state']} at {oid}", r.get("body")))
    for t in pr["reviewThreads"]["nodes"]:
        where = f"{t.get('path')}:{t.get('line') or '?'}" + (" (resolved)" if t.get("isResolved") else "")
        for i, c in enumerate(t["comments"]["nodes"]):
            events.append((c["createdAt"], f"{who(c)} inline {where}" + (" reply" if i else ""), c.get("body")))
    for at, label, body in sorted(events):
        lines += [f"### {at} {label}", (body or "").strip() or "(no body)", ""]
    return "\n".join(lines) + "\n"


def main(argv=None, gh=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pr", metavar="owner/repo#N")
    ap.add_argument("-o", "--out")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        hub.load_config(args.config)
        owner, name, number = hub.split_pr(args.pr)
    except (hub.ConfigError, ValueError) as e:
        print(f"config: {e}")
        return 2
    try:
        pr = (gh or hub.Gh()).graphql(TRANSCRIPT, owner=owner, name=name, number=number)["repository"]["pullRequest"]
    except hub.GhError as e:
        print(f"BLOCKED: {args.pr} could not be read: {e}")
        return 3
    if pr is None:
        print(f"BLOCKED: {args.pr} not found")
        return 3
    more = partial(pr)
    if more:
        print(f"BLOCKED: {args.pr} has more than one page of {more}; a partial transcript reads as complete")
        return 3
    text = render(args.pr, pr)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(text.splitlines()[0])
        print(f"{len(text.splitlines())} lines -> {args.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
