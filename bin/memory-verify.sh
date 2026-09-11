#!/usr/bin/env bash
# Checks file-based memories against external truth.
#
# Claude Code's own hygiene (auto-dream) reasons over memory *content* and
# session logs — it never leaves the machine. So a memory that says "PR #4821
# is a held draft" survives consolidation untouched, because nothing inside the
# file contradicts it. The contradiction lives on GitHub. That is the gap this
# closes.
#
# Two classes of memory, deliberately handled differently:
#
#   1. Carries a `verify:` block  -> resolved mechanically here, no model needed.
#   2. Does not                   -> reported as TRIAGE for the /memory-audit
#                                    skill, which has the judgment to work out
#                                    which repo a bare "#4821" means and then
#                                    writes a `verify:` block back, so the next
#                                    run lands in class 1.
#
# Read-only by contract: this script never edits, moves, or deletes a memory.
# Deleting on a heuristic destroys knowledge silently, which is strictly worse
# than staleness. It reports; a human or the skill decides.
#
# Usage:  bash memory-verify.sh [--store SLUG] [--json] [--all]
#   --store SLUG  only this store (default: every store under ~/.claude/projects)
#   --json        one JSON object per finding, for the skill to consume
#   --all         also list VERIFIED memories (default: only what needs attention)
#   --curate      also report merge candidates and settled entries (advisory; never deletes,
#                 and deliberately proposes no retirements — see the note by CLOSED_RE)
#
# The index has TWO limits and the line one usually binds first: 200 lines and
# ~25,000 characters. One line per memory means a store with more than ~200
# memories cannot comply by shortening hooks — only by consolidating them.
#
# Findings are a queue, so each one means exactly one thing:
#   STALE      a verify claim resolved against reality and disagrees
#   TRIAGE     asserts open state with no way to check it - needs a verify block
#   NEEDS_MCP  a well-formed claim only the skill can resolve (Jira is MCP-only)
#   SKIP       malformed or unrecognised claim - the memory needs fixing
#   OVERSIZE   the index is past a load limit and its tail is being dropped
#   SETTLED    advisory, --curate only: a project memory whose work is finished,
#              so its index line can be archived. Reversible, never a deletion —
#              the file, its links and its lessons all stay exactly where they are.
#   CANDIDATE  advisory, --curate only: two memories make the same claims
#
# Exit: 0 nothing needs attention · 1 at least one STALE · 2 only TRIAGE/SKIP
#       3 could not run
#
# Portability: macOS ships bash 3.2 — no associative arrays, no mapfile.
set -u

PROJECTS="${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}"
ONLY_STORE=""
AS_JSON=0
SHOW_ALL=0
# Age below which an unverified open-state claim is not worth flagging yet.
TRIAGE_MIN_AGE_DAYS="${MEMORY_TRIAGE_MIN_AGE_DAYS:-14}"
# Index load limits. Past either one the tail is silently dropped at session
# start, so the oldest entries stop reaching the model.
INDEX_MAX_LINES="${MEMORY_INDEX_MAX_LINES:-200}"
# Byte limit. The env var keeps its historical _CHARS spelling so existing
# overrides keep working; the value it carries is and always was bytes.
INDEX_MAX_BYTES="${MEMORY_INDEX_MAX_CHARS:-25000}"
CURATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --json)  AS_JSON=1; shift ;;
    --all)   SHOW_ALL=1; shift ;;
    --curate) CURATE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required." >&2; exit 3; }
[ -d "$PROJECTS" ] || { echo "FATAL: no projects dir at $PROJECTS" >&2; exit 3; }

# Testing seam: MEMORY_VERIFY_GH_CMD replaces how gh is invoked, so
# tests/memory-verify.test.sh can stub GitHub and stay hermetic in CI, where
# there is no gh credential.
GH_CMD="${MEMORY_VERIFY_GH_CMD:-gh}"
HAVE_GH=0
if [ -n "${MEMORY_VERIFY_GH_CMD:-}" ]; then
  HAVE_GH=1
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  HAVE_GH=1
fi

N_STALE=0
N_TRIAGE=0
N_SKIP=0
N_NEEDS_MCP=0
N_SETTLED=0
N_VERIFIED=0
N_OVERSIZE=0
N_CANDIDATE=0
HEADER_SHOWN=""

# Emit one finding. Fields are positional to stay bash-3.2 friendly.
emit() {
  local status="$1" store="$2" file="$3" detail="$4"
  case "$status" in
    STALE)    N_STALE=$((N_STALE+1)) ;;
    TRIAGE)   N_TRIAGE=$((N_TRIAGE+1)) ;;
    SKIP)     N_SKIP=$((N_SKIP+1)) ;;
    NEEDS_MCP) N_NEEDS_MCP=$((N_NEEDS_MCP+1)) ;;
    SETTLED)  N_SETTLED=$((N_SETTLED+1)) ;;
    VERIFIED) N_VERIFIED=$((N_VERIFIED+1)); [ "$SHOW_ALL" -eq 1 ] || return 0 ;;
    OVERSIZE) N_OVERSIZE=$((N_OVERSIZE+1)) ;;
    CANDIDATE) N_CANDIDATE=$((N_CANDIDATE+1)) ;;
  esac
  if [ "$AS_JSON" -eq 1 ]; then
    jq -nc --arg s "$status" --arg st "$store" --arg f "$file" --arg d "$detail" \
      '{status:$s, store:$st, file:$f, detail:$d}'
    return 0
  fi
  # Print the store name lazily, on its first finding — most stores are clean,
  # and a column of bare headers buries the few that need attention.
  if [ "$store" != "$HEADER_SHOWN" ]; then
    printf '\n%s\n' "$store"
    HEADER_SHOWN="$store"
  fi
  printf '  %-8s %-52s %s\n' "$status" "$file" "$detail"
}

# Age in whole days, preferring the frontmatter `modified:` stamp over mtime —
# mtime moves when anything rewrites the file, the stamp tracks the claim.
age_days() {
  local f="$1" stamp epoch now
  stamp=$(sed -n 's/^[[:space:]]*modified:[[:space:]]*//p' "$f" 2>/dev/null | head -1 | tr -d '"')
  epoch=""
  if [ -n "$stamp" ]; then
    # Three forms, because two writers disagree: Claude Code stamps an ISO
    # datetime, memory-fix stamps a bare date. BSD `date -f` needs a format that
    # matches the WHOLE string, so a datetime format silently rejects a bare
    # date - which then fell through to mtime, i.e. to the day the last rewrite
    # ran. That made every backfilled stamp read as 0d old.
    epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${stamp%%.*}" +%s 2>/dev/null) \
      || epoch=$(date -j -f '%Y-%m-%d' "${stamp%%T*}" +%s 2>/dev/null) \
      || epoch=$(date -d "$stamp" +%s 2>/dev/null) || epoch=""
  fi
  if [ -z "$epoch" ]; then
    epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  fi
  now=$(date +%s)
  echo $(( (now - epoch) / 86400 ))
}

# Pull the `verify:` block: top-level key, one claim per `- ` line, each of the
# form "<kind> <ref> <expected>". Kept whitespace-delimited on purpose so it
# parses with sed in bash 3.2 rather than needing a YAML library.
verify_lines() {
  awk '
    /^verify:[[:space:]]*$/ { inblock=1; next }
    inblock && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next
    }
    inblock && /^[^[:space:]]/ { inblock=0 }
  ' "$1" 2>/dev/null
}

# Resolve one "gh owner/repo#N expected" claim. Echoes "ok <actual>",
# "mismatch <actual>", or "skip <reason>".
resolve_gh() {
  local ref="$1" expected="$2" repo num actual
  repo="${ref%%#*}"
  num="${ref##*#}"
  case "$repo" in */*) : ;; *) echo "skip ref-not-repo-qualified"; return ;; esac
  case "$num" in ''|*[!0-9]*) echo "skip ref-has-no-number"; return ;; esac
  [ "$HAVE_GH" -eq 1 ] || { echo "skip gh-unavailable-or-unauthenticated"; return; }

  actual=$($GH_CMD pr view "$num" --repo "$repo" --json state -q .state 2>/dev/null)
  if [ -z "$actual" ]; then
    actual=$($GH_CMD issue view "$num" --repo "$repo" --json state -q .state 2>/dev/null)
  fi
  [ -z "$actual" ] && { echo "skip lookup-failed"; return; }

  # Case-insensitive compare; gh returns OPEN/MERGED/CLOSED.
  local a e
  a=$(printf '%s' "$actual"   | tr 'A-Z' 'a-z')
  e=$(printf '%s' "$expected" | tr 'A-Z' 'a-z')
  if [ "$a" = "$e" ]; then echo "ok $actual"; else echo "mismatch $actual"; fi
}

# Open-state language, i.e. the memory asserts something is still in flight.
# Matched case-insensitively (memories write "PENDING", "Pending" and "pending"
# interchangeably) and on word boundaries.
#
# "held" and "in review" were dropped after auditing 11 real memories: between
# them they produced three false positives ("held-out error" from a regression
# fit, "load-bearing in review", and "held" used as a disposition label in an
# included/held/skipped list) and not one true positive. Every genuine stale
# claim in that sample was caught by pending / awaiting / draft pr. Prose reuses
# state words freely, so a term only earns its place if it survives real text.
# A bare "pending" was in this list and was two thirds noise: memories describe
# GitHub's own states constantly ("required checks are pending - that is the
# healthy state", "a required check is missing, pending, or failed"). A finding
# that cries wolf gets ignored, so only liveness CONSTRUCTIONS count now.
OPEN_RE='\b(pending (review|merge|approval|deploy|release|sign-?off)|(is|still) pending|draft pr|awaiting|not yet (merged|deployed|landed|shipped)|blocked on|still open|will land)\b'
# Closed-state language. Co-occurrence with the above inside one file is the
# append-don't-revise contradiction: an update was added, the stale sentence
# stayed. Boundaried for the same reason, and because "unresolved" contains
# "resolved" — matching it would invert the signal entirely.
TERMINAL_RE='^(Done|Closed|Resolved|Won.t Do|Mitigated|IR Published)$'
CLOSED_RE='\b(merged|shipped|deployed|landed|resolved|verified in prod)\b'

# True when this memory's index line has already been moved to the archive.
# SETTLED's whole advice is "the index line can move to the archive section", so
# for a line already there the finding is vacuous - and it costs a reader the
# detour of opening the memory to discover that. Measured on a real store: all 7
# SETTLED findings on one run were already archived. Matched on the link TARGET,
# the same way memory-index.sh recognises its own pointer, so a line moved by
# hand counts too.
archived_already() {
  [ -f "$1/MEMORY_ARCHIVE.md" ] || return 1
  grep -qF "]($2)" "$1/MEMORY_ARCHIVE.md"
}

# There is deliberately NO "retire this memory" heuristic here, and the reason
# is worth recording so the idea is not re-invented. Staleness is not the test:
# an audit of a real 204-memory store found four verifiably stale memories and
# zero deletable ones, because in every case the lesson outlived the ticket.
# The obvious fallback — "settled outcome AND no lesson-shaped wording" — was
# built and then removed: it flagged a memory recording a verified pipeline
# MISMATCH and another recording that a table is absent from the lakehouse, so
# a conversion is blocked. Both are durable FACTS carrying no lesson-shaped
# words. No wordlist separates a pure status record from a durable fact, and a
# wrong suggestion here costs knowledge that cannot be recovered. Retirement
# stays a human judgement; this script only surfaces size pressure and overlap.

# The index is skipped as a memory (it is a list of links, not a claim), which
# left a blind spot: a stale claim written into an index one-liner was never
# examined at all — and the index is the part loaded into context every single
# session, so it is the worst place to leave one. Found in a real store, where a
# hook still said "awaiting new doc dump" for work that had merged months
# earlier while the memory it pointed at was already correct.
#
# Age-gate each line by the memory it links to, not by the index's own mtime:
# the index is rewritten whenever any entry changes, so its mtime says nothing
# about how long a given line has been wrong.
scan_index() {
  local dir="$1" slug="$2" line target age
  # Separate statement: within one `local`, $dir is not yet assigned.
  local idx="$dir/MEMORY.md"
  local n=0

  [ -f "$idx" ] || return 0
  while IFS= read -r line; do
    n=$((n + 1))
    printf '%s' "$line" | grep -qiE "$OPEN_RE" || continue
    target=$(printf '%s' "$line" | sed -n 's/.*](\([^)]*\.md\)).*/\1/p' | head -1)
    if [ -n "$target" ] && [ -f "$dir/$target" ]; then
      age=$(age_days "$dir/$target")
      [ "$age" -lt "$TRIAGE_MIN_AGE_DAYS" ] && continue
      emit TRIAGE "$slug" "MEMORY.md:$n" "index line asserts open state about ${target} (${age}d old)"
    else
      emit TRIAGE "$slug" "MEMORY.md:$n" "index line asserts open state"
    fi
  done < "$idx"
}

# The index is the one file loaded into context every session, so passing
# either limit silently truncates its tail — the oldest hooks simply stop
# arriving, with no error at the point of use. Checked per store, because
# each store carries its own index.
scan_index_size() {
  local dir="$1" slug="$2"
  local idx="$dir/MEMORY.md"
  [ -f "$idx" ] || return 0
  local lines bytes entries over
  lines=$(wc -l < "$idx" | tr -d ' ')
  # BYTES, not characters: wc -c counts bytes and the upstream limit is 25KB.
  # Reporting this number as "chars" is how a 24,688-character index got called
  # compliant while measuring 25,150 bytes and still being truncated.
  bytes=$(wc -c < "$idx" | tr -d ' ')
  entries=$(grep -c '^- \[' "$idx" 2>/dev/null || true)
  over=""
  [ "$lines" -gt "$INDEX_MAX_LINES" ] && over="${lines}/${INDEX_MAX_LINES} lines"
  if [ "$bytes" -gt "$INDEX_MAX_BYTES" ]; then
    [ -n "$over" ] && over="$over, "
    over="${over}${bytes}/${INDEX_MAX_BYTES} bytes"
  fi
  [ -n "$over" ] || return 0
  emit OVERSIZE "$slug" "MEMORY.md" \
    "index over the load limit ($over; $entries entries) — the tail is dropped at session start. One line per memory, so shortening hooks cannot fix the LINE limit; order by type so the tail is cheap, then retire settled entries."
}

# Advisory overlap pass. Answers one question a size problem actually turns
# on: do two memories make the same claims, and could they be one file?
#
# This was originally keyed on ticket number and that was wrong. Measured on a
# real 218-memory store, ticket-key grouping produced four candidate groups; the
# one genuine pair shared four verbatim claims and the other three shared ZERO.
# A ticket cited by two memories usually means one records the fix and the other
# records a lesson learned alongside it — different content, correctly separate
# files. Grouping on shared claims instead separates them exactly.
#
# Reports only — see the note above on why retirement is not automated.
CURATE_MIN_OVERLAP="${MEMORY_CURATE_MIN_OVERLAP:-2}"

scan_curation() {
  local dir="$1" slug="$2" f base
  local tmp="${TMPDIR:-/tmp}/mv-claims.$$"
  : > "$tmp"

  # A memory's claims are its bolded runs. Short bolds are labels ("**Note**")
  # and match everywhere, so they are excluded by the length floor.
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ "$base" = "MEMORY.md" ] && continue
    # MEMORY_ARCHIVE.md, not ARCHIVE.md: this guard named a file that has never
    # existed, so the archive's index lines were mined for claims like any
    # memory and could pair a live memory against its own archived hook.
    [ "$base" = "MEMORY_ARCHIVE.md" ] && continue
    grep -o '\*\*[^*]\{25,160\}\*\*' "$f" 2>/dev/null \
      | sed 's/\*\*//g' | tr 'A-Z' 'a-z' | tr -s ' \t' ' ' \
      | sed 's/^ //; s/ $//' | sort -u \
      | while IFS= read -r c; do printf '%s\t%s\n' "$c" "$base"; done >> "$tmp"
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }

  # Every unordered file pair per shared claim, counted, then thresholded.
  # Written to a file and read back by redirect, not by pipe: a piped `while`
  # runs in a subshell and emit's counters would vanish.
  sort "$tmp" | awk -F'\t' '
    { c[$1] = c[$1] " " $2 }
    END {
      for (k in c) {
        n = split(c[k], a, " ")
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
          if (a[i] == "" || a[j] == "" || a[i] == a[j]) continue
          if (a[i] < a[j]) print a[i] "\t" a[j]; else print a[j] "\t" a[i]
        }
      }
    }
  ' | sort | uniq -c | sort -rn > "$tmp.p"

  while read -r cnt pair; do
    [ -z "$cnt" ] && continue
    [ "$cnt" -lt "$CURATE_MIN_OVERLAP" ] && continue
    emit CANDIDATE "$slug" "$(printf '%s' "$pair" | tr '\t' ' ')" \
      "merge? these two share $cnt verbatim claims"
  done < "$tmp.p"
  rm -f "$tmp" "$tmp.p"
}

scan_store() {
  local dir="$1" slug="$2" f base claims line kind ref expected result actual age ids id_count note
  local settled recorded_only mtype

  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ "$base" = "MEMORY.md" ] && continue
    # Neither index is a memory. The archive carries index lines whose hooks
    # quote the memories they point at, so scanning it re-reports their claims
    # against a file with no frontmatter, no type and no verify block.
    [ "$base" = "MEMORY_ARCHIVE.md" ] && continue

    claims=$(verify_lines "$f")
    if [ -n "$claims" ]; then
      # Track whether every claim in this memory has reached a terminal state.
      settled=1; recorded_only=0
      # Here-string, not a pipe: a piped `while` runs in a subshell and the
      # N_* counters incremented inside it would be discarded on exit.
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        kind=$(printf '%s' "$line" | awk '{print $1}')
        ref=$(printf '%s' "$line" | awk '{print $2}')
        expected=$(printf '%s' "$line" | awk '{print $3}')
        if [ -z "$ref" ] || [ -z "$expected" ]; then
          emit SKIP "$slug" "$base" "malformed verify claim: $line"
          settled=0
          continue
        fi
        case "$kind" in
          gh)
            result=$(resolve_gh "$ref" "$expected")
            actual=$(printf '%s' "$result" | awk '{print $2}')
            case "$result" in
              ok*)       emit VERIFIED "$slug" "$base" "$ref is $actual, as recorded"
                         printf '%s' "$actual" | grep -qiE '^(merged|closed)$' || settled=0 ;;
              mismatch*) emit STALE "$slug" "$base" "$ref expected=$expected actual=$actual"
                         settled=0 ;;
              *)         emit SKIP  "$slug" "$base" "$ref $(printf '%s' "$result" | cut -d' ' -f2-)"
                         settled=0 ;;
            esac
            ;;
          jira)
            # Jira lives behind MCP, which a shell script cannot reach. The
            # skill resolves these; flagging rather than silently passing.
            emit NEEDS_MCP "$slug" "$base" "$ref is resolvable only through the Jira MCP, so the /memory-audit skill has to run it"
            # The shell cannot confirm this, so the recorded status is the only
            # evidence there is. Good enough to SUGGEST retirement, which is
            # reversible - and if it ever diverges, the skill's next run says
            # STALE. Never good enough to act on unattended.
            printf '%s' "$expected" | grep -qiE "$TERMINAL_RE" || settled=0
            recorded_only=1
            ;;
          *)
            emit SKIP "$slug" "$base" "unknown verify kind '$kind'"
            settled=0
            ;;
        esac
      done <<< "$claims"

      # Every claim terminal, no in-flight language, and lifecycle-bound: this
      # memory's WORK is finished. That is a claim about the index line, not
      # about the memory - the lesson usually outlives the ticket, so the file
      # and its links stay exactly where they are and only the entry moves to a
      # section that is not loaded. Reversible in one line, which is why it may
      # be suggested at all where the withdrawn retirement heuristic could not:
      # that one guessed from prose, this one reads resolved evidence.
      mtype=$(sed -n 's/^[[:space:]]*type:[[:space:]]*\([a-z]*\)[[:space:]]*$/\1/p' "$f" | head -1)
      # Behind --curate, with the other index-size advice: a healthy store
      # should stay quiet on a default run, and a settled memory is not a
      # defect. It is only interesting when the index is being trimmed.
      if [ "$CURATE" -eq 1 ] && [ "$settled" -eq 1 ] && [ "$mtype" = "project" ] \
         && ! grep -qiE "$OPEN_RE" "$f" 2>/dev/null \
         && ! archived_already "$dir" "$base"; then
        if [ "$recorded_only" -eq 1 ]; then
          emit SETTLED "$slug" "$base" "every claim is terminal per the RECORDED evidence and nothing is in flight — the index line can move to the archive section"
        else
          emit SETTLED "$slug" "$base" "every claim verified terminal and nothing is in flight — the index line can move to the archive section"
        fi
      fi
      continue
    fi

    # No verify block. Worth triaging if it asserts in-flight state.
    #
    # Deliberately NOT age-gated. Rot rate is a property of the claim, not of
    # the file: a durable fact is worth re-checking on a cadence, but a claim
    # about something still open with no way to check it mechanically is a
    # write-time defect the moment it is written. The evidence is a memory in
    # this corpus that asserted three PRs were open when all three had merged
    # the same day - a 14-day gate would have hidden it for two weeks, and it
    # sat in the most-read block of the index the whole time.
    if grep -qiE "$OPEN_RE" "$f" 2>/dev/null; then
      age=$(age_days "$f")
      # Advisory context for the skill, which reads the file itself anyway — so
      # bias to high signal over completeness. Standards tokens (SHA-256,
      # ISO-8601) match the Jira-key shape but are never tickets, and a file
      # citing thirty PRs produces an unreadable line, so cap the list.
      ids=$(grep -oE '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]{2,6}|[A-Z]{2,10}-[0-9]{2,6}' "$f" 2>/dev/null \
              | grep -vE '^(SHA|ISO|UTF|RFC|AES|RSA|TLS|HMAC|UTC|BASE)-' \
              | sort -u)
      id_count=$(printf '%s\n' "$ids" | grep -c . || true)
      ids=$(printf '%s\n' "$ids" | head -8 | tr '\n' ' ' | sed 's/ $//')
      [ "$id_count" -gt 8 ] && ids="$ids …and $((id_count - 8)) more"
      note="${age}d old, asserts open state"
      if grep -qiE "$CLOSED_RE" "$f" 2>/dev/null; then
        note="$note; ALSO claims closed state (self-contradictory)"
      fi
      [ -n "$ids" ] && note="$note; refs: $ids"
      emit TRIAGE "$slug" "$base" "$note"
    fi
  done
}

[ "$AS_JSON" -eq 0 ] && {
  echo "Checking memories against external truth."
  [ "$HAVE_GH" -eq 1 ] || echo "NOTE: gh unavailable or unauthenticated — GitHub claims will be SKIPped."
}

STORES_SCANNED=0
for store in "$PROJECTS"/*; do
  [ -d "$store/memory" ] || continue
  slug=$(basename "$store")
  [ -n "$ONLY_STORE" ] && [ "$slug" != "$ONLY_STORE" ] && continue
  STORES_SCANNED=$((STORES_SCANNED+1))
  scan_store "$store/memory" "$slug"
  scan_index "$store/memory" "$slug"
  scan_index_size "$store/memory" "$slug"
  if [ "$CURATE" -eq 1 ]; then scan_curation "$store/memory" "$slug"; fi
done

# A mistyped slug must not exit 0 — silence would read as "nothing is stale"
# when in fact nothing was examined.
if [ "$STORES_SCANNED" -eq 0 ]; then
  if [ -n "$ONLY_STORE" ]; then
    echo "FATAL: no store named '$ONLY_STORE' under $PROJECTS" >&2
  else
    echo "FATAL: no memory stores found under $PROJECTS" >&2
  fi
  exit 3
fi

if [ "$AS_JSON" -eq 0 ]; then
  echo ""
  echo "--- Results: $N_STALE stale, $N_TRIAGE triage, $N_NEEDS_MCP need-mcp, $N_SKIP skipped, $N_VERIFIED verified, $N_OVERSIZE oversize, $N_SETTLED settled, $N_CANDIDATE candidates"
  [ "$N_TRIAGE" -gt 0 ] && echo "Run /memory-audit to resolve the TRIAGE entries and give them verify: blocks."
  if [ "$N_OVERSIZE" -gt 0 ] && [ "$CURATE" -eq 0 ]; then
    echo "The index is over its load limit, so its tail is dropped at session start."
    echo "One line per memory, so shortening hooks cannot fix the LINE limit. Order the"
    echo "index by type first, so what falls off is cheap, then retire settled entries."
  fi
fi

[ "$N_STALE" -gt 0 ] && exit 1
[ $((N_TRIAGE + N_SKIP + N_NEEDS_MCP + N_OVERSIZE)) -gt 0 ] && exit 2
exit 0
