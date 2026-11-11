#!/usr/bin/env python3
"""lint-baseline: is a feature flag on for a tenant (a lint fixture).

  engine.py show TENANT           the tenant's flag rows
  engine.py flip TENANT FLAG      print the change; --apply makes it
  engine.py --self-test           the read-only check's corpus, offline
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mask import emit, header  # noqa: E402

BLOCK = ("insert", "update", "delete")


def read_only(sql: str) -> bool:
    return not any(w in sql.lower() for w in BLOCK)


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def show_sql(tenant: str) -> str:
    return f"SELECT flag, enabled FROM flags WHERE tenant = {quote(tenant)}"


def flip_sql(tenant: str, flag: str) -> str:
    return ("BEGIN; UPDATE flags SET enabled = NOT enabled WHERE tenant = " + quote(tenant) + " AND flag = " + quote(flag)
            + "; INSERT INTO flag_audit (tenant, flag) VALUES (" + quote(tenant) + ", " + quote(flag) + "); COMMIT;")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="is a feature flag on for a tenant")
    p.add_argument("--self-test", action="store_true", help="run the read-only corpus offline")
    p.add_argument("--apply", action="store_true", help="make the change; without it, print it")
    p.add_argument("cmd", nargs="?", choices=["show", "flip"])
    p.add_argument("args", nargs="*")
    a = p.parse_args(argv)
    if a.self_test:
        ok = read_only("SELECT 1") and not read_only("DELETE FROM t")
        emit("self-test " + ("passed" if ok else "FAILED"))
        return 0 if ok else 1
    sql = flip_sql(*a.args) if a.cmd == "flip" else show_sql(a.args[0])
    rows = []
    if a.cmd == "flip" and not a.apply:
        rows = ["would run: " + sql]
    elif a.cmd == "flip":
        subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1"], input=sql, text=True, check=True)
    else:
        out = subprocess.run(["psql", "-X", "--csv"], input=sql, text=True, capture_output=True).stdout
        rows = out.splitlines()[1:]
    emit(header("flags table", "n/a: the current state", rows=len(rows)))
    for r in rows:
        emit(r)
    return 0 if rows or a.cmd == "flip" else 2


if __name__ == "__main__":
    sys.exit(main())
