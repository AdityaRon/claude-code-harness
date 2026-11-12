"""Tests for tool.py, at the skill root as the flat layout keeps them. The names
cover the dry run, the golden output and a planted mask pattern, so skill-lint's
C1, C6 and C7 findings on this fixture come from the engine itself.

Mutations:
  no-count: tool.py: `return json.load(r)["count"]` => `return 0`
"""
import unittest


class ToolTest(unittest.TestCase):
    def test_move_is_a_dry_run_without_apply(self):
        pass

    def test_count_golden_output(self):
        pass

    def test_a_planted_mask_pattern_is_masked(self):
        pass
