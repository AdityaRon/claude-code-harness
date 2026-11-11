"""Tests for mask.py, the output path. skill-forge copies this file into every
skill it drafts, unchanged.

Mutations that must turn this file red:
  no-userinfo: mask.py: `("url userinfo", r"(?<=://)[^/\\s@]+(?=@)"),` => ``
  no-email: mask.py: `[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+` => `[A-Za-z0-9._%+-]+@NEVER[A-Za-z0-9-]+`
  versions-as-email: mask.py: `*\.[A-Za-z]{2,}(?![\w.:-])` => `*\.[A-Za-z0-9]{2,}(?![\w.:-])`
  config-ignored: mask.py: `for src in (config_path(), skill / "forge.toml"):` => `for src in (skill / "forge.toml",):`
  skill-manifest-ignored: mask.py: `for src in (config_path(), skill / "forge.toml"):` => `for src in (config_path(),):`
  bad-pattern-tolerated: mask.py: `raise SystemExit(f"mask: pattern` => `print(f"mask: pattern`
  stderr-unmasked: mask.py: `stream.write(masker()(str(text)) + "\\n")` => `stream.write(str(text) + "\\n")`
  ids-renumbered: mask.py: `if key not in self.seen:` => `if True:`
  partial-hidden: mask.py: `f"# partial: {'YES: ' + partial if partial else 'no'}",` => `"# partial: no",`
  window-optional: mask.py: `if not str(window).strip():` => `if False:`
  naive-time-accepted: mask.py: `raise ValueError(f"{text!r} has no timezone` => `return t.replace(tzinfo=timezone.utc)  # (`
  window-backwards: mask.py: `if end < start:` => `if False:`
"""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
import mask  # noqa: E402

T0 = datetime(2026, 11, 10, 5, 0, tzinfo=timezone.utc)


class Config:
    """A config file with these mask patterns, for the length of a with-block."""

    def __init__(self, patterns=(), manifest_patterns=()):
        self.patterns, self.manifest = patterns, manifest_patterns

    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory()
        cfg = Path(self.tmp.name) / "config.toml"
        cfg.write_text("[mask]\npatterns = " + json.dumps(list(self.patterns)) + "\n")
        skill = Path(self.tmp.name) / "skill"
        skill.mkdir()
        (skill / "forge.toml").write_text("[mask]\npatterns = " + json.dumps(list(self.manifest)) + "\n")
        self.env = mock.patch.dict(os.environ, {"SKILL_FORGE_CONFIG": str(cfg)})
        self.env.start()
        self.skill = mock.patch.object(mask, "SKILL", skill)
        self.skill.start()
        mask._MASKER = None
        return self

    def __exit__(self, *exc):
        self.skill.stop()
        self.env.stop()
        mask._MASKER = None
        self.tmp.cleanup()


def printed(fn, *args, **kw) -> tuple[str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        fn(*args, **kw)
    return out.getvalue(), err.getvalue()


class MaskerTest(unittest.TestCase):
    def test_builtins_mask_url_userinfo_email_and_bearer(self):
        with Config():
            out, _ = printed(mask.emit, "http://admin:pw@db:9090 ops.lead@example.com Bearer abcdefghijkl")
        self.assertNotIn("admin:pw", out)
        self.assertNotIn("ops.lead@example.com", out)
        self.assertNotIn("abcdefghijkl", out)
        self.assertIn("http://<masked-1>@db:9090", out)

    def test_a_git_remote_stays_readable(self):
        with Config():
            out, _ = printed(mask.emit, "git@github.com:org/repo.git")
        self.assertEqual(out, "git@github.com:org/repo.git\n")

    def test_a_versioned_package_path_is_not_an_email(self):
        with Config():
            out, _ = printed(mask.emit, "/opt/homebrew/Cellar/python@3.11/3.11.15/bin")
        self.assertEqual(out, "/opt/homebrew/Cellar/python@3.11/3.11.15/bin\n")

    def test_mask_planted_pattern_from_the_config(self):
        with Config(patterns=[r"\bcust-[a-z]+"]):
            out, _ = printed(mask.emit, "tenant cust-acme drove 80%")
        self.assertEqual(out, "tenant <masked-1> drove 80%\n")

    def test_mask_planted_pattern_from_the_skills_own_manifest(self):
        with Config(manifest_patterns=[r"\bacct-\d+"]):
            out, _ = printed(mask.emit, "acct-42")
        self.assertEqual(out, "<masked-1>\n")

    def test_equal_ids_share_a_number_and_different_ids_do_not(self):
        with Config(patterns=[r"\bcust-[a-z]+"]):
            out, _ = printed(mask.emit, "cust-a cust-b cust-a")
        self.assertEqual(out, "<masked-1> <masked-2> <masked-1>\n")

    def test_stderr_is_masked_too(self):
        with Config(patterns=[r"\bcust-[a-z]+"]):
            _, err = printed(mask.emit, "no rows for cust-acme", err=True)
        self.assertEqual(err, "no rows for <masked-1>\n")

    def test_a_pattern_that_does_not_compile_stops_the_program(self):
        with Config(patterns=["(unclosed"]):
            with self.assertRaises(SystemExit) as cm:
                mask.masker()
        self.assertIn("does not compile", str(cm.exception))


class HeaderTest(unittest.TestCase):
    def test_golden_provenance_header(self):
        w = mask.Window(T0, T0 + timedelta(hours=1), step="60s")
        got = mask.header("prometheus http://p:9090", w, ["eng.py", "query", "up"], rows=3, partial="series cap 2 of 5")
        self.assertEqual(got, "\n".join([
            "# target:  prometheus http://p:9090",
            "# window:  2026-11-10T05:00:00Z .. 2026-11-10T06:00:00Z (UTC, bounds [start, end], step 60s)",
            "# command: eng.py query up",
            "# rows:    3",
            "# partial: YES: series cap 2 of 5",
        ]))

    def test_complete_says_partial_no(self):
        self.assertTrue(mask.header("t", "n/a: now", "c", rows=0).endswith("# partial: no"))

    def test_the_window_is_required(self):
        with self.assertRaises(ValueError):
            mask.header("t", "  ", "c")

    def test_a_window_cannot_run_backwards(self):
        with self.assertRaises(ValueError):
            mask.Window(T0, T0 - timedelta(seconds=1))


class TimeTest(unittest.TestCase):
    def test_a_time_without_a_zone_is_refused(self):
        with self.assertRaises(ValueError) as cm:
            mask.parse_time("2026-11-10T05:00:00")
        self.assertIn("timezone", str(cm.exception))

    def test_relative_and_zoned_times(self):
        self.assertEqual(mask.parse_time("now-1h30m", now=T0), T0 - timedelta(minutes=90))
        self.assertEqual(mask.parse_time("2026-11-10T05:00:00Z"), T0)
        self.assertEqual(mask.parse_time("2026-11-09T21:00:00-08:00"), T0)

    def test_durations(self):
        self.assertEqual(mask.parse_duration("1h30m"), timedelta(minutes=90))
        for bad in ("", "1x", "h1", "1h 30m"):
            with self.assertRaises(ValueError, msg=bad):
                mask.parse_duration(bad)


if __name__ == "__main__":
    unittest.main()
