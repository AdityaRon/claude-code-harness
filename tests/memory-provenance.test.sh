#!/usr/bin/env bash
# Tests for memory-provenance.sh — synthetic store and job records in a temp
# dir, so no real memory or session data is read.
#
# The property that matters most is that an unattributable memory is reported as
# ANON rather than quietly omitted. The whole point of the tool is to stop a
# memory being cited as independent corroboration, and a memory that silently
# does not appear reads exactly like one that was checked and cleared. Absence
# and an all-clear must not be the same output.
set -u
SCRIPT_UT="bin/memory-provenance.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
export CLAUDE_SESSION_JOBS_DIR="$TMP/jobs"
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/teststore/memory"
mkdir -p "$STORE" "$CLAUDE_SESSION_JOBS_DIR"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2  got: $3" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }

run() { bash "$SCRIPT_UT" "$@" 2>&1; }

# mem <stem> [sid] [modified] [origin-source]
# The 4th argument writes originSessionId_source, marking an origin recovered
# from transcripts rather than stamped at write time. Written directly rather
# than patched in afterwards: `sed -i ''` is BSD-only and silently does nothing
# on GNU sed, so a fixture built that way passes on macOS and fails on Linux CI
# with the memory reading ANON.
mem() {
  local stem="$1" sid="${2:-}" mod="${3:-2026-08-01T00:00:00.000Z}" src="${4:-}"
  { echo "---"; echo "name: $stem"; echo "description: d"
    echo "metadata:"; echo "  type: reference"; echo "  modified: $mod"
    [ -n "$sid" ] && echo "  originSessionId: $sid"
    [ -n "$src" ] && echo "  originSessionId_source: $src"
    echo "---"; echo "body"; } > "$STORE/$stem.md"
}
# job <sid> <name>
job() {
  mkdir -p "$CLAUDE_SESSION_JOBS_DIR/${1:0:8}"
  printf '{"sessionId":"%s","name":"%s","nameSource":"auto","state":"done"}\n' \
    "$1" "$2" > "$CLAUDE_SESSION_JOBS_DIR/${1:0:8}/state.json"
}

echo "memory-provenance.sh"

mem attributed   "aaaaaaaa-1111-2222-3333-444444444444" "2026-08-10T00:00:00.000Z"
mem orphaned     "bbbbbbbb-1111-2222-3333-444444444444" "2026-08-11T00:00:00.000Z"
mem unattributed ""                                     "2026-08-12T00:00:00.000Z"
job "aaaaaaaa-1111-2222-3333-444444444444" "cypher query optimization"
# bbbbbbbb deliberately has no job record.

out=$(run)
check_contains "attributes a memory to its session" 'by "cypher query optimization"' "$out"
check_contains "BY finding for an attributed memory" "BY " "$out"

# An id with no job record is still an id: two memories sharing it share an
# author, so it must not be collapsed into ANON.
check_contains "id with no job record is UNRESOLVED" "UNRESOLVED" "$out"
check_absent   "UNRESOLVED is not reported as attributed" 'orphaned   by "' "$out"

# The property this tool exists for.
check_contains "memory with no origin is ANON" "ANON" "$out"
check_contains "ANON memory is listed by name, not omitted" "unattributed" "$out"
check_contains "says an ANON memory is not neutral evidence" "not neutral evidence" "$out"

# --- the corroboration query -----------------------------------------------
# Before citing a memory as agreement with what a session just told you: did
# that session write it?
out=$(run --session "cypher query optimization")
check_contains "--session finds what that session wrote" "attributed" "$out"
check_absent   "--session excludes other sessions' memories" "unattributed" "$out"
check_contains "--session warns the result is not independent" "not independent" "$out"

out=$(run --session "a session that never existed")
check_contains "a session that wrote nothing reports nothing" "nothing to report" "$out"

# Case-insensitive and substring, because session names are prose.
out=$(run --session "CYPHER QUERY")
check_contains "--session is case-insensitive and substring" "attributed" "$out"

# --- counts must answer the question asked ---------------------------------
# A filtered run printing the corpus-wide total invites the reader to take a
# number that answers a different question.
out=$(run --anon)
check_contains "--anon keeps unattributable memories" "unattributed" "$out"
check_absent   "--anon drops attributed memories" "cypher query optimization" "$out"
check_contains "--anon count reflects the filter" "1 matched, of 3 memories scanned" "$out"

out=$(run)
check_contains "unfiltered count reports the corpus" "1 of 3 stamped at write time, 1 anonymous" "$out"

# --- a recovered origin must not pass as a first-party stamp ----------------
# memory-fix --provenance recovers origins from transcripts and marks them with
# originSessionId_source. If this reader ignored that field, a recovered origin
# would render identically to one Claude Code stamped at write time -- turning an
# inference into a fact silently, which is the failure this tool exists to catch.
mem derived_one "aaaaaaaa-1111-2222-3333-444444444444" "2026-08-14T00:00:00.000Z" transcript
# Assert the fixture itself, or a helper that silently wrote nothing would make
# the checks below fail for the wrong reason -- which is exactly how the BSD-only
# sed edit this replaced passed locally and failed on Linux.
grep -q '^  originSessionId_source: transcript$' "$STORE/derived_one.md" \
  && pass "fixture carries the derived label" \
  || fail "fixture carries the derived label" "helper did not write it"
out=$(run)
check_contains "a recovered origin is DERIVED, not BY"  "DERIVED" "$out"
check_contains "and still resolves to the session name" 'derived_one' "$out"
check_contains "the count separates recovered from stamped" "recovered from transcripts" "$out"
check_contains "and says what a DERIVED origin is worth"    "evidence, not a record" "$out"

out=$(run --json)
echo "$out" | jq -e 'select(.memory=="derived_one") | select(.derived==true)' >/dev/null 2>&1 \
  && pass "--json marks it derived" || fail "--json marks it derived" "flag absent"
echo "$out" | jq -e 'select(.memory=="attributed") | select(.derived==false)' >/dev/null 2>&1 \
  && pass "--json leaves a first-party stamp underived" || fail "--json first-party underived" "flag wrong"

# --- output modes and edge cases -------------------------------------------
out=$(run --json)
echo "$out" | jq -e '.finding' >/dev/null 2>&1 \
  && pass "--json is valid JSON" || fail "--json is valid JSON" "jq rejected it"
check_contains "--json carries the resolved session" '"session":"cypher query optimization"' "$out"

# A UUID quoted in the body is a reference, not provenance.
{ echo "---"; echo "name: body_mention"; echo "description: d"
  echo "metadata:"; echo "  type: reference"; echo "  modified: 2026-08-13T00:00:00.000Z"
  echo "---"
  echo "The session was originSessionId: aaaaaaaa-1111-2222-3333-444444444444"; } \
  > "$STORE/body_mention.md"
out=$(run --anon)
check_contains "a UUID in the body does not count as provenance" "body_mention" "$out"

# The index files are not memories.
echo "- [X](x.md) — hook" > "$STORE/MEMORY.md"
echo "- [Y](y.md) — hook" > "$STORE/MEMORY_ARCHIVE.md"
out=$(run)
check_absent "MEMORY.md is not treated as a memory"         " MEMORY " "$out"
check_absent "MEMORY_ARCHIVE.md is not treated as a memory" "MEMORY_ARCHIVE" "$out"

out=$(CLAUDE_MEMORY_PROJECTS_DIR="$TMP/nope" bash "$SCRIPT_UT" 2>&1); rc=$?
check_contains "an absent store reports nothing rather than failing" "nothing to report" "$out"
[ "$rc" = "0" ] && pass "absent store exits 0" || fail "absent store exits 0" "rc=$rc"

# --- read-only contract -----------------------------------------------------
before=$(find "$CLAUDE_MEMORY_PROJECTS_DIR" "$CLAUDE_SESSION_JOBS_DIR" -type f | sort | xargs shasum 2>/dev/null | shasum)
run >/dev/null; run --anon >/dev/null; run --json >/dev/null
after=$(find "$CLAUDE_MEMORY_PROJECTS_DIR" "$CLAUDE_SESSION_JOBS_DIR" -type f | sort | xargs shasum 2>/dev/null | shasum)
if [ "$before" = "$after" ]; then pass "writes nothing it reads"; else fail "writes nothing it reads" "inputs changed"; fi

echo ""
echo "--- Results: ${PASS} passed, ${FAIL} failed ---"
[ "$FAIL" -eq 0 ]
