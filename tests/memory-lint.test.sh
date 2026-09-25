#!/usr/bin/env bash
# Tests for memory-lint.sh — builds a synthetic memory store in a temp dir.
# Hermetic: no real memory is read.
#
# Half of these assert SILENCE. A write-time hook that fires on healthy memories
# gets ignored, and then it is worse than no hook at all.
set -u
HOOK="hooks/memory-lint.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STORE="$TMP/projects/teststore/memory"
mkdir -p "$STORE"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }
check_eq()       { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }

lint() {  # lint <file> [tool]
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "${2:-Write}" "$1" \
    | bash "$HOOK" 2>&1
}
lint_rc() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | bash "$HOOK" >/dev/null 2>&1; echo $?
}

# A healthy memory, plus its index line.
write_mem() {  # write_mem <stem> <description> <body...>
  local stem="$1" desc="$2"; shift 2
  { echo "---"; echo "name: $stem"; echo "description: $desc"
    echo "metadata:"; echo "  type: reference"; echo "  modified: 2026-01-01"
    # Provenance is part of a healthy memory: without it nothing can tell a fact
    # that survived months from one a peer session appended minutes ago.
    echo "  originSessionId: 11111111-2222-3333-4444-555555555555"
    echo "---"; echo ""; printf '%s\n' "$@"; } > "$STORE/$stem.md"
  grep -q "($stem.md)" "$STORE/MEMORY.md" 2>/dev/null \
    || echo "- [T](
$stem.md) — hook" | tr -d '\n' >> "$STORE/MEMORY.md" && echo "" >> "$STORE/MEMORY.md"
}

echo "=== a healthy memory produces no findings at all ==="
: > "$STORE/MEMORY.md"
write_mem good "what this memory is about, stated as a retrieval cue" "body text"
OUT=$(lint "$STORE/good.md")
check_eq "silent"  ""  "$OUT"
check_eq "exit 0"  "0" "$(lint_rc "$STORE/good.md")"

echo ""
echo "=== files outside a memory store, and the index itself, are ignored ==="
echo "whatever" > "$TMP/notes.md"
check_eq "non-store file ignored" "0" "$(lint_rc "$TMP/notes.md")"
check_eq "MEMORY.md itself ignored" "0" "$(lint_rc "$STORE/MEMORY.md")"
check_eq "a Read is ignored" "" "$(lint "$STORE/good.md" Read)"

echo ""
echo "=== name: must equal the filename, because links resolve by filename ==="
: > "$STORE/MEMORY.md"
write_mem wrongname "a description" "body"
sed -i.bak 's/^name: wrongname/name: wrong-name/' "$STORE/wrongname.md" && rm -f "$STORE/wrongname.md.bak"
OUT=$(lint "$STORE/wrongname.md")
check_contains "flagged"          "does not match the filename" "$OUT"
check_contains "says why it matters" "silently breaks them"     "$OUT"

echo ""
echo "=== frontmatter completeness ==="
: > "$STORE/MEMORY.md"
printf -- '---\nname: bare\n---\nbody\n' > "$STORE/bare.md"
echo "- [T](bare.md) — hook" > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/bare.md")
check_contains "missing description" "no \`description:\`"     "$OUT"
check_contains "missing type"        "no \`metadata.type\`"    "$OUT"
check_contains "missing modified"    "no \`metadata.modified\`" "$OUT"

: > "$STORE/MEMORY.md"
write_mem badtype "a description" "body"
sed -i.bak 's/^  type: reference/  type: notes/' "$STORE/badtype.md" && rm -f "$STORE/badtype.md.bak"
check_contains "invalid type named" "is not one of user, feedback, project, reference" \
               "$(lint "$STORE/badtype.md")"

echo ""
echo "=== a description that carries changing state is a drift vector ==="
: > "$STORE/MEMORY.md"
write_mem statey "INS-1 fix; the PR is still open and unreviewed" "body"
check_contains "flagged" "asserts changing state" "$(lint "$STORE/statey.md")"

: > "$STORE/MEMORY.md"
write_mem cue "why the consumer runs on one core and what that costs" "body"
check_absent "a state-free cue is not flagged" "changing state" "$(lint "$STORE/cue.md")"

echo ""
echo "=== a liveness claim with no verify: block cannot ever be checked ==="
: > "$STORE/MEMORY.md"
write_mem inflight "what the change does" "The PR is not yet merged; deploy is blocked on review."
check_contains "flagged"        "no \`verify:\` block" "$(lint "$STORE/inflight.md")"

: > "$STORE/MEMORY.md"
write_mem withblock "what the change does" "verify:" "  - gh acme/api#1 open" \
                                           "The PR is not yet merged."
check_absent "silent once a block exists" "verify\` block" "$(lint "$STORE/withblock.md")"

: > "$STORE/MEMORY.md"
write_mem durable "a durable measured fact" "The consumer runs on one core. Measured."
check_absent "a durable fact needs no block" "verify" "$(lint "$STORE/durable.md")"

echo "=== describing review states is not a liveness claim ==="
# A bare "pending" was two thirds noise on a real corpus: memories describe
# GitHub's own states constantly. Only liveness constructions count.
: > "$STORE/MEMORY.md"
write_mem describes "a description" "MERGEABLE just means required checks are pending — the healthy state."
check_absent "descriptive use ignored" "verify\` block" "$(lint "$STORE/describes.md")"

: > "$STORE/MEMORY.md"
write_mem awaiting_review "a description" "Shipped, pending review: acme/api#1."
check_contains "a real construction still fires" "no \`verify:\` block" "$(lint "$STORE/awaiting_review.md")"

echo ""

echo ""
echo "=== links: a separator typo is a defect, a missing target is not ==="
: > "$STORE/MEMORY.md"
write_mem reference_tag_chain "the target" "body"
write_mem src "the source" "see [[reference_tag_chain]], [[reference-tag-chain]] and [[project_never_written]]"
OUT=$(lint "$STORE/src.md")
check_contains "hyphen typo flagged"    "[[reference-tag-chain]] does not resolve" "$OUT"
check_contains "names the right target" "[[reference_tag_chain]] does"             "$OUT"
check_absent   "forward reference is fine"  "project_never_written"        "$OUT"

echo ""
echo "=== a memory absent from the index will never be recalled ==="
: > "$STORE/MEMORY.md"
write_mem indexed "a description" "body"
cp "$STORE/indexed.md" "$STORE/orphan.md"
sed -i.bak 's/^name: indexed/name: orphan/' "$STORE/orphan.md" && rm -f "$STORE/orphan.md.bak"
check_contains "orphan flagged" "no line in MEMORY.md points at orphan.md" "$(lint "$STORE/orphan.md")"
check_absent   "indexed one is not" "no line in MEMORY.md"                 "$(lint "$STORE/indexed.md")"

echo ""
echo "=== the index LINE budget is counted in CHARACTERS, unlike the total ==="
# Two units, matching upstream: the index TOTAL is a byte size (the truncation
# warning states it in KB) while the per-entry budget upstream states is in
# characters. Em-dashes make the two differ, so this asserts the per-line check
# stays on characters -- counting its bytes would flag lines within budget.
: > "$STORE/MEMORY.md"
write_mem budget "a description" "body"
LONG=$(printf 'x%.0s' $(seq 1 130))

# A small index has enormous headroom, so a long hook there costs nothing.
echo "- [T](budget.md) — $LONG" > "$STORE/MEMORY.md"
check_absent "a roomy index is not nagged about line length" "per-line length" "$(lint "$STORE/budget.md")"

# Push the index over the pressure threshold; now per-line length is the only
# lever left on the total, so it is worth saying.
export MEMORY_INDEX_PRESSURE_CHARS=100
check_contains "over-budget line flagged under pressure" "per-line length is the only lever" "$(lint "$STORE/budget.md")"
check_contains "and quantifies the pressure"            "of ~25000"                        "$(lint "$STORE/budget.md")"

DASHES=$(printf '\xe2\x80\x94%.0s' $(seq 1 30))   # 30 em-dashes: 30 chars, 90 bytes
echo "- [T](budget.md) — $DASHES" > "$STORE/MEMORY.md"
check_absent "not flagged on byte count" "per-line length" "$(lint "$STORE/budget.md")"
# ${#var} counts bytes under a POSIX locale, which is what a container shell has.
check_absent "nor under a POSIX locale"  "per-line length" "$(LC_ALL=POSIX lint "$STORE/budget.md")"
unset MEMORY_INDEX_PRESSURE_CHARS

echo ""
echo "=== an index hook carrying changing state is the drift nothing else catches ==="
# The file and its hook never contradict each other from inside the store; the
# contradiction lives on GitHub. So this can only be caught at write time.
: > "$STORE/MEMORY.md"
write_mem drifty "a state-free description" "body"
echo "- [T](drifty.md) — 3 PRs open (#1 #2 #3)" > "$STORE/MEMORY.md"
check_contains "flagged" "index line asserts changing state" "$(lint "$STORE/drifty.md")"

echo "- [T](drifty.md) — why the cypher tail dominates the suite" > "$STORE/MEMORY.md"
check_absent "a retrieval cue is not flagged" "index line asserts changing state" "$(lint "$STORE/drifty.md")"

echo ""
echo "=== an entry filed under the wrong type marker defeats the ordering ==="
mk_index() {  # mk_index <marker-section-for-the-entry> <entry-file>
  { echo "<!-- ACTIVE WORK — kept at top so index truncation cannot drop it -->"
    echo "- [A](other.md) — hook"
    echo ""
    echo "<!-- FEEDBACK — how to work; these only function when loaded, so never in the tail -->"
    [ "$1" = FEEDBACK ] && echo "- [T]($2) — hook"
    echo ""
    echo "<!-- REFERENCE — durable facts; the index line is how the model learns they exist -->"
    [ "$1" = REFERENCE ] && echo "- [T]($2) — hook"
    echo ""
    echo "<!-- PROJECT — lifecycle-bound, newest first; the oldest tail is archive-eligible -->"
    [ "$1" = PROJECT ] && echo "- [T]($2) — hook"
    [ "$1" = ACTIVE ] && sed -i.bak "2a\\
- [T]($2) — hook" "$STORE/MEMORY.md" 2>/dev/null
  } > "$STORE/MEMORY.md"
}
: > "$STORE/MEMORY.md"
write_mem refmem "a description" "body"          # type: reference

mk_index PROJECT refmem.md
OUT=$(lint "$STORE/refmem.md")
check_contains "wrong section flagged"   "sits in the PROJECT section" "$OUT"
check_contains "names the actual type"   "type: reference"             "$OUT"
check_contains "says how to fix it"      "memory-index.sh"             "$OUT"

mk_index REFERENCE refmem.md
check_absent "right section is silent" "sits in the" "$(lint "$STORE/refmem.md")"

mk_index FEEDBACK refmem.md
check_contains "feedback section flagged too" "sits in the FEEDBACK section" "$(lint "$STORE/refmem.md")"

echo "=== an untyped memory is not reported twice for the same defect ==="
# memory-index files untyped entries under REFERENCE on purpose, so a merely
# malformed memory is not demoted into the truncated tail. Flagging the
# placement as well would have the two tools contradict each other.
printf -- '---\nname: untyped\ndescription: d\nmetadata:\n  modified: 2026-01-01\n---\nbody\n' > "$STORE/untyped.md"
{ echo "<!-- REFERENCE — durable facts; the index line is how the model learns they exist -->"
  echo "- [T](untyped.md) — hook"; } > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/untyped.md")
check_contains "the missing type is reported" "no \`metadata.type\`" "$OUT"
check_absent   "the placement is not"         "sits in the"          "$OUT"

echo ""

echo ""
echo "=== the hand-curated ACTIVE block accepts any type ==="
{ echo "<!-- ACTIVE WORK — kept at top so index truncation cannot drop it -->"
  echo "- [T](refmem.md) — hook"; } > "$STORE/MEMORY.md"
check_absent "no placement complaint in ACTIVE" "sits in the" "$(lint "$STORE/refmem.md")"

echo ""
echo "=== an index with no section markers yet is not nagged about placement ==="
echo "- [T](refmem.md) — hook" > "$STORE/MEMORY.md"
check_absent "silent on an unsorted index" "sits in the" "$(lint "$STORE/refmem.md")"

echo ""
echo "=== the hook never edits and never blocks a write ==="
: > "$STORE/MEMORY.md"
write_mem untouched "a description" "The PR is not yet merged."
SUM_BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
lint "$STORE/untouched.md" >/dev/null 2>&1
SUM_AFTER=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
check_eq "store byte-identical" "$SUM_BEFORE" "$SUM_AFTER"
check_eq "exit 2 is advice, not a block" "2" "$(lint_rc "$STORE/untouched.md")"

echo ""
echo ""
echo "=== the INDEX itself is checked on write, not skipped ==="
# MEMORY.md used to exit unchecked. Every memory write appends to the index and
# nothing looked at the index on write, so tier order decayed until feedback_
# entries sat past the truncation cut and stopped loading entirely.
: > "$STORE/MEMORY.md"
write_mem idx_a "a description" "body"
OUT=$(lint "$STORE/MEMORY.md")
check_eq "a healthy index is silent" "" "$OUT"
check_eq "and exits 0"               "0" "$(lint_rc "$STORE/MEMORY.md")"

# A feedback_ entry past line 200 is the harm: it is not loaded, and feedback_
# only works when loaded. Build an index whose tail holds one.
{ i=0; while [ "$i" -lt 205 ]; do echo "- [T](reference_pad_$i.md) — hook"; i=$((i+1)); done
  echo "- [T](feedback_stranded.md) — hook"; } > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/MEMORY.md")
check_contains "a feedback_ entry past the cut is flagged" "past line 200" "$OUT"
check_contains "says it will not load"                     "will not load"  "$OUT"
check_contains "over-length index is flagged"              "over the 200-line limit" "$OUT"
check_eq       "and exits 2"                               "2" "$(lint_rc "$STORE/MEMORY.md")"

# The cut is a setting shared with memory-verify, not a constant baked into the
# message. If it were hardcoded, the two tools could disagree about where the
# tail begins and each would still look self-consistent.
OUT=$(MEMORY_INDEX_MAX_LINES=50 lint "$STORE/MEMORY.md")
check_contains "the cut follows the configured limit" "past line 50" "$OUT"
check_absent   "and is not hardcoded at 200"          "past line 200" "$OUT"

# A stray line stops being an entry, so the memory silently leaves the index.
{ echo "<!-- FEEDBACK -->"
  echo "- [T](reference_ok.md) — hook"
  echo "grep -c . MEMORY.md; tail -2 MEMORY.md- [T](feedback_fused.md) — hook"; } > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/MEMORY.md")
check_contains "a fused line is flagged"     "neither an entry nor a tier marker" "$OUT"
check_contains "names the likely cause"      "no trailing newline" "$OUT"
check_absent   "a tier marker is not a stray" "2 line(s) are neither" "$OUT"

# Size is measured in BYTES. Em-dashes are multi-byte, so a character count can
# read as compliant while the byte count is over and the tail is truncated.
DASHY=$(printf -- '— %.0s' $(seq 1 400))
{ echo "- [T](reference_ok.md) — $DASHY"; } > "$STORE/MEMORY.md"
OUT=$(MEMORY_INDEX_MAX_CHARS=500 lint "$STORE/MEMORY.md")
check_contains "over-size index reports BYTES" "bytes" "$OUT"

# The archive index is not the loaded index and has no such limits.
echo "- [T](x.md) — hook" > "$STORE/MEMORY_ARCHIVE.md"
check_eq "MEMORY_ARCHIVE.md is ignored" "0" "$(lint_rc "$STORE/MEMORY_ARCHIVE.md")"

echo ""
echo "=== a new feedback memory is pointed at the store's principle hubs ==="
# Only fires where hubs already exist and only on a memory that has no index
# line yet: that is the moment a line gets spent, and the only moment the
# question is live. Half the value here is the SILENCE cases below.
: > "$STORE/MEMORY.md"
mkmem() {  # mkmem <stem> <type>
  { echo "---"; echo "name: $1"; echo "description: what this is about"
    echo "metadata:"; echo "  type: $2"; echo "  modified: 2026-01-01"
    echo "  originSessionId: 11111111-2222-3333-4444-555555555555"
    echo "---"; echo ""; echo "body"; } > "$STORE/$1.md"
}
mkmem feedback_hub_result_describes_lookup feedback
mkmem feedback_hub_test_cannot_fail        feedback
mkmem feedback_new_lesson                  feedback
OUT=$(lint "$STORE/feedback_new_lesson.md")
check_contains "hub advice given"      "principle hubs"                          "$OUT"
check_contains "names a real hub"      "[[feedback_hub_result_describes_lookup]]" "$OUT"
check_contains "names the other hub"   "[[feedback_hub_test_cannot_fail]]"        "$OUT"
check_contains "says where the line goes" "MEMORY_ARCHIVE.md"                     "$OUT"
check_absent   "not the generic advice" "Add one, in the section for its type"    "$OUT"

echo ""
echo "=== the hub itself, other types, and indexed memories are left alone ==="
OUT=$(lint "$STORE/feedback_hub_test_cannot_fail.md")
check_absent   "a hub is not told to join a hub" "principle hubs"                  "$OUT"
check_contains "a hub still needs its own line"  "Add one, in the section"         "$OUT"

mkmem reference_fact reference
OUT=$(lint "$STORE/reference_fact.md")
check_absent   "reference gets no hub advice"    "principle hubs"                  "$OUT"
check_contains "reference gets generic advice"   "Add one, in the section"         "$OUT"

# An already-indexed feedback memory is not a budget decision — editing one must
# not re-open the question, or the hook becomes noise on every edit.
echo "- [T](feedback_new_lesson.md) — hook" > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/feedback_new_lesson.md")
check_absent   "indexed memory is silent"        "principle hubs"                  "$OUT"

echo ""
echo "=== a memory a hub already carries is left alone ==="
# Its missing index line is the intended state. Firing here would tax every
# future edit to every hubbed lesson — the failure this hook exists to avoid.
mkmem feedback_hub_result_describes_lookup feedback
mkmem feedback_hub_test_cannot_fail        feedback
mkmem feedback_carried                     feedback
echo "- [[feedback_carried]] — what it was" >> "$STORE/feedback_hub_test_cannot_fail.md"
echo "- [T](feedback_carried.md) — hook" > "$STORE/MEMORY_ARCHIVE.md"
: > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/feedback_carried.md")
check_absent "hubbed memory gets no hub advice"  "principle hubs"          "$OUT"
check_absent "hubbed memory not told to index"   "Add one, in the section" "$OUT"
check_eq     "silent"  ""  "$OUT"

# The archived line is the restore path; a hub bullet without one strands it.
: > "$STORE/MEMORY_ARCHIVE.md"
OUT=$(lint "$STORE/feedback_carried.md")
check_contains "missing archive line flagged" "restore path"                        "$OUT"
check_contains "names the hub that carries it" "[[feedback_hub_test_cannot_fail]]"  "$OUT"

echo ""
echo "=== a store with no hubs never mentions them ==="
rm -f "$STORE"/feedback_hub_*.md
: > "$STORE/MEMORY.md"
mkmem feedback_another feedback
OUT=$(lint "$STORE/feedback_another.md")
check_absent   "no hubs, no hub advice"          "principle hubs"                  "$OUT"
check_contains "falls back to generic advice"    "Add one, in the section"         "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
