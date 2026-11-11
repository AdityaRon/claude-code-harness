"""Tests for sqlguard.py, the client-side read-only layers. skill-forge copies
this file into every sql-readonly skill it drafts, unchanged.

Mutations that must turn this file red:
  no-nested-write-scan: sqlguard.py: `if up in WRITE_WORDS:` => `if False:`
  strings-are-words: sqlguard.py: `elif c == "'":` => `elif False:`
  dollar-bodies-are-words: sqlguard.py: `if j < n and sql[j] == "$":` => `if False:`
  comments-are-words: sqlguard.py: `elif sql.startswith("--", i):` => `elif False:`
  many-statements: sqlguard.py: `if len(stmts) > 1:` => `if False:`
  backslash-ok: sqlguard.py: `if any(k == "backslash" for k, _ in toks):` => `if False:`
  side-effect-funcs-ok: sqlguard.py: `if nxt == ("punct", "(") and v.lower() in SIDE_EFFECT_FUNCS:` => `if False:`
  quoted-funcs-ok: sqlguard.py: `if k == "qident" and idx + 1 < len(st)` => `if False and k == "qident" and idx + 1 < len(st)`
  unterminated-guessed: sqlguard.py: `raise Unterminated("an unterminated '' string")` => `break`
  no-allowlist: sqlguard.py: `if st[0][0] != "word" or first not in ALLOW_FIRST:` => `if False:`
  analyze-anywhere: sqlguard.py: `if up == "ANALYZE" and not _explain_option(st, idx):` => `if False:`
  select-into-ok: sqlguard.py: `"REASSIGN", "INTO", "SHARE",` => `"REASSIGN",`
"""
from __future__ import annotations

import io
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
import sqlguard  # noqa: E402


class CorpusTest(unittest.TestCase):
    def test_every_must_pass_passes(self):
        for q in sqlguard.MUST_PASS:
            with self.subTest(q=q):
                ok, why = sqlguard.check(q)
                self.assertTrue(ok, why)

    def test_every_must_block_is_blocked(self):
        for q in sqlguard.MUST_BLOCK:
            with self.subTest(q=q):
                self.assertFalse(sqlguard.check(q)[0])

    def test_self_test_exits_zero_and_counts(self):
        out = io.StringIO()
        self.assertEqual(sqlguard.self_test(out), 0)
        self.assertIn("0 missed", out.getvalue())

    def test_the_corpus_holds_the_named_cases(self):
        must = " | ".join(sqlguard.MUST_BLOCK)
        for case in ("WITH x AS (DELETE", "SELECT * INTO", "FOR UPDATE", "EXPLAIN ANALYZE DELETE", "COPY", "CALL",
                     "set_config", "\\!", "; DELETE"):
            self.assertIn(case, must)


class ReasonTest(unittest.TestCase):
    def reason(self, q: str) -> str:
        ok, why = sqlguard.check(q)
        self.assertFalse(ok, q)
        return why

    def test_reasons_name_the_layer(self):
        self.assertIn("2 statements", self.reason("SELECT 1; SELECT 2"))
        self.assertIn("DELETE inside", self.reason("WITH x AS (DELETE FROM t RETURNING 1) SELECT 1"))
        self.assertIn("backslash", self.reason("SELECT 1 \\gexec"))
        self.assertIn("side effects", self.reason("SELECT pg_terminate_backend(42)"))
        self.assertIn("side effects", self.reason('SELECT "lo_export"(1, $$/tmp/x$$)'))
        self.assertIn("unterminated", self.reason("SELECT 'x"))
        self.assertIn("leads with 'COPY'", self.reason("COPY t TO STDOUT"))

    def test_an_injection_inside_a_string_stays_a_string(self):
        self.assertTrue(sqlguard.check("SELECT * FROM t WHERE name = 'x''; DELETE FROM t; --'")[0])

    def test_a_write_keyword_in_a_dollar_body_is_data(self):
        self.assertTrue(sqlguard.check("SELECT $q$ update t set a = 1 $q$")[0])


class CliTest(unittest.TestCase):
    def run_cli(self, *args, stdin=""):
        return subprocess.run([sys.executable, "-B", str(HERE.parent / "bin" / "sqlguard.py"), *args],
                              input=stdin, capture_output=True, text=True)

    def test_check_exit_codes(self):
        self.assertEqual(self.run_cli("--check", stdin="SELECT 1").returncode, 0)
        p = self.run_cli("--check", stdin="DELETE FROM t")
        self.assertEqual(p.returncode, 5)
        self.assertIn("BLOCKED", p.stdout)

    def test_self_test_cli(self):
        self.assertEqual(self.run_cli("--self-test").returncode, 0)


if __name__ == "__main__":
    unittest.main()
