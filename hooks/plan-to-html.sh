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
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css">
<style>
  :root{
    --bg:#0d1117; --panel:#161b22; --panel2:#1c2430; --border:#30363d;
    --fg:#e6edf3; --muted:#9da7b3; --accent:#58a6ff; --green:#3fb950;
    --amber:#d29922; --red:#f85149; --purple:#bc8cff; --orange:#ffa657;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
    font:15.5px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  .wrap{max-width:900px;margin:0 auto;padding:40px 28px 90px;}
  .meta{color:var(--muted);font-size:12.5px;letter-spacing:.02em;margin-bottom:26px;
    border-bottom:1px solid var(--border);padding-bottom:14px}
  h1{font-size:30px;line-height:1.25;margin:0 0 14px;letter-spacing:-.02em}
  h2{font-size:21px;margin:38px 0 14px;padding-bottom:8px;border-bottom:1px solid var(--border)}
  h3{font-size:16.5px;margin:24px 0 8px;color:var(--purple)}
  h4{font-size:14.5px;margin:18px 0 6px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  p,li{margin:9px 0}
  ul,ol{padding-left:24px}
  strong{color:#fff}
  code{background:var(--panel2);color:var(--orange);padding:2px 6px;border-radius:5px;
    font:13px/1.5 "SF Mono",ui-monospace,Menlo,Consolas,monospace}
  pre{background:var(--panel);border:1px solid var(--border);border-radius:10px;
    padding:14px 16px;overflow-x:auto;margin:14px 0}
  pre code{background:none;padding:0;font-size:13px}
  blockquote{border-left:3px solid var(--accent);background:rgba(88,166,255,.07);
    padding:12px 18px;border-radius:0 8px 8px 0;margin:16px 0;color:var(--fg)}
  blockquote p{margin:6px 0}
  table{width:100%;border-collapse:collapse;margin:16px 0;font-size:14px}
  th,td{border:1px solid var(--border);padding:8px 12px;text-align:left;vertical-align:top}
  th{background:var(--panel);font-weight:600}
  tr:nth-child(even) td{background:rgba(255,255,255,.02)}
  hr{border:none;border-top:1px solid var(--border);margin:28px 0}
  .fallback{white-space:pre-wrap;word-wrap:break-word;color:var(--fg)}
</style>
</head>
<body>
<div class="wrap">
<div class="meta">Plan rendered $ts · Claude Code harness</div>
<article id="content"></article>
</div>
<script>
  var bytes = Uint8Array.from(atob("$b64"), function (c) { return c.charCodeAt(0); });
  var md = new TextDecoder("utf-8").decode(bytes);
  var el = document.getElementById("content");
  // Render with marked when the CDN is reachable; otherwise show readable raw
  // markdown so the plan is never lost when offline.
  if (window.marked && typeof marked.parse === "function") {
    el.innerHTML = marked.parse(md);
    // Syntax-highlight fenced code blocks when highlight.js is available.
    if (window.hljs) {
      document.querySelectorAll("pre code").forEach(function (b) { hljs.highlightElement(b); });
    }
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
