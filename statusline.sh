#!/usr/bin/env bash
# Single-jq statusline: one jq pass formats everything except the git branch
# (resolved subprocess-free from .git/HEAD, worktree-aware) and the plan link
# (from the session pointer file). No external tools, no git subprocess.
# model │ repo:branch │ context bar+% │ tokens │ cost │ [rate limits] │ plan
export PATH="/opt/homebrew/bin:$PATH"
exec 2>/dev/null

INPUT=$(cat)

# One jq pass -> TAB-separated: <formatted line w/ __BR__ token>\t<session_id>\t<current_dir>
IFS=$'\t' read -r LINE SID CDIR < <(printf '%s' "$INPUT" | jq -r '
  def fmt: if . >= 1000000 then "\(./1000000*10|floor/10)M"
           elif . >= 1000 then "\(./1000*10|floor/10)k" else "\(.)" end;
  (.model.display_name // "...") as $model |
  (.workspace.repo.name // ((.workspace.project_dir // .workspace.current_dir // .cwd // "") | split("/") | last) // "") as $repo |
  ((.context_window.used_percentage // 0) | floor) as $pct |
  (.cost.total_cost_usd // 0) as $cost |
  (.context_window.current_usage.input_tokens // 0) as $in |
  (.context_window.current_usage.output_tokens // 0) as $out |
  (.context_window.current_usage.cache_read_input_tokens // 0) as $cache |
  (.rate_limits.five_hour.used_percentage) as $r5 |
  (.rate_limits.seven_day.used_percentage) as $r7 |
  (if $pct >= 70 then "\u001b[91m" elif $pct >= 50 then "\u001b[33m" else "\u001b[32m" end) as $c |
  "\u001b[0m" as $r | "\u001b[38;5;248m" as $dim | "\u001b[36m" as $cy |
  ([$pct / 10 | floor, 0] | max) as $f |
  ([10 - $f, 0] | max) as $e |
  (("▓" * $f) + ("░" * $e)) as $bar |
  (if $pct >= 80 then " \($c)USE /compact\($r)" elif $pct >= 70 then " \($c)⚠\($r)" else "" end) as $warn |
  (if $r5 != null then " │ \($dim)5h:\($r5|floor)% 7d:\(($r7 // 0)|floor)%\($r)" else "" end) as $rl |
  "\($model) │ \($cy)\($repo)__BR__\($r) │ \($c)\($bar)\($r) \($pct)%\($warn) │ \($dim)in:\($in|fmt) out:\($out|fmt) cache:\($cache|fmt)\($r) │ $\($cost * 100 | floor / 100)\($rl)"
  + "\t" + (.session_id // "") + "\t" + (.workspace.current_dir // .cwd // "")
')

# Git branch without a subprocess: walk up for .git (dir, or worktree pointer
# file), then read HEAD. Falls back to a short SHA when detached.
branch=""; gitdir=""; d="$CDIR"
while [[ -n "$d" && "$d" != "/" ]]; do
  if [[ -d "$d/.git" ]]; then gitdir="$d/.git"; break
  elif [[ -f "$d/.git" ]]; then read -r _ gitdir < "$d/.git"; break; fi
  d="${d%/*}"
done
if [[ -n "$gitdir" && -f "$gitdir/HEAD" ]]; then
  read -r ref < "$gitdir/HEAD"
  if [[ "$ref" == ref:* ]]; then branch="${ref#ref: refs/heads/}"; else branch="${ref:0:7}"; fi
fi
if [[ -n "$branch" ]]; then LINE="${LINE/__BR__/:$branch}"; else LINE="${LINE/__BR__/}"; fi

# Plan link (OSC-8) to this session's latest rendered plan, if a live pointer exists.
PLAN_SEG=""
if [[ -n "$SID" ]]; then
  PTR="${CLAUDE_PLAN_STATE_DIR:-$HOME/.claude/state/plans}/$SID.path"
  if [[ -f "$PTR" ]]; then
    read -r PLAN < "$PTR"
    if [[ -n "$PLAN" && -f "$PLAN" ]]; then
      PLAN_SEG=$(printf ' │ \033]8;;file://%s\033\\\342\224\200 \360\237\223\204 plan\033]8;;\033\\' "$PLAN")
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
      WF_SEG=$(printf ' │ \033]8;;%s%s\033\\\342\224\200 \342\232\231 wf\033]8;;\033\\' "$ed" "$WF")
    fi
  fi
fi

printf '%s%s%s\n' "$LINE" "$PLAN_SEG" "$WF_SEG"
