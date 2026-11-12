"""Tests for access.py, the route an engine takes to its API. skill-forge copies
this file, unchanged, into every metrics-query, logs-fetch and api-readonly
skill it drafts. kubectl is a stub on PATH that runs as a real process: its
port-forward announces a local test server's port and then sleeps, so a test can
see whether the process outlived the route; its `exec ... curl -K -` reads the
curl config from stdin and answers from the same server.

Mutations that must turn this file red:
  prefix-guessed: access.py: `            why = self.probe()` => `            why = None`
  login-wall-ends-search: access.py: `                held = held or e` => `                raise`
  failure-forgotten: access.py: `            self.state, self.error = "failed", e` => `            self.state = "new"`
  current-context-assumed: access.py: `        if not ctx:` => `        if False:`
  context-unchecked: access.py: `        if ctx not in out.split():` => `        if False:`
  pod-without-apply: access.py: `    if not apply:` => `    if False:`
  pod-left-behind: access.py: `        rc, _, err = kubectl(delete)` => `        rc, err = 0, ""`
  interrupted-create-kept: access.py: `        if created is not False:` => `        if created:`
  refused-create-deleted: access.py: `            created = False   # the API server` => `            created = None   # the API server`
  forward-left-running: access.py: `        stop(p)` => `        pass`
  signals-ignored: access.py: `            old[s] = signal.signal(s, raise_exit)` => `            pass`
  token-in-argv: access.py: `["exec", "-i", self.pod, "--", "curl", "-K", "-"]` => `["exec", "-i", self.pod, "--", "curl", "-K", "-", "-H", str(headers)]`
  pod-headers-dropped: access.py: `return int(code), {k.lower(): ", ".join(v) if isinstance(v, list) else str(v) for k, v in hdrs.items()}, body` => `return int(code), {}, body`
  config-unquoted: access.py: `return '"' + s.replace("\\\\", "\\\\\\\\").replace('"', '\\\\"') + '"'` => `return '"' + s + '"'`
  header-injection: access.py: `        if "\\n" in s or "\\r" in s:` => `        if False:`
  kube-auth-unseen: access.py: `    if p.returncode != 0 and KUBE_AUTH.search(p.stderr):` => `    if False:`
  forward-auth-unseen: access.py: `raise (AccessAuth if KUBE_AUTH.search(msg) else AccessRefused)` => `raise AccessRefused`
  forward-waits-forever: access.py: `                if time.monotonic() > deadline:` => `                if False:`
  pod-ttl-ignored: access.py: `"--command", "--", "sleep", str(ttl)]` => `"--command", "--", "sleep", str(POD_TTL)]`
  stopped-pod-unexplained: access.py: `hint = f"; its {self.ttl}s lifetime may have run out, so raise {self.env}_POD_TTL" if gone else ""` => `hint = ""`
  unopened-route-unnamed: access.py: `        self.via = f"svc/{svc}:{port} in {ns} via {mode}, context {ctx} (not opened)"` => `        pass`
"""
from __future__ import annotations

import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "bin"
sys.path.insert(0, str(BIN))
import access  # noqa: E402

ENV = "T"
TOKEN = "tok-" + os.urandom(6).hex()
STUB = textwrap.dedent('''\
    import json, os, re, sys, time, urllib.error, urllib.request
    args = sys.argv[1:]
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write(json.dumps(args) + "\\n")
    mode = os.environ.get("STUB_MODE", "")
    if args[:2] == ["config", "get-contexts"]:
        print("kind-test\\nother-ctx"); sys.exit(0)
    if "port-forward" in args:
        if mode == "auth":
            print("error: You must be logged in to the server (Unauthorized)", file=sys.stderr); sys.exit(1)
        if mode == "forbidden":
            print('error: pods "p" is forbidden: cannot create resource "pods/portforward"', file=sys.stderr); sys.exit(1)
        with open(os.environ["STUB_PIDFILE"], "w") as f:
            f.write(str(os.getpid()))
        if mode != "silent":
            print("Forwarding from 127.0.0.1:%s -> 9090" % os.environ["STUB_PORT"], flush=True)
            print("Forwarding from [::1]:%s -> 9090" % os.environ["STUB_PORT"], flush=True)
        time.sleep(8 if mode == "silent" else 300); sys.exit(0)
    if "service" in args:
        print("9090"); sys.exit(0)
    if "exec" in args:
        if mode == "stopped":
            print("error: cannot exec in a stopped container", file=sys.stderr); sys.exit(1)
        if mode == "auth-exec":
            print("error: You must be logged in to the server (Unauthorized)", file=sys.stderr); sys.exit(1)
        cfg = sys.stdin.read()
        with open(os.environ["STUB_CURLCFG"], "a") as f:
            f.write(cfg)
        url = re.search(r'^url = "(.*)"$', cfg, re.M).group(1)
        path = "/" + url.split("/", 3)[3]
        hdrs = dict(h.split(": ", 1) for h in re.findall(r'^header = "(.*)"$', cfg, re.M))
        req = urllib.request.Request("http://127.0.0.1:%s%s" % (os.environ["STUB_PORT"], path), headers=hdrs)
        try:
            r = urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            r = e
        hj = json.dumps({k.lower(): [v] for k, v in r.headers.items()})
        sys.stdout.write(r.read().decode() + "\\n<<sf-access>>%d %s" % (r.status, hj)); sys.exit(0)
    if "run" in args and mode == "auth-run":
        print("error: You must be logged in to the server (Unauthorized)", file=sys.stderr); sys.exit(1)
    if "run" in args and mode == "slow-run":
        time.sleep(30); sys.exit(0)
    if "delete" in args and mode == "nodelete":
        print("error: connection refused", file=sys.stderr); sys.exit(1)
    sys.exit(0)
''')


class Api(BaseHTTPRequestHandler):
    """/prom/api/v1/query answers; / is a wrong prefix that answers ROOT (404 text by default)."""
    root = (404, "text/plain", "404 page not found")
    seen: list = []

    def do_GET(self):
        Api.seen.append((self.path, self.headers.get("Authorization")))
        if self.path.startswith("/prom/api/v1/query"):
            code, ctype, body = 200, "application/json", json.dumps({"status": "success", "data": {"resultType": "vector", "result": []}})
        elif self.path.startswith("/prom/paged"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Link", '</page2>; rel="next"')
            self.end_headers()
            self.wfile.write(b"[]")
            return
        elif self.path.startswith("/wall/"):
            code, ctype, body = 200, "text/html", "<!doctype html><title>Sign in</title>"
        else:
            code, ctype, body = Api.root
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *a):
        pass


class Login(Exception):
    pass


class Fixture:
    """A test server, a stub kubectl on PATH, and an engine-shaped probe."""

    def __init__(self, test: unittest.TestCase, mode: str = "", **env):
        self.tmp = Path(tempfile.mkdtemp(prefix="access-test."))
        test.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Api)
        threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        test.addCleanup(srv.shutdown)
        Api.seen, Api.root = [], (404, "text/plain", "404 page not found")
        (self.tmp / "bin").mkdir()
        stub = self.tmp / "bin" / "kubectl"
        stub.write_text(f"#!{sys.executable}\n" + STUB)
        stub.chmod(0o755)
        self.log, self.pidfile, self.curlcfg = self.tmp / "log", self.tmp / "pid", self.tmp / "curlcfg"
        self.port = srv.server_address[1]
        base = {"PATH": f"{self.tmp / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}", "STUB_LOG": str(self.log),
                "STUB_PIDFILE": str(self.pidfile), "STUB_CURLCFG": str(self.curlcfg), "STUB_PORT": str(self.port),
                "STUB_MODE": mode, f"{ENV}_PATH_PREFIXES": ",/prom", f"{ENV}_CONTEXT": "kind-test", **env}
        p = mock.patch.dict(os.environ, base)
        p.start()
        test.addCleanup(p.stop)

    def direct(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def calls(self) -> list:
        return [json.loads(ln) for ln in self.log.read_text().splitlines()] if self.log.exists() else []

    def stub_alive(self) -> bool:
        if not self.pidfile.exists():
            return False
        try:
            os.kill(int(self.pidfile.read_text()), 0)
        except ProcessLookupError:
            return False
        return True


def probe_for(holder: dict):
    """An engine's probe: its own fetch, its own auth and success checks."""
    def probe():
        status, got, body = holder["r"].get("/api/v1/query", "query=vector%281%29", {"Authorization": "Bearer " + TOKEN})
        if status in (401, 403) or "html" in got.get("content-type", ""):
            raise Login(f"HTTP {status}")
        if status == 404:
            raise ValueError("HTTP 404")
        d = json.loads(body)
        return None if d.get("status") == "success" else f"not a success answer ({body[:40]})"
    return probe


def opened(fx: Fixture, apply: bool = False, probe=True):
    holder: dict = {}
    cm = access.route(ENV, fx.direct, probe_for(holder) if probe else None, ["", "/prometheus"], apply=apply)
    return cm, holder


class PrefixTest(unittest.TestCase):
    def test_the_prefix_is_probed_and_the_answering_one_is_echoed(self):
        fx = Fixture(self)
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            status, _, _ = r.get("/api/v1/query", "query=up")
            self.assertEqual(status, 200)
            self.assertEqual(r.describe(), f"{fx.direct()} (direct) · prefix /prom (probed; no API at /: HTTP 404)")
        self.assertEqual([p for p, _ in Api.seen], ["/api/v1/query?query=vector%281%29", "/prom/api/v1/query?query=vector%281%29",
                                                   "/prom/api/v1/query?query=up"])

    def test_a_wrong_prefix_that_answers_200_is_not_the_api(self):
        fx = Fixture(self, T_PATH_PREFIXES="")
        Api.root = (200, "application/json", "{}")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessRefused) as e:
                r.get("/api/v1/query", "query=up")
            self.assertIn("no API answered", str(e.exception))
            self.assertIn("/: not a success answer", str(e.exception))
            with self.assertRaises(access.AccessRefused):   # and stays refused: nothing goes out unconfirmed
                r.get("/api/v1/query", "query=up")
        self.assertNotIn("/api/v1/query?query=up", [p for p, _ in Api.seen])

    def test_a_login_wall_at_the_probe_is_raised_and_kept(self):
        fx = Fixture(self, T_PATH_PREFIXES="/wall")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            for _ in range(2):
                with self.assertRaises(Login):
                    r.get("/api/v1/query", "query=up")
        self.assertEqual(len(Api.seen), 1)

    def test_a_login_wall_at_one_prefix_does_not_hide_the_api_at_the_next(self):
        fx = Fixture(self, T_PATH_PREFIXES="/wall,/prom")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            self.assertEqual(r.get("/api/v1/query", "query=up")[0], 200)
            self.assertIn("prefix /prom (probed; no API at /wall: Login: HTTP 200)", r.describe())

    def test_no_probe_says_so_in_the_route(self):
        fx = Fixture(self)
        cm, _ = opened(fx, probe=False)
        with cm as r:
            r.get("/x")
            self.assertIn("(not probed; set T_API_PROBE)", r.describe())

    def test_nothing_is_sent_before_the_first_request(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus:9090 in monitoring")
        cm, _ = opened(fx)
        with cm:
            pass
        self.assertEqual(fx.calls(), [])
        self.assertEqual(Api.seen, [])

    def test_prefixes_from_the_environment(self):
        with mock.patch.dict(os.environ, {"T_PATH_PREFIXES": " , prometheus/ ,/select/0/prometheus"}):
            self.assertEqual(access.prefixes(ENV, ["x"]), ["", "/prometheus", "/select/0/prometheus"])
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(access.prefixes(ENV, ["", "/prometheus"]), ["", "/prometheus"])


class PortForwardTest(unittest.TestCase):
    def test_requests_go_through_the_forward_and_it_stops_after(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus:9090 in monitoring")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            self.assertEqual(r.get("/api/v1/query", "query=up")[0], 200)
            self.assertTrue(fx.stub_alive())
            self.assertEqual(r.describe(), "svc/prometheus:9090 in monitoring via port-forward, context kind-test · prefix /prom (probed; no API at /: HTTP 404)")
        self.assertFalse(fx.stub_alive())
        self.assertIn(["--context", "kind-test", "--namespace", "monitoring", "port-forward", "svc/prometheus", ":9090"], fx.calls())

    def test_the_forward_stops_when_the_engine_raises(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus in monitoring")
        cm, h = opened(fx)
        with self.assertRaises(RuntimeError):
            with cm as r:
                h["r"] = r
                r.get("/api/v1/query", "query=up")
                raise RuntimeError("engine failed")
        self.assertFalse(fx.stub_alive())
        self.assertIn(["--context", "kind-test", "--namespace", "monitoring", "get", "service", "prometheus", "-o",
                       "jsonpath={.spec.ports[0].port}"], fx.calls())

    def test_the_forward_stops_on_sigterm(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus:9090 in monitoring")
        driver = fx.tmp / "driver.py"
        driver.write_text(textwrap.dedent(f'''\
            import sys, time
            sys.path.insert(0, {str(BIN)!r})
            import access
            with access.route("T", lambda: "http://unused", None, [""]) as r:
                r.get("/x")
                print("open", flush=True)
                time.sleep(60)
            '''))
        p = subprocess.Popen([sys.executable, str(driver)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(p.stdout.readline().strip(), "open", p.stderr.read() if p.poll() is not None else "")
        self.assertTrue(fx.stub_alive())
        p.send_signal(signal.SIGTERM)
        self.assertEqual(p.wait(10), 128 + signal.SIGTERM)
        p.stdout.close()
        p.stderr.close()
        time.sleep(0.2)
        self.assertFalse(fx.stub_alive())

    def test_an_expired_kube_login_is_auth(self):
        fx = Fixture(self, "auth", T_ACCESS="port-forward prometheus:9090 in monitoring")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessAuth) as e:
                r.get("/x")
        self.assertIn("Unauthorized", str(e.exception))

    def test_a_forbidden_forward_is_refused_not_auth(self):
        fx = Fixture(self, "forbidden", T_ACCESS="port-forward prometheus:9090 in monitoring")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessRefused) as e:
                r.get("/x")
        self.assertIn("forbidden", str(e.exception))

    def test_a_forward_that_never_announces_is_stopped(self):
        fx = Fixture(self, "silent", T_ACCESS="port-forward prometheus:9090 in monitoring")
        cm, h = opened(fx)
        with mock.patch.object(access, "FORWARD_WAIT", 1.0), cm as r:
            h["r"] = r
            with self.assertRaises(OSError) as e:
                r.get("/x")
        self.assertIn("no 'Forwarding from' line", str(e.exception))
        self.assertFalse(fx.stub_alive())


class ContextTest(unittest.TestCase):
    def test_the_context_is_named_never_assumed(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus:9090 in monitoring", T_CONTEXT="")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessRefused) as e:
                r.get("/x")
        self.assertIn("set T_CONTEXT", str(e.exception))
        self.assertFalse(any("current-context" in c for c in fx.calls()))
        self.assertFalse(any("port-forward" in c for c in fx.calls()))

    def test_an_unknown_context_is_refused(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus:9090 in monitoring", T_CONTEXT="prod-typo")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessRefused) as e:
                r.get("/x")
        self.assertIn("'prod-typo' is not a context", str(e.exception))
        self.assertFalse(any("port-forward" in c for c in fx.calls()))

    def test_a_malformed_setting_is_refused_before_anything_runs(self):
        fx = Fixture(self, T_ACCESS="port-forward prometheus:9090")
        cm, _ = opened(fx)
        with self.assertRaises(access.AccessRefused) as e:
            with cm:
                pass
        self.assertIn("port-forward SVC[:PORT] in NS", str(e.exception))
        self.assertEqual(fx.calls(), [])


class PodTest(unittest.TestCase):
    def test_without_apply_it_prints_the_pod_and_creates_nothing(self):
        fx = Fixture(self, T_ACCESS="pod prometheus:9090 in monitoring")
        cm, h = opened(fx)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessRefused) as e:
                r.get("/x")
        self.assertIn("needs --apply", str(e.exception))
        self.assertIn("kubectl --context kind-test --namespace monitoring run sf-access-", str(e.exception))
        self.assertFalse(any("run" in c for c in fx.calls()))

    def test_with_apply_the_token_rides_stdin_and_the_pod_is_deleted(self):
        fx = Fixture(self, T_ACCESS="pod prometheus:9090 in monitoring")
        cm, h = opened(fx, apply=True)
        with cm as r:
            h["r"] = r
            status, got, body = r.get("/api/v1/query", "query=up", {"Authorization": "Bearer " + TOKEN})
            self.assertEqual((status, got["content-type"], json.loads(body)["status"]), (200, "application/json", "success"))
            self.assertEqual(r.get("/paged")[1]["link"], '</page2>; rel="next"')
            self.assertEqual(r.get("/nowhere")[:2][0], 404)
            self.assertRegex(r.describe(), r"^svc/prometheus:9090 in monitoring via throwaway pod sf-access-[0-9a-f]{8}, context kind-test · prefix /prom")
        verbs = [c[4] for c in fx.calls() if c[:1] == ["--context"]]
        self.assertEqual(verbs[0], "run")
        self.assertEqual(verbs[-1], "delete")
        self.assertIn("exec", verbs)
        self.assertNotIn(TOKEN, fx.log.read_text())
        cfg = fx.curlcfg.read_text()
        self.assertIn(f'header = "Authorization: Bearer {TOKEN}"', cfg)
        self.assertIn('url = "http://prometheus.monitoring.svc:9090/prom/api/v1/query?query=up"', cfg)
        self.assertIn(("/prom/api/v1/query?query=up", "Bearer " + TOKEN), Api.seen)

    def test_the_pod_is_deleted_when_the_engine_raises(self):
        fx = Fixture(self, T_ACCESS="pod prometheus:9090 in monitoring")
        cm, h = opened(fx, apply=True)
        with self.assertRaises(RuntimeError):
            with cm as r:
                h["r"] = r
                r.get("/x")
                raise RuntimeError("engine failed")
        self.assertEqual([c[4] for c in fx.calls() if c[:1] == ["--context"]][-1], "delete")

    def test_a_pod_that_could_not_be_deleted_is_reported(self):
        fx = Fixture(self, "nodelete", T_ACCESS="pod prometheus:9090 in monitoring")
        cm, h = opened(fx, apply=True)
        err = io.StringIO()
        with redirect_stderr(err), cm as r:
            h["r"] = r
            r.get("/x")
        self.assertRegex(err.getvalue(), r"LEFTOVER: pod sf-access-[0-9a-f]{8} was not deleted \(error: connection refused\); "
                                         r"delete it with: kubectl --context kind-test --namespace monitoring delete pod")

    def test_a_create_refused_for_auth_deletes_nothing(self):
        fx = Fixture(self, "auth-run", T_ACCESS="pod prometheus:9090 in monitoring")
        cm, h = opened(fx, apply=True)
        err = io.StringIO()
        with redirect_stderr(err), cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessAuth):
                r.get("/x")
        self.assertEqual([c[4] for c in fx.calls() if c[:1] == ["--context"]], ["run"])
        self.assertNotIn("LEFTOVER", err.getvalue())

    def test_a_sigterm_while_the_pod_is_created_still_deletes_it(self):
        fx = Fixture(self, "slow-run", T_ACCESS="pod prometheus:9090 in monitoring")
        driver = fx.tmp / "driver.py"
        driver.write_text(textwrap.dedent(f'''\
            import sys
            sys.path.insert(0, {str(BIN)!r})
            import access
            with access.route("T", lambda: "http://unused", None, [""], apply=True) as r:
                r.get("/x")
            '''))
        p = subprocess.Popen([sys.executable, str(driver)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        while not any("run" in c for c in fx.calls()) and time.monotonic() < deadline:
            time.sleep(0.05)
        p.send_signal(signal.SIGTERM)
        self.assertEqual(p.wait(10), 128 + signal.SIGTERM, p.stderr.read())
        p.stderr.close()
        self.assertEqual([c[4] for c in fx.calls() if c[:1] == ["--context"]], ["run", "delete"])

    def test_the_pod_lives_as_long_as_asked_and_says_when_it_ran_out(self):
        fx = Fixture(self, "stopped", T_ACCESS="pod prometheus:9090 in monitoring", T_POD_TTL="3600")
        cm, h = opened(fx, apply=True)
        with cm as r:
            h["r"] = r
            with self.assertRaises(OSError) as e:
                r.get("/x")
        self.assertIn("sleep", fx.calls()[1])
        self.assertEqual(fx.calls()[1][-1], "3600")
        self.assertIn("its 3600s lifetime may have run out, so raise T_POD_TTL", str(e.exception))
        fx2 = Fixture(self, T_ACCESS="pod prometheus:9090 in monitoring", T_POD_TTL="5")
        cm, h = opened(fx2, apply=True)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessRefused):
                r.get("/x")

    def test_a_route_that_fails_to_open_still_names_itself(self):
        fx = Fixture(self, "silent", T_ACCESS="port-forward prometheus in monitoring")
        cm, h = opened(fx)
        with mock.patch.object(access, "FORWARD_WAIT", 1.0), cm as r:
            h["r"] = r
            with self.assertRaises(OSError):
                r.get("/x")
            self.assertTrue(r.describe().startswith("svc/prometheus:9090 in monitoring via port-forward, context kind-test (not opened)"), r.describe())

    def test_an_expired_login_at_exec_is_auth(self):
        fx = Fixture(self, "auth-exec", T_ACCESS="pod prometheus:9090 in monitoring")
        cm, h = opened(fx, apply=True)
        with cm as r:
            h["r"] = r
            with self.assertRaises(access.AccessAuth):
                r.get("/x")


class CurlConfigTest(unittest.TestCase):
    def test_quoting_escapes_backslash_and_quote(self):
        cfg = access.curl_config('http://h/a?q=say "hi"\\', {"X-Note": 'a "b" \\c'})
        self.assertIn('url = "http://h/a?q=say \\"hi\\"\\\\"', cfg)
        self.assertIn('header = "X-Note: a \\"b\\" \\\\c"', cfg)

    def test_a_header_with_a_line_break_is_refused(self):
        with self.assertRaises(access.AccessRefused):
            access.curl_config("http://h/", {"Authorization": "Bearer x\nX-Evil: 1"})


if __name__ == "__main__":
    unittest.main()
