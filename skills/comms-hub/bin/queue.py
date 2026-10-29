#!/usr/bin/env python3
"""The GitHub side of a comms tick.

  queue.py scan [--wall-limit S]

Sections: INBOUND (review requested from me personally, not through a team,
drafts left out), REVIEWED (anyone's open PR whose head moved since my last
review: a re-look, with the `compare` range), WATCHED (open PRs by watched
authors that I have not reviewed at their current head, requested or not,
drafts left out), AWAITING (my open PRs with nothing new from anyone), OUTBOUND
(activity on my PRs, open or merged within merged_days, newer than my last
reply; an approval or a dismissal that only approves, no body or "LGTM", is not
activity I owe a reply), ROUTE (each of those that asks something: a
[consider], [question] or [blocking] tag, a '?' outside code, links and quotes,
or changes requested), DRIFT (an approval pinned to an older head), UNKNOWN (a
PR that could not be read). The header prints search-quota, my-open-xcheck and,
for a watched author the search finds nothing for, whether graphql agrees.

The scan writes to the log itself, each row once (`key=` in its detail): a
`todo` per ROUTE item and per review or re-look, before the session starts the
work; a `blocked` row needing the user for a scheduled message that posted with
no re-gate since the window opened. It closes a todo GitHub shows is done, and a
`reviewed` row once the user approves or the PR merges, or turns it into a
re-look when the head moves.

A scan that does not end BLOCKED replaces <state dir>/prs.json, which the panel
reads: {"written_at": ISO, "reviewing": [PR], "authored": [PR]}, each PR
{ref, url, title, author, head, ci, decision, merge, my_state, my_sha,
approvals, changes_requested, unresolved, requested}, and requested_me on a
reviewing one.

A scan that prints BLOCKED (exit 3) means the queue is unknown, not empty.
A scan still running from an earlier tick is killed first.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub  # noqa: E402

WALL_LIMIT = 330
POLL = float(os.environ.get("COMMS_HUB_WATCHDOG_POLL", "5"))

MY_OPEN = """query CommsMyOpen($cursor:String){viewer{login pullRequests(states:OPEN,first:100,after:$cursor){
 pageInfo{hasNextPage endCursor} nodes{number repository{nameWithOwner isArchived owner{login}}}}}}"""

MINE = """query CommsMine($cursor:String){viewer{pullRequests(states:[OPEN,MERGED],first:25,after:$cursor,
 orderBy:{field:UPDATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor}
 nodes{number state updatedAt mergedAt repository{nameWithOwner isArchived owner{login}}}}}}"""

AUTHOR_OPEN = """query CommsAuthorOpen($login:String!,$cursor:String){user(login:$login){pullRequests(states:OPEN,first:100,after:$cursor){
 pageInfo{hasNextPage endCursor} nodes{number isDraft repository{nameWithOwner isArchived owner{login}}}}}}"""

PR = """query CommsPR($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){
 pullRequest(number:$number){number url title state isDraft createdAt mergedAt headRefOid mergeStateStatus
  reviewDecision author{login}
  reviewRequests(first:50){nodes{requestedReviewer{__typename ... on User{login} ... on Team{slug}
   ... on Bot{login} ... on Mannequin{login}}}}
  reviews(first:100){pageInfo{hasNextPage} nodes{author{login __typename} state body submittedAt commit{oid}}}
  comments(first:100){pageInfo{hasNextPage endCursor} nodes{author{login __typename} createdAt body}}
  reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved
   comments(first:50){pageInfo{hasNextPage endCursor} nodes{author{login __typename} createdAt body}}}}
  commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100){pageInfo{hasNextPage}
   nodes{__typename ... on CheckRun{name status conclusion startedAt completedAt}
   ... on StatusContext{context state createdAt}}}}}}}}}}"""


COMMENTS = """query CommsComments($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){
 pullRequest(number:$number){comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor}
  nodes{author{login __typename} createdAt body}}}}}"""

THREAD_COMMENTS = """query CommsThreadComments($id:ID!,$cursor:String){node(id:$id){... on PullRequestReviewThread{
 comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{author{login __typename} createdAt body}}}}}"""


class Blocked(Exception):
    pass


def page_all(first: dict, more, what: str) -> list[dict]:
    """Every node behind a first page: `more(cursor)` fetches the next. A list
    that reads short says "nothing new" about what fell off it."""
    nodes, info, pages = list(first["nodes"]), first["pageInfo"], 1
    while info.get("hasNextPage"):
        if pages >= 20:
            raise hub.GhError(f"more than 20 pages of {what}")
        nxt = more(info["endCursor"])
        nodes += nxt["nodes"]
        info = nxt["pageInfo"]
        pages += 1
    return nodes


# ---- the watchdog and the previous scan ------------------------------------

def watchdog(limit: float, poll: float = POLL, exit_fn=os._exit, on_fire=None) -> threading.Thread:
    """Wall-clock time, not monotonic: monotonic time and subprocess timeouts stop
    while a laptop sleeps, so a scan caught by sleep would resume hours later
    and report a stale queue as current. os._exit, because the main thread sits
    in subprocess.run and an exception raised here never reaches it."""
    clock = time.time
    start = clock()

    def loop():
        while True:
            time.sleep(poll)
            if clock() - start > limit:
                if on_fire:
                    on_fire()
                sys.stdout.write(f"BLOCKED: past the {limit:g}s wall-clock limit (the machine slept, or gh hung); "
                                 "the queue is unknown, not empty\n")
                sys.stdout.flush()
                exit_fn(3)
                return

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def kill_previous(pidfile) -> str | None:
    try:
        pid_s, started = pidfile.read_text().split()[:2]
        pid = int(pid_s)
    except (OSError, ValueError):
        return None
    if pid == os.getpid() or not alive(pid):
        return None
    cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    # A reused pid could be an editor open on this file: only a running scan is ours.
    if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):
        return None
    os.kill(pid, signal.SIGTERM)
    for _ in range(30):
        if not alive(pid):
            break
        time.sleep(0.1)
    else:
        os.kill(pid, signal.SIGKILL)
    return f"killed a previous scan still running (pid {pid}, started {started})"


# ---- search ----------------------------------------------------------------

def search(gh: hub.Gh, q: str) -> tuple[list[dict], int]:
    """Every row, or Blocked. A throttled search returns fewer rows, not an
    error, so the row count is checked against total_count."""
    items, page = [], 1
    while True:
        d = gh.json(["api", "-X", "GET", "search/issues", "-f", f"q={q}", "-f", "per_page=100", "-f", f"page={page}"])
        if d.get("incomplete_results"):
            raise Blocked(f"search {q!r}: GitHub marked the results incomplete")
        rows = d.get("items") or []
        items += rows
        total = d.get("total_count", 0)
        if len(items) >= total or not rows or page >= 10:
            break
        page += 1
    if len(items) != total:
        raise Blocked(f"search {q!r} returned {len(items)} of {total} rows")
    return items, page


def row_ref(item: dict) -> str:
    return f"{item['repository_url'].split('/repos/', 1)[1]}#{item['number']}"


def scope(owners) -> str:
    return " ".join(f"user:{o}" for o in owners)


# ---- my PRs ----------------------------------------------------------------

def my_open_graphql(gh: hub.Gh, me: str, owners) -> set[str]:
    want = {o.lower() for o in owners}
    refs, cursor = set(), None
    while True:
        v = gh.graphql(MY_OPEN, cursor=cursor)["viewer"]
        if v["login"].lower() != me.lower():
            raise Blocked(f"gh is signed in as {v['login']}, the config says {me}")
        page = v["pullRequests"]
        for n in page["nodes"]:
            if n["repository"].get("isArchived"):  # search's archived:false drops it too
                continue
            if n["repository"]["owner"]["login"].lower() in want:
                refs.add(f"{n['repository']['nameWithOwner']}#{n['number']}")
        if not page["pageInfo"]["hasNextPage"]:
            return refs
        cursor = page["pageInfo"]["endCursor"]


def author_open_graphql(gh: hub.Gh, author: str, owners, repos) -> set[str]:
    """An author's open, non-draft PRs in the watched repos (else the owners), by
    graphql: the check behind a search that found none."""
    want_repos = {r.lower() for r in repos}
    want_owners = {o.lower() for o in owners}
    refs, cursor = set(), None
    while True:
        page = gh.graphql(AUTHOR_OPEN, login=author, cursor=cursor)["user"]["pullRequests"]
        for n in page["nodes"]:
            repo = n["repository"]
            if n["isDraft"] or repo.get("isArchived"):
                continue
            if (repo["nameWithOwner"].lower() in want_repos if want_repos else repo["owner"]["login"].lower() in want_owners):
                refs.add(f"{repo['nameWithOwner']}#{n['number']}")
        if not page["pageInfo"]["hasNextPage"]:
            return refs
        cursor = page["pageInfo"]["endCursor"]


def my_recent(gh: hub.Gh, owners, cutoff: dt.datetime) -> tuple[set[str], int]:
    """My open PRs and those merged since the cutoff, newest update first, paged
    only until a page ends before the cutoff. Never a repo's whole PR list: one
    busy repo had 300+ PRs updated in a week, and a fixed first:50 dropped open ones."""
    want = {o.lower() for o in owners}
    refs, cursor, pages = set(), None, 0
    while True:
        pages += 1
        page = gh.graphql(MINE, cursor=cursor)["viewer"]["pullRequests"]
        for n in page["nodes"]:
            if n["repository"]["owner"]["login"].lower() not in want or n["repository"].get("isArchived"):
                continue
            merged = hub.parse_time(n.get("mergedAt"))
            if n["state"] == "OPEN" or (merged and merged >= cutoff):
                refs.add(f"{n['repository']['nameWithOwner']}#{n['number']}")
        nodes = page["nodes"]
        if not page["pageInfo"]["hasNextPage"] or not nodes or hub.parse_time(nodes[-1]["updatedAt"]) < cutoff:
            return refs, pages
        if pages >= 40:
            raise Blocked("paging my PRs did not reach the merged cutoff in 40 pages")
        cursor = page["pageInfo"]["endCursor"]


def fetch_pr(gh: hub.Gh, ref: str) -> dict:
    owner, name, number = hub.split_pr(ref)
    pr = gh.graphql(PR, owner=owner, name=name, number=number)["repository"]["pullRequest"]
    if pr is None:
        raise hub.GhError("not found")
    if pr["reviews"]["pageInfo"]["hasNextPage"]:
        raise hub.GhError("more than 100 reviews; the standing review cannot be read")
    if pr["reviewThreads"]["pageInfo"]["hasNextPage"]:
        raise hub.GhError("more than 100 review threads")
    pr["comments"]["nodes"] = page_all(
        pr["comments"], lambda c: gh.graphql(COMMENTS, owner=owner, name=name, number=number, cursor=c)
        ["repository"]["pullRequest"]["comments"], "comments")
    for t in pr["reviewThreads"]["nodes"]:
        t["comments"]["nodes"] = page_all(
            t["comments"], lambda c, tid=t["id"]: gh.graphql(THREAD_COMMENTS, id=tid, cursor=c)["node"]["comments"],
            "thread comments")
    return pr


TAG = re.compile(r"\[(consider|question|blocking)\]", re.I)
# What an approval says when it asks nothing. The ask check runs first, so
# "looks good, but why X?" is still a question.
ACK = re.compile(r"lgtm|looks good( to me)?|ship ?it|approved?|thanks?( you)?|thank you|nice( work| one)?|"
                 r"great( work)?|\+1|:\+1:|:shipit:|:white_check_mark:", re.I)


def ask_kind(body: str) -> str:
    """What a review, comment or thread comment asks: "consider", "question" or
    "blocking" from its tag, else "question" for a '?' outside code, links and
    quoted lines, else ''. A quote is the line being answered, not a new ask.
    An approval with a [consider] once logged as status and routed nothing."""
    m = TAG.search(body)
    if m:
        return m.group(1).lower()
    prose = re.sub(r"```.*?```", " ", body, flags=re.S)
    prose = re.sub(r"`[^`\n]*`", " ", prose)
    prose = re.sub(r"https?://\S+", " ", prose)
    prose = re.sub(r"(?m)^\s*>.*$", " ", prose)
    return "question" if "?" in prose else ""


def acknowledgement(body: str) -> bool:
    """True for a body that only approves: empty, "LGTM", "Looks good, thanks!"."""
    return not ask_kind(body) and not re.sub(r"[\W_]+", "", ACK.sub(" ", body))


def ask_line(body: str) -> str:
    """The line that asks, for the ROUTE row: 80 characters on one line."""
    lines = [ln.strip() for ln in body.splitlines() if ln.strip() and not ln.lstrip().startswith(">")]
    hit = next((ln for ln in lines if TAG.search(ln) or "?" in ln), lines[0] if lines else "")
    return hit[:80]


def classify(ref: str, pr: dict, me: str) -> dict:
    """The rows this PR contributes: outbound, route, awaiting, drift."""
    reviews = [r for r in pr["reviews"]["nodes"] if r.get("state") != "PENDING"]
    comments = pr["comments"]["nodes"]
    thread_comments = [c for t in pr["reviewThreads"]["nodes"] for c in t["comments"]["nodes"]]
    t = hub.parse_time
    mine = ([t(c["createdAt"]) for c in comments + thread_comments if hub.is_me(c.get("author"), me)]
            + [t(r["submittedAt"]) for r in reviews if hub.is_me(r.get("author"), me)])
    last_reply = max(mine) if mine else t(pr["createdAt"])

    def theirs(actor):
        return not hub.is_me(actor, me) and not hub.is_bot(actor)

    def who(actor):
        return hub.login(actor) or "a deleted account"

    def owed(r):
        """An approval or a dismissal that only approves (no body, "LGTM") asks
        nothing; its inline comments are thread comments, read on their own."""
        if r["state"] in ("APPROVED", "DISMISSED") and acknowledgement(r.get("body") or ""):
            return False
        return theirs(r.get("author"))

    events = ([(t(c["createdAt"]), who(c.get("author")), "comment", c.get("body") or "") for c in comments
               if theirs(c.get("author"))]
              + [(t(c["createdAt"]), who(c.get("author")), "thread comment", c.get("body") or "")
                 for c in thread_comments if theirs(c.get("author"))]
              + [(t(r["submittedAt"]), who(r.get("author")), f"review {r['state']}", r.get("body") or "")
                 for r in reviews if owed(r)])
    events = sorted((e for e in events if e[0] > last_reply), key=lambda e: e[:3])
    out = {"outbound": None, "route": [], "awaiting": None, "drift": []}
    url = pr["url"]
    for when, who_, kind, body in events:
        ask = ask_kind(body) or ("blocking" if kind == "review CHANGES_REQUESTED" else "")
        if ask:
            out["route"].append({"ref": ref, "who": who_, "what": kind, "ask": ask, "text": ask_line(body), "url": url,
                                 "at": f"{when:%Y%m%dT%H%M%S}"})
    if events:
        by: dict[str, dict[str, int]] = {}
        for _, who, kind, _ in events:
            by.setdefault(who, {}).setdefault(kind, 0)
            by[who][kind] += 1
        what = "; ".join(f"{who} " + ", ".join(f"{k} x{n}" if n > 1 else k for k, n in kinds.items())
                         for who, kinds in by.items())
        out["outbound"] = (f"{ref} {pr['state']} {len(events)} new since my last reply "
                           f"{last_reply:%Y-%m-%dT%H:%MZ}: {what}  {url}")
    if pr["state"] != "OPEN":
        return out
    head = pr["headRefOid"]
    for who, r in sorted(hub.standing_reviews(pr["reviews"]["nodes"]).items()):
        if r["state"] != "APPROVED":
            continue
        oid = (r.get("commit") or {}).get("oid")
        if oid != head:
            at = oid[:7] if oid else "a commit no longer on the branch"
            out["drift"].append(f"{ref} {who} approved at {at}; head is {head[:7]}  {url}")
    if not events:
        verdict, names = ci_of(pr)
        ci = verdict + (f" ({', '.join(names)})" if names else "")
        req = requested_of(pr)
        waits = "draft (yours)" if pr["isDraft"] else ("requested " + ",".join(req) if req else "nobody requested")
        out["awaiting"] = (f"{ref} waits-on={waits} decision={pr.get('reviewDecision') or 'NONE'} ci={ci} "
                           f"merge={pr.get('mergeStateStatus')}  {url}")
    return out


def ci_of(pr: dict) -> tuple[str, list[str]]:
    rollup = ((pr["commits"]["nodes"] or [{}])[0].get("commit") or {}).get("statusCheckRollup") or {}
    ctx = rollup.get("contexts") or {"nodes": [], "pageInfo": {}}
    if ctx["pageInfo"].get("hasNextPage"):
        return "unknown", ["over 100 checks"]
    return hub.ci_summary(ctx["nodes"])


def requested_of(pr: dict) -> list[str]:
    return [x.get("login") or x.get("slug") or "?" for x in
            ((n.get("requestedReviewer") or {}) for n in pr["reviewRequests"]["nodes"])]


def my_last_review(pr: dict, me: str) -> dict | None:
    mine = sorted((r for r in pr["reviews"]["nodes"] if hub.is_me(r.get("author"), me) and r.get("state") != "PENDING"),
                  key=lambda r: r.get("submittedAt") or "")
    return mine[-1] if mine else None


def watched_row(ref: str, pr: dict, me: str, requested: bool, updated: str) -> str | None:
    """The WATCHED line for a PR by a watched author, or None when it is a draft
    or I already reviewed its current head."""
    if pr["isDraft"]:
        return None
    head = pr["headRefOid"]
    mine = sorted((r for r in pr["reviews"]["nodes"] if hub.is_me(r.get("author"), me) and r.get("state") != "PENDING"),
                  key=lambda r: r.get("submittedAt") or "")
    if any(((r.get("commit") or {}).get("oid")) == head for r in mine):
        return None
    last = mine[-1] if mine else None
    seen = f"{last['state']}@{((last.get('commit') or {}).get('oid') or '?')[:7]}" if last else "none"
    return (f"{ref} by {hub.login(pr.get('author')) or '?'} requested={'yes' if requested else 'no'} head={head[:7]} "
            f"my-review={seen} updated {updated[:10]} {pr['title']!r}  {pr['url']}")


def reviewed_row(ref: str, pr: dict, me: str, requested: bool) -> str | None:
    """The REVIEWED line for an open PR, anyone's, whose head moved since my last
    review: a re-look, a delta review of `compare` against my open threads. None
    when it is a draft, I never reviewed it, or my last review is at its head.
    Four PRs once got commits after my reviews and only the closing report noticed."""
    if pr["state"] != "OPEN" or pr["isDraft"]:
        return None
    last = my_last_review(pr, me)
    sha = ((last or {}).get("commit") or {}).get("oid")
    head = pr["headRefOid"]
    if not last or sha == head:
        return None
    return (f"{ref} by {hub.login(pr.get('author')) or '?'} requested={'yes' if requested else 'no'} head={head[:7]} "
            f"my-review={last['state']}@{(sha or '?')[:7]} compare={sha or '?'}...{head} {pr['title']!r}  {pr['url']}")


def pr_facts(ref: str, pr: dict, me: str) -> dict:
    """One PR as prs.json holds it: what the panel's PRS section draws without a token spent."""
    last = my_last_review(pr, me)
    head = pr["headRefOid"]
    standing = hub.standing_reviews(pr["reviews"]["nodes"])
    others = {w: r for w, r in standing.items() if not hub.is_me(r.get("author"), me)}
    return {"ref": ref, "url": pr["url"], "title": pr["title"], "author": hub.login(pr.get("author")) or "?",
            "head": head, "ci": ci_of(pr)[0], "decision": pr.get("reviewDecision"), "merge": pr.get("mergeStateStatus"),
            "my_state": (last or {}).get("state"), "my_sha": ((last or {}).get("commit") or {}).get("oid"),
            "approvals": sorted(w for w, r in others.items() if r["state"] == "APPROVED"
                                and (r.get("commit") or {}).get("oid") == head),
            "changes_requested": sorted(w for w, r in others.items() if r["state"] == "CHANGES_REQUESTED"),
            "unresolved": sum(1 for t in pr["reviewThreads"]["nodes"] if not t.get("isResolved")),
            "requested": requested_of(pr)}


def write_prs(cfg: dict, at: dt.datetime, reviewing: list[dict], authored: list[dict]) -> None:
    """prs.json, whole or not at all: the panel reads it as each turn ends."""
    p = hub.state_dir(cfg) / "prs.json"
    tmp = p.with_name("prs.json.tmp")
    tmp.write_text(json.dumps({"written_at": at.isoformat(), "reviewing": reviewing, "authored": authored}) + "\n")
    os.replace(tmp, p)


def history(cfg: dict, prev: dict | None, reviewing: list[dict], authored: list[dict], details: dict) -> int:
    """Append what changed since the last prs.json to prs-history.jsonl: a review
    or an approval of mine, a PR that merged. The panel's five-day strip counts
    them. The first scan has nothing to compare and writes nothing, so the
    strip starts the day this runs instead of claiming a history it never saw."""
    if prev is None:
        return 0
    path = hub.state_dir(cfg) / "prs-history.jsonl"
    seen = {json.loads(ln).get("key") for ln in path.read_text().splitlines() if ln.strip()} if path.is_file() else set()
    old = {p["ref"]: p for p in prev.get("reviewing", [])}
    today = f"{hub.local_now(cfg):%Y-%m-%d}"
    rows = []
    for p in reviewing:
        o = old.get(p["ref"]) or {}
        if p.get("my_sha") and (o.get("my_state"), o.get("my_sha")) != (p.get("my_state"), p.get("my_sha")):
            event = "approved" if p["my_state"] == "APPROVED" else "reviewed"
            rows.append({"day": today, "ref": p["ref"], "event": event, "key": f"{event}:{p['ref']}:{p['my_sha']}"})
    now_refs = {p["ref"] for p in reviewing + authored}
    for p in prev.get("reviewing", []) + prev.get("authored", []):
        d = details.get(p["ref"])
        if p["ref"] not in now_refs and d and d.get("state") == "MERGED":
            day = hub.parse_time(d.get("mergedAt")) or hub.now()
            rows.append({"day": f"{day.astimezone(hub.zone(cfg)):%Y-%m-%d}", "ref": p["ref"], "event": "merged",
                         "key": f"merged:{p['ref']}"})
    rows = [r for r in rows if r["key"] not in seen]
    if rows:
        with path.open("a") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
    return len(rows)


def read_prs(cfg: dict) -> dict | None:
    try:
        return json.loads((hub.state_dir(cfg) / "prs.json").read_text())
    except (OSError, ValueError):
        return None


# ---- what the scan writes to the log itself ----------------------------------
# Each row carries `key=` in its detail, so a later scan never logs it twice.

def logged_keys(cfg: dict) -> set[str]:
    return {m.group(1) for back in range(hub.OPEN_DAYS)
            for r in hub.day_rows(cfg, hub.local_now(cfg).date() - dt.timedelta(days=back))
            for m in [re.search(r"\bkey=(\S+)", r.get("detail") or "")] if m}


def open_rows(cfg: dict, kind: str) -> list[dict]:
    return [r for r in hub.folded(cfg, hub.OPEN_DAYS) if r["kind"] == kind]


def key_of(row: dict) -> str:
    m = re.search(r"\bkey=(\S+)", row.get("detail") or "")
    return m.group(1) if m else ""


pr_ref = hub.pr_ref


def unregated_posts(cfg: dict, at: dt.datetime) -> list[dict]:
    """Scheduled messages that posted today with no re-gate this morning: the
    machine slept through the ticks between the window's start and post_at, so
    nothing re-checked their claims before they went out."""
    tz = hub.zone(cfg)
    start = dt.datetime.combine(at.astimezone(tz).date(), dt.time.fromisoformat(cfg["active_hours"]["start"]),
                                tzinfo=tz)
    gate = hub.state_dir(cfg) / "gate"
    out = []
    for p in sorted(gate.glob("*.json")) if gate.is_dir() else []:
        s = json.loads(p.read_text())
        if s.get("send") != "schedule" or not s.get("sent_id") or s.get("withdrawn_at") or s.get("regate_of"):
            continue
        post = hub.parse_time(s.get("post_at"))
        # Gated this morning, re-gated, or re-gated and failed (claim_moved_at): each is a check.
        checked = max([dt.datetime.fromtimestamp(s.get("passed_at") or 0, dt.timezone.utc)]
                      + [t for t in (hub.parse_time(s.get("regated_at")), hub.parse_time(s.get("claim_moved_at"))) if t])
        if post and start <= post <= at and checked < start:
            out.append(s)
    return out


# ---- the scan --------------------------------------------------------------

def scan(cfg: dict, gh: hub.Gh, emit=print, wall_limit: float = WALL_LIMIT) -> int:
    wall0 = time.time()
    g = cfg["github"]
    me, owners, authors = g["login"], g["owners"], g["watch_authors"]
    at = hub.now()
    cutoff = at - dt.timedelta(days=int(g["merged_days"]))
    blocked: list[str] = []
    emit(f"comms-hub queue {at:%Y-%m-%dT%H:%MZ} login={me} owners={','.join(owners)} merged_days={g['merged_days']}")
    # How far back the mention searches must reach; the Slack pages are read without `oldest`.
    stamp = hub.state_dir(cfg) / "last-scan"
    try:
        prev = hub.parse_time(stamp.read_text().strip()) if stamp.is_file() else None
    except ValueError:
        prev = None
    emit(f"previous-scan: {prev.isoformat()} epoch={int(prev.timestamp())}" if prev
         else "previous-scan: none (first scan: nothing before this tick was checked)")
    if hub.first_tick_after_quiet(cfg, prev, at):
        emit("morning: first tick since quiet hours ended; what was scheduled has posted, confirm each landed")
    # A scheduled message can be withdrawn only before post_at, so each tick until then re-checks its claims.
    pending = hub.pending_scheduled(cfg)
    emit(f"scheduled-pending: {len(pending)}"
         + (f" ({' '.join(s['sent_id'] for s in pending)}): gate each copy again this tick (check_draft.py --scheduled)"
            if pending else ""))
    stamp.write_text(at.isoformat() + "\n")
    hub.log_event(cfg, "scan", "scan started", detail=f"{at:%Y-%m-%dT%H:%M:%SZ}")
    # Every tick, not only the morning's: that tick can end before it re-gates.
    keys = logged_keys(cfg)
    missed = unregated_posts(cfg, at)
    for s in missed:
        if f"unregated:{s['sent_id']}" not in keys:
            hub.log_event(cfg, "blocked", "posted without the morning re-gate", ref=(s.get("prs") or [""])[0].split(" ")[0],
                          target=s.get("target", ""), needs_user=True, detail=f"key=unregated:{s['sent_id']}")
    emit(f"morning-unchecked: {len(missed)}" + (
        f" ({' '.join(s['sent_id'] for s in missed)}): posted with no re-gate since the window opened; re-check each "
        "claim now and tell the user what moved" if missed else ""))
    # A held draft lives in a file, not in the session's memory, so a compaction cannot lose it.
    held = sorted(p.name for p in (hub.state_dir(cfg) / "held").glob("*.md"))
    emit(f"held-drafts: {len(held)}" + (f" ({' '.join(held)}): gate and send each, or say why it still waits" if held else ""))
    # What a compaction would lose mid-tick: logged by an earlier scan, not yet done.
    todo = open_rows(cfg, "todo")
    emit(f"in-flight: {len(todo)}" + (f" ({' '.join(r['id'] for r in todo)}): left from an earlier tick; finish each, "
                                       "then log the outcome with --corrects ID" if todo else ""))
    # Each with what it is, since the session that logged it may not remember.
    for r in todo:
        emit(f"  {r['id']}  {r['text']}  {r['ref']}")
    # What waits on the user or on a peer stays open across days until a row corrects it.
    needs, routed_ = hub.open_items(cfg)
    emit(f"needs-you: {len(needs)}" + (f" ({' '.join(r['id'] for r in needs)}): carry each in the report until "
                                        "answered, then log the outcome with --corrects ID" if needs else ""))
    emit(f"with-sessions: {len(routed_)}" + (f" ({' '.join(r['id'] for r in routed_)}): when a peer answers, "
                                              "log --kind returned --corrects ID" if routed_ else ""))
    # What the user parked stays out of the status sections and the panel;
    # what asks something new of them still shows.
    parked = hub.parked(cfg)
    emit(f"parked: {len(parked)}" + (f" ({' '.join(sorted(parked))}): left out of REVIEWED, WATCHED, AWAITING, DRIFT "
                                     "and the panel; INBOUND, OUTBOUND and ROUTE still show them" if parked else ""))

    need = 3 + len(authors)
    can_search = False
    try:
        res = gh.json(["api", "rate_limit"])["resources"]
        s, q = res["search"], res["graphql"]
        reset = dt.datetime.fromtimestamp(s["reset"], dt.timezone.utc)
        emit(f"search-quota: {s['remaining']}/{s['limit']} left, need {need}, resets {reset:%H:%M:%SZ}")
        emit(f"graphql-quota: {q['remaining']}/{q['limit']} left")
        can_search = s["remaining"] >= need
        if not can_search:
            blocked.append(f"search quota {s['remaining']} is below the {need} this scan needs; "
                           "a throttled search returns fewer rows, not an error")
        if q["remaining"] < 200:
            blocked.append(f"graphql quota {q['remaining']} is below 200")
    except (hub.GhError, KeyError, TypeError) as e:
        emit("search-quota: unknown")
        blocked.append(f"rate_limit unreadable, so no search was spent: {e}")

    inbound, watched, reviewed, searched_open = [], [], [], None
    if can_search:
        try:
            # review-requested: alone counts a team's requests as mine.
            rows, _ = search(gh, f"is:pr is:open archived:false user-review-requested:{me} draft:false {scope(owners)}")
            inbound = sorted(rows, key=row_ref)
            # Every author, not only watch_authors. A thread reply on my own PR is a
            # review too, hence -author. Bounded by merged_days: a head that moved
            # since my review updated the PR, and each row costs a fetch.
            rows, _ = search(gh, f"is:pr is:open archived:false reviewed-by:{me} -author:{me} "
                                 f"updated:>={cutoff:%Y-%m-%d} {scope(owners)}")
            reviewed = sorted(rows, key=row_ref)
            rows, _ = search(gh, f"is:pr is:open archived:false author:{me} {scope(owners)}")
            searched_open = {row_ref(r) for r in rows}
            where = " ".join(f"repo:{r}" for r in g["watch_repos"]) or scope(owners)
            for a in authors:
                if a.lower() == me.lower():
                    continue
                rows, _ = search(gh, f"is:pr is:open archived:false author:{a} {where}")
                watched += rows
                if rows:
                    continue
                # A zero is an instrument reading until the other instrument agrees.
                by_graph = author_open_graphql(gh, a, owners, g["watch_repos"])
                if by_graph:
                    blocked.append(f"WATCHED: the search found no open PR by {a}, graphql lists "
                                   f"{len(by_graph)}: {' '.join(sorted(by_graph))}")
                else:
                    emit(f"watched-xcheck: {a} has no open PR (search and graphql agree)")
        except (hub.GhError, Blocked) as e:
            blocked.append(str(e))

    try:
        graph_open = my_open_graphql(gh, me, owners)
    except (hub.GhError, Blocked) as e:
        graph_open = None
        blocked.append(f"my open PRs (graphql): {e}")

    if searched_open is not None and graph_open is not None:
        if searched_open == graph_open:
            emit(f"my-open-xcheck: search={len(searched_open)} graphql={len(graph_open)} agree")
        else:
            only_s = sorted(searched_open - graph_open)
            only_g = sorted(graph_open - searched_open)
            emit(f"my-open-xcheck: search={len(searched_open)} graphql={len(graph_open)} DISAGREE"
                 f" only-search={only_s} only-graphql={only_g}")
            blocked.append("my open PRs differ between search and graphql")
    else:
        emit("my-open-xcheck: not run (an instrument failed; see BLOCKED)")

    refs: set[str] = set()
    try:
        refs, pages = my_recent(gh, owners, cutoff)
        emit(f"my-prs: {len(refs)} open or merged since {cutoff:%Y-%m-%d} ({pages} page{'s' if pages > 1 else ''})")
    except (hub.GhError, Blocked) as e:
        blocked.append(f"my recent PRs: {e}")
    below = sorted((graph_open or set()) - refs)
    if below:
        emit(f"my-prs: {len(below)} open but not updated since the cutoff, fetched by number: {' '.join(below)}")
    refs |= set(below)

    watched_items = {row_ref(r): r for r in sorted(watched, key=row_ref)}
    inbound_refs = {row_ref(r) for r in inbound}
    reviewed_refs = {row_ref(r) for r in reviewed}
    # A posted review waits under Needs you until the user approves or it merges:
    # read those PRs too, merged ones included, which no open-PR search returns.
    waiting = [r for r in open_rows(cfg, "reviewed") if r.get("needs_user") and pr_ref(r.get("ref", ""))]
    todo_refs = {key_of(r).split(":", 1)[1].split("@")[0] for r in todo if key_of(r).startswith("review:")}
    # What the last prs.json listed: one that has left every search may have merged.
    prev = read_prs(cfg)
    listed = {p["ref"] for p in (prev or {}).get("reviewing", []) + (prev or {}).get("authored", [])}
    extra = {pr_ref(r["ref"]) for r in waiting} | todo_refs | listed
    outbound, route, awaiting, drift, unknown = [], [], [], [], []
    with cf.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(fetch_pr, gh, ref): ref
                   for ref in sorted(refs | set(watched_items) | inbound_refs | reviewed_refs | extra)}
        details, failed = {}, {}
        for f in cf.as_completed(futures):
            ref = futures[f]
            try:
                details[ref] = f.result()
            except hub.GhError as e:
                failed[ref] = e
    # One wider re-read, alone and with twice the timeout, before a PR is UNKNOWN.
    wider = hub.Gh(runner=gh.runner, timeout=gh.timeout * 2, retries=gh.retries, pause=gh.pause)
    for ref in sorted(failed):
        emit(f"re-read: {ref} failed ({failed[ref]}); once more with a {wider.timeout:g}s timeout")
        try:
            details[ref] = fetch_pr(wider, ref)
        except hub.GhError as e:
            unknown.append(f"{ref} UNKNOWN: {e} (after the wider re-read)")
    for ref in sorted(refs & set(details)):
        rows = classify(ref, details[ref], me)
        if rows["outbound"]:
            outbound.append(rows["outbound"])
        if rows["awaiting"] and ref not in parked:
            awaiting.append(rows["awaiting"])
        route += rows["route"]
        drift += [] if ref in parked else rows["drift"]
    if unknown:
        blocked.append(f"{len(unknown)} PR(s) could not be read")

    # A PR in REVIEWED is a re-look, whether or not it was requested again or
    # its author is watched: one row, there.
    reviewed_rows = {}
    for ref in sorted((reviewed_refs | inbound_refs | set(watched_items)) - set(parked)):
        row = reviewed_row(ref, details[ref], me, ref in inbound_refs) if ref in details else None
        if row:
            reviewed_rows[ref] = row
    watched_rows = []
    for ref, r in watched_items.items():
        if ref in details and ref not in reviewed_rows and ref not in parked:
            row = watched_row(ref, details[ref], me, ref in inbound_refs, r["updated_at"])
            if row:
                watched_rows.append(row)
    sections = [
        ("INBOUND", [f"{row_ref(r)} by {r['user']['login']} updated {r['updated_at'][:10]} {r['title']!r}  {r['html_url']}"
                     for r in inbound if row_ref(r) not in reviewed_rows]),
        ("REVIEWED", list(reviewed_rows.values())),
        ("WATCHED", watched_rows),
        ("AWAITING", awaiting),
        ("OUTBOUND", outbound),
        ("ROUTE", [f"{r['ref']} {r['who']} {r['what']} [{r['ask']}]: {r['text']!r}  {r['url']}" for r in route]),
        ("DRIFT", drift),
        ("UNKNOWN", sorted(unknown)),
    ]
    # The watchdog polls on monotonic sleep, so a scan that wakes after its last
    # gh call could finish before it looks: check the wall clock here too.
    if time.time() - wall0 > wall_limit:
        blocked.append(f"the scan took more than {wall_limit:g}s of wall-clock time (the machine slept?); "
                       "what it read may be stale")
    remember(cfg, emit, details, me, route, inbound_refs - set(reviewed_rows), reviewed_rows, todo, waiting)
    if blocked:
        emit("prs: not written (BLOCKED); the panel keeps the last scan's, with its age")
    else:
        mine = sorted(r for r in refs - set(parked) if r in details and details[r]["state"] == "OPEN")
        theirs = sorted(r for r in (inbound_refs | reviewed_refs | set(watched_items)) - set(parked)
                        if r in details and details[r]["state"] == "OPEN" and not details[r]["isDraft"]
                        and not hub.is_me(details[r].get("author"), me)
                        and (r in inbound_refs or my_last_review(details[r], me)))
        reviewing = [{**pr_facts(r, details[r], me), "requested_me": r in inbound_refs} for r in theirs]
        authored = [pr_facts(r, details[r], me) for r in mine]
        changed = history(cfg, prev, reviewing, authored, details)
        write_prs(cfg, at, reviewing, authored)
        emit(f"prs: wrote {len(theirs)} reviewing, {len(mine)} authored; {changed} new in the history")
    for name, rows in sections:
        emit(f"== {name} ({len(rows)}) ==")
        for row in rows:
            emit(row)
    if blocked:
        for b in blocked:
            emit(f"BLOCKED: {b}")
        emit("BLOCKED: the queue is unknown, not empty")
        return 3
    emit("OK")
    return 0


def remember(cfg: dict, emit, details: dict, me: str, route: list[dict], to_review: set[str], relook: dict,
             todo: list[dict], waiting: list[dict]) -> None:
    """Write the tick's work to the log before the session starts it, so a
    compaction mid-tick resumes from disk (one once rebuilt the PR state and
    lost an ask), and close what GitHub shows is done."""
    keys, new, closed = logged_keys(cfg), [], []
    route_keys = set()
    for r in route:
        key = f"route:{r['ref']}:{r['who']}@{r['at']}"
        route_keys.add(key)
        if key not in keys:
            new.append(hub.log_event(cfg, "todo", f"route {r['who']}'s {r['ask']}", ref=r["url"], who=r["who"],
                                     detail=f"key={key}"))
    for ref in sorted(to_review | set(relook)):
        if ref not in details:
            continue
        key = f"review:{ref}@{details[ref]['headRefOid'][:7]}"
        if key not in keys:
            new.append(hub.log_event(cfg, "todo", "re-look: new commits" if ref in relook else "review requested",
                                     ref=details[ref]["url"], detail=f"key={key}"))
    for r in todo:
        key = key_of(r)
        ref = key.split(":", 1)[1].split("@")[0].rsplit(":", 1)[0] if ":" in key else ""
        pr = details.get(ref)
        if not pr:
            continue  # unread: unknown, so left open
        if pr["state"] != "OPEN":
            why = f"{pr['state'].lower()} before it was done"
        elif key.startswith("review:") and ((my_last_review(pr, me) or {}).get("commit") or {}).get("oid") == pr["headRefOid"]:
            why = "review posted at the head"
        elif key.startswith("route:") and key not in route_keys:
            why = "answered on the PR"
        else:
            continue
        closed.append(hub.log_event(cfg, "done", why, ref=pr["url"], corrects=r["id"]))
    for r in waiting:
        pr = details.get(pr_ref(r["ref"]))
        if not pr:
            continue
        mine = hub.standing_reviews(pr["reviews"]["nodes"])
        mine = next((v for w, v in mine.items() if hub.is_me(v.get("author"), me)), None)
        sha = (re.search(r"\bsha=([0-9a-f]{40})\b", r.get("detail") or "") or [None, None])[1]
        decided = (mine or {}).get("state") in ("APPROVED", "CHANGES_REQUESTED")
        if pr["state"] != "OPEN" or decided:
            why = (pr["state"].lower() if pr["state"] != "OPEN"
                   else "you approved" if mine["state"] == "APPROVED" else "you requested changes")
            closed.append(hub.log_event(cfg, "answered", why, ref=r["ref"], corrects=r["id"]))
        elif sha and sha != pr["headRefOid"] and not r["text"].startswith("re-look"):
            closed.append(hub.log_event(cfg, "reviewed", "re-look: new commits since the review", ref=r["ref"],
                                        needs_user=True, corrects=r["id"], detail=f"sha={sha}"))
    emit(f"logged: {len(new)} in-flight" + (f" ({' '.join(x['id'] for x in new)})" if new else "")
         + f", {len(closed)} closed" + (f" ({' '.join(x['corrects'] for x in closed)})" if closed else ""))


def main(argv=None, gh=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=["scan"])
    ap.add_argument("--wall-limit", type=float, default=WALL_LIMIT)
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    try:
        cfg = hub.load_config(args.config)
    except hub.ConfigError as e:
        print(f"config: {e}")
        return 2
    pidfile = hub.state_dir(cfg) / "queue.pid"
    killed = kill_previous(pidfile)
    if killed:
        print(killed)
    pidfile.write_text(f"{os.getpid()} {hub.now().isoformat()}\n")

    def drop_pidfile():
        try:
            if pidfile.read_text().split()[0] == str(os.getpid()):
                pidfile.unlink()
        except (OSError, IndexError):
            pass

    watchdog(args.wall_limit, on_fire=drop_pidfile)
    try:
        return scan(cfg, gh or hub.Gh(), wall_limit=args.wall_limit)
    finally:
        drop_pidfile()


if __name__ == "__main__":
    sys.exit(main())
