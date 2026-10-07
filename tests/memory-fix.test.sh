#!/usr/bin/env bash
# Tests for memory-fix.sh — builds a synthetic memory store in a temp dir, so the
# suite is hermetic: no real memory is read or written.
#
# The invariant under test throughout is that this tool only makes changes with a
# single provably-correct answer. Half of these cases assert that it does NOT act.
set -u
SCRIPT="bin/memory-fix.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/teststore/memory"
mkdir -p "$STORE"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }
check_eq()       { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }
check_file()     { if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing file: $2"; fi; }

run()    { bash "$SCRIPT" --store teststore "$@" 2>&1; }
run_rc() { bash "$SCRIPT" --store teststore "$@" >/dev/null 2>&1; echo $?; }

# A memory with an explicit `name:` so tests can make it disagree with the file.
mem() {  # mem <filename> <name-value> <body...>
  local file="$1" nm="$2"; shift 2
  { echo "---"; echo "name: $nm"; echo "description: fixture"
    echo "metadata:"; echo "  type: reference"; echo "  modified: 2020-01-01"
    echo "---"; printf '%s\n' "$@"; } > "$STORE/$file"
}
# A memory with no `modified:` stamp at all.
mem_nostamp() {  # mem_nostamp <filename> <body...>
  local file="$1"; shift
  { echo "---"; echo "name: ${file%.md}"; echo "description: fixture"
    echo "metadata:"; echo "  type: reference"; echo "---"; printf '%s\n' "$@"; } > "$STORE/$file"
}
reset_store() { rm -rf "$STORE" && mkdir -p "$STORE"; }
git_store() {
  git -C "$STORE" init -q
  ( cd "$STORE" && git add -- *.md )
  git -C "$STORE" -c user.name=t -c user.email=t@t commit -q -m base
}

# ---------------------------------------------------------------------------
echo "=== A clean store is silent and exits 0 ==="
reset_store
mem a.md a "body with a good [[b]] link"
mem b.md b "body"
OUT=$(run); check_contains "reports clean" "clean: nothing to fix" "$OUT"
check_eq "exits 0" "0" "$(run_rc)"

# ---------------------------------------------------------------------------
echo ""
echo "=== name: is rewritten to the filename stem, and the file is NOT renamed ==="
reset_store
mem alpha_beta.md "alpha-beta" "body"
OUT=$(run)
check_contains "reports the mismatch"    "name:=stem 1"      "$OUT"
check_contains "names the wanted value"  "alpha_beta"        "$OUT"
check_eq       "dry run changes nothing" "alpha-beta" \
               "$(sed -n 's/^name: //p' "$STORE/alpha_beta.md")"
git_store; run --apply >/dev/null
check_eq   "frontmatter rewritten" "alpha_beta" "$(sed -n 's/^name: //p' "$STORE/alpha_beta.md")"
check_file "file kept its name"    "$STORE/alpha_beta.md"
check_eq   "second run is a no-op" "0" "$(run_rc --apply --force)"

echo ""
echo "=== a name: inside a fenced example in the body is left alone ==="
reset_store
mem gamma.md "gamma-x" 'Example frontmatter:' '```' 'name: not-a-real-memory' '```'
git_store; run --apply >/dev/null
check_eq "frontmatter fixed"     "gamma"              "$(sed -n '2s/^name: //p' "$STORE/gamma.md")"
check_contains "body untouched"  "name: not-a-real-memory" "$(cat "$STORE/gamma.md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== wiki-links: repaired only when exactly one file can be meant ==="
reset_store
mem one_two_three.md one_two_three "target"
mem src.md src "see [[one-two-three]] and [[one_two_three.md]]"
OUT=$(run)
check_contains "both variants counted" "links repaired 2" "$OUT"
git_store; run --apply >/dev/null
check_contains "hyphen form repaired"    "[[one_two_three]]"    "$(cat "$STORE/src.md")"
check_absent   "no hyphen form remains"  "[[one-two-three]]"    "$(cat "$STORE/src.md")"
check_absent   "no .md suffix remains"   "[[one_two_three.md]]" "$(cat "$STORE/src.md")"

echo ""
echo "=== a POSIX character class is not a wiki-link ==="
reset_store
mem re.md re 'match with sed "s/^[[:space:]]*x//" and [[:alpha:]] too'
OUT=$(run)
check_absent "not reported as a link"  ":space:"                 "$OUT"
check_contains "store still clean"     "clean: nothing to fix"   "$OUT"

echo ""
echo "=== a link to a memory that does not exist is a forward ref, not a defect ==="
reset_store
mem solo.md solo "worth writing later: [[project_not_yet_written]]"
OUT=$(run)
check_contains "reported as forward ref"  "forward ref"              "$OUT"
check_contains "named"                    "project_not_yet_written"  "$OUT"
check_absent   "never called ambiguous"   "AMBIGUOUS"                "$OUT"
git_store; run --apply --force >/dev/null
check_contains "left exactly as written"  "[[project_not_yet_written]]" "$(cat "$STORE/solo.md")"

echo ""
echo "=== a link with two possible targets is reported, never guessed ==="
reset_store
mem a_b_c.md a_b_c "one"
mem a-b_c.md a-b_c "two"
mem ref.md  ref   "ambiguous [[a-b-c]]"
OUT=$(run)
check_contains "flagged ambiguous"  "AMBIGUOUS link"  "$OUT"
check_contains "candidate count"    "(2 candidates)"  "$OUT"
git_store; run --apply --force >/dev/null
check_contains "left unchanged"     "[[a-b-c]]"       "$(cat "$STORE/ref.md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== modified: is backfilled from mtime, never from today ==="
reset_store
mem_nostamp old.md "body"
touch -t 202301150000 "$STORE/old.md"
OUT=$(run)
check_contains "counted" "modified backfilled 1" "$OUT"
git_store
touch -t 202301150000 "$STORE/old.md"     # git checkout/add can restat
run --apply >/dev/null
check_eq "stamped with the file's own mtime" "2023-01-15" \
         "$(sed -n 's/^  modified: //p' "$STORE/old.md")"
check_contains "provenance says mtime" "modified_source: mtime" "$(cat "$STORE/old.md")"
check_absent   "not stamped today"   "$(date +%Y-%m-%d)"      "$(sed -n 's/^  modified: //p' "$STORE/old.md")"
check_eq "second run is a no-op" "0" "$(run_rc --apply --force)"

echo ""
echo "=== when the mtime has been reset, the memory's own dates are used ==="
# A memory cannot predate the events it records, so the latest date written
# inside it is a real lower bound - unlike an mtime any tool can reset.
reset_store
mem_nostamp dated.md "The rollout finished on 2026-03-04." "Follow-up landed 2026-05-19."
OUT=$(run)
check_contains "counted as fixable"   "modified backfilled 1" "$OUT"
git_store; run --apply --force >/dev/null
check_eq "stamped with the LATEST date in the body" "2026-05-19" \
         "$(sed -n 's/^  modified: //p' "$STORE/dated.md")"
check_contains "provenance says content" "modified_source: content" "$(cat "$STORE/dated.md")"

echo ""
echo "=== a date in the future never becomes the stamp ==="
reset_store
mem_nostamp planned.md "Shipped 2026-02-02. Cutover is scheduled for 2099-12-31."
git_store; run --apply --force >/dev/null
check_eq "capped at today, so the past date wins" "2026-02-02" \
         "$(sed -n 's/^  modified: //p' "$STORE/planned.md")"

echo ""
echo "=== with no date anywhere, it stays unstamped rather than fabricated ==="
reset_store
mem_nostamp fresh.md "body with no dates at all"   # created now, so mtime is today
OUT=$(run)
check_contains "reported as undatable" "no usable date"          "$OUT"
check_absent   "not counted as a fix"  "modified backfilled 1"   "$OUT"
git_store; run --apply --force >/dev/null
check_absent "left unstamped rather than stamped today" "modified:" "$(cat "$STORE/fresh.md")"

echo ""
echo "=== normalising a name does not advance that memory's modified stamp ==="
reset_store
mem_nostamp drift.md "body"
# Rewrite the name so pass 1 must edit the file, and backdate it.
sed -i.bak 's/^name: drift/name: drift-x/' "$STORE/drift.md" && rm -f "$STORE/drift.md.bak"
touch -t 202301150000 "$STORE/drift.md"
git_store
touch -t 202301150000 "$STORE/drift.md"
run --apply >/dev/null
check_eq "name fixed"                    "drift"      "$(sed -n 's/^name: //p' "$STORE/drift.md")"
check_eq "stamp is the ORIGINAL mtime"   "2023-01-15" "$(sed -n 's/^  modified: //p' "$STORE/drift.md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== a memory with no name: is malformed, and says so on its own ==="
reset_store
printf -- '---\ndescription: d\nmetadata:\n  type: reference\n---\nbody\n' > "$STORE/noname.md"
OUT=$(run)
check_contains "missing name reported"          "no name: in frontmatter" "$OUT"
check_contains "counted as malformed"           "1 memories have malformed frontmatter" "$OUT"
check_absent   "not counted as ambiguous links" "ambiguous 1" "$OUT"

echo ""
echo "=== older flat frontmatter is stamped in place, not restructured ==="
# These exist: `type:` at the top level with no `metadata:` block. Rewriting
# their shape would be a bigger change than the one repair being made, so the
# stamp matches the style already there.
reset_store
printf -- '---\nname: flat\ndescription: d\ntype: reference\n---\nShipped 2026-03-09.\n' > "$STORE/flat.md"
git_store; run --apply --force >/dev/null
check_eq "stamped from the body date" "2026-03-09" \
         "$(sed -n 's/^modified: //p' "$STORE/flat.md")"
check_contains "at the top level, matching the file" "$(printf 'type: reference\nmodified: 2026-03-09')" "$(cat "$STORE/flat.md")"
check_absent   "no metadata: block invented"         "metadata:" "$(cat "$STORE/flat.md")"
check_eq       "second run is a no-op" "0" "$(run_rc --apply --force)"

# ---------------------------------------------------------------------------
echo ""
echo "=== --apply refuses where there would be no undo ==="
reset_store
mem nogit.md "nogit-x" "body"
OUT=$(run --apply)
check_contains "refuses without git"     "not a git repo"  "$OUT"
check_eq       "exits 3"                 "3"               "$(run_rc --apply)"
check_eq       "and changed nothing"     "nogit-x"         "$(sed -n 's/^name: //p' "$STORE/nogit.md")"

echo ""
echo "=== --apply refuses on a dirty store, so the fix lands as its own commit ==="
reset_store
mem dirty.md "dirty-x" "body"
git_store
echo "uncommitted edit" >> "$STORE/dirty.md"
OUT=$(run --apply)
check_contains "refuses when dirty" "uncommitted changes" "$OUT"
check_eq       "exits 3"            "3"                   "$(run_rc --apply)"
check_contains "--force overrides"  "applied"             "$(run --apply --force)"

# ---------------------------------------------------------------------------
echo ""
echo "=== a dry run never writes ==="
reset_store
mem d1.md "d1-x" "link [[d2-x]]"
mem_nostamp d2.md "body"
BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
run >/dev/null 2>&1
AFTER=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
check_eq "store byte-identical after a dry run" "$BEFORE" "$AFTER"


# ===========================================================================
# --provenance: originSessionId recovered from the transcripts
# ===========================================================================
# The evidence lives beside the store: <projects>/<slug>/<sessionId>.jsonl, and
# the transcript's filename IS the session id. These helpers write one recorded
# tool call each, in the two shapes a memory actually gets written by.

# Shape 1: the Write tool, which records an absolute file_path.
tx_write() {  # tx_write <session-uuid> <timestamp> <memory-filename>
  printf '{"timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/%s","content":"x"}}]}}\n' \
    "$2" "$STORE" "$3" >> "$CLAUDE_MEMORY_PROJECTS_DIR/teststore/$1.jsonl"
}
# Shape 2: a Bash heredoc. There is no file_path key anywhere in this line, and
# the directory is a shell variable — this is the shape that carries almost all
# of the real corpus, and the shape a file_path query cannot see.
tx_bash() {  # tx_bash <session-uuid> <timestamp> <memory-filename>
  printf '{"timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"M=%s; cat > \\"$M/%s\\" <<EOF\\nbody\\nEOF"}}]}}\n' \
    "$2" "$STORE" "$3" >> "$CLAUDE_MEMORY_PROJECTS_DIR/teststore/$1.jsonl"
}
# A memory carrying an origin already, so tests can prove it is never rewritten.
mem_origin() {  # mem_origin <filename> <session-uuid>
  { echo "---"; echo "name: ${1%.md}"; echo "description: fixture"
    echo "metadata:"; echo "  type: reference"; echo "  originSessionId: $2"
    echo "---"; echo "body"; } > "$STORE/$1"
}
# Clear the transcripts as well as the store: a leftover .jsonl from the
# previous case is evidence, and would silently attribute the next one.
reset_prov() {
  reset_store
  rm -f "$CLAUDE_MEMORY_PROJECTS_DIR/teststore"/*.jsonl
}

EARLY=11111111-1111-1111-1111-111111111111
LATE=22222222-2222-2222-2222-222222222222

echo ""
echo "=== the earliest write wins, not the most recent one ==="
# Several sessions write the same memory; the one that created it got there
# first. Same rule as session-route.sh uses to pick a PR's raiser.
reset_prov
mem_nostamp shared.md "body"
tx_write "$LATE"  2026-05-05T10:00:00.000Z shared.md
tx_write "$EARLY" 2026-01-01T10:00:00.000Z shared.md
tx_write "$LATE"  2026-06-06T10:00:00.000Z shared.md
OUT=$(run --provenance)
check_contains "counted as recoverable" "origin recovered 1" "$OUT"
check_contains "names the earliest writer" "11111111" "$OUT"
git_store; run --provenance --apply >/dev/null
check_eq "stamped with the earliest writer" "$EARLY" \
         "$(sed -n 's/^  originSessionId: //p' "$STORE/shared.md")"
check_absent "the later writer is not the origin" "$LATE" "$(cat "$STORE/shared.md")"

echo ""
echo "=== the recovered origin is labelled as derived, never passed off as first-party ==="
reset_prov
mem_nostamp derived.md "body"
tx_write "$EARLY" 2026-01-01T10:00:00.000Z derived.md
git_store; run --provenance --apply >/dev/null
check_contains "origin written"      "originSessionId: $EARLY"          "$(cat "$STORE/derived.md")"
check_contains "and marked derived"  "originSessionId_source: transcript" "$(cat "$STORE/derived.md")"

echo ""
echo "=== an origin already on the file is never overwritten ==="
# Even when the transcripts name a different, earlier session. A first-party
# stamp is the writer's own record; this tool does not get to argue with it.
reset_prov
mem_origin kept.md "0000-first-party"
tx_write "$EARLY" 2020-01-01T10:00:00.000Z kept.md
OUT=$(run --provenance)
check_contains "counted as already stamped" "already stamped 1" "$OUT"
check_absent   "not counted as recoverable" "origin recovered 1" "$OUT"
git_store; run --provenance --apply --force >/dev/null
check_eq       "left exactly as it was" "0000-first-party" \
               "$(sed -n 's/^  originSessionId: //p' "$STORE/kept.md")"
check_absent   "no derived label added" "originSessionId_source" "$(cat "$STORE/kept.md")"

echo ""
echo "=== a memory no transcript wrote stays ANON, and is counted, not dropped ==="
# The failure this guards against is a report that lists only its successes:
# "recovered 90" reads as done, while the memories nothing can attribute stay
# invisible. They are the ones a reader most needs to know about.
reset_prov
mem_nostamp evidenced.md "body"
mem_nostamp orphan.md   "body"
tx_write "$EARLY" 2026-01-01T10:00:00.000Z evidenced.md
OUT=$(run --provenance)
check_contains "the orphan is named"      "still ANON  orphan"  "$OUT"
check_contains "and counted"              "still ANON 1"        "$OUT"
check_contains "the denominator is printed" "scanned 2"         "$OUT"
check_contains "so is the recovered count"  "origin recovered 1" "$OUT"
git_store; run --provenance --apply --force >/dev/null
check_absent "nothing invented for it" "originSessionId" "$(cat "$STORE/orphan.md")"

echo ""
echo "=== a Bash heredoc write is evidence too — it carries no file_path key ==="
# Measured on the real corpus: the file_path shape alone recovers 1 memory of
# 120; adding this shape recovers 90. A query that sees one spelling of a write
# is not a census of writes.
reset_prov
mem_nostamp viabash.md "body"
tx_bash "$EARLY" 2026-01-01T10:00:00.000Z viabash.md
OUT=$(run --provenance)
check_absent   "the fixture really has no file_path key" "file_path" \
               "$(cat "$CLAUDE_MEMORY_PROJECTS_DIR/teststore/$EARLY.jsonl")"
check_contains "recovered anyway" "origin recovered 1" "$OUT"
git_store; run --provenance --apply >/dev/null
check_eq "stamped from the heredoc" "$EARLY" \
         "$(sed -n 's/^  originSessionId: //p' "$STORE/viabash.md")"

echo ""
echo "=== an arrow in prose is not a redirect ==="
# `-> name.md` in a memory body matches the shape of a shell redirect. Left
# unhandled it invents a writer for whichever memory a sentence happens to name.
reset_prov
mem_nostamp arrowed.md "body"
printf '{"timestamp":"2026-01-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo see %s/notes -> $M/arrowed.md"}}]}}\n' \
  "$STORE" > "$CLAUDE_MEMORY_PROJECTS_DIR/teststore/$EARLY.jsonl"
OUT=$(run --provenance)
check_contains "no writer invented" "still ANON 1"       "$OUT"
check_absent   "nothing recovered"  "origin recovered 1" "$OUT"

echo ""
echo "=== a --provenance dry run never writes ==="
reset_prov
mem_nostamp dry1.md "body"
mem_nostamp dry2.md "body"
tx_write "$EARLY" 2026-01-01T10:00:00.000Z dry1.md
tx_bash  "$EARLY" 2026-01-02T10:00:00.000Z dry2.md
BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
run --provenance >/dev/null 2>&1
AFTER=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
check_eq "store byte-identical after a dry run" "$BEFORE" "$AFTER"

echo ""
echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
