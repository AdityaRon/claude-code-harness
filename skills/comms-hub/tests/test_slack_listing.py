r"""slack_listing.py: JSON and text dumps, loud failure, the snapshot merge.

Mutations (run.py --mutate applies each and expects this file to fail):
  replies-kept: slack_listing.py: `if m.get("thread_ts") not in (None, ts):` => `if False:`
  float-ts-ok: slack_listing.py: `if not isinstance(ts, str):` => `if False:`
  empty-ok: slack_listing.py: `if not found:` => `if False:`
  keep-everything: slack_listing.py: `kept = {ts: c for ts, c in snapshot.items() if ts_key(ts) < oldest}` => `kept = dict(snapshot)`
  string-order: slack_listing.py: `return "".join(f"{ts}\t{listing[ts]}\n" for ts in sorted(listing, key=ts_key))` => `return "".join(f"{ts}\t{listing[ts]}\n" for ts in sorted(listing))`
"""
import json
import unittest

import fakes  # noqa: F401  (puts bin/ on sys.path)
import slack_listing as sl

A, B, C, D = "1761000000.000100", "1761000100.000200", "1761000200.000300", "1761000300.000400"


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
