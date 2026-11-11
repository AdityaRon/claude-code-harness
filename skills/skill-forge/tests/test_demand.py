"""Tests for demand.py on fixture transcripts built here. One sequence is
planted in four sessions; decoys beat it on each single factor (more sessions,
more steps, a higher failure rate) and lose on the product.

Mutations that must turn this file red:
  steps-ignored: demand.py: `c["sessions"] * c["steps"] * smoothed(` => `c["sessions"] * smoothed(`
  sessions-ignored: demand.py: `c["sessions"] * c["steps"] * smoothed(` => `c["steps"] * smoothed(`
  failures-ignored: demand.py: `* smoothed(c["failures"], c["attempts"])` => `* 1`
  unsmoothed: demand.py: `return (fails + 1) / (attempts + 2)` => `return fails / attempts if attempts else 0`
  ids-in-shapes: demand.py: `if b and len(v2[(p, a, b)]) >= 3:` => `if b:`
  sidechains-counted: demand.py: `if not isinstance(rec, dict) or rec.get("isSidechain"):` => `if not isinstance(rec, dict):`
  exit-code-text-ignored: demand.py: ` or bool(re.match(r"Exit code [1-9]", body or ""))` => ``
  subsumed-kept: demand.py: `if any(k["kind"] == "sequence" and c["_sids"] <= k["_sids"]` => `if False and any(k["kind"] == "sequence" and c["_sids"] <= k["_sids"]`
  partial-hidden: demand.py: `partial=f"{bad} unreadable transcript lines or files skipped" if bad else None` => `partial=None`
  label-unmasked: demand.py: `c["label"] = m(c["label"])[:80]` => `c["label"] = c["label"][:80]`
  history-ignored: demand.py: `hist = read_history(hfiles, since, ignore)` => `hist = []`
  questions-dropped: demand.py: `out.append({"kind": "question"` => `(lambda d: None)({"kind": "question"`
  filters-as-steps: demand.py: `if r and r[0] not in FILTERS:` => `if r:`
  arguments-as-verbs: demand.py: `while prog in SUBCOMMANDS and j < len(rest)` => `while j < len(rest)`
  redirections-as-steps: demand.py: `cmd = REDIRECT.sub(" ", cmd.replace("\\n", " ; "))` => `cmd = cmd.replace("\\n", " ; ")`
  numbers-as-programs: demand.py: `r"[A-Za-z_.][A-Za-z0-9_.+-]{0,39}"` => `r"[A-Za-z0-9_.+-]{1,40}"`
  briefs-as-questions: demand.py: `if len(w) >= 2 and len(t) <= MAX_PROMPT:` => `if len(w) >= 2:`
  question-steps-uncapped: demand.py: `min(MAX_QUESTION_STEPS, round(` => `min(10**6, round(`
  shell-keywords-as-steps: demand.py: `"do", "then", "else", "elif", "if", "while", "until", "!", "{"}` => `}`
  unanswered-questions-kept: demand.py: `if len(c["sids"]) >= min_sessions and steps >= 1:` => `if len(c["sids"]) >= min_sessions:`
"""
from __future__ import annotations

import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
import demand  # noqa: E402
import mask  # noqa: E402

NOW = datetime.now(timezone.utc)
PODS = ["web-alpha", "web-bravo", "web-charlie", "web-delta"]
OPENERS = ["checkout is throwing errors", "payments look slow today", "orders stuck in pending", "cart page returns a 500"]
PLANTED = "kubectl get pods → kubectl logs → curl"


def P(text):
    return ("prompt", text)


def B(cmd, err=False, text="ok"):
    return ("bash", cmd, err, text)


def planted(i: int) -> list:
    # The first logs attempt fails: half the sessions say so with is_error, half only in the text.
    fail = B(f"kubectl logs {PODS[i]} -n web --tail 200", err=i % 2 == 0, text="Exit code 1\nError from server (NotFound)")
    return [P(OPENERS[i]),
            B("kubectl get pods -n web | grep web"), fail,
            B(f"kubectl logs {PODS[i]} -n web --tail 200 | tail -50"),
            B("curl -s https://checkout.internal.example/healthz | jq .status")]


class Transcripts:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="demand-test."))
        self.dir = self.tmp / "projects"
        self.n = 0

    def session(self, events: list, project="-home-me-code-ops", days_ago=1, sidechain=False, extra_lines=()):
        self.n += 1
        sid = f"{self.n:08d}-0000-4000-8000-000000000000"
        t = NOW - timedelta(days=days_ago)
        lines, k = [], 0
        for ev in events:
            t += timedelta(seconds=30)
            ts = t.strftime("%Y-%m-%dT%H:%M:%S.000Z")
            if ev[0] == "prompt":
                lines.append({"type": "user", "sessionId": sid, "timestamp": ts, "message": {"role": "user", "content": ev[1]}})
                continue
            _, cmd, err, text = ev
            uid = f"toolu_{self.n}_{k}"
            k += 1
            lines.append({"type": "assistant", "sessionId": sid, "timestamp": ts, "isSidechain": sidechain,
                          "message": {"role": "assistant", "content": [{"type": "tool_use", "id": uid, "name": "Bash", "input": {"command": cmd}}]}})
            lines.append({"type": "user", "sessionId": sid, "timestamp": ts, "isSidechain": sidechain,
                          "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": uid, "is_error": err, "content": text}]}})
        d = self.dir / project
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{sid}.jsonl").write_text("\n".join([json.dumps(x) for x in lines] + list(extra_lines)) + "\n")

    def standard(self):
        for i in range(4):
            self.session(planted(i), project="-home-me-code-ops" if i < 2 else "-home-me-code-api", days_ago=i + 1)
        for i in range(7):   # more sessions, never fails
            self.session([B("make build"), B("make test")], project="-home-me-code-app", days_ago=i + 1)
        for i in range(2):   # more steps
            self.session([B("terraform init"), B("terraform plan"), B("terraform apply"), B("aws s3 ls"), B("gh pr create")], days_ago=i + 1)
        for i in range(2):   # a higher failure rate
            self.session([B("npm test", True), B("npm test", True), B("npm test", True)], project="-home-me-code-web", days_ago=i + 1)
        for i, q in enumerate(["why did the nightly export job fail", "the nightly export job failed again, why",
                               "nightly export job failure, what happened"]):
            self.session([P(q), B("aws logs tail /export"), B("aws batch describe-jobs")], project="-home-me-code-data", days_ago=i + 1)
        return self

    def run(self, *argv, config=""):
        cfg = self.tmp / "config.toml"
        cfg.write_text('[mask]\npatterns = ["\\\\bcust-[a-z]+"]\n' + config)
        out, err = io.StringIO(), io.StringIO()
        mask._MASKER = None
        with mock.patch.dict(os.environ, {"SKILL_FORGE_CONFIG": str(cfg), "HOME": "/home/me"}), redirect_stdout(out), redirect_stderr(err):
            rc = demand.main(["--transcripts", str(self.dir), "--history", str(self.tmp / "none"), *argv])
        mask._MASKER = None
        return rc, out.getvalue(), err.getvalue()

    def ranked(self, *argv):
        rc, out, _ = self.run("--json", "--top", "50", *argv)
        assert rc == 0
        return json.loads(out)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class RankTest(unittest.TestCase):
    def setUp(self):
        self.t = Transcripts().standard()

    def tearDown(self):
        self.t.close()

    def test_the_planted_sequence_ranks_first(self):
        top = self.t.ranked()[0]
        self.assertEqual((top["kind"], top["label"], top["sessions"], top["steps"]), ("sequence", PLANTED, 4, 3))
        self.assertEqual(top["failures"], 4)

    def test_each_decoy_beats_it_on_one_factor_and_loses_overall(self):
        ranked = self.t.ranked()
        by = {c["label"]: c for c in ranked}
        planted_c = by[PLANTED]
        make = by["make build → make test"]
        tf = by["terraform init → terraform plan → terraform apply → aws s3 → gh pr"]
        npm = [c for c in ranked if c["kind"] == "failing" and c["label"] == "npm test"][0]
        self.assertGreater(make["sessions"], planted_c["sessions"])
        self.assertGreater(tf["steps"], planted_c["steps"])
        self.assertGreater(npm["failures"] / npm["attempts"], planted_c["failures"] / planted_c["attempts"])
        for c in (make, tf, npm):
            self.assertLess(c["score"], planted_c["score"])

    def test_a_sequence_that_never_failed_still_scores(self):
        self.assertGreater(self.t.ranked()[1:][0]["score"], 0)
        make = [c for c in self.t.ranked() if c["label"] == "make build → make test"][0]
        self.assertGreater(make["score"], 0)

    def test_a_repeated_question_is_a_candidate(self):
        qs = [c for c in self.t.ranked() if c["kind"] == "question"]
        self.assertEqual([(q["sessions"], q["steps"]) for q in qs], [(3, 2)], qs)
        self.assertIn("nightly export job", qs[0]["label"])

    def test_no_sub_sequence_of_the_planted_one_is_listed_separately(self):
        for c in self.t.ranked():
            if c["kind"] == "sequence" and c["label"] != PLANTED:
                self.assertFalse(c["label"] in PLANTED and c["sessions"] <= 4, c["label"])

    def test_no_argument_id_or_url_reaches_the_output(self):
        _, out, _ = self.t.run("--top", "50")
        for leak in PODS + ["checkout.internal.example", "healthz", "Error from server", "/export", "--tail"]:
            self.assertNotIn(leak, out)

    def test_ignore_drops_a_program(self):
        labels = [c["label"] for c in self.t.ranked("--ignore", "kubectl")]
        self.assertFalse(any("kubectl" in lb for lb in labels))

    def test_golden_provenance_header(self):
        _, out, _ = self.t.run()
        lines = out.splitlines()
        self.assertEqual(lines[0], "# target:  18 transcript sessions in 5 projects; 0 shell-history sessions")
        self.assertRegex(lines[1], r"^# window:  \S+Z \.\. \S+Z \(UTC, bounds sessions modified in \[start, end\]\)$")
        self.assertEqual(lines[3], "# rows:    7")
        self.assertEqual(lines[4], "# partial: no")
        self.assertTrue(lines[6].startswith(" 1. score 3.33   sequence  " + PLANTED), lines[6])
        self.assertRegex(lines[7], r"4 sessions · 3 steps · 16 attempts, 4 failed · e\.g\. \d{4}-\d\d-\d\d \(code-ops, 00000001\)")


class InputTest(unittest.TestCase):
    def setUp(self):
        self.t = Transcripts()

    def tearDown(self):
        self.t.close()

    def test_an_unreadable_line_marks_the_run_partial(self):
        self.t.standard()
        self.t.session([B("make build")], extra_lines=["{not json"])
        _, out, _ = self.t.run()
        self.assertIn("# partial: YES: 1 unreadable transcript lines or files skipped", out)

    def test_subagent_sidechains_are_not_counted(self):
        self.t.standard()
        for i in range(3):
            self.t.session([B("helm list"), B("helm status", True), B("helm rollback", True), B("helm history", True)], sidechain=True, days_ago=i + 1)
        self.assertFalse(any("helm" in c["label"] for c in self.t.ranked()))

    def test_mask_planted_name_in_a_question_label(self):
        for i in range(3):
            self.t.session([P("why is cust-acme seeing checkout timeouts"), B("kubectl get pods")], days_ago=i + 1)
        _, out, _ = self.t.run()
        self.assertNotIn("cust-acme", out)
        self.assertIn("<masked-1>", out)

    def test_mask_before_the_cut_so_a_name_cannot_split(self):
        filler = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo"
        for i in range(2):
            self.t.session([P(f"{filler} cust-acme-prod"), B("kubectl get pods")], days_ago=i + 1)
        _, out, _ = self.t.run(config="")
        cfg = self.t.tmp / "config.toml"
        cfg.write_text('[mask]\npatterns = ["\\\\bcust-[a-z]+-prod\\\\b"]\n')
        out_io = io.StringIO()
        mask._MASKER = None
        with mock.patch.dict(os.environ, {"SKILL_FORGE_CONFIG": str(cfg), "HOME": "/home/me"}), redirect_stdout(out_io):
            demand.main(["--transcripts", str(self.t.dir), "--history", str(self.t.tmp / "none")])
        mask._MASKER = None
        self.assertNotIn("cust-acme", out_io.getvalue())

    def test_shell_history_sessions_count(self):
        base = int((NOW - timedelta(days=2)).timestamp())
        lines = []
        for k in range(3):
            t = base + k * 7200
            lines += [f": {t}:0;psql -c 'select 1' service=ro", f": {t + 30}:0;pg_dump --schema-only app",
                      f": {t + 60}:0;vim notes.md"]
        hist = self.t.tmp / "zsh_history"
        hist.write_text("\n".join(lines) + "\n")
        self.t.dir.mkdir(parents=True)
        rc, out, _ = self.t.run("--history", str(hist), "--json")
        ranked = json.loads(out)
        self.assertEqual(ranked[0]["label"], "psql → pg_dump → vim")
        self.assertEqual(ranked[0]["sessions"], 3)
        self.assertIn("shell history", ranked[0]["examples"][0])

    def test_a_redirection_is_never_a_step(self):
        self.assertEqual([demand.step_of(p) for p in demand.pipelines("bash run.sh 2>&1 | tail -5; make test &> log; jq . < in.json")],
                         [("bash", "run.sh", ""), ("make", "test", ""), None])

    def test_shell_keywords_and_numbers_are_not_programs(self):
        steps = [demand.step_of(p) for p in demand.pipelines("for c in a b; do kubectl --context $c get pods; done; until gh pr checks 1; do sleep 5; done")]
        self.assertEqual([s for s in steps if s], [("kubectl", "get", "pods"), ("gh", "pr", "checks")])
        self.assertIsNone(demand.step_of([["2", "x"]]))

    def test_a_question_no_command_answered_is_left_out(self):
        for i in range(3):
            self.t.session([P("what does the export dashboard show")], days_ago=i + 1)
        self.t.dir.mkdir(parents=True, exist_ok=True)
        self.assertEqual([c for c in self.t.ranked() if c["kind"] == "question"], [])

    def test_a_pasted_brief_is_not_a_question(self):
        brief = "deploy the export job: " + " ".join(f"requirement{i} rollout{i}" for i in range(40))
        for i in range(3):
            self.t.session([P(brief), B("kubectl get pods")], days_ago=i + 1)
        self.assertEqual([c for c in self.t.ranked() if c["kind"] == "question"], [])

    def test_a_long_run_after_a_question_counts_at_most_ten_steps(self):
        for i in range(2):
            self.t.session([P("why is the nightly export slow")] + [B(f"make step{k}") for k in range(25)], days_ago=i + 1)
        q = [c for c in self.t.ranked() if c["kind"] == "question"][0]
        self.assertEqual(q["steps"], 10)

    def test_shapes_cut_arguments_and_skip_filters(self):
        self.assertEqual(demand.step_of([["KUBECONFIG=x", "kubectl", "--context", "prod", "-n", "web", "get", "pods"]]), ("kubectl", "get", "pods"))
        self.assertEqual(demand.step_of([["cat", "f"], ["jq", "."]]), None)
        self.assertEqual(demand.step_of([["grep", "x"], ["psql", "-c", "select"]]), ("psql", "", ""))
        self.assertEqual(demand.step_of([["pg_dump", "--schema-only", "app"]]), ("pg_dump", "", ""))
        self.assertEqual(demand.step_of([["python3.11", "bin/query.py", "--x"]]), ("python", "query.py", ""))


if __name__ == "__main__":
    unittest.main()
