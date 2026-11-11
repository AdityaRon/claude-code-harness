r"""hub.py: log events, corrections, and what the comms panel draws.

Mutations (run.py --mutate applies each and expects this file to fail):
  text-any-length: hub.py: `if len(text) > TEXT_MAX:` => `if False:`
  text-ids-ok: hub.py: `for rx, what in NOT_TEXT:` => `for rx, what in ():`
  at-unchecked: hub.py: `if not problem and args.at and not re.fullmatch(` => `if False and not re.fullmatch(`
  at-ignored: hub.py: `"at": at or f"{stamp:%H:%M}"` => `"at": f"{stamp:%H:%M}"`
  no-jsonl: hub.py: `    with jl.open("a") as f:
        f.write(json.dumps(row) + "\n")` => `    pass`
  legacy-unread: hub.py: `elif md.is_file():` => `elif False:`
  legacy-unscrubbed: hub.py: `"text": scrub(cfg, text),` => `"text": text,`
  pr-unshortened: hub.py: `    if m:
        return f"{cfg['github']['repo_aliases']` => `    if False:
        return f"{cfg['github']['repo_aliases']`
  channel-unnamed: hub.py: `name = cfg["slack"]["channel_names"].get(cid)` => `name = None`
  correction-is-a-new-line: hub.py: `if target and target in by_id:` => `if False:`
  correction-of-correction-lost: hub.py: `alias[r["id"]] = target` => `pass`
  needs-forgotten-next-day: hub.py: `rows = folded(cfg, OPEN_DAYS)` => `rows = folded(cfg, 1)`
  held-go-not-needs: hub.py: `if h.get("needs", "").strip() == "user":` => `if False:`
  unrecorded-not-going: hub.py: `or s.get("regate_of") or not s.get("post_at"):` => `or s.get("regate_of") or not s.get("post_at") or not s.get("sent_id"):`
  withdrawn-going: hub.py: `if s.get("send") != "schedule" or s.get("withdrawn_at") or s.get("regate_of")` => `if s.get("send") != "schedule" or s.get("regate_of")`
  regate-going: hub.py: `or s.get("withdrawn_at") or s.get("regate_of") or not` => `or s.get("withdrawn_at") or not`
  claim-moved-hidden: hub.py: `if s.get("claim_moved_at"):` => `if False:`
  recheck-never-due: hub.py: `elif last_scan and last_scan > checked:` => `elif False:`
  scans-in-events: hub.py: `for r in reversed(recent) if r["kind"] not in UNSHOWN]` => `for r in reversed(recent) if r["kind"] != "scan"]`
  todo-counts-as-an-item: hub.py: `if r["kind"] not in UNSHOWN + ("tick", "setup")] if scans else []` => `if r["kind"] not in ("scan", "tick", "setup")] if scans else []`
  moved-head-ignored: hub.py: `behind = bool(p.get("my_sha")) and p["my_sha"] != p["head"]` => `behind = False`
  moved-still-approvable: hub.py: `"new commits" if moved else verdict` => `verdict or ("new commits" if moved else "")`
  verdict-unshown: hub.py: `verdicts[f"{m.group(1)}/{m.group(2)}#{m.group(3)}"] = r["text"]` => `pass`
  asked-not-needs: hub.py: `"needs": bool(moved or verdict or asked)` => `"needs": bool(moved or verdict)`
  merge-not-needs: hub.py: `merge_me = p.get("decision") == "APPROVED" and p.get("merge") in MERGEABLE` => `merge_me = False`
  needs-unsorted: hub.py: `rows.sort(key=lambda r: (not r["needs"], r["group"] != "reviewing", short_ref(cfg, r["ref"])))` => `rows.sort(key=lambda r: short_ref(cfg, r["ref"]))`
  repo-needs-uncounted: hub.py: `c[0] += r["needs"]` => `pass`
  old-file-live: hub.py: `stale = written is None or bool(second and second + lag + LATE_GRACE <= now()) \` => `stale = written is None or False \`
  stale-after-one-tick: hub.py: `second = next_tick(cfg, next_tick(cfg, written) or now()) if written else None` => `second = next_tick(cfg, written) if written else None`
  stale-without-lag: hub.py: `second + lag + LATE_GRACE <= now()` => `second + LATE_GRACE <= now()`
  stale-without-grace: hub.py: `second + lag + LATE_GRACE <= now()` => `second + lag <= now()`
  stale-without-the-usual-lag: hub.py: `"prs": prs_panel(cfg, verdicts, lag),` => `"prs": prs_panel(cfg, verdicts),`
  blocked-scan-live: hub.py: `or bool(last_scan and last_scan - written > dt.timedelta(minutes=1))` => `or False`
  bad-file-crashes: hub.py: `except (OSError, ValueError, KeyError, TypeError):
        data, written = None, None` => `except OSError:
        data, written = None, None`
  strip-weekends: hub.py: `if DAYS[day.weekday()] in cfg["active_hours"]["days"]:` => `if True:`
  strip-uncounted: hub.py: `counts[r["day"]][r["event"]] += 1` => `pass`
  events-oldest-first: hub.py: `for r in reversed(recent) if` => `for r in recent if`
  events-yesterday-dropped: hub.py: `if r["day"] in logs[-2:]]` => `if r["day"] in logs[-1:]]`
  events-yesterday-undated: hub.py: `return r["at"] if r["day"] == today else` => `return r["at"] if True else`
  header-newest-log-day: hub.py: `"day": f"{local_now(cfg):%a %d %b}",` => `"day": f"{dt.date.fromisoformat(logs[-1]):%a %d %b}" if logs else "",`
  last-tick-counts-all: hub.py: `r in rows[scans[-1] + 1:]` => `r in rows`
  last-tick-untimed: hub.py: `"last_tick": f"{dated(rows[scans[-1]])}, " + (` => `"last_tick": "" + (`
  last-tick-undated: hub.py: `"last_tick": f"{dated(rows[scans[-1]])}, " + (` => `"last_tick": f"{rows[scans[-1]]['at']}, " + (`
  scans-of-today-only: hub.py: `rows = rows_since(cfg, now() - dt.timedelta(days=OPEN_DAYS))` => `rows = rows_since(cfg, now())`
  next-tick-ignores-lag: hub.py: `nxt = next_tick(cfg, now() - lag)` => `nxt = next_tick(cfg, now())`
  lag-unshown: hub.py: `+ (f" (+{lag_m}m lately)" if lag_m else "")` => `+ ""`
  lag-the-latest: hub.py: `return lags[len(lags) // 2] if len(lags) >= 3 else None` => `return lags[-1] if len(lags) >= 3 else None`
  lag-from-one-scan: hub.py: `return lags[len(lags) // 2] if len(lags) >= 3 else None` => `return lags[len(lags) // 2] if lags else None`
  missed-unshown: hub.py: `+ (f" · {len(late)} missed since" if late else "")` => `+ ""`
  missed-without-grace: hub.py: `now() - lag - LATE_GRACE, rows)` => `now() - lag, rows)`
  missed-without-lag: hub.py: `now() - lag - LATE_GRACE, rows)` => `now() - LATE_GRACE, rows)`
  age-hours-only: hub.py: `return (f"{h}h{m}m" if m else f"{h}h")` => `return f"{h}h"`
  torn-row-read: hub.py: `if lines and not text.endswith("\n"):` => `if False:`
  half-gate-record-fails: hub.py: `continue  # caught mid-write, or left half by a crash` => `raise  # caught mid-write, or left half by a crash`
  half-stamp-fails: hub.py: `        return parse_time((state_dir(cfg) / "last-scan").read_text().strip())
    except (OSError, ValueError):` => `        return parse_time((state_dir(cfg) / "last-scan").read_text().strip())
    except OSError:`
  written-in-place: hub.py: `tmp = path.with_name(path.name + ".tmp")` => `tmp = path`
  gate-written-in-place: check_draft.py: `hub.write_whole(p, json.dumps(stamp, indent=1))` => `p.write_text(json.dumps(stamp, indent=1))`
  stamp-written-in-place: queue.py: `hub.write_whole(stamp, at.isoformat() + "\n")` => `stamp.write_text(at.isoformat() + "\n")`
  parked-uncounted: hub.py: `"parked": len(parked(cfg))}` => `"parked": 0}`
  held-text-uncut: hub.py: `"text": clip(h["first"]), "full"` => `"text": h["first"], "full"`
  held-full-first-line: hub.py: `"full": whole(h["body"])}` => `"full": h["first"]}`
  going-full-first-line: hub.py: `"full": whole(d["body"]), "status"` => `"full": d["first"], "status"`
  full-uncapped: hub.py: `return text if len(text) <= FULL_MAX else` => `return text if True else`
  full-blank-runs: hub.py: `text = re.sub(r"\n\s*\n", "\n\n", (text or "").strip())` => `text = (text or "").strip()`
  clip-off-by-one: hub.py: `text[:TEXT_MAX - 1].rstrip() + "…"` => `text[:TEXT_MAX].rstrip() + "…"`
  kindless-refused: hub.py: `if args.kind is None:` => `if False:`
  kindless-text-dropped: hub.py: `args.detail = " ".join(x for x in (text, args.detail) if x)` => `pass`
  kindless-id-refused: hub.py: `text = "a note whose text is in the detail"` => `pass`
"""
import contextlib
import io
import json
import os
import unittest
from unittest import mock

from fakes import CONFIG, Env

import hub

NOW = "2026-10-21T17:00:00+00:00"  # 10:00 on Wednesday the 21st in Los Angeles, the config's zone
NAMES = CONFIG + '\n[slack.channel_names]\n"C0CHANONE1" = "team-reviews"\n"D0DMBOBXX1" = "Bob"\n' \
                 '\n[github.repo_aliases]\n"acme/application-server" = "app"\n'


def main_out(*argv, now=NOW):
    out = io.StringIO()
    with mock.patch.dict(os.environ, {"COMMS_HUB_NOW": now}), contextlib.redirect_stdout(out):
        rc = hub.main(list(argv))
    return rc, out.getvalue()


def rows(env, day="2026-10-21"):
    p = env.state / "log" / f"{day}.jsonl"
    return [json.loads(ln) for ln in p.read_text().splitlines()] if p.is_file() else []


def md(env, day="2026-10-21"):
    p = env.state / "log" / f"{day}.md"
    return p.read_text() if p.is_file() else ""


class LogEvents(unittest.TestCase):
    def test_an_event_is_a_jsonl_row_and_an_md_line(self):
        with Env(config=NAMES, now=NOW) as env:
            rc, out = main_out("log", "--kind", "routed", "--ref", "https://github.com/acme/application-server/pull/12",
                               "--who", "app-session", "--detail", "asked in team-reviews", "bob's", "question",
                               "on", "the", "release")
            self.assertEqual((rc, out.strip()), (0, "logged 1021.1: routed bob's question on the release"))
            self.assertEqual(rows(env), [{"id": "1021.1", "ts": NOW, "at": "10:00", "kind": "routed",
                                          "text": "bob's question on the release",
                                          "ref": "https://github.com/acme/application-server/pull/12", "target": "",
                                          "who": "app-session", "needs_user": False, "corrects": None,
                                          "detail": "asked in team-reviews"}])
            self.assertEqual(md(env), "- 10:00 routed https://github.com/acme/application-server/pull/12 (app-session): "
                                      "bob's question on the release | asked in team-reviews [1021.1]\n")

    def test_text_the_panel_cannot_show_is_refused(self):
        cases = ((["x" * 81], "81 characters, over 80"),
                 (["reply in C0ABCDEF12"], "a Slack id"),
                 (["reply under 1761040800.000100"], "a thread ts"),
                 (["gate passed 7221f2a48fda"], "a hash"),
                 (["see https://example.com/x"], "a link"),
                 (["19:58 held a draft"], "a time (pass it as --at)"),
                 (["--at", "7pm", "held a draft"], "--at '7pm' is not HH:MM"))
        with Env(now=NOW) as env:
            for argv, why in cases:
                rc, out = main_out("log", "--kind", "note", *argv)
                self.assertEqual(rc, 2, argv)
                self.assertIn(why, out, argv)
                self.assertIn("Nothing logged.", out)
            self.assertEqual((rows(env), md(env)), ([], ""))

    def test_an_unknown_kind_or_help_logs_nothing(self):
        # `hub.py log --help` once wrote "--help" into the log.
        with Env(now=NOW) as env:
            for argv in (["--kind", "QUESTION", "may bob drop it"], ["--help"]):
                with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                    main_out("log", *argv)
            rc, out = main_out("feedback", "--help")
            self.assertEqual(rc, 2)
            self.assertEqual((rows(env), md(env)), ([], ""))
            self.assertFalse((env.state / "feedback.md").exists())

    def test_text_with_no_kind_is_kept_as_a_note(self):
        # After an in-place install, a session on the older skill logged nothing all day.
        with Env(now=NOW) as env:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                for text in ("routed the conflict to the app session",
                             "19:58 sent 1761040800.000100 to C0123ABCD9 https://github.com/acme/app/pull/12",
                             "asked U0123ABCD9 about it"):
                    rc, out = main_out("log", text)
                    self.assertEqual(rc, 0, out)
            got = rows(env)
            self.assertEqual([r["kind"] for r in got], ["note", "note", "note"])
            self.assertEqual((got[0]["text"], got[0]["detail"]), ("routed the conflict to the app session", ""))
            self.assertNotRegex(got[1]["text"], r"\d{10}\.\d{6}|https?://|^19:58")
            self.assertIn("1761040800.000100", got[1]["detail"], "what the text may not hold is kept, in the detail")
            self.assertEqual(got[2]["text"], "a note whose text is in the detail")
            self.assertIn("U0123ABCD9", got[2]["detail"])
            self.assertIn("no --kind, so logged as a note", err.getvalue())

    def test_a_late_entry_keeps_one_time(self):
        # "21:40 19:58 held ...": the session wrote its own time into the text.
        with Env(now=NOW) as env:
            main_out("log", "--kind", "held", "--at", "09:12", "carol's review ask, held for the user")
            self.assertEqual(rows(env)[0]["at"], "09:12")
            self.assertTrue(md(env).startswith("- 09:12 held: carol's review ask"))

    def test_a_day_with_no_jsonl_reads_its_md_lines_without_ids(self):
        with Env(config=NAMES, now=NOW) as env:
            (env.state / "log").mkdir(parents=True)
            (env.state / "log" / "2026-10-21.md").write_text(
                "- 09:12 sent 1761044400.000200 target=reply:1761040800.000100 sha256=abc123def456: bob asked when #12 "
                "merges\n"
                "- 09:30 HELD (quiet hours): review ask https://github.com/acme/application-server/pull/14 in "
                "C0CHANONE1 thread 1761040800.000100, gate PASS 7221f2a48fda, draft at /home/u/.claude/jobs/x/tmp/d.md\n"
                "- 21:40 scheduled Ab0CD1KJQP1U for 08:30: a reply\n")
            got = [(r["at"], r["kind"], r["text"]) for r in hub.day_rows(hub.load_config(), hub.dt.date(2026, 10, 21))]
        self.assertEqual(got, [("09:12", "sent", "bob asked when #12 merges"),
                               ("09:30", "held", "(quiet hours): review ask app #14 in #team-reviews thread, gate PASS, draft at"),
                               ("21:40", "scheduled", "for 08:30: a reply")])


class Corrections(unittest.TestCase):
    def test_a_correction_replaces_its_row_and_closes_what_it_answers(self):
        with Env(now=NOW):
            main_out("log", "--kind", "asked", "--needs-user", "may bob drop three dev tables?")
            main_out("log", "--kind", "routed", "--who", "app-session", "acme/app#12 conflicts")
            cfg = hub.load_config()
            needs, routed = hub.open_items(cfg)
            self.assertEqual(([r["id"] for r in needs], [r["id"] for r in routed]), (["1021.1"], ["1021.2"]))
            main_out("log", "--kind", "answered", "--corrects", "1021.1", "the user said drop them",
                     now="2026-10-21T18:00:00+00:00")
            main_out("log", "--kind", "returned", "--corrects", "1021.2", "app-session rebased it",
                     now="2026-10-21T18:05:00+00:00")
            self.assertEqual(hub.open_items(cfg), ([], []))
            got = [(r["id"], r["at"], r["kind"], r["text"], r.get("corrected")) for r in hub.folded(cfg, 1)]
        self.assertEqual(got, [("1021.1", "10:00", "answered", "the user said drop them", True),
                               ("1021.2", "10:00", "returned", "app-session rebased it", True)])

    def test_a_correction_of_a_correction_folds_into_the_first_row(self):
        with Env(now=NOW):
            main_out("log", "--kind", "note", "the thread had 3 replies")
            main_out("log", "--kind", "note", "--corrects", "1021.1", "the thread had 19 replies")
            main_out("log", "--kind", "note", "--corrects", "1021.2", "the thread had 20 replies")
            got = [(r["id"], r["text"]) for r in hub.folded(hub.load_config(), 1)]
        self.assertEqual(got, [("1021.1", "the thread had 20 replies")])

    def test_a_question_from_yesterday_still_needs_the_user(self):
        with Env(now=NOW):
            main_out("log", "--kind", "asked", "--needs-user", "may bob drop three dev tables?",
                     now="2026-10-20T17:00:00+00:00")
            self.assertEqual([r["id"] for r in hub.open_items(hub.load_config())[0]], ["1020.1"])


class Panel(unittest.TestCase):
    def build(self, env):
        s = env.state
        (s / "held").mkdir(parents=True)
        (s / "held" / "app-session-1761040800.000100.md").write_text(
            "to: C0CHANONE1 reply 1761040800.000100\nkind: reply\nneeds: user\nclaims:\n"
            "- acme/application-server#14 open | its PR\n---\n\nCarol, could you review #14?\n")
        (s / "held" / "app-session-1761040900.000100.md").write_text(
            "to: D0DMBOBXX1 top-level\nkind: reply\nreason: a fold-in from app-session is expected\n---\n\nMerged.\n")
        (s / "sent" / "2026-10-21").mkdir(parents=True)
        (s / "gate").mkdir()
        passed = hub.dt.datetime.fromisoformat("2026-10-21T16:50:00+00:00").timestamp()
        records = {"Q0001": {}, "Q0002": {"withdrawn_at": NOW}, "Q0003": {"claim_moved_at": NOW},
                   "unrecorded": {"sent_id": None}, "copy": {"regate_of": "Q0001"}}
        for name, extra in records.items():
            copy = s / "sent" / "2026-10-21" / f"{name}.md"
            copy.write_text("to: D0DMBOBXX1 top-level\nkind: reply\n---\n\nBob, could you review #15?\n\nThe tables move first.\n")
            (s / "gate" / f"{name}.json").write_text(json.dumps({
                "send": "schedule", "sent_id": name, "sent_copy": str(copy), "path": str(copy), "target": "top-level",
                "post_at": "2026-10-22T08:30:00-07:00", "passed_at": passed, "headline": f"review ask {name}",
                "prs": ["acme/application-server#15 state=OPEN draft=no"], **extra}))

    def test_it_sorts_what_needs_the_user_what_goes_out_and_since_the_last_look(self):
        with Env(config=NAMES, now=NOW) as env:
            self.build(env)
            (env.state / "last-scan").write_text("2026-10-21T16:55:00+00:00\n")  # after the 16:50 gate
            main_out("log", "--kind", "scan", "scan started", now="2026-10-21T16:00:00+00:00")
            main_out("log", "--kind", "asked", "--needs-user", "--target", "D0DMBOBXX1", "may bob drop the tables?",
                     now="2026-10-21T16:10:00+00:00")
            main_out("log", "--kind", "routed", "--who", "app-session", "--ref",
                     "https://github.com/acme/application-server/pull/16", "conflicts", now="2026-10-21T16:20:00+00:00")
            main_out("log", "--kind", "note", "the thread had 3 replies", now="2026-10-21T16:30:00+00:00")
            main_out("log", "--kind", "note", "--corrects", "1021.4", "the thread had 19 replies",
                     now="2026-10-21T16:40:00+00:00")
            main_out("log", "--kind", "scan", "scan started", now="2026-10-21T16:45:00+00:00")
            main_out("log", "--kind", "sent", "--target", "C0CHANONE1", "reply to carol", now="2026-10-21T16:46:00+00:00")
            rc, out = main_out("panel")
            self.assertEqual(rc, 0, out)
            p = json.loads(out)
        self.assertEqual([(n["ref"], n["target"], n["text"], n["note"]) for n in p["needs"]],
                         [("app #14", "#team-reviews", "Carol, could you review #14?", "needs your go"),
                          ("", "Bob DM", "may bob drop the tables?", "")])
        self.assertEqual(p["needs"][1]["age"], "50m")
        self.assertEqual([(h["target"], h["reason"]) for h in p["held"]],
                         [("Bob DM", "a fold-in from app-session is expected")])
        self.assertEqual([(g["text"], g["post"], g["target"], g["ref"], g["status"], g["warn"]) for g in p["going"]],
                         [("review ask Q0001", "08:30", "Bob DM", "app #15", "re-check due", False),
                          ("review ask Q0003", "08:30", "Bob DM", "app #15", "claim moved ⚠", True),
                          ("review ask unrecorded", "08:30", "Bob DM", "app #15", "re-check due", False)])
        self.assertEqual([(w["who"], w["ref"], w["text"], w["since"]) for w in p["sessions"]],
                         [("app-session", "app #16", "conflicts", "09:20")])
        self.assertEqual([(e["at"], e["kind"], e["text"], e["corrected"]) for e in p["events"]],
                         [("09:46", "sent", "reply to carol", False),
                          ("09:30", "note", "the thread had 19 replies", True),
                          ("09:20", "routed", "conflicts", False),
                          ("09:10", "asked", "may bob drop the tables?", False)])
        self.assertEqual(p["events"][0]["target"], "#team-reviews")
        self.assertEqual((p["day"], p["last_tick"], p["next_tick"], p["read"]),
                         ("Wed 21 Oct", "09:45, 1 event", "10:07", "10:00"))

    def test_a_gate_after_the_last_scan_reads_as_gated(self):
        with Env(now=NOW) as env:
            self.build(env)
            (env.state / "last-scan").write_text("2026-10-21T16:40:00+00:00\n")
            p = json.loads(main_out("panel")[1])
        self.assertEqual(p["going"][0]["status"], "gated 09:50 ✓")
        self.assertEqual(p["going"][0]["full"], "Bob, could you review #15?\n\nThe tables move first.",
                         "the whole draft, not its headline or first line")

    def test_an_empty_state_dir_draws_empty_sections(self):
        with Env(now=NOW):
            p = json.loads(main_out("panel")[1])
        self.assertEqual((p["needs"], p["going"], p["sessions"], p["held"], p["events"], p["day"], p["last_tick"]),
                         ([], [], [], [], [], "Wed 21 Oct", "none yet"))
        self.assertEqual((p["prs"]["rows"], p["prs"]["stale"], p["prs"]["as_of"]), ([], True, ""))

    def test_the_scans_own_bookkeeping_stays_out_of_the_events(self):
        with Env(now=NOW) as env:
            main_out("log", "--kind", "scan", "scan started", now="2026-10-21T16:45:00+00:00")
            main_out("log", "--kind", "todo", "review requested", now="2026-10-21T16:46:00+00:00")
            main_out("log", "--kind", "done", "--corrects", "1021.2", "review posted at the head",
                     now="2026-10-21T16:47:00+00:00")
            p = json.loads(main_out("panel")[1])
        self.assertEqual((p["events"], p["last_tick"]), ([], "09:45, quiet"), "a quiet tick does not read as 2 events")

    def test_the_evening_before_stays_past_the_first_scan_of_a_new_day(self):
        with Env(config=NAMES, now=NOW):
            main_out("log", "--kind", "note", "a row two log days back", now="2026-10-19T20:00:00+00:00")
            main_out("log", "--kind", "sent", "--target", "C0CHANONE1", "reply to carol", now="2026-10-20T23:30:00+00:00")
            main_out("log", "--kind", "scan", "scan started", now="2026-10-21T16:00:00+00:00")
            main_out("log", "--kind", "sent", "--target", "D0DMBOBXX1", "reply to bob", now="2026-10-21T16:10:00+00:00")
            p = json.loads(main_out("panel")[1])
        self.assertEqual([(e["at"], e["kind"], e["text"]) for e in p["events"]],
                         [("09:10", "sent", "reply to bob"), ("Tue 16:30", "sent", "reply to carol")],
                         "the day before keeps its rows, dated; two log days back has gone")
        self.assertEqual(p["day"], "Wed 21 Oct")

    def test_a_gate_record_or_scan_stamp_caught_half_written_does_not_fail_the_read(self):
        """One half-written gate record failed every read with a traceback the pane showed whole."""
        with Env(config=NAMES, now=NOW) as env:
            self.build(env)
            (env.state / "gate" / "half.json").write_text('{"path": "/synthetic/draft-1.md",\n "sha')
            (env.state / "last-scan").write_text("2026-10-2")
            rc, out = main_out("panel")
        self.assertEqual(rc, 0, out)
        self.assertEqual([g["key"] for g in json.loads(out)["going"]], ["going:Q0001", "going:Q0003", "going:unrecorded"],
                         "the half record is left out, the rest stay")

    def test_a_row_still_being_written_waits_for_the_next_read(self):
        with Env(config=NAMES, now=NOW) as env:
            main_out("log", "--kind", "sent", "--target", "D0DMBOBXX1", "reply to bob", now="2026-10-21T16:10:00+00:00")
            with (env.state / "log" / "2026-10-21.jsonl").open("a") as f:
                f.write('{"id": "1021.2", "ts": "2026-10-21T16:20:00+00:00", "at": "09:2')
            rc, out = main_out("panel")
        self.assertEqual(rc, 0, out)
        self.assertEqual([e["text"] for e in json.loads(out)["events"]], ["reply to bob"])

    def scans_7_minutes_late(self):
        # The 08:07, 08:37 and 09:07 ticks scanned 7:00, 6:30 and 6:41 late, and one by hand at 09:30 23 minutes late.
        for t in ("15:14:00", "15:43:30", "16:13:41", "16:30:00"):
            main_out("log", "--kind", "scan", "scan started", now=f"2026-10-21T{t}+00:00")

    def test_next_tick_says_how_late_ticks_have_started_and_waits_for_the_late_one(self):
        with Env(now=NOW):
            self.scans_7_minutes_late()
            p = json.loads(main_out("panel", now="2026-10-21T16:40:00+00:00")[1])
        self.assertEqual(p["next_tick"], "09:37 (+7m lately)",
                         "at 09:40 the 09:37 tick is still to come; the median, not the scan by hand")

    def test_last_scan_counts_the_ticks_due_since_that_did_not_run(self):
        with Env(now=NOW):
            self.scans_7_minutes_late()
            # After the 09:30 scan nothing ran: a lost login logs nothing.
            soon = json.loads(main_out("panel", now="2026-10-21T16:47:00+00:00")[1])
            later = json.loads(main_out("panel", now="2026-10-21T17:30:00+00:00")[1])
        self.assertEqual(soon["last_tick"], "09:30, quiet",
                         "09:47: the 09:37 tick is due about 09:44, and gets five minutes past that")
        self.assertEqual(later["last_tick"], "09:30, quiet · 2 missed since", "10:30: the 09:37 and 10:07 ticks")
        self.assertEqual(later["next_tick"], "10:37 (+7m lately)")


def a_day_of_scans(day: str, next_day: str) -> None:
    """The ticks of a weekday in Los Angeles (UTC-7), each scanning 7 minutes late:
    08:14 to 17:44, the last two on the next UTC day."""
    for h in range(15, 24):
        for m in ("14", "44"):
            main_out("log", "--kind", "scan", "scan started", now=f"{day}T{h:02d}:{m}:00+00:00")
    for m in ("14", "44"):
        main_out("log", "--kind", "scan", "scan started", now=f"{next_day}T00:{m}:00+00:00")


class NoTickDue(unittest.TestCase):
    """What the pane says while no tick runs: in the evening, at the weekend, before the first."""

    def written_after(self, env, scans_on, next_day):
        a_day_of_scans(scans_on, next_day)
        stamp = f"{next_day}T00:44:00+00:00"   # the 17:44 scan
        (env.state / "last-scan").write_text(stamp + "\n")
        (env.state / "prs.json").write_text(json.dumps({"written_at": stamp, "reviewing": [], "authored": []}))

    def test_an_evening_or_weekend_file_is_old_not_stale_until_two_ticks_were_due(self):
        """The amber said stale every evening: after 17:37 no tick is due."""
        def stale(at):
            return json.loads(main_out("panel", now=at)[1])["prs"]["stale"]
        with Env(now=NOW) as env:
            self.written_after(env, "2026-10-20", "2026-10-21")       # Tuesday
            evening = json.loads(main_out("panel", now="2026-10-21T03:00:00+00:00")[1])["prs"]
            self.assertEqual((evening["as_of"], evening["age"], evening["stale"]), ("17:44", "2h16m", False))
            self.assertTrue(stale("2026-10-21T15:50:00+00:00"), "Wed 08:50: 08:07 and 08:37 were due, by 7m late and 5m grace")
        with Env(now=NOW) as env:
            self.written_after(env, "2026-10-23", "2026-10-24")       # Friday
            self.assertFalse(stale("2026-10-24T19:00:00+00:00"), "Saturday noon")
            self.assertFalse(stale("2026-10-26T15:48:00+00:00"), "Mon 08:48: the 08:37 tick may start until 08:49")
            self.assertTrue(stale("2026-10-26T15:50:00+00:00"), "Mon 08:50")

    def test_the_header_is_today_and_another_days_rows_say_which(self):
        """Friday's log read on Monday at 07:30: the pane was still on Friday."""
        with Env(config=NAMES, now=NOW):
            main_out("log", "--kind", "scan", "scan started", now="2026-10-24T00:44:00+00:00")
            main_out("log", "--kind", "sent", "--target", "C0CHANONE1", "reply to carol", now="2026-10-24T00:50:00+00:00")
            p = json.loads(main_out("panel", now="2026-10-26T14:30:00+00:00")[1])
        self.assertEqual(p["day"], "Mon 26 Oct")
        self.assertEqual([(e["at"], e["text"]) for e in p["events"]], [("Fri 17:50", "reply to carol")])
        self.assertEqual(p["last_tick"], "Fri 17:44, 1 event")

    def test_a_row_before_the_days_first_scan_does_not_hide_the_last_scan(self):
        """A draft held at 07:00 started the day's log, which then read "none yet"
        and did not count the four ticks due by 10:00 that never ran."""
        with Env(now=NOW) as env:
            self.written_after(env, "2026-10-20", "2026-10-21")
            main_out("log", "--kind", "held", "a fold-in is expected", now="2026-10-21T14:00:00+00:00")
            p = json.loads(main_out("panel")[1])
        self.assertEqual(p["last_tick"], "Tue 17:44, 1 event · 4 missed since")


SHA1, SHA2 = "1" * 40, "2" * 40


def pr(ref, **over):
    return {"ref": ref, "url": "", "title": "t", "author": "dana", "head": SHA2, "ci": "green", "decision": None,
            "merge": "CLEAN", "my_state": None, "my_sha": None, "approvals": [], "changes_requested": [],
            "unresolved": 0, "requested": [], **over}


class Prs(unittest.TestCase):
    """Item 8: what can I approve, what waits on me, without asking the session."""

    def write(self, env, written=NOW, reviewing=(), authored=(), last_scan=None):
        env.state.mkdir(parents=True, exist_ok=True)
        (env.state / "prs.json").write_text(json.dumps({"written_at": written, "reviewing": list(reviewing),
                                                        "authored": list(authored)}))
        (env.state / "last-scan").write_text((last_scan or written) + "\n")

    def test_what_needs_me_comes_first_with_a_count_per_repo(self):
        with Env(config=NAMES, now=NOW) as env:
            self.write(env, reviewing=[
                pr("acme/application-server#31", my_state="COMMENTED", my_sha=SHA1, approvals=["erin"]),  # moved
                pr("acme/application-server#32", my_state="COMMENTED", my_sha=SHA2),                      # approvable
                pr("acme/infra#7", requested_me=True),                                                     # asked
                pr("acme/infra#8", my_state="COMMENTED", my_sha=SHA2),                                    # waiting
            ], authored=[
                pr("acme/application-server#40", decision="APPROVED"),
                pr("acme/infra#9", decision="REVIEW_REQUIRED", merge="BLOCKED"),
                pr("acme/infra#10", decision="CHANGES_REQUESTED", unresolved=2, ci="red"),
            ])
            main_out("log", "--kind", "reviewed", "--needs-user", "--ref",
                     "https://github.com/acme/application-server/pull/32", "approvable")
            p = json.loads(main_out("panel")[1])["prs"]
        lines = [(r["needs"], r["line"]) for r in p["rows"]]
        self.assertEqual(lines, [
            (True, "app #31  dana  commented@1111111 · new commits · CI green · approved by erin"),
            (True, "app #32  dana  commented@2222222 · approvable · CI green"),
            (True, "infra #7  dana  not reviewed · CI green"),
            (True, "app #40  approved, needs your merge · CI green"),
            (True, "infra #10  changes requested · CI red · 2 unresolved"),
            (False, "infra #8  dana  commented@2222222 · CI green"),
            (False, "infra #9  review required · CI green"),
        ])
        self.assertEqual(p["repos"], [{"repo": "app", "needs": 3, "total": 3}, {"repo": "infra", "needs": 2, "total": 4}])
        self.assertEqual((p["stale"], p["as_of"], p["age"]), (False, "10:00", "0m"))

    def test_a_moved_head_is_never_approvable(self):
        with Env(now=NOW) as env:
            self.write(env, reviewing=[pr("acme/app#32", my_state="COMMENTED", my_sha=SHA1)])
            main_out("log", "--kind", "reviewed", "--needs-user", "--ref", "acme/app#32", "approvable")
            line = json.loads(main_out("panel")[1])["prs"]["rows"][0]["line"]
        self.assertIn("new commits", line)
        self.assertNotIn("approvable", line)

    def test_it_counts_what_is_parked(self):
        with Env(now=NOW) as env:
            self.write(env)
            self.assertEqual(json.loads(main_out("panel")[1])["prs"]["parked"], 0)
            main_out("park", "acme/app#7")
            main_out("park", "https://github.com/acme/infra/pull/8", "not mine to track")
            self.assertEqual(json.loads(main_out("panel")[1])["prs"]["parked"], 2)

    def test_an_old_or_unreplaced_file_is_stale_and_says_when(self):
        with Env(now=NOW) as env:
            self.write(env, written="2026-10-21T15:30:00+00:00")  # 90 min, three 30-minute ticks
            p = json.loads(main_out("panel")[1])["prs"]
            self.assertEqual((p["stale"], p["as_of"], p["age"]), (True, "08:30", "1h30m"))
            self.write(env, written="2026-10-21T16:50:00+00:00", last_scan="2026-10-21T16:58:00+00:00")
            self.assertTrue(json.loads(main_out("panel")[1])["prs"]["stale"], "a later scan ended BLOCKED")
            (env.state / "prs.json").write_text("{half a file")
            p = json.loads(main_out("panel")[1])["prs"]
            self.assertEqual((p["stale"], p["rows"]), (True, []))

    def test_the_strip_counts_five_days(self):
        with Env(now=NOW) as env:
            env.state.mkdir(parents=True)
            rows = [("2026-10-21", "reviewed"), ("2026-10-21", "reviewed"), ("2026-10-21", "approved"),
                    ("2026-10-20", "merged"), ("2026-10-14", "merged")]
            (env.state / "prs-history.jsonl").write_text("".join(json.dumps({"day": d, "event": e}) + "\n" for d, e in rows))
            days = json.loads(main_out("panel")[1])["prs"]["days"]
        self.assertEqual([d["day"] for d in days], ["Thu 15", "Fri 16", "Mon 19", "Tue 20", "Wed 21"],
                         "the last five active days: the weekend is skipped, the 14th is too far back")
        self.assertEqual([(d["reviewed"], d["approved"], d["merged"]) for d in days],
                         [(0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 1), (2, 1, 0)])

    def test_a_draft_written_as_one_paragraph_is_cut_to_80(self):
        # One held draft once put ~700 characters into its row.
        with Env(now=NOW) as env:
            (env.state / "held").mkdir(parents=True)
            body = "Follow-up on the release: " + "configuration" * 52  # no space where the cut falls
            (env.state / "held" / "app-session-1761040900.000100.md").write_text(
                f"to: C0CHANONE1 top-level\nkind: reply\nneeds: user\n---\n\n{body}\n")
            (env.state / "held" / "app-session-1761041000.000100.md").write_text(
                f"to: C0CHANONE1 top-level\nkind: reply\n---\n\n{body}\n")
            p = json.loads(main_out("panel")[1])
        for row in (p["needs"][0], p["held"][0]):
            self.assertEqual(len(row["text"]), 80, row["text"])
            self.assertTrue(row["text"].startswith("Follow-up on the release: ") and row["text"].endswith("…"))
            self.assertEqual(row["full"], body, "the expanded view reads it whole")

    def test_the_expanded_view_gets_the_whole_draft_within_a_cap(self):
        with Env(now=NOW) as env:
            (env.state / "held").mkdir(parents=True)
            (env.state / "held" / "app-session-1761041000.000100.md").write_text(
                "to: C0CHANONE1 top-level\nkind: reply\n---\n\nFirst paragraph.\n\n\n\nSecond, after three blank lines.\n")
            (env.state / "held" / "app-session-1761041100.000100.md").write_text(
                "to: C0CHANONE1 top-level\nkind: reply\n---\n\n" + "word " * 1000 + "\n")
            held = json.loads(main_out("panel")[1])["held"]
        self.assertEqual((held[0]["text"], held[0]["full"]),
                         ("First paragraph.", "First paragraph.\n\nSecond, after three blank lines."))
        self.assertEqual(len(held[1]["full"]), 2000)
        self.assertTrue(held[1]["full"].endswith("…"))


class Lint(unittest.TestCase):
    PANEL = hub.Path(__file__).resolve().parent.parent / "panel"

    @unittest.skipUnless(PANEL.is_dir(), "the mutation runner copies bin/ and tests/ alone")
    def test_no_binding_shadows_the_jsx_factory(self):
        # JSX compiles to h(...): a HELD row's parameter named h threw "h is not a
        # function" on every render with a held draft, in v1.1.9.
        import re
        found = []
        for p in sorted(self.PANEL.rglob("*.tsx")):
            code = re.sub(r"/\*.*?\*/|//[^\n]*", " ", p.read_text(), flags=re.S)
            code = re.sub(r"'(?:\\.|[^'\\\n])*'|\"(?:\\.|[^\"\\\n])*\"|`(?:\\.|[^`\\])*`", "''", code)
            found += [f"{p.name}: {m.group(0)!r}" for m in re.finditer(r"(?<![\w$.])h(?![\w$])", code)]
        self.assertEqual(found, [], "no identifier h in the panel: it is the JSX factory")

    def test_gate_records_and_the_scan_stamp_are_written_whole(self):
        """The panel reads them each minute: a write in place can be met half done."""
        import re
        bin_ = hub.Path(hub.__file__).resolve().parent
        found = [f"check_draft.py: {m.group(0)}" for m in
                 re.finditer(r"\.write_text\(json\.dumps\(", (bin_ / "check_draft.py").read_text())]
        found += [f"queue.py: {m.group(0)}" for m in re.finditer(r"stamp\.write_text\(", (bin_ / "queue.py").read_text())]
        self.assertEqual(found, [], "through hub.write_whole")


class WriteWhole(unittest.TestCase):
    def test_a_rename_that_fails_leaves_the_old_file_whole(self):
        with Env(now=NOW) as env:
            env.state.mkdir(parents=True)
            p = env.state / "Q0001.json"
            p.write_text('{"old": true}')
            with mock.patch.object(hub.os, "replace", side_effect=OSError("disk full")), \
                    self.assertRaises(OSError):
                hub.write_whole(p, '{"new": tru')
            self.assertEqual(p.read_text(), '{"old": true}')
            hub.write_whole(p, '{"new": true}')
            self.assertEqual((p.read_text(), sorted(x.name for x in env.state.iterdir())), ('{"new": true}', ["Q0001.json"]))


if __name__ == "__main__":
    unittest.main()
