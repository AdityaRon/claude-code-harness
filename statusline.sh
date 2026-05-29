#!/usr/bin/env bash
# Single-process statusline — parsing/formatting done in one jq call.
# Shows: model │ context bar + % │ tokens (in/out/cache) │ cost │ ‹ plan link ›
# The plan segment is an OSC-8 hyperlink to this session's most recently
# rendered plan HTML (written by plan-to-html.sh), so it is one click to review.
export PATH="/opt/homebrew/bin:$PATH"
exec 2>/dev/null

INPUT=$(cat)

# Clickable link to this session's latest rendered plan, if one exists.
PLAN_SEG=""
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
if [[ -n "$SID" ]]; then
  PTR="${CLAUDE_PLAN_STATE_DIR:-$HOME/.claude/state/plans}/$SID.path"
  if [[ -f "$PTR" ]]; then
    PLAN=$(cat "$PTR")
    if [[ -n "$PLAN" && -f "$PLAN" ]]; then
      # OSC-8 hyperlink: ESC ] 8 ;; file://<path> ESC \  <label>  ESC ] 8 ;; ESC \
      PLAN_SEG=$(printf ' │ \033]8;;file://%s\033\\\342\224\200 \360\237\223\204 plan\033]8;;\033\\' "$PLAN")
    fi
  fi
fi

LINE=$(printf '%s' "$INPUT" | jq -r '
  def fmt: if . >= 1000000 then "\(. / 1000000 * 10 | floor / 10)M"
           elif . >= 1000 then "\(. / 1000 * 10 | floor / 10)k"
           else "\(.)" end;

  (.model.display_name // "...") as $model |
  ((.context_window.used_percentage // 0) | floor) as $pct |
  (.cost.total_cost_usd // 0) as $cost |
  (.context_window.current_usage.input_tokens // 0) as $in |
  (.context_window.current_usage.output_tokens // 0) as $out |
  (.context_window.current_usage.cache_read_input_tokens // 0) as $cache |

  # color: green <50, yellow <70, red >=70
  (if $pct >= 70 then "\u001b[91m" elif $pct >= 50 then "\u001b[33m" else "\u001b[32m" end) as $c |
  "\u001b[0m" as $r |

  # bar: 10 chars
  ([$pct / 10 | floor, 0] | max) as $filled |
  ([10 - $filled, 0] | max) as $empty |
  ("▓" * $filled + "░" * $empty) as $bar |

  # warning at high usage
  (if $pct >= 80 then " \($c)USE /compact\($r)"
   elif $pct >= 70 then " \($c)⚠\($r)"
   else "" end) as $warn |

  "\($model) │ \($c)\($bar)\($r) \($pct)%\($warn) │ in:\($in | fmt) out:\($out | fmt) cache:\($cache | fmt) │ $\($cost * 100 | floor / 100)"
')
printf '%s%s\n' "$LINE" "$PLAN_SEG"
