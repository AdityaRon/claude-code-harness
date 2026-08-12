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

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --json)  AS_JSON=1; shift ;;
    --all)   SHOW_ALL=1; shift ;;
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
N_VERIFIED=0
HEADER_SHOWN=""

# Emit one finding. Fields are positional to stay bash-3.2 friendly.
emit() {
  local status="$1" store="$2" file="$3" detail="$4"
  case "$status" in
    STALE)    N_STALE=$((N_STALE+1)) ;;
    TRIAGE)   N_TRIAGE=$((N_TRIAGE+1)) ;;
    SKIP)     N_SKIP=$((N_SKIP+1)) ;;
    VERIFIED) N_VERIFIED=$((N_VERIFIED+1)); [ "$SHOW_ALL" -eq 1 ] || return 0 ;;
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
    epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${stamp%%.*}" +%s 2>/dev/null) \
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
OPEN_RE='\b(pending|draft pr|awaiting|not yet (merged|deployed|landed|shipped)|blocked on|still open|will land)\b'
# Closed-state language. Co-occurrence with the above inside one file is the
# append-don't-revise contradiction: an update was added, the stale sentence
# stayed. Boundaried for the same reason, and because "unresolved" contains
# "resolved" — matching it would invert the signal entirely.
CLOSED_RE='\b(merged|shipped|deployed|landed|resolved|verified in prod)\b'

scan_store() {
  local dir="$1" slug="$2" f base claims line kind ref expected result actual age ids id_count note

  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ "$base" = "MEMORY.md" ] && continue

    claims=$(verify_lines "$f")
    if [ -n "$claims" ]; then
      # Here-string, not a pipe: a piped `while` runs in a subshell and the
      # N_* counters incremented inside it would be discarded on exit.
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        kind=$(printf '%s' "$line" | awk '{print $1}')
        ref=$(printf '%s' "$line" | awk '{print $2}')
        expected=$(printf '%s' "$line" | awk '{print $3}')
        if [ -z "$ref" ] || [ -z "$expected" ]; then
          emit SKIP "$slug" "$base" "malformed verify claim: $line"
          continue
        fi
        case "$kind" in
          gh)
            result=$(resolve_gh "$ref" "$expected")
            actual=$(printf '%s' "$result" | awk '{print $2}')
            case "$result" in
              ok*)       emit VERIFIED "$slug" "$base" "$ref is $actual, as recorded" ;;
              mismatch*) emit STALE "$slug" "$base" "$ref expected=$expected actual=$actual" ;;
              *)         emit SKIP  "$slug" "$base" "$ref $(printf '%s' "$result" | cut -d' ' -f2-)" ;;
            esac
            ;;
          jira)
            # Jira lives behind MCP, which a shell script cannot reach. The
            # skill resolves these; flagging rather than silently passing.
            emit SKIP "$slug" "$base" "$ref needs the /memory-audit skill (Jira is MCP-only)"
            ;;
          *)
            emit SKIP "$slug" "$base" "unknown verify kind '$kind'"
            ;;
        esac
      done <<< "$claims"
      continue
    fi

    # No verify block. Worth triaging only if it asserts in-flight state and
    # has had time to go stale.
    if grep -qiE "$OPEN_RE" "$f" 2>/dev/null; then
      age=$(age_days "$f")
      [ "$age" -lt "$TRIAGE_MIN_AGE_DAYS" ] && continue
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
  echo "--- Results: $N_STALE stale, $N_TRIAGE triage, $N_SKIP skipped, $N_VERIFIED verified"
  [ "$N_TRIAGE" -gt 0 ] && echo "Run /memory-audit to resolve the TRIAGE entries and give them verify: blocks."
fi

[ "$N_STALE" -gt 0 ] && exit 1
[ $((N_TRIAGE + N_SKIP)) -gt 0 ] && exit 2
exit 0
