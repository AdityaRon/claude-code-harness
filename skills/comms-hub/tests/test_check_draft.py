r"""check_draft.py: shape, live state, send mode, freshness, the sent record.

Mutations (run.py --mutate applies each and expects this file to fail):
  em-dash-ok: check_draft.py: `if EM_DASH in line:` => `if False:`
  quote-ok: check_draft.py: `if line.lstrip().startswith(">"):` => `if False:`
  code-gt-ok: check_draft.py: `if ">" in m.group(0):` => `if False:`
  unlinked-ok: check_draft.py: `out.append(f"PR reference {m.group(0)!r} is not a link")` => `pass`
  links-not-stripped: check_draft.py: `rest = BARE_URL.sub(" ", MD_LINK.sub(" ", SLACK_LINK.sub(" ", text)))` => `rest = text`
  unknown-state-passes: check_draft.py: `ok = False` => `ok = True`
  bytes-unchecked: check_draft.py: `if hub.sha256(open(args.file, "rb").read()) != stamp["sha256"]:` => `if False:`
  age-unchecked: check_draft.py: `if age > args.max_age or age < 0:` => `if False:`
  resend-ok: check_draft.py: `if stamp.get("sent_id"):` => `if False:`
  quiet-ignored: check_draft.py: `mode, post = hub.send_plan(cfg, hub.now())` => `mode, post = "live", None`
  bare-url-greedy: check_draft.py: `BARE_URL = re.compile(r"https?://[^\s,;)\]>]+")` => `BARE_URL = re.compile(r"https?://\S+")`
  pr-dash-missed: check_draft.py: `\bPR[\s-]*#?\d+\b` => `\bPR\s*#?\d+\b`
  sent-machine-zone: check_draft.py: `day = hub.local_now(cfg).strftime("%Y-%m-%d")` => `day = hub.now().astimezone().strftime("%Y-%m-%d")`
  merged-awaiting-ok: check_draft.py: `if d.get("state") in ("MERGED", "CLOSED") and m:` => `if False:`
  ask-any-approver: check_draft.py: `r = d["standing"].get(login.lower())` => `r = next((x for x in d["standing"].values() if x["state"] == "APPROVED"), None)`
  ask-unaddressed-ok: check_draft.py: `if not asks:` => `if False:`
  ask-old-head-fails: check_draft.py: `if r["state"] == "APPROVED" and oid in (None, d.get("headRefOid")):` => `if r["state"] == "APPROVED":`
  ask-off-line-missed: check_draft.py: `for pr in here or every:` => `for pr in here:`
  answers-unchecked: check_draft.py: `if args.answers and args.reply != max(args.answers, key=ts_key):` => `if False:`
  replies-optional: check_draft.py: `if stamp["target"].startswith("reply:") and not args.replies:` => `if False:`
  send-unconfirmed: check_draft.py: `if after <= before:` => `if False:`
"""
import contextlib
import io
import os
import unittest
from unittest import mock

from fakes import Env, Fail, FakeGh, machine_zone

import check_draft
import hub

PR_JSON = {"state": "OPEN", "isDraft": False, "headRefOid": "abcdef1234", "mergeStateStatus": "CLEAN",
           "reviewDecision": "APPROVED", "reviews": []}
LINK = "<https://github.com/acme/app/pull/12|acme/app#12>"


def review(who, state, oid="abcdef1234", at="2026-10-21T16:50:00Z"):
    return {"author": {"login": who}, "state": state, "submittedAt": at, "commit": {"oid": oid}, "body": ""}
DAY = "2026-10-21T17:00:00+00:00"      # 10:00 in America/Los_Angeles
EVENING = "2026-10-22T03:30:00+00:00"  # 20:30 the same evening there


def gate(env, text, *flags, gh=None, now=DAY):
    path = env.dir / "draft.md"
    if text is not None:
        path.write_bytes(text.encode())
    out = io.StringIO()
    with mock.patch.dict(os.environ, {"COMMS_HUB_NOW": now}), contextlib.redirect_stdout(out):
        rc = check_draft.main([str(path), *flags], gh=hub.Gh(runner=gh, pause=0) if gh else None)
    return rc, out.getvalue()


def fake(state=PR_JSON):
    return FakeGh(rest={"pr view": lambda n, repo: state})


class Shape(unittest.TestCase):
    def check(self, text):
        with Env() as env:
            return gate(env, text, "--top-level", gh=fake())

    def test_clean_draft_passes(self):
        rc, out = self.check("Merged <https://github.com/acme/app/pull/12|acme/app#12>, thanks.\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("acme/app#12 state=OPEN draft=no head=abcdef1 merge=CLEAN review=APPROVED", out)

    def test_markdown_link_and_bare_url_count_as_links(self):
        rc, out = self.check("See [#12](https://github.com/acme/app/pull/12) and https://github.com/acme/app/pull/13\n")
        self.assertEqual(rc, 0, out)

    def test_em_dash_fails(self):
        rc, out = self.check(f"Done {chr(0x2014)} thanks\n")
        self.assertEqual(rc, 1)
        self.assertIn("em dash", out)

    def test_quote_at_line_start_fails(self):
        rc, out = self.check("> you asked\nyes\n")
        self.assertEqual(rc, 1)
        self.assertIn("starts with '>'", out)

    def test_gt_in_code_span_fails(self):
        rc, out = self.check("run `a > b` first\n")
        self.assertEqual(rc, 1)
        self.assertIn("inside a code span", out)

    def test_a_reference_glued_to_a_url_is_still_checked(self):
        rc, out = self.check("See https://github.com/acme/app/pull/12,#13 please\n")
        self.assertEqual(rc, 1)
        self.assertIn("'#13' is not a link", out)

    def test_unlinked_pr_references_fail(self):
        for ref in ("#12", "acme/app#12", "PR 12", "PR #12", "PR-12"):
            rc, out = self.check(f"See {ref} please\n")
            self.assertEqual(rc, 1, ref)
            self.assertIn("is not a link", out, ref)

    def test_token_shape_fails(self):
        rc, out = self.check("token xoxb-" + "1" * 12 + "-abcdefghij\n")
        self.assertEqual(rc, 1)
        self.assertIn("no secrets", out)


class LiveState(unittest.TestCase):
    def test_gh_failure_blocks_and_records_no_pass(self):
        with Env() as env:
            rc, out = gate(env, "<https://github.com/acme/app/pull/12|PR>\n", "--top-level",
                           gh=FakeGh(rest={"pr view": [Fail(), Fail()]}))
            self.assertEqual(rc, 3, out)
            self.assertIn("UNKNOWN", out)
            rc, out = gate(env, None, "--assert-fresh")
            self.assertEqual(rc, 1)

    def test_reply_needs_a_slack_ts(self):
        with Env() as env:
            self.assertEqual(gate(env, "ok\n", "--reply", "12.3", gh=fake())[0], 2)
            rc, out = gate(env, "ok\n", "--reply", "1761040800.123456", gh=fake())
            self.assertEqual(rc, 0, out)
            self.assertIn("target: reply:1761040800.123456", out)


class Claims(unittest.TestCase):
    def check(self, text, *flags, state=PR_JSON):
        with Env() as env:
            return gate(env, text, "--top-level", *flags, gh=fake(state))

    def test_a_merged_pr_called_awaiting_fails(self):
        merged = {**PR_JSON, "state": "MERGED"}
        for words in ("still awaiting review", "waiting on CI", "ready for review", "not merged yet"):
            rc, out = self.check(f"{LINK} is {words}.\n", state=merged)
            self.assertEqual(rc, 1, words)
            self.assertIn("calls merged acme/app#12", out)
        rc, out = self.check(f"{LINK} merged, thanks.\n", state=merged)
        self.assertEqual(rc, 0, out)
        rc, out = self.check(f"{LINK} is still awaiting review.\n")
        self.assertEqual(rc, 0, "an open PR may be awaiting: " + out)

    def test_an_ask_to_someone_who_approved_at_this_head_fails(self):
        approved = {**PR_JSON, "reviews": [review("Bob", "APPROVED")]}
        rc, out = self.check(f"could you review {LINK}?\n", "--asks", "bob", state=approved)
        self.assertEqual(rc, 1, out)
        self.assertIn("asks bob to review acme/app#12, which they approved 2026-10-21T16:50:00Z at the current head", out)
        self.assertIn("approved-by=bob@abcdef1", out)

    def test_another_reviewers_approval_does_not_fail_the_ask(self):
        other = {**PR_JSON, "reviews": [review("carol", "APPROVED")]}
        rc, out = self.check(f"could you review {LINK}?\n", "--asks", "bob", state=other)
        self.assertEqual(rc, 0, out)

    def test_an_approval_at_an_older_head_is_a_re_review_ask(self):
        moved = {**PR_JSON, "reviews": [review("bob", "APPROVED", oid="0123456789")]}
        rc, out = self.check(f"PTAL {LINK}, head moved.\n", "--asks", "bob", state=moved)
        self.assertEqual(rc, 0, out)
        changes = {**PR_JSON, "reviews": [review("bob", "APPROVED"), review("bob", "CHANGES_REQUESTED", at="2026-10-21T16:55:00Z")]}
        self.assertEqual(self.check(f"PTAL {LINK}\n", "--asks", "bob", state=changes)[0], 0)

    def test_an_ask_with_no_addressee_fails_closed(self):
        rc, out = self.check(f"could you take a look at {LINK}?\n")
        self.assertEqual(rc, 1, out)
        self.assertIn("name the addressee with --asks LOGIN", out)
        self.assertEqual(self.check(f"{LINK} is in; I reviewed it myself.\n")[0], 0, "not an ask")

    def test_an_ask_on_its_own_line_covers_every_linked_pr(self):
        approved = {**PR_JSON, "reviews": [review("bob", "APPROVED")]}
        rc, out = self.check(f"Two for you, mind taking a look?\n- {LINK}\n", "--asks", "bob", state=approved)
        self.assertEqual(rc, 1, out)
        self.assertIn("line 1: asks bob to review acme/app#12", out)


class SendMode(unittest.TestCase):
    def test_daytime_live_evening_schedules(self):
        with Env() as env:
            self.assertIn("send: live", gate(env, "ok\n", "--top-level", gh=fake())[1])
            rc, out = gate(env, "ok\n", "--top-level", gh=fake(), now=EVENING)
            self.assertIn("send: schedule post_at=2026-10-22T08:00:00-07:00", out)


class Freshness(unittest.TestCase):
    def test_pass_then_fresh(self):
        with Env() as env:
            self.assertEqual(gate(env, "ok\n", "--top-level", gh=fake())[0], 0)
            rc, out = gate(env, None, "--assert-fresh")
            self.assertEqual(rc, 0, out)
            self.assertIn("FRESH", out)

    def test_changed_bytes_are_stale(self):
        with Env() as env:
            gate(env, "ok\n", "--top-level", gh=fake())
            rc, out = gate(env, "ok, and one more line\n", "--assert-fresh")
            self.assertEqual(rc, 1)
            self.assertIn("changed", out)

    def test_old_pass_is_stale(self):
        with Env() as env:
            gate(env, "ok\n", "--top-level", gh=fake())
            rc, out = gate(env, None, "--assert-fresh", now="2026-10-21T17:06:00+00:00")
            self.assertEqual(rc, 1)
            self.assertIn("old", out)

    def test_sent_draft_cannot_pass_fresh_again(self):
        with Env() as env:
            gate(env, "ok\n", "--top-level", gh=fake())
            rc, out = gate(env, None, "--record-sent", "1761040800.000100")
            self.assertEqual(rc, 0, out)
            self.assertTrue(list((env.state / "sent").rglob("*.md")))
            self.assertIn("sent 1761040800.000100", "".join(p.read_text() for p in (env.state / "log").iterdir()))
            rc, out = gate(env, None, "--assert-fresh")
            self.assertEqual(rc, 1)
            self.assertIn("already sent", out)
            self.assertEqual(gate(env, None, "--record-sent", "again")[0], 1)

    def test_a_combined_reply_threads_under_the_newest_message_it_answers(self):
        older, newer = "1761040800.000100", "1761044400.000200"
        with Env() as env:
            rc, out = gate(env, "ok\n", "--reply", older, "--answers", older, newer, gh=fake())
            self.assertEqual(rc, 1, out)
            self.assertIn(f"FAIL: --reply {older} is not the newest message the draft answers ({newer})", out)
            rc, out = gate(env, "ok\n", "--reply", newer, "--answers", older, newer, gh=fake())
            self.assertEqual(rc, 0, out)

    def test_a_sent_reply_is_recorded_only_when_the_parents_reply_count_moved(self):
        with Env() as env:
            gate(env, "ok\n", "--reply", "1761040800.000100", gh=fake())
            rc, out = gate(env, None, "--record-sent", "1761044400.000200")
            self.assertEqual(rc, 1, out)
            self.assertIn("pass --replies BEFORE AFTER", out)
            rc, out = gate(env, None, "--record-sent", "1761044400.000200", "--replies", "3", "3")
            self.assertEqual(rc, 1, out)
            self.assertIn("did not move (3 -> 3)", out)
            self.assertFalse((env.state / "sent").exists(), "nothing recorded")
            rc, out = gate(env, None, "--record-sent", "1761044400.000200", "--replies", "3", "4")
            self.assertEqual(rc, 0, out)

    def test_the_sent_folder_is_the_day_in_the_configured_zone(self):
        # DAY is 10:00 on 2026-10-21 in Los Angeles, the config's zone, and 06:00 on the 22nd in Auckland.
        with Env() as env, machine_zone("Pacific/Auckland"):
            gate(env, "ok\n", "--top-level", gh=fake())
            rc, out = gate(env, None, "--record-sent", "1761040800.000100")
            self.assertEqual(rc, 0, out)
            self.assertTrue((env.state / "sent" / "2026-10-21" / "1761040800.000100.md").is_file(), out)


if __name__ == "__main__":
    unittest.main()
