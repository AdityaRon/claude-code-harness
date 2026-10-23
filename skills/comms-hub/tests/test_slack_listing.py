r"""slack_listing.py: JSON and text dumps, loud failure, the snapshot merge.

Mutations (run.py --mutate applies each and expects this file to fail):
  replies-kept: slack_listing.py: `if m.get("thread_ts") not in (None, ts):` => `if False:`
  float-ts-ok: slack_listing.py: `if not isinstance(ts, str):` => `if False:`
  empty-ok: slack_listing.py: `if not found:` => `if False:`
  keep-everything: slack_listing.py: `kept = {ts: c for ts, c in snapshot.items() if ts_key(ts) < oldest}` => `kept = dict(snapshot)`
  thread-reply-kept: slack_listing.py: `if th and th.group(1) != m.group(1):` => `if False:`
  bare-count-first: slack_listing.py: `r = re.search(REPLIES_LABELLED, block) or re.search(REPLIES_BARE, block)` => `r = re.search(REPLIES_BARE, block) or re.search(REPLIES_LABELLED, block)`
  string-order: slack_listing.py: `return "".join(f"{ts}\t{listing[ts]}\n" for ts in sorted(listing, key=ts_key))` => `return "".join(f"{ts}\t{listing[ts]}\n" for ts in sorted(listing))`
  concise-ok: slack_listing.py: `if page and not signal and not no_threads:` => `if False:`
  cursor-unchecked: slack_listing.py: `if ts_key(cursor) > ts_key(newest):` => `if False:`
  one-line-missed: slack_listing.py: `starts = list(re.finditer(TS_LINE_RE, text))` => `pass`
  envelope-missed: slack_listing.py: `return parse_text("\n".join(inner), ts_re, replies_re)` => `raise Unreadable("JSON")`
  second-document-dropped: slack_listing.py: `found.update(page)` => `found = page`
  full-object-not-a-signal: slack_listing.py: `or ("type" in m and "text" in m):` => `or False:`
  second-dump-dropped: slack_listing.py: `page.update(parse(open(dump).read(), *patterns(args), no_threads=args.no_threads))` => `page = parse(open(dump).read(), *patterns(args), no_threads=args.no_threads)`
"""
import base64
import contextlib
import io
import json
import unittest

from fakes import Env

import slack_listing as sl

A, B, C, D = "1761000000.000100", "1761000100.000200", "1761000200.000300", "1761000300.000400"


def cursor(ts):
    """Slack's next_cursor: base64 of next_ts:<the 16 digits of a ts>."""
    return base64.b64encode(f"next_ts:{ts.replace('.', '')}".encode()).decode()


class ShortReads(unittest.TestCase):
    def test_no_reply_count_anywhere_is_a_concise_read(self):
        dump = f"ts: {A}\nhello\nts: {B}\nhey\n"
        with self.assertRaisesRegex(sl.Unreadable, "concise"):
            sl.parse(dump)
        self.assertEqual(sl.parse(dump, no_threads=True), {A: 0, B: 0})
        with self.assertRaisesRegex(sl.Unreadable, "concise"):
            sl.parse(json.dumps({"messages": [{"ts": A, "text": "hello"}, {"ts": B, "text": "hey"}]}))
        self.assertEqual(sl.parse(json.dumps({"messages": [{"ts": A, "text": "hi", "reply_count": 0}, {"ts": B}]})),
                         {A: 0, B: 0})

    def test_a_page_of_full_api_message_objects_with_no_thread_is_a_full_read(self):
        # Slack puts reply_count only on a thread parent; type and text are on every message object.
        full = [{"type": "message", "ts": A, "user": "user-bob", "text": "hello"},
                {"type": "message", "ts": B, "user": "user-me", "text": "hey"}]
        self.assertEqual(sl.parse(json.dumps({"ok": True, "messages": full})), {A: 0, B: 0})

    def test_a_cursor_newer_than_the_page_means_oldest_was_passed(self):
        with self.assertRaisesRegex(sl.Unreadable, "read with oldest"):
            sl.parse(f"ts: {A}\nreplies: 1\nts: {B}\nhey\nnext_cursor: {cursor(D)}\n")
        with self.assertRaisesRegex(sl.Unreadable, "read with oldest"):
            sl.parse(json.dumps({"messages": [{"ts": B, "reply_count": 1}, {"ts": A}],
                                 "response_metadata": {"next_cursor": cursor(D)}}))
        older = json.dumps({"messages": [{"ts": B, "reply_count": 1}, {"ts": A}],
                            "response_metadata": {"next_cursor": cursor("1760999999.000900")}})
        self.assertEqual(sl.parse(older), {B: 1, A: 0})
        self.assertEqual(sl.parse(f"ts: {A}\nreplies: 1\ncursor: next_ts:1760999999000900\n"), {A: 1})


class Shapes(unittest.TestCase):
    def test_one_line_dump(self):
        dump = f"[{A}] alice: hi (3 replies)\n[{B}] bob: hey\n[{C}] (thread_ts: {A}) alice: a reply\n"
        self.assertEqual(sl.parse(dump), {A: 3, B: 0})

    def test_the_tools_json_envelope_around_a_text_dump(self):
        dump = json.dumps({"content": [{"type": "text", "text": f"ts: {A}\nreplies: 2\nhello\nts: {B}\nhey\n"}]})
        self.assertEqual(sl.parse(dump), {A: 2, B: 0})

    def test_several_json_documents_in_one_file_are_one_page(self):
        dump = (json.dumps({"messages": [{"ts": C, "reply_count": 1}]}) + "\n"
                + json.dumps({"messages": [{"ts": A, "reply_count": 2}, {"ts": B}]}) + "\n")
        self.assertEqual(sl.parse(dump), {C: 1, A: 2, B: 0})

    def test_several_dumps_make_one_listing(self):
        with Env() as env:
            (env.dir / "p1.txt").write_text(f"ts: {C}\nreplies: 1\n")
            (env.dir / "p2.txt").write_text(f"ts: {A}\nreplies: 2\nts: {B}\n")
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rc = sl.main([str(env.dir / "p1.txt"), str(env.dir / "p2.txt"), "-o", str(env.dir / "out.tsv")])
            self.assertEqual(rc, 0, err.getvalue())
            self.assertEqual((env.dir / "out.tsv").read_text(), f"{A}\t2\n{B}\t0\n{C}\t1\n")
            self.assertIn("3 lines (3 from 2 pages)", err.getvalue())


class Parse(unittest.TestCase):
    def test_slack_api_json(self):
        dump = json.dumps({"ok": True, "messages": [
            {"ts": B, "reply_count": 3, "thread_ts": B},
            {"ts": A},
            {"ts": C, "thread_ts": B, "subtype": "thread_broadcast"},
        ]})
        self.assertEqual(sl.parse(dump), {B: 3, A: 0})

    def test_float_ts_is_refused(self):
        with self.assertRaisesRegex(sl.Unreadable, "not a string"):
            sl.parse(json.dumps({"messages": [{"ts": 1761000000.0001}]}))

    def test_labelled_text(self):
        dump = (f"## Message 1\n**User**: someone\nts: {A}\nhello\nThread replies: 4\n"
                f"## Message 2\nMessage TS: {B}\nno thread here\n"
                f"## Message 3\n- timestamp = \"{C}\"\n(2 replies)\n")
        self.assertEqual(sl.parse(dump), {A: 4, B: 0, C: 2})

    def test_a_labelled_count_beats_the_message_text(self):
        dump = f"ts: {A}\nI sent 3 replies to the vendor already\nreplies: 5\n"
        self.assertEqual(sl.parse(dump), {A: 5})

    def test_a_reply_listed_in_the_page_is_not_a_top_level_message(self):
        dump = f"ts: {A}\nreplies: 1\nts: {B}\nthread_ts: {A}\nhello, a reply\n"
        self.assertEqual(sl.parse(dump), {A: 1})

    def test_unrecognised_or_empty_input_is_an_error(self):
        for dump in ("", "   \n", "Here are the messages:\nhello there\n", json.dumps({"ok": True})):
            with self.assertRaises(sl.Unreadable, msg=repr(dump)):
                sl.parse(dump)

    def test_custom_patterns(self):
        dump = f"[{A}] (r=2) hi\n[{B}] hey\n"
        self.assertEqual(sl.parse(dump, r"(?m)^\[(\d{10}\.\d{6})\]", r"\(r=(\d+)\)"), {A: 2, B: 0})


class Merge(unittest.TestCase):
    def test_older_than_page_kept_the_rest_replaced(self):
        snapshot = {A: 1, B: 2, C: 0}
        page = {B: 5, D: 0}             # C was deleted inside the page window
        self.assertEqual(sl.merge(snapshot, page), {A: 1, B: 5, D: 0})

    def test_render_orders_by_number_not_by_string(self):
        short = "999999999.000001"      # nine digits sorts after ten as a string
        self.assertEqual(sl.render({A: 0, short: 1}).splitlines()[0], f"{short}\t1")


if __name__ == "__main__":
    unittest.main()
