#!/usr/bin/env bash
# Tests for session-route.sh — synthetic transcripts and job records in a temp
# dir, so no real session data is read.
#
# The property that matters most is EARLIEST-LINK WINS. Claude Code writes a
# pr-link record whenever any session links a PR, so a reviewer, a monitor and
# the author all leave records on the same PR. Picking the wrong one routes a
# review to a session that merely looked at the PR — the exact failure this
# tool exists to prevent — and it fails silently, because a plausible session
# name comes back either way. So the ordering is asserted directly, and
# asserted against the case with known ground truth (#1620) rather than only
# against a happy path.
set -u
SCRIPT_UT="bin/session-route.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_SESSION_PROJECTS_DIR="$TMP/projects"
export CLAUDE_SESSION_JOBS_DIR="$TMP/jobs"
mkdir -p "$CLAUDE_SESSION_PROJECTS_DIR/store" "$CLAUDE_SESSION_JOBS_DIR"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2  got: $3" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2  in: $3" ;; *) pass "$1" ;; esac; }

run() { bash "$SCRIPT_UT" "$@" 2>&1; }

# link <sid> <pr> <iso-ts> [repo]
link() {
  local sid="$1" pr="$2" ts="$3" repo="${4:-acme/widgets}"
  printf '{"type":"pr-link","sessionId":"%s","prNumber":%s,"prUrl":"https://github.com/%s/pull/%s","prRepository":"%s","timestamp":"%s"}\n' \
    "$sid" "$pr" "$repo" "$pr" "$repo" "$ts" >> "$CLAUDE_SESSION_PROJECTS_DIR/store/$sid.jsonl"
}
# job <sid> <name>
job() {
  local sid="$1" name="$2"
  mkdir -p "$CLAUDE_SESSION_JOBS_DIR/${sid:0:8}"
  printf '{"sessionId":"%s","name":"%s","nameSource":"auto","state":"done","updatedAt":"2026-08-27T00:00:00.000Z"}\n' \
    "$sid" "$name" > "$CLAUDE_SESSION_JOBS_DIR/${sid:0:8}/state.json"
}

echo "session-route.sh"

# --- 1. earliest linker wins, later toucher is not chosen -------------------
# Mirrors #1620: the owner linked first, the wrong session linked 19h later.
link owner-1620 1620 "2026-08-26T22:28:55.309Z"
link owner-1620 1620 "2026-08-26T23:00:14.883Z"   # repeats must not outvote
link tourist-99 1620 "2026-08-27T17:13:25.752Z"
link tourist-99 1620 "2026-08-27T17:37:13.723Z"
job owner-1620 "ins-543 volume estimate reply"
job tourist-99 "performance lag investigation ins-168"

out=$(run --pr 1620)
check_contains "routes to the earliest linker"      "ins-543 volume estimate reply" "$out"
check_absent   "does not route to the later toucher" "performance lag investigation" "$out"
check_contains "reports it as ROUTE"                "ROUTE" "$out"
check_contains "counts the other sessions"          "+1 touched" "$out"

# Repeat count must not decide it: the tourist has as many records as the owner.
link tourist-99 1620 "2026-08-27T18:00:00.000Z"
link tourist-99 1620 "2026-08-27T18:01:00.000Z"
out=$(run --pr 1620)
check_contains "record COUNT does not outvote time" "ins-543 volume estimate reply" "$out"

# --- 2. unreachable raiser is never replaced by a toucher -------------------
# The raiser has no job record. A later session does. Returning that later
# session would be a confident wrong answer, so it must report NO_SESSION.
link ghost-raiser 42 "2026-08-01T10:00:00.000Z"
link late-helper  42 "2026-08-02T10:00:00.000Z"
job late-helper "some other session"

out=$(run --pr 42)
check_contains "unreachable raiser reports NO_SESSION" "NO_SESSION" "$out"
check_absent   "does not present a toucher as the owner in the session column" \
               "->  some other session" "$out"
check_contains "names the toucher only as not-the-owner" "not the owner" "$out"

# --- 3. no records at all ---------------------------------------------------
out=$(run --pr 999999)
check_contains "unknown PR reports NO_RECORD" "NO_RECORD" "$out"

# --- 4. weak-name flag ------------------------------------------------------
link vague-sess 7 "2026-08-03T10:00:00.000Z"
job vague-sess "corpus data evaluation proposal"
out=$(run --pr 7)
check_contains "name with no digit is flagged weak-name" "weak-name" "$out"

link sharp-sess 8 "2026-08-03T10:00:00.000Z"
job sharp-sess "pr 1509 review comments"
out=$(run --pr 8)
check_absent "name carrying an identifier is not flagged" "weak-name" "$out"

# --- 5. filters and output modes -------------------------------------------
link other-repo 5 "2026-08-04T10:00:00.000Z" "acme/gadgets"
job other-repo "gadget session"
out=$(run --repo gadgets)
check_contains "--repo keeps the matching repo"  "gadgets #5" "$out"
check_absent   "--repo excludes other repos"     "widgets" "$out"

out=$(run --unrouted)
check_contains "--unrouted keeps unroutable findings" "NO_SESSION" "$out"
check_absent   "--unrouted drops ROUTE lines"         "ROUTE" "$out"

out=$(run --pr 1620 --json)
check_contains "--json emits a parseable object" '"finding":"ROUTE"' "$out"
echo "$out" | jq -e '.session' >/dev/null 2>&1 \
  && pass "--json is valid JSON" || fail "--json is valid JSON" "jq rejected it"

# --- 6. read-only contract --------------------------------------------------
before=$(find "$CLAUDE_SESSION_PROJECTS_DIR" "$CLAUDE_SESSION_JOBS_DIR" -type f | sort | xargs shasum 2>/dev/null | shasum)
run >/dev/null; run --unrouted >/dev/null; run --json >/dev/null
after=$(find "$CLAUDE_SESSION_PROJECTS_DIR" "$CLAUDE_SESSION_JOBS_DIR" -type f | sort | xargs shasum 2>/dev/null | shasum)
if [ "$before" = "$after" ]; then pass "writes nothing it reads"; else fail "writes nothing it reads" "inputs changed"; fi

# --- 7. absent directories must not explode ---------------------------------
out=$(CLAUDE_SESSION_PROJECTS_DIR="$TMP/nope" CLAUDE_SESSION_JOBS_DIR="$TMP/nope2" bash "$SCRIPT_UT" 2>&1)
rc=$?
check_contains "missing dirs report nothing rather than failing" "nothing to report" "$out"
[ "$rc" = "0" ] && pass "missing dirs exit 0" || fail "missing dirs exit 0" "rc=$rc"

echo ""
echo "--- Results: ${PASS} passed, ${FAIL} failed ---"
[ "$FAIL" -eq 0 ]
