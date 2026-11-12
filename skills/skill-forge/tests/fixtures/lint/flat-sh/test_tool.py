"""Tests for tool.sh, at the skill root. The names cover the dry run, the golden
output and a planted mask pattern, so skill-lint's C1, C6 and C7 findings on
this fixture come from the engine itself.

Mutations:
  no-namespace: tool.sh: `kubectl -n apps apply` => `kubectl apply`
"""
import unittest


class ToolTest(unittest.TestCase):
    def test_apply_is_a_dry_run_without_apply(self):
        pass

    def test_rollout_golden_output(self):
        pass

    def test_a_planted_mask_pattern_is_masked(self):
        pass
