#!/usr/bin/env python3
"""The GitHub side of a comms tick.

  queue.py scan [--wall-limit S]

Sections: INBOUND (review requested from me personally, not through a team,
drafts left out), WATCHED (open PRs by watched authors that I have not reviewed
at their current head, requested or not, drafts left out), AWAITING (my open
PRs with nothing new from anyone), OUTBOUND (activity on my PRs, open or merged
within merged_days, newer than my last reply; an approval or a dismissal with
no body is not activity I owe a reply), DRIFT (an approval pinned to an older
head), UNKNOWN (a PR that could not be read). The header prints search-quota,
my-open-xcheck and, for a watched author the search finds nothing for, whether
graphql agrees.

A scan that prints BLOCKED (exit 3) means the queue is unknown, not empty.
A scan still running from an earlier tick is killed first.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import os
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
  comments(first:100){pageInfo{hasNextPage endCursor} nodes{author{login __typename} createdAt}}
  reviewThreads(first:100){pageInfo{hasNextPage} nodes{id
   comments(first:50){pageInfo{hasNextPage endCursor} nodes{author{login __typename} createdAt}}}}
  commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100){pageInfo{hasNextPage}
   nodes{__typename ... on CheckRun{name status conclusion startedAt completedAt}
   ... on StatusContext{context state createdAt}}}}}}}}}}"""


COMMENTS = """query CommsComments($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){
 pullRequest(number:$number){comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor}
  nodes{author{login __typename} createdAt}}}}}"""

THREAD_COMMENTS = """query CommsThreadComments($id:ID!,$cursor:String){node(id:$id){... on PullRequestReviewThread{
 comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{author{login __typename} createdAt}}}}}"""


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


def classify(ref: str, pr: dict, me: str) -> dict:
    """The rows this PR contributes: outbound, awaiting, drift."""
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
        """An approval or a dismissal with no body asks nothing; its inline comments are thread comments."""
        if r["state"] in ("APPROVED", "DISMISSED") and not (r.get("body") or "").strip():
            return False
        return theirs(r.get("author"))

    events = ([(t(c["createdAt"]), who(c.get("author")), "comment") for c in comments if theirs(c.get("author"))]
              + [(t(c["createdAt"]), who(c.get("author")), "thread comment") for c in thread_comments
                 if theirs(c.get("author"))]
              + [(t(r["submittedAt"]), who(r.get("author")), f"review {r['state']}") for r in reviews if owed(r)])
    events = sorted(e for e in events if e[0] > last_reply)
    out = {"outbound": None, "awaiting": None, "drift": []}
    url = pr["url"]
    if events:
        by: dict[str, dict[str, int]] = {}
        for _, who, kind in events:
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
        rollup = ((pr["commits"]["nodes"] or [{}])[0].get("commit") or {}).get("statusCheckRollup") or {}
        ctx = rollup.get("contexts") or {"nodes": [], "pageInfo": {}}
        if ctx["pageInfo"].get("hasNextPage"):
            ci = "unknown (over 100 checks)"
        else:
            verdict, names = hub.ci_summary(ctx["nodes"])
            ci = verdict + (f" ({', '.join(names)})" if names else "")
        req = [x.get("login") or x.get("slug") or "?" for x in
               ((n.get("requestedReviewer") or {}) for n in pr["reviewRequests"]["nodes"])]
        waits = "draft (yours)" if pr["isDraft"] else ("requested " + ",".join(req) if req else "nobody requested")
        out["awaiting"] = (f"{ref} waits-on={waits} decision={pr.get('reviewDecision') or 'NONE'} ci={ci} "
                           f"merge={pr.get('mergeStateStatus')}  {url}")
    return out


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
    hub.append_log(cfg, f"scan started {at:%Y-%m-%dT%H:%M:%SZ}")
    # A held draft lives in a file, not in the session's memory, so a compaction cannot lose it.
    held = sorted(p.name for p in (hub.state_dir(cfg) / "held").glob("*.md"))
    emit(f"held-drafts: {len(held)}" + (f" ({' '.join(held)}): gate and send each, or say why it still waits" if held else ""))

    need = 2 + len(authors)
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

    inbound, watched, searched_open = [], [], None
    if can_search:
        try:
            # review-requested: alone counts a team's requests as mine.
            rows, _ = search(gh, f"is:pr is:open archived:false user-review-requested:{me} draft:false {scope(owners)}")
            inbound = sorted(rows, key=row_ref)
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
    outbound, awaiting, drift, unknown = [], [], [], []
    with cf.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(fetch_pr, gh, ref): ref for ref in sorted(refs | set(watched_items))}
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
        if rows["awaiting"]:
            awaiting.append(rows["awaiting"])
        drift += rows["drift"]
    if unknown:
        blocked.append(f"{len(unknown)} PR(s) could not be read")

    inbound_refs = {row_ref(r) for r in inbound}
    watched_rows = []
    for ref, r in watched_items.items():
        if ref in details:
            row = watched_row(ref, details[ref], me, ref in inbound_refs, r["updated_at"])
            if row:
                watched_rows.append(row)
    sections = [
        ("INBOUND", [f"{row_ref(r)} by {r['user']['login']} updated {r['updated_at'][:10]} {r['title']!r}  {r['html_url']}"
                     for r in inbound]),
        ("WATCHED", watched_rows),
        ("AWAITING", awaiting),
        ("OUTBOUND", outbound),
        ("DRIFT", drift),
        ("UNKNOWN", sorted(unknown)),
    ]
    for name, rows in sections:
        emit(f"== {name} ({len(rows)}) ==")
        for row in rows:
            emit(row)
    # The watchdog polls on monotonic sleep, so a scan that wakes after its last
    # gh call could finish before it looks: check the wall clock here too.
    if time.time() - wall0 > wall_limit:
        blocked.append(f"the scan took more than {wall_limit:g}s of wall-clock time (the machine slept?); "
                       "what it read may be stale")
    if blocked:
        for b in blocked:
            emit(f"BLOCKED: {b}")
        emit("BLOCKED: the queue is unknown, not empty")
        return 3
    emit("OK")
    return 0


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
