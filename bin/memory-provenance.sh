#!/usr/bin/env bash
# Answers "who wrote this memory, and when?" — and the question that matters
# more: "which memories did THIS session write?"
#
# A memory file records what is believed, never who came to believe it. There is
# no author field in the body and no per-section date, so a paragraph a peer
# session appended twenty minutes ago is textually indistinguishable from one
# that has survived months of contact. With several sessions running, they all
# write to the store they all read from.
#
# That is a different defect from staleness, and worse in one specific way.
# Staleness means a memory was true once and aged out. This means a memory may
# never have been independently established at all — and it can manufacture
# agreement. The failure it produces: a session reports a finding, you check the
# store, the store agrees, and you report a claim as corroborated from two
# directions. It was one direction. That session wrote the memory an hour
# earlier, and before its edit the memory said the opposite. Two sources that
# are one source is worse than one source, because it licenses a confidence
# nothing earned.
#
# The data to prevent that is already on disk and simply never surfaced:
#
#   <store>/*.md                  metadata.originSessionId, metadata.modified
#   ~/.claude/jobs/*/state.json   sessionId -> the session's name
#
# So `--session "<name>"` answers, before you cite anything: did the session
# that just told me this also write the memory I am about to cite as agreement?
#
# Read-only by contract: reads memories and job records, writes nothing, and
# makes no network call.
#
# Usage:  bash memory-provenance.sh [--store SLUG] [--session NAME] [--anon] [--json]
#   --store SLUG    only this store (default: every store under ~/.claude/projects)
#   --session NAME  only memories written by sessions whose name contains NAME —
#                   the corroboration check
#   --anon          only memories that cannot be attributed at all
#   --json          one JSON object per memory
#
# Findings:
#   BY          attributed to a named session
#   UNRESOLVED  carries an originSessionId with no matching job record — written
#               from an interactive session, or the record aged out. Still a real
#               id, so two memories sharing it still share an author.
#   ANON        no originSessionId. Cannot be attributed, and cannot be excluded
#               as a source. Treat as unverified provenance, not as neutral.
#   DERIVED     attributed, but the origin was RECOVERED from transcripts by
#               memory-fix --provenance rather than stamped at write time. It is
#               evidence, not a record: good enough to exclude a session as an
#               independent source, not good enough to assert one. DERIVED? is
#               the same, with no job record to resolve the name.
#
# The distinction is the point. A recovered origin that rendered as BY would turn
# an inference into a fact silently, which is the failure this tool was built to
# prevent, reproduced inside the tool itself.
set -u

PROJECTS_DIR="${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}"
JOBS_DIR="${CLAUDE_SESSION_JOBS_DIR:-$HOME/.claude/jobs}"

WANT_STORE=""; WANT_SESSION=""; ONLY_ANON=0; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --store)   WANT_STORE="${2:-}"; shift 2 ;;
    --session) WANT_SESSION="${2:-}"; shift 2 ;;
    --anon)    ONLY_ANON=1; shift ;;
    --json)    AS_JSON=1; shift ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
    *) echo "memory-provenance: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "memory-provenance: jq is required" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

# ---- sessionId -> name --------------------------------------------------
: > "$TMP/jobs.jsonl"
if [ -d "$JOBS_DIR" ]; then
  for s in "$JOBS_DIR"/*/state.json; do
    [ -f "$s" ] || continue
    jq -c 'select(.sessionId != null) | {sid:.sessionId, name:(.name // "?")}' "$s" \
      2>/dev/null >> "$TMP/jobs.jsonl" || true
  done
fi

# ---- memories -----------------------------------------------------------
# One awk pass over every file rather than a sed/jq pair per memory: a corpus of
# a few hundred memories otherwise costs a thousand process spawns and takes
# minutes, which is slow enough that nobody runs it. Emitted as TSV and turned
# into JSON by a single jq, so the field values are escaped once, properly.
: > "$TMP/mem.tsv"
find "$PROJECTS_DIR" -path '*/memory/*.md' -type f -print0 2>/dev/null \
  | xargs -0 awk '
      function flush(   n, parts) {
        if (cur == "") return
        n = split(cur, parts, "/")
        # .../projects/<slug>/memory/<name>.md
        mem = parts[n]; sub(/\.md$/, "", mem)
        slug = parts[n-2]
        if (mem != "MEMORY" && mem != "MEMORY_ARCHIVE" && mem != "ARCHIVE" \
            && (want == "" || slug == want))
          printf "%s\t%s\t%s\t%s\t%s\n", slug, mem, sid, mod, src
      }
      FNR == 1 { flush(); cur = FILENAME; sid = ""; mod = ""; src = "" }
      # Frontmatter only. A UUID quoted in the body is a reference, not provenance.
      FNR <= 25 && sid == "" && /^[[:space:]]*originSessionId:[[:space:]]*/ {
        sid = $0; sub(/^[^:]*:[[:space:]]*/, "", sid); gsub(/["'"'"'[:space:]]/, "", sid)
      }
      FNR <= 25 && mod == "" && /^[[:space:]]*modified:[[:space:]]*/ {
        mod = $0; sub(/^[^:]*:[[:space:]]*/, "", mod); gsub(/["'"'"'[:space:]]/, "", mod)
      }
      # originSessionId_source marks an origin RECOVERED from transcripts rather
      # than stamped by Claude Code at write time. Without reading it, a derived
      # origin renders identically to a first-party one -- which erases the exact
      # distinction the label was added to preserve, and quietly upgrades an
      # inference into a fact.
      FNR <= 25 && src == "" && /^[[:space:]]*originSessionId_source:[[:space:]]*/ {
        src = $0; sub(/^[^:]*:[[:space:]]*/, "", src); gsub(/["'"'"'[:space:]]/, "", src)
      }
      END { flush() }
    ' want="$WANT_STORE" >> "$TMP/mem.tsv" || true

: > "$TMP/mem.jsonl"
if [ -s "$TMP/mem.tsv" ]; then
  jq -R -c 'split("\t")
            | {store:.[0], memory:.[1], sid:(.[2] // ""),
               modified:(.[3] // ""), src:(.[4] // "")}' \
    "$TMP/mem.tsv" > "$TMP/mem.jsonl" 2>/dev/null || : > "$TMP/mem.jsonl"
fi

jq -rn \
  --slurpfile mem  "$TMP/mem.jsonl" \
  --slurpfile jobs "$TMP/jobs.jsonl" \
  --arg want_session "$WANT_SESSION" \
  --argjson only_anon "$ONLY_ANON" --argjson as_json "$AS_JSON" '
  ($jobs | map({key:.sid, value:.name}) | from_entries) as $byid

  | ($mem | map(
      . as $m
      | (if ($m.sid == "") then null else ($byid[$m.sid] // null) end) as $name
      # A recovered origin is evidence, not a stamp. Classifying it as BY would
      # make an inference indistinguishable from a fact Claude Code recorded at
      # write time -- and this tool exists precisely to keep sources apart.
      | ($m.src != "") as $derived
      | {store:$m.store, memory:$m.memory, modified:$m.modified,
         sid:$m.sid, session:$name, src:$m.src, derived:$derived,
         finding:(if $m.sid == "" then "ANON"
                  elif $name == null then (if $derived then "DERIVED?" else "UNRESOLVED" end)
                  else (if $derived then "DERIVED" else "BY" end) end)}
    )) as $all

  | ($all
     | map(select($only_anon == 0 or .finding == "ANON"))
     | map(select($want_session == "" or ((.session // "") | ascii_downcase
                   | contains($want_session | ascii_downcase))))
     | sort_by([.finding, (.modified // "")]) ) as $rows

  | if $as_json == 1 then ($rows[] | tojson)
    else
      (if ($rows|length) == 0 then "  (nothing to report)"
       else ($rows[] |
         "  \((.finding + "            ")[0:11])\(.memory)"
         + (if .session then "   by \"\(.session)\"" else "" end)
         + (if (.modified // "") != "" then "   \(.modified[0:10])" else "" end))
       end),
      "",
      # Report the count for what was actually listed. A filtered run that prints
      # the corpus-wide total invites the reader to take a number that answers a
      # different question than the one they asked.
      ( (($want_session != "") or ($only_anon == 1)) as $filtered
      | ($all | length) as $t
      | ($all | map(select(.finding=="BY"))|length) as $b
      | ($all | map(select(.finding=="ANON"))|length) as $a
      | if $filtered then
          "  \($rows|length) matched, of \($t) memories scanned. "
          + (if $want_session != "" then
               "Anything this session wrote is not independent of what it tells you."
             else
               "These carry no origin at all, so they can neither be attributed nor excluded."
             end)
        else
          ($all | map(select(.derived)) | length) as $d
          | "  \($b) of \($t) stamped at write time"
            + (if $d > 0 then ", \($d) recovered from transcripts" else "" end)
            + ", \($a) anonymous. "
            + "An ANON memory cannot be ruled out as a source, so it is not neutral evidence."
            + (if $d > 0 then
                 " A DERIVED origin is evidence, not a record: enough to exclude a session, not to assert one."
               else "" end)
        end
      )
    end
'
