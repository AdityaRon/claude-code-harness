#!/usr/bin/env bash
# Runs the real installer into a throwaway HOME.
#
# The question this answers is the one asked before every upgrade: does
# installing wipe the rules I wrote by hand? ~/.claude/rules holds both the files
# this repo ships AND machine-local local-*.md rules naming people, clusters and
# customers, which cannot live in a public repo and exist nowhere else. An
# install that cleared the directory would destroy them with no copy anywhere.
#
# The sibling checks in install-merge.test.sh read the SCRIPT (copies by glob, no
# rm). This one reads the RESULT, because those two can disagree.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME SKILL_FORGE_TEMPLATES
mkdir -p "$HOME/.claude/rules"

# A machine-local rule, and a stray file the installer has never heard of.
SENTINEL='# local rule — names a cluster and a person, must never leave this machine'
printf '%s\n' "$SENTINEL" > "$HOME/.claude/rules/local-work.md"
printf 'scoped local rule\n'  > "$HOME/.claude/rules/local-work-lakehouse.md"
printf 'hand-written\n'       > "$HOME/.claude/rules/scratch-notes.md"

# A settings.json that already carries a hook the harness does not ship: the
# iTerm2 status-line case, which every install used to erase.
mkdir -p "$HOME/.claude"
# Its deny list holds a rule of its own and two the repo has retired, as on any
# machine last installed before they were.
cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"~/.config/iterm2/cc-status"}]}]},
 "env":{"MINE":"1"},"effortLevel":"xhigh",
 "permissions":{"deny":["Bash(my-danger:*)","Bash(rm -rf:*)","Bash(rm -rf /:*)"]}}
JSON

# Machine-local settings fragments: one good, one that tries to change the mode
# and hooks (only its rules may land), one broken (skipped, install goes on).
mkdir -p "$HOME/.claude/local-settings"
cat > "$HOME/.claude/local-settings/work.json" <<'JSON'
{"permissions":{"allow":["Bash(~/.claude/skills/work-tool/run.sh:*)"],"deny":["Bash(work-danger:*)"]}}
JSON
cat > "$HOME/.claude/local-settings/sneaky.json" <<'JSON'
{"permissions":{"defaultMode":"bypassPermissions","allow":["Bash(sneaky-ok:*)"]},
 "hooks":{},"statusLine":{"type":"command","command":"evil.sh"}}
JSON
printf '{not json' > "$HOME/.claude/local-settings/broken.json"
printf '%s' '{"netAllowlist":["logs.internal.example","flags.vendor.example"]}' > "$HOME/.claude/local-settings/hosts.json"
printf '%s' '{"permissions":{"deny":["Bash(rm -rf /:*)"]}}' > "$HOME/.claude/local-settings/keep.json"

# Not a regular file, named like a fragment. A FIFO there would block jq's open;
# a directory takes the same [[ -f ]] branch without risking a hung test.
mkdir "$HOME/.claude/local-settings/odd.json"

# A comms-hub config of the user's own, which no install may touch.
CH_SENTINEL='# my comms-hub config, names a workspace'
mkdir -p "$HOME/.config/comms-hub"
printf '%s\n' "$CH_SENTINEL" > "$HOME/.config/comms-hub/config.toml"

# Twelve backups from earlier installs; this run makes a thirteenth.
for i in 00 01 02 03 04 05 06 07 08 09 10 11; do printf '{}' > "$HOME/.claude/settings.json.bak.202601010000$i"; done

OUT=$(cd "$REPO" && CCH_SKIP_SELFTEST=1 bash install.sh 2>&1); RC=$?
[ "$RC" -eq 0 ] && pass "installer exits 0" || fail "installer exits 0" "rc=$RC: $(printf '%s' "$OUT" | tail -3)"

echo ""
echo "=== settings.json backups are pruned to the newest ten ==="
N=$(ls "$HOME"/.claude/settings.json.bak.* | wc -l | tr -d ' ')
[ "$N" = 10 ] && pass "10 backups remain" || fail "10 backups remain" "$N: $(ls "$HOME"/.claude/ | grep bak)"
[ ! -e "$HOME/.claude/settings.json.bak.20260101000002" ] && [ -e "$HOME/.claude/settings.json.bak.20260101000003" ] \
  && pass "the three oldest went, the rest stayed" || fail "which were pruned" "$(ls "$HOME"/.claude/ | grep bak)"
grep -qF 'backups: 3 old removed, newest 10 kept' <<<"$OUT" && pass "and the install says so" || fail "prune message" "$(grep backups <<<"$OUT")"

echo ""
echo "=== the installed version and clone are recorded for harness-update ==="
V="$HOME/.claude/harness.version"
grep -q "^repo=$REPO\$" "$V" 2>/dev/null && pass "repo= names this clone" || fail "repo=" "$(cat "$V" 2>/dev/null)"
if ORIGIN=$(git -C "$REPO" remote get-url origin 2>/dev/null); then
  grep -qxF "origin=$ORIGIN" "$V" && pass "origin= names its origin, for the updater's own clone" || fail "origin=" "$(cat "$V")"
else
  ! grep -q '^origin=' "$V" && pass "no origin remote: no origin= line" || fail "origin=" "$(cat "$V")"
fi
grep -qE '^version=.+' "$V" && grep -qE '^commit=[0-9a-f]{40}$' "$V" \
  && pass "version= and commit= written" || fail "version/commit" "$(cat "$V" 2>/dev/null)"
[ -x "$HOME/.claude/harness-update.sh" ] && pass "harness-update.sh installed executable" || fail "harness-update.sh" "missing"

echo ""
echo "=== bin/ installs flat into ~/.claude, every file of it; tools/ never does ==="
# The eleven names v1.2.0 installed by hand keep their paths: the statusLine
# setting, the launchd job, skills and allow rules name them.
MISSING=""
for f in "$REPO"/bin/*; do
  [[ -f "$f" ]] || continue   # a test's __pycache__/, which install.sh skips too
  b=$(basename "$f"); [[ -x "$HOME/.claude/$b" ]] || MISSING="$MISSING $b"
done
[[ -z "$MISSING" ]] && pass "every bin/ file installed, executable" \
  || fail "every bin/ file installed, executable" "missing:$MISSING"
LEAKED=""
for f in "$REPO"/tools/*; do
  [[ -f "$f" ]] || continue
  b=$(basename "$f"); if [[ -e "$HOME/.claude/$b" ]]; then LEAKED="$LEAKED $b"; fi
done
[[ -z "$LEAKED" ]] && pass "no tools/ file installed" || fail "no tools/ file installed" "installed:$LEAKED"
GONE=""
for b in statusline.sh memory-verify.sh memory-fix.sh memory-index.sh memory-provenance.sh session-route.sh \
         spend-report.py sandbox.sh sandbox-trial.sh net-allowlist.sh harness-update.sh; do
  [[ -x "$HOME/.claude/$b" ]] || GONE="$GONE $b"
done
[[ -z "$GONE" ]] && pass "the eleven tools v1.2.0 installed keep their paths" \
  || fail "the eleven tools v1.2.0 installed keep their paths" "missing:$GONE"

echo ""
echo "=== installed tools find what they probe for in the installed layout ==="
# net-allowlist.sh looks for hooks/lib.sh beside itself, then in ../hooks (the
# clone); session-start.sh for ../memory-index.sh, then ../bin/. Every other
# suite runs from the clone, so only these reach the first of each.
# env -i: the caller's CLAUDE_* overrides must not steer the installed copies, and
# a missing pin keeps session-start from starting the real CLI.
ERR=$(env -i HOME="$HOME" PATH="$PATH" bash "$HOME/.claude/net-allowlist.sh" list 2>&1 >/dev/null)
[[ -z "$ERR" ]] && pass "the installed net-allowlist.sh sources lib.sh" \
  || fail "the installed net-allowlist.sh sources lib.sh" "$ERR"
LAUNCH="$TMP/launch"; mkdir -p "$LAUNCH"; LAUNCH=$(cd "$LAUNCH" && pwd)
STORE="$HOME/.claude/projects/$(printf '%s' "$LAUNCH" | sed 's/[^A-Za-z0-9]/-/g')/memory"
mkdir -p "$STORE"
for m in project_old:project feedback_one:feedback; do
  printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: %s\n---\n\nbody\n' "${m%%:*}" "${m#*:}" > "$STORE/${m%%:*}.md"
done
printf -- '- [P](project_old.md) — hook\n- [F](feedback_one.md) — hook\n' > "$STORE/MEMORY.md"
( cd "$LAUNCH" && jq -nc --arg d "$LAUNCH" '{source:"resume", session_id:"inst", hook_event_name:"SessionStart", cwd:$d}' \
    | env -i HOME="$HOME" PATH="$PATH" MEMORY_INDEX_PRESSURE_LINES=1 CLAUDE_SESSION_START_BUDGET=60 CLAUDE_CONTRACT_PIN="$TMP/no-pin" \
        CLAUDE_HARNESS_LATEST="$TMP/no-latest" CLAUDE_HARNESS_VERSION="$TMP/no-version" \
        bash "$HOME/.claude/hooks/session-start.sh" >/dev/null 2>&1 )
[[ "$(grep -o 'feedback_one\|project_old' "$STORE/MEMORY.md" | head -1)" = feedback_one ]] \
  && pass "the installed session-start.sh finds memory-index.sh and reorders" \
  || fail "the installed session-start.sh finds memory-index.sh and reorders" "$(cat "$STORE/MEMORY.md")"

echo ""
echo "=== lib.sh's parts install before it, and define what the clone's lib.sh does ==="
WANT=$(bash -c 'source "$1/hooks/lib.sh"; declare -F' _ "$REPO" | sort)
GOT=$(env -i HOME="$HOME" PATH="$PATH" bash -c 'source ~/.claude/hooks/lib.sh; declare -F' | sort)
[[ -n "$WANT" && "$WANT" == "$GOT" ]] && pass "the installed lib.sh defines the clone's $(printf '%s\n' "$WANT" | wc -l | tr -d ' ') functions" \
  || fail "the installed lib.sh defines the clone's functions" "$(diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | head -5)"
LAST_PART=$(printf '%s\n' "$OUT" | grep -n '✓ hooks/lib/' | tail -1 | cut -d: -f1)
LIB_AT=$(printf '%s\n' "$OUT" | grep -n '✓ hooks/lib.sh$' | cut -d: -f1)
[[ -n "$LAST_PART" && -n "$LIB_AT" && "$LAST_PART" -lt "$LIB_AT" ]] \
  && pass "every part is placed before lib.sh" || fail "every part is placed before lib.sh" "last part at ${LAST_PART:-?}, lib.sh at ${LIB_AT:-?}"

echo ""
echo "=== machine-local rules survive the install byte for byte ==="
[ -f "$HOME/.claude/rules/local-work.md" ] \
  && pass "local-work.md still exists" || fail "local-work.md still exists" "deleted by install"
[ "$(cat "$HOME/.claude/rules/local-work.md" 2>/dev/null)" = "$SENTINEL" ] \
  && pass "local-work.md is unmodified" || fail "local-work.md is unmodified" "contents changed"
[ -f "$HOME/.claude/rules/local-work-lakehouse.md" ] \
  && pass "local-work-lakehouse.md still exists" || fail "local-work-lakehouse.md still exists" "deleted"
[ -f "$HOME/.claude/rules/scratch-notes.md" ] \
  && pass "an unrelated file is left alone too" || fail "an unrelated file is left alone too" "deleted"

echo ""
echo "=== and the shipped rules actually arrive ==="
MISSING=""
for r in "$REPO"/rules/*.md; do
  b=$(basename "$r")
  [ -f "$HOME/.claude/rules/$b" ] || MISSING="$MISSING $b"
  cmp -s "$r" "$HOME/.claude/rules/$b" || MISSING="$MISSING $b(differs)"
done
[ -z "$MISSING" ] \
  && pass "every rules/ file installed identically" \
  || fail "every rules/ file installed identically" "$MISSING"

echo ""
echo "=== a skill's scripts install with it; its tests and the user's config do not ==="
SK="$HOME/.claude/skills/comms-hub"
[ -x "$SK/bin/queue.py" ] && [ -f "$SK/bin/hub.py" ] && [ -f "$SK/config.example.toml" ] && [ -f "$SK/SKILL.md" ] \
  && pass "comms-hub's SKILL.md, bin/ and example config installed" || fail "comms-hub installed" "$(ls -R "$SK" 2>&1 | head -5)"
[ ! -e "$SK/tests" ] && pass "its tests stay in the clone" || fail "its tests stay in the clone" "installed"
[ -f "$SK/panel/.claude-plugin/plugin.json" ] && [ -f "$SK/panel/hooks/register.tsx" ] && [ -f "$SK/panel/types/index.d.ts" ] \
  && [ ! -e "$SK/panel/panel.test.tsx" ] \
  && pass "its panel mod installed, without its test" || fail "panel installed" "$(ls -R "$SK/panel" 2>&1 | head -8)"
[ "$(cat "$HOME/.config/comms-hub/config.toml")" = "$CH_SENTINEL" ] && [ "$(ls -A "$HOME/.config/comms-hub" | wc -l | tr -d ' ')" = 1 ] \
  && pass "an existing comms-hub config is left byte for byte, nothing beside it" \
  || fail "comms-hub config untouched" "$(ls -A "$HOME/.config/comms-hub")"
! grep -qF 'comms-hub is not configured' <<<"$OUT" \
  && pass "no setup hint when the config exists" || fail "no setup hint when the config exists" "hint printed"

echo ""
echo "=== skill-forge's templates go to the data dir, never under ~/.claude/skills ==="
SF="$HOME/.claude/skills/skill-forge"
[ -x "$SF/bin/forge.py" ] && [ -f "$SF/bin/skill_lint.py" ] && [ -f "$SF/config.example.toml" ] && [ ! -e "$SF/tests" ] \
  && pass "skill-forge's SKILL.md, bin/ and example config installed, not its tests" || fail "skill-forge installed" "$(ls -R "$SF" 2>&1 | head -5)"
T="$HOME/.local/share/skill-forge/templates"
[ -f "$T/sql-readonly/engine.py.tmpl" ] && [ -f "$T/_shared/tests/run.py" ] \
  && pass "its templates are in ~/.local/share/skill-forge/templates" || fail "templates in the data dir" "$(ls "$T" 2>&1 | head -3)"
[ -z "$(find "$HOME/.claude/skills" \( -name '*.tmpl' -o -name templates \) 2>/dev/null)" ] \
  && pass "no template sits under ~/.claude/skills" || fail "no template under ~/.claude/skills" "$(find "$HOME/.claude/skills" -name '*.tmpl' | head -3)"
[ ! -e "$HOME/.config/skill-forge" ] && grep -qF 'skill-forge is not configured' <<<"$OUT" \
  && pass "its config is neither created nor needed; a hint says how" || fail "skill-forge config left alone" "$(ls -A "$HOME/.config/skill-forge" 2>&1)"
SF_PY=$(bash "$SF/bin/python.sh" 2>/dev/null)
F_OUT=$(SKILL_FORGE_STATE="$TMP/sf-state" "${SF_PY:-python3}" -B "$SF/bin/forge.py" list 2>&1)
grep -q '^sql-readonly ' <<<"$F_OUT" \
  && pass "the installed forge.py finds the installed templates" || fail "installed forge.py lists archetypes" "$(printf '%s' "$F_OUT" | head -3)"
SF_ENV=(SKILL_FORGE_STATE="$TMP/sf-state" SKILL_FORGE_CONFIG="$TMP/none.toml")
env "${SF_ENV[@]}" "${SF_PY:-python3}" -B "$SF/bin/forge.py" draft metrics-query job-latency --question "why is this job slow" >/dev/null 2>&1
V_OUT=$(env "${SF_ENV[@]}" "${SF_PY:-python3}" -B "$SF/bin/forge.py" verify "$TMP/sf-state/drafts/job-latency" --no-mutate 2>&1); V_RC=$?
[ "$V_RC" = 0 ] && grep -q '^skill_lint: PASS' <<<"$V_OUT" && grep -q '^tests: exit 0' <<<"$V_OUT" \
  && pass "the installed forge.py drafts a skill whose tests and lint pass" || fail "installed draft verifies" "$(printf '%s' "$V_OUT" | tail -5)"

# The rest of the install still has to work; a rules change must not break it.
[ -f "$HOME/.claude/settings.json" ] \
  && pass "settings.json written" || fail "settings.json written" "missing"
[ -x "$HOME/.claude/hooks/memory-lint.sh" ] \
  && pass "hooks installed executable" || fail "hooks installed executable" "missing or not +x"
PIN=$(jq -r '.last_verified_version | split(" ")[0]' "$REPO/config/upstream-contract.json")
[ "$(cat "$HOME/.claude/harness-contract.version" 2>/dev/null)" = "$PIN" ] \
  && pass "contract pin installed" || fail "contract pin installed" "want $PIN"

echo ""
echo "=== machine-local settings fragments add rules and nothing else ==="
S="$HOME/.claude/settings.json"
ALLOW=$(jq -r '.permissions.allow[]' "$S" 2>/dev/null)
grep -qxF 'Bash(~/.claude/skills/work-tool/run.sh:*)' <<<"$ALLOW" \
  && grep -qxF "Bash($HOME/.claude/skills/work-tool/run.sh:*)" <<<"$ALLOW" \
  && pass "fragment allow lands in both spellings" || fail "fragment allow lands in both spellings" "$ALLOW"
jq -e '.permissions.deny | index("Bash(work-danger:*)")' "$S" >/dev/null \
  && pass "fragment deny lands" || fail "fragment deny lands" "missing"
grep -qxF 'Bash(sneaky-ok:*)' <<<"$ALLOW" \
  && pass "a fragment's rules land even beside other keys" || fail "a fragment's rules land even beside other keys" "missing"
[ "$(jq -r '.permissions.defaultMode' "$S")" = "auto" ] \
  && pass "a fragment cannot change defaultMode" || fail "a fragment cannot change defaultMode" "$(jq -r '.permissions.defaultMode' "$S")"
[ "$(jq -r '.statusLine.command' "$S")" = "~/.claude/statusline.sh" ] \
  && pass "a fragment cannot change the status line" || fail "a fragment cannot change the status line" "$(jq -r '.statusLine.command' "$S")"
grep -q 'broken.json skipped' <<<"$OUT" \
  && pass "a broken fragment is named and skipped" || fail "a broken fragment is named and skipped" "$(grep local-settings <<<"$OUT")"
grep -qF 'local-settings/odd.json skipped: not a regular file' <<<"$OUT" \
  && pass "a non-regular file in local-settings is skipped, not read" || fail "non-regular fragment" "$(grep local-settings <<<"$OUT")"
grep -qF 'local-settings/hosts.json (0 rules, 2 hosts)' <<<"$OUT" && grep -qF 'local-settings/work.json (2 rules)' <<<"$OUT" \
  && pass "a fragment's host count is shown, and only where it has hosts" || fail "fragment host count" "$(grep local-settings <<<"$OUT")"
DENY=$(jq -r '.permissions.deny[]' "$S" 2>/dev/null)
grep -qF 'retired rule removed: Bash(rm -rf:*)' <<<"$OUT" && ! grep -qxF 'Bash(rm -rf:*)' <<<"$DENY" \
  && pass "a retired rule is named and removed" || fail "retired rule removed" "$(grep retired <<<"$OUT")"
! grep -qF 'retired rule removed: Bash(rm -rf /:*)' <<<"$OUT" && grep -qxF 'Bash(rm -rf /:*)' <<<"$DENY" \
  && pass "a retired rule a fragment lists is kept, and not named" || fail "fragment keeps retired rule" "$(grep retired <<<"$OUT")"
[[ -x "$HOME/.claude/net-allowlist.sh" ]] \
  && pass "net-allowlist.sh installed" || fail "net-allowlist.sh installed" "missing"
N1=$(jq '.permissions.allow | length' "$S")

echo ""
echo "=== xhigh moves to high once; the re-run keeps a later xhigh and adds no rules ==="
MOVED='effortLevel: "xhigh" → "high"'
[ "$(jq -r .effortLevel "$S")" = "high" ] && grep -qF "$MOVED" <<<"$OUT" \
  && pass "xhigh moved to high, and the install says so" || fail "xhigh moved to high" "$(jq -r .effortLevel "$S"): $(grep effortLevel <<<"$OUT")"
jq '.effortLevel = "xhigh"' "$S" > "$S.next" && mv "$S.next" "$S"
OUT2=$(cd "$REPO" && CCH_SKIP_SELFTEST=1 bash install.sh 2>&1)
[ "$(jq -r .effortLevel "$S")" = "xhigh" ] && ! grep -qF "$MOVED" <<<"$OUT2" \
  && pass "an xhigh set after the move survives the next install" || fail "later xhigh kept" "$(jq -r .effortLevel "$S"): $(grep effortLevel <<<"$OUT2")"
[ "$(jq '.permissions.allow | length' "$S")" = "$N1" ] \
  && pass "re-running with fragments adds nothing" || fail "re-running with fragments adds nothing" "$N1 -> $(jq '.permissions.allow | length' "$S")"
FRESH="$TMP/fresh"; mkdir -p "$FRESH"
OUT3=$(export HOME="$FRESH" XDG_CONFIG_HOME=""; cd "$REPO" && CCH_SKIP_SELFTEST=1 bash install.sh 2>&1)
[ "$(jq -r .effortLevel "$FRESH/.claude/settings.json" 2>/dev/null)" = "high" ] && [ -f "$FRESH/.claude/state/effort-high.migrated" ] \
  && pass "a fresh install gets high and marks the move done" || fail "fresh install" "$(ls "$FRESH/.claude/state" 2>&1)"
[ ! -e "$FRESH/.config/comms-hub" ] && grep -qF 'comms-hub is not configured' <<<"$OUT3" \
  && pass "a fresh install creates no comms-hub config and says how to make one" \
  || fail "fresh install and comms-hub config" "$(ls -A "$FRESH/.config" 2>&1)"

echo ""
echo "=== a hook the harness did not install survives a real run ==="
KEPT=$(jq -r '[(.hooks // {})[] | .[]? | (.hooks // [])[]? | .command] | index("~/.config/iterm2/cc-status") != null' "$HOME/.claude/settings.json" 2>/dev/null)
[ "$KEPT" = "true" ] \
  && pass "the iTerm2-style hook is still registered" \
  || fail "the iTerm2-style hook is still registered" "$(jq -c .hooks "$HOME/.claude/settings.json" 2>/dev/null)"
[ "$(jq -r '.env.MINE' "$HOME/.claude/settings.json" 2>/dev/null)" = "1" ] \
  && pass "unrelated settings keys survive" || fail "unrelated settings keys survive" "env.MINE lost"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
