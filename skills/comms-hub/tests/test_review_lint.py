r"""review_lint.py: the body's shape, the PR's live state, and that a review from here is a COMMENT.

Mutations (run.py --mutate applies each and expects this file to fail):
  posts-approve: review_lint.py: `--repo {owner}/{repo} --comment` => `--repo {owner}/{repo} --approve`
  closed-ok: review_lint.py: `if d.get("state") != "OPEN":` => `if False:`
  draft-ok: review_lint.py: `if d.get("isDraft"):` => `if False:`
  head-unchecked: review_lint.py: `if now != head:` => `if False:`
  unknown-passes: review_lint.py: `return [f"{ref} live state unknown ({e})"], False` => `return [], True`
  review-cap-ignored: review_lint.py: `if len(text) > cap:` => `if False:`
  review-thin-bullet-ok: review_lint.py: `out += cd.thin_bullets(text)` => `pass`
"""
import contextlib
import io
import re
import unittest

from fakes import BIN, CONFIG, Env, Fail, FakeGh

import hub
import review_lint as rl

HEAD = "abcdef1234567890"
OPEN = {"state": "OPEN", "isDraft": False, "headRefOid": HEAD}


def run(env, text, *flags, state=OPEN):
    path = env.dir / "review.md"
    path.write_text(text)
    gh = hub.Gh(runner=FakeGh(rest={"pr view": state}), pause=0)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = rl.main([str(path), "--pr", "acme/app#12", "--head", HEAD, *flags], gh=gh)
    return rc, out.getvalue()


class Lint(unittest.TestCase):
    def test_a_clean_body_passes_and_the_post_is_a_comment(self):
        with Env() as env:
            rc, out = run(env, "One finding: the retry loop never backs off (src/a.py:3).\n")
            self.assertEqual(rc, 0, out)
            self.assertIn(f"post: gh pr review 12 --repo acme/app --comment --body-file {env.dir / 'review.md'}", out)
            self.assertNotIn("approve", out.lower())

    def test_shape_failures(self):
        with Env() as env:
            rc, out = run(env, f"Looks fine {chr(0x2014)} one nit:\n- typo\n")
            self.assertEqual(rc, 1)
            self.assertIn("line 1: em dash", out)
            self.assertIn("line 2: thin bullet 'typo'", out)
            rc, out = run(env, "x" * 2600 + "\n")
            self.assertEqual(rc, 1)
            self.assertIn("2601 characters, over the 2500 cap", out)
            self.assertEqual(run(env, "\n")[0], 1)
        with Env(config=CONFIG.replace("merged_days = 7", "merged_days = 7\nreview_max_chars = 3000")) as env:
            self.assertEqual(run(env, "x" * 2600 + "\n")[0], 0)

    def test_the_pr_must_be_open_not_draft_and_at_the_head_the_reviewer_read(self):
        with Env() as env:
            rc, out = run(env, "fine\n", state={**OPEN, "state": "MERGED"})
            self.assertEqual(rc, 1)
            self.assertIn("acme/app#12 is MERGED: nothing to review", out)
            rc, out = run(env, "fine\n", state={**OPEN, "isDraft": True})
            self.assertEqual(rc, 1)
            self.assertIn("is a draft", out)
            rc, out = run(env, "fine\n", state={**OPEN, "headRefOid": "0123456789abcdef"})
            self.assertEqual(rc, 1)
            self.assertIn("head is 0123456, the review read abcdef1: review again", out)
            self.assertNotIn("post:", out)

    def test_an_unreadable_pr_blocks(self):
        with Env() as env:
            rc, out = run(env, "fine\n", state=[Fail(), Fail()])
            self.assertEqual(rc, 3, out)
            self.assertIn("BLOCKED: acme/app#12 live state unknown", out)
            self.assertNotIn("post:", out)


class CommentOnly(unittest.TestCase):
    def test_no_script_can_approve_or_request_changes(self):
        for p in sorted(BIN.glob("*.py")):
            text = p.read_text()
            self.assertFalse(re.search(r"--approve|--request-changes|APPROVE\b|REQUEST_CHANGES\b", text),
                             f"{p.name} carries a review verdict; this session posts comments only")


if __name__ == "__main__":
    unittest.main()
