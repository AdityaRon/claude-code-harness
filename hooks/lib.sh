#!/usr/bin/env bash
# Shared helpers for Claude Code harness hooks.
# Source from every hook: source "$(dirname "$0")/lib.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# The functions live in lib/, one file per concern; this file stays the one the
# hooks source. A part that cannot be read (an install half done) ends the hook
# with exit 2, which blocks, rather than letting a guard run without its checks.
_lib_dir=${BASH_SOURCE[0]%/*}; [[ "$_lib_dir" == "${BASH_SOURCE[0]}" ]] && _lib_dir=.
for _lib_part in command paths scratch io inline net host; do
  # shellcheck source=/dev/null
  source "$_lib_dir/lib/$_lib_part.sh" || { echo "hooks/lib.sh: cannot read $_lib_dir/lib/$_lib_part.sh; run install.sh again" >&2; exit 2; }
done
unset _lib_dir _lib_part
