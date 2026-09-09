#!/usr/bin/env bash
# Install apt packages on a GitHub Linux runner, tolerating the image's
# preinstalled third-party apt sources.
#
# Why this exists: `apt-get update` exits 100 when ANY configured source fails,
# so one broken third-party repo fails the whole job in its dependency step,
# before a line of the harness runs. That happened on 2026-09-09 — the runner
# image's google-chrome source served a Packages.gz whose hash did not match
# its Release file, and every Linux job here went red while macOS passed the
# same suite on the same commit.
#
# Removing the source by filename was the obvious fix and the wrong one: on
# noble the entry is not google-chrome.list, so deleting that path changed
# nothing and Chrome was still fetched. This matches on CONTENT instead, which
# holds regardless of filename or of .list vs deb822 .sources format.
#
# Deliberately NOT `apt-get update || true`: that would go green today and also
# swallow a genuine failure to reach the Ubuntu archives, turning a dependency
# outage into a mysterious "command not found" later in the job.
#
# Kept as one script rather than three inline copies so the three call sites
# cannot drift apart.
#
# Usage: .github/install-apt-deps.sh jq shellcheck ...
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <package>..." >&2
  exit 2
fi

echo "::group::apt sources before"
ls -1 /etc/apt/sources.list.d/ 2>/dev/null || echo "(no sources.list.d)"
echo "::endgroup::"

# Any source file mentioning a host we do not need. Content match, not name.
UNNEEDED='dl\.google\.com'
found=$(grep -rlE "$UNNEEDED" /etc/apt/sources.list.d/ 2>/dev/null || true)
if [ -n "$found" ]; then
  echo "Removing apt sources that this repo does not need:"
  printf '  %s\n' $found
  # shellcheck disable=SC2086  # newline-separated paths, no spaces on a runner
  sudo rm -f $found
else
  echo "No third-party sources matched /$UNNEEDED/ — nothing removed."
fi

# The main archives can also be listed in sources.list itself.
if [ -f /etc/apt/sources.list ] && grep -qE "$UNNEEDED" /etc/apt/sources.list; then
  echo "Dropping matching lines from /etc/apt/sources.list"
  sudo sed -i -E "\#$UNNEEDED#d" /etc/apt/sources.list
fi

sudo apt-get update
sudo apt-get install -y "$@"
