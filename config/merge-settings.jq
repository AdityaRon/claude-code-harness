# Merges the harness settings.json into an existing ~/.claude/settings.json.
#
# Invoked by install.sh as:  jq -s --arg home "$HOME" -f merge-settings.jq OLD NEW
# Kept as a standalone program so tests/install-merge.test.sh exercises the
# exact filter the installer runs (no second copy to drift out of sync).
#
# Ownership rules:
#   - user wins for overlapping top-level keys they set themselves (env, tui, …)
#   - allow / deny lists are unioned so users and projects can extend them
#   - hooks, statusLine and permissions.defaultMode are harness-owned
#
# Note on the union: it can only ever ADD rules. An update that drops a rule
# from config/settings.json will not remove it from a machine that already has
# it, so narrowing a rule (say Bash(kubectl:*) down to Bash(kubectl get:*))
# means editing ~/.claude/settings.json by hand. Widening is the only direction
# the installer can deliver.

# Bash rules are matched against the literal command text, and whether `~` is
# expanded on either side is undocumented upstream. A rule written with `~/`
# therefore ships alongside a $HOME-expanded twin, so both spellings match no
# matter which way the CLI compares them. Applied to deny as well as allow: a
# deny rule that silently failed to match would be a hole that reads as cover.
def expand_home($h):
  . as $rules
  | $rules + ($rules | map(select(contains("~/")) | gsub("~/"; $h + "/")))
  | unique;

.[0] as $old | .[1] as $new
| $new
  * $old                                                     # user wins for overlapping top-level keys
| .permissions.allow = (($old.permissions.allow // []) + ($new.permissions.allow // []) | expand_home($home))
| .permissions.deny  = (($old.permissions.deny  // []) + ($new.permissions.deny  // []) | expand_home($home))
# Harness owns the permission mode, so a stale value can't shadow it — but
# never write a null key if a customized source has dropped it.
| (if $new.permissions.defaultMode
   then .permissions.defaultMode = $new.permissions.defaultMode
   else . end)
| .hooks      = $new.hooks                                   # harness fully owns hooks
| .statusLine = $new.statusLine                              # harness owns statusline
