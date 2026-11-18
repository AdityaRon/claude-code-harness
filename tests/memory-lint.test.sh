#!/usr/bin/env bash
# Tests for memory-lint.sh — builds a synthetic memory store in a temp dir.
# Hermetic: no real memory is read.
#
# Half of these assert SILENCE. A write-time hook that fires on healthy memories
# gets ignored, and then it is worse than no hook at all.
set -u
HOOK="${CCH_MEMORY_LINT_SH:-hooks/memory-lint.sh}"   # a mutation run points this at a changed copy
PASS=0; FAIL=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STORE="$TMP/projects/teststore/memory"
mkdir -p "$STORE"

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
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
# Claude Code stamps `modified` itself on every memory write (2.1.214), so
# flagging its absence here would be a second report of the CLI's own field.
check_absent   "modified is the CLI's" "metadata.modified"      "$OUT"

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
check_contains "says how to fix it, installed path and this store" "bash ~/.claude/memory-index.sh --store teststore --write" "$OUT"

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
check_contains "names the fix: installed path, this store" \
  "Run \`bash ~/.claude/memory-index.sh --store teststore --write\` to restore tier order" "$OUT"
# The size itself is the CLI's finding: since 2.1.210 a write that leaves the
# index over its limit gets an error from Claude Code, so saying it twice is noise.
check_absent   "the over-limit size is not repeated"       "over the 200-line limit" "$OUT"
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

# An index that is merely over its byte limit, with nothing stranded past the
# cut, is the CLI's finding to make (it errors on that write), not this hook's.
DASHY=$(printf -- '— %.0s' $(seq 1 400))
{ echo "- [T](reference_ok.md) — $DASHY"; } > "$STORE/MEMORY.md"
check_eq "size alone is left to the CLI" "0" "$(MEMORY_INDEX_MAX_CHARS=500 lint_rc "$STORE/MEMORY.md")"

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
echo ""
echo "=== a memory without originSessionId is stamped, not flagged ==="
: > "$STORE/MEMORY.md"
printf -- '---\nname: unstamped\ndescription: a cue\nmetadata:\n  type: reference\n  modified: 2026-01-01\n---\n\nbody\n' > "$STORE/unstamped.md"
echo "- [T](unstamped.md) — hook" > "$STORE/MEMORY.md"
OUT=$(printf '{"tool_name":"Write","session_id":"abcd-1234","tool_input":{"file_path":"%s"}}' "$STORE/unstamped.md" | bash "$HOOK" 2>&1)
check_absent  "no finding for it"            "originSessionId" "$OUT"
check_contains "the field is written"        "  originSessionId: abcd-1234" "$(cat "$STORE/unstamped.md")"
check_eq      "under metadata, once"         "1" "$(grep -c originSessionId "$STORE/unstamped.md")"
check_contains "the body is untouched"       "body" "$(tail -1 "$STORE/unstamped.md")"

echo ""
echo "=== index findings reach the model (stderr) ==="
: > "$STORE/MEMORY.md"
printf 'not an entry line\n' >> "$STORE/MEMORY.md"
ERR=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$STORE/MEMORY.md" | bash "$HOOK" 2>&1 >/dev/null)
check_contains "on stderr" "neither an entry nor a tier marker" "$ERR"

echo ""
echo "=== verify: none <reason> in the frontmatter stands in for a verify: block ==="
wmem() {  # wmem <stem> <frontmatter line> <body>
  { echo "---"; echo "name: $1"; echo "description: what this is about"; echo "$2"
    echo "metadata:"; echo "  type: project"; echo "  originSessionId: 11111111-2222-3333-4444-555555555555"
    echo "---"; echo ""; echo "$3"; } > "$STORE/$1.md"
  echo "- [T]($1.md) — hook" > "$STORE/MEMORY.md"
}
wmem waived "verify: none a weekly rota, not one ticket" "The rota is awaiting a volunteer each week."
check_eq "a reason: silent" "" "$(lint "$STORE/waived.md")"
wmem waived "  verify: none indented under the frontmatter's keys" "The rota is awaiting a volunteer each week."
check_eq "indented: silent too" "" "$(lint "$STORE/waived.md")"
wmem waived "verify: none" "The rota is awaiting a volunteer each week."
OUT=$(lint "$STORE/waived.md")
check_contains "no reason: flagged"        "gives no reason" "$OUT"
wmem waived "  verify: none" "The rota is awaiting a volunteer each week."
OUT=$(lint "$STORE/waived.md")
check_contains "no reason, indented: flagged" "gives no reason" "$OUT"
check_contains "and the claim still needs a block" "no \`verify:\` block" "$OUT"
{ echo "---"; echo "name: waived"; echo "description: d"; echo "metadata:"; echo "  type: project"
  echo "  originSessionId: 11111111-2222-3333-4444-555555555555"; echo "---"
  echo "  verify: none in the body is not the frontmatter"; echo "The rota is awaiting a volunteer."; } > "$STORE/waived.md"
check_contains "outside the frontmatter: no waiver" "no \`verify:\` block" "$(lint "$STORE/waived.md")"

echo ""
echo "=== an archived project or reference memory is not called unindexed ==="
: > "$STORE/MEMORY.md"; rm -f "$STORE"/feedback_hub_*.md
mkmem project_done project; mkmem reference_old reference; mkmem feedback_alone feedback; mkmem user_pref user
printf '%s\n' "# archive" "- [T](project_done.md) — hook" "- [T](reference_old.md) — hook" \
  "- [T](feedback_alone.md) — hook" "- [T](user_pref.md) — hook" > "$STORE/MEMORY_ARCHIVE.md"
check_eq "project: silent"   "" "$(lint "$STORE/project_done.md")"
check_eq "reference: silent" "" "$(lint "$STORE/reference_old.md")"
OUT=$(lint "$STORE/feedback_alone.md")
check_contains "feedback alone in the archive is still a finding" "never archived on its own" "$OUT"
check_contains "and says what to do"                             "Move the line back into MEMORY.md" "$OUT"
check_absent   "not the old wording"                             "will never be recalled" "$OUT"
check_contains "a user memory is a rule too" "never archived on its own" "$(lint "$STORE/user_pref.md")"
mkmem feedback_hub_b feedback
OUT=$(lint "$STORE/feedback_alone.md")
check_contains "with hubs, names them"       "[[feedback_hub_b]]" "$OUT"
check_absent   "and not the new-memory advice" "do NOT add a MEMORY.md line" "$OUT"
rm -f "$STORE/MEMORY_ARCHIVE.md"
check_contains "no archive line: the old finding stands" "no line in MEMORY.md points at project_done.md" "$(lint "$STORE/project_done.md")"

echo ""
echo "=== a handoff tracker: the shape, size, STATE stamp and crons ==="
TRK="$TMP/trackers"; mkdir -p "$TRK"
tracker() {  # FILE STAMP CRONS_BLOCK [EXTRA_SECTION]
  { printf '# t\n\nSTATE: %s\n\n## Scope\nx\n\n## Open\nx\n\n## Owed\nx\n\n## Settled\nx\n\n## Next on restart\n%s\n' "$2" "$3"
    [ -n "${4:-}" ] && printf '%s\n' "$4"; } > "$1"
}
NOWS=$(date -u +%Y-%m-%dT%H:%MZ)
CR=$'Crons:\n- */30 9-17 * * 1-5 check the PR queue\n- 0 8 * * * morning re-gate'
tracker "$TRK/good.md" "$NOWS" "$CR"
check_eq "a well-formed tracker: silent, exit 0" "0" "$(lint_rc "$TRK/good.md")"
tracker "$TRK/none.md" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "Crons: none"
check_eq "Crons: none and a stamp with seconds: silent" "0" "$(lint_rc "$TRK/none.md")"
tracker "$TRK/twice.md" "$NOWS" "$CR" $'\n## Scope\ny'
check_contains "a second Scope: appended, not replaced" "once each, in that order" "$(lint "$TRK/twice.md")"
tracker "$TRK/order.md" "$NOWS" "$CR"; sed -i.bak 's/^## Owed$/## Debts/' "$TRK/order.md"
check_contains "a renamed heading" "Scope|Open|Debts|Settled|Next on restart" "$(lint "$TRK/order.md")"
tracker "$TRK/big.md" "$NOWS" "$CR" "$(head -c 6000 /dev/zero | tr '\0' x)"
check_contains "past 5,000 bytes" "past 5000" "$(lint "$TRK/big.md")"
check_eq "TRACKER_MAX_BYTES raises it" "" "$(TRACKER_MAX_BYTES=9000 lint "$TRK/big.md" | grep 'past ')"
tracker "$TRK/ahead.md" "$(date -u -r $(( $(date +%s) + 720 )) +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d @$(( $(date +%s) + 720 )) +%Y-%m-%dT%H:%MZ)" "$CR"
check_contains "a stamp 12 min ahead of the clock" "min ahead of the clock" "$(lint "$TRK/ahead.md")"
tracker "$TRK/old.md" "2026-01-01T00:00Z" "$CR"
check_contains "an old stamp" "min old, older than this write" "$(lint "$TRK/old.md")"
tracker "$TRK/bad.md" "yesterday afternoon" "$CR"
check_contains "a stamp that is not UTC ISO" "is not a UTC time" "$(lint "$TRK/bad.md")"
{ printf '## Scope\n## Open\n## Owed\n## Settled\n## Next on restart\nCrons: none\n'; } > "$TRK/nostamp.md"
check_contains "no STATE line" "no \`STATE:\` line" "$(lint "$TRK/nostamp.md")"
tracker "$TRK/nocron.md" "$NOWS" "next: merge"
check_contains "no Crons line" "no \`Crons:\` line" "$(lint "$TRK/nocron.md")"
tracker "$TRK/prose.md" "$NOWS" $'Crons:\n- every half hour, check the queue'
check_contains "a cron in prose, not five fields" "without five fields and a prompt" "$(lint "$TRK/prose.md")"
tracker "$TRK/inline.md" "$NOWS" "Crons: every morning"
check_contains "Crons: with prose on its own line" "takes \`none\` or entries" "$(lint "$TRK/inline.md")"
tracker "$TRK/noprompt.md" "$NOWS" $'Crons:\n- 0 8 * * *'
check_contains "a cron with no prompt" "without five fields and a prompt" "$(lint "$TRK/noprompt.md")"
tracker "$TRK/noneplus.md" "$NOWS" $'Crons: none\n- 0 8 * * * morning re-gate'
check_contains "Crons: none with an entry under it" "\`Crons: none\` with entries under it" "$(lint "$TRK/noneplus.md")"
check_eq "a tracker finding exits 2 (handed to the model)" "2" "$(lint_rc "$TRK/nocron.md")"
mkdir -p "$TMP/notes"; cp "$TRK/nocron.md" "$TMP/notes/nocron.md"
check_eq "the same file outside trackers/: not checked" "0" "$(lint_rc "$TMP/notes/nocron.md")"

echo ""
echo "=== trackers/: an archive, a ledger, and the ledgers beside a handoff ==="
# Each case has its own trackers/ folder: a big file beside the handoffs above
# would add a finding to every one of them.
pad() { head -c "$2" /dev/zero | tr '\0' y > "$1"; }   # pad FILE BYTES: one shapeless line
L1="$TMP/l1/trackers"; mkdir -p "$L1"
pad "$L1/work-archive.md" 30000
check_eq "an archive Edit: silent, exit 0" "0" "$(lint_rc "$L1/work-archive.md")"
check_eq "and no output" "" "$(lint "$L1/work-archive.md" Edit)"
pad "$L1/work.md" 8000
check_eq "a pruned ledger under 20 KB with its archive beside it: silent" "" "$(lint "$L1/work.md" Edit)"

L2="$TMP/l2/trackers"; mkdir -p "$L2"
tracker "$L2/grown.md" "$NOWS" "$CR" "$(head -c 25000 /dev/zero | tr '\0' x)"
check_eq "a handoff grown past 20 KB is a ledger: its own edit is silent, exit 0" "0" "$(lint_rc "$L2/grown.md" 2>/dev/null)"
check_eq "and prints nothing" "" "$(lint "$L2/grown.md")"
check_contains "TRACKER_LEDGER_BYTES moves the line: then it is a handoff again" "past 5000" "$(TRACKER_LEDGER_BYTES=30000 lint "$L2/grown.md")"
L2B="$TMP/l2b/trackers"; mkdir -p "$L2B"
pad "$L2B/shapeless.md" 6000
check_eq "a 6 KB file with no STATE: and no Next on restart is not a handoff: silent" "0" "$(lint_rc "$L2B/shapeless.md")"
{ printf '# Open items\n\n## Open\n'; for i in $(seq 1 1500); do printf '| OI-%d | thing %d | open |\n' "$i" "$i"; done; printf '## Settled\nx\n'; } > "$L2B/open-items.md"
check_eq "a 113 KB-class open-items tracker with ## Open and ## Settled: silent" "" "$(lint "$L2B/open-items.md" Edit)"
printf '# Report\n\n## Open\nfindings\n' > "$L2B/report.md"
check_eq "a small report with an ## Open heading: silent" "0" "$(lint_rc "$L2B/report.md")"
printf '## Scope\nx\n## Next on restart\nx\n' > "$L2B/marked.md"
OUT=$(lint "$L2B/marked.md")
check_contains "a ## Next on restart heading marks a handoff" "no \`STATE:\` line" "$OUT"
check_contains "and its other findings stand" "once each, in that order" "$OUT"
printf 'STATE: %s\n## Scope\nx\n' "$NOWS" > "$L2B/stated.md"
check_contains "a STATE: line marks a handoff" "no \`Crons:\` line" "$(lint "$L2B/stated.md")"
check_eq "CLAUDE_TRACKER_LINT=off: a handoff with findings is silent" "0" "$(CLAUDE_TRACKER_LINT=off lint_rc "$L2B/marked.md")"
pad "$L2B/big-stated.md" 6000; printf '\nSTATE: %s\n' "$NOWS" >> "$L2B/big-stated.md"
check_contains "a handoff past 5000: move, never delete" "never delete what has no other copy" "$(lint "$L2B/big-stated.md")"

L3="$TMP/l3/trackers"; mkdir -p "$L3"
tracker "$L3/handoff.md" "$NOWS" "$CR"
check_eq "a handoff with no big sibling: silent" "" "$(lint "$L3/handoff.md")"
pad "$L3/log.md" 26000
pad "$L3/log-archive.md" 40000
OUT=$(lint "$L3/handoff.md")
check_contains "a big sibling: named, with its size" "ledger log.md beside this handoff is 26000 bytes" "$OUT"
check_contains "and the prune command for it" "tracker-prune.py '$L3/log.md'" "$OUT"
check_absent "an archive is not a big sibling" "log-archive.md" "$OUT"
check_eq "exit 2" "2" "$(lint_rc "$L3/handoff.md")"
check_eq "TRACKER_LEDGER_BYTES moves the find too" "" "$(TRACKER_LEDGER_BYTES=50000 lint "$L3/handoff.md")"
mkdir -p "$TMP/l3/elsewhere"; mv "$L3/log.md" "$TMP/l3/elsewhere/log.md"; ln -s "$TMP/l3/elsewhere/log.md" "$L3/log.md"
check_contains "a linked ledger is measured at its target" "log.md beside this handoff is 26000 bytes" "$(lint "$L3/handoff.md")"

echo ""
echo "=== a handoff line that sends a session to read a ledger whole ==="
L4="$TMP/l4/trackers"; mkdir -p "$L4"
pad "$L4/tracker.md" 21000
printf 'small\n' > "$L4/work-tracker.md"
rf() {  # rf LINE...: lint a handoff that ends in these lines, from line 21
  tracker "$L4/h.md" "$NOWS" "$CR" "$(printf '%s\n' "$@")"
  lint "$L4/h.md"
}
fires()  { check_contains "fires: $1" "tells a session to read tracker.md (21000 bytes) first" "$(rf "$1")"; }
silent() { check_absent   "silent: $1" "tells a session to read" "$(rf "$1")"; }
fires  "Read tracker.md first."
fires  "Before anything else, reread \`tracker.md\`."
fires  "Start by reading [the log](tracker.md)."
fires  "On restart, read ~/notes/trackers/tracker.md"
fires  "Read the large tracker.md first"
silent "Do not read tracker.md whole."
silent "Already read: tracker.md lines 40-90."
silent "T-9 in tracker.md was read before the restart."
silent "Read tracker.md first, by grep -n on the id."
silent "Before anything, read tracker.md by slice."
silent "Read work-tracker.md first."
silent "Read tracker.md.bak first."
silent "Open tracker.md first."
silent "See the thread on tracker.md before Friday."
OUT=$(rf "Read tracker.md first." "Read tracker.md first, again." "Start: read tracker.md" \
         "Read tracker.md before lunch." "Read tracker.md first, really.")
check_eq "at most three lines named" "3" "$(printf '%s\n' "$OUT" | grep -c 'tells a session to read')"
check_contains "the rest counted" "and 2 more like that" "$OUT"
check_contains "by line number" "line 21 tells" "$OUT"

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
