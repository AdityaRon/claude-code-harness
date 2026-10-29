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
  scans-in-events: hub.py: `for r in reversed(today) if r["kind"] not in UNSHOWN]` => `for r in reversed(today) if r["kind"] != "scan"]`
  todo-counts-as-an-item: hub.py: `if r["kind"] not in UNSHOWN + ("tick", "setup")] if scans else []` => `if r["kind"] not in ("scan", "tick", "setup")] if scans else []`
  moved-head-ignored: hub.py: `moved = bool(p.get("my_sha")) and p["my_sha"] != p["head"]` => `moved = False`
  moved-still-approvable: hub.py: `"new commits" if moved else verdict` => `verdict or ("new commits" if moved else "")`
  verdict-unshown: hub.py: `verdicts[f"{m.group(1)}/{m.group(2)}#{m.group(3)}"] = r["text"]` => `pass`
  asked-not-needs: hub.py: `"needs": bool(moved or verdict or asked)` => `"needs": bool(moved or verdict)`
  merge-not-needs: hub.py: `merge_me = p.get("decision") == "APPROVED" and p.get("merge") in MERGEABLE` => `merge_me = False`
  needs-unsorted: hub.py: `rows.sort(key=lambda r: (not r["needs"], r["group"] != "reviewing", short_ref(cfg, r["ref"])))` => `rows.sort(key=lambda r: short_ref(cfg, r["ref"]))`
  repo-needs-uncounted: hub.py: `c[0] += r["needs"]` => `pass`
  old-file-live: hub.py: `stale = written is None or now() - written > dt.timedelta(minutes=2 * every) \` => `stale = written is None or False \`
  blocked-scan-live: hub.py: `or bool(last_scan and last_scan - written > dt.timedelta(minutes=1))` => `or False`
  bad-file-crashes: hub.py: `except (OSError, ValueError, KeyError, TypeError):
        data, written = None, None` => `except OSError:
        data, written = None, None`
  strip-weekends: hub.py: `if DAYS[day.weekday()] in cfg["active_hours"]["days"]:` => `if True:`
  strip-uncounted: hub.py: `counts[r["day"]][r["event"]] += 1` => `pass`
  events-oldest-first: hub.py: `for r in reversed(today) if` => `for r in today if`
  last-tick-counts-all: hub.py: `r in raw[scans[-1] + 1:]` => `r in raw`
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
        self.assertEqual((p["day"], p["last_tick"], p["next_tick"], p["read"]), ("Wed 21 Oct", "1 item", "10:07", "10:00"))

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
                         ([], [], [], [], [], "", "none yet"))
        self.assertEqual((p["prs"]["rows"], p["prs"]["stale"], p["prs"]["as_of"]), ([], True, ""))

    def test_the_scans_own_bookkeeping_stays_out_of_the_events(self):
        with Env(now=NOW) as env:
            main_out("log", "--kind", "scan", "scan started", now="2026-10-21T16:45:00+00:00")
            main_out("log", "--kind", "todo", "review requested", now="2026-10-21T16:46:00+00:00")
            main_out("log", "--kind", "done", "--corrects", "1021.2", "review posted at the head",
                     now="2026-10-21T16:47:00+00:00")
            p = json.loads(main_out("panel")[1])
        self.assertEqual((p["events"], p["last_tick"]), ([], "quiet"), "a quiet tick does not read as 2 items")


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
            self.assertEqual((p["stale"], p["as_of"], p["age"]), (True, "08:30", "1h"))
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


if __name__ == "__main__":
    unittest.main()
