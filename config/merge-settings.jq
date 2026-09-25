# Merges the harness settings.json into an existing ~/.claude/settings.json.
#
# Invoked by install.sh as:
#   jq -s --arg home "$HOME" --argjson owned '["audit.sh",…]' -f merge-settings.jq OLD NEW
# Kept as a standalone program so tests/install-merge.test.sh exercises the
# exact filter the installer runs (no second copy to drift out of sync).
#
# Ownership rules:
#   - user wins for overlapping top-level keys they set themselves (env, tui, …)
#   - allow / deny lists are unioned so users and projects can extend them
#   - statusLine and permissions.defaultMode are harness-owned
#   - the harness owns the hook entries it installed; yours are preserved
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

# A hook entry this harness installed: its command runs a file in ~/.claude/hooks
# whose name the harness ships (--argjson owned, from hooks/*.sh). A user's own
# script in that directory is theirs. Both spellings, because settings.json
# carries the tilde form and an expanded one is equally valid on disk. Without
# owned, every file there counts, as before. A hook dropped from hooks/ is no
# longer owned, so its entry would survive: retire one by editing settings.json.
def is_harness_hook($h):
  (.command // "") as $c
  | [("~/.claude/hooks/", $h + "/.claude/hooks/") as $p
     | select($c | startswith($p)) | $c | ltrimstr($p) | split(" ")[0]] as $names
  | ($names | length) > 0
    and (($ARGS.named.owned // null) as $o | $o == null or any($o[]; . == $names[0]));

# Strip the harness's own entries from a matcher list, and drop matchers left
# empty, so only hooks the harness did not install survive.
def keep_foreign($h):
  (. // [])
  | map(.hooks = ((.hooks // []) | map(select(is_harness_hook($h) | not))))
  | map(select((.hooks | length) > 0));

.[0] as $old | .[1] as $new
| (($old.hooks // {}) | with_entries(.value |= keep_foreign($home))
                      | with_entries(select(.value | length > 0))) as $foreign
| $new
  * $old                                                     # user wins for overlapping top-level keys
| .permissions.allow = (($old.permissions.allow // []) + ($new.permissions.allow // []) | expand_home($home))
| .permissions.deny  = (($old.permissions.deny  // []) + ($new.permissions.deny  // []) | expand_home($home))
# Harness owns the permission mode, so a stale value can't shadow it — but
# never write a null key if a customized source has dropped it.
| (if $new.permissions.defaultMode
   then .permissions.defaultMode = $new.permissions.defaultMode
   else . end)
# The harness owns ITS hooks, not yours. Replacing the whole block cost a real
# machine its 10 iTerm2 status-line entries on every install: they live under
# ~/.config, nothing here ships them, and re-running the installer silently took
# them to zero. Anything whose command is not a harness hook is preserved, per
# event, after the harness entries.
| .hooks      = (($new.hooks // {}) | with_entries(.value = (.value + ($foreign[.key] // []))))
                + ($foreign | with_entries(. as $e | select((($new.hooks // {}) | has($e.key)) | not)))
| .statusLine = $new.statusLine                              # harness owns statusline
