#!/usr/bin/env bash
# Orders MEMORY.md by memory type, so that when the index is truncated the lines
# it drops are the cheapest ones.
#
# The index is loaded into every session and truncated tail-first past ~200
# lines. Left in append order it therefore drops the NEWEST entries: measured on
# a real 218-memory store, 19 entries fell past the cut and five of them were
# `feedback` memories - rules about how to work, which do nothing at all unless
# they are loaded. The most expensive lines to lose were exactly the ones being
# lost.
#
# The order, cheapest-to-lose last:
#
#   ACTIVE     hand-curated block at the top, passed through untouched
#   feedback   behaviour rules; worthless unless loaded, so never in the tail
#   reference  durable facts. An index line is how the model learns one EXISTS,
#              so these cannot be demoted out of the index on the assumption it
#              will go looking. Newest first WITHIN the block, same as project.
#   project    lifecycle-bound and the only type with a natural exit. Newest
#              first, so the tail is the oldest - the archive-eligible end.
#
# Reference kept append order until 2026-08-31, which put the freshest fact at
# the cut. Measured on a live 283-memory store sitting at 197 of its 200 lines:
# the last two entries of the reference block were both written that same day,
# while facts from 2026-06-03 sat safely near the top. That is the same failure
# this script was written to fix for feedback, just never applied one block
# down - a fact the session has only just paid to discover is the single most
# expensive line to drop.
#
# This does not fix the size. On a corpus that is mostly live work nothing does:
# measured against Jira, only 3 of 56 project memories were provably settled, so
# neither merging nor archiving reclaims the lines. Ordering is the lever that
# actually exists, which makes truncation survivable rather than lossy.
#
# A pure permutation, always: every entry line is preserved byte-identical, and
# the run aborts before writing if the set of entries changed at all.
#
# Usage:  bash memory-index.sh [--store SLUG] [--write]
#   --store SLUG  only this store (default: every store under ~/.claude/projects)
#   --write       reorder in place (default: report whether it is already ordered)
#   --archive-overflow
#                 implies --write. After ordering, keep the index at or below
#                 the 200-line / 25,000-byte budget MINUS a margin (default 15
#                 lines / 1,500 bytes) by moving entries into MEMORY_ARCHIVE.md,
#                 cheapest end first: oldest project, then oldest reference.
#                 The margin is the room the index needs to stay under the cap
#                 BETWEEN runs; drained to exactly the cap it is over again
#                 after one new memory.
#                 Ordering alone decides WHICH line is lost; this decides
#                 whether losing it is RECORDED or silent. Measured on a live
#                 store growing ~14 memories a day, no fixed headroom survives
#                 24 hours, so the index is permanently at its cap and the tail
#                 is permanently being dropped - the only question left is
#                 whether anything says so. Never peels ACTIVE, feedback or
#                 untyped entries: those are above the cut by design, and never
#                 an entry newer than the age floor below.
#   --min-age-days N
#                 age floor for --archive-overflow (default 2, 0 disables):
#                 never peel an entry whose memory was modified in the last N
#                 days. Tier cheapness is an INDIRECT proxy for "least costly to
#                 lose" and it breaks down when a tier is nearly empty: measured
#                 on two consecutive days, the drain took a `project` memory
#                 written that same morning - the freshest and most actionable
#                 entry in the store - because project is the cheapest tier and
#                 that memory was the only thing in it. Recency is a DIRECT
#                 signal, so it overrides the proxy. If the floor blocks every
#                 remaining candidate the drain stops short and says so, rather
#                 than peeling live work to satisfy a number.
#
# Exit: 0 already ordered (or written) · 1 out of order · 3 could not run
#
# Portability: macOS ships bash 3.2 — no associative arrays, no mapfile.
set -u

PROJECTS="${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}"
ONLY_STORE=""
WRITE=0
ARCHIVE_OVERFLOW=0
# Same budget memory-verify enforces. Bytes, not characters - `wc -c` counts
# bytes and this index is full of multi-byte punctuation.
INDEX_MAX_LINES="${MEMORY_INDEX_MAX_LINES:-200}"
INDEX_MAX_BYTES="${MEMORY_INDEX_MAX_CHARS:-25000}"
# Drain BELOW the cap, not to it. This tool runs occasionally, not on every
# memory write, so an index drained to exactly 200 lines is back over the cap
# within a day at the measured ~14-memories-a-day rate - and everything past
# the cap in the meantime is dropped with nothing recording it. The margin is
# what keeps the index compliant BETWEEN runs.
INDEX_ARCHIVE_MARGIN="${MEMORY_INDEX_ARCHIVE_MARGIN:-15}"
INDEX_ARCHIVE_MARGIN_BYTES="${MEMORY_INDEX_ARCHIVE_MARGIN_BYTES:-1500}"
# Never peel a memory modified within this many days. See --min-age-days above:
# the tier is a proxy for cost-of-loss and a nearly-empty tier defeats it.
INDEX_ARCHIVE_MIN_AGE_DAYS="${MEMORY_INDEX_ARCHIVE_MIN_AGE_DAYS:-2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --write) WRITE=1; shift ;;
    --archive-overflow) ARCHIVE_OVERFLOW=1; WRITE=1; shift ;;
    --min-age-days) INDEX_ARCHIVE_MIN_AGE_DAYS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

[ -d "$PROJECTS" ] || { echo "FATAL: no projects dir at $PROJECTS" >&2; exit 3; }

# Section markers. memory-lint.sh reads these to tell which section a line is
# in, so the two must agree; keep the leading text stable.
# The ACTIVE marker is only ever READ, never written: that block is hand-curated
# and this script passes it through, so a store without one does not get one.
M_ACTIVE_PREFIX='<!-- ACTIVE WORK'
M_ACTIVE='<!-- ACTIVE WORK — kept at top so index truncation cannot drop it -->'
# The safety property archiving rests on: the memory file stays on disk and the
# index keeps ONE line saying the archive exists. Without it an archived memory
# is invisible - the index line is the only way the model learns one exists.
# Matched by target, so a hand-written pointer is recognised and not duplicated.
ARCHIVE_POINTER='- [ARCHIVE: older memories](MEMORY_ARCHIVE.md) — index lines only; every memory file is still on disk and recallable. Read this when older work comes up.'
M_FEEDBACK='<!-- FEEDBACK — how to work; these only function when loaded, so never in the tail -->'
M_REFERENCE='<!-- REFERENCE — durable facts, newest first; the index line is how the model learns they exist -->'
M_PROJECT='<!-- PROJECT — lifecycle-bound, newest first; the oldest tail is archive-eligible -->'

TAB=$(printf '\t')
# Newest first, ties in ORIGINAL input order. `sort -r` alone is not stable and
# would reverse same-day entries - and on a store where most memories land on a
# handful of busy days, most entries are ties. The sequence number is therefore
# an explicit ascending tiebreak against a descending date key.
sort_newest_first() { sort -t"$TAB" -k1,1r -k2,2n "$1" | cut -f3-; }

# The `modified:` date of the memory an index line points at, read exactly as the
# sort key is so the two can never disagree. Fails when the line names no
# resolvable file - an untyped or broken entry is never a peel candidate anyway.
entry_mdate() {  # entry_mdate <dir> <index-line>
  local d="$1" line="$2" f m
  f=$(printf '%s\n' "$line" | sed -n 's/.*](\([^)]*\)).*/\1/p')
  [ -n "$f" ] && [ -f "$d/$f" ] || return 1
  m=$(sed -n 's/^[[:space:]]*modified:[[:space:]]*\([0-9-]*\).*/\1/p' "$d/$f" | head -1)
  [ -n "$m" ] || m=$(date -r "$d/$f" +%Y-%m-%d 2>/dev/null || echo 0000-00-00)
  printf '%s\n' "$m"
}

# Oldest date still counted as "recent". Portable across BSD (macOS) and GNU.
# Empty means the floor is off, so every comparison against it is skipped.
AGE_CUTOFF=""
case "$INDEX_ARCHIVE_MIN_AGE_DAYS" in
  ''|0|*[!0-9]*) : ;;
  *) AGE_CUTOFF=$(date -v-"${INDEX_ARCHIVE_MIN_AGE_DAYS}"d +%Y-%m-%d 2>/dev/null \
               || date -d "${INDEX_ARCHIVE_MIN_AGE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
               || echo "") ;;
esac

TMP="${TMPDIR:-/tmp}/memory-index.$$"
mkdir -p "$TMP" || exit 3
trap 'rm -rf "$TMP"' EXIT

RC=0
STORES=0

for dir in "$PROJECTS"/*/memory; do
  [ -d "$dir" ] || continue
  slug=$(basename "$(dirname "$dir")")
  [ -n "$ONLY_STORE" ] && [ "$slug" != "$ONLY_STORE" ] && continue
  idx="$dir/MEMORY.md"
  [ -f "$idx" ] || continue
  STORES=$((STORES+1))

  # The ACTIVE block is the leading comment plus the entries directly under it,
  # up to the first blank line. It is hand-curated and passed through as-is.
  : > "$TMP/active"
  first=$(head -1 "$idx")
  case "$first" in
    "$M_ACTIVE_PREFIX"*)
      # `exit` still runs END in awk, so guard it with a flag or this prints twice.
      end=$(awk 'NR>1 && !/^- \[/ { print NR-1; f=1; exit } END { if (!f) print NR }' "$idx")
      head -n "$end" "$idx" > "$TMP/active"
      ;;
    *) end=0 ;;
  esac

  awk -v s="$end" 'NR>s && /^- \[/' "$idx" > "$TMP/rest"

  # One awk pass, not a bash loop: this runs at every session start, and each
  # exec costs ~25ms on a Mac behind an endpoint agent (5 per entry before).
  # `type:`/`modified:` are matched at any indentation on purpose: older
  # memories carry them at the top level, and memory-lint reads them the same
  # way. Link target is the LAST `](...)`, as the greedy sed it replaced did.
  awk -v dir="$dir" '
    {
      seq++; line = $0; f = ""; t = ""; m = ""; s = line
      while (match(s, /\]\([^)]*\)/)) {
        f = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + 2)
      }
      if (f != "") {
        p = dir "/" f; rc = 0
        while ((rc = (getline l < p)) > 0) {
          if (t == "" && match(l, /^[[:space:]]*type:[[:space:]]*[a-z]*[[:space:]]*$/)) {
            t = l; sub(/^[[:space:]]*type:[[:space:]]*/, "", t); sub(/[[:space:]]*$/, "", t)
            if (t == "") t = "-"
          }
          if (m == "" && match(l, /^[[:space:]]*modified:/)) {
            m = l; sub(/^[[:space:]]*modified:[[:space:]]*/, "", m); sub(/[^0-9-].*$/, "", m)
            if (m == "") m = "-"
          }
        }
        if (rc == 0) close(p)
      }
      if (t == "user") t = "feedback"
      if (t != "feedback" && t != "reference" && t != "project") t = "unknown"
      if ((t == "reference" || t == "project") && (m == "" || m == "-")) {
        # Sort key falls back to file mtime; `date -r FILE` is BSD and GNU.
        q = p; gsub(/\047/, "\047\\\047\047", q)
        cmd = "date -r \047" q "\047 +%Y-%m-%d 2>/dev/null"
        m = ""; cmd | getline m; close(cmd)
        if (m == "") m = "0000-00-00"
      }
      printf "%s\t%s\t%d\t%s\n", t, m, seq, line
    }' "$TMP/rest" > "$TMP/classified"

  # feedback/unknown: the bare line, input order. reference/project keep
  # <mdate>TAB<seq>TAB<line> for sort_newest_first. Unknown (no resolvable
  # type) is kept above project so a malformed memory is not demoted to the tail.
  : > "$TMP/feedback"; : > "$TMP/reference"; : > "$TMP/project"; : > "$TMP/unknown"
  awk -F'\t' -v out="$TMP" '
    $1 == "feedback" || $1 == "unknown" { print substr($0, length($1) + length($2) + length($3) + 4) > (out "/" $1); next }
    { print substr($0, length($1) + 2) > (out "/" $1) }' "$TMP/classified"

  # Sort once, then emit from the sorted lists so overflow can be peeled off
  # their tails without re-deriving the order each time.
  sort_newest_first "$TMP/reference" > "$TMP/ref.s"
  sort_newest_first "$TMP/project"   > "$TMP/prj.s"
  : > "$TMP/peeled"

  emit_index() {  # emit_index <reference-sorted> <project-sorted>
    if [ -s "$TMP/active" ]; then cat "$TMP/active"; echo ""; fi
    if [ -s "$TMP/feedback" ]; then echo "$M_FEEDBACK"; cat "$TMP/feedback"; echo ""; fi
    if [ -s "$1" ] || [ -s "$TMP/unknown" ]; then
      echo "$M_REFERENCE"
      # Untyped entries go ABOVE the sorted facts, not below. They are already
      # kept out of the project tail on purpose; now that reference is sorted
      # they would otherwise become the tail themselves in any store whose
      # project block is empty, which is exactly where a merely-malformed
      # memory must not sit.
      [ -s "$TMP/unknown" ] && cat "$TMP/unknown"
      [ -s "$1" ] && cat "$1"
      echo ""
    fi
    if [ -s "$2" ]; then echo "$M_PROJECT"; cat "$2"; fi
  }

  emit_index "$TMP/ref.s" "$TMP/prj.s" > "$TMP/new"

  if [ "$ARCHIVE_OVERFLOW" -eq 1 ]; then
    # ONE threshold, used to trigger and to drain: keep the index at or below
    # the cap minus a margin. Triggering on the cap itself and draining to it
    # leaves the index exactly full, so it is back over after a single new
    # memory and everything past the cap until the next run is dropped with
    # nothing recording it. The margin is the whole point - it is the room the
    # index needs to stay compliant BETWEEN runs, not during one.
    tgt_l=$((INDEX_MAX_LINES - INDEX_ARCHIVE_MARGIN))
    tgt_b=$((INDEX_MAX_BYTES - INDEX_ARCHIVE_MARGIN_BYTES))
    [ "$tgt_l" -lt 1 ] && tgt_l=1
    [ "$tgt_b" -lt 1 ] && tgt_b=1
    over=0
    [ "$(wc -l < "$TMP/new" | tr -d ' ')" -gt "$tgt_l" ] && over=1
    [ "$(wc -c < "$TMP/new" | tr -d ' ')" -gt "$tgt_b" ] && over=1
    # Add the pointer BEFORE draining, never after: it costs a line, and a
    # drain that ran to exactly the budget and then appended one would hand
    # back an index one line over.
    if [ "$over" -eq 1 ] && ! grep -q '](MEMORY_ARCHIVE\.md)' "$TMP/new"; then
      [ -s "$TMP/active" ] || printf '%s\n' "$M_ACTIVE" > "$TMP/active"
      printf '%s\n' "$ARCHIVE_POINTER" >> "$TMP/active"
      emit_index "$TMP/ref.s" "$TMP/prj.s" > "$TMP/new"
    fi
    # Bounded on purpose. Every iteration appends to a file the user keeps, so
    # a loop that failed to shrink would grow the archive without limit; one
    # pass per entry is strictly more than it can ever need.
    blocked_by_age=0
    guard=$(( $(wc -l < "$TMP/ref.s" | tr -d ' ') + $(wc -l < "$TMP/prj.s" | tr -d ' ') + 1 ))
    while [ "$over" -eq 1 ] && [ "$guard" -gt 0 ]; do
      guard=$((guard-1))
      l=$(wc -l < "$TMP/new" | tr -d ' ')
      b=$(wc -c < "$TMP/new" | tr -d ' ')
      [ "$l" -le "$tgt_l" ] && [ "$b" -le "$tgt_b" ] && break
      # Cheapest end first. Both lists are newest-first, so their LAST line is
      # the oldest entry of that type - the same line truncation would take,
      # except that here it is written down instead of vanishing.
      #
      # The age floor overrides that order. Because each list is newest-first
      # its tail is the OLDEST of its tier, so if even the tail is inside the
      # floor then every entry in that tier is: skipping the whole tier is
      # exactly right, not an approximation.
      src=""
      for cand in "$TMP/prj.s" "$TMP/ref.s"; do
        [ -s "$cand" ] || continue
        if [ -n "$AGE_CUTOFF" ]; then
          cdate=$(entry_mdate "$dir" "$(tail -1 "$cand")" 2>/dev/null || echo "")
          if [ -n "$cdate" ] && [ "$cdate" \> "$AGE_CUTOFF" ]; then
            blocked_by_age=1
            continue
          fi
        fi
        src="$cand"; break
      done
      [ -n "$src" ] || break
      tail -1 "$src" >> "$TMP/peeled"
      sed '$d' "$src" > "$TMP/pop" && mv "$TMP/pop" "$src"
      emit_index "$TMP/ref.s" "$TMP/prj.s" > "$TMP/new"
    done
    # Say so rather than leaving a silently-short drain to look like a full one.
    if [ "$blocked_by_age" -eq 1 ] \
       && { [ "$(wc -l < "$TMP/new" | tr -d ' ')" -gt "$tgt_l" ] \
            || [ "$(wc -c < "$TMP/new" | tr -d ' ')" -gt "$tgt_b" ]; }; then
      echo "$slug: drain stopped short of the target — every remaining candidate is newer than ${INDEX_ARCHIVE_MIN_AGE_DAYS}d (age floor); index left at $(wc -l < "$TMP/new" | tr -d ' ') lines" >&2
    fi
  fi

  # Abort before writing anything if this is not a pure permutation.
  # The invariant is across the PAIR of files, not MEMORY.md alone: a peeled
  # entry has moved to the archive, not disappeared. Comparing only the index
  # would read every archived line as a loss and abort every run.
  # The pointer line is GENERATED, not carried over from the old index, so it is
  # excluded from both sides. Everything else must still balance exactly.
  grep '^- \[' "$idx" | grep -v '](MEMORY_ARCHIVE\.md)' | sort > "$TMP/a"
  { grep '^- \[' "$TMP/new"; cat "$TMP/peeled"; } | grep -v '](MEMORY_ARCHIVE\.md)' | sort > "$TMP/b"
  if ! cmp -s "$TMP/a" "$TMP/b"; then
    echo "ABORT $slug: reordering would not be a pure permutation" >&2
    diff "$TMP/a" "$TMP/b" | head -5 >&2
    exit 3
  fi

  # The check above cannot see its own blind spot: it filters both sides with
  # `^- [`, the same predicate the reordering uses. A line that fails that
  # predicate is equally absent from BOTH sides, so the comparison passes while
  # the line is dropped. Measured on a live store: an index entry acquired a
  # leaked shell-command prefix from an append with no trailing newline
  # ("grep -c . MEMORY.md; tail -2 MEMORY.md- [AgentTool unblocked...").
  # It stopped being an entry, the permutation check saw nothing wrong, and the
  # memory silently left the index -- which is the only way the model learns it
  # exists. A checker whose population is defined by the predicate under test
  # cannot catch a failure of that predicate, so this counts EVERY line.
  awk 'NF && $0 !~ /^- \[/ && $0 !~ /^<!--/ { print }' "$idx" > "$TMP/strays"
  if [ -s "$TMP/strays" ]; then
    echo "ABORT $slug: $(wc -l < "$TMP/strays" | tr -d ' ') line(s) in the index are neither an entry nor a tier marker." >&2
    echo "  Reordering would discard them silently. Repair them first:" >&2
    cut -c1-100 "$TMP/strays" | sed 's/^/    /' >&2
    echo "  A stray is usually an append with no trailing newline colliding with the next line." >&2
    exit 3
  fi

  n=$(wc -l < "$TMP/a" | tr -d ' ')
  if cmp -s "$idx" "$TMP/new"; then
    [ -n "$ONLY_STORE" ] && echo "$slug: already ordered ($n entries)"
    continue
  fi

  if [ "$WRITE" -eq 1 ]; then
    # Archive BEFORE the index is replaced. If the append fails the index is
    # left alone and the entries are still in it, which is recoverable; the
    # other order can drop a line from the index with nothing holding it.
    if [ -s "$TMP/peeled" ]; then
      arch="$dir/MEMORY_ARCHIVE.md"
      if [ ! -f "$arch" ]; then
        { echo "# Memory archive — index lines moved out of MEMORY.md"
          echo ""
          echo "Index lines only. **Every memory file listed here is still on disk and still"
          echo "recallable**; only its one-line pointer left the index, which is capped at"
          echo "${INDEX_MAX_LINES} lines / ${INDEX_MAX_BYTES} bytes and drops its tail silently past the cap."
          echo "To bring one back, move its line into MEMORY.md."
        } > "$arch"
      fi
      { echo ""
        echo "## Overflow archived $(date +%Y-%m-%d) — oldest first, cheapest end of the index"
        cat "$TMP/peeled"
      } >> "$arch"
    fi
    cp "$TMP/new" "$idx"
    echo "$slug: reordered ($n entries: feedback $(wc -l < "$TMP/feedback" | tr -d ' '), reference $(wc -l < "$TMP/ref.s" | tr -d ' '), project $(wc -l < "$TMP/prj.s" | tr -d ' '))"
    if [ -s "$TMP/peeled" ]; then
      echo "$slug: archived $(wc -l < "$TMP/peeled" | tr -d ' ') overflow entries to MEMORY_ARCHIVE.md → $(wc -l < "$idx" | tr -d ' ') lines, $(wc -c < "$idx" | tr -d ' ') bytes"
    fi
  else
    echo "$slug: OUT OF ORDER ($n entries) — rerun with --write"
    RC=1
  fi
done

if [ "$STORES" -eq 0 ]; then
  echo "FATAL: no store to check${ONLY_STORE:+ named '$ONLY_STORE'}" >&2
  exit 3
fi
exit "$RC"
