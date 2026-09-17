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
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

echo "=== The root holds only the documented entry points ==="
# README: "Two entry points sit at the root". README.md itself is the conventional
# exception; anything else is a doc that belongs in docs/.
STRAY=""
for f in *.md *.sh; do
  [ -e "$f" ] || continue
  case "$f" in README.md|install.sh|doctor.sh) continue ;; esac
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
    hooks/*.sh|bin/*.sh|install.sh|doctor.sh|.github/*.sh)
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
MISSING=""
for d in docs/*.md; do
  b=$(basename "$d")
  printf '%s' "$BLOCK" | grep -qF "$b" || MISSING="$MISSING $b"
done
[ -n "$BLOCK" ] \
  && pass "the layout block was found" || fail "the layout block was found" "(empty)"
[ -z "$MISSING" ] \
  && pass "every docs/ file appears in the layout block" \
  || fail "every docs/ file appears in the layout block" "missing:$MISSING"

echo ""
echo "=== The README layout block names every file in rules/ ==="
# Same reason as docs/: a rule that ships to every session on the machine but is
# invisible in the map is one nobody reviews before it starts shaping behaviour.
MISSING_RULES=""
for r in rules/*.md; do
  [ -e "$r" ] || continue
  b=$(basename "$r")
  printf '%s' "$BLOCK" | grep -qF "$b" || MISSING_RULES="$MISSING_RULES $b"
done
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
for src in README.md docs/*.md skills/*/SKILL.md config/upstream-contract.json; do
  [ -f "$src" ] || continue
  while read -r ref; do
    case "$ref" in *'<'*|*'*'*|*'$'*) continue ;; esac
    CHECKED=$((CHECKED+1))
    [ -e "$ref" ] || BROKEN="$BROKEN $src->$ref"
  done < <(sed 's|~/\.claude/[A-Za-z0-9._/-]*||g' "$src" \
           | grep -oE '(^|[^A-Za-z0-9._/-])(docs|bin|hooks|tests|config|skills|rules)/[A-Za-z0-9._/-]+' \
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
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
