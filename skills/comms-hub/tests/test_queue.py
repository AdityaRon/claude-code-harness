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
  no-previous-scan: queue.py: `hub.write_whole(stamp, at.isoformat() + "\n")` => `pass`
  gate-prune-unsaid: queue.py: `    if pruned:
        emit(f"gate-pruned:` => `    if False:
        emit(f"gate-pruned:`
  gate-unpruned: queue.py: `pruned = hub.prune_gate(cfg)` => `pruned = 0`
  check-stops-scans: queue.py: `if args.command == "check":` => `if False:`
  check-in-quiet-hours: queue.py: `if hub.window(cfg, at)[1]:` => `if False:`
  check-partial-pages-read: queue.py: `if not pr or pr["reviews"]["pageInfo"]["hasNextPage"] or pr["reviewThreads"]["pageInfo"]["hasNextPage"]:` => `if not pr:`
  check-gone-kept: queue.py: `out[ref] = {"gone": why} if pr["state"] != "OPEN" else` => `out[ref] = {"gone": why} if False else`
  check-unanswered: queue.py: `{"facts": pr_facts(ref, pr, me), "answered": why}` => `{"facts": pr_facts(ref, pr, me), "answered": ""}`
  check-of-unset: queue.py: `json.dumps({"checked_at": at.isoformat(), "of": data["written_at"], "prs": out})` => `json.dumps({"checked_at": at.isoformat(), "of": "", "prs": out})`
  partial-answer-fails: hub.py: `if isinstance(body, dict) and isinstance(body.get("data"), dict):` => `if p.returncode == 0 and isinstance(body, dict) and isinstance(body.get("data"), dict):`
  main-thread-wall: queue.py: `if time.time() - wall0 > wall_limit:` => `if False:`
  monotonic-watchdog: queue.py: `clock = time.time` => `clock = time.monotonic`
  watchdog-no-exit: queue.py: `exit_fn(3)` => `pass`
  kill-nothing: queue.py: `if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):` => `if True:`
  kill-anything: queue.py: `if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):` => `if False:`
  kill-an-editor: queue.py: `if not ("comms-hub" in cmd and "queue.py" in cmd and " scan" in cmd):` => `if "queue.py" not in cmd:`
  stdlib-queue-unbound: hub.py: `import queue  # noqa: F401` => `pass`
  team-requests-inbound: queue.py: `user-review-requested:{me} draft:false` => `review-requested:{me} draft:false`
  draft-requests-inbound: queue.py: `user-review-requested:{me} draft:false` => `user-review-requested:{me}`
  relook-still-reviewed: queue.py: `if not last or head in (sha, looked):` => `if not last or sha == head:`
  relook-compare-from-review: queue.py: `since = looked if looked and hub.parse_time(mark.get("at")) > hub.parse_time(last.get("submittedAt")) else sha` => `since = sha`
  relook-still-watched: queue.py: ` or (mark or {}).get("sha") == head:` => `:`
  relook-still-inbound: queue.py: `for r in inbound if row_ref(r) not in set(reviewed_rows) | looked]),` => `for r in inbound if row_ref(r) not in reviewed_rows]),`
  relook-todo-again: queue.py: `inbound_refs - set(reviewed_rows) - looked,` => `inbound_refs - set(reviewed_rows),`
  relook-panel-moved: hub.py: `moved = behind and not looked` => `moved = behind`
  relook-head-unchecked: hub.py: `if live.get("state") != "OPEN" or live.get("headRefOid") != sha:` => `if False:`
  relook-unsaid: hub.py: `"re-looked" if looked else ""` => `""`
  relook-todo-open: hub.py: `if r["kind"] == "todo" and key and sha.startswith(key.group(1)):` => `if False:`
  relook-row-unmoved: hub.py: `elif r["kind"] == "reviewed" and r.get("needs_user") and row_sha and row_sha.group(1) != sha:` => `elif False:`
  relook-short-sha: hub.py: `re.fullmatch(r"[0-9a-f]{40}", sha)` => `re.fullmatch(r"[0-9a-f]{7,40}", sha)`
  hand-review-ignored: queue.py: `elif sha and sha != pr["headRefOid"] and posted:` => `elif False:`
  hand-review-any-commit: queue.py: `and (v.get("commit") or {}).get("oid") == pr["headRefOid"] for v in pr["reviews"]["nodes"])` => `for v in pr["reviews"]["nodes"])`
  route-todo-unread: queue.py: `todo_refs = {todo_ref(r) for r in todo} - {""}` => `todo_refs = {todo_ref(r) for r in todo if key_of(r).startswith("review:")}`
  empty-approval-owed: queue.py: `if r["state"] in ("APPROVED", "DISMISSED") and acknowledgement(r.get("body") or ""):` => `if False:`
  lgtm-owed: queue.py: `if r["state"] in ("APPROVED", "DISMISSED") and acknowledgement(r.get("body") or ""):` => `if r["state"] in ("APPROVED", "DISMISSED") and not (r.get("body") or "").strip():`
  ask-tag-ignored: queue.py: `m = TAG.search(body)` => `m = None`
  do-tag-ignored: queue.py: `blocking|do)` => `blocking)`
  url-question: queue.py: `prose = re.sub(r"https?://\S+", " ", prose)` => `pass`
  code-question: queue.py: `prose = re.sub(r"`[^`\n]*`", " ", prose)` => `pass`
  quote-question: queue.py: `prose = re.sub(r"(?m)^\s*>.*$", " ", prose)` => `pass`
  route-unlisted: queue.py: `out["route"].append(` => `out["route"].count(`
  changes-requested-silent: queue.py: `ask = ask_kind(body) or ("blocking" if kind == "review CHANGES_REQUESTED" else "")` => `ask = ask_kind(body)`
  reviewed-search-dropped: queue.py: `reviewed = sorted(rows, key=row_ref)` => `reviewed = []`
  reviewed-own-prs: queue.py: `reviewed-by:{me} -author:{me} ` => `reviewed-by:{me} `
  reviewed-unbounded: queue.py: `f"updated:>={cutoff:%Y-%m-%d} {scope(owners)}")` => `f"{scope(owners)}")`
  relook-at-head: queue.py: `if not last or head in (sha, looked):` => `if not last or head == looked:`
  watched-wins: queue.py: `if ref in details and ref not in reviewed_rows and ref not in parked:` => `if ref in details and ref not in parked:`
  inbound-wins: queue.py: `for r in inbound if row_ref(r) not in set(reviewed_rows) | looked]),` => `for r in inbound if row_ref(r) not in looked]),`
  need-unchanged: queue.py: `need = 3 + len(authors)` => `need = 2 + len(authors)`
  untraced-unlogged: queue.py: `    if untraced:
        hub.log_event(` => `    if False:
        hub.log_event(`
  untraced-unsaid: queue.py: `emit(f"missed-ticks: {len(untraced)}" + (` => `emit("missed-ticks: 0" or (`
  untraced-list-uncut: queue.py: `if len(when) <= 3 else` => `if True else`
  tick-rows-no-trace: hub.py: `if r["kind"] in ("scan", "tick")]` => `if r["kind"] == "scan"]`
  trace-on-the-minute: hub.py: `if not any(t <= r < t + every for r in ran):` => `if not any(t <= r < t + dt.timedelta(minutes=1) for r in ran):`
  full-unrecorded: queue.py: `        hub.record_full(cfg, hub.now())` => `        pass`
  full-recorded-when-blocked: queue.py: `if plan == "full" and blocked:` => `if False:`
  full-recorded-on-quick: queue.py: `elif plan == "full":` => `else:`
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
  approval-never-closes: queue.py: `return DECIDED.get((mine or {}).get("state"), "")` => `return ""`
  merge-never-closes: queue.py: `        return pr["state"].lower()
    mine = next(` => `        pass
    mine = next(`
  prs-written-blocked: queue.py: `emit("prs: not written (BLOCKED); the panel keeps the last scan's, with its age")
    else:` => `pass
    if True:`
  prs-watched-unreviewed: queue.py: `and (r in inbound_refs or my_last_review(details[r], me)))` => `)`
  history-merge-missed: queue.py: `if p["ref"] not in now_refs and d and d.get("state") == "MERGED":` => `if False:`
  merge-unfetched: queue.py: `extra = {pr_ref(r["ref"]) for r in waiting} | todo_refs | listed` => `extra = {pr_ref(r["ref"]) for r in waiting} | todo_refs`
  history-review-missed: queue.py: `if p.get("my_sha") and (o.get("my_state"), o.get("my_sha")) != (p.get("my_state"), p.get("my_sha")):` => `if False:`
  watched-draft-listed: queue.py: `if pr["isDraft"]:` => `if False:`
  watched-reviewed-listed: queue.py: `if any(((r.get("commit") or {}).get("oid")) == head for r in mine) or` => `if False or`
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

    def test_ticks_that_left_no_trace_are_logged_when_the_next_scan_starts(self):
        def scan_at(env):
            out = []
            q.scan(hub.load_config(), hub.Gh(runner=fake(), pause=0), emit=out.append)
            rows = [json.loads(ln) for ln in (env.state / "log" / "2026-10-21.jsonl").read_text().splitlines()]
            return out, [r["text"] for r in rows if r["kind"] == "tick"]

        with Env(now=NOW) as env:  # 10:00 there
            env.state.mkdir(parents=True)
            # A scan by hand at 07:50. The 08:37 tick failed fast, which its row records; this scan is the
            # 09:37 tick, late. The 08:07 and 09:07 ticks left nothing.
            (env.state / "last-scan").write_text("2026-10-21T14:50:00+00:00\n")
            with mock.patch.dict(os.environ, {"COMMS_HUB_NOW": "2026-10-21T15:44:00+00:00"}):
                hub.log_event(hub.load_config(), "tick", "ended: the Slack read timed out")
            out, ticks = scan_at(env)
            self.assertIn("missed-ticks: 2 (08:07, 09:07): no scan or tick row; the machine slept, or the session "
                          "failed before it could act (\"Not logged in\" logs nothing). Logged; say so in the report", out)
            self.assertEqual(ticks, ["ended: the Slack read timed out", "2 ticks left no trace: 08:07, 09:07"])
            out, ticks = scan_at(env)
            self.assertIn("missed-ticks: 0", out, "a second scan finds nothing new")
            self.assertEqual(len(ticks), 2)
        with Env(now=NOW) as env:
            env.state.mkdir(parents=True)
            (env.state / "last-scan").write_text("2026-10-20T15:13:00+00:00\n")  # 08:13 the day before
            out, ticks = scan_at(env)
        self.assertEqual(ticks, ["22 ticks left no trace: Tue 08:37 to 09:07"])

    def test_a_full_scan_records_itself_unless_blocked(self):
        with Env(now=NOW):
            cfg = hub.load_config()
            outs = []
            for quota in (2, 30, 30):
                out = []
                q.scan(cfg, hub.Gh(runner=fake(quota=quota), pause=0), emit=out.append)
                outs.append([ln for ln in out if ln.startswith("full-scan:")])
                if len(outs) == 1:
                    self.assertEqual(hub.scan_plan(cfg, hub.now()), "full")
            self.assertEqual(hub.scan_plan(cfg, hub.now()), "quick", "with no `window --full-done`")
        self.assertEqual(outs, [["full-scan: not recorded (BLOCKED); the next tick scans in full again"],
                                ["full-scan: recorded"], []], "a quick scan records nothing")

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
                           ("[do] rename the flag", "do"), ("**[Do]** drop the retry", "do"),
                           ("[docs] a typo in the readme", ""),
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

    def test_do_items_on_an_approval_route_one_todo_each(self):
        """Four [do] inline items on an approval, none with a '?', went unflagged."""
        items = ("[do] rename the flag", "**[Do]** drop the retry", "[do] log the skip", "[DO] add a test")
        d = detail(2, comments=[ev(ME, MINE_AT)], reviews=[rv("bob", "APPROVED", AFTER, body="")],
                   threads=[[body_ev("bob", AFTER, b)] for b in items])
        outs, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 2: d}), n=2)
        self.assertEqual(section(outs[0], "ROUTE"),
                         [f"acme/app#2 bob thread comment [do]: {b!r}  https://github.com/acme/app/pull/2" for b in items])
        todo = [r["text"] for r in rows if r["kind"] == "todo" and r["text"].startswith("route")]
        self.assertEqual(todo, ["route bob's do"] * 4, "one todo per item, though all four share a second")
        self.assertIn("logged: 0 in-flight", outs[1], "a second scan logs none of them again")

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

    def test_an_ask_on_a_pr_merged_before_the_window_still_closes(self):
        # #6 merged before merged_days, so no search returns it: its ask stayed
        # in flight every tick, unread, and was routed again each time.
        def seed(cfg, state):
            hub.log_event(cfg, "todo", "route bob's question", ref="https://github.com/acme/app/pull/6", who="bob",
                          detail="key=route:acme/app#6:bob@20261012T100000")
        outs, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 6: detail(6, state="MERGED")}), n=2, before=seed)
        self.assertEqual([(r["kind"], r["text"]) for r in rows if r["corrects"]], [("done", "merged before it was done")])
        self.assertNotIn("route bob's question", outs[1].split("== INBOUND")[0])

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


SHA_A, SHA_B = "a" * 40, "b" * 40


class Check(unittest.TestCase):
    """Between ticks an approval or a merge stayed under NEEDS YOU until the next scan."""

    WRITTEN = "2026-10-21T16:44:00+00:00"

    def seed(self, env):
        env.state.mkdir(parents=True, exist_ok=True)
        facts = {"url": "", "title": "t", "author": "teammate", "ci": "green", "decision": None, "merge": "CLEAN",
                 "approvals": [], "changes_requested": [], "unresolved": 0, "requested": []}
        (env.state / "prs.json").write_text(json.dumps({
            "written_at": self.WRITTEN,
            "reviewing": [{**facts, "ref": "acme/app#31", "head": SHA_B, "my_state": "COMMENTED", "my_sha": SHA_A,
                           "requested_me": False}],
            "authored": [{**facts, "ref": "acme/app#40", "head": SHA_B, "my_state": None, "my_sha": None}]}))
        (env.state / "last-scan").write_text(self.WRITTEN + "\n")
        return (env.state / "prs.json").read_bytes()

    @staticmethod
    def gh(body, code=0):
        calls = []

        def run(args, timeout):
            calls.append(list(args))
            return subprocess.CompletedProcess(args, code, json.dumps(body) if body is not None else "",
                                               "gh: Could not resolve to a PullRequest" if code else "")
        return hub.Gh(runner=run, pause=0), calls

    @staticmethod
    def approved():
        return detail(31, author="teammate", head=SHA_B, reviews=[rv(ME, "APPROVED", "2026-10-21T16:50:00Z", oid=SHA_B)])

    def checked(self, gh, now=NOW):
        out = []
        with Env(now=now) as env:
            before = self.seed(env)
            rc = q.check(hub.load_config(), gh, emit=out.append)
            p = env.state / "prs-checked.json"
            rec = json.loads(p.read_text()) if p.is_file() else None
            files = sorted(x.name for x in env.state.iterdir())
            untouched = (env.state / "prs.json").read_bytes() == before \
                and (env.state / "last-scan").read_text() == self.WRITTEN + "\n"
        return rc, out, rec, files, untouched

    def test_one_query_reads_the_listed_prs_and_writes_its_own_file_alone(self):
        gh, calls = self.gh({"data": {"p0": {"pullRequest": self.approved()},
                                      "p1": {"pullRequest": detail(40, state="MERGED")}}})
        rc, out, rec, files, untouched = self.checked(gh)
        self.assertEqual((rc, out), (0, ["check: 2 read, 2 answered or closed"]))
        self.assertEqual(len(calls), 1, "one query for both")
        query = next(a for a in calls[0] if a.startswith("query="))
        self.assertNotIn("acme", query, "owner, name and number go as variables")
        self.assertTrue({"o0=acme", "n0=app", "p0=31", "p1=40"} <= set(calls[0]))
        self.assertEqual((rec["of"], rec["checked_at"]), (self.WRITTEN, NOW))
        self.assertEqual(rec["prs"]["acme/app#40"], {"gone": "merged"})
        mine = rec["prs"]["acme/app#31"]
        self.assertEqual((mine["answered"], mine["facts"]["my_state"], mine["facts"]["my_sha"]), ("you approved", "APPROVED", SHA_B))
        self.assertEqual(files, ["last-scan", "prs-checked.json", "prs.json"], "no log, no pid file, no history")
        self.assertTrue(untouched, "prs.json and last-scan are the scan's")

    def test_a_pr_github_cannot_resolve_stays_as_the_scan_had_it(self):
        gh, _ = self.gh({"data": {"p0": None, "p1": {"pullRequest": detail(40, state="MERGED")}},
                         "errors": [{"type": "NOT_FOUND", "message": "Could not resolve"}]}, code=1)
        rc, out, rec, _, _ = self.checked(gh)
        self.assertEqual((rc, out), (0, ["check: 1 read, 1 answered or closed, 1 unread (acme/app#31)"]))
        self.assertEqual(sorted(rec["prs"]), ["acme/app#40"])

    def test_a_pr_with_more_reviews_than_a_page_is_unread(self):
        many = self.approved()
        many["reviews"]["pageInfo"]["hasNextPage"] = True
        gh, _ = self.gh({"data": {"p0": {"pullRequest": many}, "p1": {"pullRequest": detail(40)}}})
        rc, out, rec, _, _ = self.checked(gh)
        self.assertEqual(out, ["check: 1 read, 0 answered or closed, 1 unread (acme/app#31)"])
        self.assertEqual(rec["prs"]["acme/app#40"]["answered"], "")

    def test_outside_the_window_it_asks_github_nothing(self):
        gh, calls = self.gh({"data": {}})
        rc, out, rec, _, _ = self.checked(gh, now="2026-10-21T03:00:00+00:00")   # 20:00
        self.assertEqual((rc, out, calls, rec), (0, ["check: the window is closed"], [], None))

    def test_github_unread_writes_nothing(self):
        gh, _ = self.gh(None, code=1)
        rc, out, rec, _, _ = self.checked(gh)
        self.assertEqual((rc, rec), (1, None))
        self.assertTrue(out[0].startswith("check: GitHub unread: "), out)

    def test_it_stops_no_scan(self):
        gh, _ = self.gh({"data": {"p0": {"pullRequest": self.approved()}, "p1": {"pullRequest": detail(40)}}})
        with Env(now=NOW) as env:
            self.seed(env)
            (env.state / "queue.pid").write_text("999999 2026-10-21T16:59:00+00:00\n")
            rc = q.main(["check"], gh=gh)
            pid = (env.state / "queue.pid").read_text()
        self.assertEqual((rc, pid), (0, "999999 2026-10-21T16:59:00+00:00\n"))


class GatePruned(unittest.TestCase):
    def test_the_scan_prunes_the_gate_and_says_so(self):
        def seed(cfg, state):
            (state / "gate").mkdir()
            base = hub.parse_time(NOW).timestamp()
            for name, days in (("old", 31), ("older", 40), ("young", 2)):
                p = state / "gate" / f"{name}.json"
                p.write_text(json.dumps({"send": "live"}))
                os.utime(p, (base - days * 86400, base - days * 86400))
        outs, _, _, _ = scans(lambda i: fake(), n=2, before=seed)
        self.assertIn("gate-pruned: 2 records untouched for 30 days", outs[0])
        self.assertNotIn("gate-pruned", outs[1], "nothing left to prune says nothing")


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

    def test_a_review_posted_by_hand_at_the_head_moves_the_row_there(self):
        # Posted outside review_lint.py --post, it left the re-look open for days.
        d = detail(20, author="stranger", head="2" * 40,
                   reviews=[rv(ME, "COMMENTED", OLD, oid="1" * 40), rv(ME, "COMMENTED", RECENT, oid="2" * 40)])
        for text in ("approvable", "re-look: new commits since the review"):
            def seed(cfg, state, text=text):
                hub.log_event(cfg, "reviewed", text, ref="https://github.com/acme/app/pull/20", needs_user=True,
                              detail="sha=" + "1" * 40)
            _, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 20: d}), n=2, before=seed)
            self.assertEqual([(r["text"], r["needs_user"], r["detail"]) for r in rows if r["corrects"]],
                             [("looked again: review at the head", True, "sha=" + "2" * 40)], text)


class Relooked(unittest.TestCase):
    """A re-look done by hand with nothing to post left the PR flagged "new commits"
    and its todo open until a review sat at the head."""

    H1, H2, H3 = "1" * 40, "2" * 40, "3" * 40

    def mark(self, ref, sha, *why, head=None, state="OPEN"):
        """hub.py relooked, against a gh that says the PR is `state` at `head` (sha by default)."""
        gh = FakeGh(rest={"pr view": {"state": state, "headRefOid": head or sha}})
        return hub.main(["relooked", ref, sha, *why], gh=hub.Gh(runner=gh, pause=0))

    def pr(self, head, requests=()):
        return detail(20, author="stranger", head=head, requests=requests,
                      reviews=[rv(ME, "APPROVED", OLD, oid=self.H1)])

    def test_the_head_counts_as_reviewed_until_it_moves(self):
        heads, seen, said = [self.H2, self.H2, self.H3], [], io.StringIO()

        def gh(i):
            cfg = hub.load_config()
            if i == 1:
                with contextlib.redirect_stdout(said):
                    self.assertEqual(self.mark("acme/app#20", self.H2, "nothing", "new"), 0)
                seen.append(hub.prs_panel(cfg, {})["rows"])
            if i == 2:
                seen.append(hub.prs_panel(cfg, {})["rows"])
            return fake(details={**DETAILS, 20: self.pr(heads[i])}, reviewed=[(20, "stranger")])
        outs, rows, _, _ = scans(gh, n=3)
        self.assertTrue(section(outs[0], "REVIEWED")[-1].startswith("acme/app#20"), outs[0])
        todo = next(r for r in rows if r["kind"] == "todo" and q.pr_ref(r["ref"]) == "acme/app#20")
        self.assertIn(f"closed {todo['id']}: the re-look it was waiting on", said.getvalue())
        self.assertEqual([r["text"] for r in rows if r["corrects"] == todo["id"]], ["re-looked by hand"])
        # The panel reads the record at once, before the next scan writes prs.json.
        row = lambda rs: next(r for r in rs if r["key"] == "pr:acme/app#20")  # noqa: E731
        self.assertEqual((row(seen[0])["needs"], row(seen[0])["line"]),
                         (False, "app #20  stranger  approved@1111111 · re-looked · CI none"))
        self.assertFalse(row(seen[1])["needs"])
        self.assertNotIn("acme/app#20", "".join(section(outs[1], "REVIEWED") + section(outs[1], "WATCHED")))
        self.assertIn("logged: 0 in-flight", outs[1])
        # A push after it: a re-look again, from the head looked at.
        self.assertIn(f"my-review=APPROVED@1111111 re-looked@2222222 compare={self.H2}...{self.H3}",
                      section(outs[2], "REVIEWED")[-1])

    def test_a_re_request_still_pending_is_not_inbound_once_relooked(self):
        def seed(cfg, state):
            with contextlib.redirect_stdout(io.StringIO()):
                self.mark("acme/app#9", self.H2)
        d = detail(9, author="teammate", head=self.H2, requests=[ME], reviews=[rv(ME, "COMMENTED", OLD, oid=self.H1)])
        outs, rows, _, _ = scans(lambda i: fake(details={**DETAILS, 9: d}), before=seed)
        self.assertEqual(section(outs[0], "INBOUND"), [])
        self.assertNotIn("acme/app#9", "".join(section(outs[0], "REVIEWED") + section(outs[0], "WATCHED")))
        self.assertEqual([r for r in rows if r["kind"] == "todo" and q.pr_ref(r["ref"]) == "acme/app#9"], [])

    def test_the_open_review_row_moves_to_the_head_and_still_needs_the_user(self):
        def seed(cfg, state):
            hub.log_event(cfg, "reviewed", "re-look: new commits since the review",
                          ref="https://github.com/acme/app/pull/20", needs_user=True, detail="sha=" + self.H1)
        out = io.StringIO()
        with Env(now=NOW) as env, contextlib.redirect_stdout(out):
            cfg = hub.load_config()
            env.state.mkdir(parents=True, exist_ok=True)
            seed(cfg, env.state)
            # An older head, or a merged PR: nothing recorded, nothing moved.
            self.assertEqual(self.mark("acme/app#20", self.H2, head=self.H3), 1)
            self.assertEqual(self.mark("acme/app#20", self.H2, state="MERGED"), 1)
            self.assertEqual(hub.relooked(cfg), {})
            self.assertEqual(self.mark("https://github.com/acme/app/pull/20", self.H2), 0)
            needs = hub.open_items(cfg)[0]
            for bad in (["relooked", "acme/app#20", "2222222"], ["relooked", "app#20", self.H2], ["relooked", "acme/app#20"]):
                self.assertEqual(hub.main(bad), 2, bad)
            self.assertEqual(set(hub.relooked(cfg)), {"acme/app#20"})
        self.assertIn("FAIL: acme/app#20 is open at 3333333, not open at 2222222: re-look the head it has", out.getvalue())
        self.assertEqual([(r["text"], r["detail"]) for r in needs], [("looked again: nothing new", "sha=" + self.H2)])


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
