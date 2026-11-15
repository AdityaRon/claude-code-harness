#!/usr/bin/env bash
# bin/skills-sync.sh against a fixture skills repo, then the handover itself:
# harness v1.4.2 installed into a temp HOME and upgraded to this tree, with the
# pinned claude-code-skills release fetched from a local clone, no network.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKSRC=$(skills_src "$REPO") || SKSRC=""
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
# The fixture's pin names its URL; each case below that wants another sets it.
unset XDG_CONFIG_HOME XDG_DATA_HOME SKILL_FORGE_TEMPLATES HARNESS_SKILLS_CLONE HARNESS_SKILLS_URL
export CCH_SKIP_SELFTEST=1
G=(git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c tag.gpgsign=false)
SYNC="$REPO/bin/skills-sync.sh"
FROM=v1.4.2

echo "=== skills-sync.sh: a fixture release, checked out and verified before it runs ==="
F="$TMP/fx"; mkdir -p "$F"
cat > "$F/install.sh" <<'SH'
#!/usr/bin/env bash
echo run >> "$HOME/fx-installs"
mkdir -p "$HOME/.claude/skills/fx" && cat "$(dirname "$0")/body" > "$HOME/.claude/skills/fx/SKILL.md"
printf 'commit=%s\n' "$(git -C "$(dirname "$0")" rev-parse HEAD)" > "$HOME/.claude/skills.version"
SH
echo one > "$F/body"
printf '#!/usr/bin/env bash\necho "fx doctor $*"\n' > "$F/doctor.sh"
( cd "$F" && "${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm one && "${G[@]}" tag v9.0.0 ) || { echo "fixture failed"; exit 1; }
ONE=$("${G[@]}" -C "$F" rev-parse HEAD)
pin() { printf 'url=%s\ntag=%s\ncommit=%s\n' "${3:-$F}" "$1" "$2" > "$TMP/pin"; }   # TAG COMMIT [URL]
sync() { HOME="$1" bash "$SYNC" --pin "$TMP/pin" "${@:2}" 2>&1; }
installs() { if [[ -f "$1/fx-installs" ]]; then wc -l < "$1/fx-installs" | tr -d ' '; fi; }
A="$TMP/a"; mkdir -p "$A/.claude/skills/mine"; echo mine > "$A/.claude/skills/mine/SKILL.md"

printf 'url=%s\ntag=v9.0.0\n' "$F" > "$TMP/pin"
OUT=$(sync "$A"); RC=$?
[[ $RC == 1 && "$OUT" == *"does not name"* && ! -e "$A/.claude/skills-src" ]] && pass "a pin with no commit is refused" || fail "bad pin" "rc=$RC $OUT"

pin v9.0.0 "$ONE"
OUT=$(HARNESS_SKILLS_URL="$TMP/nowhere" sync "$A"); RC=$?
[[ $RC == 1 && "$OUT" == *"git clone of $TMP/nowhere failed"*"left as it was" && ! -e "$A/.claude/skills-src" ]] \
  && [[ -z "$(find "$A/.claude" -name 'skills-src.new.*')" && "$(ls "$A/.claude/skills")" == mine && -z "$(installs "$A")" ]] \
  && pass "an unreachable URL: exit 1, says so, no clone or half clone, the tree untouched" || fail "unreachable" "rc=$RC $OUT"

OUT=$(sync "$A"); RC=$?
[[ $RC == 0 && "$(cat "$A/.claude/skills/fx/SKILL.md")" == one && "$(git -C "$A/.claude/skills-src" rev-parse HEAD)" == "$ONE" ]] \
  && [[ "$OUT" == *"✓ skills v9.0.0 (${ONE:0:12}) from $F"* && -f "$A/.claude/skills/mine/SKILL.md" ]] \
  && pass "clones, checks the tag out at the pinned commit, runs its install.sh" || fail "first sync" "rc=$RC $OUT"
OUT=$(sync "$A" --if-behind); RC=$?
[[ $RC == 0 && -z "$OUT" && "$(installs "$A")" == 1 ]] && pass "--if-behind at the pinned commit does nothing" || fail "--if-behind" "rc=$RC $OUT"

echo two > "$A/.claude/skills-src/body"
OUT=$(sync "$A"); RC=$?
[[ $RC == 1 && "$OUT" == *"has local changes"* && "$(installs "$A")" == 1 ]] && pass "a clone with local changes is refused" || fail "dirty clone" "rc=$RC $OUT"
git -C "$A/.claude/skills-src" checkout -q -- body

( cd "$F" && echo two > body && "${G[@]}" commit -qam two && "${G[@]}" tag v9.1.0 )
TWO=$("${G[@]}" -C "$F" rev-parse HEAD)
pin v9.1.0 "$TWO"
OUT=$(sync "$A" --if-behind); RC=$?
[[ $RC == 0 && "$(cat "$A/.claude/skills/fx/SKILL.md")" == two && "$(installs "$A")" == 2 ]] \
  && pass "a clone without the new tag fetches it; --if-behind runs when behind" || fail "new tag" "rc=$RC $OUT"

pin v9.1.0 "$ONE"
OUT=$(sync "$TMP/b"); RC=$?
[[ $RC == 1 && "$OUT" == *"v9.1.0 at $F is $TWO, and the harness pins $ONE"* && ! -e "$TMP/b/.claude/skills" ]] \
  && pass "a tag that is not the pinned commit is refused before anything runs" || fail "moved tag" "rc=$RC $OUT"

pin v9.1.0 "$TWO"
OUT=$(HARNESS_SKILLS_CLONE="$TMP/elsewhere" sync "$TMP/c"); RC=$?
[[ $RC == 0 && -d "$TMP/elsewhere/.git" && ! -e "$TMP/c/.claude/skills-src" ]] && pass "HARNESS_SKILLS_CLONE moves the clone" || fail "clone override" "rc=$RC $OUT"

# Cloned from a mirror with HARNESS_SKILLS_URL; later runs, as launchd starts
# them, have no such variable and the pin's URL is unreachable.
git clone -q --mirror "$F" "$TMP/mirror.git"
OUT=$(HARNESS_SKILLS_URL="$TMP/mirror.git" sync "$TMP/e"); RC=$?
( cd "$F" && echo three > body && "${G[@]}" commit -qam three && "${G[@]}" tag v9.2.0 ) && git -C "$TMP/mirror.git" fetch -q origin 'refs/tags/*:refs/tags/*'
pin v9.2.0 "$("${G[@]}" -C "$F" rev-parse HEAD)" "$TMP/unreachable"
OUT=$(sync "$TMP/e"); RC2=$?
[[ $RC == 0 && $RC2 == 0 && "$(cat "$TMP/e/.claude/skills/fx/SKILL.md")" == three ]] \
  && pass "a clone made from a mirror fetches the next tag from it, with no URL set" || fail "mirror origin" "rc=$RC/$RC2 $OUT"

# Installed from a working clone by hand: the scheduled retry leaves it, an install does not.
printf 'commit=%s\nrepo=%s\n' "$ONE" "$TMP/dev-clone" > "$TMP/e/.claude/skills.version"
N=$(installs "$TMP/e")
OUT=$(sync "$TMP/e" --if-behind); RC=$?
[[ $RC == 0 && "$OUT" == *"installed from $TMP/dev-clone"*"left as they are"* && "$(installs "$TMP/e")" == "$N" ]] \
  && pass "--if-behind leaves skills installed from another clone" || fail "hand install kept" "rc=$RC $OUT"
OUT=$(sync "$TMP/e"); RC=$?
[[ $RC == 0 && "$(installs "$TMP/e")" == $((N + 1)) ]] && pass "and a plain run installs the pinned release over them" || fail "plain run" "rc=$RC $OUT"

echo ""
echo "=== doctor.sh --skill runs the skills clone's check ==="
OUT=$(HARNESS_SKILLS_CLONE="$TMP/e/.claude/skills-src" bash "$REPO/doctor.sh" --skill comms-hub 2>&1); RC=$?
[[ $RC == 0 && "$OUT" == "fx doctor --skill comms-hub" ]] && pass "it runs that clone's doctor.sh --skill NAME" || fail "forward" "rc=$RC $OUT"
OUT=$(HOME="$TMP/none" bash "$REPO/doctor.sh" --skill comms-hub 2>&1); RC=$?
[[ $RC == 2 && "$OUT" == *"no claude-code-skills clone at $TMP/none/.claude/skills-src"* ]] && pass "with no clone: exit 2, saying where it looked" || fail "no clone" "rc=$RC $OUT"

echo ""
echo "=== harness $FROM, upgraded to this tree: ~/.claude/skills byte for byte ==="
if [[ -z "$SKSRC" ]]; then no_skills "the upgrade from $FROM"; results; fi
if ! git -C "$REPO" cat-file -e "$FROM^{commit}" 2>/dev/null; then
  if [[ -n "${CI:-}" ]]; then fail "the upgrade from $FROM" "the clone has no $FROM tag: fetch-depth 0"
  else echo "  SKIP: the upgrade from $FROM: this clone has no $FROM tag (git fetch --tags)"; fi
  results
fi

# The ~/.claude scripts the pinned skills run (each forge.toml's uses) are this
# repo's to ship: one bin/ drops would break a skill no harness test runs.
skills_tree "$SKSRC" "$REPO" "$TMP/pinned" skills
USES=$(cat "$TMP"/pinned/skills/*/forge.toml | sed -n 's/^uses *= *\[\(.*\)\]/\1/p' | tr ',' '\n' | sed -nE 's/.*"~\/\.claude\/([^"/]+)".*/\1/p' | sort -u)
MISSING=""; for u in $USES; do [[ -f "$REPO/bin/$u" ]] || MISSING="$MISSING $u"; done
[[ "$(wc -w <<<"$USES" | tr -d ' ')" -ge 4 && -z "$MISSING" ]] && pass "bin/ ships each of the $(wc -w <<<"$USES" | tr -d ' ') scripts the pinned skills run: $(echo $USES)" \
  || fail "scripts the pinned skills run" "read: $(echo $USES); not in bin/:$MISSING"

# Mode, blob and path of every entry under each DIR; a folder's blob is "-".
sig() {
  python3 - "$@" <<'PY'
import hashlib, os, stat, sys
for top in sys.argv[1:]:
    if not os.path.isdir(top):
        print("absent", top); continue
    rows = []
    for d, dirs, files in os.walk(top):
        for n in dirs + files:
            p = os.path.join(d, n); st = os.lstat(p); rel = os.path.relpath(p, top)
            blob = "-"
            if stat.S_ISREG(st.st_mode):
                data = open(p, "rb").read()
                blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            rows.append(f"{stat.filemode(st.st_mode)} {blob} {os.path.basename(top)}/{rel}")
    print("\n".join(sorted(rows)))
PY
}
PIN_COMMIT=$(sed -n 's/^commit=//p' "$REPO/config/skills.pin")
H="$TMP/h"
"${G[@]}" clone -q --no-checkout "$REPO" "$H" && "${G[@]}" -C "$H" checkout -q --detach "$FROM" || { fail "a clone at $FROM" ""; results; }
inst() {  # HOME [VAR=value...]: install.sh from $H into HOME
  ( export HOME="$1"; mkdir -p "$HOME"; cd "$H" && env "${@:2}" bash install.sh 2>&1 )
}
U="$TMP/up"
OUT=$(inst "$U"); RC=$?
[[ $RC == 0 && "$(sed -n 's/^commit=//p' "$U/.claude/harness.version")" == "$(git -C "$H" rev-parse HEAD)" ]] \
  && [[ "$(git -C "$H" rev-parse HEAD)" == "$(git -C "$REPO" rev-parse "$FROM^{commit}")" && -f "$U/.claude/skills/comms-hub/bin/hub.py" ]] \
  && pass "$FROM installed from a clone at its tag, which harness.version records" || fail "$FROM install" "rc=$RC $(tail -3 <<<"$OUT")"
TREES=("$U/.claude/skills" "$U/.local/share/skill-forge")
BEFORE=$(sig "${TREES[@]}")
[[ "$(grep -c ' ' <<<"$BEFORE")" -ge 60 ]] && pass "$(grep -c '^-' <<<"$BEFORE") files and their folders recorded" || fail "the tree read" "$(head -3 <<<"$BEFORE")"
cp -Rp "$U" "$TMP/down"   # the same machine, for the failed fetch below

# This tree, committed in the clone over $FROM, as a release cut from it would be.
"${G[@]}" -C "$H" rm -rq .
( cd "$REPO" && git ls-files -co --exclude-standard | while IFS= read -r p; do [[ -f "$p" ]] && printf '%s\n' "$p"; done > "$TMP/files" \
  && tar -cf - -T "$TMP/files" ) | tar -xf - -C "$H"
"${G[@]}" -C "$H" add -A && "${G[@]}" -C "$H" commit -qm head
HEAD_SHA=$(git -C "$H" rev-parse HEAD)
[[ ! -e "$H/skills" ]] && git -C "$H" merge-base --is-ancestor "$FROM" HEAD && pass "this tree, committed on $FROM, has no skills/" || fail "head commit" ""

OUT=$(inst "$U" HARNESS_SKILLS_URL="$SKSRC"); RC=$?
AFTER=$(sig "${TREES[@]}")
[[ $RC == 0 && "$(sed -n 's/^commit=//p' "$U/.claude/harness.version")" == "$HEAD_SHA" && "$(sed -n 's/^commit=//p' "$U/.claude/skills.version")" == "$PIN_COMMIT" ]] \
  && pass "the upgrade installs this tree and the pinned skills release" || fail "upgrade" "rc=$RC $(grep -iE 'skills|✗' <<<"$OUT" | head -5)"
[[ -n "$AFTER" && "$AFTER" == "$BEFORE" ]] && pass "~/.claude/skills and the templates: every path, mode and byte as $FROM left them" \
  || fail "the tree changed" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -8)"
[[ "$OUT" == *"pick up what changed since $(git -C "$REPO" rev-parse --short=12 "$FROM^{commit}")"* && "$OUT" != *"$U/.claude/skills/"* ]] \
  && pass "the report ran from $FROM, and names nothing under ~/.claude/skills as removed or kept" \
  || fail "the report" "$(grep -E 'since|Deleted' <<<"$OUT" | head -3) $(grep -F "$U/.claude/skills/" <<<"$OUT" | head -3)"
[[ -f "$U/.claude/skills.manifest" && "$(wc -l < "$U/.claude/skills.manifest" | tr -d ' ')" == "$(grep -c '^-' <<<"$(sig "$U/.claude/skills")")" ]] \
  && pass "the skills installer's record lists every file there, outside the tree" || fail "manifest" "$(wc -l < "$U/.claude/skills.manifest" 2>&1)"

F2="$TMP/fresh"
OUT=$(inst "$F2" HARNESS_SKILLS_URL="$SKSRC"); RC=$?
FRESH=$(sig "$F2/.claude/skills" "$F2/.local/share/skill-forge")
[[ $RC == 0 && "${FRESH//$F2/}" == "${BEFORE//$U/}" ]] && pass "a fresh install yields the same tree" \
  || fail "fresh tree" "rc=$RC $(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$FRESH") | head -6)"

D="$TMP/down"
OUT=$(inst "$D" HARNESS_SKILLS_URL="$TMP/nowhere"); RC=$?
[[ $RC == 0 && "$OUT" == *"⚠ skills: git clone of $TMP/nowhere failed"* && "$OUT" == *"Done. Open Claude Code"* \
   && "$(sed -n 's/^commit=//p' "$D/.claude/harness.version")" == "$HEAD_SHA" ]] \
  && pass "the same upgrade with the fetch failing: reported, and the install finishes" || fail "failed fetch" "rc=$RC $(tail -4 <<<"$OUT")"
DOWN=$(sig "$D/.claude/skills" "$D/.local/share/skill-forge")
[[ "${DOWN//$D/}" == "${BEFORE//$U/}" && ! -e "$D/.claude/skills.manifest" ]] \
  && pass "and leaves the tree $FROM installed untouched: nothing pruned, nothing written" \
  || fail "tree after a failed fetch" "$(diff <(printf '%s\n' "${BEFORE//$U/}") <(printf '%s\n' "${DOWN//$D/}") | head -6)"

echo local > "$U/.claude/skills-src/README.md"
OUT=$(inst "$U" HARNESS_SKILLS_URL="$SKSRC"); RC=$?
[[ $RC == 0 && "$OUT" == *"has local changes"* && "$(sig "${TREES[@]}")" == "$BEFORE" ]] \
  && pass "a refused clone on a later install leaves the tree as it was" || fail "refused later" "rc=$RC $(grep skills <<<"$OUT" | head -3)"

results
