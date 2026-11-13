#!/usr/bin/env bash
# Shared helpers for Claude Code harness hooks.
# Source from every hook: source "$(dirname "$0")/lib.sh"

# A Bash guard run by hooks/bash-guards.sh is a fork of it: this file is loaded
# and the payload read once there, and HARNESS_PRESET says so. It holds the
# dispatcher's $$, which its forks share and no other process has, and it is
# never exported, so a guard's own `bash` child (check_inline_shellouts) loads
# this file and reads its stdin as a hook run alone does. Any other value, as
# from the environment, is dropped here with the two names that go with it.
[[ -n "${HARNESS_PRESET:-}" && "$HARNESS_PRESET" == "$$" ]] && return 0
unset HARNESS_PRESET GUARD_NAME GUARD_SELF

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Bytes, not characters: macOS awk's substr cut a "⏎" in half, its regex match
# then failed (towc), and a lexer that died there returned half the command, so
# git-guard never read a force push after one in a commit message. It holds for
# every hook that sources this file, not just the lexers: an awk missed there
# would die on command text, where under bytes a length counts a "⏎" as 3.
awk() { LC_ALL=C command awk "$@"; }

# The functions live in lib/, one file per concern; this file stays the one the
# hooks source. A part that cannot be read (an install half done) ends the hook
# with exit 2, which blocks, rather than letting a guard run without its checks.
_lib_dir=${BASH_SOURCE[0]%/*}; [[ "$_lib_dir" == "${BASH_SOURCE[0]}" ]] && _lib_dir=.
for _lib_part in command paths scratch io inline net host; do
  # shellcheck source=/dev/null
  source "$_lib_dir/lib/$_lib_part.sh" || { echo "hooks/lib.sh: cannot read $_lib_dir/lib/$_lib_part.sh; run install.sh again" >&2; exit 2; }
done
# A part that reads but defines less (empty, or cut short at a function's end)
# would leave a guard without its checks: the last function of each must be
# here. tests/fail-closed.test.sh holds this list to the parts.
declare -F neutralize_quoted_separators canonical_path in_scratch log_audit check_inline_shellouts local_net_hosts stale_claude_hosts >/dev/null \
  || { echo "hooks/lib.sh: a part in $_lib_dir/lib/ is incomplete; run install.sh again" >&2; exit 2; }
unset _lib_dir _lib_part
