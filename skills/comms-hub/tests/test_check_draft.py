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
  ask-any-reviewer: check_draft.py: `r = d["at_head"].get(login.lower())` => `r = next(iter(d["at_head"].values()), None)`
  ask-unaddressed-ok: check_draft.py: `if not asks:` => `if False:`
  ask-old-head-fails: check_draft.py: `if (r.get("commit") or {}).get("oid") == head and hub.login(r.get("author")):` => `if hub.login(r.get("author")):`
  thread-reply-is-a-review: check_draft.py: `or (r.get("state") == "COMMENTED" and not (r.get("body") or "").strip())` => ``
  ask-off-line-missed: check_draft.py: `for pr in here or every:` => `for pr in here:`
  en-dash-ok: check_draft.py: `if EN_DASH in line:` => `if False:`
  aws-temp-key-missed: check_draft.py: `(?:AKIA|ASIA)[0-9A-Z]{16}` => `AKIA[0-9A-Z]{16}`
  launchdarkly-key-missed: check_draft.py: `|(?:sdk|mob|api)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` => ``
  pem-missed: check_draft.py: `|-----BEGIN [A-Z ]*-----` => ``
  assignment-missed: check_draft.py: `|(?i:[a-z_]*(?:key|token|secret|password)\s*[=:]\s*[\"']?[\w./+-]{8,})` => ``
  mention-map-ignored: check_draft.py: `login = logins.get(sid)` => `login = None`
  answers-unchecked: check_draft.py: `if args.answers and args.reply != max(args.answers, key=ts_key):` => `if False:`
  replies-optional: check_draft.py: `if stamp["target"].startswith("reply:") and not args.replies:` => `if False:`
  send-unconfirmed: check_draft.py: `if after <= before:` => `if False:`
  posted-still-listed: hub.py: `if parse_time(s.get("post_at")) <= now_:` => `if False:`
  cap-ignored: check_draft.py: `if len(text) > cap:` => `if False:`
  cap-hardcoded: check_draft.py: `problems = shape_problems(text, int(cfg["slack"]["max_chars"]))` => `problems = shape_problems(text)`
  thin-bullet-ok: check_draft.py: `if m and len(re.findall(r"\w+", m.group(1))) < 3:` => `if False:`
  restate-sends: check_draft.py: `react = bool(restating) and not more` => `react = False`
  restate-with-news-fails: check_draft.py: `react = bool(restating) and not more` => `react = bool(restating)`
  extra-words-ignored: check_draft.py: `if extra:` => `if False:`
  bare-link-restates: check_draft.py: `if not said or not prs:` => `if not prs:`
  ask-restates: check_draft.py: `if "?" in rest or ASK.search(rest):` => `if "?" in rest:`
  question-restates: check_draft.py: `if "?" in rest or ASK.search(rest):` => `if ASK.search(rest):`
  restate-anyones-review: check_draft.py: `r = d["at_head"].get(me)` => `r = next(iter(d["at_head"].values()), None)`
  restate-any-head: check_draft.py: `r = d["at_head"].get(me)` => `r = d["standing"].get(me)`
  merged-not-restated: check_draft.py: `if not r and d.get("state") == "MERGED":` => `if False:`
  sha-is-news: check_draft.py: `r"|\b[0-9a-f]{7,40}\b", re.I)` => `r"", re.I)`
  merged-is-news: check_draft.py: `r"|\bmerged\b"` => `r""`
  ci-is-news: check_draft.py: `r"\bci\b|\bchecks?\b|\btests?\b|\bbuilds?\b|\bgreen\b|\bpass(?:es|ed|ing)?\b|"` => `r""`
  emoji-is-news: check_draft.py: `rest = EMOJI.sub(" ", rest)` => `pass`
  mention-is-news: check_draft.py: `MENTION.sub(" ", line)` => `line`
  react-on-reply-only: check_draft.py: `parents = sorted({args.reply, *args.answers}, key=ts_key) if args.reply else []` => `parents = [args.reply] if args.reply else []`
  ack-hardcoded: check_draft.py: `ack = cfg["slack"]["ack_reaction"]` => `ack = "white_check_mark"`
  ack-colons-kept: hub.py: `.strip(":")` => ``
  long-reply-ok: check_draft.py: `if args.reply and not react and words > REPLY_WORDS:` => `if False:`
  long-top-level-warned: check_draft.py: `if args.reply and not react and words > REPLY_WORDS:` => `if not react and words > REPLY_WORDS:`
"""
import contextlib
import io
import os
import unittest
from unittest import mock

from fakes import CONFIG, ME, Env, Fail, FakeGh, machine_zone

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

    def test_en_dash_fails(self):
        rc, out = self.check(f"Done {chr(0x2013)} thanks\n")
        self.assertEqual(rc, 1)
        self.assertIn("line 1: en dash", out)
        self.assertEqual(self.check("Done - thanks, 2-3 days\n")[0], 0, "a hyphen is fine")

    def test_more_token_shapes_fail(self):
        fakes = {"AWS temporary key": "ASIA" + "EXAMPLEEXAMPLE00",
                 "LaunchDarkly key": "sdk-00000000-0000-0000-0000-000000000000",
                 "PEM block": "-----BEGIN EXAMPLE PRIVATE KEY-----",
                 "key assignment": "api_key=examplevalue0000",
                 "token assignment": "token: 'example-token-0000'"}
        for name, fixture in fakes.items():
            rc, out = self.check(f"config has {fixture} in it\n")
            self.assertEqual(rc, 1, name)
            self.assertIn("no secrets", out, name)
        self.assertEqual(self.check("the key = retries; token count 3\n")[0], 0, "prose with the words is fine")

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

    def test_a_long_draft_fails_at_the_configured_cap(self):
        long = "word " * 520 + "\n"  # 2601 characters
        rc, out = self.check(long)
        self.assertEqual(rc, 1)
        self.assertIn("2601 characters, over the 2500 cap", out)
        with Env(config=CONFIG + "\n[slack.extra]\n") as env:
            env.config.write_text(env.config.read_text().replace('my_user_id = "user-me"', 'my_user_id = "user-me"\nmax_chars = 3000'))
            self.assertEqual(gate(env, long, "--top-level", gh=fake())[0], 0)

    def test_a_thin_bullet_fails(self):
        rc, out = self.check("Done:\n- fixed\n- retried the flaky job\n")
        self.assertEqual(rc, 1)
        self.assertIn("line 2: thin bullet 'fixed'", out)
        self.assertNotIn("line 3", out)
        self.assertEqual(self.check("1. fixed the retry loop\n* and the test\n")[0], 0)


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

    def test_an_ask_to_someone_who_reviewed_this_head_fails(self):
        approved = {**PR_JSON, "reviews": [review("Bob", "APPROVED")]}
        rc, out = self.check(f"could you review {LINK}?\n", "--asks", "bob", state=approved)
        self.assertEqual(rc, 1, out)
        self.assertIn("asks bob to review acme/app#12, which they already reviewed (APPROVED) 2026-10-21T16:50:00Z "
                      "at the current head", out)
        self.assertIn("approved-by=bob@abcdef1", out)
        commented = {**PR_JSON, "reviews": [{**review("bob", "COMMENTED"), "body": "two nits, see inline"}]}
        rc, out = self.check(f"could you review {LINK}?\n", "--asks", "bob", state=commented)
        self.assertEqual(rc, 1, "a comment review with a body is a review too: " + out)
        replied = {**PR_JSON, "reviews": [review("bob", "COMMENTED")]}  # body "": what a thread reply creates
        rc, out = self.check(f"could you review {LINK}?\n", "--asks", "bob", state=replied)
        self.assertEqual(rc, 0, "a thread reply is not a review: " + out)

    def test_the_addressee_comes_from_the_mention_and_the_config_map(self):
        cfg = CONFIG + '\n[slack.github_logins]\n"user-bob" = "bob"\n'
        reviewed = {**PR_JSON, "reviews": [{**review("bob", "COMMENTED"), "body": "one nit"}]}
        with Env(config=cfg) as env:
            rc, out = gate(env, f"<@user-bob> could you review {LINK}?\n", "--top-level", gh=fake(reviewed))
            self.assertEqual(rc, 1, out)
            self.assertIn("addressees: bob", out)
            self.assertIn("asks bob to review acme/app#12, which they already reviewed (COMMENTED)", out)
            rc, out = gate(env, f"<@user-zed> could you review {LINK}?\n", "--top-level", gh=fake(reviewed))
            self.assertEqual(rc, 1, out)
            self.assertIn("addressees: - (no slack.github_logins entry for <@user-zed>)", out)
            self.assertIn("name the addressee with --asks LOGIN", out)
            rc, out = gate(env, f"<@user-bob> could you review {LINK}?\n", "--top-level", gh=fake())
            self.assertEqual(rc, 0, "bob has not reviewed it: " + out)

    def test_another_reviewers_approval_does_not_fail_the_ask(self):
        other = {**PR_JSON, "reviews": [review("carol", "APPROVED")]}
        rc, out = self.check(f"could you review {LINK}?\n", "--asks", "bob", state=other)
        self.assertEqual(rc, 0, out)

    def test_an_approval_at_an_older_head_is_a_re_review_ask(self):
        moved = {**PR_JSON, "reviews": [review("bob", "APPROVED", oid="0123456789")]}
        rc, out = self.check(f"PTAL {LINK}, head moved.\n", "--asks", "bob", state=moved)
        self.assertEqual(rc, 0, out)
        changes = {**PR_JSON, "reviews": [review("bob", "CHANGES_REQUESTED", oid="0123456789")]}
        self.assertEqual(self.check(f"PTAL {LINK}\n", "--asks", "bob", state=changes)[0], 0, "a push since: re-review")

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


class Restates(unittest.TestCase):
    """A reply that only restates my own posted review becomes a reaction on the request."""
    PARENT = "1761040800.000100"
    LATER = "<https://github.com/acme/app/pull/13|acme/app#13>"

    def check(self, text, *reviews, state="OPEN", where=None, config=CONFIG):
        pr = {**PR_JSON, "state": state, "reviews": list(reviews)}
        with Env(config=config) as env:
            return gate(env, text, *(where or ("--reply", self.PARENT)), gh=fake(pr))

    def test_a_reply_that_only_restates_my_approval_becomes_a_reaction(self):
        mine = review(ME, "APPROVED")
        rc, out = self.check(f"Approved {LINK} at abcdef1, no asks. Thanks!\n", mine)
        self.assertEqual(rc, 1, out)
        self.assertIn(f"send: react white_check_mark on {self.PARENT}", out)
        self.assertNotIn("send: live", out)
        self.assertIn("FAIL: line 1 restates your review of acme/app#12 (APPROVED at abcdef1), which GitHub already "
                      "shows", out)
        rc, out = self.check(f"<@user-bob> {LINK}\n\nApproved at `abcdef1`, CI green :white_check_mark:\n", mine)
        self.assertEqual(rc, 1, "the PR on one line, the restatement on another: " + out)
        self.assertIn("FAIL: line 3 restates", out)
        rc, out = self.check(f"Approved {LINK}, no asks.\n", mine, where=("--top-level",))
        self.assertEqual(rc, 1, out)
        self.assertIn("send: react white_check_mark on the message that asked for each review; none in Slack: "
                      "drop it", out)

    def test_every_message_answered_gets_the_configured_reaction(self):
        older = "1761037200.000050"
        cfg = CONFIG.replace('my_user_id = "user-me"', 'my_user_id = "user-me"\nack_reaction = ":github-check-mark:"')
        rc, out = self.check(f"Approved {LINK}, no asks.\n", review(ME, "APPROVED"), config=cfg,
                             where=("--reply", self.PARENT, "--answers", self.PARENT, older))
        self.assertEqual(rc, 1, out)
        self.assertIn(f"send: react github-check-mark on {older} {self.PARENT}\n", out)

    def test_a_restatement_that_carries_more_passes(self):
        mine = review(ME, "APPROVED")
        rc, out = self.check(f"Approved {LINK} at abcdef1, no asks. Please merge it after {self.LATER}. Thanks!\n", mine)
        self.assertEqual(rc, 0, out)
        self.assertIn("send: live", out)
        self.assertNotIn("restates", out)
        rc, out = self.check(f"Approved {LINK}; good to go on your side?\n", mine)
        self.assertEqual(rc, 0, "a question: " + out)
        rc, out = self.check(f"Approved {LINK} at abcdef1, no asks.\nPlease merge it after {self.LATER}.\n", mine)
        self.assertEqual(rc, 0, out)
        self.assertIn("WARN: line 1 restates your review of acme/app#12 (APPROVED at abcdef1): cut it", out)
        self.assertIn("PASS", out)
        rc, out = self.check(f"Please merge these in order:\n1. {self.LATER}\n2. {LINK}\n", mine)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("restates", out, "a bare link says nothing either way")

    def test_an_ask_to_another_reviewer_is_left_to_the_ask_check(self):
        cfg = CONFIG + '\n[slack.github_logins]\n"user-bob" = "bob"\n'
        mine = review(ME, "APPROVED")
        rc, out = self.check(f"<@user-bob> please review {LINK} too, thanks\n", mine, config=cfg)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("restates", out)
        rc, out = self.check(f"<@user-bob> please review {LINK} too, thanks\n", mine, review("bob", "APPROVED"), config=cfg)
        self.assertEqual(rc, 1, out)
        self.assertIn("asks bob to review acme/app#12, which they already reviewed", out)
        self.assertIn("send: live", out)

    def test_without_a_review_of_mine_nothing_is_restated(self):
        for reviews in ([review("carol", "APPROVED")], [review(ME, "COMMENTED")], []):
            rc, out = self.check(f"Approved {LINK} at abcdef1, no asks.\n", *reviews)
            self.assertEqual(rc, 0, f"{reviews}: {out}")
            self.assertNotIn("restates", out)

    def test_my_approval_of_an_older_head_is_news(self):
        rc, out = self.check(f"Approved {LINK} at 0123456, no asks.\n", review(ME, "APPROVED", oid="0123456789"))
        self.assertEqual(rc, 0, out)
        self.assertNotIn("restates", out)

    def test_a_pr_merged_after_my_review_is_restated(self):
        rc, out = self.check(f"Approved {LINK}, merged. Thanks!\n", review(ME, "APPROVED", oid="0123456789"),
                             state="MERGED")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL: line 1 restates your review of acme/app#12 (APPROVED at 0123456)", out)


class Length(unittest.TestCase):
    def test_a_thread_reply_over_60_words_warns_and_still_passes(self):
        with Env() as env:
            rc, out = gate(env, " ".join(["word"] * 61) + "\n", "--reply", "1761040800.000100", gh=fake())
            self.assertEqual(rc, 0, out)
            self.assertIn("WARN: 61 words, over 60 for a thread reply", out)
            rc, out = gate(env, " ".join(["word"] * 60) + "\n", "--reply", "1761040800.000100", gh=fake())
            self.assertNotIn("WARN", out)
            rc, out = gate(env, " ".join(["word"] * 61) + "\n", "--top-level", gh=fake())
            self.assertNotIn("WARN", out, "a top-level message is not a reply to a request")


class SendMode(unittest.TestCase):
    def test_daytime_live_evening_schedules(self):
        with Env() as env:
            self.assertIn("send: live", gate(env, "ok\n", "--top-level", gh=fake())[1])
            rc, out = gate(env, "ok\n", "--top-level", gh=fake(), now=EVENING)
            self.assertIn("send: schedule post_at=2026-10-22T08:00:00-07:00", out)


class Scheduled(unittest.TestCase):
    def test_pending_scheduled_messages_are_listed_until_they_post(self):
        with Env() as env:
            rc, out = gate(env, "ok\n", "--top-level", gh=fake(), now=EVENING)
            self.assertIn("send: schedule", out)
            self.assertEqual(gate(env, None, "--record-sent", "Q0001", now=EVENING)[0], 0)
            rc, out = gate(env, None, "--scheduled", now="2026-10-22T14:00:00+00:00")  # 07:00 there
            self.assertEqual(rc, 0, out)
            self.assertIn("scheduled: 1 pending", out)
            self.assertIn(f"Q0001 post_at=2026-10-22T08:00:00-07:00 target=top-level copy={env.state}/sent/2026-10-21/Q0001.md", out)
            rc, out = gate(env, None, "--scheduled", now="2026-10-22T15:30:00+00:00")  # 08:30, posted
            self.assertIn("scheduled: 0 pending", out)


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
