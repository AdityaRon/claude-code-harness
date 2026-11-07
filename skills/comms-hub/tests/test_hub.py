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
  weekend-post: hub.py: `while DAYS[day.weekday()] not in cfg["active_hours"]["days"]:` => `while False:`
  post-before-tick-ok: hub.py: `if q["post_at"] <= first:` => `if False:`
  first-tick-on-the-hour: hub.py: `first = f"{a['start'][:2]}:{TICK_MINUTE:02d}"` => `first = a["start"]`
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
  log-machine-zone: hub.py: `    stamp = local_now(cfg)
    p = d / f"{stamp:%Y-%m-%d}.md"` => `    stamp = now().astimezone()
    p = d / f"{stamp:%Y-%m-%d}.md"`
  local-now-machine: hub.py: `return t.astimezone(zone(cfg)) if` => `return t.astimezone() if`
  thread-search-dropped: hub.py: `f"with:<@{uid}> is:thread {day}"` => `f"with:<@{uid}> {day}"`
  to-search-dropped: hub.py: `f"to:<@{uid}> {day}", ` => ``
  queries-today: hub.py: `local_now(cfg).date() - dt.timedelta(days=2)` => `local_now(cfg).date()`
  route-keys-unset: hub.py: `for k in ("repos", "tickets", "channels"):` => `for k in ():`
  morning-never: hub.py: `return prev < end <= at` => `return False`
  morning-every-tick: hub.py: `return prev < end <= at` => `return True`
  routed-today-only: hub.py: `for back in range(days):` => `for back in range(1):`
  routed-any-line: hub.py: `if any(n in line for n in needles)]` => `if True]`
  routed-text-only: hub.py: `needles = [n for ts in slack_ts(text) for n in (ts, "p" + ts.replace(".", ""))] or [text]` => `needles = [text]`
  routed-dotted-only: hub.py: `for n in (ts, "p" + ts.replace(".", ""))` => `for n in (ts,)`
  routed-p-only: hub.py: `for n in (ts, "p" + ts.replace(".", ""))` => `for n in ("p" + ts.replace(".", ""),)`
  p-path-ignored: hub.py: `found = [f"{a}.{b}" for a, b in _P_TS.findall(text)] + _DOTTED_TS` => `found = _DOTTED_TS`
  thread-of-a-reply-ignored: hub.py: `found = [f"{a}.{b}" for a, b in _P_TS.findall(text)] + _DOTTED_TS.findall(text)` => `found = [f"{a}.{b}" for a, b in _P_TS.findall(text)] or _DOTTED_TS.findall(text)`
  owner-never-expires: hub.py: `return isinstance(v, dict) and (parse_time(v.get("at")) or cutoff) > cutoff` => `return isinstance(v, dict)`
  owner-unprinted: hub.py: `owner = thread_owner(cfg, text)` => `owner = None`
  owner-any-ts: hub.py: `not re.fullmatch(r"\d{10}\.\d{6}", argv[2]) or ` => `False or `
  reach-from-full-scan: hub.py: `last = parse_time(_record(cfg, "tick.json").get("mentions"))` => `last = parse_time(_record(cfg, "tick.json").get("full"))`
  reach-no-overlap: hub.py: `return last - REACH_OVERLAP` => `return last`
  reach-default-today: hub.py: `day = at.astimezone(zone(cfg)).date() - dt.timedelta(days=1)` => `day = at.astimezone(zone(cfg)).date()`
  reach-short-recorded: hub.py: `dt.timezone.utc)] if t > reach]` => `dt.timezone.utc)] if False]`
  reach-thread-ts: hub.py: `m = _P_TS.search(hit)` => `m = re.search(r"thread_ts=(\d{10})\.(\d{6})", hit) or _P_TS.search(hit)`
  reach-future-ok: hub.py: `or started > now() + dt.timedelta(minutes=1)` => ``
  since-ignores-reach: hub.py: `return min(local_now(cfg).date() - dt.timedelta(days=2), reach.astimezone(zone(cfg)).date() - dt.timedelta(days=1))` => `return local_now(cfg).date() - dt.timedelta(days=2)`
  routed-two-days: hub.py: `def routed(cfg: dict, text: str, days: int = OPEN_DAYS)` => `def routed(cfg: dict, text: str, days: int = 2)`
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
  launch-any-window: hub.py: `if have is None or (have != int(want) if exact else have > int(want)):` => `if have is None:`
  launch-smaller-window-ok: hub.py: `have != int(want) if exact else` => `have > int(want) if exact else`
  room-unwarned: hub.py: `if window - base < ROOM_MIN:` => `if False:`
  baseline-of-the-first-compaction: hub.py: `count, base, when, after = count + 1, None, d.get("timestamp") or "", True` => `count, base, when, after = count + 1, base, when or d.get("timestamp") or "", base is None`
  subagent-transcript-counts: hub.py: `root.glob("*/*.jsonl")` => `root.glob("**/*.jsonl")`
  quoted-prompt-counts: hub.py: `if d.get("type") == "user" and isinstance(c, str) and c.strip().startswith(prompt):` => `if True:`
  launch-without-panel: hub.py: `print(cmd + (f" --plugin-dir {shlex_quote(str(panel))}" if panel else ""))` => `print(cmd)`
  days-unvalidated: hub.py: `or any(d not in DAYS for d in a["days"]):` => `or False:`
  mid-hour-window: hub.py: `if not re.fullmatch(r"([01]\d|2[0-3]):00|24:00", str(a[k]))` => `if False`
  cadence-unvalidated: hub.py: `if a["every_minutes"] not in CADENCES:` => `if False:`
  link-projects-unvalidated: hub.py: `if projects is not None and not keys:` => `if False:`
  link-projects-lowercase-ok: hub.py: `re.fullmatch(r"[A-Z][A-Z0-9_]+", t)` => `True`
  ack-unvalidated: hub.py: `if not re.fullmatch(r"[\w+'.-]+", ack):` => `if False:`
  control-not-earlier: hub.py: `since -= dt.timedelta(days=CONTROL_DAYS)` => `pass`
  queries-any-flag: hub.py: `if argv[1:] not in ([], ["--control"]):` => `if False:`
  launch-check-unrecorded: hub.py: `(state_dir(cfg) / "launch.json").write_text(` => `(state_dir(cfg) / "launch-unread.json").write_text(`
  stopped-transcript-trusted: hub.py: `if since and dt.datetime.fromtimestamp(transcript.stat().st_mtime, dt.timezone.utc) < since:` => `if False:`
  live-transcript-distrusted: hub.py: `transcript.stat().st_mtime, dt.timezone.utc) < since:` => `transcript.stat().st_mtime, dt.timezone.utc) > since:`
  named-transcript-guarded: hub.py: `transcript, since = Path(argv[2]), None` => `transcript, since = Path(argv[2]), parse_time(_record(cfg, "launch.json").get("checked"))`
  park-unnormalized: hub.py: `ref = pr_ref(argv[1])` => `ref = argv[1]`
  unpark-noop: hub.py: `if marks.pop(ref, None) is None:` => `if marks.get(ref) is None:`
  park-why-dropped: hub.py: `"why": " ".join(argv[2:])}` => `"why": ""}`
  parked-bad-file-crashes: hub.py: `/ "parked.json").read_text())
    except (OSError, ValueError):` => `/ "parked.json").read_text())
    except OSError:`
"""
import contextlib
import datetime as dt
import io
import json
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
    cfg = {"quiet_hours": {"start": "19:00", "post_at": "08:30", "tz": "America/Los_Angeles"},
           "active_hours": {"days": ["Mon", "Tue", "Wed", "Thu", "Fri"]}}

    def at(self, s):
        return hub.send_plan(self.cfg, dt.datetime.fromisoformat(s))

    def test_daytime_is_live(self):
        self.assertEqual(self.at("2026-10-21T12:00:00-07:00"), ("live", None))

    def test_evening_schedules_next_morning(self):
        mode, post = self.at("2026-10-21T20:30:00-07:00")
        self.assertEqual((mode, post.isoformat()), ("schedule", "2026-10-22T08:30:00-07:00"))

    def test_small_hours_schedule_the_same_morning(self):
        mode, post = self.at("2026-10-22T02:00:00-07:00")
        self.assertEqual((mode, post.isoformat()), ("schedule", "2026-10-22T08:30:00-07:00"))

    def test_the_first_tick_is_still_quiet(self):
        # The 08:07 tick gates what was scheduled overnight again, before it posts.
        mode, post = self.at("2026-10-22T08:07:00-07:00")
        self.assertEqual((mode, post.isoformat()), ("schedule", "2026-10-22T08:30:00-07:00"))

    def test_a_weekend_schedules_for_monday(self):
        # No tick runs on Saturday or Sunday to gate it again before it posts.
        for s in ("2026-10-23T20:30:00-07:00", "2026-10-24T02:00:00-07:00", "2026-10-25T20:30:00-07:00"):
            mode, post = self.at(s)
            self.assertEqual((mode, post.isoformat()), ("schedule", "2026-10-26T08:30:00-07:00"), s)

    def test_the_first_tick_after_quiet_hours_is_the_morning_one(self):
        t = dt.datetime.fromisoformat
        morning = t("2026-10-22T08:37:00-07:00")
        self.assertTrue(hub.first_tick_after_quiet(self.cfg, t("2026-10-22T08:07:00-07:00"), morning))
        self.assertTrue(hub.first_tick_after_quiet(self.cfg, t("2026-10-21T17:37:00-07:00"), morning), "slept all night")
        self.assertFalse(hub.first_tick_after_quiet(self.cfg, t("2026-10-22T08:37:00-07:00"), t("2026-10-22T09:07:00-07:00")))
        self.assertFalse(hub.first_tick_after_quiet(self.cfg, t("2026-10-21T17:37:00-07:00"), t("2026-10-22T08:07:00-07:00")),
                         "still quiet: the 08:07 tick gates what is about to post")
        self.assertFalse(hub.first_tick_after_quiet(self.cfg, None, morning))

    def test_the_log_day_is_the_configured_zones_not_the_machines(self):
        # 17:00 UTC on 2026-10-21 is 10:00 that day in Los Angeles and 06:00 the next in Auckland.
        cfg = CONFIG.replace('tz = "America/Los_Angeles"', 'tz = "Pacific/Auckland"')
        with Env(config=cfg, now="2026-10-21T17:00:00Z"), machine_zone("America/Los_Angeles"):
            p = hub.append_log(hub.load_config(), "scan started")
            self.assertEqual((p.name, p.read_text()), ("2026-10-22.md", "- 06:00 scan started\n"))


class Config(unittest.TestCase):
    def test_link_ticket_projects_is_a_list_of_project_keys(self):
        def listing(value):
            return CONFIG.replace('my_user_id = "user-me"', f'my_user_id = "user-me"\nlink_ticket_projects = {value}')
        for bad in ('"PROJ"', '["proj"]', "[12]"):
            with Env(config=listing(bad)), self.assertRaisesRegex(hub.ConfigError, "slack.link_ticket_projects must list"):
                hub.load_config()
        with Env(config=listing('["SEC", "OPS_2"]')):
            self.assertEqual(hub.load_config()["slack"]["link_ticket_projects"], ["SEC", "OPS_2"])
        with Env():
            self.assertNotIn("link_ticket_projects", hub.load_config()["slack"], "unset: the routing entries' tickets")

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
            self.assertIn("slack: primary_dm=dm-primary my_user_id=user-me watched=chan-one ack=white_check_mark", lines)
            self.assertIn("bots: - max_chars: slack=2500 review=2500", lines)
            self.assertIn("quiet: 19:00 to 08:30 America/Los_Angeles", lines)

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

    def test_the_ack_reaction_is_an_emoji_name(self):
        with Env(config=CONFIG.replace('my_user_id = "user-me"', 'my_user_id = "user-me"\nack_reaction = "a b"')):
            with self.assertRaisesRegex(hub.ConfigError, "slack.ack_reaction must be an emoji name"):
                hub.load_config()


class MentionQueries(unittest.TestCase):
    def test_three_searches_dated_two_days_back_in_the_configured_zone(self):
        # 03:00 UTC on the 22nd is still the 21st in Los Angeles: two days back is the 19th.
        out = io.StringIO()
        with Env(now="2026-10-22T03:00:00Z"), contextlib.redirect_stdout(out):
            self.assertEqual(hub.main(["queries"]), 0)
        self.assertEqual(out.getvalue().splitlines()[:3], [
            "<@user-me> after:2026-10-19", "to:<@user-me> after:2026-10-19",
            "with:<@user-me> is:thread after:2026-10-19"])

    def queries(self, *args, now=None):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"COMMS_HUB_NOW": now} if now else {}), contextlib.redirect_stdout(out):
            rc = hub.main(["queries", *args])
        return rc, out.getvalue().splitlines()

    def test_the_searches_page_back_to_where_the_last_complete_ones_started(self):
        # One page of the with: search once held only the last hour, and nothing said the rest was unread.
        tue_0900, mon_2300, mon_2200, mon_2000 = "1792512000.000100", "1792476000.000100", "1792472400.000100", "1792465200"
        perma = "https://example.slack.com/archives/chan-one/p{}?thread_ts=" + mon_2000 + ".000100"
        reply, older = perma.format(tue_0900.replace(".", "")), perma.format(mon_2200.replace(".", ""))
        with Env(now="2026-10-21T17:00:00Z") as env:
            # A full scan's record is not the searches' own: the reach is still the start of yesterday.
            env.state.mkdir(parents=True)
            (env.state / "tick.json").write_text('{"full": "2026-10-21T16:00:00+00:00"}\n')
            rc, lines = self.queries()
            self.assertEqual(lines[3:], [
                "reach: Tue 00:00 epoch=1792479600: page each search, newest first, until its oldest hit is at "
                "or before this, or it runs out",
                "then: hub.py queries --reached 1792602000 --oldest <each search's oldest hit read, its ts or "
                "permalink, or end where it ran out>"])
            # A search whose oldest hit is after the reach stopped short: nothing recorded.
            rc, lines = self.queries("--reached", "1792602000", "--oldest", tue_0900, "end", older)
            self.assertEqual((rc, lines), (1, [
                "TRUNCATED: the mention search stopped at Tue 09:00, after the reach Tue 00:00: read its next page, "
                "or log the mentions as truncated",
                "mentions: not recorded; the next tick reaches back to Tue 00:00 again"]))
            # A reply's permalink counts by its own ts, not its thread's, which is older.
            rc, lines = self.queries("--reached", "1792602000", "--oldest", mon_2300, "end", reply)
            self.assertEqual(rc, 1, lines)
            self.assertIn("TRUNCATED: the with: search stopped at Tue 09:00", lines[0])
            self.assertNotIn("mentions", json.loads((env.state / "tick.json").read_text()))
            rc, lines = self.queries("--reached", "1792602000", "--oldest", mon_2300, "end", older)
            self.assertEqual((rc, lines), (0, [
                "mentions: every search reached Tue 00:00; the next tick reaches back to 09:55"]))
            self.assertEqual(json.loads((env.state / "tick.json").read_text()),
                             {"full": "2026-10-21T16:00:00+00:00", "mentions": "2026-10-21T17:00:00+00:00"})
            # The next tick reaches back to that start, less the overlap; `after:` stays two days back.
            rc, lines = self.queries(now="2026-10-21T17:30:00Z")
            self.assertEqual(lines[0], "<@user-me> after:2026-10-19")
            self.assertTrue(lines[3].startswith("reach: 09:55 epoch=1792601700:"), lines)

    def test_after_a_weekend_the_searches_date_back_to_the_day_before_the_reach(self):
        with Env(now="2026-10-26T15:07:00Z") as env:
            env.state.mkdir(parents=True)
            (env.state / "tick.json").write_text('{"mentions": "2026-10-24T00:30:00+00:00"}\n')
            rc, lines = self.queries()
            self.assertEqual(lines[:3], ["<@user-me> after:2026-10-22", "to:<@user-me> after:2026-10-22",
                                         "with:<@user-me> is:thread after:2026-10-22"])
            self.assertTrue(lines[3].startswith("reach: Fri 17:25 "), lines)

    def test_a_reach_claim_it_cannot_read_records_nothing(self):
        with Env(now="2026-10-21T17:00:00Z") as env:
            for args in (["x", "--oldest", "end", "end", "end"], ["1792602000", "--oldest", "end", "end"],
                         ["1792605600", "--oldest", "end", "end", "end"],   # an hour ahead: not a `then:` line
                         ["1792602000", "--oldest", "end", "yesterday", "end"]):
                self.assertEqual(self.queries("--reached", *args)[0], 2, args)
            self.assertFalse((env.state / "tick.json").exists())

    def test_the_control_is_the_same_searches_a_week_further_back(self):
        out = io.StringIO()
        with Env(now="2026-10-22T03:00:00Z"), contextlib.redirect_stdout(out):
            self.assertEqual(hub.main(["queries", "--control"]), 0)
            self.assertEqual(hub.main(["queries", "--contrl"]), 2)
        self.assertEqual(out.getvalue().splitlines()[:3], [
            "<@user-me> after:2026-10-12", "to:<@user-me> after:2026-10-12",
            "with:<@user-me> is:thread after:2026-10-12"])


class Feedback(unittest.TestCase):
    def test_a_correction_is_appended_dated_in_the_configured_zone(self):
        with Env(now="2026-10-21T17:00:00Z") as env, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(hub.main(["feedback", "no 'quick' in a status line"]), 0)
            self.assertEqual(hub.main(["feedback", "lead with the ask"]), 0)
            self.assertEqual((env.state / "feedback.md").read_text(),
                             "- 2026-10-21 10:00 no 'quick' in a status line\n- 2026-10-21 10:00 lead with the ask\n")


class Park(unittest.TestCase):
    def test_park_lists_and_unparks_by_ref_or_link(self):
        out = io.StringIO()
        with Env(now="2026-10-21T17:00:00Z") as env, contextlib.redirect_stdout(out):
            self.assertEqual(hub.main(["park", "https://github.com/acme/app/pull/12", "not", "mine"]), 0)
            self.assertEqual(hub.main(["park", "acme/infra#3"]), 0)
            self.assertEqual(hub.main(["park", "app#12"]), 2)
            self.assertEqual(hub.main(["park"]), 0)
            self.assertEqual(hub.main(["unpark", "acme/infra#3"]), 0)
            self.assertEqual(hub.main(["unpark", "acme/infra#3"]), 1)
            self.assertEqual(hub.main(["unpark"]), 2)
            self.assertEqual(set(hub.parked(hub.load_config())), {"acme/app#12"})
            self.assertEqual(hub.json.loads((env.state / "parked.json").read_text())["acme/app#12"]["why"], "not mine")
        lines = out.getvalue().splitlines()
        for line in ("parked acme/app#12: the next scan leaves it out", "acme/app#12  since 2026-10-21  not mine",
                     "acme/infra#3  since 2026-10-21", "parked: 2", "unparked acme/infra#3", "acme/infra#3 was not parked"):
            self.assertIn(line, lines)

    def test_a_bad_file_parks_nothing(self):
        with Env(now="2026-10-21T17:00:00Z") as env:
            env.state.mkdir(parents=True, exist_ok=True)
            (env.state / "parked.json").write_text("{half a file")
            self.assertEqual(hub.parked(hub.load_config()), {})


class Routed(unittest.TestCase):
    def test_finds_what_the_last_seven_days_logged_and_nothing_else(self):
        # Seven, as long as an item stays open: with two, an ask answered on the 18th was routed again.
        link = "https://github.com/acme/app/pull/12"
        with Env(now="2026-10-21T17:00:00Z") as env:
            (env.state / "log").mkdir(parents=True)
            (env.state / "log" / "2026-10-20.md").write_text(f"- 16:10 routed {link} to app-session\n- 16:11 held a draft\n")
            (env.state / "log" / "2026-10-18.md").write_text(f"- 09:00 routed {link} to app-session\n")
            (env.state / "log" / "2026-10-14.md").write_text(f"- 09:00 routed {link} to app-session\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = hub.main(["routed", link])
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().splitlines(),
                             [f"2026-10-20 - 16:10 routed {link} to app-session",
                              f"2026-10-18 - 09:00 routed {link} to app-session",
                              f"routed: 2 line(s) in the last 7 days mention '{link}'"])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hub.main(["routed", "acme/app#99"]), 1)

    def routed(self, text, now=None):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"COMMS_HUB_NOW": now} if now else {}), contextlib.redirect_stdout(out):
            rc = hub.main(["routed", text])
        return rc, out.getvalue().splitlines()

    def test_a_slack_thread_matches_in_every_form_the_log_holds_it(self):
        # Asked by permalink, it printed nothing for a thread it had routed and sent into.
        thread, perma = "1792600000.000100", "https://example.slack.com/archives/chan-two/p1792600000000100"
        log = (f"- 09:00 sent acme/app#12 chan-two: reply | id=1792600500.000200 target=reply:{thread} sha256=abc [1021.1]\n"
               f"- 09:05 routed chan-two {thread} (app-session): a reviewer asked when it merges [1021.2]\n"
               f"- 09:06 routed {perma} (app-session): a second reply [1021.3]\n"
               "- 09:07 routed chan-two 1792699999.000100 (ops-session): another thread [1021.4]\n")
        with Env(now="2026-10-21T17:00:00Z") as env:
            (env.state / "log").mkdir(parents=True)
            (env.state / "log" / "2026-10-21.md").write_text(log)
            for text in (f"https://example.slack.com/archives/chan-two/p1792600900000300?thread_ts={thread}&cid=chan-two",
                         perma, f"chan-two {thread}", thread):
                rc, lines = self.routed(text)
                self.assertEqual((rc, [ln.split(" [")[-1] for ln in lines[:-1]]), (0, ["1021.1]", "1021.2]", "1021.3]"]),
                                 text)
            self.assertEqual(self.routed("1792699999.000100")[1][0], "2026-10-21 " + log.splitlines()[3])

    def test_the_peer_that_drafted_into_a_thread_owns_its_replies_for_two_weeks(self):
        thread = "1792600000.000100"
        reply = f"https://example.slack.com/archives/chan-two/p1792600900000300?thread_ts={thread}&cid=chan-two"
        with Env(now="2026-10-21T17:00:00Z") as env:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(hub.main(["owner", "chan-two", thread, "app-session"]), 0)
                self.assertEqual(hub.main(["owner", "chan-two", "1792600000", "app-session"]), 2)
                self.assertEqual(hub.main(["owner", "chan-two", thread]), 2)
            self.assertIn(f"owner: app-session owns the replies in chan-two {thread} for 14 days", out.getvalue())
            self.assertEqual(self.routed(reply), (0, [
                f"routed: 0 line(s) in the last 7 days mention '{reply}'",
                "owner: app-session drafted the hub's last message in this thread (10:00), so its replies route there"]))
            self.assertEqual(self.routed("1792699999.000100")[0], 1)
            # 13 days on it still owns them; 15 days on, no one does, and a new owner drops the stale entry.
            self.assertEqual(self.routed(thread, now="2026-11-03T17:00:00Z")[0], 0)
            self.assertEqual(self.routed(thread, now="2026-11-05T17:00:00Z")[0], 1)
            with mock.patch.dict(os.environ, {"COMMS_HUB_NOW": "2026-11-05T17:00:00Z"}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hub.main(["owner", "chan-two", "1793900000.000100", "ops-session"]), 0)
            self.assertEqual(list(json.loads((env.state / "threads.json").read_text())), ["chan-two 1793900000.000100"])


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
        with Env(config=CONFIG.replace('post_at = "08:30"', 'post_at = "09:30"')
                 + '\n[active_hours]\ndays = ["Mon", "Tue", "Wed", "Fri", "Sun"]\nstart = "09:00"\n'
                 'end = "10:00"\nevery_minutes = 15\n'):
            c = hub.load_config()
        self.assertEqual(hub.cron(c), "7,22,37,52 9 * * 0-3,5")

    def test_post_at_must_come_after_the_first_tick(self):
        # The Slack tools cannot delete a scheduled message, so the morning tick gates it again first.
        for post, start in (("08:00", "08:00"), ("08:07", "08:00"), ("09:30", "10:00")):
            with Env(config=CONFIG.replace('post_at = "08:30"', f'post_at = "{post}"')
                     + f'\n[active_hours]\nstart = "{start}"\n'):
                with self.assertRaisesRegex(hub.ConfigError, f"post_at {post} must come after the first tick, {start[:2]}:07"):
                    hub.load_config()
        with Env(config=CONFIG.replace('post_at = "08:30"', 'post_at = "08:08"')):
            self.assertEqual(hub.load_config()["quiet_hours"]["post_at"], "08:08")

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

    def test_the_launch_check_wants_the_configured_window_and_a_timeout(self):
        c = self.cfg()
        ok = {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "600k", "MCP_TOOL_TIMEOUT": "60000"}
        self.assertEqual(hub.launch_problems(c, ok), [])
        # A session still at the old 150k compacted ten times a day and passed a `want or less` check.
        self.assertEqual(hub.launch_problems(c, {**ok, "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "150000"}),
                         ["CLAUDE_CODE_AUTO_COMPACT_WINDOW is 150000 in this session, want 600000"])
        self.assertEqual(len(hub.launch_problems(c, {**ok, "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "800000"})), 1)
        self.assertEqual(len(hub.launch_problems(c, {**ok, "MCP_TOOL_TIMEOUT": "300000"})), 1)
        self.assertEqual(len(hub.launch_problems(c, {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "600000"})), 1)
        settings = "claude --settings '{\"env\":{\"CLAUDE_CODE_AUTO_COMPACT_WINDOW\":\"600000\",\"MCP_TOOL_TIMEOUT\":\"120000\"}}'"
        with Env(), mock.patch.object(hub, "panel_dir", return_value=None):
            rc, out = main_out("launch")
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), settings)
        with Env(), mock.patch.object(hub, "panel_dir", return_value=hub.Path("/home/me/.claude/skills/comms-hub/panel")):
            rc, out = main_out("launch")
        self.assertEqual(out.strip(), settings + " --plugin-dir /home/me/.claude/skills/comms-hub/panel",
                         "the panel loads into the comms session alone")


class Compaction(unittest.TestCase):
    """What a compaction leaves the comms session: 150k compacted at ~118k with
    77-94k back each time, so ten compactions in a day."""

    def transcripts(self, root):
        import json as _json
        import time as _time
        root = root / "projects"

        def write(rel, rows, age):
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("".join(_json.dumps(r) + "\n" for r in rows))
            t = _time.time() - age
            os.utime(p, (t, t))
            return p

        tick = {"type": "user", "isMeta": True, "scheduledFireId": "f1",
                "message": {"role": "user", "content": "comms-hub tick"}}
        boundary = lambda ts: {"type": "system", "subtype": "compact_boundary", "timestamp": ts,  # noqa: E731
                               "compactMetadata": {"trigger": "auto", "postTokens": 9000}}
        usage = lambda read, write_: {"type": "assistant", "message": {"id": "m", "usage": {  # noqa: E731
            "input_tokens": 2, "cache_read_input_tokens": read, "cache_creation_input_tokens": write_}}}
        old = write("proj/old.jsonl", [tick, boundary("2026-10-28T09:00:00Z"), usage(30_000, 20_000)], 3600)
        new = write("proj/new.jsonl", [tick, boundary("2026-10-29T09:00:00Z"), usage(30_000, 20_000),
                                       boundary("2026-10-29T10:00:00Z"), usage(60_000, 34_000), usage(90_000, 1_000)],
                    600)
        # Newer than both, and each holds the prompt: a reviewer's own transcript, and a
        # tool result (a user record) quoting it, as a grep of a transcript would.
        write("proj/new/subagents/agent-a1.jsonl", [tick], 60)
        write("proj/quote.jsonl", [{"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "comms-hub tick"}]}}], 30)
        return old, new

    def test_the_comms_transcript_is_found_by_its_tick_prompt_alone(self):
        with Env() as env:
            old, new = self.transcripts(env.dir)
            self.assertEqual(hub.tick_transcript(env.dir / "projects"), new)
            self.assertIsNone(hub.tick_transcript(env.dir / "projects", days=0))

    def test_the_latest_compaction_sets_the_baseline(self):
        with Env() as env:
            _, new = self.transcripts(env.dir)
            self.assertEqual(hub.compaction_baseline(new), (2, 94_002, "2026-10-29T10:00:00Z"))

    def test_a_window_that_leaves_under_100k_warns(self):
        with Env() as env:
            _, new = self.transcripts(env.dir)
            env.config.write_text(env.config.read_text() + "\n[session]\ncompact_window = 150000\n")
            small = hub.compaction_lines(hub.load_config(), new)
            self.assertIn("left 94k, so 55k to work in", small[0])
            self.assertTrue(small[1].startswith("WARN: under 100k to work in after a compaction"), small)
            env.config.write_text(env.config.read_text().replace("150000", "600000"))
            big = hub.compaction_lines(hub.load_config(), new)
            self.assertEqual(len(big), 1, big)
            self.assertIn("so 505k to work in", big[0])
            self.assertIn("not compacted yet",
                          hub.compaction_lines(hub.load_config(), env.dir / "projects" / "proj" / "quote.jsonl")[0])
            self.assertIn("no transcript", hub.compaction_lines(hub.load_config(), None)[0])

    def test_config_prints_it(self):
        with Env() as env:
            self.transcripts(env.dir)
            out = io.StringIO()
            with mock.patch.object(hub, "projects_root", return_value=env.dir / "projects"), \
                    contextlib.redirect_stdout(out):
                self.assertEqual(hub.main(["config"]), 0)
            self.assertIn("compact: window 600000; session new compacted 2x", out.getvalue())

    def test_after_a_relaunch_the_stopped_sessions_transcript_is_named_as_such(self):
        # A relaunched session has no tick until the first cron fire, so the newest
        # tick transcript was the stopped one's, and config read it as this one's.
        with Env() as env:
            _, new = self.transcripts(env.dir)  # last written ten minutes ago
            launched = {k: str(v) for k, v in hub.launch_env(hub.load_config()).items()}
            out = io.StringIO()
            with mock.patch.object(hub, "projects_root", return_value=env.dir / "projects"), \
                    mock.patch.dict(os.environ, launched), contextlib.redirect_stdout(out):
                self.assertEqual(hub.main(["launch", "--check"]), 0)
                self.assertEqual(hub.main(["config"]), 0)
                self.assertEqual(hub.main(["config", "--transcript", str(new)]), 0)
            lines = [ln for ln in out.getvalue().splitlines() if ln.startswith("compact:")]
            self.assertIn("session new, was last written before this session passed its launch check", lines[0])
            self.assertIn("waits for this session's first tick", lines[0])
            self.assertIn("session new compacted 2x", lines[1], "a named transcript is read as asked")

    def test_a_transcript_written_since_the_launch_check_is_this_sessions(self):
        with Env() as env:
            self.transcripts(env.dir)
            hour_ago = hub.dt.datetime.now(hub.dt.timezone.utc) - hub.dt.timedelta(hours=1)
            (env.state).mkdir(parents=True, exist_ok=True)
            (env.state / "launch.json").write_text(hub.json.dumps({"checked": hour_ago.isoformat()}))
            out = io.StringIO()
            with mock.patch.object(hub, "projects_root", return_value=env.dir / "projects"), \
                    contextlib.redirect_stdout(out):
                self.assertEqual(hub.main(["config"]), 0)
            self.assertIn("compact: window 600000; session new compacted 2x", out.getvalue())


if __name__ == "__main__":
    unittest.main()
