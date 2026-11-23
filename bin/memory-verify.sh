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
# Usage:  bash memory-verify.sh [--store SLUG] [--json] [--all] [--offline]
#   --store SLUG  only this store (default: every store under ~/.claude/projects)
#   --json        one JSON object per finding, for the skill to consume
#   --offline     never run gh, not even `gh auth status`: each GitHub claim is a SKIP
#                 ("offline"), and everything checked on this machine is reported as usual
#   --all         also list VERIFIED and WAIVED memories (default: only what needs attention)
#   --curate      also report merge candidates and settled entries (advisory; never deletes,
#                 and deliberately proposes no retirements — see the note by CLOSED_RE)
#   --jira-keys   print only the keys of every `jira` verify claim, deduped, as
#                 `key in (...)` lines of 50: one JQL search per line, ready to paste
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
#   ORPHAN     no index line, archive line or feedback_hub_* [[link]] reaches it
#   OVERSIZE   the index is past a load limit and its tail is being dropped
#   SETTLED    advisory, --curate only: a project memory whose work is finished,
#              so its index line can be archived. Reversible, never a deletion —
#              the file, its links and its lessons all stay exactly where they are.
#   CANDIDATE  advisory, --curate only: two memories make the same claims
#   WAIVED     counted, listed with --all: frontmatter `verify: none <reason>`
#              stops TRIAGE for it; an empty reason is a SKIP and waives nothing
#
# Exit: 0 nothing needs attention · 1 at least one STALE · 2 only TRIAGE, SKIP,
#       NEEDS_MCP, ORPHAN or OVERSIZE · 3 could not run
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
# One copy, shared with memory-index and memory-lint: beside this file when
# installed (~/.claude/hooks/lib), ../hooks/lib in the clone.
case "$0" in */*) HERE=${0%/*}; [ -n "$HERE" ] || HERE=/ ;; *) HERE=. ;; esac
LIMITS="$HERE/hooks/lib/memory-limits.sh"
[ -f "$LIMITS" ] || LIMITS="$HERE/../hooks/lib/memory-limits.sh"
# shellcheck source=../hooks/lib/memory-limits.sh
. "$LIMITS" 2>/dev/null || { echo "FATAL: cannot read hooks/lib/memory-limits.sh near $0; run install.sh again" >&2; exit 3; }
INDEX_MAX_LINES="$MEMORY_MAX_LINES"
INDEX_MAX_BYTES="$MEMORY_MAX_BYTES"
CURATE=0
JIRA_KEYS=0
OFFLINE=0
# GitHub claims are looked up this many to one GraphQL call, per repo.
GH_BATCH="${MEMORY_VERIFY_GH_BATCH:-100}"
case "$GH_BATCH" in ''|*[!0-9]*|0) GH_BATCH=100 ;; esac
NL='
'
TAB='	'

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --json)  AS_JSON=1; shift ;;
    --all)   SHOW_ALL=1; shift ;;
    --curate) CURATE=1; shift ;;
    --jira-keys) JIRA_KEYS=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required." >&2; exit 3; }
[ -d "$PROJECTS" ] || { echo "FATAL: no projects dir at $PROJECTS" >&2; exit 3; }
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/memory-verify.XXXXXX") || { echo "FATAL: no temp dir" >&2; exit 3; }
trap 'rm -rf "$TMP_DIR"' EXIT

# Testing seam: MEMORY_VERIFY_GH_CMD replaces how gh is invoked, so
# tests/memory-verify.test.sh can stub GitHub and stay hermetic in CI, where
# there is no gh credential.
GH_CMD="${MEMORY_VERIFY_GH_CMD:-gh}"
HAVE_GH=0
if [ "$OFFLINE" -eq 1 ]; then
  :
elif [ -n "${MEMORY_VERIFY_GH_CMD:-}" ]; then
  HAVE_GH=1
elif [ "$JIRA_KEYS" -eq 0 ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
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
N_HOOK=0
N_ORPHAN=0
N_WAIVED=0
HEADER_SHOWN=""
US=$'\037'
JSON_ROWS=""

# One jq for every buffered row, not one per row. A detail may hold any byte but
# a newline; the fourth field onward is rejoined, so it is never cut short.
flush_json() {
  [ -n "$JSON_ROWS" ] || return 0
  printf '%s' "$JSON_ROWS" | jq -Rnc 'inputs | split("\u001f")
    | {status: .[0], store: .[1], file: .[2], detail: (.[3:] | join("\u001f"))}'
}

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
    HOOK)     N_HOOK=$((N_HOOK+1)) ;;
    ORPHAN)   N_ORPHAN=$((N_ORPHAN+1)) ;;
    WAIVED)   N_WAIVED=$((N_WAIVED+1)); [ "$SHOW_ALL" -eq 1 ] || return 0 ;;
  esac
  if [ "$AS_JSON" -eq 1 ]; then
    # Buffered, one row to a line: flush_json turns every row into JSON in one jq.
    JSON_ROWS="$JSON_ROWS$status$US$store$US$file$US$detail$NL"
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
# Sets AGE and runs in the caller's shell, so NOW and AGE_CACHE persist: `now`
# is read once, and a stamp is parsed by `date` once however many files carry it.
MODIFIED_RE='^[[:space:]]*modified:[[:space:]]*(.*)$'
NOW0=""
SECS0=0
NOW=""
AGE=0
AGE_CACHE="$NL"
DATE_BSD=0
case "$OSTYPE" in darwin*|*bsd*) DATE_BSD=1 ;; esac
age_days() {
  local f="$1" stamp="" epoch="" line ent
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $MODIFIED_RE ]]; then stamp=${BASH_REMATCH[1]}; break; fi
  done 2>/dev/null < "$f"
  stamp=${stamp//\"/}
  if [ -n "$stamp" ]; then
    ent=""
    case "$stamp" in *"$TAB"*) ;; *) ent=${AGE_CACHE#*"$NL$stamp$TAB"}; [ "$ent" = "$AGE_CACHE" ] && ent="" ;; esac
    if [ -n "$ent" ]; then
      epoch=${ent%%"$NL"*}
    else
      # Three forms, because two writers disagree: Claude Code stamps an ISO
      # datetime, memory-fix stamps a bare date. BSD `date -f` needs a format that
      # matches the WHOLE string, so a datetime format silently rejects a bare
      # date - which then fell through to mtime, i.e. to the day the last rewrite
      # ran. The -j forms run only where they can succeed (BSD date; a T to match).
      if [ "$DATE_BSD" -eq 1 ]; then
        case "${stamp%%.*}" in
          *T*) epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${stamp%%.*}" +%s 2>/dev/null) || epoch="" ;;
        esac
        [ -n "$epoch" ] || epoch=$(date -j -f '%Y-%m-%d' "${stamp%%T*}" +%s 2>/dev/null) || epoch=""
      fi
      [ -n "$epoch" ] || epoch=$(date -d "$stamp" +%s 2>/dev/null) || epoch=""
      case "$stamp" in *"$TAB"*) ;; *) AGE_CACHE="$AGE_CACHE$stamp$TAB$epoch$NL" ;; esac
    fi
  fi
  if [ -z "$epoch" ]; then
    epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  fi
  # `date -f` fills a bare date's time of day from the clock, so `now` must not
  # read earlier than that parse. Read once, then advanced by $SECONDS, rounded
  # up: never behind the parse, and no `date` start per call.
  if [ -n "${EPOCHSECONDS:-}" ]; then NOW=$EPOCHSECONDS
  else
    [ -n "$NOW0" ] || { NOW0=$(date +%s); SECS0=$SECONDS; }
    NOW=$((NOW0 + SECONDS - SECS0 + 1))
  fi
  AGE=$(( (NOW - epoch) / 86400 ))
}

# One awk pass over a store, before any lookup. Given an output dir it writes
# tab-separated files there: g <repo> <number> (a gh claim), w <file> <reason>
# (a `verify: none` waiver), v <file> (has a verify: block), c <file> <claim> (a
# line of that block, in order). Given "" it prints each jira claim's key.
# A claim missing from g is a lookup-failed SKIP in resolve_gh, never a pass.
store_prepass() {  # store_prepass <outdir or ""> <memory files>
  local od="$1"; shift
  awk -v OFS='\t' -v od="$od" '
    FNR == 1 {
      skip = (FILENAME ~ /(^|\/)MEMORY(_ARCHIVE)?\.md$/); inblock = 0; vb = 0
      base = FILENAME; sub(/.*\//, "", base)
      fm = ($0 == "---"); if (fm) next
    }
    skip { next }
    # The claims of the verify: block, whatever the frontmatter says: its own
    # state (vb), ended by any unindented line, the closing --- included.
    od != "" {
      if ($0 ~ /^verify:[[:space:]]*$/) vb = 1
      else if (vb && $0 ~ /^[[:space:]]*-[[:space:]]/) {
        s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); print base, s > (od "/c")
      } else if (vb && $0 ~ /^[^[:space:]]/) vb = 0
    }
    fm && /^---[[:space:]]*$/ { fm = 0; next }
    # The same pattern hooks/memory-lint.sh accepts the waiver by.
    fm && /^[[:space:]]*verify:[[:space:]]*none([[:space:]]|$)/ {
      r = $0; sub(/^[[:space:]]*verify:[[:space:]]*none[[:space:]]*/, "", r); sub(/[[:space:]]+$/, "", r)
      sub(/\t.*/, "", r)
      if (od != "") print base, r > (od "/w")
      next
    }
    /^verify:[[:space:]]*$/ { inblock = 1; if (od != "") print base > (od "/v"); next }
    inblock && /^[[:space:]]*-[[:space:]]/ {
      s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); n = split(s, a, " ")
      if (od != "" && n >= 3 && a[1] == "gh" && a[2] ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+$/) {
        k = index(a[2], "#"); num = substr(a[2], k + 1)
        # A GraphQL Int takes no leading zero; 9 digits keeps it inside 32 bits.
        sub(/^0+/, "", num); if (num == "") num = "0"
        if (length(num) <= 9) print substr(a[2], 1, k - 1), num > (od "/g")
      }
      if (od == "" && n >= 3 && a[1] == "jira") print a[2]
      next
    }
    inblock && /^[^[:space:]]/ { inblock = 0 }
  ' "$@" 2>/dev/null
}

# "<owner/repo>#<n><TAB><STATE>" lines: STATE as GitHub gives it, or "!<error
# type>" for an alias that came back null. A ref with no line was not answered.
GH_STATES="$NL"

# One GraphQL call per repo per GH_BATCH numbers, replacing a `gh pr view` per
# claim (plus an `issue view` fallback) that took minutes on a store of a few
# hundred claims. issueOrPullRequest answers for either kind.
gh_prefetch() {  # gh_prefetch <file of sorted, unique "owner/repo<TAB>number" lines>
  local repo num cur="" q="" n=0
  [ "$HAVE_GH" -eq 1 ] && [ -s "$1" ] || return 0
  while IFS="$TAB" read -r repo num; do
    if [ "$repo" != "$cur" ] || [ "$n" -ge "$GH_BATCH" ]; then
      [ "$n" -gt 0 ] && gh_batch "$cur" "$q"
      cur="$repo"; q=""; n=0
    fi
    q="${q}n$num: issueOrPullRequest(number: $num) { ... on PullRequest { state } ... on Issue { state } }$NL"
    n=$((n + 1))
  done < "$1"
  [ "$n" -gt 0 ] && gh_batch "$cur" "$q"
  return 0
}

# gh exits 1 when any alias fails, and stdout still carries every other alias
# (measured with gh api graphql on 2026-11-18: one PR and one missing number
# gave exit 1, the PR's state, `null` for the other and an errors[] entry). So
# the status is ignored and stdout read whole: one bad ref costs its own claim,
# not the batch. Output that is not JSON leaves every ref unanswered.
gh_batch() {  # gh_batch <owner/repo> <alias lines>
  local out
  out=$($GH_CMD api graphql -f query="query {${NL}r: repository(owner: \"${1%%/*}\", name: \"${1#*/}\") {${NL}${2}}${NL}}" 2>/dev/null)
  GH_STATES="$GH_STATES$(printf '%s' "$out" | jq -r --arg repo "$1" '
      ((.errors // []) | map(select((.path | length) == 2) | {key: .path[1], value: (.type // "ERROR")}) | from_entries) as $e
      | (.data.r // {}) | to_entries[]
      | "\($repo)#\(.key | ltrimstr("n"))\t\(.value.state // ("!" + ($e[.key] // "NULL")))"' 2>/dev/null)$NL"
}

# Resolve one "gh owner/repo#N expected" claim from GH_STATES. Sets R_KIND to
# ok, mismatch or skip, and R_VAL to the state or the reason. No subshell.
resolve_gh() {
  local ref="$1" expected="$2" repo num rest actual
  repo="${ref%%#*}"
  num="${ref##*#}"
  R_KIND=skip
  case "$repo" in */*) : ;; *) R_VAL="ref-not-repo-qualified"; return ;; esac
  case "$num" in ''|*[!0-9]*) R_VAL="ref-has-no-number"; return ;; esac
  case "$repo" in */*/*|/*|*/|*[!A-Za-z0-9_./-]*) R_VAL="ref-malformed"; return ;; esac
  num=$((10#$num))
  [ "${#num}" -le 9 ] || { R_VAL="ref-malformed"; return; }
  [ "$OFFLINE" -eq 0 ] || { R_VAL="offline"; return; }
  [ "$HAVE_GH" -eq 1 ] || { R_VAL="gh-unavailable-or-unauthenticated"; return; }

  case "$GH_STATES" in
    *"$NL$repo#$num$TAB"*) rest=${GH_STATES#*"$NL$repo#$num$TAB"}; actual=${rest%%"$NL"*} ;;
    *) R_VAL="lookup-failed"; return ;;
  esac
  case "$actual" in
    '!NOT_FOUND') R_VAL="not-found"; return ;;
    '!'*)         R_VAL="lookup-failed (${actual#!})"; return ;;
  esac

  # Case-insensitive compare; GitHub returns OPEN/MERGED/CLOSED.
  R_VAL="$actual"
  shopt -s nocasematch
  if [[ "$actual" == "$expected" ]]; then R_KIND=ok; else R_KIND=mismatch; fi
  shopt -u nocasematch
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
TYPE_RE='^[[:space:]]*type:[[:space:]]*([a-z]*)[[:space:]]*$'

# True when this memory's index line has already been moved to the archive.
# SETTLED's whole advice is "the index line can move to the archive section", so
# for a line already there the finding is vacuous - and it costs a reader the
# detour of opening the memory to discover that. Measured on a real store: all 7
# SETTLED findings on one run were already archived. Matched on the link TARGET,
# the same way memory-index.sh recognises its own pointer, so a line moved by
# hand counts too.
ARCH_DIR=""; ARCH_TXT=""
archived_already() {
  [ -f "$1/MEMORY_ARCHIVE.md" ] || return 1
  [ "$ARCH_DIR" = "$1" ] || { ARCH_DIR="$1"; ARCH_TXT=$(<"$1/MEMORY_ARCHIVE.md"); }
  case "$ARCH_TXT" in *"]($2)"*) return 0 ;; *) return 1 ;; esac
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
LINK_RE='^.*\]\(([^)]*\.md)\)'   # the last `](x.md)` on a line: the greedy .* is the point
scan_index() {
  local dir="$1" slug="$2" line target age
  # Separate statement: within one `local`, $dir is not yet assigned.
  local idx="$dir/MEMORY.md"
  local n=0

  [ -f "$idx" ] || return 0
  # One grep for the lines that matter, rather than one per index line.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=${line%%:*}; line=${line#*:}
    target=""; [[ $line =~ $LINK_RE ]] && target=${BASH_REMATCH[1]}
    [ -n "$target" ] && case "$WAIVED_FILES" in *"$NL$target$NL"*) continue ;; esac
    if [ -n "$target" ] && [ -f "$dir/$target" ]; then
      age_days "$dir/$target"; age=$AGE
      [ "$age" -lt "$TRIAGE_MIN_AGE_DAYS" ] && continue
      emit TRIAGE "$slug" "MEMORY.md:$n" "index line asserts open state about ${target} (${age}d old)"
    else
      emit TRIAGE "$slug" "MEMORY.md:$n" "index line asserts open state"
    fi
  done <<EOF
$(grep -niE "$OPEN_RE" "$idx")
EOF
}

# A memory nothing links to is never recalled. Reached means named by a link
# in MEMORY.md or MEMORY_ARCHIVE.md, or by a [[stem]] in a feedback_hub_*.md,
# the hubs memory-lint.sh reads. One `comm` of two sorted lists, so the cost
# does not grow with a grep per file. No index, no finding: nothing to orphan from.
scan_orphans() {
  local dir="$1" slug="$2" f list="" srcs orphans
  [ -f "$dir/MEMORY.md" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    f=${f##*/}
    [ "$f" = MEMORY.md ] || [ "$f" = MEMORY_ARCHIVE.md ] || list="$list$f$NL"
  done
  # Link sources: both indexes, then every hub if the first glob entry is a file.
  srcs=("$dir/MEMORY.md"); [ -f "$dir/MEMORY_ARCHIVE.md" ] && srcs[1]="$dir/MEMORY_ARCHIVE.md"
  for f in "$dir"/feedback_hub_*.md; do
    [ -f "$f" ] || break
    srcs=("${srcs[@]}" "$dir"/feedback_hub_*.md)
    break
  done
  # One awk: the files no link names, in byte order (what `comm` of two C-sorted lists gave).
  orphans=$(FILES_NL="$list" LC_ALL=C awk '
    FNR == 1 { b = FILENAME; sub(/.*\//, "", b); hub = (b ~ /^feedback_hub_.*\.md$/) }
    {
      s = $0
      if (hub) {
        while (match(s, /\[\[[^]]*\]\]/)) { L[substr(s, RSTART + 2, RLENGTH - 4) ".md"] = 1; s = substr(s, RSTART + RLENGTH) }
      } else {
        while (match(s, /\]\([^)]*\)/)) {
          t = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
          sub(/#.*/, "", t); sub(/^\.\//, "", t); L[t] = 1
        }
      }
    }
    END {
      n = split(ENVIRON["FILES_NL"], a, "\n"); m = 0
      for (i = 1; i <= n; i++) if (a[i] != "" && !(a[i] in L)) {
        for (j = m; j > 0 && o[j] > a[i]; j--) o[j + 1] = o[j]
        o[j + 1] = a[i]; m++
      }
      for (i = 1; i <= m; i++) print o[i]
    }' "${srcs[@]}" 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] && emit ORPHAN "$slug" "$f" "no index line, archive line or hub [[link]] reaches it, so nothing recalls it"
  done <<< "$orphans"
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
  # BYTES, not characters: wc -c counts bytes and the upstream limit is 25KB.
  # Reporting this number as "chars" is how a 24,688-character index got called
  # compliant while measuring 25,150 bytes and still being truncated.
  read -r lines bytes <<< "$(wc -lc < "$idx")"
  over=""
  [ "$lines" -gt "$INDEX_MAX_LINES" ] && over="${lines}/${INDEX_MAX_LINES} lines"
  if [ "$bytes" -gt "$INDEX_MAX_BYTES" ]; then
    [ -n "$over" ] && over="$over, "
    over="${over}${bytes}/${INDEX_MAX_BYTES} bytes"
  fi
  [ -n "$over" ] || return 0
  entries=$(grep -c '^- \[' "$idx" 2>/dev/null || true)
  emit OVERSIZE "$slug" "MEMORY.md" \
    "index over the load limit ($over; $entries entries) — the tail is dropped at session start. One line per memory, so shortening hooks cannot fix the LINE limit; order by type so the tail is cheap, then retire settled entries."
}

# A hook is the only part of a memory that loads every session; the body arrives
# only once something recalls it. A hook that trails off ("3 of 48 tenants
# carry…") spends its index line and delivers none of the payload.
#
# The ellipsis is AUTHORED, not a tool truncating: measured across four backups
# of one store the damaged hooks were byte-identical for six days and ran 77-140
# chars, so no fixed-width cut produced them. Nothing else checks hook quality,
# which is how one store reached 25 trailed-off hooks in 82 entries.
#
# Only flagged when the memory's own `description:` still carries the payload,
# so every finding is a one-line edit with nothing to re-derive. A terse hook on
# a terse description is not a defect. Advisory: it does not change the exit
# code, because a thin hook still loads and an oversize index does not.
HOOK_MIN_DESC_RATIO="${MEMORY_HOOK_MIN_DESC_RATIO:-150}"
TRAIL_RE='(…|\.\.\.|,|;)$|(^|[[:space:]])(and|or|not|the|but|with|is|of|to|for|an?)$'
DESC_RE='^description: *(.*)$'
char_len() {  # sets CLEN: characters, by dropping the UTF-8 continuation bytes
  local LC_ALL=C s="$1"
  s=${s//[$'\200'-$'\277']/}
  CLEN=${#s}
}

scan_index_hooks() {
  local dir="$1" slug="$2" line target hook desc dlen hlen
  local idx="$dir/MEMORY.md"
  local n=0
  [ -f "$idx" ] || return 0
  # Every line is tested in this shell: a grep to pick candidates, and then a
  # grep, sed and tr per candidate, were most of the starts a run made.
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '- ['*) ;; *) continue ;; esac
    # Split on the separator the index format uses; no separator, no hook.
    hook=${line#*") — "}
    [ "$hook" = "$line" ] && continue
    # Trails off: an ellipsis, or a connective the writer meant to continue past.
    [[ $hook =~ $TRAIL_RE ]] || continue
    target=""; [[ $line =~ $LINK_RE ]] && target=${BASH_REMATCH[1]}
    [ -n "$target" ] && [ -f "$dir/$target" ] || continue
    desc=""
    while IFS= read -r dline || [ -n "$dline" ]; do
      if [[ $dline =~ $DESC_RE ]]; then desc=${BASH_REMATCH[1]}; break; fi
    done 2>/dev/null < "$dir/$target"
    desc=${desc#\"}; desc=${desc%\"}
    [ -n "$desc" ] || continue
    # Characters, not bytes: ${#var} counts bytes under a POSIX locale.
    char_len "$desc"; dlen=$CLEN
    char_len "$hook"; hlen=$CLEN
    [ $(( dlen * 100 )) -ge $(( hlen * HOOK_MIN_DESC_RATIO )) ] || continue
    emit HOOK "$slug" "MEMORY.md:$n" \
      "hook trails off (\"$hook\") but ${target} still has the payload: $(printf '%.120s' "$desc")"
  done < "$idx"
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
    base=${f##*/}
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

# "<file><TAB><ref>" for every issue-shaped ref in the given files, one line per
# distinct pair, grouped by file and sorted within it as `sort -u` sorts the refs.
# awk has no {n,m} in every build, so the interval is spelled out; the standards
# tokens (SHA-256, ISO-8601) are dropped here and not by a second grep.
store_ids() {
  awk -v OFS='\t' '
    FNR == 1 { base = FILENAME; sub(/.*\//, "", base) }
    {
      s = $0
      while (match(s, "([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9][0-9][0-9]?[0-9]?[0-9]?[0-9]?|[A-Z][A-Z][A-Z]?[A-Z]?[A-Z]?[A-Z]?[A-Z]?[A-Z]?[A-Z]?[A-Z]?-[0-9][0-9][0-9]?[0-9]?[0-9]?[0-9]?")) {
        id = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (id !~ /^(SHA|ISO|UTF|RFC|AES|RSA|TLS|HMAC|UTC|BASE)-/) print base, id
      }
    }' "$@" 2>/dev/null | sort -u -t "$TAB" -k1,1 -k2,2
}

# BASES = a newline, then each path's file name and a newline: `case` matches "$NL$name$NL".
base_list() {
  local p out=""
  while IFS= read -r p; do [ -n "$p" ] && out="$out${p##*/}$NL"; done <<< "$1"
  BASES="$NL$out"
}

# Sets `claims` (in scan_store) to the verify: claims of <file>, one a line, from CLAIMS.
claims_of() {
  local b="$1" rest
  claims=""
  case "$CLAIMS" in *"$NL$b$TAB"*) ;; *) return 0 ;; esac
  rest=${CLAIMS#*"$NL$b$TAB"}
  while :; do
    claims="$claims${rest%%"$NL"*}$NL"
    rest=${rest#*"$NL"}
    case "$rest" in "$b$TAB"*) rest=${rest#"$b$TAB"} ;; *) break ;; esac
  done
  while [ "${claims%"$NL"}" != "$claims" ]; do claims=${claims%"$NL"}; done
}

scan_store() {
  local dir="$1" slug="$2" f base claims line kind ref expected _rest age ids id_count note
  local settled recorded_only mtype waived waiver rest

  # Every gh claim in the store, looked up in batches before the first emit.
  : > "$TMP_DIR/g"; : > "$TMP_DIR/w"; : > "$TMP_DIR/v"; : > "$TMP_DIR/c"
  store_prepass "$TMP_DIR" "$dir"/*.md
  if [ "$HAVE_GH" -eq 1 ]; then
    LC_ALL=C sort -u "$TMP_DIR/g" > "$TMP_DIR/gh-refs"
    gh_prefetch "$TMP_DIR/gh-refs"
  fi
  WAIVERS="$NL$(<"$TMP_DIR/w")$NL"
  WAIVED_FILES="$NL"
  # One awk and two greps for the store, not one of each per file: on a few
  # hundred memories the per-file execs were most of the run once gh was batched.
  # The verify: claims and the refs below come out of the store's one awk each too.
  VFILES="$NL$(<"$TMP_DIR/v")$NL"
  CLAIMS="$NL$(<"$TMP_DIR/c")$NL"
  OPEN_FILES=$(grep -liE "$OPEN_RE" "$dir"/*.md 2>/dev/null)
  base_list "$OPEN_FILES"; OPEN_FILES=$BASES
  # Closed-state and refs are read only to annotate an open-state finding.
  CLOSED_FILES="$NL"; IDS="$NL"
  if [ "$OPEN_FILES" != "$NL" ]; then
    CLOSED_FILES=$(grep -liE "$CLOSED_RE" "$dir"/*.md 2>/dev/null)
    base_list "$CLOSED_FILES"; CLOSED_FILES=$BASES
    IDS="$NL$(store_ids "$dir"/*.md)$NL"
  fi

  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base=${f##*/}
    [ "$base" = "MEMORY.md" ] && continue
    # Neither index is a memory. The archive carries index lines whose hooks
    # quote the memories they point at, so scanning it re-reports their claims
    # against a file with no frontmatter, no type and no verify block.
    [ "$base" = "MEMORY_ARCHIVE.md" ] && continue

    waived=0
    case "$WAIVERS" in
      *"$NL$base$TAB"*)
        waiver=${WAIVERS#*"$NL$base$TAB"}; waiver=${waiver%%"$NL"*}
        if [ -n "$waiver" ]; then
          waived=1; WAIVED_FILES="$WAIVED_FILES$base$NL"
          emit WAIVED "$slug" "$base" "verify: none, $waiver"
        else
          emit SKIP "$slug" "$base" "verify: none gives no reason, so the waiver is ignored; say why it cannot be checked"
        fi ;;
    esac

    claims=""
    case "$VFILES" in *"$NL$base$NL"*) claims_of "$base" ;; esac
    if [ -n "$claims" ]; then
      # Track whether every claim in this memory has reached a terminal state.
      settled=1; recorded_only=0
      # Here-string, not a pipe: a piped `while` runs in a subshell and the
      # N_* counters incremented inside it would be discarded on exit.
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        read -r kind ref expected _rest <<< "$line"
        if [ -z "$ref" ] || [ -z "$expected" ]; then
          emit SKIP "$slug" "$base" "malformed verify claim: $line"
          settled=0
          continue
        fi
        case "$kind" in
          gh)
            resolve_gh "$ref" "$expected"
            case "$R_KIND" in
              ok)       emit VERIFIED "$slug" "$base" "$ref is $R_VAL, as recorded"
                        case "$R_VAL" in MERGED|CLOSED|merged|closed) ;; *) settled=0 ;; esac ;;
              mismatch) emit STALE "$slug" "$base" "$ref expected=$expected actual=$R_VAL"
                        settled=0 ;;
              *)        emit SKIP  "$slug" "$base" "$ref $R_VAL"
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
            shopt -s nocasematch
            [[ $expected =~ $TERMINAL_RE ]] || settled=0
            shopt -u nocasematch
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
      # Behind --curate, with the other index-size advice: a healthy store
      # should stay quiet on a default run, and a settled memory is not a
      # defect. It is only interesting when the index is being trimmed.
      mtype=""
      if [ "$CURATE" -eq 1 ] && [ "$settled" -eq 1 ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          if [[ $line =~ $TYPE_RE ]]; then mtype=${BASH_REMATCH[1]}; break; fi
        done 2>/dev/null < "$f"
      fi
      if [ "$mtype" = "project" ] \
         && case "$OPEN_FILES" in *"$NL$base$NL"*) false ;; *) true ;; esac \
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
    case "$OPEN_FILES" in *"$NL$base$NL"*) ;; *) continue ;; esac
    if [ "$waived" -eq 0 ]; then
      age_days "$f"; age=$AGE
      # Advisory context for the skill, which reads the file itself anyway — so
      # bias to high signal over completeness. Standards tokens (SHA-256,
      # ISO-8601) match the Jira-key shape but are never tickets, and a file
      # citing thirty PRs produces an unreadable line, so cap the list.
      ids=""; id_count=0
      case "$IDS" in
        *"$NL$base$TAB"*)
          rest=${IDS#*"$NL$base$TAB"}
          while :; do
            id_count=$((id_count + 1))
            [ "$id_count" -le 8 ] && ids="$ids${ids:+ }${rest%%"$NL"*}"
            rest=${rest#*"$NL"}
            case "$rest" in "$base$TAB"*) rest=${rest#"$base$TAB"} ;; *) break ;; esac
          done ;;
      esac
      [ "$id_count" -gt 8 ] && ids="$ids …and $((id_count - 8)) more"
      note="${age}d old, asserts open state"
      case "$CLOSED_FILES" in
        *"$NL$base$NL"*) note="$note; ALSO claims closed state (self-contradictory)" ;;
      esac
      [ -n "$ids" ] && note="$note; refs: $ids"
      emit TRIAGE "$slug" "$base" "$note"
    fi
  done
}

[ "$AS_JSON" -eq 0 ] && [ "$JIRA_KEYS" -eq 0 ] && {
  echo "Checking memories against external truth."
  if [ "$OFFLINE" -eq 1 ]; then echo "NOTE: --offline: GitHub claims are SKIPped, not looked up."
  elif [ "$HAVE_GH" -eq 0 ]; then echo "NOTE: gh unavailable or unauthenticated — GitHub claims will be SKIPped."; fi
}

STORES_SCANNED=0
: > "$TMP_DIR/jira-keys"
for store in "$PROJECTS"/*; do
  [ -d "$store/memory" ] || continue
  slug=${store##*/}
  [ -n "$ONLY_STORE" ] && [ "$slug" != "$ONLY_STORE" ] && continue
  STORES_SCANNED=$((STORES_SCANNED+1))
  if [ "$JIRA_KEYS" -eq 1 ]; then
    store_prepass "" "$store/memory"/*.md >> "$TMP_DIR/jira-keys"
    continue
  fi
  scan_store "$store/memory" "$slug"
  scan_index "$store/memory" "$slug"
  scan_index_size "$store/memory" "$slug"
  scan_index_hooks "$store/memory" "$slug"
  scan_orphans "$store/memory" "$slug"
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

# A key JQL would reject (lowercase, no number) is left out rather than
# breaking the whole search it would sit in.
if [ "$JIRA_KEYS" -eq 1 ]; then
  grep -E '^[A-Z][A-Z0-9_]*-[0-9]+$' "$TMP_DIR/jira-keys" | LC_ALL=C sort -t- -k1,1 -k2,2n -u \
    | awk '{ k[n++] = $0 }
           END { for (i = 0; i < n; i += 50) {
                   s = "key in ("; for (j = i; j < n && j < i + 50; j++) s = s (j > i ? ", " : "") k[j]
                   print s ")" } }'
  exit 0
fi

flush_json
if [ "$AS_JSON" -eq 0 ]; then
  echo ""
  echo "--- Results: $N_STALE stale, $N_TRIAGE triage, $N_NEEDS_MCP need-mcp, $N_SKIP skipped, $N_VERIFIED verified, $N_OVERSIZE oversize, $N_SETTLED settled, $N_CANDIDATE candidates, $N_HOOK thin-hooks, $N_ORPHAN orphans, $N_WAIVED waived"
  [ "$N_TRIAGE" -gt 0 ] && echo "Run /memory-audit to resolve the TRIAGE entries and give them verify: blocks."
  if [ "$N_OVERSIZE" -gt 0 ] && [ "$CURATE" -eq 0 ]; then
    echo "The index is over its load limit, so its tail is dropped at session start."
    echo "One line per memory, so shortening hooks cannot fix the LINE limit. Order the"
    echo "index by type first, so what falls off is cheap, then retire settled entries."
  fi
fi

[ "$N_STALE" -gt 0 ] && exit 1
[ $((N_TRIAGE + N_SKIP + N_NEEDS_MCP + N_OVERSIZE + N_ORPHAN)) -gt 0 ] && exit 2
exit 0
