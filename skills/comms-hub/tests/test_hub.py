r"""hub.py: standing reviews, the CI verdict, the gh runner, quiet hours, config.

Mutations (run.py --mutate applies each and expects this file to fail):
  commented-revokes: hub.py: `if r.get("state") in ("COMMENTED", "PENDING"):` => `if r.get("state") in ("PENDING",):`
  first-review-wins: hub.py: `key=lambda r: r.get("submittedAt") or ""` => `key=lambda r: r.get("submittedAt") or "", reverse=True`
  cancelled-green: hub.py: `GREEN = ("SUCCESS", "NEUTRAL", "SKIPPED")` => `GREEN = ("SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED")`
  first-run-wins: hub.py: `if name not in latest or started >= latest[name][0]:` => `if name not in latest:`
  no-retry: hub.py: `for attempt in range(self.retries + 1):` => `for attempt in range(1):`
  no-timeout: hub.py: `p = self.runner(args, self.timeout)` => `p = self.runner(args, None)`
  quiet-never: hub.py: `if not quiet:` => `if True:`
  next-day-always: hub.py: `day = local.date() if t < post else` => `day = local.date() if False else`
  placeholders-ok: hub.py: `if left:` => `if False:`
  tz-optional: hub.py: `if not q.get("tz"):` => `if False:`
  bad-time-ok: hub.py: `dt.time.fromisoformat(q[k])` => `pass`
  queued-hidden: hub.py: `started = started or "~"  # queued, not started: newer than any run that has` => `pass`
  case-sensitive-me: hub.py: `return (login(actor) or "").lower() == me.lower()` => `return login(actor) == me`
"""
import datetime as dt
import subprocess
import unittest

from fakes import BIN, Env, Fail, FakeGh, actor

import hub


def review(who, state, at, oid="h1"):
    return {"author": actor(who), "state": state, "submittedAt": at, "commit": {"oid": oid}}


class StandingReviews(unittest.TestCase):
    def test_commented_after_approval_keeps_it(self):
        s = hub.standing_reviews([review("bob", "APPROVED", "2026-10-01T10:00:00Z"),
                                  review("bob", "COMMENTED", "2026-10-02T10:00:00Z")])
        self.assertEqual(s["bob"]["state"], "APPROVED")

    def test_later_changes_requested_revokes(self):
        s = hub.standing_reviews([review("bob", "APPROVED", "2026-10-01T10:00:00Z"),
                                  review("bob", "CHANGES_REQUESTED", "2026-10-02T10:00:00Z")])
        self.assertEqual(s["bob"]["state"], "CHANGES_REQUESTED")

    def test_order_is_by_time_not_by_list_position(self):
        s = hub.standing_reviews([review("bob", "APPROVED", "2026-10-03T10:00:00Z"),
                                  review("bob", "CHANGES_REQUESTED", "2026-10-02T10:00:00Z")])
        self.assertEqual(s["bob"]["state"], "APPROVED")

    def test_comment_only_reviewer_has_no_standing(self):
        self.assertNotIn("bob", hub.standing_reviews([review("bob", "COMMENTED", "2026-10-01T10:00:00Z")]))

    def test_my_login_matches_whatever_its_case(self):
        self.assertTrue(hub.is_me(actor("AdityaR"), "adityar"))
        self.assertFalse(hub.is_me(None, "adityar"))
        self.assertFalse(hub.is_me(actor("bob"), "adityar"))


def run(name, conclusion, start, status="COMPLETED"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion, "startedAt": start}


class Ci(unittest.TestCase):
    def test_cancelled_superseded_by_success_is_green(self):
        self.assertEqual(hub.ci_summary([run("t", "CANCELLED", "2026-10-01T10:00:00Z"),
                                         run("t", "SUCCESS", "2026-10-01T10:05:00Z")]), ("green", []))

    def test_lone_cancelled_is_red(self):
        self.assertEqual(hub.ci_summary([run("t", "CANCELLED", "2026-10-01T10:00:00Z"),
                                         run("u", "SUCCESS", "2026-10-01T10:00:00Z")]), ("red", ["t"]))

    def test_latest_by_start_time_decides(self):
        self.assertEqual(hub.ci_summary([run("t", "SUCCESS", "2026-10-01T10:05:00Z"),
                                         run("t", "FAILURE", "2026-10-01T10:00:00Z")])[0], "green")
        self.assertEqual(hub.ci_summary([run("t", "SUCCESS", "2026-10-01T10:00:00Z"),
                                         run("t", "FAILURE", "2026-10-01T10:05:00Z")])[0], "red")

    def test_a_queued_rerun_is_not_masked_by_the_earlier_success(self):
        queued = {"__typename": "CheckRun", "name": "t", "status": "QUEUED", "conclusion": None, "startedAt": None}
        self.assertEqual(hub.ci_summary([run("t", "SUCCESS", "2026-10-01T10:00:00Z"), queued]), ("pending", ["t"]))

    def test_in_progress_is_pending_and_status_contexts_count(self):
        self.assertEqual(hub.ci_summary([run("t", None, "2026-10-01T10:00:00Z", status="IN_PROGRESS")])[0], "pending")
        self.assertEqual(hub.ci_summary([{"__typename": "StatusContext", "context": "s", "state": "ERROR",
                                          "createdAt": "2026-10-01T10:00:00Z"}]), ("red", ["s"]))
        self.assertEqual(hub.ci_summary([]), ("none", []))


class GhRunner(unittest.TestCase):
    def test_one_retry_after_a_timeout(self):
        seen = []

        def runner(args, timeout):
            seen.append(timeout)
            if len(seen) == 1:
                raise subprocess.TimeoutExpired(args, timeout)
            return subprocess.CompletedProcess(args, 0, "{}", "")
        self.assertEqual(hub.Gh(runner=runner, pause=0).json(["api", "x"]), {})
        self.assertEqual(seen, [45, 45], "every call carries the timeout")

    def test_two_failures_raise(self):
        fake = FakeGh(rest={"rate_limit": [Fail(), Fail()]})
        with self.assertRaises(hub.GhError):
            hub.Gh(runner=fake, pause=0).json(["api", "rate_limit"])
        self.assertEqual(len(fake.calls), 2)


class QuietHours(unittest.TestCase):
    cfg = {"quiet_hours": {"start": "19:00", "post_at": "08:00", "tz": "America/Los_Angeles"}}

    def at(self, s):
        return hub.send_plan(self.cfg, dt.datetime.fromisoformat(s))

    def test_daytime_is_live(self):
        self.assertEqual(self.at("2026-10-21T12:00:00-07:00"), ("live", None))

    def test_evening_schedules_next_morning(self):
        mode, post = self.at("2026-10-21T20:30:00-07:00")
        self.assertEqual((mode, post.isoformat()), ("schedule", "2026-10-22T08:00:00-07:00"))

    def test_small_hours_schedule_the_same_morning(self):
        mode, post = self.at("2026-10-22T02:00:00-07:00")
        self.assertEqual((mode, post.isoformat()), ("schedule", "2026-10-22T08:00:00-07:00"))


class Config(unittest.TestCase):
    def test_defaults_and_required_keys(self):
        with Env():
            cfg = hub.load_config()
            self.assertEqual(cfg["github"]["merged_days"], 7)
        with Env(config='[github]\nlogin = "x"\n'):
            with self.assertRaisesRegex(hub.ConfigError, "owners"):
                hub.load_config()

    def test_a_placeholder_left_in_is_an_error(self):
        with Env(config='[github]\nlogin = "CHANGE-ME"\nowners = ["a"]\n'):
            with self.assertRaisesRegex(hub.ConfigError, "CHANGE-ME"):
                hub.load_config()

    def test_the_example_loads_once_filled_in(self):
        example = (BIN.parent / "config.example.toml").read_text()
        with Env(config=example):
            with self.assertRaisesRegex(hub.ConfigError, "CHANGE-ME"):
                hub.load_config()
        with Env(config=example.replace('tz = "CHANGE-ME"', 'tz = "Europe/Berlin"').replace("CHANGE-ME", "x")):
            cfg = hub.load_config()
            self.assertEqual(cfg["routing"][0]["session"], "x")

    def test_a_zone_is_required_and_times_must_exist(self):
        base = '[github]\nlogin = "x"\nowners = ["a"]\n[quiet_hours]\n'
        with Env(config=base):
            with self.assertRaisesRegex(hub.ConfigError, "tz is required"):
                hub.load_config()
        with Env(config=base + 'tz = "Europe/Berlin"\nstart = "25:99"\n'):
            with self.assertRaisesRegex(hub.ConfigError, "HH:MM"):
                hub.load_config()

    def test_a_bad_zone_is_a_config_error(self):
        with Env(config='[github]\nlogin = "x"\nowners = ["a"]\n[quiet_hours]\ntz = "Mars/Olympus"\n'):
            with self.assertRaisesRegex(hub.ConfigError, "IANA"):
                hub.load_config()


if __name__ == "__main__":
    unittest.main()
