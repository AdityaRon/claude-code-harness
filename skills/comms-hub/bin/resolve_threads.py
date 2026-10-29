#!/usr/bin/env python3
"""Resolve review threads on my own open PRs that were answered and then approved.

  resolve_threads.py [--pr owner/repo#N ...]          dry run: RESOLVE and SKIP, with reasons
  resolve_threads.py --apply [--pr owner/repo#N ...]  resolve, then re-read each thread

A thread is resolved only when all hold:
  1. the PR is mine and open;
  2. the thread is unresolved and was opened by a reviewer: not me, not a bot;
  3. the last comment on the thread is mine;
  4. the opener's standing review is APPROVED (their last review that is not
     COMMENTED, so a later CHANGES_REQUESTED or DISMISSED revokes it and a
     thread reply does not);
  5. that approval was submitted after our last reply on the thread.
A RESOLVE whose approval sits on an older commit than the head says so (DRIFT):
the thread still resolves, the approval still needs renewing.
A PR whose thread or review list is longer than one page is skipped, and so is
a thread whose comments are. After --apply, isResolved is what GitHub says.
Exit 0, or 3 when a fetch, a mutation or a re-read failed.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402

VIEWER = """query CommsViewer{viewer{login}}"""

MY_OPEN = """query CommsMyOpenThreads($cursor:String){viewer{login pullRequests(states:OPEN,first:100,after:$cursor){
 pageInfo{hasNextPage endCursor} nodes{number repository{nameWithOwner owner{login}}}}}}"""

THREADS = """query CommsThreads($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){
 pullRequest(number:$number){number url state headRefOid author{login __typename}
  reviews(first:100){pageInfo{hasNextPage} nodes{author{login __typename} state submittedAt commit{oid}}}
  reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved path line
   comments(first:100){pageInfo{hasNextPage} nodes{author{login __typename} createdAt}}}}}}}"""

RESOLVE = """mutation CommsResolve($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}"""

REREAD = """query CommsThread($id:ID!){node(id:$id){... on PullRequestReviewThread{id isResolved}}}"""


def decide(pr: dict, me: str):
    """(pr_skip_reason or None, [(verdict, thread, reason)])."""
    if not hub.is_me(pr.get("author"), me):
        return "not my PR", []
    if pr.get("state") != "OPEN":
        return f"PR is {pr.get('state')}", []
    if pr["reviews"]["pageInfo"]["hasNextPage"]:
        return "more than one page of reviews", []
    if pr["reviewThreads"]["pageInfo"]["hasNextPage"]:
        return "more than one page of review threads", []
    standing = hub.standing_reviews(pr["reviews"]["nodes"])
    out = []
    for t in pr["reviewThreads"]["nodes"]:
        if t.get("isResolved"):
            continue
        comments = t["comments"]["nodes"]
        if t["comments"]["pageInfo"]["hasNextPage"]:
            out.append(("SKIP", t, "thread longer than one page"))
            continue
        if not comments:
            out.append(("SKIP", t, "no comments"))
            continue
        opener = comments[0].get("author")
        if hub.login(opener) is None:
            out.append(("SKIP", t, "opener unknown (deleted account)"))
            continue
        if hub.is_me(opener, me):
            out.append(("SKIP", t, "I opened it"))
            continue
        if hub.is_bot(opener):
            out.append(("SKIP", t, f"opened by a bot ({hub.login(opener)})"))
            continue
        last = comments[-1]
        if not hub.is_me(last.get("author"), me):
            out.append(("SKIP", t, f"{hub.login(last.get('author'))} has the last word"))
            continue
        review = standing.get(hub.login(opener))
        if not review or review.get("state") != "APPROVED":
            out.append(("SKIP", t, f"{hub.login(opener)}'s standing review is {review['state'] if review else 'none'}"))
            continue
        if hub.parse_time(review["submittedAt"]) <= hub.parse_time(last["createdAt"]):
            out.append(("SKIP", t, f"{hub.login(opener)} approved before our last reply"))
            continue
        why = f"{hub.login(opener)} approved {review['submittedAt']} after our reply {last['createdAt']}"
        oid, head = (review.get("commit") or {}).get("oid"), pr.get("headRefOid")
        if oid and head and oid != head:
            why += f"; approval at {oid[:7]}, head is {head[:7]} (DRIFT: the thread resolves, the approval is older)"
        out.append(("RESOLVE", t, why))
    return None, out


def my_open_prs(gh: hub.Gh, owners: list[str]) -> list[str]:
    refs, cursor = [], None
    want = {o.lower() for o in owners}
    while True:
        page = gh.graphql(MY_OPEN, cursor=cursor)["viewer"]["pullRequests"]
        for n in page["nodes"]:
            if n["repository"]["owner"]["login"].lower() in want:
                refs.append(f"{n['repository']['nameWithOwner']}#{n['number']}")
        if not page["pageInfo"]["hasNextPage"]:
            return refs
        cursor = page["pageInfo"]["endCursor"]


def main(argv=None, gh=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--pr", action="append", default=[], metavar="owner/repo#N")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        cfg = hub.load_config(args.config)
    except hub.ConfigError as e:
        print(f"config: {e}")
        return 2
    gh = gh or hub.Gh()
    me = cfg["github"]["login"]
    rc = 0
    try:
        viewer = gh.graphql(VIEWER)["viewer"]["login"]
    except hub.GhError as e:
        print(f"BLOCKED: could not read which account gh is signed in as: {e}")
        return 3
    if viewer.lower() != me.lower():
        print(f"BLOCKED: gh is signed in as {viewer}, the config says {me}; nothing resolved")
        return 3
    try:
        refs = args.pr or my_open_prs(gh, cfg["github"]["owners"])
    except hub.GhError as e:
        print(f"BLOCKED: listing my open PRs failed: {e}")
        return 3
    plan = []
    for ref in refs:
        owner, name, number = hub.split_pr(ref)
        try:
            pr = gh.graphql(THREADS, owner=owner, name=name, number=number)["repository"]["pullRequest"]
        except hub.GhError as e:
            print(f"UNKNOWN {ref}: {e}")
            rc = 3
            continue
        skip, verdicts = decide(pr, me)
        if skip:
            print(f"SKIP {ref}: {skip}")
            continue
        for verdict, t, why in verdicts:
            where = f"{t.get('path') or '?'}:{t.get('line') or '?'}"
            print(f"{verdict} {ref} {where} thread={t['id']}: {why}")
            if verdict == "RESOLVE":
                plan.append((ref, where, t["id"]))
    print(f"summary: {len(plan)} to resolve across {len(refs)} PRs" + ("" if args.apply else " (dry run)"))
    if not args.apply:
        return rc
    for ref, where, tid in plan:
        try:
            gh.graphql(RESOLVE, id=tid)
        except hub.GhError as e:
            print(f"FAILED {ref} {where} thread={tid}: {e}")
            rc = 3
            continue
        try:
            resolved = bool(gh.graphql(REREAD, id=tid)["node"]["isResolved"])
        except hub.GhError as e:
            print(f"UNKNOWN {ref} {where} thread={tid}: resolved, but the re-read failed: {e}")
            rc = 3
            continue
        print(f"{'resolved' if resolved else 'STILL OPEN'} {ref} {where} thread={tid} isResolved={str(resolved).lower()} (re-read)")
        if resolved:
            hub.log_event(cfg, "resolved", "review thread", ref=ref, detail=f"thread {tid} ({where})")
        else:
            rc = 3
    return rc


if __name__ == "__main__":
    sys.exit(main())
