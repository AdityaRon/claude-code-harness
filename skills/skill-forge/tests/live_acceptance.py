#!/usr/bin/env python3
"""The acceptance checks that need Docker. Brings up Postgres and Prometheus
from fixtures/live/compose.yml with a random canary as the database password,
plants the same canary in env vars and a kubeconfig, then runs discover, a
drafted sql-readonly skill and a drafted metrics-query skill against them.

  live_acceptance.py          bring the fixture up, run every check, take it down
  live_acceptance.py --keep   leave the containers running afterwards

Ends with `--- Results: N passed, M failed ---`; exit status is the failure count.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
BIN = SKILL / "bin"
COMPOSE = HERE / "fixtures" / "live" / "compose.yml"
PASSED, FAILED = [], []


def check(name: str, ok: bool, detail: str = "") -> None:
    (PASSED if ok else FAILED).append(name)
    sys.stdout.write(f"{'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"\n      {detail.strip()[:600]}") + "\n")
    sys.stdout.flush()


def sh(argv, env=None, stdin=None, timeout=300) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in argv], env=env, input=stdin, capture_output=True, text=True, timeout=timeout)


def draft(arch: str, name: str, question: str, state: Path) -> Path:
    env = dict(os.environ, SKILL_FORGE_STATE=str(state), SKILL_FORGE_TEMPLATES=str(SKILL / "templates"))
    p = sh([sys.executable, "-B", BIN / "forge.py", "draft", arch, name, "--question", question], env=env)
    if p.returncode:
        raise SystemExit(f"draft {arch} failed: {p.stderr}")
    return state / "drafts" / name


def check_discover(tmp: Path, project: str, prom: str, canary: str, docker_host: str) -> None:
    home = tmp / "home"
    home.mkdir()
    kube = tmp / "kube.yaml"
    kube.write_text("apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://127.0.0.1:6443\n"
                    "contexts:\n- name: sf-live\n  context:\n    cluster: c\n    user: u\ncurrent-context: sf-live\n"
                    "users:\n- name: u\n  user:\n    token: " + canary + "\n")
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "DOCKER_HOST": docker_host, "KUBECONFIG": str(kube),
           "SKILL_FORGE_STATE": str(tmp / "state"), "SKILL_FORGE_CONFIG": str(tmp / "none.toml"),
           "PGPASSWORD": canary, "DD_API_KEY": canary,
           "PROMETHEUS_URL": "http://admin:" + canary + "@" + prom + "/?tok" + "en=" + canary}
    p = sh([sys.executable, "-B", BIN / "discover.py", "--probe-local", "--repo-root", tmp / "no-repos"], env=env)
    inv_path = tmp / "state" / "inventory.md"
    inv = inv_path.read_text() if inv_path.exists() else ""
    check("discover: exits 0", p.returncode == 0, p.stderr)
    check("discover: lists the Postgres container with its port",
          f"postgres container `{project}-pg-1` (postgres:16.4) on 127.0.0.1:" in inv, inv)
    check("discover: lists the Prometheus container with its deep link",
          f"prometheus container `{project}-prom-1` (prom/prometheus:v2.53.2) on 127.0.0.1:" in inv and "/graph?g0.expr=" in inv, inv)
    check("discover: --probe-local finds `reader` as a read-only login role", "read-only login roles: reader" in inv, inv)
    check("discover: --probe-local reads the Prometheus version", f"prometheus `{project}-prom-1` answers: version 2.53.2" in inv, inv)
    check("discover: lists the kube context", "kube context `sf-live`" in inv, inv)
    lines = [ln for ln in inv.splitlines() if ln.startswith("- **")]
    check("discover: every finding names the command that found it", bool(lines) and all("· found by `" in ln for ln in lines))
    check("discover: the planted canary is in no output (inventory.md, stdout, stderr)",
          canary not in inv and canary not in p.stdout and canary not in p.stderr)


def check_sql(tmp: Path, project: str, docker_host: str) -> None:
    pg = f"{project}-pg-1"
    d = draft("sql-readonly", "live-orders", "Which tenant drove the order volume?", tmp / "forge")
    eng = d / "bin" / "live_orders.py"
    cfg = tmp / "mask.toml"
    cfg.write_text('[mask]\npatterns = ["\\\\bcust-[a-z]+"]\n')
    env = dict(os.environ, DOCKER_HOST=docker_host, SKILL_FORGE_CONFIG=str(cfg),
               LIVE_ORDERS_PSQL=f"docker exec -i {pg} psql -U reader -d forge")

    def run(*a, extra=None):
        return sh([sys.executable, "-B", eng, *a], env={**env, **(extra or {})})

    def count() -> str:
        return sh(["docker", "exec", "-i", pg, "psql", "-X", "-qAt", "-U", "forge", "-d", "forge"], env=env,
                  stdin="SELECT count(*) FROM orders;").stdout.strip()

    before = count()
    r = run("query", "--sql", "SELECT tenant, count(*) AS orders FROM orders GROUP BY 1 ORDER BY 1")
    first = r.stdout.splitlines()[:1]
    check("sql: answers through the reader role, header names db, role and primary",
          r.returncode == 0 and first == ["# target:  postgres db=forge role=reader primary v16.4 via $LIVE_ORDERS_PSQL"], r.stdout + r.stderr)
    check("sql: tenant ids are masked", "cust-" not in r.stdout and "<masked-1>" in r.stdout and "# rows:    3" in r.stdout, r.stdout)
    r = run("--self-test")
    check("sql: --self-test passes (the corpus blocks every must-block query)", r.returncode == 0 and "passed" in r.stdout, r.stdout + r.stderr)
    sys.path.insert(0, str(d / "bin"))
    import sqlguard
    leaked = []
    for q in sqlguard.MUST_BLOCK:
        rr = run("query", "--sql", q)
        if rr.returncode != 5:
            leaked.append(f"{q!r} exit {rr.returncode}")
    nested = "WITH x AS (DELETE FROM orders RETURNING *) SELECT * FROM x"
    rr = run("query", "--sql", nested)
    check(f"sql: all {len(sqlguard.MUST_BLOCK)} must-block queries are BLOCKED on the live target, DML in a CTE included",
          not leaked and rr.returncode == 5 and "BLOCKED" in rr.stderr, "; ".join(leaked) + rr.stderr)
    bypass = ("import sys; sys.path.insert(0, sys.argv[1]); import live_orders as e; "
              "rc, out, err = e.run_psql(e.runner(), e.wrap(\"INSERT INTO orders (tenant, amount) VALUES ('x', 1)\", 5, '5s'), 60); "
              "sys.stdout.write(err)")
    r = sh([sys.executable, "-B", "-c", bypass, d / "bin"], env={**env, "LIVE_ORDERS_PSQL": f"docker exec -i {pg} psql -U forge -d forge"})
    check("sql: with the client check bypassed, BEGIN READ ONLY alone refuses an INSERT even as the superuser",
          "cannot execute INSERT in a read-only transaction" in r.stdout, r.stdout + r.stderr)
    r = sh(["docker", "exec", "-i", pg, "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "reader", "-d", "forge"], env=env,
           stdin="INSERT INTO orders (tenant, amount) VALUES ('x', 1);")
    check("sql: with no wrapper at all, the reader role's own default refuses an INSERT",
          "cannot execute INSERT in a read-only transaction" in r.stderr, r.stderr)
    check("sql: the table is unchanged after every attempt", count() == before == "30", f"before {before}, after {count()}")
    r = run("query", "--sql", "SELECT * FROM ordrs")
    check("sql: a misspelled table is ABSENT with the closest name, not empty",
          r.returncode == 2 and "ABSENT: relation ordrs does not exist" in r.stdout and "Closest: orders" in r.stdout, r.stdout + r.stderr)
    r = run("query", "--sql", "SELECT * FROM orders WHERE false")
    check("sql: a query that matches nothing is EMPTY, exit 0", r.returncode == 0 and "EMPTY:" in r.stdout, r.stdout + r.stderr)
    r = run("query", "--sql", "SELECT id FROM orders", "--max-rows", "5")
    check("sql: more rows than the cap is PARTIAL", r.returncode == 3 and "# partial: YES: row cap 5 reached" in r.stdout, r.stdout + r.stderr)
    r = run("query", "--sql", "SELECT 1", extra={
        "LIVE_ORDERS_PSQL": f"docker run --rm -i -e PGPASSWORD --network {project}_default postgres:16.4 psql -h pg -U forge -d forge",
        "PGPASSWORD": "wrong-" + uuid.uuid4().hex, "LIVE_ORDERS_RELOGIN": "renew-db-access"})
    check("sql: a failed login is AUTH with the re-login command, not an empty answer",
          r.returncode == 4 and "password authentication failed" in r.stderr and "Re-login with: renew-db-access" in r.stderr, r.stdout + r.stderr)
    r = run("query", "--sql", "SELECT 1", extra={"LIVE_ORDERS_EXPECT_DB": "billing"})
    check("sql: the wrong database is REFUSED", r.returncode == 5 and "expected 'billing'" in r.stderr, r.stderr)


def check_metrics(tmp: Path, prom: str) -> None:
    d = draft("metrics-query", "live-latency", "Why is this job slow?", tmp / "forge")
    eng = d / "bin" / "live_latency.py"
    env = dict(os.environ, LIVE_LATENCY_PROM_URL=f"http://{prom}", SKILL_FORGE_CONFIG=str(tmp / "none.toml"))

    def run(*a):
        return sh([sys.executable, "-B", eng, *a], env=env)

    deadline = time.time() + 90
    while time.time() < deadline and "1 series" not in run("instant", "up").stdout:
        time.sleep(3)
    r = run("query", "prometheus_http_requets_total", "--window", "10m")
    check("metrics: a misspelled metric is ABSENT, with the right name suggested",
          r.returncode == 2 and "ABSENT: metric prometheus_http_requets_total has no series" in r.stdout
          and "did you mean prometheus_http_requests_total" in r.stdout, r.stdout + r.stderr)
    r = run("instant", 'prometheus_http_requests_total{handler="/api/v1/qeury"}')
    check("metrics: a wrong label value is ABSENT, with the closest values",
          r.returncode == 2 and "closest: /api/v1/query" in r.stdout, r.stdout + r.stderr)
    r = run("instant", "prometheus_http_requests_total", "--max-series", "2")
    check("metrics: a query capped by --max-series is PARTIAL", r.returncode == 3 and "printed the first 2 (--max-series)" in r.stdout, r.stdout + r.stderr)
    r = run("series", "prometheus_http_requests_total", "--limit", "2", "--window", "10m")
    check("metrics: the backend's own truncation warning is PARTIAL",
          r.returncode == 3 and "# partial: YES: results truncated due to limit" in r.stdout, r.stdout + r.stderr)
    r = run("query", 'rate(prometheus_http_requests_total{handler="/-/ready"}[1s])', "--window", "5m")
    check("metrics: series that exist but have no samples in the window are EMPTY, exit 0",
          r.returncode == 0 and "EMPTY: the series exist" in r.stdout, r.stdout + r.stderr)
    r = run("query", "up", "--window", "5m", "--step", "30s")
    check("metrics: the header names the backend version and the UTC window with its step",
          "v2.53.2" in r.stdout.splitlines()[0] and "(UTC, bounds [start, end], step 30s)" in r.stdout, r.stdout + r.stderr)


def main() -> int:
    keep = "--keep" in sys.argv[1:]
    if sh(["docker", "info", "--format", "{{.ServerVersion}}"]).returncode:
        sys.stdout.write("needs a running Docker daemon\n--- Results: 0 passed, 1 failed ---\n")
        return 1
    ctx = sh(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]).stdout.strip()
    docker_host = os.environ.get("DOCKER_HOST") or ctx
    canary = "sfcanary" + uuid.uuid4().hex
    project = f"sf-live-{os.getpid()}"
    tmp = Path(tempfile.mkdtemp(prefix="sf-live."))
    env0 = dict(os.environ, SF_CANARY=canary)
    compose = ["docker", "compose", "-p", project, "-f", COMPOSE]
    try:
        up = sh(compose + ["up", "-d", "--wait"], env=env0, timeout=900)
        check("fixture: compose up --wait", up.returncode == 0, up.stderr)
        if up.returncode == 0:
            prom = sh(compose + ["port", "prom", "9090"], env=env0).stdout.strip()
            check_discover(tmp, project, prom, canary, docker_host)
            check_sql(tmp, project, docker_host)
            check_metrics(tmp, prom)
    finally:
        if not keep:
            sh(compose + ["down", "-v"], env=env0, timeout=300)
        shutil.rmtree(tmp, ignore_errors=True)
    sys.stdout.write(f"--- Results: {len(PASSED)} passed, {len(FAILED)} failed ---\n")
    return len(FAILED)


if __name__ == "__main__":
    sys.exit(min(main(), 255))
