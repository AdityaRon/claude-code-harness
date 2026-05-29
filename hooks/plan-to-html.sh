#!/usr/bin/env bash
# PreToolUse → ExitPlanMode: render the proposed plan as a styled, self-rendering
# HTML file and open it in the default browser, so a long plan can be read
# comfortably before you approve/reject it in the terminal.
#
# Side-effect only: never denies, never asks, never blocks the approval prompt
# (registered async). Bails out silently on any missing input.
#
# Env overrides:
#   CLAUDE_PLANS_HTML_DIR   output directory (default ~/.claude/plans-html)
#   CLAUDE_PLAN_HTML_NO_OPEN=1  write the file but do not launch a browser (tests)
source "$(dirname "$0")/lib.sh"

read_input

# The matcher already scopes us to ExitPlanMode, but stay defensive in case the
# hook is wired more broadly.
tool=$(jq_get '.tool_name')
[[ "$tool" == "ExitPlanMode" ]] || exit 0

plan=$(jq_get '.tool_input.plan')
[[ -n "$plan" ]] || exit 0

outdir=$(expand_tilde "${CLAUDE_PLANS_HTML_DIR:-$HOME/.claude/plans-html}")
mkdir -p "$outdir" 2>/dev/null || exit 0
ts=$(date +%Y%m%d-%H%M%S)
out="$outdir/plan-$ts.html"

# Some plans are authored as a full HTML document rather than markdown. Serve
# those verbatim: otherwise marked renders an HTML page *inside* our HTML page
# (duplicate <html>/<head>/<style>/<body>), and the plan's own body{margin:0}
# clobbers our centered layout.
if printf '%s' "$plan" | head -c 256 | grep -iqE '^[[:space:]]*<(!doctype[[:space:]]+html|html([[:space:]>]|$))'; then
  printf '%s' "$plan" > "$out"
else
# Base64-embed the markdown so no quoting/escaping can ever break the HTML, then
# decode it as UTF-8 in the browser (em-dashes, arrows, box-drawing all survive).
b64=$(printf '%s' "$plan" | base64 | tr -d '\n')
cat > "$out" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Plan — $ts</title>
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    max-width: 820px; margin: 0 auto; padding: 3rem 1.5rem 6rem;
    color: #1a1a1a; background: #fafafa;
  }
  @media (prefers-color-scheme: dark) {
    body { color: #e6e6e6; background: #161616; }
    code, pre { background: #232323 !important; }
    a { color: #6cb6ff; }
    th { background: #232323; }
    table, th, td { border-color: #333; }
  }
  h1, h2, h3 { line-height: 1.25; margin-top: 2rem; }
  h1 { border-bottom: 2px solid #8884; padding-bottom: .3rem; }
  h2 { border-bottom: 1px solid #8884; padding-bottom: .2rem; }
  code { background: #00000010; padding: .15em .4em; border-radius: 4px; font-size: .9em; }
  pre { background: #00000010; padding: 1rem; border-radius: 8px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  blockquote { border-left: 3px solid #8886; margin: 1rem 0; padding: .2rem 1rem; color: #8888; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
  th, td { border: 1px solid #ccc; padding: .5rem .75rem; text-align: left; }
  th { background: #00000008; }
  .meta { color: #8888; font-size: .85rem; margin-bottom: 2rem; }
  .fallback { white-space: pre-wrap; word-wrap: break-word; }
</style>
</head>
<body>
<div class="meta">Plan rendered $ts · Claude Code harness</div>
<article id="content"></article>
<script>
  var bytes = Uint8Array.from(atob("$b64"), function (c) { return c.charCodeAt(0); });
  var md = new TextDecoder("utf-8").decode(bytes);
  var el = document.getElementById("content");
  // Render with marked when the CDN is reachable; otherwise show readable raw
  // markdown so the plan is never lost when offline.
  if (window.marked && typeof marked.parse === "function") {
    el.innerHTML = marked.parse(md);
  } else {
    var pre = document.createElement("pre");
    pre.className = "fallback";
    pre.textContent = md;
    el.appendChild(pre);
  }
</script>
</body>
</html>
HTML
fi

# Record this session's latest plan path so the statusline can link to it.
sid=$(jq_get '.session_id')
if [[ -n "$sid" ]]; then
  pdir=$(expand_tilde "${CLAUDE_PLAN_STATE_DIR:-$HOME/.claude/state/plans}")
  if mkdir -p "$pdir" 2>/dev/null; then
    printf '%s\n' "$out" > "$pdir/$sid.path" 2>/dev/null || true
    chmod 600 "$pdir/$sid.path" 2>/dev/null || true
  fi
fi

# Retention: keep the newest 50 rendered plans.
ls -1t "$outdir"/plan-*.html 2>/dev/null | tail -n +51 | while read -r old; do
  rm -f "$old" 2>/dev/null || true
done

[[ "${CLAUDE_PLAN_HTML_NO_OPEN:-}" == "1" ]] && exit 0

if command -v open &>/dev/null; then
  open "$out" >/dev/null 2>&1 || true
elif command -v xdg-open &>/dev/null; then
  xdg-open "$out" >/dev/null 2>&1 || true
fi
exit 0
