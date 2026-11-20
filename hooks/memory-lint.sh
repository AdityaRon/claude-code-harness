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
if [[ "$0" == */* ]]; then source "${0%/*}/lib.sh"; else source ./lib.sh; fi   # dirname "$0", with no process

read_input
command -v jq &>/dev/null || exit 0     # advisory only; never fail a write
TOOL=$(jq_get '.tool_name')

case "$TOOL" in
  Write|Edit|MultiEdit) FILE=$(jq_get '.tool_input.file_path') ;;
  *) exit 0 ;;
esac

[ -n "$FILE" ] || exit 0
TRACKER=""
case "$FILE" in
  */memory/*.md) ;;
  */trackers/*-archive.md) exit 0 ;;   # tracker-prune.py's archive: grows by design, read by grep only
  */trackers/*.md) [ "${CLAUDE_TRACKER_LINT:-on}" = off ] && exit 0; TRACKER=1 ;;
  *) exit 0 ;;
esac
BASE=${FILE##*/}
[ -f "$FILE" ] || exit 0

# ---- trackers/: only a handoff is linted -------------------------------------
# A handoff is what a restart reads whole (rules/working-agreement.md): at most
# TRACKER_LEDGER_BYTES, no archive beside it, and marked by a STATE: or Crons:
# line or a "## Next on restart" heading; a file named *-handoff*.md without one gets a single
# finding saying so. Everything else in a trackers/ folder (ledgers,
# reports, logs) is not linted on its own writes: a finding there could lead a
# session to cut a file that has no other copy.
if [ -n "$TRACKER" ]; then
  LB=${TRACKER_LEDGER_BYTES:-20000}
  TB=$(( $(wc -c < "$FILE") ))
  PRUNE="python3 ~/.claude/tracker-prune.py"
  [ "$TB" -le "$LB" ] && [ ! -f "${FILE%.md}-archive.md" ] || exit 0
  if ! grep -qE '^(STATE:|Crons:|##[[:space:]]*Next on restart[[:space:]]*$)' "$FILE"; then
    # Unmarked: silent, unless the name says handoff. Then one finding, and none of the size, heading or
    # stamp ones until it is marked. A case on the name: no process start.
    case "$BASE" in
      *-[Hh][Aa][Nn][Dd][Oo][Ff][Ff]*.md)
        printf 'handoff lint on %s:\n  - it is named as a handoff but has no `STATE:`, `Crons:` or `## Next on restart`. Add them if it is a handoff; leave it as it is if it is not.\n(CLAUDE_TRACKER_LINT=off in settings.json env turns this off.)\n' "$BASE" >&2
        exit 2 ;;
    esac
    exit 0
  fi
  TF=""
  tadd() { TF="${TF}  - $1
"; }
  WANT="Scope|Open|Owed|Settled|Next on restart"
  GOT=$(sed -n 's/^## *//p' "$FILE" | sed 's/[[:space:]]*$//' | paste -sd '|' -)
  [ "$GOT" = "$WANT" ] || tadd "its ## headings are \"${GOT:-none}\". A handoff has Scope, Open, Owed, Settled, Next on restart, once each, in that order. If this file is not a handoff, leave it as it is."
  TMAX=${TRACKER_MAX_BYTES:-5000}
  [ "$TB" -le "$TMAX" ] || tadd "it is $TB bytes, past $TMAX. Move what a restart does not need into a memory, the PR or a ledger; never delete what has no other copy."
  STAMP=$(sed -n 's/^STATE:[[:space:]]*//p' "$FILE" | sed 's/[[:space:]]*$//' | head -1)
  if [ -z "$STAMP" ]; then
    tadd "no \`STATE:\` line. Take it from \`date -u +%Y-%m-%dT%H:%MZ\`, not from the conversation."
  else
    D=$(jq -nr --arg s "$STAMP" '(try ($s|strptime("%Y-%m-%dT%H:%M:%SZ")) catch (try ($s|strptime("%Y-%m-%dT%H:%MZ")) catch null))
      | if . == null then "bad" else ((mktime - now) | floor | tostring) end' 2>/dev/null)
    case "$D" in
      bad|"") tadd "\`STATE: $STAMP\` is not a UTC time like 2026-11-18T14:05Z. Take it from \`date -u +%Y-%m-%dT%H:%MZ\`." ;;
      *) if [ "$D" -gt 120 ]; then tadd "\`STATE: $STAMP\` is $(( D / 60 )) min ahead of the clock. Take it from \`date -u +%Y-%m-%dT%H:%MZ\`."
         elif [ "$D" -lt -300 ]; then tadd "\`STATE: $STAMP\` is $(( -D / 60 )) min old, older than this write. Refresh it from \`date -u +%Y-%m-%dT%H:%MZ\`."; fi ;;
    esac
  fi
  # Session crons live only in the session: the tracker is what carries them across a restart.
  CRONS=$(awk '/^Crons:/ { v = $0; sub(/^Crons:[[:space:]]*/, "", v); print "HEAD " v; on = 1; next }
               on && /^[[:space:]]*- / { print; next } on { exit }' "$FILE")
  if [ -z "$CRONS" ]; then
    tadd "no \`Crons:\` line. List each session cron as \`- <five cron fields> <prompt>\`, or write \`Crons: none\`."
  else
    CH=$(printf '%s\n' "$CRONS" | sed -n '1s/^HEAD //p')
    CL=$(printf '%s\n' "$CRONS" | sed '1d')
    if [ "$CH" = none ]; then
      [ -z "$CL" ] || tadd "\`Crons: none\` with entries under it."
    elif [ -n "$CH" ] || [ -z "$CL" ]; then
      tadd "\`Crons:\` takes \`none\` or entries on the lines under it, each \`- <five cron fields> <prompt>\`."
    else
      BAD=$(printf '%s\n' "$CL" | grep -vE '^[[:space:]]*- ([0-9*/,-]+[[:space:]]+){5}[^[:space:]]' | head -3)
      [ -z "$BAD" ] || tadd "a cron entry without five fields and a prompt: $(printf '%s' "$BAD" | head -1 | sed 's/^[[:space:]]*//')"
    fi
  fi
  # Ledgers beside this handoff, the one check that sees a ledger edited through
  # Bash. -L: one kept elsewhere and linked in is measured at its target, as wc
  # and sed above read it. wc and awk start only when find names one.
  BIG=$(find -L "${FILE%/*}" -maxdepth 1 -name '*.md' ! -name '*-archive.md' -size +"${LB}"c -exec wc -c {} + 2>/dev/null)
  if [ -n "$BIG" ]; then
    # Whole words and names by hand: mawk and BWK awk have no \b. A read-first line
    # names a ledger after read/reread/reading, says first, before, start or
    # restart, and no slice tool.
    RF=$(awk -v lb="$LB" -v prune="$PRUNE" '
      function at(s, w, from,   i, p) {
        while ((i = index(substr(s, from), w)) > 0) {
          p = from + i - 1
          if ((p == 1 || substr(s, p - 1, 1) !~ /[a-z0-9_]/) && substr(s, p + length(w), 1) !~ /[a-z0-9_]/) return p
          from = p + 1
        }
        return 0
      }
      function named(s, w, from,   i, p, a) {
        while ((i = index(substr(s, from), w)) > 0) {
          p = from + i - 1; a = substr(s, p + length(w), 2)
          if ((p == 1 || substr(s, p - 1, 1) !~ /[a-z0-9._-]/) && a !~ /^[a-z0-9_-]/ && a !~ /^\.[a-z0-9_-]/) return p
          from = p + 1
        }
        return 0
      }
      function first(a, b) { return !a ? b : (!b || a < b) ? a : b }
      FNR == NR {
        if (index($0, "/") == 0) next
        p = $0; sub(/^[ \t]*[0-9]+[ \t]/, "", p); b = p; sub(/.*\//, "", b)
        n++; nm[n] = tolower(b); bn[n] = b; sz[n] = $1
        next
      }
      {
        l = tolower($0)
        if (at(l, "grep", 1) || at(l, "rg", 1) || at(l, "sed", 1) || at(l, "awk", 1) || at(l, "slice", 1)) next
        if (!(at(l, "first", 1) || at(l, "before", 1) || at(l, "start", 1) || at(l, "restart", 1))) next
        r = first(first(at(l, "read", 1), at(l, "reread", 1)), at(l, "reading", 1))
        if (!r) next
        for (k = 1; k <= n; k++) if (named(l, nm[k], r + 1)) {
          if (++hits <= 3) printf "  - line %d tells a session to read %s (%d bytes) first. Say to read it by slice (grep, sed -n) instead.\n", FNR, bn[k], sz[k]
          break
        }
      }
      END { if (hits > 3) printf "  - and %d more like that.\n", hits - 3 }' - "$FILE" <<EOF
$BIG
EOF
)
    [ -z "$RF" ] || TF="$TF$RF
"
  fi
  [ -n "$TF" ] || exit 0
  printf 'handoff lint on %s:\n%s(CLAUDE_TRACKER_LINT=off in settings.json env turns this off.)\n' "$BASE" "$TF" >&2
  exit 2
fi

# The same limits memory-verify reports OVERSIZE against. Measured in BYTES:
# wc -c counts bytes, and the upstream limit is 25KB, not 25,000 characters. The
# distinction is not academic here -- em-dashes and arrows are multi-byte, so a
# real index runs ~2% larger in bytes than in characters, which is enough to sit
# inside the limit on one measure and outside it on the other. These names say
# BYTES so nobody reads a passing character count as compliance.
# shellcheck source=lib/memory-limits.sh
source "$(dirname "$0")/lib/memory-limits.sh" \
  || { echo "memory-lint: cannot read lib/memory-limits.sh; run install.sh again" >&2; exit 1; }
INDEX_LINE_MAX="$MEMORY_LINE_MAX"
INDEX_MAX_BYTES="$MEMORY_MAX_BYTES"
INDEX_MAX_LINES="$MEMORY_MAX_LINES"
# The fix for an out-of-order index, at the installed path, for this store:
# projects/<slug>/memory/<file>.
_d=${FILE%/*}; _d=${_d%/*}
REINDEX="bash ~/.claude/memory-index.sh --store ${_d##*/} --write"

# ---- the index itself ---------------------------------------------------
# The per-memory checks below do not apply to an index, so this is its own pass.
# Size is not checked here: since 2.1.210 Claude Code itself returns an error
# on a write that leaves MEMORY.md over its limit, and a reminder near it.
if [ "$BASE" = "MEMORY.md" ]; then
  IFIND=""
  iadd() { IFIND="${IFIND}  - $1
"; }

  # The harm is never the limit, it is WHICH entries fall past it. A tail of
  # settled project_ entries is the designed sacrifice; a feedback_ entry there
  # is silently not loaded, and feedback_ only works when loaded.
  BELOW=$(grep -n '^- \[' "$FILE" 2>/dev/null | awk -F: -v cut="$INDEX_MAX_LINES" '$1>cut' | grep -c 'feedback_' || true)
  [ "${BELOW:-0}" -gt 0 ] \
    && iadd "${BELOW} feedback_ memor$([ "$BELOW" = 1 ] && echo y || echo ies) sit past line ${INDEX_MAX_LINES} and will not load. Run \`$REINDEX\` to restore tier order, or move them up by hand."

  # A line that is neither an entry nor a tier marker is usually an append with
  # no trailing newline that collided with the next line. It stops being an
  # entry, so the memory silently leaves the index -- and a reorder would drop
  # it outright.
  STRAY=$(awk 'NF && $0 !~ /^- \[/ && $0 !~ /^<!--/' "$FILE" 2>/dev/null | wc -l | tr -d ' ')
  [ "${STRAY:-0}" -gt 0 ] \
    && iadd "${STRAY} line(s) are neither an entry nor a tier marker — likely an append with no trailing newline fused to the next line. Repair before reordering, or the entry is discarded."

  if [ -n "$IFIND" ]; then
    # stderr: on exit 2 that is the stream Claude Code hands back to the model.
    printf 'memory-lint on %s:\n%s\n' "$BASE" "$IFIND" >&2
    printf 'The index is what tells the model a memory exists. Fix these now.\n' >&2
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

# No `modified:` check: Claude Code stamps it on the write itself, for any
# memory file with frontmatter (2.1.214).

# Provenance. A memory records what is believed, never who came to believe it, so
# an unattributed file is a claim with no origin: a paragraph a peer session
# appended twenty minutes ago is textually identical to one that has survived
# months of contact. That is not a staleness problem -- the memory may never have
# been independently established at all -- and it lets a session cite a memory as
# corroboration for the very finding that wrote it.
#
# Claude Code stamps originSessionId on memories it writes itself; one written
# straight through the Write tool gets whatever frontmatter the author chose, so
# this is where that gap closes. The hook knows the writing session, so it stamps
# the field itself: asking cost the writer an edit on 8 of every 9 new memories.
if ! grep -q 'originSessionId:' "$FILE"; then
  SID=$(jq_get '.session_id')
  STAMP="$FILE.stamp.$$"
  if [ -n "$SID" ] && awk -v sid="$SID" '
      NR == 1 && $0 != "---" { exit 1 }
      NR > 1 && !done && /^---[[:space:]]*$/ { if (!meta) print "metadata:"; print "  originSessionId: " sid; done = 1 }
      { print }
      NR > 1 && !done && /^metadata:[[:space:]]*$/ { meta = 1; print "  originSessionId: " sid; done = 1 }
      END { if (!done) exit 1 }' "$FILE" > "$STAMP" 2>/dev/null; then
    mv -f "$STAMP" "$FILE"
  elif [ -n "$SID" ]; then
    rm -f "$STAMP"
    add "no \`metadata.originSessionId\`, and no frontmatter to add it to. Add \`originSessionId: $SID\` under \`metadata:\` so this memory can be attributed later."
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
# A frontmatter `verify: none <reason>` says the wording cannot be checked, and
# why. The pattern is memory-verify's store_prepass, which honours it the same way.
WAIVER=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && /^---[[:space:]]*$/ { exit }
  NR > 1 && /^[[:space:]]*verify:[[:space:]]*none([[:space:]]|$)/ {
    sub(/^[[:space:]]*verify:[[:space:]]*none[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print "W:" $0; exit }' "$FILE")
if [ "$WAIVER" = "W:" ]; then
  add "\`verify: none\` gives no reason, so memory-verify ignores it. Say why this memory cannot be checked: \`verify: none <reason>\`."
fi
if grep -qiE "$OPEN_RE" "$FILE" && ! grep -q '^verify:' "$FILE" && [ "${WAIVER#W:}" = "" ]; then
  add "asserts work still in flight but carries no \`verify:\` block, so nothing can ever check it. Add one, e.g. \`  - gh owner/repo#123 open\` or \`  - jira PROJ-1 In Progress\`, or \`verify: none <reason>\` in the frontmatter if no lookup can settle it."
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
    # deletion (see docs/history/memory-hygiene-problems.md).
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
    ARCHIVED=""
    [ -f "$DIR/MEMORY_ARCHIVE.md" ] && grep -qF "($BASE)" "$DIR/MEMORY_ARCHIVE.md" && ARCHIVED=1
    if [ -n "$IN_HUB" ]; then
      # The archive line is the whole restore path: move it back and the lesson
      # has its own index line again. A hub bullet with no archived line leaves
      # nothing to move.
      if [ -f "$DIR/MEMORY_ARCHIVE.md" ] && [ -z "$ARCHIVED" ]; then
        add "[[$IN_HUB]] carries this memory, but no line for $BASE is in MEMORY_ARCHIVE.md. That line is the restore path — without it there is nothing to move back if the lesson needs its own index line again."
      fi
    elif [ -n "$ARCHIVED" ]; then
      # Archived is the intended state for a fact or a finished project. A rule
      # only works when loaded, so it may leave the index only under a hub.
      case "$TYPE" in
        project|reference) ;;
        feedback|user)
          add "its only index line is in MEMORY_ARCHIVE.md, and a feedback memory is never archived on its own: a rule works only when loaded. Move the line back into MEMORY.md, or add a bullet for [[$STEM]] to a hub whose own line is in MEMORY.md and keep the archive line under that hub's heading.${HUBS:+ Hubs:$HUBS}" ;;
        *)
          add "its only index line is in MEMORY_ARCHIVE.md, which holds \`project\` and \`reference\` memories. Give it a type, or move the line back into MEMORY.md." ;;
      esac
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
    # budget upstream states is in characters. Naming them apart is the fix --
    # calling the byte total "chars" is what let a 24,688-character index read
    # as compliant at 25,150 bytes. ILEN drops UTF-8 continuation bytes rather
    # than using ${#IDX}, which counts bytes under a POSIX locale.
    IDX_BYTES=$(wc -c < "$DIR/MEMORY.md" | tr -d ' ')
    IDX_LINES=$(wc -l < "$DIR/MEMORY.md" | tr -d ' ')
    if memory_pressure "$IDX_LINES" "$IDX_BYTES"; then
      ILEN=$(printf '%s' "$IDX" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
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
                     || add "its index line sits in the FEEDBACK section but the memory is \`type: $TYPE\`. Run: $REINDEX" ;;
      *REFERENCE*) [ "$TYPE" = "reference" ] \
                     || add "its index line sits in the REFERENCE section but the memory is \`type: $TYPE\`. Run: $REINDEX" ;;
      *PROJECT*)   [ "$TYPE" = "project" ] \
                     || add "its index line sits in the PROJECT section but the memory is \`type: $TYPE\`. Run: $REINDEX" ;;
    esac
  fi
fi

[ -n "$FINDINGS" ] || exit 0

printf 'memory-lint on %s:\n%s\nFix these now — each one is a single edit here, and none of them is detectable later.\n' \
  "$BASE" "$FINDINGS" >&2
exit 2
