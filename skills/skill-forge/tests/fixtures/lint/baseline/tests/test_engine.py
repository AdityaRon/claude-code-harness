"""Tests for engine.py (a lint fixture: the lint reads these names, nothing runs them).

Mutations that must turn this file red:
  no-quote: engine.py: `value.replace("'", "''")` => `value`
  no-apply-gate: engine.py: `a.cmd == "flip" and not a.apply` => `False`
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin"))
import engine  # noqa: E402


class EngineTest(unittest.TestCase):
    def test_flip_is_a_dry_run_without_apply(self):
        self.assertEqual(engine.main(["flip", "t1", "f1"]), 0)

    def test_guard_absent_no_rows_exits_2(self):
        self.assertTrue(engine.read_only("SELECT 1"))

    def test_guard_partial_is_flagged(self):
        self.assertTrue(engine.read_only("SELECT 1"))

    def test_golden_header(self):
        self.assertIn("flags", engine.show_sql("t1"))

    def test_mask_planted_tenant(self):
        self.assertTrue(callable(engine.emit))

    def test_quoting_a_tenant_with_a_quote(self):
        self.assertEqual(engine.quote("o'neil"), "'o''neil'")

    def test_write_and_audit_one_transaction(self):
        self.assertTrue(engine.flip_sql("t", "f").startswith("BEGIN;"))


if __name__ == "__main__":
    unittest.main()
