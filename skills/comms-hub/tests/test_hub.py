r"""hub.py: standing reviews, the CI verdict, the gh runner, quiet hours, config, active hours.

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
  placeholders-unnamed: hub.py: `raise ConfigError(f"{path}: still {PLACEHOLDER}: {', '.join(left)}")` => `raise ConfigError(f"{path}: still {PLACEHOLDER}")`
  init-overwrites: hub.py: `if path.exists():` => `if False:`
  init-login-unfilled: hub.py: `text = (text.replace(f'login = "{PLACEHOLDER}"', f'login = "{login}"', 1)` => `text = (text`
  init-tz-unfilled: hub.py: `text = text.replace(f'tz = "{PLACEHOLDER}"', f'tz = "{tz}"', 1)` => `pass`
  zone-unvalidated: hub.py: `and _valid_zone(n):` => `and True:`
  job-tmp-ignored: hub.py: `if os.environ.get("CLAUDE_JOB_DIR"):` => `if False:`
  log-machine-zone: hub.py: `stamp = local_now(cfg)` => `stamp = now().astimezone()`
  local-now-machine: hub.py: `return t.astimezone(zone(cfg)) if` => `return t.astimezone() if`
  thread-search-dropped: hub.py: `f"with:<@{uid}> is:thread {day}"` => `f"with:<@{uid}> {day}"`
  to-search-dropped: hub.py: `f"to:<@{uid}> {day}", ` => ``
  queries-today: hub.py: `local_now(cfg).date() - dt.timedelta(days=2)` => `local_now(cfg).date()`
  route-keys-unset: hub.py: `for k in ("repos", "tickets", "channels"):` => `for k in ():`
  morning-never: hub.py: `return prev < end <= at` => `return False`
  morning-every-tick: hub.py: `return prev < end <= at` => `return True`
  routed-today-only: hub.py: `for back in range(days):` => `for back in range(1):`
  routed-any-line: hub.py: `if text in line]` => `if True]`
  known-bots-ignored: hub.py: `or name.lower() in KNOWN_BOTS` => `or False`
  feedback-undated: hub.py: `f.write(f"- {local_now(cfg):%Y-%m-%d %H:%M} {text}\n")` => `f.write(f"- {text}\n")`
  weekend-ticks: hub.py: `days = sorted((DAYS.index(d) + 1) % 7 for d in a["days"])` => `days = list(range(7))`
  close-hour-ticks: hub.py: `int(a["end"][:2]) - 1` => `int(a["end"][:2])`
  window-every-day: hub.py: `workday = lambda d: DAYS[d.weekday()] in a["days"]` => `workday = lambda d: True`
  window-margin-ignored: hub.py: `if close - at < dt.timedelta(minutes=margin):` => `if False:`
  review-margin-ignored: hub.py: `margin = cfg["active_hours"]["review_margin_minutes"] if args.review else args.margin` => `margin = args.margin`
  full-scan-not-daily: hub.py: `if last is None or last < opened or` => `if last is None or`
  full-scan-never-due: hub.py: `or at - last >= dt.timedelta(minutes=a["full_scan_minutes"]):` => `:`
  trigger-never-renewed: hub.py: `elif at - created >= dt.timedelta(days=TRIGGER_RENEW_DAYS):` => `elif False:`
  live-trigger-unchecked: hub.py: `if live is not None and " ".join(live.split()) != want:` => `if False:`
  trigger-zone-unchecked: hub.py: `if at.astimezone().utcoffset() != at.astimezone(tz).utcoffset():` => `if False:`
  created-expr-unchecked: hub.py: `elif rec.get("expr") != want:` => `elif False:`
  launch-any-window: hub.py: `if have is None or have > int(want):` => `if have is None:`
  days-unvalidated: hub.py: `or any(d not in DAYS for d in a["days"]):` => `or False:`
  mid-hour-window: hub.py: `if not re.fullmatch(r"([01]\d|2[0-3]):00|24:00", str(a[k]))` => `if False`
  cadence-unvalidated: hub.py: `if a["every_minutes"] not in CADENCES:` => `if False:`
"""
import contextlib
import datetime as dt
import io
import os
import re
import stat
import subprocess
import unittest
from unittest import mock

from fakes import BIN, CONFIG, Env, Fail, FakeGh, actor, machine_zone

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

    def test_a_login_in_github_bots_is_a_bot(self):
        with Env(config=CONFIG.replace('merged_days = 7', 'merged_days = 7\nbots = ["Renovate-Runner"]')):
            hub.load_config()
            self.assertTrue(hub.is_bot(actor("renovate-runner")))
            self.assertFalse(hub.is_bot(actor("bob")))
        with Env():
            hub.load_config()
            self.assertFalse(hub.is_bot(actor("renovate-runner")), "the list is the config's, not sticky")
            self.assertTrue(hub.is_bot(actor("ci[bot]")))

    def test_my_login_matches_whatever_its_case(self):
        self.assertTrue(hub.is_me(actor("OctoCat"), "octocat"))
        self.assertFalse(hub.is_me(None, "octocat"))
        self.assertFalse(hub.is_me(actor("bob"), "octocat"))


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

    def test_the_first_tick_after_quiet_hours_is_the_morning_one(self):
        t = dt.datetime.fromisoformat
        morning = t("2026-10-22T08:07:00-07:00")
        self.assertTrue(hub.first_tick_after_quiet(self.cfg, t("2026-10-22T07:37:00-07:00"), morning))
        self.assertTrue(hub.first_tick_after_quiet(self.cfg, t("2026-10-21T18:37:00-07:00"), morning), "slept all night")
        self.assertFalse(hub.first_tick_after_quiet(self.cfg, t("2026-10-22T08:07:00-07:00"), t("2026-10-22T08:37:00-07:00")))
        self.assertFalse(hub.first_tick_after_quiet(self.cfg, t("2026-10-22T06:37:00-07:00"), t("2026-10-22T07:07:00-07:00")),
                         "still quiet")
        self.assertFalse(hub.first_tick_after_quiet(self.cfg, None, morning))

    def test_the_log_day_is_the_configured_zones_not_the_machines(self):
        # 17:00 UTC on 2026-10-21 is 10:00 that day in Los Angeles and 06:00 the next in Auckland.
        cfg = CONFIG.replace('tz = "America/Los_Angeles"', 'tz = "Pacific/Auckland"')
        with Env(config=cfg, now="2026-10-21T17:00:00Z"), machine_zone("America/Los_Angeles"):
            p = hub.append_log(hub.load_config(), "scan started")
            self.assertEqual((p.name, p.read_text()), ("2026-10-22.md", "- 06:00 scan started\n"))


class Config(unittest.TestCase):
    def test_defaults_and_required_keys(self):
        with Env():
            cfg = hub.load_config()
            self.assertEqual(cfg["github"]["merged_days"], 7)
        with Env(config='[github]\nlogin = "x"\n'):
            with self.assertRaisesRegex(hub.ConfigError, "owners"):
                hub.load_config()

    def test_a_placeholder_left_in_is_named(self):
        with Env(config='[github]\nlogin = "CHANGE-ME"\nowners = ["CHANGE-ME", "CHANGE-ME"]\n[slack]\nmy_user_id = "CHANGE-ME"\n'):
            with self.assertRaisesRegex(hub.ConfigError, "still CHANGE-ME: github.login, github.owners, slack.my_user_id$"):
                hub.load_config()

    def test_a_missing_config_names_init_and_the_example(self):
        with Env() as env:
            env.config.unlink()
            with self.assertRaisesRegex(hub.ConfigError, r"hub\.py init` writes one from .*config\.example\.toml"):
                hub.load_config()

    def test_the_example_loads_once_filled_in(self):
        example = (BIN.parent / "config.example.toml").read_text()
        with Env(config=example):
            with self.assertRaisesRegex(hub.ConfigError, "CHANGE-ME"):
                hub.load_config()
        filled = example.replace('tz = "CHANGE-ME"', 'tz = "Europe/Berlin"').replace("CHANGE-ME", "x")
        with Env(config=filled):
            self.assertEqual(hub.load_config()["routing"], [], "the routing table ships commented out")
        with Env(config=re.sub(r"(?m)^# (\[\[routing\]\]|session|repos|tickets|channels)", r"\1", filled)):
            cfg = hub.load_config()
            self.assertEqual((cfg["routing"][0]["session"], cfg["routing"][0]["repos"], cfg["routing"][0]["channels"]),
                             ("x", ["x"], []))

    def test_a_route_without_channels_or_tickets_gets_empty_lists(self):
        out = io.StringIO()
        with Env(config=CONFIG + '[[routing]]\nsession = "app-session"\nrepos = ["acme/app"]\n'), \
                contextlib.redirect_stdout(out):
            cfg = hub.load_config()
            self.assertEqual((cfg["routing"][0]["tickets"], cfg["routing"][0]["channels"]), ([], []))
            self.assertEqual(hub.main(["config"]), 0)
        self.assertIn("route: app-session repos=acme/app tickets=- channels=-", out.getvalue().splitlines())

    def test_config_prints_the_ids_and_the_tmp_dir(self):
        out = io.StringIO()
        with Env() as env, mock.patch.dict(os.environ, {"CLAUDE_JOB_DIR": str(env.dir / "job")}), \
                contextlib.redirect_stdout(out):
            self.assertEqual(hub.main(["config"]), 0)
            lines = out.getvalue().splitlines()
            self.assertIn(f"tmp: {env.dir / 'job' / 'tmp'}", lines)
            self.assertIn("slack: primary_dm=dm-primary my_user_id=user-me watched=chan-one", lines)
            self.assertIn("bots: - max_chars: slack=2500 review=2500", lines)
            self.assertIn("quiet: 19:00 to 08:00 America/Los_Angeles", lines)

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


class MentionQueries(unittest.TestCase):
    def test_three_searches_dated_two_days_back_in_the_configured_zone(self):
        # 03:00 UTC on the 22nd is still the 21st in Los Angeles: two days back is the 19th.
        out = io.StringIO()
        with Env(now="2026-10-22T03:00:00Z"), contextlib.redirect_stdout(out):
            self.assertEqual(hub.main(["queries"]), 0)
        self.assertEqual(out.getvalue().splitlines(), [
            "<@user-me> after:2026-10-19", "to:<@user-me> after:2026-10-19",
            "with:<@user-me> is:thread after:2026-10-19"])


class Feedback(unittest.TestCase):
    def test_a_correction_is_appended_dated_in_the_configured_zone(self):
        with Env(now="2026-10-21T17:00:00Z") as env, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(hub.main(["feedback", "no 'quick' in a status line"]), 0)
            self.assertEqual(hub.main(["feedback", "lead with the ask"]), 0)
            self.assertEqual((env.state / "feedback.md").read_text(),
                             "- 2026-10-21 10:00 no 'quick' in a status line\n- 2026-10-21 10:00 lead with the ask\n")


class Routed(unittest.TestCase):
    def test_finds_what_the_last_two_days_logged_and_nothing_else(self):
        link = "https://github.com/acme/app/pull/12"
        with Env(now="2026-10-21T17:00:00Z") as env:
            (env.state / "log").mkdir(parents=True)
            (env.state / "log" / "2026-10-20.md").write_text(f"- 16:10 routed {link} to app-session\n- 16:11 held a draft\n")
            (env.state / "log" / "2026-10-18.md").write_text(f"- 09:00 routed {link} to app-session\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = hub.main(["routed", link])
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().splitlines(),
                             [f"2026-10-20 - 16:10 routed {link} to app-session",
                              f"routed: 1 line(s) in the last 2 days mention '{link}'"])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hub.main(["routed", "acme/app#99"]), 1)


class TmpDir(unittest.TestCase):
    def test_job_tmp_when_claude_code_set_one_else_under_state(self):
        with Env() as env:
            with mock.patch.dict(os.environ, {"CLAUDE_JOB_DIR": str(env.dir / "job")}):
                self.assertEqual(hub.tmp_dir(hub.load_config()), env.dir / "job" / "tmp")
            os.environ.pop("CLAUDE_JOB_DIR", None)
            d = hub.tmp_dir(hub.load_config())
            self.assertEqual(d, env.state / "tmp")
            self.assertTrue(d.is_dir())


class SystemZone(unittest.TestCase):
    def zone(self, tz, localtime, timezone=OSError()):
        with mock.patch.dict(os.environ, {"TZ": tz}), mock.patch("os.path.realpath", return_value=localtime), \
                mock.patch.object(hub.Path, "read_text", side_effect=[timezone]):
            return hub.system_zone()

    def test_tz_then_localtime_link_then_etc_timezone(self):
        self.assertEqual(self.zone("Asia/Tokyo", "/usr/share/zoneinfo/Europe/Berlin"), "Asia/Tokyo")
        self.assertEqual(self.zone("", "/var/db/timezone/zoneinfo/Europe/Berlin"), "Europe/Berlin")
        self.assertEqual(self.zone("", "/etc/localtime", "Europe/Berlin\n"), "Europe/Berlin")
        self.assertIsNone(self.zone("", "/etc/localtime"), "a copied /etc/localtime has no name")

    def test_a_name_that_is_not_a_zone_is_skipped(self):
        self.assertEqual(self.zone("Mars/Olympus", "/usr/share/zoneinfo/Europe/Berlin"), "Europe/Berlin")
        self.assertEqual(self.zone("EST5EDT", "/usr/share/zoneinfo/Europe/Berlin"), "Europe/Berlin")


class Init(unittest.TestCase):
    def run_init(self, gh=None, zone="Europe/Berlin"):
        out = io.StringIO()
        gh = hub.Gh(runner=gh or FakeGh(rest={"user": {"login": "octocat"}}), pause=0)
        with mock.patch("hub.system_zone", return_value=zone), contextlib.redirect_stdout(out):
            rc = hub.main(["init"], gh=gh)
        return rc, out.getvalue()

    def test_writes_the_example_with_login_owners_and_zone_filled(self):
        with Env() as env:
            env.config.unlink()
            rc, out = self.run_init()
            self.assertEqual(rc, 0, out)
            text = env.config.read_text()
            for line in ('login = "octocat"', 'owners = ["octocat"]', 'tz = "Europe/Berlin"'):
                self.assertIn(line, text)
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)
            self.assertIn(f"wrote {env.config}", out)
            self.assertIn("still CHANGE-ME, fill in by hand: slack.primary_dm, slack.my_user_id", out)
            with self.assertRaisesRegex(hub.ConfigError, "slack.primary_dm, slack.my_user_id"):
                hub.load_config()
            env.config.write_text(text.replace("CHANGE-ME", "x"))
            self.assertEqual(hub.load_config()["github"]["login"], "octocat")

    def test_refuses_an_existing_config(self):
        with Env() as env:
            before = env.config.read_text()
            rc, out = self.run_init()
            self.assertEqual(rc, 1)
            self.assertIn(f"refusing: {env.config} exists", out)
            self.assertEqual(env.config.read_text(), before)

    def test_gh_or_the_zone_unknown_leaves_the_placeholder_and_says_so(self):
        with Env() as env:
            env.config.unlink()
            rc, out = self.run_init(gh=FakeGh(rest={"user": [Fail(), Fail()]}), zone=None)
            self.assertEqual(rc, 0, out)
            self.assertIn("github.login: not read from gh", out)
            self.assertIn("still CHANGE-ME, fill in by hand: github.login, github.owners, slack.primary_dm, "
                          "slack.my_user_id, quiet_hours.tz", out)
            self.assertIn('login = "CHANGE-ME"', env.config.read_text())


def at(s):
    return dt.datetime.fromisoformat(s)


def main_out(*argv, now=None):
    out = io.StringIO()
    env = {"COMMS_HUB_NOW": now} if now else {}
    with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out):
        rc = hub.main(list(argv))
    return rc, out.getvalue()


class ActiveHours(unittest.TestCase):
    def cfg(self, extra=""):
        with Env(config=CONFIG + extra):
            return hub.load_config()

    def test_the_default_trigger_skips_weekends_and_nights(self):
        self.assertEqual(hub.cron(self.cfg()), "7,37 8-17 * * 1-5")

    def test_the_trigger_follows_the_config(self):
        c = self.cfg('\n[active_hours]\ndays = ["Mon", "Tue", "Wed", "Fri", "Sun"]\nstart = "09:00"\n'
                     'end = "10:00"\nevery_minutes = 15\n')
        self.assertEqual(hub.cron(c), "7,22,37,52 9 * * 0-3,5")

    def test_bad_active_hours_are_refused_by_name(self):
        for extra, key in (('days = "Mon-Fri"', "days"), ('days = ["Funday"]', "days"), ("days = []", "days"),
                           ('start = "08:30"', "start"), ('end = "07:00"', "start"),
                           ("every_minutes = 25", "every_minutes")):
            with Env(config=CONFIG + "\n[active_hours]\n" + extra + "\n"):
                with self.assertRaisesRegex(hub.ConfigError, "active_hours." + key):
                    hub.load_config()
        with Env(config=CONFIG + "\n[session]\ncompact_window = 50000\n"):
            with self.assertRaisesRegex(hub.ConfigError, "session.compact_window"):
                hub.load_config()

    def test_the_window_is_closed_on_weekends_and_nights(self):
        c = self.cfg()
        monday = at("2026-10-26T08:00:00-07:00")
        self.assertEqual(hub.window(c, at("2026-10-24T10:00:00-07:00")), (None, monday), "Saturday")
        self.assertEqual(hub.window(c, at("2026-10-23T18:00:00-07:00")), (None, monday), "Friday at close")
        self.assertEqual(hub.window(c, at("2026-10-26T07:59:00-07:00")), (None, monday), "Monday before start")
        self.assertEqual(hub.window(c, at("2026-10-26T08:00:00-07:00")), (at("2026-10-26T18:00:00-07:00"), None))
        self.assertEqual(hub.window(c, at("2026-10-27T03:00:00+00:00")), (None, at("2026-10-27T08:00:00-07:00")),
                         "20:00 Monday, read in the config's zone")

    def test_window_exits_1_when_closed_or_closing(self):
        with Env():
            self.assertEqual(main_out("window", now="2026-10-24T10:00:00-07:00")[0], 1)
            rc, out = main_out("window", "--margin", "120", now="2026-10-26T16:30:00-07:00")
            self.assertEqual((rc, out.strip()), (1, "window: closing at 18:00, within 120 min"))
            self.assertEqual(main_out("window", "--review", now="2026-10-26T16:30:00-07:00")[0], 1,
                             "--review uses review_margin_minutes")
            rc, out = main_out("window", "--margin", "120", now="2026-10-26T15:30:00-07:00")
            self.assertEqual(rc, 0)
            self.assertIn("window: open until 18:00", out)
            self.assertIn("scan: full (the window's first)", out)

    def test_a_full_scan_opens_each_day_and_recurs(self):
        with Env():
            c = hub.load_config()
            self.assertEqual(hub.scan_plan(c, at("2026-10-26T08:07:00-07:00")), "full", "nothing recorded")
            main_out("window", "--full-done", now="2026-10-26T08:10:00-07:00")
            self.assertEqual(hub.scan_plan(c, at("2026-10-26T08:37:00-07:00")), "quick")
            self.assertEqual(hub.scan_plan(c, at("2026-10-26T10:11:00-07:00")), "full", "two hours on")
            self.assertEqual(hub.scan_plan(c, at("2026-10-27T08:07:00-07:00")), "full", "the next day's first tick")
        with Env(config=CONFIG + "\n[active_hours]\nfull_scan_minutes = 2000\n"):
            c = hub.load_config()
            main_out("window", "--full-done", now="2026-10-26T17:37:00-07:00")
            self.assertEqual(hub.scan_plan(c, at("2026-10-26T17:50:00-07:00")), "quick")
            self.assertEqual(hub.scan_plan(c, at("2026-10-27T08:07:00-07:00")), "full",
                             "the window's first tick is full however long full_scan_minutes is")

    def test_the_trigger_is_checked_against_the_config_and_its_age(self):
        with Env(), machine_zone("America/Los_Angeles"):
            c = hub.load_config()
            t0 = at("2026-10-19T08:00:00-07:00")
            self.assertTrue(hub.trigger_problems(c, t0)[0].startswith("NONE"))
            self.assertEqual(main_out("trigger", "--created", "7,37  8-17 * * 1-5", now=t0.isoformat())[0], 0)
            self.assertEqual(hub.trigger_problems(c, at("2026-10-24T08:00:00-07:00"), "7,37 8-17 * * 1-5"), [])
            live = hub.trigger_problems(c, at("2026-10-24T08:00:00-07:00"), "*/15 * * * *")
            self.assertEqual(len(live), 1)
            self.assertIn("MISMATCH: the live trigger is '*/15 * * * *'", live[0])
            renew = hub.trigger_problems(c, at("2026-10-25T08:00:00-07:00"))
            self.assertEqual(len(renew), 1)
            self.assertTrue(renew[0].startswith("RENEW: created 2026-10-19"), renew)
            self.assertEqual(main_out("trigger", "--created", "7,37 * * * *", now=t0.isoformat())[0], 1)
            self.assertIn("created as '7,37 * * * *'", hub.trigger_problems(c, t0)[0])

    def test_a_machine_in_another_zone_is_named(self):
        with Env(), machine_zone("UTC"):
            c = hub.load_config()
            zone = [p for p in hub.trigger_problems(c, at("2026-10-26T08:00:00-07:00")) if p.startswith("ZONE")]
            self.assertEqual(len(zone), 1)
            self.assertIn("UTC+0000", zone[0])

    def test_the_launch_check_wants_the_small_window_and_a_timeout(self):
        c = self.cfg()
        ok = {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "150k", "MCP_TOOL_TIMEOUT": "60000"}
        self.assertEqual(hub.launch_problems(c, ok), [])
        self.assertEqual(len(hub.launch_problems(c, {**ok, "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "600000"})), 1)
        self.assertEqual(len(hub.launch_problems(c, {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "150000"})), 1)
        with Env():
            rc, out = main_out("launch")
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "claude --settings '{\"env\":{\"CLAUDE_CODE_AUTO_COMPACT_WINDOW\":\"150000\","
                                      "\"MCP_TOOL_TIMEOUT\":\"120000\"}}'")


if __name__ == "__main__":
    unittest.main()
