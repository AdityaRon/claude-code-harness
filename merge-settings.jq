# Merges the harness settings.json into an existing ~/.claude/settings.json.
#
# Invoked by install.sh as:  jq -s -f merge-settings.jq OLD NEW
# Kept as a standalone program so tests/install-merge.test.sh exercises the
# exact filter the installer runs (no second copy to drift out of sync).
#
# Ownership rules:
#   - user wins for overlapping top-level keys they set themselves (env, tui, …)
#   - allow / deny lists are unioned so users and projects can extend them
#   - hooks, statusLine and permissions.defaultMode are harness-owned
.[0] as $old | .[1] as $new
| $new
  * $old                                                     # user wins for overlapping top-level keys
| .permissions.allow = (($old.permissions.allow // []) + ($new.permissions.allow // []) | unique)
| .permissions.deny  = (($old.permissions.deny  // []) + ($new.permissions.deny  // []) | unique)
# Harness owns the permission mode, so a stale value can't shadow it — but
# never write a null key if a customized source has dropped it.
| (if $new.permissions.defaultMode
   then .permissions.defaultMode = $new.permissions.defaultMode
   else . end)
| .hooks      = $new.hooks                                   # harness fully owns hooks
| .statusLine = $new.statusLine                              # harness owns statusline
