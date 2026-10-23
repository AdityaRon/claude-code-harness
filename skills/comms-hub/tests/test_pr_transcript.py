r"""pr_transcript.py: the conversation in time order, bodies shown or named empty, nothing partial.

Mutations (run.py --mutate applies each and expects this file to fail):
  unordered: pr_transcript.py: `for at, label, body in sorted(events):` => `for at, label, body in events:`
  empty-body-silent: pr_transcript.py: `(body or "").strip() or "(no body)"` => `(body or "").strip()`
  inline-dropped: pr_transcript.py: `for i, c in enumerate(t["comments"]["nodes"]):` => `for i, c in ():`
  partial-ok: pr_transcript.py: `if pr[k]["pageInfo"].get("hasNextPage"):` => `if False:`
  no-head-line: pr_transcript.py: `lines = [f"head: {pr['headRefOid']}", ` => `lines = [`
"""
import contextlib
import io
import unittest

from fakes import Env, Fail, FakeGh, actor, page

import hub
import pr_transcript as pt

T1, T2, T3, T4 = "2026-10-20T10:00:00Z", "2026-10-20T11:00:00Z", "2026-10-20T12:00:00Z", "2026-10-20T13:00:00Z"


def pr(more=None, more_thread=False):
    return {"number": 7, "url": "https://github.com/acme/app/pull/7", "title": "retry with backoff", "state": "OPEN",
            "isDraft": False, "headRefOid": "abcdef1234567890", "createdAt": T1, "body": "Adds backoff.",
            "author": actor("teammate"),
            "comments": page([{"author": actor("bob"), "createdAt": T4, "body": "ping"}], more=more == "comments"),
            "reviews": page([{"author": actor("carol"), "state": "APPROVED", "submittedAt": T2, "body": "",
                              "commit": {"oid": "abcdef1234567890"}}], more=more == "reviews"),
            "reviewThreads": page([{"isResolved": False, "path": "src/a.py", "line": 3, "comments": page(
                [{"author": actor("carol"), "createdAt": T2, "body": "off by one?"},
                 {"author": actor("teammate"), "createdAt": T3, "body": "fixed in the next push"}], more=more_thread)}],
                more=more == "reviewThreads")}


def run(env, handler, *argv):
    gh = hub.Gh(runner=FakeGh(graphql={"CommsTranscript": handler}), pause=0)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = pt.main(["acme/app#7", *argv], gh=gh)
    return rc, out.getvalue()


class Transcript(unittest.TestCase):
    def test_time_order_with_empty_bodies_named(self):
        with Env() as env:
            rc, out = run(env, {"repository": {"pullRequest": pr()}})
        self.assertEqual(rc, 0, out)
        lines = out.splitlines()
        self.assertEqual(lines[0], "head: abcdef1234567890")
        self.assertIn("# acme/app#7: retry with backoff", lines)
        self.assertIn("Adds backoff.", lines)
        heads = [l for l in lines if l.startswith("### ")]
        self.assertEqual(heads, [f"### {T2} carol inline src/a.py:3", f"### {T2} carol review APPROVED at abcdef1",
                                 f"### {T3} teammate inline src/a.py:3 reply", f"### {T4} bob comment"])
        self.assertEqual(lines[lines.index(heads[1]) + 1], "(no body)")
        self.assertEqual(lines[lines.index(heads[0]) + 1], "off by one?")

    def test_writes_a_file_and_prints_the_head(self):
        with Env() as env:
            rc, out = run(env, {"repository": {"pullRequest": pr()}}, "-o", str(env.dir / "pr-7.md"))
            self.assertEqual(rc, 0, out)
            self.assertEqual(out.splitlines()[0], "head: abcdef1234567890")
            self.assertIn("### ", (env.dir / "pr-7.md").read_text())

    def test_more_than_one_page_or_an_unreadable_pr_blocks(self):
        with Env() as env:
            for more in ("comments", "reviews", "reviewThreads"):
                rc, out = run(env, {"repository": {"pullRequest": pr(more=more)}})
                self.assertEqual(rc, 3, more)
                self.assertIn(f"more than one page of {more}", out)
            rc, out = run(env, {"repository": {"pullRequest": pr(more_thread=True)}})
            self.assertEqual(rc, 3)
            self.assertIn("a thread at src/a.py:3", out)
            rc, out = run(env, [Fail(), Fail()])
            self.assertEqual(rc, 3)
            self.assertIn("BLOCKED", out)


if __name__ == "__main__":
    unittest.main()
