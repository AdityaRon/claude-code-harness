#!/usr/bin/env python3
"""The client-side layers of a read-only SQL check, for PostgreSQL and psql.
skill-forge copies this file into every sql-readonly skill it drafts.

  sqlguard.py --self-test     run the must-pass and must-block corpus offline; exit 1 on any miss
  sqlguard.py --check         read one statement on stdin; print OK or BLOCKED and the reason

The layers, each of which has a known bypass on its own:
  1. a tokenizer, so a write keyword inside a string, a quoted identifier, a
     dollar-quoted body or a comment does not count, and an unterminated one
     is refused rather than guessed at;
  2. one statement only;
  3. a leading-keyword allowlist: SELECT, WITH, VALUES, TABLE, SHOW, EXPLAIN;
  4. a scan of every keyword for nested writes: DML inside a CTE, SELECT INTO,
     FOR UPDATE / FOR SHARE, EXPLAIN ANALYZE wrapping a write, transaction and
     session control, and calls to known side-effecting functions;
  5. no psql backslash command outside a string: psql reads the statement on
     stdin and would run \\! (a shell), \\o (a file write) or \\gexec.
The server-side layer (a read-only role, and a READ ONLY transaction the
engine opens) is the engine's job; this file cannot see the server.
An unquoted column named like a write keyword (update, delete) is refused;
quote it ("update") to read it.
"""
from __future__ import annotations

import argparse
import sys

ALLOW_FIRST = {"SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN"}
WRITE_WORDS = {
    "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "TRUNCATE", "DROP", "ALTER", "CREATE",
    "GRANT", "REVOKE", "COPY", "CALL", "DO", "VACUUM", "CLUSTER", "REINDEX", "LOCK",
    "REFRESH", "IMPORT", "LISTEN", "NOTIFY", "UNLISTEN", "PREPARE", "EXECUTE", "DEALLOCATE",
    "SET", "RESET", "DISCARD", "BEGIN", "START", "COMMIT", "ROLLBACK", "ABORT",
    "SAVEPOINT", "RELEASE", "CHECKPOINT", "LOAD", "SECURITY", "REASSIGN", "INTO", "SHARE",
}
SIDE_EFFECT_FUNCS = {
    "set_config", "pg_terminate_backend", "pg_cancel_backend", "pg_reload_conf", "pg_rotate_logfile",
    "pg_advisory_lock", "pg_advisory_lock_shared", "pg_advisory_xact_lock", "pg_try_advisory_lock",
    "pg_try_advisory_xact_lock", "pg_advisory_unlock", "pg_advisory_unlock_all",
    "nextval", "setval", "lo_import", "lo_export", "lo_unlink", "lo_create", "lo_from_bytea", "lo_put",
    "pg_read_file", "pg_read_binary_file", "pg_ls_dir", "pg_file_write", "pg_file_unlink", "pg_file_rename",
    "dblink", "dblink_exec", "dblink_connect", "dblink_send_query", "query_to_xml", "query_to_xmlschema",
    "query_to_xml_and_xmlschema", "cursor_to_xml", "pg_sleep", "pg_sleep_for", "pg_sleep_until",
    "pg_switch_wal", "pg_create_restore_point", "pg_promote", "pg_logical_emit_message",
    "pg_create_logical_replication_slot", "pg_create_physical_replication_slot", "pg_drop_replication_slot",
    "pg_replication_origin_create", "pg_stat_reset", "pg_stat_statements_reset",
}


class Unterminated(ValueError):
    pass


def tokens(sql: str):
    """Yield (kind, text): word, qident, string, dollar, param, semi, backslash,
    punct. Comments are dropped."""
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j + 1
        elif sql.startswith("/*", i):
            depth, j = 1, i + 2
            while depth:
                if j >= n:
                    raise Unterminated("an unterminated /* comment")
                if sql.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif sql.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            i = j
        elif c in "eE" and i + 1 < n and sql[i + 1] == "'":
            j = i + 2
            while True:
                if j >= n:
                    raise Unterminated("an unterminated E'' string")
                if sql[j] == "\\":
                    j += 2
                elif sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                    else:
                        break
                else:
                    j += 1
            yield "string", sql[i:j + 1]
            i = j + 1
        elif c == "'":
            j = i + 1
            while True:
                if j >= n:
                    raise Unterminated("an unterminated '' string")
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                    else:
                        break
                else:
                    j += 1
            yield "string", sql[i:j + 1]
            i = j + 1
        elif c == '"':
            j = sql.find('"', i + 1)
            while j >= 0 and j + 1 < n and sql[j + 1] == '"':
                j = sql.find('"', j + 2)
            if j < 0:
                raise Unterminated('an unterminated "" identifier')
            yield "qident", sql[i + 1:j].replace('""', '"')
            i = j + 1
        elif c == "$":
            j = i + 1
            if j < n and sql[j].isdigit():
                while j < n and sql[j].isdigit():
                    j += 1
                yield "param", sql[i:j]
                i = j
                continue
            while j < n and (sql[j].isalnum() or sql[j] == "_"):
                j += 1
            if j < n and sql[j] == "$":
                tag = sql[i:j + 1]
                end = sql.find(tag, j + 1)
                if end < 0:
                    raise Unterminated(f"an unterminated {tag} body")
                yield "dollar", sql[i:end + len(tag)]
                i = end + len(tag)
            else:
                yield "punct", c
                i += 1
        elif c.isalpha() or c == "_":
            j = i
            while j < n and (sql[j].isalnum() or sql[j] in "_$"):
                j += 1
            yield "word", sql[i:j]
            i = j
        elif c == ";":
            yield "semi", c
            i += 1
        elif c == "\\":
            yield "backslash", c
            i += 1
        else:
            yield "punct", c
            i += 1


def check(sql: str) -> tuple[bool, str]:
    """(True, "") when every client-side layer passes, else (False, reason)."""
    try:
        toks = list(tokens(sql))
    except Unterminated as e:
        return False, f"{e}; refusing to guess where it ends"
    if any(k == "backslash" for k, _ in toks):
        return False, "a psql backslash command outside a string (\\! runs a shell, \\o writes a file)"
    stmts, cur = [], []
    for k, v in toks:
        if k == "semi":
            if cur:
                stmts.append(cur)
            cur = []
        else:
            cur.append((k, v))
    if cur:
        stmts.append(cur)
    if not stmts:
        return False, "no statement"
    if len(stmts) > 1:
        return False, f"{len(stmts)} statements; send one"
    st = stmts[0]
    first = st[0][1].upper() if st[0][0] == "word" else st[0][1]
    if st[0][0] != "word" or first not in ALLOW_FIRST:
        return False, f"leads with {first!r}; only {', '.join(sorted(ALLOW_FIRST))} may start a statement"
    for idx, (k, v) in enumerate(st):
        if k != "word":
            continue
        up = v.upper()
        nxt = st[idx + 1] if idx + 1 < len(st) else ("", "")
        if up in WRITE_WORDS:
            return False, f"{up} inside the statement (a nested write, lock or session change)"
        if up == "ANALYZE" and not _explain_option(st, idx):
            return False, "ANALYZE outside EXPLAIN's options"
        if nxt == ("punct", "(") and v.lower() in SIDE_EFFECT_FUNCS:
            return False, f"{v}() has side effects"
    for idx, (k, v) in enumerate(st):
        if k == "qident" and idx + 1 < len(st) and st[idx + 1] == ("punct", "(") and v.lower() in SIDE_EFFECT_FUNCS:
            return False, f'"{v}"() has side effects'
    return True, ""


def _explain_option(st, idx) -> bool:
    """ANALYZE is allowed right after EXPLAIN, or inside EXPLAIN ( ... )."""
    if st[0][1].upper() != "EXPLAIN":
        return False
    if idx == 1:
        return True
    return len(st) > 2 and st[1] == ("punct", "(") and all(t != ("punct", ")") for t in st[2:idx])


MUST_PASS = [
    "SELECT 1",
    "select now();",
    "SELECT 'insert into t values (1); drop table t' AS s",
    'SELECT "delete", "update" FROM t',
    "SELECT 1 -- drop table t",
    "SELECT /* update t set a = 1 */ 1",
    "SELECT /* nested /* delete */ comment */ 1",
    "SELECT $$delete from t$$",
    "SELECT $body$ ; drop table t; $body$ AS x",
    "SELECT E'it\\'s; delete from t'",
    "SELECT 'it''s; delete'",
    "WITH a AS (SELECT 1 AS x) SELECT x FROM a",
    "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT * FROM r",
    "EXPLAIN SELECT * FROM t",
    "EXPLAIN ANALYZE SELECT * FROM t",
    "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM t",
    "SHOW server_version",
    "VALUES (1, 'a'), (2, 'b')",
    "TABLE pg_roles",
    "SELECT count(*) FROM orders WHERE created_at > now() - interval '1 day' AND id = $1",
    "SELECT tenant, sum(bytes) FROM usage GROUP BY 1 ORDER BY 2 DESC LIMIT 10",
    "SELECT pg_is_in_recovery()",
    'SELECT "set_config" FROM t',
    "SELECT CASE WHEN n > 0 THEN 'up' ELSE 'down' END AS dir FROM t",
    "SELECT * FROM t ORDER BY id FETCH FIRST 5 ROWS ONLY",
]

MUST_BLOCK = [
    "INSERT INTO t VALUES (1)",
    "UPDATE t SET a = 1",
    "DELETE FROM t",
    "WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x",
    "WITH x AS (UPDATE t SET a = 1 RETURNING *) SELECT 1",
    "WITH x AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM x",
    "WITH x AS (MERGE INTO t USING s ON true WHEN MATCHED THEN DELETE) SELECT 1",
    "SELECT 1; DELETE FROM t",
    "select 1;select 2",
    "SELECT * INTO newt FROM t",
    "SELECT * FROM t FOR UPDATE",
    "SELECT * FROM t FOR NO KEY UPDATE",
    "SELECT * FROM t FOR SHARE",
    "SELECT * FROM t FOR KEY SHARE",
    "EXPLAIN ANALYZE DELETE FROM t",
    "EXPLAIN (ANALYZE) INSERT INTO t VALUES (1)",
    "COPY t TO '/tmp/x'",
    "COPY (SELECT 1) TO PROGRAM 'id'",
    "CALL p()",
    "DO $$BEGIN DELETE FROM t; END$$",
    "SELECT set_config('default_transaction_read_only', 'off', false)",
    "SELECT pg_catalog.set_config('default_transaction_read_only', 'off', false)",
    "SET default_transaction_read_only = off",
    "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
    "BEGIN READ WRITE",
    "COMMIT",
    "RESET ALL",
    "SELECT pg_terminate_backend(1)",
    "SELECT nextval('s')",
    "SELECT lo_export(1, '/tmp/x')",
    "SELECT dblink_exec('host=x', 'delete from t')",
    "SELECT query_to_xml('delete from t', true, true, '')",
    "SELECT pg_sleep(600)",
    "SELECT pg_advisory_lock(1)",
    'SELECT "pg_terminate_backend"(1)',
    "TRUNCATE t",
    "DROP TABLE t",
    "ALTER ROLE r SET default_transaction_read_only = off",
    "GRANT ALL ON t TO public",
    "VACUUM t",
    "ANALYZE t",
    "SELECT 1 FROM t WHERE ANALYZE",
    "REFRESH MATERIALIZED VIEW m",
    "LOCK TABLE t",
    "PREPARE p AS DELETE FROM t",
    "EXECUTE p",
    "NOTIFY c",
    "\\! id",
    "SELECT 1 \\gexec",
    "SELECT 1 \\o /tmp/x",
    "SELECT 'unterminated",
    "SELECT /* unterminated",
    'SELECT "unterminated',
    "SELECT $$unterminated",
    "",
    "   -- only a comment",
    "CREATE TABLE t (a int)",
]


def self_test(out=sys.stdout) -> int:
    missed = 0
    for q in MUST_PASS:
        ok, why = check(q)
        if not ok:
            missed += 1
            out.write(f"MISS must-pass blocked: {q!r}: {why}\n")
    for q in MUST_BLOCK:
        ok, _ = check(q)
        if ok:
            missed += 1
            out.write(f"MISS must-block passed: {q!r}\n")
    out.write(f"sqlguard self-test: {len(MUST_PASS)} must-pass, {len(MUST_BLOCK)} must-block, {missed} missed\n")
    return 1 if missed else 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--self-test", action="store_true", help="run the corpus offline")
    g.add_argument("--check", action="store_true", help="check one statement from stdin")
    a = p.parse_args(argv)
    if a.self_test:
        return self_test()
    ok, why = check(sys.stdin.read())
    sys.stdout.write("OK\n" if ok else f"BLOCKED: {why}\n")
    return 0 if ok else 5


if __name__ == "__main__":
    sys.exit(main())
