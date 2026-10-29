r"""review_lint.py: the body's shape, the PR's live state, and that a review from here is a COMMENT.

Mutations (run.py --mutate applies each and expects this file to fail):
  hint-hand-post: review_lint.py: `print(f"PASS: the body. Post the review with review_lint.py --post <review.json> --pr {owner}/{repo}#{n}, "` => `print(f"post: gh pr review {n} --repo {owner}/{repo} --comment --body-file {args.file} "`
  closed-ok: review_lint.py: `if d.get("state") != "OPEN":` => `if False:`
  draft-ok: review_lint.py: `if d.get("isDraft"):` => `if False:`
  head-unchecked: review_lint.py: `if now != head:` => `if False:`
  unknown-passes: review_lint.py: `return [f"{ref} live state unknown ({e})"], False` => `return [], True`
  review-cap-ignored: review_lint.py: `if len(text) > cap:` => `if False:`
  review-thin-bullet-ok: review_lint.py: `out += cd.thin_bullets(text)` => `pass`
  post-not-a-comment: review_lint.py: `"event": "COMMENT", "body"` => `"event": "PENDING", "body"`
  inline-dropped: review_lint.py: `for c in r.get("comments") or []]}` => `for c in []]}`
  inline-unlinted: review_lint.py: `for p in lint(c["body"], cap)]` => `for p in []]`
  short-sha-ok: review_lint.py: `if not re.fullmatch(r"[0-9a-f]{40}", str(r.get("head") or "")):` => `if False:`
  question-approvable: review_lint.py: `any(f.get("kind") not in ("nit", "consider")` => `any(f.get("kind") == "blocking"`
  escalation-ignored: review_lint.py: `if r.get("escalate") or any(` => `if any(`
  post-unlogged: review_lint.py: `row = hub.log_event(cfg, "reviewed", verdict(r),` => `row = dict(id="x", text="", ref="", kind="reviewed") or hub.log_event(cfg, "reviewed", verdict(r),`
  todo-left-open: review_lint.py: `hub.log_event(cfg, "done", "review posted", ref=row["ref"], corrects=t["id"])` => `pass`
  rows-pile-up: review_lint.py: `corrects=old["id"] if old else "",` => `corrects="",`
  failed-post-logged: review_lint.py: `print(f"BLOCKED: the post failed, so nothing was logged and the review is still to do: {e}")
        return 3` => `res = {}`
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
    def test_a_clean_body_passes_and_points_at_post(self):
        # A printed hand-typed post command, followed, drops the inline comments.
        with Env() as env:
            rc, out = run(env, "One finding: the retry loop never backs off (src/a.py:3).\n")
            self.assertEqual(rc, 0, out)
            self.assertIn("review_lint.py --post <review.json> --pr acme/app#12", out)
            self.assertNotIn("gh pr review", out)
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


FULL = "abcdef1234567890" + "0" * 24


def review(**over):
    return {"head": FULL, "body": "The retry loop never backs off (src/a.py:3).",
            "comments": [{"path": "src/a.py", "line": 3, "body": "This sleeps a fixed second on every try."}],
            "findings": [{"kind": "nit"}, {"kind": "consider"}], **over}


def post(env, r, state=None, answer=None):
    path = env.dir / "review.json"
    path.write_text(r if isinstance(r, str) else __import__("json").dumps(r))
    sent = []

    def on_post(endpoint, payload):
        sent.append((endpoint, payload))
        return answer if answer is not None else {"id": 77, "state": "COMMENTED",
                                                  "html_url": "https://github.com/acme/app/pull/12#pullrequestreview-77"}
    gh = hub.Gh(runner=FakeGh(rest={"pr view": state or {**OPEN, "headRefOid": FULL}, "post": on_post}), pause=0)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = rl.main(["--post", str(path), "--pr", "acme/app#12"], gh=gh)
    return rc, out.getvalue(), sent


def logged(env):
    p = env.state / "log"
    return [__import__("json").loads(ln) for f in sorted(p.glob("*.jsonl")) for ln in f.read_text().splitlines()]


class Post(unittest.TestCase):
    def test_a_clean_review_posts_as_a_comment_with_its_inline_comments_and_is_logged(self):
        with Env(now="2026-10-21T17:00:00+00:00") as env:
            rc, out, sent = post(env, review())
            self.assertEqual(rc, 0, out)
            (endpoint, payload), = sent
            self.assertEqual(endpoint, "repos/acme/app/pulls/12/reviews")
            self.assertEqual(payload["event"], "COMMENT")
            self.assertEqual(payload["commit_id"], FULL)
            self.assertEqual(payload["comments"], [{"path": "src/a.py", "line": 3, "side": "RIGHT",
                                                    "body": "This sleeps a fixed second on every try."}],
                             "the inline comment a hand-typed gh pr review dropped")
            row, = logged(env)
            self.assertEqual((row["kind"], row["text"], row["needs_user"]), ("reviewed", "approvable", True))
            self.assertIn(f"sha={FULL}", row["detail"])

    def test_a_question_blocking_or_escalation_needs_the_users_read(self):
        for over in ({"findings": [{"kind": "nit"}, {"kind": "question"}]}, {"findings": [{"kind": "blocking"}]},
                     {"findings": [], "escalate": "touches the billing schema"}):
            with Env(now="2026-10-21T17:00:00+00:00") as env:
                rc, out, _ = post(env, review(**over))
                self.assertEqual(rc, 0, out)
                self.assertEqual(logged(env)[0]["text"], "needs your read", over)

    def test_nothing_posts_on_a_lint_or_live_failure(self):
        with Env(now="2026-10-21T17:00:00+00:00") as env:
            dash = review(comments=[{"path": "a.py", "line": 1, "body": f"off by one {chr(0x2014)} see above"}])
            for r, why in ((review(head="abcdef1"), "full 40-character sha"),
                           (review(findings=[{"kind": "maybe"}]), "needs a kind"),
                           (review(comments=[{"path": "a.py", "body": "x y z"}]), "an integer line"),
                           (dash, "comment 1 (a.py:1): line 1: em dash"),
                           (review(body="x" * 2600), "over the 2500 cap")):
                rc, out, sent = post(env, r)
                self.assertEqual((rc, sent), (1, []), out)
                self.assertIn(why, out)
            rc, out, sent = post(env, review(), state={**OPEN, "headRefOid": "f" * 40})
            self.assertEqual((rc, sent), (1, []), out)
            self.assertIn("review again from the new head", out)
            self.assertEqual(logged(env), [])

    def test_a_failed_post_logs_nothing_and_leaves_the_todo_open(self):
        with Env(now="2026-10-21T17:00:00+00:00") as env:
            cfg = hub.load_config()
            todo = hub.log_event(cfg, "todo", "review requested", ref="https://github.com/acme/app/pull/12",
                                 detail="key=review:acme/app#12@abcdef1")
            rc, out, _ = post(env, review(), answer=Fail("HTTP 422: line must be part of the diff"))
            self.assertEqual(rc, 3, out)
            self.assertIn("nothing was logged", out)
            self.assertEqual([r["id"] for r in logged(env)], [todo["id"]])

    def test_a_post_closes_its_todo_and_replaces_the_last_review_row(self):
        with Env(now="2026-10-21T17:00:00+00:00") as env:
            cfg = hub.load_config()
            first = hub.log_event(cfg, "reviewed", "re-look: new commits since the review",
                                  ref="https://github.com/acme/app/pull/12", needs_user=True, detail="sha=" + "1" * 40)
            todo = hub.log_event(cfg, "todo", "re-look: new commits", ref="https://github.com/acme/app/pull/12",
                                 detail="key=review:acme/app#12@abcdef1")
            rc, out, _ = post(env, review(findings=[]))
            self.assertEqual(rc, 0, out)
            open_ = hub.open_items(cfg)[0]
            self.assertEqual([(r["id"], r["text"]) for r in open_], [(first["id"], "approvable")],
                             "one row per PR, now the re-look's verdict")
            self.assertEqual([r for r in hub.folded(cfg, 7) if r["kind"] == "todo"], [], f"{todo['id']} closed")


class CommentOnly(unittest.TestCase):
    def test_no_script_can_approve_or_request_changes(self):
        for p in sorted(BIN.glob("*.py")):
            text = p.read_text()
            self.assertFalse(re.search(r"--approve|--request-changes|APPROVE\b|REQUEST_CHANGES\b", text),
                             f"{p.name} carries a review verdict; this session posts comments only")


if __name__ == "__main__":
    unittest.main()
