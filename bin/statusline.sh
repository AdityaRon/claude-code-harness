#!/usr/bin/env bash
# Single-jq statusline: one jq pass formats everything except the git branch
# (resolved subprocess-free from .git/HEAD, worktree-aware) and the plan/wf
# links (from session pointer files). No git subprocess, no external tools
# beyond jq. Degrades gracefully when fields — or jq — are missing.
# model │ repo:branch │ context bar+% │ tokens │ $cost·dur │ +/-lines │ [style] │ [rate] │ plan │ wf
export PATH="/opt/homebrew/bin:$PATH"
# Silence stderr in normal use; set CLAUDE_STATUSLINE_DEBUG=1 to see errors.
[[ -z "${CLAUDE_STATUSLINE_DEBUG:-}" ]] && exec 2>/dev/null

INPUT=$(cat)

# One jq pass -> US-separated (, a non-whitespace delimiter so empty
# fields aren't collapsed by read): <formatted line w/ __BR__>\x1f<sid>\x1f<cdir>
_JQOUT=$(printf '%s' "$INPUT" | jq -r '
  def fmt: if . >= 1000000 then "\(./1000000*10|floor/10)M"
           elif . >= 1000 then "\(./1000*10|floor/10)k" else "\(.)" end;
  (.model.display_name // "...") as $model |
  (.workspace.repo.name
    // ((.workspace.project_dir // .workspace.current_dir // .cwd // "") | rtrimstr("/") | split("/") | last)
    // "") as $repo |
  ((.context_window.used_percentage // 0) | floor) as $pct |
  (.cost.total_cost_usd // 0) as $cost |
  (.context_window.current_usage.input_tokens // 0) as $in |
  (.context_window.current_usage.output_tokens // 0) as $out |
  (.context_window.current_usage.cache_read_input_tokens // 0) as $cache |
  (.cost.total_lines_added // 0) as $la |
  (.cost.total_lines_removed // 0) as $lr |
  (.cost.total_duration_ms // 0) as $ms |
  (.output_style.name) as $os |
  (.rate_limits.five_hour.used_percentage) as $r5 |
  (.rate_limits.seven_day.used_percentage) as $r7 |
  "[0m" as $r | "[38;5;248m" as $dim | "[36m" as $cy |
  "[32m" as $grn | "[31m" as $red | "[33m" as $yel |
  (if $pct >= 70 then $red elif $pct >= 50 then $yel else $grn end) as $c |
  ([([$pct / 10 | floor, 0] | max), 10] | min) as $f |
  (10 - $f) as $e |
  (("▓" * $f) + ("░" * $e)) as $bar |
  (if $pct >= 80 then " \($c)USE /compact\($r)" elif $pct >= 70 then " \($c)⚠\($r)" else "" end) as $warn |
  # Cost: round to cents, always two decimals, stable width. On a subscription
  # (rate_limits present) total_cost_usd is an estimated API-equivalent, not
  # real spend, so prefix "~$" to signal that; plain "$" for API accounts.
  (($cost * 100 | . + 0.5 | floor)) as $cc |
  (if (.rate_limits.five_hour.used_percentage != null or .rate_limits.seven_day.used_percentage != null) then "~$" else "$" end) as $csym |
  "\($csym)\($cc / 100 | floor).\($cc % 100 | if . < 10 then "0\(.)" else "\(.)" end)" as $costs |
  # Session wall-clock, minute granularity, hidden under a minute.
  ($ms / 60000 | floor) as $min |
  (if $min >= 60 then " \($dim)·\($r) \($dim)\($min / 60 | floor)h\($min % 60)m\($r)"
   elif $min >= 1 then " \($dim)·\($r) \($dim)\($min)m\($r)" else "" end) as $dur |
  # Lines added/removed — the clearest "did work happen" signal. Hidden at 0/0.
  (if ($la > 0 or $lr > 0) then " │ \($grn)+\($la)\($r)/\($red)-\($lr)\($r)" else "" end) as $lines |
  # Non-default output style is easy to forget you are in — surface it.
  (if ($os != null and $os != "default" and $os != "") then " │ \($dim)style:\($os)\($r)" else "" end) as $style |
  # Rate limits: color by whichever window is closer to the cap; show if either present.
  ([($r5 // 0), ($r7 // 0)] | max) as $rmax |
  (if $rmax >= 90 then $red elif $rmax >= 70 then $yel else $dim end) as $rc |
  (if ($r5 != null or $r7 != null) then " │ \($rc)5h:\(($r5 // 0)|floor)% 7d:\(($r7 // 0)|floor)%\($r)" else "" end) as $rl |
  "\($model) │ \($cy)\($repo)__BR__\($r) │ \($c)\($bar)\($r) \($pct)%\($warn) │ \($dim)in:\($in|fmt) out:\($out|fmt) cache:\($cache|fmt)\($r) │ \($costs)\($dur)\($lines)\($style)\($rl)"
  + "" + (.session_id // "") + "" + (.workspace.current_dir // .cwd // "")
')
IFS=$'\x1f' read -r LINE SID CDIR <<< "$_JQOUT"

# jq missing or unparseable input -> fail visible-but-calm, never blank.
[[ -n "$LINE" ]] || { printf 'Claude Code\n'; exit 0; }

# Git branch without a subprocess: walk up for .git (dir, or worktree/submodule
# pointer file), then read HEAD. Falls back to a short SHA when detached.
branch=""; gitdir=""; d="$CDIR"
while [[ -n "$d" && "$d" != "/" ]]; do
  if [[ -d "$d/.git" ]]; then gitdir="$d/.git"; break
  elif [[ -f "$d/.git" ]]; then
    read -r _ gitdir < "$d/.git"
    # Submodules write a RELATIVE gitdir; resolve it against the .git location.
    [[ -n "$gitdir" && "$gitdir" != /* ]] && gitdir="$d/$gitdir"
    break
  fi
  d="${d%/*}"
done
if [[ -n "$gitdir" && -f "$gitdir/HEAD" ]]; then
  read -r ref < "$gitdir/HEAD"
  if [[ "$ref" == ref:* ]]; then branch="${ref#ref: refs/heads/}"; else branch="${ref:0:7}"; fi
fi
if [[ -n "$branch" ]]; then LINE="${LINE/__BR__/:$branch}"; else LINE="${LINE/__BR__/}"; fi

# Percent-escape a filesystem path for safe embedding in an OSC-8 URI
# (spaces and % break links in many terminals/editors). Pure bash.
uri_escape() { local p="$1"; p="${p//%/%25}"; p="${p// /%20}"; printf '%s' "$p"; }

# Plan link (OSC-8) to this session's latest rendered plan, if a live pointer exists.
PLAN_SEG=""
if [[ -n "$SID" ]]; then
  PTR="${CLAUDE_PLAN_STATE_DIR:-$HOME/.claude/state/plans}/$SID.path"
  if [[ -f "$PTR" ]]; then
    read -r PLAN < "$PTR"
    if [[ -n "$PLAN" && -f "$PLAN" ]]; then
      PLAN_SEG=$(printf ' │ \033]8;;file://%s\033\\\342\224\200 \360\237\223\204 plan\033]8;;\033\\' "$(uri_escape "$PLAN")")
    fi
  fi
fi

# Workflow link (OSC-8) to this session's latest run script, if a pointer exists.
WF_SEG=""
if [[ -n "$SID" ]]; then
  WPTR="${CLAUDE_WORKFLOW_STATE_DIR:-$HOME/.claude/state/workflows}/$SID.path"
  if [[ -f "$WPTR" ]]; then
    read -r WF < "$WPTR"
    if [[ -n "$WF" && -f "$WF" ]]; then
      # Open workflow scripts (code) in a text editor, not the .js default app.
      # Honor CLAUDE_EDITOR_URI, else auto-detect an installed GUI editor.
      ed="${CLAUDE_EDITOR_URI:-}"
      if [[ -z "$ed" ]]; then
        if [[ -d "/Applications/Visual Studio Code.app" ]]; then ed="vscode://file"
        elif [[ -d "/Applications/Cursor.app" ]]; then ed="cursor://file"
        elif [[ -d "/Applications/Zed.app" ]]; then ed="zed://file"
        else ed="file://"; fi
      fi
      WF_SEG=$(printf ' │ \033]8;;%s%s\033\\\342\224\200 \342\232\231 wf\033]8;;\033\\' "$ed" "$(uri_escape "$WF")")
    fi
  fi
fi

printf '%s%s%s\n' "$LINE" "$PLAN_SEG" "$WF_SEG"
