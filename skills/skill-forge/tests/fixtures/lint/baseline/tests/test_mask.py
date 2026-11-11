"""Tests for the stand-in mask.py (a lint fixture).

Mutations that must turn this file red:
  no-newline: mask.py: `str(text) + "\\n"` => `str(text)`
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin"))
import mask  # noqa: E402


class MaskTest(unittest.TestCase):
    def test_header_names_the_target(self):
        self.assertIn("# target:  x", mask.header("x", "n/a"))


if __name__ == "__main__":
    unittest.main()
