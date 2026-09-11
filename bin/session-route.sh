#!/usr/bin/env bash
# Resolves a PR to the Claude Code session that raised it.
#
# Why this exists: in a single-author repo the PR author field carries zero bits
# — every PR has the same author — so it can never say which session owns a PR.
# Sessions get routed by NAME instead, and that name is usually auto-derived
# from the session's opening prompt. Which works right up until a session is
# opened with a prompt carrying no ticket or PR number: then the PR is silently
# unaddressable. Nothing errors. The review just never reaches the session
# holding the authoring context, and someone re-derives it from scratch.
#
# The exact answer is already on disk, in two files nothing joins:
#
#   ~/.claude/projects/*/*.jsonl   {"type":"pr-link", prNumber, prRepository, sessionId}
#                                  written by Claude Code when a session raises a PR
#   ~/.claude/jobs/*/state.json    {sessionId, name, nameSource, state, updatedAt}
#                                  written for each background session
#
# pr-link gives PR -> sessionId. state.json gives sessionId -> name. This joins
# them, so routing stops being a name-guess and becomes a lookup.
#
# LIVENESS IS NOT DECIDED HERE. A shell script cannot call ListAgents, so the
# state column is last-known job state, never proof a session is reachable now.
# Resolve the name here, then confirm with ListAgents before sending: a session
# started under a different project root is absent from the peer list while its
# job record still looks perfectly healthy.
#
# Read-only by contract: reads transcripts and job state, writes nothing,
# makes no network call.
#
# Usage:  bash session-route.sh [--pr N] [--repo OWNER/NAME] [--unrouted] [--json]
#   --pr N        just this PR number
#   --repo R      only PRs whose repository contains R
#   --unrouted    only findings that cannot be addressed — the actionable set
#   --json        one JSON object per finding
#
# A PR usually carries pr-link records from SEVERAL sessions: Claude Code writes
# one whenever a session links the PR, not only when it raises one. So a reviewer
# session, a monitor, and the author all leave records. The disambiguator is
# time — the raiser links it first, by hours. Validated against a case with known
# ground truth: on #1620 the true owner linked at 2026-08-26T22:28Z and the
# session that wrongly commented linked 19 hours later, and earliest-wins picks
# the owner. Ties are not handled because millisecond timestamps do not tie.
#
# Findings, each meaning exactly one thing:
#   ROUTE       resolved to the session that linked it first — the raiser
#   NO_SESSION  the earliest linker has no job record, so the raiser is
#               unreachable from here. Any later session named in the note
#               merely touched the PR and is NOT the owner — routing to it is
#               the mistake this tool exists to prevent.
#   NO_RECORD   --pr named a PR with no pr-link record at all
#
# A ROUTE whose session name contains no digit is tagged `weak-name`: it
# resolved, but nothing in that name would let anyone find it from a branch or
# a ticket. Those are the sessions worth renaming.
set -u

PROJECTS_DIR="${CLAUDE_SESSION_PROJECTS_DIR:-$HOME/.claude/projects}"
JOBS_DIR="${CLAUDE_SESSION_JOBS_DIR:-$HOME/.claude/jobs}"

WANT_PR=""; WANT_REPO=""; ONLY_UNROUTED=0; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)       WANT_PR="${2:-}"; shift 2 ;;
    --repo)     WANT_REPO="${2:-}"; shift 2 ;;
    --unrouted) ONLY_UNROUTED=1; shift ;;
    --json)     AS_JSON=1; shift ;;
    -h|--help)  sed -n '2,47p' "$0"; exit 0 ;;
    *) echo "session-route: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "session-route: jq is required" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# ---- PR -> sessionId, from the transcripts -----------------------------
# grep first: transcripts run to hundreds of megabytes and only a handful of
# lines are pr-link records, so jq never has to parse the bulk of the file.
: > "$TMP/links.jsonl"
if [ -d "$PROJECTS_DIR" ]; then
  find "$PROJECTS_DIR" -name '*.jsonl' -type f -print0 2>/dev/null \
    | xargs -0 grep -h '"type":"pr-link"' 2>/dev/null \
    | jq -c 'select(.type=="pr-link")
             | {pr:.prNumber, repo:.prRepository, sid:.sessionId, ts:.timestamp}' \
      2>/dev/null >> "$TMP/links.jsonl" || true
fi

# ---- sessionId -> name, from the job records ---------------------------
: > "$TMP/jobs.jsonl"
if [ -d "$JOBS_DIR" ]; then
  for s in "$JOBS_DIR"/*/state.json; do
    [ -f "$s" ] || continue
    jq -c '{sid:.sessionId, name:.name, src:(.nameSource//"?"),
            state:(.state//"?"), seen:(.updatedAt//"")}' "$s" \
      2>/dev/null >> "$TMP/jobs.jsonl" || true
  done
fi

# ---- join ---------------------------------------------------------------
jq -rn \
  --slurpfile links "$TMP/links.jsonl" \
  --slurpfile jobs  "$TMP/jobs.jsonl" \
  --arg want_pr "$WANT_PR" --arg want_repo "$WANT_REPO" \
  --argjson only_unrouted "$ONLY_UNROUTED" --argjson as_json "$AS_JSON" '
  ($jobs | map(select(.sid != null) | {key:.sid, value:.}) | from_entries) as $byid

  | ($links
     | map(select(($want_repo=="" or ((.repo//"")|contains($want_repo)))
                  and ($want_pr=="" or ((.pr|tostring)==$want_pr))))
     | group_by([.repo, .pr])
     | map({ repo:(.[0].repo//"?"), pr:(.[0].pr),
             # one entry per session, earliest link first: [0] is the raiser
             seq:( group_by(.sid)
                   | map({sid:(.[0].sid), first:(map(.ts)|min)})
                   | sort_by(.first) ) })) as $prs

  | ( if ($want_pr != "" and ($prs|length) == 0)
      then [{finding:"NO_RECORD", repo:$want_repo, pr:$want_pr, session:null,
             note:"no pr-link record — nothing to address"}]
      else ($prs | map(
          . as $p
          | ($p.seq | map(. + {job:$byid[.sid]})) as $seq
          | ($seq[0]) as $raiser
          | ($seq | map(select(.job != null))) as $known
          | (($seq|length) - 1) as $others
          | if ($known|length) == 0 then
              {finding:"NO_SESSION", repo:$p.repo, pr:$p.pr, session:null,
               note:"no linking session has a job record"}
            elif ($raiser.job == null) then
              {finding:"NO_SESSION", repo:$p.repo, pr:$p.pr, session:null,
               note:("raiser " + ($raiser.sid[0:8]) + " has no job record; \""
                     + ($known[0].job.name//"?") + "\" only touched it later — not the owner")}
            else
              ($raiser.job) as $j
              | {finding:"ROUTE", repo:$p.repo, pr:$p.pr, session:($j.name//"?"),
                 state:$j.state, src:$j.src, seen:$raiser.first,
                 note:(((if (($j.name//"")|test("[0-9]")) then [] else ["weak-name"] end)
                        + (if $others > 0 then ["+\($others) touched"] else [] end))
                       | join(", "))}
            end))
      end ) as $out

  | ($out | map(select($only_unrouted == 0 or .finding != "ROUTE"))
          | sort_by([.finding, -((.pr|tonumber?) // 0)])) as $rows

  | if $as_json == 1 then ($rows[] | tojson)
    else
      (if ($rows|length) == 0 then "  (nothing to report)"
       else ($rows[] |
         "  \((.finding + "          ")[0:11])\(((.repo//"?")|split("/")|last)) #\(.pr)"
         + (if .session then "  ->  \(.session)" else "" end)
         + (if (.note//"") != "" then "   [\(.note)]" else "" end))
       end),
      "",
      "  \($rows|map(select(.finding=="ROUTE"))|length) routable, "
      + "\($rows|map(select(.finding!="ROUTE"))|length) not. "
      + "Confirm liveness with ListAgents before sending — a job record is not a peer list."
    end
'
