r"""queue.py: the two instruments, the search quota, paging, UNKNOWN, review and
activity state, the watchdog, the previous scan.

Mutations (run.py --mutate applies each and expects this file to fail):
  xcheck-ignored: queue.py: `blocked.append("my open PRs differ between search and graphql")` => `pass`
  short-search-ok: queue.py: `if len(items) != total:` => `if False:`
  incomplete-ok: queue.py: `if d.get("incomplete_results"):` => `if False:`
  quota-unchecked: queue.py: `can_search = s["remaining"] >= need` => `can_search = True`
  page-everything: queue.py: `if not page["pageInfo"]["hasNextPage"] or not nodes or hub.parse_time(nodes[-1]["updatedAt"]) < cutoff:` => `if not page["pageInfo"]["hasNextPage"] or not nodes:`
  below-cutoff-dropped: queue.py: `refs |= set(below)` => `pass`
  merged-window-ignored: queue.py: `if n["state"] == "OPEN" or (merged and merged >= cutoff):` => `if True:`
  unknown-not-blocking: queue.py: `blocked.append(f"{len(unknown)} PR(s) could not be read")` => `pass`
  latest-reviews: queue.py: `hub.standing_reviews(pr["reviews"]["nodes"])` => `hub.standing_reviews(pr["latestReviews"]["nodes"])`
  drift-ignored: queue.py: `if oid != head:` => `if False:`
  bots-count: queue.py: `return hub.login(actor) not in (None, me) and not hub.is_bot(actor)` => `return hub.login(actor) not in (None, me)`
  old-activity-counts: queue.py: `events = sorted(e for e in events if e[0] > last_reply)` => `events = sorted(events)`
  monotonic-watchdog: queue.py: `clock = time.time` => `clock = time.monotonic`
  watchdog-no-exit: queue.py: `exit_fn(3)` => `pass`
  kill-nothing: queue.py: `if "queue.py" not in cmd:` => `if True:`
  kill-anything: queue.py: `if "queue.py" not in cmd:` => `if False:`
"""
import contextlib
import importlib.util
import io
import os
import stat
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

from fakes import BIN, ME, Env, Fail, FakeGh, actor, page

import hub

# By path: `import queue` is the stdlib's, which hub binds before this directory can shadow it.
_spec = importlib.util.spec_from_file_location("comms_queue", BIN / "queue.py")
q = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(q)

NOW = "2026-10-21T17:00:00+00:00"
RECENT, OLD = "2026-10-20T10:00:00Z", "2026-10-01T10:00:00Z"


def item(n, author, repo="acme/app"):
    return {"number": n, "repository_url": f"https://api.github.com/repos/{repo}", "title": f"pr {n}",
            "user": {"login": author}, "updated_at": RECENT, "html_url": f"https://github.com/{repo}/pull/{n}"}


def node(n, state="OPEN", updated=RECENT, merged=None, repo="acme/app"):
    return {"number": n, "state": state, "updatedAt": updated, "mergedAt": merged,
            "repository": {"nameWithOwner": repo, "owner": {"login": repo.split("/")[0]}}}


def ev(name, at, bot=False):
    return {"author": actor(name, bot=bot), "createdAt": at}


def rv(name, state, at, oid="h2"):
    return {"author": actor(name), "state": state, "submittedAt": at, "commit": {"oid": oid} if oid else None}


def detail(n, state="OPEN", head="h2", reviews=(), comments=(), threads=(), checks=(), requests=(), draft=False,
           decision=None):
    return {"number": n, "url": f"https://github.com/acme/app/pull/{n}", "title": f"pr {n}", "state": state,
            "isDraft": draft, "createdAt": OLD, "mergedAt": None, "headRefOid": head, "mergeStateStatus": "CLEAN",
            "reviewDecision": decision, "author": actor(ME),
            "reviewRequests": {"nodes": [{"requestedReviewer": {"__typename": "User", "login": r}} for r in requests]},
            "reviews": page(list(reviews)), "latestReviews": {"nodes": []},
            "comments": {"nodes": list(comments)},
            "reviewThreads": page([{"comments": {"nodes": list(t)}} for t in threads]),
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
}


def fake(**over):
    mine_open = over.get("mine_open", [1, 2, 3, 5])
    searched = over.get("searched", mine_open)

    def search(query, pg):
        if "review-requested:" in query:
            rows = [item(9, "teammate")]
        elif f"author:{ME}" in query:
            rows = [item(n, ME) for n in searched]
        else:
            rows = [item(9, "teammate"), item(10, "teammate")]
        total = over.get("total", len(rows)) if f"author:{ME}" in query else len(rows)
        return {"total_count": total, "incomplete_results": over.get("incomplete", False),
                "items": rows if pg == 1 else []}

    def pr(v):
        d = over.get("details", DETAILS).get(v["number"])
        return d if isinstance(d, Fail) else {"repository": {"pullRequest": d}}

    return FakeGh(
        graphql={
            "CommsMyOpen": {"viewer": {"login": ME, "pullRequests": page([node(n) for n in mine_open])}},
            "CommsMine": over.get("mine_pages", [{"viewer": {"pullRequests": page(
                [node(1), node(2), node(3), node(4, state="MERGED", merged=RECENT),
                 node(6, state="MERGED", updated="2026-10-13T10:00:00Z", merged="2026-10-13T09:00:00Z")])}}]),
            "CommsPR": pr,
        },
        rest={"rate_limit": {"resources": {"search": {"limit": 30, "remaining": over.get("quota", 30),
                                                      "reset": 1792600000},
                                           "graphql": {"limit": 5000, "remaining": 4900, "reset": 1792600000}}},
              "search": search})


def scan(gh):
    out = []
    with Env(now=NOW):
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
        self.assertIn("search-quota: 30/30 left, need 3", out)
        self.assertIn("my-open-xcheck: search=4 graphql=4 agree", out)
        self.assertEqual([r.split()[0] for r in section(out, "INBOUND")], ["acme/app#9"])
        self.assertEqual([r.split()[:4] for r in section(out, "WATCHED")],
                         [["acme/app#10", "by", "teammate", "requested=no"], ["acme/app#9", "by", "teammate", "requested=yes"]])
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
        self.assertIn("search quota 2 is below the 3", out)
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
        self.assertTrue(section(out, "AWAITING"), "the rest is still listed")

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
        p = self.spawn("queue.py", "scan")
        time.sleep(0.2)
        with Env() as env:
            env.state.mkdir(parents=True)
            pidfile = env.state / "queue.pid"
            pidfile.write_text(f"{p.pid} 2026-10-21T10:00:00Z\n")
            self.assertIn(f"pid {p.pid}", q.kill_previous(pidfile) or "")
        self.assertIsNotNone(p.wait(timeout=5))

    def test_another_process_is_left_alone(self):
        p = self.spawn("something-else")
        time.sleep(0.2)
        with Env() as env:
            env.state.mkdir(parents=True)
            pidfile = env.state / "queue.pid"
            pidfile.write_text(f"{p.pid} 2026-10-21T10:00:00Z\n")
            self.assertIsNone(q.kill_previous(pidfile))
        self.assertIsNone(p.poll())


if __name__ == "__main__":
    unittest.main()
