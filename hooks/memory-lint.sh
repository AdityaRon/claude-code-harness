#!/usr/bin/env bash
# Checks a memory the moment it is written, instead of months later in an audit.
#
# Every defect the memory audit finds is cheap to fix at write time and
# expensive afterwards. A `name:` that disagrees with its filename silently
# breaks every wiki-link pointing at it. A description carrying volatile state
# ("3 PRs open") is wrong within days and nothing detects it, because the
# contradiction lives on GitHub rather than in the file. A claim about work
# still in flight, with no `verify:` block, can never be checked at all.
#
# Without this hook, memory-fix.sh and the audit skill are a cleanup that gets
# repeated forever: a corpus of 218 memories accumulated 64 name mismatches, 26
# broken links and 88 missing timestamps, and a memory written by the live
# system DURING the session that fixed all of them arrived with no timestamp and
# a 176-character index hook.
#
# Advisory by design. This is a PostToolUse hook, so the write has already
# happened; the findings go back to the model while the context is still hot and
# the fix costs one edit. It never blocks and never edits.
source "$(dirname "$0")/lib.sh"

read_input
command -v jq &>/dev/null || exit 0     # advisory only; never fail a write
TOOL=$(jq_get '.tool_name')

case "$TOOL" in
  Write|Edit|MultiEdit) FILE=$(jq_get '.tool_input.file_path') ;;
  *) exit 0 ;;
esac

[ -n "$FILE" ] || exit 0
case "$FILE" in
  */memory/*.md) ;;
  *) exit 0 ;;
esac
BASE=$(basename "$FILE")
[ -f "$FILE" ] || exit 0

INDEX_LINE_MAX="${MEMORY_INDEX_LINE_MAX:-110}"
# The same limits memory-verify reports OVERSIZE against. Measured in BYTES:
# wc -c counts bytes, and the upstream limit is 25KB, not 25,000 characters. The
# distinction is not academic here -- em-dashes and arrows are multi-byte, so a
# real index runs ~2% larger in bytes than in characters, which is enough to sit
# inside the limit on one measure and outside it on the other. These names say
# BYTES so nobody reads a passing character count as compliance.
# The env var names keep their historical _CHARS spelling so existing overrides
# and tests keep working; the values they carry are and always were bytes.
INDEX_MAX_BYTES="${MEMORY_INDEX_MAX_CHARS:-25000}"
INDEX_PRESSURE_BYTES="${MEMORY_INDEX_PRESSURE_CHARS:-20000}"
INDEX_PRESSURE_LINES="${MEMORY_INDEX_PRESSURE_LINES:-180}"
INDEX_MAX_LINES="${MEMORY_INDEX_MAX_LINES:-200}"   # same name memory-verify reads

# ---- the index itself ---------------------------------------------------
# MEMORY.md used to exit here unchecked, and that is why tier ordering decayed:
# every memory write appends to the index, nothing ever looked at the index on
# write, and feedback_ entries drifted below the truncation cut where they stop
# being loaded at all. Measured on a live store: ordering went from clean to two
# feedback_ entries past the cut in under two hours.
#
# The per-memory checks below do not apply to an index, so this is its own pass.
if [ "$BASE" = "MEMORY.md" ]; then
  IBYTES=$(wc -c < "$FILE" | tr -d ' ')
  ILINES=$(wc -l < "$FILE" | tr -d ' ')
  IFIND=""
  iadd() { IFIND="${IFIND}  - $1
"; }

  [ "$IBYTES" -gt "$INDEX_MAX_BYTES" ] \
    && iadd "index is ${IBYTES} bytes, over the ~${INDEX_MAX_BYTES} limit — everything past it is dropped at session start. Shorten hooks; that is the only lever on bytes that does not cost an entry."
  [ "$ILINES" -gt "$INDEX_MAX_LINES" ] \
    && iadd "index is ${ILINES} lines, over the ${INDEX_MAX_LINES}-line limit. One line per memory, so only fewer entries fixes this — archive settled project_ memories, never feedback_."

  # The harm is never the limit, it is WHICH entries fall past it. A tail of
  # settled project_ entries is the designed sacrifice; a feedback_ entry there
  # is silently not loaded, and feedback_ only works when loaded.
  BELOW=$(grep -n '^- \[' "$FILE" 2>/dev/null | awk -F: -v cut="$INDEX_MAX_LINES" '$1>cut' | grep -c 'feedback_' || true)
  [ "${BELOW:-0}" -gt 0 ] \
    && iadd "${BELOW} feedback_ memor$([ "$BELOW" = 1 ] && echo y || echo ies) sit past line ${INDEX_MAX_LINES} and will not load. Re-run \`memory-index.sh --write\` to restore tier order, or move them up by hand."

  # A line that is neither an entry nor a tier marker is usually an append with
  # no trailing newline that collided with the next line. It stops being an
  # entry, so the memory silently leaves the index -- and a reorder would drop
  # it outright.
  STRAY=$(awk 'NF && $0 !~ /^- \[/ && $0 !~ /^<!--/' "$FILE" 2>/dev/null | wc -l | tr -d ' ')
  [ "${STRAY:-0}" -gt 0 ] \
    && iadd "${STRAY} line(s) are neither an entry nor a tier marker — likely an append with no trailing newline fused to the next line. Repair before reordering, or the entry is discarded."

  if [ -n "$IFIND" ]; then
    printf 'memory-lint on %s:\n%s\n' "$BASE" "$IFIND"
    printf 'The index is what tells the model a memory exists. Fix these now.\n'
    exit 2
  fi
  exit 0
fi
case "$BASE" in
  MEMORY_ARCHIVE.md|ARCHIVE.md) exit 0 ;;
esac

DIR=$(dirname "$FILE")

# Volatile state in a SUMMARY - the description or the index hook. Wider than
# OPEN_RE, because a summary saying "in progress" or "unreviewed" is a status
# even when the body is not asserting in-flight work. Kept free of a bare
# "pending" for the same reason OPEN_RE is: memories describe review states
# constantly, and a check that cries wolf is one nobody reads.
STATE_RE='\b(still open|now open|in progress|unreviewed|[0-9]+ prs? open|awaiting|blocked on|not yet (merged|landed|deployed)|pending (review|merge|approval|deploy|release|sign-?off)|(is|still) pending)\b'
STEM="${BASE%.md}"
FINDINGS=""
add() { FINDINGS="${FINDINGS}  - $1
"; }

# --- identity -------------------------------------------------------------
NAME=$(sed -n '1,20p' "$FILE" | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d '"'"'"'' | sed 's/[[:space:]]*$//')
if [ -z "$NAME" ]; then
  add "no \`name:\` in the frontmatter"
elif [ "$NAME" != "$STEM" ]; then
  add "\`name: $NAME\` does not match the filename \`$STEM\`. Every [[$STEM]] link resolves by filename, so this silently breaks them — set name to the stem."
fi

# --- type -----------------------------------------------------------------
TYPE=$(sed -n 's/^[[:space:]]*type:[[:space:]]*//p' "$FILE" | head -1)
case "$TYPE" in
  user|feedback|project|reference) ;;
  "") add "no \`metadata.type\`. One of: user, feedback, project, reference." ;;
  *)  add "\`metadata.type: $TYPE\` is not one of user, feedback, project, reference." ;;
esac

# --- timestamp ------------------------------------------------------------
grep -q '^[[:space:]]*modified:' "$FILE" \
  || add "no \`metadata.modified\`. Without it, age falls back to file mtime, which any tool touching the file resets."

# Provenance. A memory records what is believed, never who came to believe it, so
# an unattributed file is a claim with no origin: a paragraph a peer session
# appended twenty minutes ago is textually identical to one that has survived
# months of contact. That is not a staleness problem -- the memory may never have
# been independently established at all -- and it lets a session cite a memory as
# corroboration for the very finding that wrote it.
#
# Claude Code stamps originSessionId on memories it writes itself; one written
# straight through the Write tool gets whatever frontmatter the author chose, so
# this is where that gap closes. The hook knows the writing session, so report the
# value rather than the absence: naming the field costs an edit and a guess,
# supplying it costs an edit.
if ! grep -q 'originSessionId:' "$FILE"; then
  SID=$(jq_get '.session_id')
  if [ -n "$SID" ]; then
    add "no \`metadata.originSessionId\`. Add \`originSessionId: $SID\` so this memory can be attributed later — without it nothing can tell a fact that survived months from one appended minutes ago."
  else
    add "no \`metadata.originSessionId\`, and this hook could not read its own session id. Add the writing session's id by hand."
  fi
fi

# --- description ----------------------------------------------------------
# The description becomes the index hook, and the index is the only thing loaded
# into every session. Volatile state in a hook is the drift that no checker can
# catch: the file says merged, the hook still says open, and nothing disagrees
# with itself inside the file.
DESC=$(sed -n 's/^description:[[:space:]]*//p' "$FILE" | head -1 | tr -d '"')
if [ -z "$DESC" ]; then
  add "no \`description:\`. It becomes the index hook, so the memory is unfindable without it."
else
  # No length check here on purpose. The description is the fuller summary and
  # runs long by convention (median 167 chars in a real store); it is the INDEX
  # LINE that gets clipped, and that is checked below.
  if printf '%s' "$DESC" | grep -qiE "$STATE_RE"; then
    add "the description asserts changing state. A hook is a retrieval cue, not a status: say what the memory is ABOUT and keep the state in the body next to a \`verify:\` block."
  fi
fi

# --- unverifiable liveness claims ----------------------------------------
# A bare "pending" was in this list and was two thirds noise: memories describe
# GitHub's own states constantly ("required checks are pending - that is the
# healthy state", "a required check is missing, pending, or failed"). A finding
# that cries wolf gets ignored, so only liveness CONSTRUCTIONS count now.
OPEN_RE='\b(pending (review|merge|approval|deploy|release|sign-?off)|(is|still) pending|draft pr|awaiting|not yet (merged|deployed|landed|shipped)|blocked on|still open|will land)\b'
if grep -qiE "$OPEN_RE" "$FILE" && ! grep -q '^verify:' "$FILE"; then
  add "asserts work still in flight but carries no \`verify:\` block, so nothing can ever check it. Add one, e.g. \`  - gh owner/repo#123 open\` or \`  - jira PROJ-1 In Progress\`."
fi

# --- links that were MEANT to resolve ------------------------------------
# A link to a memory that does not exist is legitimate — it marks something
# worth writing. A link whose only problem is separator style is a typo.
# Read loop rather than `for t in $(...)`: word splitting on an unquoted
# expansion is a shell-dependent behaviour, and getting it wrong here fails
# open, silently.
while IFS= read -r t; do
  [ -z "$t" ] && continue
  [ -f "$DIR/$t.md" ] && continue
  alt=$(printf '%s' "$t" | tr '-' '_')
  [ "$alt" != "$t" ] && [ -f "$DIR/$alt.md" ] \
    && add "[[$t]] does not resolve, but [[$alt]] does — underscores, not hyphens."
done <<EOF
$(grep -oh '\[\[[^]]*\]\]' "$FILE" 2>/dev/null | sed 's/\[\[//; s/\]\]//' | grep -v '^:.*:$' | sort -u)
EOF

# --- indexed? -------------------------------------------------------------
if [ -f "$DIR/MEMORY.md" ]; then
  IDX=$(grep -m1 "($BASE)" "$DIR/MEMORY.md")
  if [ -z "$IDX" ]; then
    # A NEW `feedback_` memory is the moment an index line gets spent, so it is
    # the only moment worth asking whether it should be. The index is capped at
    # one line per memory; `feedback_` is the one type the archiving tool never
    # peels, so every incident that mints its own named lesson permanently costs
    # a line. Measured on a live store: feedback held 138 of 185 entries (75%)
    # while being 30% of the files, and reading all 138 showed 76 were instances
    # of 12 principles. Grouping them under hub memories freed 63 lines with no
    # deletion (see docs/memory-hygiene-problems.md).
    #
    # Fires only where hubs already exist, so a store that has not adopted the
    # pattern stays silent, and only on creation — an edit to an established
    # memory is not a budget decision and nagging there would train the reader
    # to skip the whole hook.
    # Already carried by a hub? Then having no index line is the INTENDED state,
    # not a defect, and saying otherwise taxes every future edit to all 76 of
    # them. Caught by running this hook against a real store rather than a
    # fixture: it fired on a memory that was correctly hubbed.
    IN_HUB=""
    for h in "$DIR"/feedback_hub_*.md; do
      [ -f "$h" ] || break
      grep -qF "[[$STEM]]" "$h" 2>/dev/null && { IN_HUB=$(basename "$h" .md); break; }
    done
    HUBS=""
    case "$TYPE:$STEM" in
      feedback:feedback_hub_*) ;;   # a hub carries the others; it keeps its own line
      feedback:*)
        for h in "$DIR"/feedback_hub_*.md; do
          [ -f "$h" ] || break
          HUBS="$HUBS
      [[$(basename "$h" .md)]]"
        done
        ;;
    esac
    if [ -n "$IN_HUB" ]; then
      # The archive line is the whole restore path: move it back and the lesson
      # has its own index line again. A hub bullet with no archived line leaves
      # nothing to move.
      if [ -f "$DIR/MEMORY_ARCHIVE.md" ] && ! grep -qF "($BASE)" "$DIR/MEMORY_ARCHIVE.md"; then
        add "[[$IN_HUB]] carries this memory, but no line for $BASE is in MEMORY_ARCHIVE.md. That line is the restore path — without it there is nothing to move back if the lesson needs its own index line again."
      fi
    elif [ -n "$HUBS" ]; then
      add "no MEMORY.md line points at $BASE yet — and this store groups method lessons under principle hubs. If this lesson is an instance of one, do NOT add a MEMORY.md line: add a bullet to that hub and put this memory's index line in MEMORY_ARCHIVE.md under the hub's heading. Give it its own index line only if it is a user preference, a fact about a specific tool, or fits no hub. Hubs:$HUBS"
    else
      add "no line in MEMORY.md points at $BASE, so it will never be recalled. Add one, in the section for its type."
    fi
  else
    # Nothing clips an index line on the way in - a 109-char line arrives in
    # the session verbatim. The budget exists because the index as a WHOLE is
    # capped near 25,000 BYTES, and one line per memory means the per-line
    # average is the only lever on it: 220 entries x 110 chars is already
    # 24,200, and more than that in bytes -- an em-dash is three. Compose the
    # hook to fit. Hand-clipping is what left a live index with entries ending
    # "per-policy ms ALREADY" and "superset".
    # The per-line budget exists ONLY because the index as a whole is capped
    # near 25,000 bytes and holds one line per memory, so per-line length
    # is the single lever on the total. A store with 6 memories and a 2KB index
    # has enormous headroom, and nagging about a long hook there is noise that
    # would teach the reader to ignore the check. Measured: enforcing it
    # unconditionally produced 72 findings across seven small stores, every one
    # of them pointless. So enforce it only when the index is actually under
    # pressure.
    # Two units on purpose, matching upstream: the index TOTAL is a byte size
    # (wc -c; the truncation warning states it in KB), while the per-entry
    # budget upstream states is in characters. ILEN stays ${#IDX} for that
    # reason. Naming them apart is the fix -- calling the byte total "chars" is
    # what let a 24,688-character index read as compliant at 25,150 bytes.
    IDX_BYTES=$(wc -c < "$DIR/MEMORY.md" | tr -d ' ')
    IDX_LINES=$(wc -l < "$DIR/MEMORY.md" | tr -d ' ')
    if [ "$IDX_BYTES" -ge "$INDEX_PRESSURE_BYTES" ] || [ "$IDX_LINES" -ge "$INDEX_PRESSURE_LINES" ]; then
      ILEN=${#IDX}
      [ "$ILEN" -gt "$INDEX_LINE_MAX" ] \
        && add "its index line is $ILEN chars. This index is at $IDX_BYTES bytes of ~$INDEX_MAX_BYTES and $IDX_LINES lines, so per-line length is the only lever left on the total — compose the hook under $INDEX_LINE_MAX."
    fi

    # An index hook carrying changing state is the drift no checker can catch.
    # The file and the hook never contradict each other from inside the store —
    # the contradiction lives on GitHub. A live index had a hook reading
    # "3 PRs open (#1938 #1608 #29)" pointing at a memory whose own body already
    # said all three had merged, and it sat in the most-read block of the file.
    if printf '%s' "$IDX" | grep -qiE "$STATE_RE"; then
      add "its index line asserts changing state. The hook is the one thing loaded into every session and nothing inside the store can ever contradict it — say what the memory is ABOUT and leave the state in the body."
    fi

    # Placement. The index is ordered by type so that truncation drops the
    # cheapest lines; an entry filed under the wrong marker defeats that
    # silently. The live memory writer appends to the end of the file
    # regardless of type, so this fires exactly when it should.
    SECTION=$(awk -v want="$IDX" '
      /^<!--/ { m = $0 }
      $0 == want { print m; exit }
    ' "$DIR/MEMORY.md")
    # An untyped memory is placed under REFERENCE by memory-index, by design, so
    # that a merely malformed memory is not demoted into the truncated tail.
    # Flagging that placement too would have this tool contradict its sibling
    # and report one defect twice - the missing `type:` is already reported
    # above, and the placement is a consequence of it, not a separate problem.
    [ -z "$TYPE" ] && SECTION=""
    case "$SECTION" in
      *"ACTIVE WORK"*|"") ;;                       # hand-curated, or unsorted index
      *FEEDBACK*)  [ "$TYPE" = "feedback" ] || [ "$TYPE" = "user" ] \
                     || add "its index line sits in the FEEDBACK section but the memory is \`type: $TYPE\`. Run: bash bin/memory-index.sh --store <slug> --write" ;;
      *REFERENCE*) [ "$TYPE" = "reference" ] \
                     || add "its index line sits in the REFERENCE section but the memory is \`type: $TYPE\`. Run: bash bin/memory-index.sh --store <slug> --write" ;;
      *PROJECT*)   [ "$TYPE" = "project" ] \
                     || add "its index line sits in the PROJECT section but the memory is \`type: $TYPE\`. Run: bash bin/memory-index.sh --store <slug> --write" ;;
    esac
  fi
fi

[ -n "$FINDINGS" ] || exit 0

printf 'memory-lint on %s:\n%s\nFix these now — each one is a single edit here, and none of them is detectable later.\n' \
  "$BASE" "$FINDINGS" >&2
exit 2
