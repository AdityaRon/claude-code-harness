#!/usr/bin/env bash
# Tests for the repo's own structure.
#
# These exist because the layout drifted silently and nothing could see it. The
# reorg in 7eada78 created docs/ and wrote the rule into the README ("Two entry
# points sit at the root; everything else is grouped by what it is"). Two weeks
# later 24a1936 — message prefixed `docs:` — added three briefs at the ROOT, and
# re-added a research doc docs/ already held. The two copies then diverged: the
# docs/ one gained an Errata section correcting two claims, the root one never
# did, and different readers were pointed at different files. Six references,
# one README block and one stale duplicate, none of it detectable by any test.
#
# A layout rule that only lives in prose is a rule nothing enforces.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

echo "=== The root holds only the documented entry points ==="
# README: "Two entry points sit at the root". README.md itself is the conventional
# exception; anything else is a doc that belongs in docs/.
STRAY=""
for f in *.md *.sh; do
  [ -e "$f" ] || continue
  case "$f" in README.md|CHANGELOG.md|install.sh|doctor.sh) continue ;; esac
  STRAY="$STRAY $f"
done
[ -z "$STRAY" ] \
  && pass "no stray files at the repo root" \
  || fail "no stray files at the repo root" "move into docs/ or bin/:$STRAY"

echo ""
echo "=== Executable bits match how each file is invoked ==="
# hooks/ are exec'd directly by Claude Code, bin/ by the user and by skills, and
# install.sh/doctor.sh are the entry points. tests/ are always run as `bash <file>`
# by doctor.sh, so they stay non-executable. Nine hooks, two bin scripts and
# install.sh were 644 while their neighbours were 755 — harmless only because
# install.sh chmods hooks on copy, which is exactly why nobody noticed.
BADMODE=""
# Both halves matter and they can disagree: the index mode is what a commit
# carries, the on-disk bit is what is true right now. Checking only the index
# let a bare `chmod +x` pass unnoticed.
while read -r mode _ _ path; do
  case "$path" in
    hooks/*.sh|bin/*|tools/*|install.sh|doctor.sh|.github/*.sh)
      [ "$mode" = "100755" ] || BADMODE="$BADMODE $path(index=$mode,want 755)"
      [ -x "$path" ]         || BADMODE="$BADMODE $path(on disk: not executable)" ;;
    tests/*.test.sh)
      [ "$mode" = "100644" ] || BADMODE="$BADMODE $path(index=$mode,want 644)"
      if [ -x "$path" ]; then BADMODE="$BADMODE $path(on disk: executable)"; fi ;;
  esac
done < <(git ls-files -s)
[ -z "$BADMODE" ] \
  && pass "every script's mode matches its invocation" \
  || fail "every script's mode matches its invocation" "$BADMODE"

echo ""
echo "=== The README layout block names every file in docs/ ==="
# The block listed session-routing.md only, while docs/ held a second file — so
# the one document a reader most needed was invisible in the map.
BLOCK=$(awk '/^## Repo layout$/{f=1} f&&/^```$/{n++; if(n==2) exit} f' README.md)
# Tracked files only: an untracked backup or a test's __pycache__/ is not the repo.
tracked() { git ls-files -- "$@"; }
# A name counts only as a whole word of the block: index.sh is not memory-index.sh.
BLOCK_WORDS=$(printf '%s\n' "$BLOCK" | tr -s ' \t' '\n\n')
missing_in() {  # WORDS PATH...: the basenames WORDS does not hold
  local words=$1 f b out=""; shift
  for f in "$@"; do
    b=$(basename "$f"); printf '%s\n' "$words" | grep -qxF "$b" || out="$out $b"
  done
  printf '%s' "$out"
}
# An entry is its first line plus continuation lines, 20 or more spaces deep; a
# listing line such as "  statusline.sh ..." sits 2 deep.
entry() {  # awk regex for the entry's first line
  printf '%s\n' "$BLOCK" | awk -v re="$1" '
    f && /^                    / {print; next}
    f {exit}
    $0 ~ re {f=1; print}'
}
# shellcheck disable=SC2046  # file names here never hold spaces
MISSING=$(missing_in "$BLOCK_WORDS" $(tracked ':(glob)docs/*.md'))
[ -n "$BLOCK" ] \
  && pass "the layout block was found" || fail "the layout block was found" "(empty)"
[ -z "$MISSING" ] \
  && pass "every docs/ file appears in the layout block" \
  || fail "every docs/ file appears in the layout block" "missing:$MISSING"

echo ""
echo "=== The README layout block names every file in rules/ ==="
# Same reason as docs/: a rule that ships to every session on the machine but is
# invisible in the map is one nobody reviews before it starts shaping behaviour.
# shellcheck disable=SC2046
MISSING_RULES=$(missing_in "$BLOCK_WORDS" $(tracked ':(glob)rules/*.md'))
[ -z "$MISSING_RULES" ] \
  && pass "every rules/ file appears in the layout block" \
  || fail "every rules/ file appears in the layout block" "missing:$MISSING_RULES"

echo ""
echo "=== Every repo-relative path referenced in prose actually exists ==="
# The class of bug this whole file is about: a reference that still reads fine
# and points at nothing. Installed paths (~/.claude/...) are stripped first —
# they are not repo paths — and placeholders (<hook>, *) are skipped.
BROKEN=""
CHECKED=0
# Workflows too: release.yml and upstream-drift.yml run tools/ by path, and no
# PR's CI runs them, so a moved tool would surface only at release or drift time.
for src in README.md docs/*.md docs/history/*.md skills/*/SKILL.md config/upstream-contract.json .github/workflows/*.yml; do
  [ -f "$src" ] || continue
  while read -r ref; do
    case "$ref" in *'<'*|*'*'*|*'$'*) continue ;; esac
    CHECKED=$((CHECKED+1))
    [ -e "$ref" ] || BROKEN="$BROKEN $src->$ref"
  done < <(sed 's|~/\.claude/[A-Za-z0-9._/-]*||g' "$src" \
           | grep -oE '(^|[^A-Za-z0-9._/-])(docs|bin|tools|hooks|tests|config|skills|rules)/[A-Za-z0-9._/-]+' \
           | sed -E 's|^[^A-Za-z0-9._/-]||; s|[.,;:)]+$||' | sort -u)
done
[ "$CHECKED" -ge 15 ] \
  && pass "checked $CHECKED repo-relative references" \
  || fail "checked $CHECKED repo-relative references" "too few — the extractor found almost nothing"
[ -z "$BROKEN" ] \
  && pass "every referenced repo path resolves" \
  || fail "every referenced repo path resolves" "$BROKEN"

echo ""
echo "=== Sibling references inside docs/ resolve from docs/ ==="
# A doc in docs/ citing `docs/other.md` reads correctly from the repo root but
# breaks when rendered in place. Bare siblings are the right spelling there.
BADSIB=""
for d in docs/*.md; do
  grep -qE '(^|[^A-Za-z0-9._/-])docs/' "$d" && BADSIB="$BADSIB $(basename "$d")"
done
[ -z "$BADSIB" ] \
  && pass "no docs/ file uses a root-relative path to a sibling" \
  || fail "no docs/ file uses a root-relative path to a sibling" "$BADSIB"

echo ""
echo "=== Shipped scripts write no fixed /tmp path ==="
# rules/environment.md says temp files never go in a shared /tmp name; this repo
# ships that rule, so its own installer and hooks follow it. mktemp is fine, and
# so is /tmp/claude-$UID: Claude Code's own per-user folder, which lib.sh only
# compares paths against.
HITS=$(grep -nE '/tmp/[A-Za-z]' install.sh doctor.sh hooks/*.sh bin/*.sh tools/*.sh 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
  | grep -v '/tmp/claude-\$UID/')
[[ -z "$HITS" ]] && pass "no fixed /tmp file names" || fail "no fixed /tmp file names" "$HITS"

echo ""
echo "=== mktemp gets a template under \$TMPDIR ==="
# Without one, macOS mktemp uses /var/folders/…/T, not $TMPDIR, and the sandbox
# refuses that ("mkdtemp failed … Operation not permitted"). Hooks and install.sh
# run outside the sandbox; sandbox-trial.sh's bare call is the probe for this.
HITS=$(grep -nE '\$\([[:space:]]*mktemp' doctor.sh bin/*.sh tools/*.sh tests/*.sh 2>/dev/null | grep -v 'XXX' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v '^bin/sandbox-trial\.sh:')
[[ -z "$HITS" ]] && pass "every mktemp in tests, doctor and bin has a template" \
  || fail "every mktemp in tests, doctor and bin has a template" "$HITS"

echo ""
echo "=== The README hook table and settings.json name the same hooks ==="
# subagent-cache-guard and tcc-check were wired and shipped with no row, so the
# table a reader checks before installing undercounted what runs on their machine.
WIRED=$(jq -r '.hooks[][]?.hooks[]?.command // empty' config/settings.json 2>/dev/null \
  | grep -oE "hooks/[^[:space:]\"']+" | sed -E 's|^hooks/||; s/\.[A-Za-z0-9]+$//' | sort -u)
TABLE=$(awk '/^## What it blocks, asks and logs$/{f=1; next} f&&/^## /{exit} f' README.md)
ROWS=$(printf '%s\n' "$TABLE" | sed -nE 's/^\| `([^`]+)` \|.*/\1/p' | sort -u)
NOROW=$(comm -23 <(printf '%s\n' "$WIRED") <(printf '%s\n' "$ROWS") | tr '\n' ' ')
UNWIRED=$(comm -13 <(printf '%s\n' "$WIRED") <(printf '%s\n' "$ROWS") | tr '\n' ' ')
[ -n "$WIRED" ] && pass "settings.json wires hooks" || fail "settings.json wires hooks" "(none found)"
[ -z "${NOROW// /}" ] \
  && pass "every wired hook has a README row" \
  || fail "every wired hook has a README row" "missing: $NOROW"
[ -z "${UNWIRED// /}" ] \
  && pass "every README row is a wired hook" \
  || fail "every README row is a wired hook" "not wired: $UNWIRED"

echo ""
echo "=== The README layout block names every bin/ and tools/ file and each skill's folders ==="
# comms-hub's panel/ shipped with no mention in the map, beside the bin/ and
# tests/ the line did name.
# bin/ is what installs and tools/ stays in the clone, so each file must sit under
# its own heading: one listed under the other misstates what installs.
section() {  # a top-level heading -> the words of its line and the lines under it
  printf '%s\n' "$BLOCK" | awk -v h="$1" 'f && /^[^ ]/ {exit} f {print} index($0, h) == 1 {f=1; print}' \
    | tr -s ' \t' '\n\n'
}
# shellcheck disable=SC2046
MISSING_BIN=$(missing_in "$(section bin/)" $(tracked ':(glob)bin/*'))
# shellcheck disable=SC2046
MISSING_TOOLS=$(missing_in "$(section tools/)" $(tracked ':(glob)tools/*'))
[ -z "$MISSING_BIN" ] \
  && pass "every bin/ file is listed under bin/" \
  || fail "every bin/ file is listed under bin/" "missing:$MISSING_BIN"
[ -z "$MISSING_TOOLS" ] \
  && pass "every tools/ file is listed under tools/" \
  || fail "every tools/ file is listed under tools/" "missing:$MISSING_TOOLS"
MISSING_SKILL=""
for n in $(tracked ':(glob)skills/*/*' ':(glob)skills/*/**' | cut -d/ -f2 | sort -u); do
  line=$(entry "(^|[ ,])$n/")
  if [ -z "$line" ]; then MISSING_SKILL="$MISSING_SKILL $n/"; continue; fi
  for sub in $(tracked "skills/$n" | awk -F/ 'NF > 3 {print $3}' | sort -u); do
    printf '%s' "$line" | grep -qE "(^|[ ,(])$sub/" || MISSING_SKILL="$MISSING_SKILL $n/$sub/"
  done
done
[ -z "$MISSING_SKILL" ] \
  && pass "every skill and its folders appear on its layout line" \
  || fail "every skill and its folders appear on its layout line" "missing:$MISSING_SKILL"

echo ""
echo "=== Every hook, bin/ and tools/ file and .github script is named by another suite ==="
# A tool can share a suite (host-binary.test.sh covers tcc-check.sh), but one no
# suite names is one nothing exercises. This file names many of them, so it is
# left out; the suites are read once.
SUITES=$(for t in tests/*.test.sh; do [ "$t" = tests/repo-layout.test.sh ] || cat "$t"; done)
UNNAMED=""
for f in $(tracked ':(glob)hooks/*.sh' ':(glob)bin/*' ':(glob)tools/*' ':(glob).github/*.sh'); do
  b=$(basename "$f")
  # apt-get as the first step of every CI job: CI runs it, nothing local can.
  [ "$b" = install-apt-deps.sh ] && continue
  printf '%s' "$SUITES" | grep -qE "(^|[^A-Za-z0-9_.-])${b//./\\.}([^A-Za-z0-9_.-]|$)" || UNNAMED="$UNNAMED $f"
done
[ -z "$UNNAMED" ] \
  && pass "every hook, bin/ and tools/ file and .github script is named by a suite" \
  || fail "every hook, bin/ and tools/ file and .github script is named by a suite" "unnamed:$UNNAMED"

echo ""
echo "=== Every suite is named after what it tests, or listed on the README tests/ line ==="
# Twelve suites cover no single file of their own name; the tests/ line is where
# a reader learns what each is for.
TESTS_WORDS=$(entry '^tests/' | tr -cs 'A-Za-z0-9*-' '\n')
UNLISTED=""
for t in $(tracked ':(glob)tests/*.test.sh'); do
  n=$(basename "$t" .test.sh)
  [ -n "$(tracked "hooks/$n.sh" ":(glob)bin/$n.*" ":(glob)tools/$n.*" ".github/$n.sh")" ] && continue
  printf '%s\n' "$TESTS_WORDS" | grep -qxF "$n" && continue
  for w in $TESTS_WORDS; do
    case "$w" in *'*') case "$n" in "${w%\*}"*) continue 2 ;; esac ;; esac
  done
  UNLISTED="$UNLISTED $n"
done
[ -z "$UNLISTED" ] \
  && pass "every suite is named after its file or on the tests/ line" \
  || fail "every suite is named after its file or on the tests/ line" "unlisted:$UNLISTED"

echo ""
echo "=== Every skill's tests/run.py is skill-forge's, byte for byte ==="
# comms-hub's was an older copy (111 lines of diff): it copied only bin/ and
# tests/, so a mutation could not name a file elsewhere in the skill.
for f in skills/*/tests/run.py; do
  [ "$f" = skills/skill-forge/tests/run.py ] && continue
  cmp -s "$f" skills/skill-forge/tests/run.py && pass "$f is skill-forge's" || fail "$f differs from skill-forge's" "copy skills/skill-forge/tests/run.py over it"
done

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
