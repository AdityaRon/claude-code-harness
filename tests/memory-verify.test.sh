#!/usr/bin/env bash
# Tests for memory-verify.sh — builds a synthetic memory store in a temp dir and
# stubs GitHub, so the suite is hermetic: no real memories are read, no network
# call is made, and CI needs no gh credential.
set -u
SCRIPT="bin/memory-verify.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/teststore/memory"
mkdir -p "$STORE"

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

check_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "expected to contain: $needle" ;;
  esac
}
check_absent() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) fail "$label" "expected NOT to contain: $needle" ;;
    *) pass "$label" ;;
  esac
}
check_eq() {
  local label="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then pass "$label"; else fail "$label" "expect=$expect got=$got"; fi
}

# Date N days ago, portable across BSD (macOS) and GNU (CI) date.
days_ago() {
  date -v-"$1"d +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -d "$1 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null
}

# A stub `gh` that answers `gh api graphql` only for known refs, so tests assert
# on our parsing and comparison rather than on GitHub. It fails the way gh did
# when probed on 2026-11-18: a number it does not know comes back `null` with an
# errors[] entry, the rest of the data is still on stdout, and it exits 1. An
# unknown repo is `"r": null`. Each call appends one line to $FAKEGH_LOG.
cat > "$TMP/fakegh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "api graphql" ] || exit 1
q=""
for a in "$@"; do case "$a" in query=*) q=${a#query=} ;; esac; done
owner=$(printf '%s\n' "$q" | sed -n 's/.*repository(owner: "\([^"]*\)".*/\1/p')
name=$(printf '%s\n' "$q" | sed -n 's/.*name: "\([^"]*\)".*/\1/p')
nums=$(printf '%s\n' "$q" | sed -n 's/^n\([0-9]*\): issueOrPullRequest(number: \1).*/\1/p')
echo "$owner/$name $(printf '%s\n' "$nums" | grep -c .)" >> "${FAKEGH_LOG:-/dev/null}"
[ "${FAKEGH_DOWN:-0}" = 1 ] && { echo "gh: connection refused" >&2; exit 1; }
case "$owner/$name" in
  acme/api|acme/web|acme/tools|acme/bulk) ;;
  *) echo '{"data":{"r":null},"errors":[{"type":"NOT_FOUND","path":["r"],"message":"Could not resolve to a Repository"}]}'
     echo "gh: Could not resolve to a Repository" >&2; exit 1 ;;
esac
body=""; errs=""; rc=0
for n in $nums; do
  case "$owner/$name#$n" in
    acme/api#4821) v='{"__typename":"PullRequest","state":"MERGED"}' ;;
    acme/web#900)  v='{"__typename":"PullRequest","state":"OPEN"}' ;;
    acme/tools#42) v='{"__typename":"Issue","state":"CLOSED"}' ;;
    acme/bulk#*)   v='{"__typename":"PullRequest","state":"OPEN"}' ;;
    *) v=null; rc=1
       errs="$errs${errs:+,}{\"type\":\"NOT_FOUND\",\"path\":[\"r\",\"n$n\"],\"message\":\"Could not resolve to an issue or pull request with the number of $n.\"}" ;;
  esac
  body="$body${body:+,}\"n$n\":$v"
done
printf '{"data":{"r":{%s}}%s}\n' "$body" "${errs:+,\"errors\":[$errs]}"
[ "$rc" = 0 ] || echo "gh: Could not resolve to an issue or pull request" >&2
exit "$rc"
STUB
chmod +x "$TMP/fakegh"
export MEMORY_VERIFY_GH_CMD="$TMP/fakegh"
export FAKEGH_LOG="$TMP/gh.log"
calls() { if [ -f "$FAKEGH_LOG" ]; then wc -l < "$FAKEGH_LOG" | tr -d ' '; else echo 0; fi; }

mem() {  # mem <filename> <age_days> <body...>
  local name="$1" age="$2"; shift 2
  {
    echo "---"
    echo "name: ${name%.md}"
    echo "description: fixture"
    echo "metadata:"
    echo "  type: project"
    echo "  modified: $(days_ago "$age")"
    echo "---"
    printf '%s\n' "$@"
  } > "$STORE/$name"
}

run() { bash "$SCRIPT" --store teststore "$@" 2>&1; }
run_rc() { bash "$SCRIPT" --store teststore "$@" >/dev/null 2>&1; echo $?; }

echo "=== A claim that matches reality is VERIFIED, not reported by default ==="
rm -f "$STORE"/*.md
mem ok.md 40 "verify:" "  - gh acme/api#4821 merged" "" "The idle-timeout fix landed."
OUT=$(run)
check_absent  "quiet when everything checks out" "ok.md" "$OUT"
check_contains "counted as verified"             "0 stale" "$OUT"
check_eq       "exit 0 when nothing needs attention" "0" "$(run_rc)"
OUT=$(run --all)
check_contains "--all surfaces it"    "VERIFIED" "$OUT"
check_contains "--all names the file" "ok.md"    "$OUT"

echo ""
echo "=== A claim contradicted by GitHub is STALE ==="
rm -f "$STORE"/*.md
mem stale.md 40 "verify:" "  - gh acme/api#4821 open" "" "Still a held draft, do not land yet."
OUT=$(run)
check_contains "flagged STALE"        "STALE"          "$OUT"
check_contains "names the file"       "stale.md"       "$OUT"
check_contains "shows expected"       "expected=open"  "$OUT"
check_contains "shows reality"        "actual=MERGED"  "$OUT"
check_eq       "exit 1 on stale"      "1" "$(run_rc)"

echo ""
echo "=== An issue number resolves too (issueOrPullRequest answers for either) ==="
rm -f "$STORE"/*.md
mem issue.md 40 "verify:" "  - gh acme/tools#42 open"
OUT=$(run)
check_contains "issue resolved and compared" "actual=CLOSED" "$OUT"

echo ""
echo "=== Unverifiable claims are SKIPped, never silently passed ==="
rm -f "$STORE"/*.md
mem jira.md    40 "verify:" "  - jira PROJ-123 Done"
mem bare.md    40 "verify:" "  - gh services#4821 merged"
mem unknown.md 40 "verify:" "  - notion abc123 done"
mem broken.md  40 "verify:" "  - gh acme/api#4821"
mem gone.md    40 "verify:" "  - gh acme/nope#1 merged"
OUT=$(run)
check_contains "jira gets its own finding"   "NEEDS_MCP"                  "$OUT"
check_contains "and says why"                "only through the Jira MCP"  "$OUT"
check_absent   "jira is not lumped into SKIP" "SKIP     teststore    jira.md" "$OUT"
check_contains "unqualified ref refused"     "ref-not-repo-qualified"     "$OUT"
check_contains "unknown kind refused"        "unknown verify kind"        "$OUT"
check_contains "malformed claim refused"     "malformed verify claim"     "$OUT"
check_contains "failed lookup refused"       "lookup-failed"              "$OUT"
check_eq       "exit 2 when only skips"      "2" "$(run_rc)"

echo ""
echo "=== An unverifiable open-state claim is triaged at ANY age ==="
# Not age-gated on purpose: a claim about something still open, with no verify
# block to check it against, is a defect the moment it is written. The corpus
# this was built for held a memory asserting three PRs were open when all three
# had merged that same day.
rm -f "$STORE"/*.md
mem old.md    40 "Still pending: merge, deploy, then live-verify. Refs services #4821."
mem fresh.md   0 "Still pending: merge, deploy, then live-verify."
OUT=$(run)
check_contains "old one triaged"          "TRIAGE"    "$OUT"
check_contains "names it"                 "old.md"    "$OUT"
check_contains "reports age"              "40d old"   "$OUT"
check_contains "a same-day one too"       "fresh.md"  "$OUT"
check_contains "reported as 0d, not hidden" "0d old"  "$OUT"
check_eq       "exit 2 on triage"         "2" "$(run_rc)"

echo ""
echo "=== Age parses both stamp formats, not just the one this suite writes ==="
# Two writers stamp `modified:` and they disagree: Claude Code writes an ISO
# datetime, memory-fix writes a bare date. BSD `date -f` requires the format to
# match the whole string, so the datetime format rejected a bare date and age
# fell through to mtime - the day of the last rewrite. Every stamp memory-fix
# backfilled therefore read as 0d old; the worst real case understated an
# 83-day-old memory as same-day, which is precisely what the staleness gate
# exists to catch.
#
# It survived 97 checks because days_ago() only ever emitted the format that
# parsed. The helper encoded the assumption, so the suite could not see past it.
rm -f "$STORE"/*.md
bare_stamp() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 days ago" +%Y-%m-%d; }
{ echo "---"
  echo "name: bare"
  echo "description: a memory stamped the way memory-fix stamps them"
  echo "metadata:"
  echo "  type: project"
  echo "  modified: $(bare_stamp 40)"
  echo "---"
  echo "Still pending: merge, deploy, then live-verify."
} > "$STORE/bare.md"
OUT=$(run)
check_contains "bare date is read as its stamp" "40d old" "$OUT"
# Leading space on purpose: "0d old" is a substring of "40d old".
check_absent   "not mistaken for same-day"      " 0d old" "$OUT"

echo "=== describing GitHub's own states is not a liveness claim ==="
# A bare "pending" used to be enough. Memories talk about review states
# constantly, so it was two thirds noise, and a finding that cries wolf is one
# nobody reads.
rm -f "$STORE"/*.md
mem describes.md 40 "MERGEABLE just means required checks are pending — the healthy state." \
                    "A required check may be missing, pending, or failed."
OUT=$(run)
check_absent "descriptive uses are ignored" "describes.md" "$OUT"
check_eq     "exit 0"                       "0" "$(run_rc)"

rm -f "$STORE"/*.md
mem real.md 40 "Shipped, pending review: services#4821." 
check_contains "an actual liveness construction still fires" "TRIAGE" "$(run)"

rm -f "$STORE"/*.md
mem real2.md 40 "The rollout is still pending."
check_contains "so does 'still pending'" "TRIAGE" "$(run)"

echo ""

echo ""
echo "=== but a durable fact with no liveness claim is still left alone ==="
rm -f "$STORE"/*.md
mem durable.md 0 "The consumer runs on one core; measured, not configured."
OUT=$(run)
check_absent "no finding for a fresh durable fact" "durable.md" "$OUT"
check_eq     "exit 0"                              "0" "$(run_rc)"

echo ""
echo "=== Self-contradiction inside one file is called out ==="
rm -f "$STORE"/*.md
mem both.md 40 "Still pending: awaiting review." "" "Update: merged and verified in prod."
OUT=$(run)
check_contains "contradiction noted" "self-contradictory" "$OUT"

echo ""
echo "=== Reference list is trimmed of noise and capped ==="
rm -f "$STORE"/*.md
mem noisy.md 40 "Still pending." "Hashes are SHA-256 and stamps are ISO-8601. See #1441 #1458."
mem many.md  40 "Still pending." "#1001 #1002 #1003 #1004 #1005 #1006 #1007 #1008 #1009 #1010"
OUT=$(run)
check_absent   "standards tokens dropped" "SHA-256"       "$OUT"
check_absent   "iso token dropped"        "ISO-8601"      "$OUT"
check_contains "real refs kept"           "#1441"         "$OUT"
check_contains "long lists capped"        "and 2 more"    "$OUT"

echo ""
echo "=== The index is checked for claims, but is not itself a memory ==="
# It is a list of links, so it gets no verify-block resolution and is never
# counted as a memory — but its one-liners are prose that can go stale, and
# they are the part loaded into context every session.
rm -f "$STORE"/*.md
{
  echo "verify:"
  echo "  - gh acme/api#4821 open"
  echo "- [Thing](thing.md) — a stable note about the loader"
} > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "verify block in the index is not resolved" "STALE" "$OUT"
check_eq     "nothing to report"                          "0" "$(run_rc)"

rm -f "$STORE"/*.md
printf -- "- [Gone](gone.md) — still pending, awaiting review\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_contains "claim about a missing target still flagged" "MEMORY.md:1" "$OUT"

echo ""
echo "=== Counters survive multiple claims in one file (subshell regression) ==="
rm -f "$STORE"/*.md
mem multi.md 40 "verify:" \
  "  - gh acme/api#4821 open" \
  "  - gh acme/web#900 merged" \
  "  - gh acme/api#4821 merged"
OUT=$(run)
check_contains "both mismatches counted" "2 stale" "$OUT"
check_contains "match counted too"       "1 verified" "$OUT"

echo ""
echo "=== --json is machine-readable ==="
rm -f "$STORE"/*.md
mem j.md 40 "verify:" "  - gh acme/api#4821 open"
OUT=$(run --json)
if printf '%s\n' "$OUT" | jq -e . >/dev/null 2>&1; then pass "emits valid JSON"; else fail "emits valid JSON" "$OUT"; fi
check_eq "json status field" "STALE" "$(printf '%s\n' "$OUT" | jq -r '.status' | head -1)"
check_eq "json file field"   "j.md"  "$(printf '%s\n' "$OUT" | jq -r '.file'   | head -1)"
check_eq "json store field"  "teststore" "$(printf '%s\n' "$OUT" | jq -r '.store' | head -1)"

echo ""
echo "=== Memories are never modified ==="
rm -f "$STORE"/*.md
mem immutable.md 40 "verify:" "  - gh acme/api#4821 open"
BEFORE=$(shasum -a 256 "$STORE/immutable.md" | awk '{print $1}')
run >/dev/null 2>&1
AFTER=$(shasum -a 256 "$STORE/immutable.md" | awk '{print $1}')
check_eq "file untouched after a run" "$BEFORE" "$AFTER"

echo ""
echo "=== A clean store prints nothing at all, not a bare header ==="
rm -f "$STORE"/*.md
mem quiet.md 40 "Nothing in flight here; this just records how the loader works."
OUT=$(run)
check_absent "no store header when there is nothing to say" "teststore" "$OUT"
check_contains "still reports totals" "0 stale, 0 triage" "$OUT"

echo ""
echo "=== State words are matched on word boundaries ==="
rm -f "$STORE"/*.md
mem unres.md 40 "Pending review. The root cause is still unresolved."
OUT=$(run)
check_contains "still triaged"                    "unres.md"           "$OUT"
check_absent   "'unresolved' is not closed state" "self-contradictory" "$OUT"
rm -f "$STORE"/*.md
mem withheld.md 40 "Payment was withheld last quarter."
OUT=$(run)
check_absent "'withheld' does not mean 'held'" "withheld.md" "$OUT"

echo ""
echo "=== Prose that merely reuses state words is not an open claim ==="
# All three are real sentences from the memories this was first run against.
rm -f "$STORE"/*.md
mem heldout.md  40 "Fitted on two tenants; predicts 702s vs actual 741s (5% held-out error)."
mem bearing.md  40 "The claim will recur on future additions and is load-bearing in review."
mem disposn.md  40 "Every candidate gets a disposition: included / held / skipped-with-reason."
OUT=$(run)
check_absent "'held-out' is a statistic"        "heldout.md" "$OUT"
check_absent "'in review' as prose, not status" "bearing.md" "$OUT"
check_absent "'held' as a disposition label"    "disposn.md" "$OUT"

echo ""
echo "=== but the terms that earn their place still fire ==="
rm -f "$STORE"/*.md
mem p1.md 40 "Pending release: the cut has not gone out."
mem p2.md 40 "Notebook committed but NOT pushed — awaiting a go for push/PR."
mem p3.md 40 "Shipped behind draft PR 1493; do not land yet."
OUT=$(run)
check_contains "pending fires"  "p1.md" "$OUT"
check_contains "awaiting fires" "p2.md" "$OUT"
check_contains "draft pr fires" "p3.md" "$OUT"

echo ""
echo "=== A stale claim in the index itself is caught ==="
# The index is skipped as a memory, which used to mean a stale hook was never
# examined — despite being the part loaded into context every session.
rm -f "$STORE"/*.md
mem thing.md 40 "This one is fine and says nothing about being in flight."
printf -- "- [Thing](thing.md) — awaiting the new dump before regenerating\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_contains "index line flagged"        "MEMORY.md:1" "$OUT"
check_contains "names the linked memory"   "thing.md"    "$OUT"
check_contains "ages by the linked memory" "40d old"     "$OUT"

echo ""
echo "=== ...but a fresh index line is not nagged about ==="
rm -f "$STORE"/*.md
mem recent.md 2 "Body says nothing in flight."
printf -- "- [Recent](recent.md) — awaiting review\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "young linked memory left alone" "MEMORY.md" "$OUT"

echo ""
echo "=== A clean index stays silent ==="
rm -f "$STORE"/*.md
mem calm.md 40 "Nothing in flight."
printf -- "- [Calm](calm.md) — how the loader resolves paths\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "no index noise when clean" "MEMORY.md" "$OUT"
check_eq     "exit 0"                    "0" "$(run_rc)"

echo ""
echo "=== A store that does not exist is an error, not a clean bill of health ==="
OUT=$(bash "$SCRIPT" --store no-such-store 2>&1)
RC=$(bash "$SCRIPT" --store no-such-store >/dev/null 2>&1; echo $?)
check_contains "says the store is missing" "no store named" "$OUT"
check_eq       "exit 3, not 0"             "3" "$RC"

echo ""

# ---------------------------------------------------------------------------
# Index load limits. The index is the only file pulled into context every
# session, so passing either limit truncates its tail silently.
# ---------------------------------------------------------------------------
mem_about() {  # mem_about <filename> <age_days> <ticket-key> <body...>
  local name="$1" age="$2" key="$3"; shift 3
  {
    echo "---"
    echo "name: ${name%.md}"
    echo "description: $key fixture"
    echo "metadata:"
    echo "  type: project"
    echo "  modified: $(days_ago "$age")"
    echo "---"
    printf '%s\n' "$@"
  } > "$STORE/$name"
}

rm -f "$STORE"/*.md
mem a.md 1 "plain body"

echo ""
echo "=== An index inside both limits is not flagged ==="
echo "- [a](a.md) — hook" > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "no OVERSIZE for a small index" "OVERSIZE" "$OUT"

echo ""
echo "=== An index past the LINE limit is OVERSIZE ==="
i=0; : > "$STORE/MEMORY.md"
while [ "$i" -lt 205 ]; do echo "- [a](a.md) — hook" >> "$STORE/MEMORY.md"; i=$((i+1)); done
export MEMORY_INDEX_MAX_LINES=200
OUT=$(run)
check_contains "flagged"                 "OVERSIZE"        "$OUT"
check_contains "names the line count"    "205/200 lines"   "$OUT"
check_contains "counts the entries"      "205 entries"     "$OUT"
check_contains "says shortening hooks cannot fix it" "shortening hooks cannot fix" "$OUT"
RC=$(run_rc)
check_eq "oversize alone still exits 2 (needs attention)" "2" "$RC"
unset MEMORY_INDEX_MAX_LINES

echo ""
echo "=== An index past the BYTE limit is OVERSIZE even when the line count is fine ==="
: > "$STORE/MEMORY.md"
LONG=$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0)
i=0
while [ "$i" -lt 10 ]; do echo "- [a](a.md) — $LONG" >> "$STORE/MEMORY.md"; i=$((i+1)); done
export MEMORY_INDEX_MAX_CHARS=100
OUT=$(run)
check_contains "flagged on size"      "OVERSIZE" "$OUT"
# Bytes, not characters. wc -c counts bytes and the upstream limit is stated in
# KB, so reporting the same number as "chars" is what let a 24,688-character
# index read as compliant while measuring 25,150 bytes and still being truncated.
check_contains "names the byte limit" "/100 bytes" "$OUT"
unset MEMORY_INDEX_MAX_CHARS
OUT=$(run)
check_absent "and is silent again at the default byte limit" "OVERSIZE" "$OUT"

# ---------------------------------------------------------------------------
# Curation pass. Overlap only — there is deliberately no retirement heuristic.
# ---------------------------------------------------------------------------
echo ""
echo "=== --curate groups memories that make the SAME CLAIMS ==="
rm -f "$STORE"/*.md
mem_about one.md   40 "PROJ-77" "**the consumer runs on a single core, measured**" \
                                "**the tier is discovered by OOM retry, not configured**"
mem_about two.md   40 "PROJ-77" "restating it: **the consumer runs on a single core, measured**" \
                                "and **the tier is discovered by OOM retry, not configured**"
OUT=$(run --curate)
check_contains "an overlapping pair is a merge candidate" "merge? these two share 2" "$OUT"
check_contains "the first file is named"                  "one.md"                   "$OUT"
check_contains "the second file is named"                 "two.md"                   "$OUT"

echo ""
echo "=== sharing a ticket key but no claims is NOT a merge candidate ==="
# The heuristic this replaced keyed on ticket number. Measured on a real store
# that produced four groups, of which three shared zero content: one memory
# records a fix and another records a lesson learned beside it, and they are
# correctly separate files.
rm -f "$STORE"/*.md
mem_about fix.md    40 "PROJ-77" "**the null check was missing on the boot path**"
mem_about lesson.md 40 "PROJ-77" "**always read cardinalities before theorising**"
OUT=$(run --curate)
check_absent "same ticket alone does not group" "CANDIDATE" "$OUT"

echo ""
echo "=== a single shared claim is below the threshold ==="
rm -f "$STORE"/*.md
mem_about a.md 40 "PROJ-1" "**one identical sentence shared between the pair**"
mem_about b.md 40 "PROJ-2" "**one identical sentence shared between the pair**"
OUT=$(run --curate)
check_absent "one overlap is not enough" "CANDIDATE" "$OUT"

echo ""
echo "=== short bolded labels do not manufacture overlap ==="
rm -f "$STORE"/*.md
mem_about x.md 40 "PROJ-3" "**Note**" "**Why:**" "distinct body one"
mem_about y.md 40 "PROJ-4" "**Note**" "**Why:**" "distinct body two"
OUT=$(run --curate)
check_absent "labels are excluded by the length floor" "CANDIDATE" "$OUT"

echo ""

echo "=== SETTLED: a project memory whose work is finished, advisory only ==="
# The sound form of the withdrawn retirement heuristic. That one guessed
# settledness from prose and flagged two durable facts. This one reads resolved
# evidence, only ever moves an INDEX LINE, and never touches the file.
rm -f "$STORE"/*.md
mem done_work.md 40 "verify:" "  - gh acme/api#4821 merged" "" "The idle-timeout fix landed."
OUT=$(run --curate)
check_contains "flagged under --curate"  "SETTLED"                       "$OUT"
check_contains "names the memory"        "done_work.md"                  "$OUT"
check_contains "says it is verified"     "every claim verified terminal" "$OUT"
check_absent   "silent on a default run" "SETTLED" "$(run)"
check_eq       "does not change the exit code" "0" "$(run_rc --curate)"

echo ""
echo "=== anything still open disqualifies ==="
rm -f "$STORE"/*.md
mem half.md 40 "verify:" "  - gh acme/api#4821 merged" "  - gh acme/web#900 open" "" "One half landed."
check_absent "one open claim is enough" "SETTLED" "$(run --curate)"

rm -f "$STORE"/*.md
mem talky.md 40 "verify:" "  - gh acme/api#4821 merged" "" "Landed, but the rollout is blocked on review."
check_absent "in-flight language in the body disqualifies" "SETTLED" "$(run --curate)"

echo ""
echo "=== only project memories settle; a durable fact has no lifecycle ==="
rm -f "$STORE"/*.md
mem lesson.md 40 "verify:" "  - gh acme/api#4821 merged" "" "The lesson outlives the ticket."
sed -i.bak 's/^  type: project/  type: reference/' "$STORE/lesson.md" && rm -f "$STORE/lesson.md.bak"
check_absent "a reference memory never settles" "SETTLED" "$(run --curate)"

echo ""
echo "=== a jira-only memory settles on RECORDED evidence, and says so ==="
# The shell cannot reach Jira, so the block is the only evidence there is. Good
# enough to suggest a reversible index move; the skill's next run says STALE if
# it ever diverges.
rm -f "$STORE"/*.md
mem tracked.md 40 "verify:" "  - jira PROJ-1 Done" "" "Shipped."
OUT=$(run --curate)
check_contains "flagged"                 "SETTLED"                   "$OUT"
check_contains "labelled as recorded"    "per the RECORDED evidence" "$OUT"
check_absent   "not claimed as verified" "every claim verified"      "$OUT"

rm -f "$STORE"/*.md
mem ongoing.md 40 "verify:" "  - jira PROJ-1 In Progress" "" "Underway."
check_absent "a non-terminal jira status disqualifies" "SETTLED" "$(run --curate)"

echo ""
echo "=== SETTLED never edits or deletes anything ==="
rm -f "$STORE"/*.md
mem done_work.md 40 "verify:" "  - gh acme/api#4821 merged" "" "Landed."
SUM_BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
run --curate >/dev/null 2>&1
check_eq "file untouched" "$SUM_BEFORE" "$(cat "$STORE"/*.md | shasum | awk '{print $1}')"
check_eq "and still present" "1" "$(ls "$STORE"/*.md | wc -l | tr -d ' ')"

echo ""

echo "=== Candidates are advisory: only with --curate, and never a deletion ==="
OUT=$(run)
check_absent "no CANDIDATE without the flag" "CANDIDATE" "$OUT"
OUT=$(run --curate)
check_absent "never proposes retirement"     "retire?"   "$OUT"

echo ""
echo "=== --curate still modifies nothing ==="
SUM_BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
run --curate >/dev/null 2>&1
SUM_AFTER=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
check_eq "memories are byte-identical after a curate run" "$SUM_BEFORE" "$SUM_AFTER"

echo ""
echo "=== SETTLED is not re-flagged once the index line is already archived ==="
# The finding's whole advice is "the index line can move to the archive
# section". For a line already sitting there it is vacuous, and it costs a
# reader the detour of opening the memory to find that out. Measured on a real
# store: all 7 SETTLED findings on one run were already archived.
rm -f "$STORE"/*.md
mem done_work.md 40 "verify:" "  - gh acme/api#4821 merged" "" "The idle-timeout fix landed."
check_contains "flagged while the line is still in the index" "SETTLED" "$(run --curate)"
printf '%s\n' "# Memory archive" "- [Done work](done_work.md) — the idle-timeout fix" > "$STORE/MEMORY_ARCHIVE.md"
check_absent   "silent once the line is archived"             "SETTLED" "$(run --curate)"

echo ""
echo "=== but an archive that does not list it still leaves it flagged ==="
# Guards the helper against matching the archive as a whole rather than the
# memory: an unrelated archived line must not silence every SETTLED finding.
printf '%s\n' "# Memory archive" "- [Something else](other_thing.md) — unrelated" > "$STORE/MEMORY_ARCHIVE.md"
check_contains "still flagged" "SETTLED" "$(run --curate)"

echo ""
echo "=== neither index is scanned as if it were a memory ==="
# MEMORY_ARCHIVE.md holds index lines whose hooks quote the memories they point
# at. Scanning it re-reports their claims against a file with no frontmatter, no
# type and no verify block. The old guard named ARCHIVE.md, which never existed.
rm -f "$STORE"/*.md
mem real.md 40 "verify:" "  - gh acme/api#4821 merged" "" "Landed."
printf '%s\n' "# Memory archive" \
  "- [Old thing](old_thing.md) — still open, awaiting review, blocked on the rollout" \
  > "$STORE/MEMORY_ARCHIVE.md"
OUT=$(run --curate)
check_absent "no finding names the archive"  "MEMORY_ARCHIVE.md" "$OUT"
check_absent "and none names ARCHIVE.md"     " ARCHIVE.md"       "$OUT"
rm -f "$STORE"/MEMORY_ARCHIVE.md

echo ""
echo "=== A hook that trails off is flagged when the payload is recoverable ==="
# ---------------------------------------------------------------------------
# The hook is the only part of a memory loaded every session. One trailing off
# mid-claim spends the index line and delivers nothing. Flagged only when the
# memory's own description still carries the claim, so the fix is one edit.
mem_desc() {  # mem_desc <filename> <description> <body...>
  local name="$1" d="$2"; shift 2
  {
    echo "---"; echo "name: ${name%.md}"; echo "description: $d"
    echo "metadata:"; echo "  type: reference"; echo "  modified: $(days_ago 40)"
    echo "---"; printf '%s
' "$@"
  } > "$STORE/$name"
}

rm -f "$STORE"/*.md
mem_desc fleet.md "add_skip_edge cost tracks graph shape, not observation volume; 3 of 48 tenants carry 98.8% of it" "body"
echo "- [add_skip_edge is SHAPE not volume](fleet.md) — 3 of 48 tenants carry…" > "$STORE/MEMORY.md"
OUT=$(run)
check_contains "trailed-off hook flagged"     "HOOK"          "$OUT"
check_contains "names the index line"         "MEMORY.md:1"   "$OUT"
check_contains "quotes the payload to use"    "98.8%"         "$OUT"
check_eq       "advisory: does not fail the run" "0" "$(run_rc)"

echo ""
echo "=== A dangling connective counts as trailing off ==="
# "— and" and "content fix→LSC," are the same defect without the ellipsis,
# and were the two the eye skips over.
echo "- [Spark EJC ceiling](fleet.md) — and" > "$STORE/MEMORY.md"
check_contains "bare connective flagged" "HOOK" "$(run)"
echo "- [Spark EJC ceiling](fleet.md) — content fix to LSC," > "$STORE/MEMORY.md"
check_contains "trailing comma flagged"  "HOOK" "$(run)"

echo ""
echo "=== A complete hook is left alone ==="
echo "- [add_skip_edge is SHAPE not volume](fleet.md) — 3 of 48 tenants = 98.8%" > "$STORE/MEMORY.md"
check_absent "complete hook not flagged" "HOOK" "$(run)"

echo ""
echo "=== A terse hook on a terse description is not a defect ==="
# Guards the ratio: without it every short hook is flagged and the check is
# noise. There is no payload to recover here, so there is nothing to report.
mem_desc terse.md "one spelling, one place" "body"
echo "- [Terse](terse.md) — one spelling, one place," > "$STORE/MEMORY.md"
check_absent "no finding when the description adds nothing" "HOOK" "$(run)"

echo ""
echo "=== A hook pointing at a missing or frontmatter-less file is not guessed at ==="
# MEMORY_ARCHIVE.md has no description; reporting against it would be a finding
# no edit can clear.
echo "- [Gone](nosuchfile.md) — trails off…" > "$STORE/MEMORY.md"
check_absent "missing target skipped" "HOOK" "$(run)"
rm -f "$STORE"/MEMORY.md

echo ""
echo "=== gh claims are looked up in one GraphQL call per repo, not one per claim ==="
rm -f "$STORE"/*.md "$FAKEGH_LOG"
mem b1.md 40 "verify:" "  - gh acme/bulk#1 open" "  - gh acme/bulk#2 open" "  - gh acme/api#4821 merged"
mem b2.md 40 "verify:" "  - gh acme/bulk#3 open" "  - gh acme/bulk#1 open"
mem b3.md 40 "verify:" "  - gh acme/bulk#4 open" "  - gh acme/bulk#5 open" "  - gh acme/bulk#6 open"
OUT=$(run --all)
check_eq       "8 claims, 7 refs, 2 repos: 2 calls"  "2" "$(calls)"
check_contains "and every claim is answered"          "8 verified" "$OUT"
check_eq       "the repeated ref is asked once"      "acme/bulk 6" "$(grep bulk "$FAKEGH_LOG")"
rm -f "$FAKEGH_LOG"
MEMORY_VERIFY_GH_BATCH=4 run >/dev/null
check_eq       "a batch of 4: 6 numbers take 2 calls, plus 1" "3" "$(calls)"

echo ""
echo "=== a wrong merged claim is STALE: merged is looked up like any other ==="
rm -f "$STORE"/*.md "$FAKEGH_LOG"
mem wrongmerged.md 40 "verify:" "  - gh acme/web#900 merged"
OUT=$(run)
check_contains "flagged STALE"       "acme/web#900 expected=merged actual=OPEN" "$OUT"
check_eq       "exit 1"              "1" "$(run_rc)"

echo ""
echo "=== one null alias is a SKIP for its claim; its batch still resolves ==="
# gh exits 1 here with the other aliases' data on stdout, as the probe showed.
rm -f "$STORE"/*.md "$FAKEGH_LOG"
mem partial.md 40 "verify:" "  - gh acme/api#4821 merged" "  - gh acme/api#77 open" "  - gh acme/api#4821 open"
OUT=$(run --all)
check_eq       "one call"                          "1" "$(calls)"
check_contains "the missing number is SKIP"        "acme/api#77 not-found" "$OUT"
check_contains "its neighbour is still VERIFIED"   "acme/api#4821 is MERGED, as recorded" "$OUT"
check_contains "and still caught when wrong"       "expected=open actual=MERGED" "$OUT"
check_contains "counted once each"                 "1 stale, 0 triage, 0 need-mcp, 1 skipped, 1 verified" "$OUT"

echo ""
echo "=== a repo GitHub does not know, or no answer at all, is lookup-failed ==="
rm -f "$STORE"/*.md "$FAKEGH_LOG"
mem norepo.md 40 "verify:" "  - gh acme/nope#1 merged" "  - gh acme/api#4821 merged"
OUT=$(run --all)
check_contains "the unknown repo is SKIP"  "acme/nope#1 lookup-failed" "$OUT"
check_contains "the other repo resolves"   "acme/api#4821 is MERGED"   "$OUT"
OUT=$(FAKEGH_DOWN=1 run --all)
check_contains "gh down: SKIP, not a pass" "acme/api#4821 lookup-failed" "$OUT"
check_absent   "and nothing is VERIFIED"   "VERIFIED" "$OUT"
check_eq       "exit 2"                    "2" "$(FAKEGH_DOWN=1 run_rc)"

echo ""
echo "=== a ref the query cannot carry is refused before any call ==="
rm -f "$STORE"/*.md "$FAKEGH_LOG"
mem shapes.md 40 "verify:" "  - gh acme/api/x#1 merged" "  - gh acme/a\"pi#1 merged" "  - gh acme/api#04821 merged"
OUT=$(run --all)
check_contains "two slashes"                 "acme/api/x#1 ref-malformed" "$OUT"
check_contains "a quote in the name"         "ref-malformed" "$(printf '%s\n' "$OUT" | grep 'a"pi')"
check_contains "a leading zero is the same number" "acme/api#04821 is MERGED" "$OUT"
check_eq       "only the good one was asked" "acme/api 1" "$(cat "$FAKEGH_LOG")"

echo ""
echo "=== --jira-keys prints the jira claims' keys as JQL, 50 to a line ==="
rm -f "$STORE"/*.md "$FAKEGH_LOG"
mem j1.md 40 "verify:" "  - jira ABC-123 Done" "  - jira XYZ-1 In Progress" "  - gh acme/api#4821 merged"
mem j2.md 40 "verify:" "  - jira ABC-7 Done" "  - jira ABC-123 Done" "  - jira abc-9 Done" "  - jira DEF-2"
OUT=$(run --jira-keys)
check_eq "deduped, numeric order, gh and malformed left out" "key in (ABC-7, ABC-123, XYZ-1)" "$OUT"
check_eq "no lookup made"                                    "0" "$(calls)"
rm -f "$STORE"/*.md
{ echo "---"; echo "name: many"; echo "description: d"; echo "---"; echo "verify:"
  i=1; while [ "$i" -le 120 ]; do echo "  - jira ABC-$i Done"; i=$((i+1)); done; } > "$STORE/many.md"
OUT=$(run --jira-keys)
check_eq "120 keys: 3 lines"           "3" "$(printf '%s\n' "$OUT" | grep -c '^key in (')"
check_eq "50 on the first"             "50" "$(printf '%s\n' "$OUT" | head -1 | tr ',' '\n' | grep -c 'ABC-')"
check_eq "20 on the last"              "20" "$(printf '%s\n' "$OUT" | tail -1 | tr ',' '\n' | grep -c 'ABC-')"
check_eq "exit 0"                      "0" "$(run_rc --jira-keys)"

echo ""
echo "=== verify: none <reason> in the frontmatter waives TRIAGE, and is counted ==="
waiver_mem() {  # waiver_mem <file> <frontmatter line> <body...>
  local name="$1" w="$2"; shift 2
  { echo "---"; echo "name: ${name%.md}"; echo "description: d"; echo "$w"
    echo "metadata:"; echo "  type: project"; echo "  modified: $(days_ago 40)"
    echo "---"; printf '%s\n' "$@"; } > "$STORE/$name"
}
rm -f "$STORE"/*.md
waiver_mem waived.md "verify: none describes a recurring rota, not one ticket" "Each week the rota is awaiting a volunteer."
printf -- '- [W](waived.md) — the rota still awaiting a volunteer\n' > "$STORE/MEMORY.md"
OUT=$(run)
check_absent   "no TRIAGE for the memory"     "TRIAGE" "$OUT"
check_contains "counted in the Results line"  "1 waived" "$OUT"
check_eq       "exit 0"                       "0" "$(run_rc)"
check_contains "--all lists it with its reason" "verify: none, describes a recurring rota" "$(run --all)"
waiver_mem waived.md "  verify: none indented under metadata counts too" "Still pending review."
check_absent   "indented in the frontmatter" "TRIAGE" "$(run)"

waiver_mem waived.md "verify: none" "Each week the rota is awaiting a volunteer."
OUT=$(run)
check_contains "an empty reason is SKIP"       "verify: none gives no reason" "$OUT"
check_contains "and waives nothing"            "TRIAGE" "$OUT"
check_contains "nor is counted"                "0 waived" "$OUT"

{ echo "---"; echo "name: inbody"; echo "description: d"; echo "metadata:"; echo "  type: project"
  echo "---"; echo "verify: none in the body is not the frontmatter"; echo "Still pending review."; } > "$STORE/waived.md"
check_contains "outside the frontmatter it is no waiver" "TRIAGE" "$(run)"
rm -f "$STORE"/MEMORY.md

echo ""
echo "=== ORPHAN: a memory nothing links to ==="
rm -f "$STORE"/*.md
mem linked.md 40 "plain"; mem archived.md 40 "plain"; mem hubbed.md 40 "plain"; mem lost.md 40 "plain"
mem feedback_hub_x.md 40 "- [[hubbed]] the instance"
printf -- '- [L](linked.md) — hook\n- [H](feedback_hub_x.md) — hub\n' > "$STORE/MEMORY.md"
printf -- '# archive\n- [A](archived.md) — hook\n' > "$STORE/MEMORY_ARCHIVE.md"
OUT=$(run)
check_contains "the unlinked one is ORPHAN"     "ORPHAN   lost.md" "$OUT"
check_absent   "an index line reaches it"       "linked.md " "$(printf '%s\n' "$OUT" | grep ORPHAN)"
check_absent   "an archive line reaches it"     "archived.md" "$OUT"
check_absent   "a hub [[link]] reaches it"      "hubbed.md" "$OUT"
check_contains "counted"                        "1 orphans" "$OUT"
check_eq       "and needs attention: exit 2"    "2" "$(run_rc)"
rm -f "$STORE"/MEMORY.md "$STORE"/MEMORY_ARCHIVE.md
check_absent   "no index at all: nothing to orphan from" "ORPHAN" "$(run)"
rm -f "$STORE"/*.md

echo ""
echo "=== --offline runs no gh at all ==="
rm -f "$STORE"/*.md
mem stale.md 40 "verify:" "  - gh acme/api#4821 open" "" "Still a held draft."
mem lost.md 40 "plain"
printf -- '- [S](stale.md) — hook\n' > "$STORE/MEMORY.md"
# A gh on PATH that logs every call, with the testing seam unset: the path a real machine takes.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "gh $*" >> "%s"\nexit 0\n' "$TMP/pathgh.log" > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
: > "$FAKEGH_LOG"
OUT=$(PATH="$TMP/bin:$PATH" MEMORY_VERIFY_GH_CMD="" bash "$SCRIPT" --store teststore --offline 2>&1)
check_eq       "no gh on PATH ran, not even auth status" "0" "$(cat "$TMP/pathgh.log" 2>/dev/null | wc -l | tr -d ' ')"
check_contains "the claim is a SKIP, marked offline" "offline" "$(printf '%s\n' "$OUT" | grep stale.md)"
check_absent   "and is not called stale"             "STALE " "$OUT"
check_contains "what needs no network still reports" "ORPHAN   lost.md" "$OUT"
OUT=$(bash "$SCRIPT" --store teststore --offline 2>&1)
check_eq       "the testing seam is not called either" "0" "$(calls)"
check_contains "and the run says why"                 "NOTE: --offline" "$OUT"
rm -f "$STORE"/*.md

echo ""
echo "=== process starts: a run costs a few starts, not a few a row ==="
# Every external tool the script can reach is a shim on a PATH of shims alone:
# it logs its name, then runs the real binary by the ABSOLUTE path resolved before
# PATH changed (a shim that looked itself up again recursed). A tool missing from
# the list fails loudly, not uncounted.
SHIMS="$TMP/shims"; SLOG="$TMP/starts.log"; mkdir -p "$SHIMS"
for t in awk sed grep sort comm wc tr head cat date stat basename dirname mktemp rm jq uniq cut; do
  real=$(command -v "$t") || continue
  printf '#!%s\necho %s >> "%s"\nexec %s "$@"\n' "$BASH" "$t" "$SLOG" "$real" > "$SHIMS/$t"
  chmod +x "$SHIMS/$t"
done
# starts <tool|all> <projects dir> <args...>: starts of the tool in one run
starts() {
  local tool="$1" proj="$2"; shift 2
  : > "$SLOG"
  PATH="${SHIMPATH:-$SHIMS}" CLAUDE_MEMORY_PROJECTS_DIR="$proj" MEMORY_VERIFY_GH_CMD="" "$BASH" "$SCRIPT" "$@" >/dev/null 2>&1
  if [ "$tool" = all ]; then wc -l < "$SLOG" | tr -d ' '; else grep -cx "$tool" "$SLOG" || true; fi
}
# A store of $2 open-state memories, each with an index line that is both a TRIAGE
# line and a trailing-off hook. $3 = distinct: a stamp a day apart; same: one stamp.
mkstarts() {  # mkstarts <projects dir> <n> <distinct|same>
  local d="$1/s/memory" i stamp; rm -rf "$1"; mkdir -p "$d"
  for i in $(seq 1 "$2"); do
    if [ "$3" = distinct ]; then stamp=$(days_ago $((20 + i))); else stamp=$SAME_STAMP; fi
    printf -- '---\nname: m%s\ndescription: a description long enough to carry the payload\nmodified: %s\n---\nStill pending review of #%s.\n' \
      "$i" "$stamp" "$((100 + i))" > "$d/m$i.md"
    printf -- '- [m%s](m%s.md) \342\200\224 still pending review and\n' "$i" "$i" >> "$d/MEMORY.md"
  done
}
SAME_STAMP=$(days_ago 30)   # once: two builds a second apart would otherwise be two stamps
mkstarts "$TMP/sa" 10 distinct; mkstarts "$TMP/sb" 20 distinct
mkstarts "$TMP/sc" 10 same;     mkstarts "$TMP/sd" 20 same
check_eq "json mode: one jq for the whole run"       "1" "$(starts jq "$TMP/sb" --offline --json)"
check_eq "text mode: no jq at all"                   "0" "$(starts jq "$TMP/sb" --offline)"
check_eq "the 20 files give 40 TRIAGE rows"          "40" "$(PATH="$SHIMS" CLAUDE_MEMORY_PROJECTS_DIR="$TMP/sb" "$BASH" "$SCRIPT" --offline --json | grep -c '"status":"TRIAGE"')"
# Doubling the rows with distinct stamps costs one `date` a new file and nothing else.
A=$(starts all "$TMP/sa" --offline --json); B=$(starts all "$TMP/sb" --offline --json)
check_eq "10 more files, distinct stamps: 10 more starts, one a file" "10" "$((B - A))"
check_eq "and they are all date, one per stamp"      "10" "$(( $(starts date "$TMP/sb" --offline --json) - $(starts date "$TMP/sa" --offline --json) ))"
# Doubling rows that share one stamp costs nothing: the parse is memoised.
C=$(starts all "$TMP/sc" --offline --json); cp "$SLOG" "$TMP/starts.c"
D=$(starts all "$TMP/sd" --offline --json)
check_eq "10 more files, one stamp: no more starts"  "0" "$((D - C))"
[ "$D" = "$C" ] || { echo "  per-tool starts, 10 files then 20:"; sort "$TMP/starts.c" | uniq -c | tr '\n' ' '; echo; sort "$SLOG" | uniq -c | tr '\n' ' '; echo; }

# A tool that answers with text, not a number, must cost a day count, not the row:
# GNU `stat -f %m` prints filesystem status and exits 1; a stamp `date` cannot read.
BADSH="$TMP/badshims"; mkdir -p "$BADSH"; cp "$SHIMS"/* "$BADSH"/
printf '#!%s\necho "File: not a number"\nexit 0\n' "$BASH" > "$BADSH/stat"
printf '#!%s\ncase "$1" in -d|-j) echo "not a number"; exit 0 ;; esac\necho date >> "%s"\nexec %s "$@"\n' "$BASH" "$SLOG" "$(command -v date)" > "$BADSH/date"
chmod +x "$BADSH/stat" "$BADSH/date"
rm -rf "$TMP/sg"; mkdir -p "$TMP/sg/s/memory"
printf -- '---\nname: nostamp\n---\nStill pending review.\n' > "$TMP/sg/s/memory/nostamp.md"
printf -- '---\nname: badstamp\nmodified: 2026-01-01\n---\nStill pending review.\n' > "$TMP/sg/s/memory/badstamp.md"
OUT=$(SHIMPATH="$BADSH" PATH="$BADSH" CLAUDE_MEMORY_PROJECTS_DIR="$TMP/sg" MEMORY_VERIFY_GH_CMD="" "$BASH" "$SCRIPT" --offline --json 2>&1)
check_contains "a stat that prints text: the no-stamp file is still TRIAGE" '"file":"nostamp.md"' "$OUT"
check_contains "a date that prints text: the stamped file is still TRIAGE"  '"file":"badstamp.md"' "$OUT"
check_absent   "and nothing leaks from the arithmetic"                      "syntax error" "$OUT"

echo "--- Results: $PASS passed, $FAIL failed"
exit "$FAIL"
