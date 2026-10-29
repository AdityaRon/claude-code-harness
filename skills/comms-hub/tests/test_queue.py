r"""queue.py: the two instruments, the search quota, paging, UNKNOWN, review and
activity state, the watchdog, the previous scan.

Mutations (run.py --mutate applies each and expects this file to fail):
  open-items-unsaid: queue.py: `needs, routed_ = hub.open_items(cfg)` => `needs, routed_ = [], []`
  xcheck-ignored: queue.py: `blocked.append("my open PRs differ between search and graphql")` => `pass`
  short-search-ok: queue.py: `if len(items) != total:` => `if False:`
  incomplete-ok: queue.py: `if d.get("incomplete_results"):` => `if False:`
  quota-unchecked: queue.py: `can_search = s["remaining"] >= need` => `can_search = True`
  page-everything: queue.py: `if not page["pageInfo"]["hasNextPage"] or not nodes or hub.parse_time(nodes[-1]["updatedAt"]) < cutoff:` => `if not page["pageInfo"]["hasNextPage"] or not nodes:`
  below-cutoff-dropped: queue.py: `refs |= set(below)` => `pass`
  merged-window-ignored: queue.py: `if n["state"] == "OPEN" or (merged and merged >= cutoff):` => `if True:`
  unknown-not-blocking: queue.py: `blocked.append(f"{len(unknown)} PR(s) could not be read")` => `pass`
  latest-reviews: queue.py: `for who, r in sorted(hub.standing_reviews(pr["reviews"]["nodes"]).items()):` => `for who, r in sorted(hub.standing_reviews(pr["latestReviews"]["nodes"]).items()):`
  drift-ignored: queue.py: `if oid != head:` => `if False:`
  bots-count: queue.py: `return not hub.is_me(actor, me) and not hub.is_bot(actor)` => `return not hub.is_me(actor, me)`
  deleted-dropped: queue.py: `return not hub.is_me(actor, me) and not hub.is_bot(actor)` => `return hub.login(actor) is not None and not hub.is_me(actor, me) and not hub.is_bot(actor)`
  case-sensitive-me: hub.py: `return (login(actor) or "").lower() == me.lower()` => `return login(actor) == me`
  archived-counted: queue.py: `if n["repository"].get("isArchived"):  # search's archived:false drops it too` => `if False:`
  old-activity-counts: queue.py: `events = sorted((e for e in events if e[0] > last_reply), key=lambda e: e[:3])` => `events = sorted(events, key=lambda e: e[:3])`
  no-previous-scan: queue.py: `stamp.write_text(at.isoformat() + "\n")` => `pass`
  main-thread-wall: queue.py: `if time.time() - wall0 > wall_limit:` => `if False:`
  monotonic-watchdog: queue.py: `clock = time.time` => `clock = time.monotonic`
  watchdog-no-exit: queue.py: `exit_fn(3)` => `pass`
  kill-nothing: queue.py: `if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):` => `if True:`
  kill-anything: queue.py: `if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):` => `if False:`
  kill-an-editor: queue.py: `if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):` => `if "queue.py" not in cmd:`
  stdlib-queue-unbound: hub.py: `import queue  # noqa: F401` => `pass`
  team-requests-inbound: queue.py: `user-review-requested:{me} draft:false` => `review-requested:{me} draft:false`
  draft-requests-inbound: queue.py: `user-review-requested:{me} draft:false` => `user-review-requested:{me}`
  empty-approval-owed: queue.py: `if r["state"] in ("APPROVED", "DISMISSED") and acknowledgement(r.get("body") or ""):` => `if False:`
  lgtm-owed: queue.py: `if r["state"] in ("APPROVED", "DISMISSED") and acknowledgement(r.get("body") or ""):` => `if r["state"] in ("APPROVED", "DISMISSED") and not (r.get("body") or "").strip():`
  ask-tag-ignored: queue.py: `m = TAG.search(body)` => `m = None`
  url-question: queue.py: `prose = re.sub(r"https?://\S+", " ", prose)` => `pass`
  code-question: queue.py: `prose = re.sub(r"`[^`\n]*`", " ", prose)` => `pass`
  quote-question: queue.py: `prose = re.sub(r"(?m)^\s*>.*$", " ", prose)` => `pass`
  route-unlisted: queue.py: `out["route"].append(` => `out["route"].count(`
  changes-requested-silent: queue.py: `ask = ask_kind(body) or ("blocking" if kind == "review CHANGES_REQUESTED" else "")` => `ask = ask_kind(body)`
  reviewed-search-dropped: queue.py: `reviewed = sorted(rows, key=row_ref)` => `reviewed = []`
  reviewed-own-prs: queue.py: `reviewed-by:{me} -author:{me} ` => `reviewed-by:{me} `
  reviewed-unbounded: queue.py: `f"updated:>={cutoff:%Y-%m-%d} {scope(owners)}")` => `f"{scope(owners)}")`
  relook-at-head: queue.py: `if not last or sha == head:` => `if not last:`
  watched-wins: queue.py: `if ref in details and ref not in reviewed_rows and ref not in parked:` => `if ref in details and ref not in parked:`
  inbound-wins: queue.py: `for r in inbound if row_ref(r) not in reviewed_rows]),` => `for r in inbound]),`
  need-unchanged: queue.py: `need = 3 + len(authors)` => `need = 2 + len(authors)`
  route-todo-relogged: queue.py: `key = f"route:{r['ref']}:{r['who']}@{r['at']}"` => `key = f"route:{r['ref']}:{r['who']}@{r['at']}:{len(keys)}"`
  review-todo-relogged: queue.py: `key = f"review:{ref}@{details[ref]['headRefOid'][:7]}"` => `key = f"review:{ref}@{details[ref]['headRefOid'][:7]}:{len(keys)}"`
  logged-keys-folded: queue.py: `for r in hub.day_rows(cfg, hub.local_now(cfg).date() - dt.timedelta(days=back))` => `for r in (hub.folded(cfg, hub.OPEN_DAYS) if back == 0 else [])`
  logged-keys-today-only: queue.py: `for back in range(hub.OPEN_DAYS)` => `for back in range(1)`
  parked-reviewed-shown: queue.py: `for ref in sorted((reviewed_refs | inbound_refs | set(watched_items)) - set(parked)):` => `for ref in sorted(reviewed_refs | inbound_refs | set(watched_items)):`
  parked-watched-shown: queue.py: `if ref in details and ref not in reviewed_rows and ref not in parked:` => `if ref in details and ref not in reviewed_rows:`
  parked-awaiting-shown: queue.py: `if rows["awaiting"] and ref not in parked:` => `if rows["awaiting"]:`
  parked-drift-shown: queue.py: `drift += [] if ref in parked else rows["drift"]` => `drift += rows["drift"]`
  parked-mine-in-panel: queue.py: `mine = sorted(r for r in refs - set(parked) if` => `mine = sorted(r for r in refs if`
  parked-theirs-in-panel: queue.py: `theirs = sorted(r for r in (inbound_refs | reviewed_refs | set(watched_items)) - set(parked)` => `theirs = sorted(r for r in (inbound_refs | reviewed_refs | set(watched_items))`
  parked-unsaid: queue.py: `emit(f"parked: {len(parked)}" + (` => `(lambda *a: None)(f"parked: {len(parked)}" + (`
  in-flight-unnamed: queue.py: `emit(f"  {r['id']}  {r['text']}  {r['ref']}")` => `pass`
  todo-never-closed: queue.py: `closed.append(hub.log_event(cfg, "done", why, ref=pr["url"], corrects=r["id"]))` => `pass`
  route-todo-closed-early: queue.py: `elif key.startswith("route:") and key not in route_keys:` => `elif key.startswith("route:"):`
  unregated-ignored: queue.py: `if f"unregated:{s['sent_id']}" not in keys:` => `if False:`
  unregated-twice: queue.py: `if f"unregated:{s['sent_id']}" not in keys:` => `if True:`
  regate-fail-unchecked: queue.py: `(hub.parse_time(s.get("regated_at")), hub.parse_time(s.get("claim_moved_at")))` => `(hub.parse_time(s.get("regated_at")),)`
  morning-gate-unchecked: queue.py: `checked = max([dt.datetime.fromtimestamp(s.get("passed_at") or 0, dt.timezone.utc)]` => `checked = max([dt.datetime.fromtimestamp(0, dt.timezone.utc)]`
  relook-never: queue.py: `elif sha and sha != pr["headRefOid"] and not r["text"].startswith("re-look"):` => `elif False:`
  approval-never-closes: queue.py: `decided = (mine or {}).get("state") in ("APPROVED", "CHANGES_REQUESTED")` => `decided = False`
  merge-never-closes: queue.py: `if pr["state"] != "OPEN" or decided:` => `if decided:`
  prs-written-blocked: queue.py: `emit("prs: not written (BLOCKED); the panel keeps the last scan's, with its age")
    else:` => `pass
    if True:`
  prs-watched-unreviewed: queue.py: `and (r in inbound_refs or my_last_review(details[r], me)))` => `)`
  history-merge-missed: queue.py: `if p["ref"] not in now_refs and d and d.get("state") == "MERGED":` => `if False:`
  merge-unfetched: queue.py: `extra = {pr_ref(r["ref"]) for r in waiting} | todo_refs | listed` => `extra = {pr_ref(r["ref"]) for r in waiting} | todo_refs`
  history-review-missed: queue.py: `if p.get("my_sha") and (o.get("my_state"), o.get("my_sha")) != (p.get("my_state"), p.get("my_sha")):` => `if False:`
  watched-draft-listed: queue.py: `if pr["isDraft"]:` => `if False:`
  watched-reviewed-listed: queue.py: `if any(((r.get("commit") or {}).get("oid")) == head for r in mine):` => `if False:`
  watched-zero-trusted: queue.py: `if by_graph:` => `if False:`
  held-uncounted: queue.py: `held = sorted(p.name for p in (hub.state_dir(cfg) / "held").glob("*.md"))` => `held = []`
  comments-one-page: queue.py: `while info.get("hasNextPage"):` => `while False:`
  thread-comments-one-page: queue.py: `t["comments"]["nodes"] = page_all(` => `t["comments"]["nodes"] = t["comments"]["nodes"] or page_all(`
  no-wider-reread: queue.py: `details[ref] = fetch_pr(wider, ref)` => `raise hub.GhError("no re-read")`
  reread-not-wider: queue.py: `timeout=gh.timeout * 2` => `timeout=gh.timeout`
  pending-uncounted: queue.py: `pending = hub.pending_scheduled(cfg)` => `pending = []`
  posted-still-pending: hub.py: `if parse_time(s.get("post_at")) <= now_:` => `if False:`
"""
import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

from fakes import BIN, CONFIG, ME, Env, Fail, FakeGh, actor, page

import hub

# By path: `import queue` is the stdlib's, which hub binds before this directory can shadow it.
_spec = importlib.util.spec_from_file_location("comms_queue", BIN / "queue.py")
q = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(q)

NOW = "2026-10-21T17:00:00+00:00"
RECENT, OLD = "2026-10-20T10:00:00Z", "2026-10-01T10:00:00Z"


def item(n, author, repo="acme/app", draft=False):
    return {"number": n, "repository_url": f"https://api.github.com/repos/{repo}", "title": f"pr {n}", "draft": draft,
            "user": {"login": author}, "updated_at": RECENT, "html_url": f"https://github.com/{repo}/pull/{n}"}


def node(n, state="OPEN", updated=RECENT, merged=None, repo="acme/app", archived=False):
    return {"number": n, "state": state, "updatedAt": updated, "mergedAt": merged,
            "repository": {"nameWithOwner": repo, "isArchived": archived, "owner": {"login": repo.split("/")[0]}}}


def ev(name, at, bot=False):
    return {"author": actor(name, bot=bot), "createdAt": at}


def rv(name, state, at, oid="h2", body="a word"):
    return {"author": actor(name), "state": state, "submittedAt": at, "commit": {"oid": oid} if oid else None,
            "body": body}


def detail(n, state="OPEN", head="h2", reviews=(), comments=(), threads=(), checks=(), requests=(), draft=False,
           decision=None, author=ME, more_comments=False, more_thread=False):
    return {"number": n, "url": f"https://github.com/acme/app/pull/{n}", "title": f"pr {n}", "state": state,
            "isDraft": draft, "createdAt": OLD, "mergedAt": None, "headRefOid": head, "mergeStateStatus": "CLEAN",
            "reviewDecision": decision, "author": actor(author),
            "reviewRequests": {"nodes": [{"requestedReviewer": {"__typename": "User", "login": r}} for r in requests]},
            "reviews": page(list(reviews)), "latestReviews": {"nodes": []},
            "comments": page(list(comments), more=more_comments),
            "reviewThreads": page([{"id": f"t{n}-{i}", "comments": page(list(t), more=more_thread)}
                                   for i, t in enumerate(threads)]),
            "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {"contexts": page(list(checks))}}}]}}


SUCCESS = {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
           "startedAt": RECENT}

DETAILS = {
    1: detail(1, requests=["bob"], checks=[SUCCESS]),
    2: detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z"), ev("bob", "2026-10-20T09:00:00Z")]),
    3: detail(3, reviews=[rv("bob", "APPROVED", "2026-10-18T10:00:00Z", oid="h1"),
                          rv("bob", "COMMENTED", "2026-10-18T11:00:00Z", oid="h2")],
              comments=[ev(ME, "2026-10-19T10:00:00Z")]),
    4: detail(4, state="MERGED", comments=[ev(ME, "2026-10-17T10:00:00Z"), ev("carol", "2026-10-18T10:00:00Z")]),
    5: detail(5, draft=True),
    # teammate's: 9 requested of me, 10 reviewed at an older head, 13 a draft, 14 reviewed at its head
    9: detail(9, author="teammate", requests=[ME]),
    10: detail(10, author="teammate", reviews=[rv(ME, "COMMENTED", OLD, oid="h1")]),
    13: detail(13, author="teammate", draft=True),
    14: detail(14, author="teammate", reviews=[rv(ME, "COMMENTED", RECENT, oid="h2")]),
}
WATCHED = [9, 10, 13, 14]


def fake(**over):
    mine_open = over.get("mine_open", [1, 2, 3, 5])
    searched = over.get("searched", mine_open)

    def search(query, pg):
        query = query.lower()  # GitHub matches qualifiers case-insensitively
        if "review-requested:" in query:
            rows = [item(9, "teammate")]
            if "user-review-requested:" not in query:
                rows.append(item(11, "teammate"))  # requested of a team I am on
            if "draft:false" not in query:
                rows.append(item(12, "teammate", draft=True))
        elif "reviewed-by:" in query:
            rows = [item(n, a) for n, a in over.get("reviewed", [])]
        elif f"author:{ME}" in query:
            rows = [item(n, ME) for n in searched]
        else:
            rows = [item(n, "teammate") for n in over.get("watched", WATCHED)]
        total = over.get("total", len(rows)) if f"author:{ME}" in query and "reviewed-by:" not in query else len(rows)
        return {"total_count": total, "incomplete_results": over.get("incomplete", False),
                "items": rows if pg == 1 else []}

    def pr(v):
        d = over.get("details", DETAILS).get(v["number"])
        if isinstance(d, list):  # one answer per call: a gh that fails, then answers
            d = d.pop(0)
        return d if isinstance(d, Fail) else {"repository": {"pullRequest": d}}

    second = {"pageInfo": {"hasNextPage": False}, "nodes": [ev("bob", "2026-10-20T10:00:00Z")]}

    return FakeGh(
        graphql={
            "CommsMyOpen": {"viewer": {"login": ME, "pullRequests": page(
                [node(n) for n in mine_open] + [node(n, repo="acme/old", archived=True) for n in over.get("archived", [])])}},
            "CommsMine": over.get("mine_pages", [{"viewer": {"pullRequests": page(
                [node(1), node(2), node(3), node(4, state="MERGED", merged=RECENT),
                 node(6, state="MERGED", updated="2026-10-13T10:00:00Z", merged="2026-10-13T09:00:00Z")])}}]),
            "CommsPR": pr,
            "CommsComments": {"repository": {"pullRequest": {"comments": second}}},
            "CommsThreadComments": {"node": {"comments": second}},
            "CommsAuthorOpen":{"user": {"pullRequests": page(
                [{"number": n, "isDraft": False, "repository": {"nameWithOwner": "acme/app", "isArchived": False,
                                                                 "owner": {"login": "acme"}}}
                 for n in over.get("author_open", [])])}},
        },
        rest={"rate_limit": {"resources": {"search": {"limit": 30, "remaining": over.get("quota", 30),
                                                      "reset": 1792600000},
                                           "graphql": {"limit": 5000, "remaining": 4900, "reset": 1792600000}}},
              "search": search})


def scan(gh, config=None):
    out = []
    with Env(now=NOW, **({"config": config} if config else {})):
        rc = q.scan(hub.load_config(), hub.Gh(runner=gh, pause=0), emit=out.append)
    return rc, "\n".join(out)


def section(out, name):
    lines = out.splitlines()
    i = next(k for k, l in enumerate(lines) if l.startswith(f"== {name} "))
    rows = []
    for l in lines[i + 1:]:
        if l.startswith("== ") or l.startswith("BLOCKED") or l == "OK":
            break
        rows.append(l)
    return rows


class Scan(unittest.TestCase):
    def test_clean_scan(self):
        rc, out = scan(fake())
        self.assertEqual(rc, 0, out)
        self.assertIn("search-quota: 30/30 left, need 4", out)
        self.assertIn("my-open-xcheck: search=4 graphql=4 agree", out)
        self.assertEqual([r.split()[0] for r in section(out, "INBOUND")], ["acme/app#9"])
        self.assertEqual([r.split()[:4] for r in section(out, "WATCHED")],
                         [["acme/app#9", "by", "teammate", "requested=yes"]])
        self.assertEqual(section(out, "REVIEWED"),
                         ["acme/app#10 by teammate requested=no head=h2 my-review=COMMENTED@h1 compare=h1...h2 'pr 10'  "
                          "https://github.com/acme/app/pull/10"], "reviewed at h1, head h2: a re-look, not WATCHED")
        awaiting = section(out, "AWAITING")
        self.assertIn("acme/app#1 waits-on=requested bob decision=NONE ci=green", awaiting[0])
        self.assertTrue(any(r.startswith("acme/app#5 waits-on=draft (yours)") for r in awaiting), awaiting)
        outbound = section(out, "OUTBOUND")
        self.assertEqual([r.split()[:2] for r in outbound], [["acme/app#2", "OPEN"], ["acme/app#4", "MERGED"]])
        self.assertIn("bob comment", outbound[0])
        self.assertEqual(section(out, "DRIFT"), ["acme/app#3 bob approved at h1; head is h2  "
                                                  "https://github.com/acme/app/pull/3"])
        self.assertNotIn("acme/app#6", out, "merged before the cutoff")
        self.assertTrue(out.endswith("OK"))

    def test_inbound_is_what_was_asked_of_me_personally_and_not_a_draft(self):
        gh = fake()
        rc, out = scan(gh)
        self.assertEqual(rc, 0, out)
        q = next(" ".join(c) for c in gh.calls if "review-requested:" in " ".join(c))
        self.assertIn(f"user-review-requested:{ME} draft:false", q)
        self.assertEqual([r.split()[0] for r in section(out, "INBOUND")], ["acme/app#9"],
                         "a team's request (#11) and a draft (#12) are not mine to review")

    def test_watched_skips_drafts_and_prs_reviewed_at_their_head(self):
        rc, out = scan(fake())
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.split()[0] for r in section(out, "WATCHED")], ["acme/app#9"])
        self.assertEqual([r.split()[0] for r in section(out, "REVIEWED")], ["acme/app#10"])
        self.assertNotIn("acme/app#13", out, "a draft")
        self.assertNotIn("acme/app#14", out, "reviewed at h2, its head")

    def test_a_watched_author_the_search_finds_nothing_for_is_checked_by_graphql(self):
        rc, out = scan(fake(watched=[]))
        self.assertEqual(rc, 0, out)
        self.assertIn("watched-xcheck: teammate has no open PR (search and graphql agree)", out)
        self.assertEqual(section(out, "WATCHED"), [])
        rc, out = scan(fake(watched=[], author_open=[15]))
        self.assertEqual(rc, 3, out)
        self.assertIn("BLOCKED: WATCHED: the search found no open PR by teammate, graphql lists 1: acme/app#15", out)

    def test_an_empty_approval_or_dismissal_is_not_owed_a_reply(self):
        after = "2026-10-20T10:00:00Z"
        quiet = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z")],
                       reviews=[rv("bob", "APPROVED", after, body=""), rv("carol", "DISMISSED", after, body=" ")])
        rc, out = scan(fake(details={**DETAILS, 2: quiet}))
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.split()[0] for r in section(out, "OUTBOUND")], ["acme/app#4"])
        self.assertNotIn("acme/app#2", "".join(section(out, "DRIFT")), "approved at the head: no drift")
        worded = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z")], reviews=[rv("bob", "APPROVED", after, body="one nit")])
        self.assertIn("bob review APPROVED", section(scan(fake(details={**DETAILS, 2: worded}))[1], "OUTBOUND")[0])
        inline = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z")], reviews=[rv("bob", "APPROVED", after, body="")],
                        threads=[[ev("bob", after)], [ev("bob", after)], [ev("bob", after)]])
        row = section(scan(fake(details={**DETAILS, 2: inline}))[1], "OUTBOUND")[0]
        self.assertIn("bob thread comment x3", row, "the empty approval's inline comments are still owed")
        self.assertNotIn("review APPROVED", row)

    def test_instruments_disagree(self):
        rc, out = scan(fake(searched=[1, 2, 3]))
        self.assertEqual(rc, 3)
        self.assertIn("DISAGREE only-search=[] only-graphql=['acme/app#5']", out)

    def test_short_or_incomplete_search_blocks(self):
        rc, out = scan(fake(total=5))
        self.assertEqual(rc, 3)
        self.assertIn("returned 4 of 5 rows", out)
        rc, out = scan(fake(incomplete=True))
        self.assertEqual(rc, 3)
        self.assertIn("incomplete", out)

    def test_low_quota_blocks_before_spending(self):
        gh = fake(quota=2)
        rc, out = scan(gh)
        self.assertEqual(rc, 3)
        self.assertIn("search quota 2 is below the 4", out)
        self.assertEqual(gh.count("search/issues"), 0)
        self.assertIn("BLOCKED: the queue is unknown, not empty", out)

    def test_paging_stops_at_the_cutoff(self):
        pages = [{"viewer": {"pullRequests": page([node(1), node(2)], more=True)}},
                 {"viewer": {"pullRequests": page([node(3), node(7, state="MERGED", updated="2026-10-10T00:00:00Z",
                                                                merged="2026-10-10T00:00:00Z")], more=True)}}]
        gh = fake(mine_pages=pages, mine_open=[1, 2, 3])
        rc, out = scan(gh)
        self.assertEqual(rc, 0, out)
        self.assertEqual(gh.count("CommsMine"), 2)
        self.assertIn("(2 pages)", out)

    def test_open_pr_below_the_cutoff_is_fetched_by_number(self):
        rc, out = scan(fake(mine_open=[1, 2, 3, 5, 8], details={**DETAILS, 8: detail(8)}))
        self.assertEqual(rc, 0, out)
        self.assertIn("fetched by number: acme/app#5 acme/app#8", out)
        self.assertTrue(any(r.startswith("acme/app#8 ") for r in section(out, "AWAITING")))

    def test_an_unreadable_pr_is_unknown_and_blocks(self):
        rc, out = scan(fake(details={**DETAILS, 2: Fail()}))
        self.assertEqual(rc, 3)
        self.assertEqual([r.split()[:2] for r in section(out, "UNKNOWN")], [["acme/app#2", "UNKNOWN:"]])
        self.assertIn("(after the wider re-read)", section(out, "UNKNOWN")[0])
        self.assertTrue(section(out, "AWAITING"), "the rest is still listed")

    def test_a_second_page_of_comments_or_thread_comments_is_read(self):
        quiet = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z")], more_comments=True)
        gh = fake(details={**DETAILS, 2: quiet})
        rc, out = scan(gh)
        self.assertEqual(rc, 0, out)
        self.assertIn("bob comment", section(out, "OUTBOUND")[0], "bob's comment is on the second page")
        self.assertEqual(gh.count("CommsComments"), 1)
        threaded = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z")], threads=[[ev(ME, "2026-10-18T10:00:00Z")]],
                          more_thread=True)
        rc, out = scan(fake(details={**DETAILS, 2: threaded}))
        self.assertIn("bob thread comment", section(out, "OUTBOUND")[0], "on the thread's second page")

    def test_a_failed_fetch_is_re_read_wider_before_it_is_unknown(self):
        rc, out = scan(fake(details={**DETAILS, 2: [Fail(), Fail(), DETAILS[2]]}))
        self.assertEqual(rc, 0, out)
        self.assertIn("re-read: acme/app#2 failed (gh api graphql: HTTP 502 (tried 2x)); once more with a 90s timeout", out)
        self.assertEqual(section(out, "UNKNOWN"), [])
        self.assertEqual([r.split()[0] for r in section(out, "OUTBOUND")], ["acme/app#2", "acme/app#4"])

    def test_bot_and_older_activity_are_not_outbound(self):
        d = detail(2, comments=[ev("bob", "2026-10-18T10:00:00Z"), ev(ME, "2026-10-19T10:00:00Z"),
                                ev("ci[bot]", "2026-10-20T10:00:00Z", bot=True)])
        rc, out = scan(fake(details={**DETAILS, 2: d}))
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.split()[0] for r in section(out, "OUTBOUND")], ["acme/app#4"])

    def test_thread_comment_and_review_after_my_reply_are_outbound(self):
        d = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z")],
                   threads=[[ev(ME, "2026-10-18T10:00:00Z"), ev("bob", "2026-10-20T10:00:00Z")]],
                   reviews=[rv("bob", "CHANGES_REQUESTED", "2026-10-20T10:00:00Z")])
        rc, out = scan(fake(details={**DETAILS, 2: d}))
        row = section(out, "OUTBOUND")[0]
        self.assertIn("2 new since my last reply", row)
        self.assertIn("review CHANGES_REQUESTED", row)

    def test_drift_from_reviews_when_latest_reviews_is_empty(self):
        rc, out = scan(fake())
        self.assertTrue(section(out, "DRIFT"), "latestReviews is [] in every fixture; reviews carries the approval")

    def test_approval_on_a_commit_gone_from_the_branch(self):
        d = detail(3, reviews=[rv("bob", "APPROVED", "2026-10-18T10:00:00Z", oid=None)],
                   comments=[ev(ME, "2026-10-19T10:00:00Z")])
        rc, out = scan(fake(details={**DETAILS, 3: d}))
        self.assertIn("bob approved at a commit no longer on the branch", out)

    def test_a_config_login_in_another_case_is_still_me(self):
        rc, out = scan(fake(), config=CONFIG.replace(f'login = "{ME}"', f'login = "{ME.upper()}"'))
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.split()[0] for r in section(out, "OUTBOUND")], ["acme/app#2", "acme/app#4"])
        self.assertNotIn(f"{ME} comment", out)

    def test_a_deleted_accounts_comment_is_activity(self):
        d = detail(2, comments=[ev(ME, "2026-10-19T10:00:00Z"), {"author": None, "createdAt": "2026-10-20T10:00:00Z"}])
        rc, out = scan(fake(details={**DETAILS, 2: d}))
        self.assertIn("a deleted account comment", section(out, "OUTBOUND")[0])

    def test_an_open_pr_in_an_archived_repo_does_not_split_the_instruments(self):
        rc, out = scan(fake(archived=[11]))
        self.assertEqual(rc, 0, out)
        self.assertIn("my-open-xcheck: search=4 graphql=4 agree", out)

    def test_previous_scan_is_recorded_for_the_mention_searches(self):
        with Env(now=NOW) as env:
            outs = []
            for _ in range(2):
                out = []
                q.scan(hub.load_config(), hub.Gh(runner=fake(), pause=0), emit=out.append)
                outs.append("\n".join(out))
            log = "".join(p.read_text() for p in (env.state / "log").glob("*.md"))
        self.assertIn("previous-scan: none", outs[0])
        self.assertIn("previous-scan: 2026-10-21T17:00:00+00:00 epoch=1792602000", outs[1])
        self.assertEqual(log.count("scan started"), 2)
        self.assertNotIn("morning:", outs[1])

    def test_held_drafts_on_disk_are_counted(self):
        with Env(now=NOW) as env:
            (env.state / "held").mkdir(parents=True)
            (env.state / "held" / "app-session-1761040800.000100.md").write_text("comms-hub draft\n")
            out = []
            q.scan(hub.load_config(), hub.Gh(runner=fake(), pause=0), emit=out.append)
        self.assertIn("held-drafts: 1 (app-session-1761040800.000100.md): gate and send each, or say why it still waits",
                      out)
        self.assertIn("held-drafts: 0", scan(fake())[1])

    def test_what_waits_on_the_user_or_a_peer_is_counted_every_tick(self):
        with Env(now=NOW) as env:
            cfg = hub.load_config()
            hub.log_event(cfg, "asked", "may bob drop the tables?", needs_user=True)
            hub.log_event(cfg, "routed", "acme/app#12 conflicts", who="app-session")
            out = []
            q.scan(cfg, hub.Gh(runner=fake(), pause=0), emit=out.append)
        self.assertIn("needs-you: 1 (1021.1): carry each in the report until answered, then log the outcome with "
                      "--corrects ID", out)
        self.assertIn("with-sessions: 1 (1021.2): when a peer answers, log --kind returned --corrects ID", out)
        self.assertIn("needs-you: 0", scan(fake())[1])

    def test_the_first_scan_after_quiet_hours_says_morning(self):
        with Env(now=NOW) as env:
            env.state.mkdir(parents=True)
            (env.state / "last-scan").write_text("2026-10-21T03:00:00+00:00\n")  # 20:00 the evening before
            out = []
            q.scan(hub.load_config(), hub.Gh(runner=fake(), pause=0), emit=out.append)
        self.assertIn("morning: first tick since quiet hours ended; what was scheduled has posted, confirm each landed", out)

    def test_scheduled_messages_still_ahead_are_counted_every_tick(self):
        stamp = {"send": "schedule", "sent_id": "Q0001", "post_at": "2026-10-22T08:30:00-07:00", "target": "top-level",
                 "sha256": "0" * 64, "passed_at": 0}
        with Env(now=NOW) as env:  # 10:00 on the 21st there; Q0001 posts the next morning
            (env.state / "gate").mkdir(parents=True)
            (env.state / "gate" / "a.json").write_text(json.dumps(stamp))
            (env.state / "gate" / "b.json").write_text(json.dumps({**stamp, "sent_id": "Q0000", "post_at": "2026-10-21T08:00:00-07:00"}))
            out = []
            q.scan(hub.load_config(), hub.Gh(runner=fake(), pause=0), emit=out.append)
        self.assertIn("scheduled-pending: 1 (Q0001): gate each copy again this tick (check_draft.py --scheduled)", out)
        self.assertIn("scheduled-pending: 0", scan(fake())[1])

    def test_a_scan_that_outlived_the_wall_limit_is_blocked_even_unwatched(self):
        base = time.time()
        ticks = iter([base] + [base + 1000] * 1000)
        with mock.patch("time.time", lambda: next(ticks)):
            rc, out = scan(fake())
        self.assertEqual(rc, 3, out)
        self.assertIn("wall-clock time", out)


MINE_AT = "2026-10-19T10:00:00Z"
AFTER = "2026-10-20T10:00:00Z"


def body_ev(name, at, body, bot=False):
    return {**ev(name, at, bot=bot), "body": body}


def scans(gh_fn, n=1, before=None):
    """n scans in one state dir; `before(cfg, state)` seeds it first. Returns outputs, state dir rows and prs.json."""
    outs = []
    with Env(now=NOW) as env:
        cfg = hub.load_config()
        env.state.mkdir(parents=True, exist_ok=True)
        if before:
            before(cfg, env.state)
        for i in range(n):
            out = []
            q.scan(cfg, hub.Gh(runner=gh_fn(i), pause=0), emit=out.append)
            outs.append("\n".join(out))
        rows = [r for p in sorted((env.state / "log").glob("*.jsonl")) for r in map(json.loads, p.read_text().splitlines())]
        prs = json.loads((env.state / "prs.json").read_text()) if (env.state / "prs.json").is_file() else None
        hist = (env.state / "prs-history.jsonl").read_text() if (env.state / "prs-history.jsonl").is_file() else ""
    return outs, rows, prs, hist


class Asks(unittest.TestCase):
    """Item 2: an approval that carries an ask was logged as status and routed nothing."""

    def test_what_asks_and_what_does_not(self):
        for text, want in (("[consider] cache the token", "consider"), ("**[Question]** is this safe", "question"),
                           ("[blocking] drops rows", "blocking"), ("why sleep a second here?", "question"),
                           ("see https://ci.example/run?id=4 for the log", ""), ("`a ? b : c` reads fine", ""),
                           ("> did you test it?\nyes, on staging", ""), ("```\nx = y ? 1 : 2\n```", ""),
                           ("one nit: a typo in the log line", ""), ("", "")):
            self.assertEqual(q.ask_kind(text), want, text)
        for text in ("", "LGTM", "Looks good, thanks!", "lgtm 👍", "Approved.", ":shipit:"):
            self.assertTrue(q.acknowledgement(text), text)
        for text in ("one nit", "LGTM but why the sleep?", "LGTM [consider] a constant"):
            self.assertFalse(q.acknowledgement(text), text)

    def test_an_approval_with_a_consider_routes_and_an_lgtm_does_not(self):
        d = detail(2, comments=[ev(ME, MINE_AT)], reviews=[rv("bob", "APPROVED", AFTER, body="[consider] name the constant")])
        rc, out = scan(fake(details={**DETAILS, 2: d}))
        self.assertEqual(rc, 0, out)
        self.assertEqual(section(out, "ROUTE"), ["acme/app#2 bob review APPROVED [consider]: '[consider] name the constant'"
                                                 "  https://github.com/acme/app/pull/2"])
        self.assertIn("bob review APPROVED", section(out, "OUTBOUND")[0])
        bare = detail(2, comments=[ev(ME, MINE_AT)], reviews=[rv("bob", "APPROVED", AFTER, body="LGTM, thanks!")])
        rc, out = scan(fake(details={**DETAILS, 2: bare}))
        self.assertEqual(section(out, "ROUTE"), [])
        self.assertEqual([r.split()[0] for r in section(out, "OUTBOUND")], ["acme/app#4"], "an LGTM owes no reply")

    def test_inline_questions_and_changes_requested_route_and_a_bots_question_does_not(self):
        d = detail(2, comments=[ev(ME, MINE_AT), body_ev("ci[bot]", AFTER, "rerun?", bot=True)],
                   reviews=[rv("carol", "CHANGES_REQUESTED", AFTER, body="see inline")],
                   threads=[[body_ev("bob", AFTER, "does this hold on retry?")]])
        rc, out = scan(fake(details={**DETAILS, 2: d}))
        self.assertEqual([r.split("]")[0] for r in section(out, "ROUTE")],
                         ["acme/app#2 bob thread comment [question", "acme/app#2 carol review CHANGES_REQUESTED [blocking"])


class Reviewed(unittest.TestCase):
    """Item 9: commits after my review waited for the author to come back."""

    def test_anyones_pr_whose_head_moved_since_my_review_is_a_relook(self):
        moved = detail(20, author="stranger", reviews=[rv(ME, "COMMENTED", OLD, oid="h1")])
        same = detail(21, author="stranger", reviews=[rv(ME, "COMMENTED", RECENT, oid="h2")])
        rc, out = scan(fake(details={**DETAILS, 20: moved, 21: same}, reviewed=[(20, "stranger"), (21, "stranger")]))
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.split()[0] for r in section(out, "REVIEWED")], ["acme/app#10", "acme/app#20"])
        self.assertIn("compare=h1...h2", section(out, "REVIEWED")[1])
        self.assertNotIn("acme/app#21", out, "reviewed at its head")

    def test_a_re_request_after_my_review_is_a_relook_not_inbound(self):
        again = detail(9, author="teammate", requests=[ME], reviews=[rv(ME, "COMMENTED", OLD, oid="h1")])
        rc, out = scan(fake(details={**DETAILS, 9: again}))
        self.assertEqual(section(out, "INBOUND"), [])
        self.assertTrue(section(out, "REVIEWED")[-1].startswith("acme/app#9 by teammate requested=yes"), out)

    def test_the_search_reaches_every_author_within_merged_days(self):
        gh = fake()
        scan(gh)
        q_ = next(" ".join(c) for c in gh.calls if "reviewed-by:" in " ".join(c))
        self.assertIn(f"reviewed-by:{ME} -author:{ME} updated:>=2026-10-14", q_)


class InFlight(unittest.TestCase):
    """Item 3: a compaction between the scan and routing lost an ask."""

    def ask(self):
        return detail(2, comments=[ev(ME, MINE_AT)], reviews=[rv("bob", "APPROVED", AFTER, body="[question] safe on retry")])

    def test_work_is_logged_once_before_it_starts(self):
        outs, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 2: self.ask()}), n=2)
        todo = [r for r in rows if r["kind"] == "todo"]
        self.assertEqual(sorted((r["text"], q.pr_ref(r["ref"])) for r in todo),
                         [("re-look: new commits", "acme/app#10"), ("review requested", "acme/app#9"),
                          ("route bob's question", "acme/app#2")])
        self.assertIn("logged: 3 in-flight", outs[0])
        self.assertIn("logged: 0 in-flight", outs[1], "a second scan with nothing new adds no row")
        self.assertIn(f"in-flight: 3 ({' '.join(sorted(r['id'] for r in todo))})", outs[1])
        ask = next(r for r in todo if r["text"].startswith("route"))
        self.assertIn(f"\n  {ask['id']}  route bob's question  https://github.com/acme/app/pull/2\n", outs[1],
                      "after a compaction an id alone says nothing")
        self.assertEqual([r for r in rows if r["kind"] == "done"], [], "the ask is still open, so its todo is too")

    def test_a_routed_ask_is_not_logged_again(self):
        def gh(i):
            if i == 1:  # the session routes the ask between the two scans
                cfg = hub.load_config()
                todo = next(r for r in q.open_rows(cfg, "todo") if r["text"].startswith("route"))
                hub.log_event(cfg, "routed", "routed to app-session", ref=todo["ref"], who="app-session",
                              corrects=todo["id"])
            return fake(details={**DETAILS, 2: self.ask()})
        outs, rows, _, _ = scans(gh, n=2)
        self.assertIn("logged: 0 in-flight", outs[1], "the ask is still in ROUTE until answered, and already logged")
        self.assertEqual(sum(r["kind"] == "todo" and r["text"].startswith("route") for r in rows), 1)
        self.assertNotIn("route bob's question", outs[1].split("== INBOUND")[0], "routed, so not in flight")

    def test_a_todo_logged_yesterday_is_not_logged_again(self):
        def seed(cfg, state):
            hub.log_event(cfg, "todo", "route bob's question", ref="https://github.com/acme/app/pull/2", who="bob",
                          detail="key=route:acme/app#2:bob@20261020T100000")
            today = hub.local_now(cfg).date()
            (state / "log" / f"{today:%Y-%m-%d}.jsonl").rename(
                state / "log" / f"{today - hub.dt.timedelta(days=1):%Y-%m-%d}.jsonl")
        outs, _, _, _ = scans(lambda i: fake(details={**DETAILS, 2: self.ask()}), before=seed)
        self.assertIn("logged: 2 in-flight", outs[0], "the two reviews; the ask was logged yesterday")

    def test_github_closes_what_is_done(self):
        replied = detail(2, comments=[ev(ME, MINE_AT), ev(ME, "2026-10-21T09:00:00Z")],
                         reviews=[rv("bob", "APPROVED", AFTER, body="[question] safe on retry")])
        reviewed9 = detail(9, author="teammate", requests=[ME], reviews=[rv(ME, "COMMENTED", NOW, oid="h2")])
        states = [{**DETAILS, 2: self.ask()}, {**DETAILS, 2: replied, 9: reviewed9}]
        outs, rows, _, _ = scans(lambda i: fake(details=states[i]), n=2)
        done = [r for r in rows if r["kind"] == "done"]
        self.assertEqual(sorted(r["text"] for r in done), ["answered on the PR", "review posted at the head"])
        self.assertIn("2 closed", outs[1])


class Parked(unittest.TestCase):
    """PRs the user parked: a local filter run after each scan let them flash back in between."""

    def test_a_parked_pr_leaves_the_status_sections_and_the_panel_but_not_the_asks(self):
        def seed(cfg, state):
            (state / "parked.json").write_text(json.dumps({r: {"at": "2026-10-21T16:00:00+00:00", "why": "not mine"}
                                                           for r in ("acme/app#10", "acme/app#3", "acme/app#2", "acme/app#9")}))
        outs, rows, prs, _ = scans(lambda i: fake(details={**DETAILS, 2: InFlight().ask()}), before=seed)
        out = outs[0]
        self.assertIn("parked: 4 (acme/app#10 acme/app#2 acme/app#3 acme/app#9): left out of", out)
        for name in ("REVIEWED", "WATCHED", "DRIFT"):
            self.assertEqual(section(out, name), [], name)
        self.assertEqual([r.split()[0] for r in section(out, "AWAITING")], ["acme/app#1", "acme/app#5"])
        self.assertEqual([r.split()[0] for r in section(out, "INBOUND")], ["acme/app#9"], "a new ask still shows")
        self.assertIn("acme/app#2", " ".join(section(out, "ROUTE")))
        self.assertIn("acme/app#2", " ".join(section(out, "OUTBOUND")))
        self.assertEqual([p["ref"] for p in prs["reviewing"]], ["acme/app#14"])
        self.assertEqual([p["ref"] for p in prs["authored"]], ["acme/app#1", "acme/app#5"])
        self.assertNotIn("re-look: new commits", [r["text"] for r in rows if r["kind"] == "todo"])


class Morning(unittest.TestCase):
    """Item 5: the machine slept, and nothing re-gated the overnight posts before 08:30."""

    def gate(self, **over):
        s = {"send": "schedule", "sent_id": "Q0009", "post_at": "2026-10-21T08:30:00-07:00", "target": "chan-one",
             "prs": ["https://github.com/acme/app/pull/2 OPEN"], "passed_at": 1792540800}  # the evening before
        s.update(over)

        def seed(cfg, state):
            (state / "gate").mkdir()
            (state / "gate" / "q.json").write_text(json.dumps(s))
        return seed

    def test_a_post_with_no_morning_check_needs_the_user_once(self):
        outs, rows, _, _ = scans(lambda i: fake(), n=2, before=self.gate())
        blocked = [r for r in rows if r["kind"] == "blocked"]
        self.assertEqual([(r["text"], r["needs_user"]) for r in blocked], [("posted without the morning re-gate", True)])
        self.assertIn("morning-unchecked: 1 (Q0009)", outs[0])

    def test_a_morning_regate_pass_or_fail_is_a_check(self):
        for over in ({"regated_at": "2026-10-21T08:10:00-07:00"}, {"claim_moved_at": "2026-10-21T08:10:00-07:00"},
                     {"passed_at": 1792602000 - 3600}, {"withdrawn_at": "2026-10-21T08:12:00-07:00"}):
            _, rows, _, _ = scans(lambda i: fake(), before=self.gate(**over))
            self.assertEqual([r for r in rows if r["kind"] == "blocked"], [], over)


class ReviewRows(unittest.TestCase):
    """Item 1: a posted review waits under Needs you until the user decides; a moved head demotes it."""

    def seed(self, cfg, state):
        hub.log_event(cfg, "reviewed", "approvable", ref="https://github.com/acme/app/pull/20", needs_user=True,
                      detail="sha=" + "1" * 40)

    def test_a_moved_head_turns_approvable_into_a_relook(self):
        d = detail(20, author="stranger", head="2" * 40, reviews=[rv(ME, "COMMENTED", OLD, oid="1" * 40)])
        _, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 20: d}), before=self.seed)
        self.assertEqual([r["text"] for r in rows if r["kind"] == "reviewed"],
                         ["approvable", "re-look: new commits since the review"])

    def test_the_users_approval_or_a_merge_closes_it(self):
        for d, why in ((detail(20, author="stranger", head="1" * 40, reviews=[rv(ME, "APPROVED", RECENT, oid="1" * 40)]),
                        "you approved"), (detail(20, author="stranger", state="MERGED", head="1" * 40), "merged")):
            _, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 20: d}), before=self.seed)
            self.assertEqual([(r["kind"], r["text"]) for r in rows if r["corrects"]], [("answered", why)])


class PrsFile(unittest.TestCase):
    """Item 8: the panel's PRS section reads prs.json; a BLOCKED scan leaves the last one."""

    def test_a_clean_scan_writes_it_and_a_blocked_one_does_not(self):
        # #15: a watched author's PR I neither reviewed nor was asked on is not mine to track.
        _, _, prs, _ = scans(lambda i: fake(watched=WATCHED + [15], details={**DETAILS, 15: detail(15, author="teammate")}))
        self.assertEqual([p["ref"] for p in prs["authored"]], ["acme/app#1", "acme/app#2", "acme/app#3", "acme/app#5"])
        self.assertEqual([(p["ref"], p["requested_me"], p["my_sha"]) for p in prs["reviewing"]],
                         [("acme/app#10", False, "h1"), ("acme/app#14", False, "h2"), ("acme/app#9", True, None)],
                         "my review or a request to me; #13, a draft, is left out")
        self.assertEqual(prs["written_at"], NOW)
        outs, _, prs, _ = scans(lambda i: fake(quota=30 if i == 0 else 2), n=2)
        self.assertEqual(len(prs["reviewing"]), 3, "the first scan's file stays; a blocked one searched nothing")
        self.assertIn("prs: not written (BLOCKED)", outs[1])

    def test_the_history_counts_my_reviews_and_merges_from_the_second_scan(self):
        relooked = detail(10, author="teammate", reviews=[rv(ME, "COMMENTED", OLD, oid="h1"), rv(ME, "COMMENTED", NOW, oid="h2")])
        open22 = detail(22, author="stranger", reviews=[rv(ME, "COMMENTED", OLD, oid="h2")])
        merged22 = {**detail(22, author="stranger", state="MERGED"), "mergedAt": "2026-10-21T16:00:00Z"}
        states = [{**DETAILS, 22: open22}, {**DETAILS, 10: relooked, 22: merged22}]
        # #22 leaves every search once it merges: only the last prs.json still names it.
        searches = [{"reviewed": [(22, "stranger")]}, {}]
        outs, _, _, hist = scans(lambda i: fake(details=states[i], **searches[i]), n=2)
        self.assertIn("0 new in the history", outs[0], "the first scan has nothing to compare")
        self.assertEqual(sorted((r["event"], r["ref"], r["day"]) for r in map(json.loads, hist.splitlines())),
                         [("merged", "acme/app#22", "2026-10-21"), ("reviewed", "acme/app#10", "2026-10-21")])


class Watchdog(unittest.TestCase):
    def test_wall_clock_jump_fires_it(self):
        fired = threading.Event()
        base = time.time()
        seen = []

        def wall():
            seen.append(1)
            return base if len(seen) == 1 else base + 1000  # the machine slept

        with mock.patch("time.time", wall), contextlib.redirect_stdout(io.StringIO()):
            q.watchdog(330, poll=0.01, exit_fn=lambda rc: fired.set())
            self.assertTrue(fired.wait(2), "a scan that slept past the limit must end BLOCKED")

    def test_quiet_scan_is_left_alone(self):
        fired = threading.Event()
        q.watchdog(330, poll=0.01, exit_fn=lambda rc: fired.set())
        self.assertFalse(fired.wait(0.2))

    def test_a_hung_gh_ends_blocked(self):
        with Env() as env:
            t0 = time.time()
            p = run_script(env, "sleep 5", "--wall-limit", "1")
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn("wall-clock limit", p.stdout)
            self.assertLess(time.time() - t0, 4.5)
            self.assertFalse((env.state / "queue.pid").exists())


def run_script(env, gh_body, *argv):
    """queue.py as the tick runs it, with a fake gh first on PATH."""
    fakebin = env.dir / "bin"
    fakebin.mkdir(exist_ok=True)
    gh = fakebin / "gh"
    gh.write_text(f"#!/bin/sh\n{gh_body}\n")
    gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
    environ = dict(os.environ, PATH=f"{fakebin}{os.pathsep}{os.environ['PATH']}",
                   COMMS_HUB_WATCHDOG_POLL="0.1", COMMS_HUB_GH_RETRY_PAUSE="0", PYTHONDONTWRITEBYTECODE="1")
    return subprocess.run([sys.executable, "-B", str(BIN / "queue.py"), "scan", *argv],
                          env=environ, capture_output=True, text=True, timeout=30)


class AsAScript(unittest.TestCase):
    def test_runs_past_the_fetch_pool_with_the_stdlib_queue(self):
        with Env() as env:
            p = run_script(env, "echo 'HTTP 502' >&2; exit 1")
            self.assertNotIn("Traceback", p.stderr)
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn("== UNKNOWN (0) ==", p.stdout)
            self.assertIn("BLOCKED: the queue is unknown, not empty", p.stdout)


class PreviousScan(unittest.TestCase):
    def spawn(self, *argv):
        p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", *argv])
        self.addCleanup(lambda: (p.kill(), p.wait()))
        return p

    def test_a_running_scan_is_killed(self):
        p = self.spawn(str(BIN / "queue.py"), "scan")
        time.sleep(0.2)
        with Env() as env:
            env.state.mkdir(parents=True)
            pidfile = env.state / "queue.pid"
            pidfile.write_text(f"{p.pid} 2026-10-21T10:00:00Z\n")
            self.assertIn(f"pid {p.pid}", q.kill_previous(pidfile) or "")
        self.assertIsNotNone(p.wait(timeout=5))

    def test_an_editor_on_the_script_is_left_alone(self):
        p = self.spawn(str(BIN / "queue.py"))
        time.sleep(0.2)
        with Env() as env:
            env.state.mkdir(parents=True)
            pidfile = env.state / "queue.pid"
            pidfile.write_text(f"{p.pid} 2026-10-21T10:00:00Z\n")
            self.assertIsNone(q.kill_previous(pidfile))
        self.assertIsNone(p.poll())


if __name__ == "__main__":
    unittest.main()
