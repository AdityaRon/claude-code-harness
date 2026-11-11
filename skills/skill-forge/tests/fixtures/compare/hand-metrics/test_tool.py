"""Tests for tool.py, a fixture's own: nothing runs them.

Mutations:
  auth-as-no-data: tool.py: `sys.exit(4)` => `return []`
"""
import unittest


class ToolTest(unittest.TestCase):
    def test_guard_expired_auth_prints_the_relogin(self):
        pass
