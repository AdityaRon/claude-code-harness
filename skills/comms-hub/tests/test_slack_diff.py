r"""slack_diff.py: NEW, MOVED, GONE, and a commit that only follows reading.

Mutations (run.py --mutate applies each and expects this file to fail):
  new-missed: slack_diff.py: `new = [ts for ts in page if ts not in snapshot]` => `new = []`
  moved-missed: slack_diff.py: `moved = [ts for ts in page if ts in snapshot and snapshot[ts] != page[ts]]` => `moved = []`
  unread-commits: slack_diff.py: `if unread:` => `if False:`
  empty-page-trusted: slack_diff.py: `if not page:` => `if False:`
  gone-missed: slack_diff.py: `and ts not in page]` => `and False]`
  baseline-twice: slack_diff.py: `if snap:` => `if False:`
  stale-listing-trusted: slack_diff.py: `if age > MAX_AGE:` => `if False:`
"""
import contextlib
import io
import os
import time
import unittest

from fakes import Env

import slack_diff

A, B, C, D = "1761000000.000100", "1761000100.000200", "1761000200.000300", "1761000300.000400"


def write(path, listing):
    path.write_text("".join(f"{ts}\t{n}\n" for ts, n in listing.items()))


def run(env, page, *flags, age=0):
    lst = env.dir / "page.tsv"
    write(lst, page)
    if age:
        os.utime(lst, (time.time() - age, time.time() - age))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = slack_diff.main([str(lst), "--channel", "dm-primary", *flags])
    return rc, out.getvalue()


class Diff(unittest.TestCase):
    def test_new_moved_gone(self):
        with Env() as env:
            (env.state / "slack").mkdir(parents=True)
            write(env.state / "slack" / "dm-primary.tsv", {A: 0, B: 1, C: 2})
            rc, out = run(env, {B: 3, D: 0})
            self.assertEqual(rc, 0, out)
            self.assertIn(f"NEW {D} replies=0", out)
            self.assertIn(f"MOVED {B} replies 1 -> 3", out)
            self.assertIn(f"GONE {C}", out)
            self.assertNotIn(f"GONE {A}", out, "A is older than the page, not gone")
            self.assertIn("summary: new=1 moved=1 gone=1", out)

    def test_commit_refused_until_every_thread_read(self):
        with Env() as env:
            (env.state / "slack").mkdir(parents=True)
            snap = env.state / "slack" / "dm-primary.tsv"
            write(snap, {A: 0, B: 1})
            rc, out = run(env, {B: 2, C: 0}, "--commit", "--read", B)
            self.assertEqual(rc, 2)
            self.assertIn(f"REFUSED: read these threads in full first, then pass them to --read: {C}", out)
            self.assertEqual(snap.read_text(), f"{A}\t0\n{B}\t1\n", "nothing written on refusal")
            rc, out = run(env, {B: 2, C: 0}, "--commit", "--read", f"{B},{C}")
            self.assertEqual(rc, 0, out)
            self.assertIn("kept 1 older lines", out)
            self.assertEqual(snap.read_text(), f"{A}\t0\n{B}\t2\n{C}\t0\n")

    def test_empty_page_is_untrusted(self):
        with Env() as env:
            (env.state / "slack").mkdir(parents=True)
            write(env.state / "slack" / "dm-primary.tsv", {A: 0})
            rc, out = run(env, {}, "--commit")
            self.assertEqual(rc, 2)
            self.assertIn("UNTRUSTED", out)

    def test_a_listing_from_an_earlier_tick_is_stale(self):
        with Env() as env:
            (env.state / "slack").mkdir(parents=True)
            write(env.state / "slack" / "dm-primary.tsv", {A: 0})
            rc, out = run(env, {A: 0, B: 2}, "--commit", "--read", B, age=20 * 60)
            self.assertEqual(rc, 2, out)
            self.assertIn("STALE: the listing is 20 min old", out)
            self.assertNotIn("NEW", out)
            self.assertEqual((env.state / "slack" / "dm-primary.tsv").read_text(), f"{A}\t0\n")
            self.assertEqual(run(env, {A: 0, B: 2}, "--commit", "--read", B, age=10 * 60)[0], 0)

    def test_baseline_only_on_first_run(self):
        with Env() as env:
            rc, out = run(env, {A: 0, B: 4}, "--commit", "--baseline")
            self.assertEqual(rc, 0, out)
            self.assertIn("BASELINE: 2 messages accepted unread", out)
            rc, out = run(env, {A: 0, B: 4, C: 0}, "--commit", "--baseline")
            self.assertEqual(rc, 2)
            self.assertIn("REFUSED", out)


if __name__ == "__main__":
    unittest.main()
