"""Tests for heredocs.py, the heredoc reader demand.py and skill_lint.py share. Its
oracle is bash itself, in tests/heredoc-openers.test.sh at the repo root (through
demand.py and skill_lint.py); these hold the rules it relies on to one case each.

Mutations that must turn this file red:
  quotes-ignored: heredocs.py: `            elif c == '"':
                self.q = '"'` => `            elif c == '"':
                pass`
  comment-read-as-code: heredocs.py: `                if not self.bt and not (self.frames and self.frames[-1][2]):
                    break` => `                if False:
                    break`
  second-opener-read: heredocs.py: `w = None if self.bt or found or` => `w = None if self.bt or`
  open-quote-at-opener-passes: heredocs.py: `        if found and (self.q or self.cont):` => `        if found and self.cont:`
  terminator-lenient: heredocs.py: `t = s.lstrip("\\t") if dash else s` => `t = s.strip()`
  dash-ignored: heredocs.py: `t = s.lstrip("\\t") if dash else s` => `t = s`
  insub-paren-passes: heredocs.py: `if self.insub and (t == term + ")" or self.body(s)):` => `if self.insub and t == term + ")":`
  open-quote-tail-dropped: heredocs.py: `                self.tail = "`" if self.hbq == "B" else self.hbq` => `                pass`
"""
from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
from heredocs import main, roles  # noqa: E402


class OpenersTest(unittest.TestCase):
    def test_a_real_opener_and_its_body(self):
        self.assertEqual(roles("cat <<EOF\n# data\nEOF\nls"), "obec")
        self.assertEqual(roles("cat <<-'END'\n\t# data\n\tEND\nls"), "obec")

    def test_a_quoted_or_commented_double_lt_opens_nothing(self):
        self.assertEqual(roles('echo "a <<EOF"\n# --apply\nEOF'), "ccc")
        self.assertEqual(roles("true # <<EOF\n# --apply\nEOF"), "ccc")
        self.assertEqual(roles("x=$((1<<2))\ncat <<<'a'\n# d"), "ccc")

    def test_the_terminator_is_exact(self):
        self.assertEqual(roles("cat <<EOF\n  EOF\n# x\nEOF\nls"), "obbec")
        self.assertEqual(roles("cat <<EOF\n\tEOF\nEOF"), "obe")

    def test_what_it_cannot_read_raises(self):
        self.assertEqual(roles("cat <<A <<B\na\nA"), "u")                   # two openers on one line
        self.assertEqual(roles('cat <<x "\n" ; \\\nls\nx'), "u")             # a quote left open
        self.assertEqual(roles("x=$(cat <<'EOF'\n)\nls\nEOF\n)"), "ou")      # bash 3.2 ends the $( ) at the )

    def test_the_command_line_prints_the_roles(self):
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write("cat <<EOF\n# data\nEOF\n")
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                rc = main([f.name])
        finally:
            os.unlink(f.name)
        self.assertEqual((rc, out.getvalue()), (0, "obec\n"))

    def test_a_quote_a_body_leaves_open_reaches_later_lines(self):
        self.assertEqual(roles("x=$(cat <<'EOF'\nit's\nEOF\n)\necho '"), "obecu")


if __name__ == "__main__":
    unittest.main()
