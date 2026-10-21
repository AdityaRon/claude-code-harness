r"""resolve_threads.py: each of the five rules, paging, and the re-read after --apply.

Mutations (run.py --mutate applies each and expects this file to fail):
  rule1-not-mine: resolve_threads.py: `if hub.login(pr.get("author")) != me:` => `if False:`
  rule1-not-open: resolve_threads.py: `if pr.get("state") != "OPEN":` => `if False:`
  rule2-resolved: resolve_threads.py: `if t.get("isResolved"):` => `if False:`
  rule2-own-thread (may survive): resolve_threads.py: `if hub.login(opener) == me:` => `if False:`
  rule2-bot: resolve_threads.py: `if hub.is_bot(opener):` => `if False:`
  rule3-last-word: resolve_threads.py: `if hub.login(last.get("author")) != me:` => `if False:`
  rule4-any-standing: resolve_threads.py: `if not review or review.get("state") != "APPROVED":` => `if not review:`
  rule4-any-approver: resolve_threads.py: `review = standing.get(hub.login(opener))` => `review = next((r for r in standing.values() if r["state"] == "APPROVED"), None)`
  rule4-commented-revokes: hub.py: `if r.get("state") in ("COMMENTED", "PENDING"):` => `if r.get("state") in ("PENDING",):`
  rule5-order: resolve_threads.py: `if hub.parse_time(review["submittedAt"]) <= hub.parse_time(last["createdAt"]):` => `if False:`
  page-reviews: resolve_threads.py: `if pr["reviews"]["pageInfo"]["hasNextPage"]:` => `if False:`
  page-threads: resolve_threads.py: `if pr["reviewThreads"]["pageInfo"]["hasNextPage"]:` => `if False:`
  page-comments: resolve_threads.py: `if t["comments"]["pageInfo"]["hasNextPage"]:` => `if False:`
  reread-trusted: resolve_threads.py: `resolved = bool(gh.graphql(REREAD, id=tid)["node"]["isResolved"])` => `resolved = True`
  dry-run-applies: resolve_threads.py: `if not args.apply:` => `if False:`
The own-thread rule may survive: a thread I opened needs MY approval to pass
rule 4, and GitHub forbids approving your own PR.
"""
import contextlib
import io
import unittest

from fakes import ME, Env, FakeGh, actor, page

import hub
import resolve_threads as rt

REF = "acme/app#7"


def who(name):
    return actor(name, bot=name.endswith("[bot]"))


def thread(*comments, tid="t1", resolved=False, more=False):
    return {"id": tid, "isResolved": resolved, "path": "src/a.py", "line": 3,
            "comments": page([{"author": who(n), "createdAt": at} for n, at in comments], more=more)}


def review(name, state, at):
    return {"author": who(name), "state": state, "submittedAt": at}


def pr(threads, reviews, author=ME, state="OPEN", more_reviews=False, more_threads=False):
    return {"number": 7, "url": "https://github.com/acme/app/pull/7", "state": state, "author": actor(author),
            "reviews": page(reviews, more=more_reviews), "reviewThreads": page(threads, more=more_threads)}


T10, T11, T1130, T12, T13 = ("2026-10-20T10:00:00Z", "2026-10-20T11:00:00Z", "2026-10-20T11:30:00Z",
                             "2026-10-20T12:00:00Z", "2026-10-20T13:00:00Z")
ANSWERED = thread(("bob", T10), (ME, T11))


def verdicts(p):
    skip, out = rt.decide(p, ME)
    return skip, [(v, why) for v, _, why in out]


class Rules(unittest.TestCase):
    def assertVerdict(self, p, verdict, why=""):
        skip, out = verdicts(p)
        self.assertIsNone(skip)
        self.assertEqual(len(out), 1, out)
        self.assertEqual(out[0][0], verdict, out)
        self.assertIn(why, out[0][1])

    def test_answered_then_approved_resolves(self):
        self.assertVerdict(pr([ANSWERED], [review("bob", "APPROVED", T12)]), "RESOLVE")

    def test_approval_survives_a_later_commented_review(self):
        self.assertVerdict(pr([ANSWERED], [review("bob", "APPROVED", T12), review("bob", "COMMENTED", T13)]),
                           "RESOLVE")

    def test_later_changes_requested_revokes(self):
        self.assertVerdict(pr([ANSWERED], [review("bob", "APPROVED", T12), review("bob", "CHANGES_REQUESTED", T13)]),
                           "SKIP", "CHANGES_REQUESTED")

    def test_dismissed_approval_does_not_count(self):
        self.assertVerdict(pr([ANSWERED], [review("bob", "DISMISSED", T12)]), "SKIP", "DISMISSED")

    def test_comment_only_reviewer(self):
        self.assertVerdict(pr([ANSWERED], [review("bob", "COMMENTED", T12)]), "SKIP", "none")

    def test_reviewer_has_the_last_word(self):
        self.assertVerdict(pr([thread(("bob", T10), (ME, T11), ("bob", T1130))], [review("bob", "APPROVED", T12)]),
                           "SKIP", "last word")

    def test_approver_is_not_the_opener(self):
        self.assertVerdict(pr([ANSWERED], [review("alice", "APPROVED", T12), review("bob", "COMMENTED", T12)]),
                           "SKIP", "bob's standing review is none")

    def test_bot_thread(self):
        self.assertVerdict(pr([thread(("lint[bot]", T10), (ME, T11))], [review("lint[bot]", "APPROVED", T12)]),
                           "SKIP", "bot")

    def test_approval_predates_our_reply(self):
        self.assertVerdict(pr([ANSWERED], [review("bob", "APPROVED", T1130.replace("11:30", "10:30"))]),
                           "SKIP", "before our last reply")

    def test_own_thread(self):
        self.assertVerdict(pr([thread((ME, T10), (ME, T11))], [review("bob", "APPROVED", T12)]), "SKIP", "I opened")

    def test_resolved_thread_is_left_alone(self):
        self.assertEqual(verdicts(pr([thread(("bob", T10), (ME, T11), resolved=True)],
                                     [review("bob", "APPROVED", T12)])), (None, []))

    def test_not_my_pr_or_not_open(self):
        self.assertEqual(verdicts(pr([ANSWERED], [review("bob", "APPROVED", T12)], author="bob"))[0], "not my PR")
        self.assertEqual(verdicts(pr([ANSWERED], [review("bob", "APPROVED", T12)], state="MERGED"))[0], "PR is MERGED")

    def test_more_than_one_page_is_skipped(self):
        approved = [review("bob", "APPROVED", T12)]
        self.assertIn("reviews", verdicts(pr([ANSWERED], approved, more_reviews=True))[0])
        self.assertIn("threads", verdicts(pr([ANSWERED], approved, more_threads=True))[0])
        long = thread(("bob", T10), (ME, T11), more=True)
        self.assertEqual(verdicts(pr([long], approved))[1], [("SKIP", "thread longer than one page")])


class Apply(unittest.TestCase):
    def run_main(self, *argv, reread=True):
        fake = FakeGh(graphql={
            "CommsMyOpenThreads": {"viewer": {"login": ME, "pullRequests": page(
                [{"number": 7, "repository": {"nameWithOwner": "acme/app", "owner": {"login": "acme"}}}])}},
            "CommsThreads": {"repository": {"pullRequest": pr(
                [ANSWERED, thread(("carol", T10), (ME, T11), tid="t2")],
                [review("bob", "APPROVED", T12), review("carol", "CHANGES_REQUESTED", T12)])}},
            "CommsResolve": {"resolveReviewThread": {"thread": {"id": "t1", "isResolved": True}}},
            "CommsThread": {"node": {"id": "t1", "isResolved": reread}},
        })
        out = io.StringIO()
        with Env() as env, contextlib.redirect_stdout(out):
            rc = rt.main(list(argv), gh=hub.Gh(runner=fake, pause=0))
            log = "".join(p.read_text() for p in (env.state / "log").glob("*.md")) if (env.state / "log").exists() else ""
        return rc, out.getvalue(), fake, log

    def test_dry_run_changes_nothing(self):
        rc, out, fake, _ = self.run_main()
        self.assertEqual(rc, 0, out)
        self.assertIn(f"RESOLVE {REF} src/a.py:3 thread=t1", out)
        self.assertIn(f"SKIP {REF} src/a.py:3 thread=t2", out)
        self.assertEqual(fake.count("resolveReviewThread"), 0)

    def test_apply_resolves_only_the_resolvable_and_reports_github(self):
        rc, out, fake, log = self.run_main("--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(fake.count("resolveReviewThread"), 1)
        self.assertIn(f"resolved {REF} src/a.py:3 thread=t1 isResolved=true (re-read)", out)
        self.assertIn("resolved thread t1", log)

    def test_a_reread_that_says_open_is_reported_and_fails(self):
        rc, out, _, log = self.run_main("--apply", reread=False)
        self.assertEqual(rc, 3)
        self.assertIn("STILL OPEN", out)
        self.assertNotIn("resolved thread t1", log)


if __name__ == "__main__":
    unittest.main()
