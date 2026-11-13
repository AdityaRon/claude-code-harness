#!/usr/bin/env bash
# hooks/lib.sh sources this: network hosts: the allowlist and the problems network-guard names.

# Can this name go on the machine-local network allowlist? network-guard allows
# an entry AND every subdomain of it, so `com` would allow the internet and a
# tunnel or request-capture service would allow a host anyone can stand up to
# collect a query string. Prints why when refused; silent when fine. The lists
# are the common cases, not every one.
net_host_problem() {
  local h="$1" s
  local sinks=(webhook.site requestbin.com requestbin.net pipedream.net beeceptor.com mockbin.org
    mockbin.io hookbin.com requestcatcher.com interact.sh oast.fun oast.live oast.me oast.online
    oast.pro oast.site oastify.com burpcollaborator.net canarytokens.com ngrok.io ngrok.app
    ngrok.dev ngrok-free.app ngrok-free.dev loca.lt localtunnel.me trycloudflare.com serveo.net
    localhost.run pastebin.com transfer.sh paste.ee hastebin.com dpaste.org 0x0.st termbin.com
    ntfy.sh api.telegram.org script.google.com script.googleusercontent.com hooks.slack.com
    discord.com discordapp.com webhook.office.com zapier.com make.com ifttt.com)
  local shared=(github.io githubusercontent.com pages.dev workers.dev vercel.app netlify.app
    herokuapp.com appspot.com web.app firebaseapp.com run.app cloudfunctions.net
    azurewebsites.net blob.core.windows.net cloudfront.net amazonaws.com s3.amazonaws.com
    glitch.me repl.co replit.dev onrender.com fly.dev railway.app gitlab.io bitbucket.io
    surge.sh deno.dev val.run pythonanywhere.com ondigitalocean.app azurestaticapps.net
    r2.dev supabase.co firebaseio.com herokudns.com codeberg.page)
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { echo "not a lower-case host name with a dot (no scheme, port, path or wildcard)"; return 1; }
  [[ "$h" =~ ^[0-9.]+$ ]] && { echo "an IP address: subdomain matching would stretch it to others"; return 1; }
  [[ "$h" =~ ^(co|com|net|org|gov|edu|ac|ne|or|go)\.[a-z]{2}$ ]] && { echo "a public suffix"; return 1; }
  [[ "$h" =~ ^(uk|us|eu|gb|br|cn|de|jpn|ru|sa|se|za|kr|hu|no|ae|qc|uy|mex)\.(com|net|org)$ ]] && { echo "a public suffix"; return 1; }
  for s in "${sinks[@]}"; do
    [[ "$h" == "$s" || "$h" == *".$s" ]] && { echo "a tunnel or request-capture service ($s)"; return 1; }
  done
  for s in "${shared[@]}"; do
    [[ "$h" == "$s" ]] && { echo "shared hosting: name the full host instead"; return 1; }
  done
  return 0
}

# `netAllowlist` entries from ~/.claude/local-settings/*.json that pass
# net_host_problem. Read on every call, so an edit applies without a reinstall;
# a file that will not parse contributes nothing, and the guard asks as before.
# Regular files only: jq blocks on a FIFO, and a hook that times out is not a
# deny, the call goes on to the permission flow. Arrays only, as install.sh counts.
local_net_hosts() {   # keys to read: netAllowlist (default), netAllowBody
  local dir f h
  dir=$(expand_tilde "${CLAUDE_LOCAL_SETTINGS_DIR:-$HOME/.claude/local-settings}")
  compgen -G "$dir/*.json" >/dev/null || return 0
  [[ $# -gt 0 ]] || set -- netAllowlist
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    jq -r --args '. as $o | $ARGS.positional[] | $o[.] | arrays | .[] | strings' "$@" < "$f" 2>/dev/null
  done | while IFS= read -r h; do
    net_host_problem "$h" >/dev/null && printf '%s\n' "$h"
  done
}
