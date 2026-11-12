#!/usr/bin/env python3
"""How an engine reaches its HTTP API: directly, through `kubectl port-forward`,
or from a throwaway pod. skill-forge copies this file, unchanged, into every
metrics-query, logs-fetch and api-readonly skill it drafts.

  <ENV>_ACCESS          unset or "direct": the engine's own URL variable, as before
                        "port-forward SVC[:PORT] in NS": kubectl port-forward to the service
                        "pod SVC[:PORT] in NS": curl from a throwaway pod; needs --apply
  <ENV>_CONTEXT         the kube context both cluster routes use; the current context
                        is never assumed
  <ENV>_PATH_PREFIXES   comma-separated API path prefixes to try in order ("" is none)
  <ENV>_POD_IMAGE       an image with curl, for the pod route

The setting and a direct URL are checked when the route is made; a cluster route
opens on the engine's first request, so a refused command starts nothing and
sends nothing. Then the prefix is probed, never guessed: each
candidate goes to the engine's own probe, which accepts only the API's own
success answer; a login wall at one prefix is AUTH only if no other prefix
answers. describe() is the route that answered, for the header. A failed
open or probe is kept and raised again on every later request, so no request
goes out on a route that was never confirmed.

The port-forward and the pod are torn down on every exit: a normal one, an
exception, SIGINT, SIGTERM or SIGHUP, even one that lands while `kubectl run`
is still creating the pod. SIGKILL cannot be caught: the pod's own `sleep` stops
it within POD_TTL seconds (the stopped pod stays until deleted), and a
port-forward left behind is a local kubectl process to kill by hand. The token travels in a header; on the
pod route the URL and headers reach curl as a config on stdin (`curl -K -`), so
neither is in argv, the pod spec or the cluster's exec audit record.
"""
from __future__ import annotations

import json
import os
import queue
import re
import secrets
import shlex
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
from contextlib import ExitStack, contextmanager

from mask import emit

POD_IMAGE = "curlimages/curl:8.10.1"
POD_TTL = 600
FORWARD_WAIT = 20.0
NAME = r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?"
SPEC = re.compile(rf"^(port-forward|pod)\s+(?:svc/)?({NAME})(?::(\d{{1,5}}))?\s+in\s+({NAME})$")
KUBE_AUTH = re.compile(r"Unauthorized|must be logged in|token (?:is |has )?expired|certificate has expired|"
                       r"refresh token|getting credentials|re-?authenticate", re.I)
FORWARDING = re.compile(r"Forwarding from 127\.0\.0\.1:(\d+)")
MARK = "<<sf-access>>"   # curl prints it, the status and the headers (as JSON, curl 7.83+) after the body


class AccessAuth(Exception):
    """The kube login behind a cluster route has expired or is missing."""


class AccessRefused(Exception):
    """The route is not set up, needs --apply, or no prefix answered; the API was not asked."""


def first(text: str) -> str:
    return next((ln.strip() for ln in (text or "").splitlines() if ln.strip()), "")[:300]


def kubectl(argv: list[str], stdin: str | None = None, timeout: float = 60) -> tuple[int, str, str]:
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise AccessRefused("kubectl is not on PATH")
    except subprocess.TimeoutExpired:
        raise OSError(f"kubectl {' '.join(argv[5:8])} timed out after {timeout:g}s")
    if p.returncode != 0 and KUBE_AUTH.search(p.stderr):
        raise AccessAuth(f"kubectl: {first(p.stderr)}")
    return p.returncode, p.stdout, p.stderr


def prefixes(env: str, default: list[str]) -> list[str]:
    raw = os.environ.get(f"{env}_PATH_PREFIXES")
    items = default if raw is None else raw.split(",")
    return [("/" + p.strip().strip("/")) if p.strip().strip("/") else "" for p in items] or [""]


def curl_config(url: str, headers: dict) -> str:
    """curl's config syntax: a quoted value escapes backslash and double quote. A header
    that spans lines would inject another one, so it is refused."""
    def q(s: str) -> str:
        if "\n" in s or "\r" in s:
            raise AccessRefused("a header or URL holds a line break; not sending it")
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    lines = [f"url = {q(url)}", "silent", "show-error", "max-time = 60", f'write-out = "\\n{MARK}%{{http_code}} %{{header_json}}"']
    return "\n".join(lines + [f"header = {q(f'{k}: {v}')}" for k, v in headers.items()]) + "\n"


class Route:
    def __init__(self, env: str, direct_url, probe, default_prefixes: list[str], apply: bool, stack: ExitStack):
        self.env, self.direct_url, self.probe, self.apply, self.stack = env, direct_url, probe, apply, stack
        self.candidates = prefixes(env, default_prefixes)
        self.state, self.error = "new", None
        self.base, self.prefix, self.via, self.probed = "", "", "", "not probed"
        self.kube: list[str] = []
        self.pod = ""
        self._parse()

    # -- what the engine calls ------------------------------------------------
    def root(self) -> str:
        self.ready()
        return self.base + self.prefix

    def get(self, path: str, query: str = "", headers: dict | None = None) -> tuple[int, dict, str]:
        """GET PATH under the route's prefix: (HTTP status, response headers by lowercase name, body)."""
        self.ready()
        return self.get_url(f"{self.base}{self.prefix}{path}" + (f"?{query}" if query else ""), headers)

    def get_url(self, url: str, headers: dict | None = None) -> tuple[int, dict, str]:
        self.ready()
        if self.pod:
            return self._pod_get(url, headers or {})
        req = urllib.request.Request(url, headers=headers or {}, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read().decode("utf-8", "replace")
                return getattr(r, "status", 200), {k.lower(): v for k, v in dict(r.headers).items()}, body
        except urllib.error.HTTPError as e:
            return e.code, {k.lower(): v for k, v in dict(e.headers or {}).items()}, e.read().decode("utf-8", "replace")

    def describe(self) -> str:
        return f"{self.via or self.base} · prefix {self.prefix or '/'} {self.probed}"

    # -- opening and probing, once ----------------------------------------------
    def ready(self) -> None:
        if self.state in ("ok", "resolving"):
            return
        if self.state == "failed":
            raise self.error
        self.state = "resolving"
        try:
            self._open()
            self._resolve()
            self.state = "ok"
        except BaseException as e:
            self.state, self.error = "failed", e
            raise

    def _parse(self) -> None:
        spec = os.environ.get(f"{self.env}_ACCESS", "").strip()
        if spec in ("", "direct"):
            self.mode, self.base = "direct", self.direct_url().rstrip("/")
            self.via = self.base + " (direct)"
            return
        m = SPEC.match(spec)
        if not m:
            raise AccessRefused(f'{self.env}_ACCESS={spec!r}: use "direct", "port-forward SVC[:PORT] in NS" or "pod SVC[:PORT] in NS"')
        self.mode, *self.spec = m.groups()
        self.via = f"svc/{self.spec[0]}:{self.spec[1] or '?'} in {self.spec[2]} via {self.mode} (not opened)"

    def _open(self) -> None:
        if self.mode == "direct":
            return
        mode, (svc, port, ns) = self.mode, self.spec
        ctx = self._context()
        self.kube = ["kubectl", "--context", ctx, "--namespace", ns]
        port = port or self._service_port(svc)
        if mode == "port-forward":
            local = self.stack.enter_context(port_forward(self.kube, svc, port))
            self.base, self.via = f"http://127.0.0.1:{local}", f"svc/{svc}:{port} in {ns} via port-forward, context {ctx}"
        else:
            self.pod = self.stack.enter_context(pod(self.kube, os.environ.get(f"{self.env}_POD_IMAGE", POD_IMAGE), self.apply))
            self.base, self.via = f"http://{svc}.{ns}.svc:{port}", f"svc/{svc}:{port} in {ns} via throwaway pod {self.pod}, context {ctx}"

    def _context(self) -> str:
        ctx = os.environ.get(f"{self.env}_CONTEXT", "").strip()
        if not ctx:
            raise AccessRefused(f"set {self.env}_CONTEXT to the kube context this route goes through; the current context is never assumed")
        rc, out, err = kubectl(["kubectl", "config", "get-contexts", "-o", "name"])
        if rc != 0:
            raise AccessRefused(f"kubectl config get-contexts failed: {first(err)}")
        if ctx not in out.split():
            raise AccessRefused(f"{self.env}_CONTEXT={ctx!r} is not a context in this kubeconfig")
        return ctx

    def _service_port(self, svc: str) -> str:
        rc, out, err = kubectl(self.kube + ["get", "service", svc, "-o", "jsonpath={.spec.ports[0].port}"])
        if rc != 0 or not out.strip().isdigit():
            raise AccessRefused(f"service {svc}: {first(err) or 'no port found'}; name it as SVC:PORT")
        return out.strip()

    def _resolve(self) -> None:
        if self.probe is None:
            self.prefix = self.candidates[0]
            self.probed = f"(not probed; set {self.env}_API_PROBE)"
            return
        tried, held = [], None
        for prefix in self.candidates:
            self.prefix = prefix
            try:
                why = self.probe()
            except OSError:
                raise   # the host, not the prefix: no other prefix will answer
            except (ValueError, KeyError, TypeError, AttributeError) as e:
                why = str(e)[:80] or type(e).__name__
            except Exception as e:   # a login wall here may be a different service from the API at the next prefix
                held = held or e
                why = f"{type(e).__name__}: {e}"[:80]
            if why is None:
                self.probed = "(probed" + (f"; no API at {', '.join(tried)}" if tried else "") + ")"
                return
            tried.append(f"{prefix or '/'}: {why}")
        if held is not None:
            raise held
        raise AccessRefused(f"no API answered at {self.via} under any prefix tried ({'; '.join(tried)}), so nothing was "
                            f"queried and there is no answer; set {self.env}_PATH_PREFIXES")

    def _pod_get(self, url: str, headers: dict) -> tuple[int, dict, str]:
        rc, out, err = kubectl(self.kube + ["exec", "-i", self.pod, "--", "curl", "-K", "-"],
                               stdin=curl_config(url, headers), timeout=90)
        if rc != 0:
            raise OSError(f"curl in pod {self.pod}: {first(err) or f'exit {rc}'}")
        body, mark, tail = out.rpartition("\n" + MARK)
        code, _, got = tail.partition(" ")
        if not mark or not code.isdigit():
            raise OSError(f"curl in pod {self.pod} gave no status line (the image needs curl 7.83 or later)")
        try:
            hdrs = json.loads(got) if got.strip() else {}
        except ValueError:
            raise OSError(f"curl in pod {self.pod} gave headers that are not JSON")
        return int(code), {k.lower(): ", ".join(v) if isinstance(v, list) else str(v) for k, v in hdrs.items()}, body


@contextmanager
def port_forward(kube: list[str], svc: str, port: str):
    """Yield the local port; the kubectl process is stopped on the way out, however it goes."""
    try:
        p = subprocess.Popen(kube + ["port-forward", f"svc/{svc}", f":{port}"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError:
        raise AccessRefused("kubectl is not on PATH")
    try:
        lines: queue.Queue = queue.Queue()
        errs: list[str] = []
        # kubectl prints a line per connection; reading both pipes for the whole run keeps it from blocking.
        readers = [threading.Thread(target=lambda s=s, put=put: [put(ln) for ln in s], daemon=True)
                   for s, put in ((p.stdout, lines.put), (p.stderr, errs.append))]
        for t in readers:
            t.start()
        deadline, local = time.monotonic() + FORWARD_WAIT, None
        while local is None:
            try:
                m = FORWARDING.search(lines.get(timeout=0.1))
                local = m.group(1) if m else None
            except queue.Empty:
                if p.poll() is not None:
                    readers[1].join(2)
                    msg = " ".join(e.strip() for e in errs)[:300] or f"exit {p.returncode}"
                    raise (AccessAuth if KUBE_AUTH.search(msg) else AccessRefused)(f"kubectl port-forward: {msg}")
                if time.monotonic() > deadline:
                    raise OSError(f"kubectl port-forward printed no 'Forwarding from' line in {FORWARD_WAIT:g}s")
        yield local
    finally:
        stop(p)


def stop(p: subprocess.Popen) -> None:
    p.terminate()
    try:
        p.wait(5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()


@contextmanager
def pod(kube: list[str], image: str, apply: bool):
    """Yield a throwaway pod's name; it is deleted on the way out, however it goes."""
    name = "sf-access-" + secrets.token_hex(4)
    create = kube + ["run", name, f"--image={image}", "--restart=Never", "--labels=skill-forge/throwaway=access",
                     "--command", "--", "sleep", str(POD_TTL)]
    if not apply:
        raise AccessRefused("the pod route creates a pod, so it needs --apply. It would run\n  " + shlex.join(create)
                            + f"\nand delete the pod when this run ends (its sleep stops it within {POD_TTL}s if this process is killed)")
    created = None   # until kubectl run answers, the pod may exist, so it is deleted
    try:
        try:
            rc, _, err = kubectl(create)
        except AccessAuth:
            created = False   # the API server turned the request away
            raise
        created = rc == 0
        if not created:
            raise AccessRefused(f"could not create pod {name}: {first(err)}")
        rc, _, err = kubectl(kube + ["wait", "--for=condition=Ready", f"pod/{name}", "--timeout=90s"], timeout=100)
        if rc != 0:
            raise OSError(f"pod {name} never became ready: {first(err)}")
        yield name
    finally:
        if created is not False:
            remove(kube, name)


def remove(kube: list[str], name: str) -> None:
    delete = kube + ["delete", "pod", name, "--wait=false", "--ignore-not-found"]
    try:
        rc, _, err = kubectl(delete)
    except (AccessAuth, AccessRefused, OSError) as e:
        rc, err = 1, str(e)
    if rc != 0:
        emit(f"LEFTOVER: pod {name} was not deleted ({first(err)}); delete it with: {shlex.join(delete)}", err=True)


@contextmanager
def teardown_on_signals():
    """SIGTERM and SIGHUP raise SystemExit, so every finally above runs; SIGINT already raises."""
    def raise_exit(signum, _frame):
        raise SystemExit(128 + signum)
    old = {}
    for s in (signal.SIGTERM, signal.SIGHUP):
        try:
            old[s] = signal.signal(s, raise_exit)
        except ValueError:   # not the main thread: the caller keeps its own handlers
            pass
    try:
        yield
    finally:
        for s, h in old.items():
            signal.signal(s, h)


@contextmanager
def route(env: str, direct_url, probe, default_prefixes: list[str], apply: bool = False):
    """The Route <ENV>_ACCESS names, opened on first use and always torn down.

    DIRECT_URL() returns the direct route's base URL (the engine checks it). PROBE()
    returns None when the API answers at the route's current prefix, else what answered
    instead; it may raise the engine's own auth error. None skips probing."""
    with teardown_on_signals(), ExitStack() as stack:
        yield Route(env, direct_url, probe, default_prefixes, apply, stack)
