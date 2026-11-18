#!/usr/bin/env bash
# Tests for bin/tracker-prune.py: what moves and what never does, the refusals, and --write's
# order (append, check the archive, re-check the tracker, replace) under injected faults.
# Fixtures are invented. A mutation run points CCH_TRACKER_PRUNE_PY at a changed copy.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TP=${CCH_TRACKER_PRUNE_PY:-$REPO/bin/tracker-prune.py}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX")
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
unset CLAUDE_TRACKER_PRUNE_TEST_PAUSE CLAUDE_TRACKER_PRUNE_TEST_FAULT
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }
check_eq()       { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }
same()  { if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$2 differs from $3"; fi; }
gone()  { if [ -e "$2" ] || [ -L "$2" ]; then fail "$1" "$2 exists"; else pass "$1"; fi; }
tp()    { python3 "$TP" "$@" --date 2026-11-18; }
mode()  { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

ledger() {  # ledger FILE: the main fixture
  cat > "$1" <<'MD'
# Widget ledger

Prose that says done: this line is never moved.

## Open

| ID | What | Status |
|---|---|---|
| W-1 | wire the knob | open |
| W-2 | paint the lid | **Done** (2026-11-02) |
| W-3 | sand the edge | not done |
| W-4 | glue the hinge | done? |
| W-5 | fit the latch | Closed (#41) |
| W-6 | oil the gear | `settled` 2026-10-30 |

| Name | Note |
|---|---|
| plain | done |

- [x] order screws
  from the hardware shop
  - [x] counted them
- [x] order paint
  - [ ] pick a colour
- [ ] order brushes
  - [x] measured the handle
- DONE: booked the van
- **CLOSED:** the shed door ticket
- Done talking about it
- settled the bill without a colon

## Settled

```
| ID | Status |
|---|---|
| F-1 | done |
- [x] in a fence
- DONE: in a fence
```

### Done
MD
}

echo "=== a dry run lists what would move and writes nothing ==="
T="$TMP/a/trackers"; mkdir -p "$T"; ledger "$T/work.md"; cp "$T/work.md" "$TMP/a/orig.md"
OUT=$(tp "$T/work.md"); RC=$?
check_eq "exit 0" "0" "$RC"
same "the tracker is untouched" "$T/work.md" "$TMP/a/orig.md"
gone "no archive is made" "$T/work-archive.md"
check_contains "counts by kind" "6 rows to move (3 table, 1 [x], 2 DONE:/CLOSED:/SETTLED:)" "$OUT"
check_contains "bytes before and after" "work.md: $(wc -c < "$T/work.md" | tr -d ' ') bytes now" "$OUT"
check_contains "the archive's size after" "work-archive.md: new, " "$OUT"
check_contains "rows with line numbers" "L10     | W-2 | paint the lid" "$OUT"
check_contains "an item's lines counted" "L20     - [x] order screws (+2 lines)" "$OUT"
check_contains "a done item with an open child is reported" "1 done item(s) with an open [ ] under them (line 23)" "$OUT"
check_contains "a table with no status column is reported" "1 table(s) with no Status or State column (line 16)" "$OUT"
check_contains "a near miss is counted" "1 status(es) that start with settled, closed or done but are not one (line 12)" "$OUT"
check_contains "says it is a dry run" "dry run: nothing written" "$OUT"

echo ""
echo "=== --write moves exactly those rows ==="
OUT=$(tp "$T/work.md" --write); RC=$?
check_eq "exit 0" "0" "$RC"
check_contains "says what moved" "moved 6 rows" "$OUT"
NEW=$(cat "$T/work.md"); ARC=$(cat "$T/work-archive.md")
for gone_row in "| W-2 |" "| W-5 |" "| W-6 |" "order screws" "from the hardware shop" "counted them" "booked the van" "shed door"; do
  check_absent "moved out: $gone_row" "$gone_row" "$NEW"
  check_contains "in the archive: $gone_row" "$gone_row" "$ARC"
done
for kept_row in "| W-1 |" "| W-3 | sand the edge | not done |" "| W-4 |" "| plain | done |" "- [x] order paint" "pick a colour" \
    "- [ ] order brushes" "measured the handle" "- Done talking about it" "settled the bill" "| F-1 | done |" \
    "- [x] in a fence" "- DONE: in a fence" "### Done" "Prose that says done"; do
  check_contains "kept: $kept_row" "$kept_row" "$NEW"
done
check_eq "8 lines left the tracker" "$(( $(wc -l < "$TMP/a/orig.md") - 8 ))" "$(( $(wc -l < "$T/work.md") ))"
check_eq "a new archive's first line says grep" "# Archive: settled rows tracker-prune.py moved out. grep it, never read it whole." "$(head -1 "$T/work-archive.md")"
check_contains "under a dated header" $'\n## 2026-11-18\n' "$ARC"
check_contains "with the section and the table header" $'### Open\n| ID | What | Status |\n|---|---|---|\n| W-2 |' "$ARC"
MISSING=""
while IFS= read -r l; do
  grep -qxF -- "$l" "$T/work.md" || grep -qxF -- "$l" "$T/work-archive.md" || MISSING="$MISSING [$l]"
done < "$TMP/a/orig.md"
check_eq "every line is in one file or the other" "" "$MISSING"
cp "$T/work-archive.md" "$TMP/a/arc1.md"
OUT=$(tp "$T/work.md" --write)
check_contains "a second run: nothing to move" "nothing to move" "$OUT"
same "and the archive is untouched" "$T/work-archive.md" "$TMP/a/arc1.md"
printf -- '- SETTLED: one more\n' >> "$T/work.md"
python3 "$TP" "$T/work.md" --write --date 2026-11-19 >/dev/null
check_eq "a later run adds a new dated block" "2" "$(grep -c '^## 2026-11-1[89]$' "$T/work-archive.md")"
check_eq "and the grep line stays one" "1" "$(grep -c '^# Archive:' "$T/work-archive.md")"

echo ""
echo "=== --write is the only thing that writes ==="
T="$TMP/b/trackers"; mkdir -p "$T"; ledger "$T/work.md"; cp "$T/work.md" "$TMP/b/orig.md"
tp "$T/work.md" --all >/dev/null
same "--all alone writes nothing" "$T/work.md" "$TMP/b/orig.md"
gone "and makes no archive" "$T/work-archive.md"

echo ""
echo "=== the listing is capped at 40 rows ==="
T="$TMP/c/trackers"; mkdir -p "$T"
{ printf '| ID | State |\n|---|---|\n'; i=1; while [ $i -le 44 ]; do printf '| C-%d | done |\n' $i; i=$((i+1)); done
  printf '| C-45 %s | done |\n' "$(head -c 150 /dev/zero | tr '\0' z)"; } > "$T/many.md"
OUT=$(tp "$T/many.md")
check_eq "40 rows listed" "40" "$(printf '%s\n' "$OUT" | grep -c '^  L')"
check_contains "and how to see the rest" "1-40 of 45 (--all lists every one)" "$OUT"
OUT=$(tp "$T/many.md" --all)
check_eq "--all lists 45" "45" "$(printf '%s\n' "$OUT" | grep -c '^  L')"
LONG=$(printf '%s\n' "$OUT" | grep 'C-45')
check_contains "a long row is cut" "…" "$LONG"
check_eq "to 100 characters" "100" "$(printf '%s' "${LONG#  L47     }" | python3 -c 'import sys; print(len(sys.stdin.read()))')"

echo ""
echo "=== bytes, line endings and mode survive ==="
T="$TMP/d/trackers"; mkdir -p "$T"
printf '| A | Status |\r\n|---|---|\r\n| a | done |\r\n| b | open — still |' > "$T/crlf.md"; chmod 640 "$T/crlf.md"
tp "$T/crlf.md" --write >/dev/null
printf '| A | Status |\r\n|---|---|\r\n| b | open — still |' > "$TMP/d/want.md"
same "CRLF kept, no final newline added" "$T/crlf.md" "$TMP/d/want.md"
check_contains "the moved row keeps its CRLF" $'| a | done |\r' "$(cat "$T/crlf-archive.md")"
check_eq "the mode is kept" "0o640" "$(mode "$T/crlf.md")"

echo ""
echo "=== a linked tracker is rewritten at its target; the archive goes beside the link ==="
T="$TMP/e/trackers"; mkdir -p "$T" "$TMP/e/real"; ledger "$TMP/e/real/work.md"; ln -s "$TMP/e/real/work.md" "$T/work.md"
tp "$T/work.md" --write >/dev/null
if [ -L "$T/work.md" ]; then pass "the link is still a link"; else fail "the link is still a link" "replaced by a file"; fi
check_absent "its target was pruned" "| W-2 |" "$(cat "$TMP/e/real/work.md")"
check_contains "the archive is beside the link" "| W-2 |" "$(cat "$T/work-archive.md" 2>/dev/null)"
gone "not beside the target" "$TMP/e/real/work-archive.md"

echo ""
echo "=== refusals: exit 3, nothing written ==="
refused() {  # refused NAME FILE ARCHIVE_STATE [ARGS]: exit 3, FILE untouched; ARCHIVE_STATE gone|same
  local name=$1 f=$2 want=$3; shift 3
  cp "$f" "$TMP/ref.orig"
  local out rc; out=$(tp "$f" "$@" 2>&1); rc=$?
  check_eq "$name: exit 3" "3" "$rc"
  check_contains "$name: says so" "refused, nothing written" "$out"
  same "$name: tracker untouched" "$f" "$TMP/ref.orig"
  [ "$want" = gone ] && gone "$name: no archive" "${f%.md}-archive.md"
}
T="$TMP/f/trackers"; mkdir -p "$T"
printf '| A | Status |\n|---|---|\n| a | done |\n```\nnever closed\n' > "$T/fence.md"
refused "an unclosed fence" "$T/fence.md" gone --write
refused "an unclosed fence, dry run" "$T/fence.md" gone
printf '| A | B | Status |\n|---|---|---|\n| a | b | done |\n| two | cells |\n' > "$T/rows.md"
refused "a malformed row in a status table" "$T/rows.md" gone --write
ledger "$T/x-archive.md"   # rows that would move, so only the name refuses it
refused "an archive named as the tracker" "$T/x-archive.md" same --write
gone "and no archive of an archive" "$T/x-archive-archive.md"
printf '| A | Status |\n|---|---|\n| a | done \377 |\n' > "$T/bin.md"
refused "not UTF-8" "$T/bin.md" gone --write
ledger "$T/dir.md"; mkdir "$T/dir-archive.md"
refused "an archive that is a folder" "$T/dir.md" same --write
ledger "$T/lnk.md"; : > "$TMP/f/elsewhere.md"; ln -s "$TMP/f/elsewhere.md" "$T/lnk-archive.md"
refused "an archive that is a symlink" "$T/lnk.md" same --write
check_eq "the symlinked archive's target is untouched" "0" "$(( $(wc -c < "$TMP/f/elsewhere.md") ))"

echo ""
echo "=== a fault the checks must catch: the tracker loses no line ==="
T="$TMP/g/trackers"; mkdir -p "$T"; ledger "$T/work.md"
CLAUDE_TRACKER_PRUNE_TEST_FAULT=drop-line refused "a line dropped from the new tracker" "$T/work.md" gone --write
ledger "$T/work.md"
CLAUDE_TRACKER_PRUNE_TEST_FAULT=drop-line refused "the same, dry run" "$T/work.md" gone

echo ""
echo "=== a short append: the archive is put back, the tracker untouched ==="
T="$TMP/h/trackers"; mkdir -p "$T"; ledger "$T/work.md"
# The archive already holds the very rows this run moves, so finding them in it proves nothing.
cp "$T/work.md" "$T/work-archive.md"; cp "$T/work-archive.md" "$TMP/h/arc.orig"
CLAUDE_TRACKER_PRUNE_TEST_FAULT=short-append refused "a short append to an archive holding the same rows" "$T/work.md" same --write
same "the archive is back to its bytes" "$T/work-archive.md" "$TMP/h/arc.orig"
rm -f "$T/work-archive.md"; ledger "$T/work.md"   # each case starts from the whole fixture
CLAUDE_TRACKER_PRUNE_TEST_FAULT=short-append refused "a short append to a new archive" "$T/work.md" gone --write
if [ "$(id -u)" = 0 ]; then
  echo "  (skipped: a read-only archive is writable as root)"
else
  ledger "$T/work.md"; : > "$T/work-archive.md"; chmod 444 "$T/work-archive.md"
  refused "an archive it cannot append to" "$T/work.md" same --write
  chmod 644 "$T/work-archive.md"; rm -f "$T/work-archive.md"
fi

echo ""
echo "=== an edit while it runs: the archive is put back and the edit kept ==="
T="$TMP/i/trackers"; mkdir -p "$T"; ledger "$T/work.md"; cp "$T/work.md" "$TMP/i/orig.md"
GO="$TMP/i/go"
CLAUDE_TRACKER_PRUNE_TEST_PAUSE="$GO" python3 "$TP" "$T/work.md" --write --date 2026-11-18 > "$TMP/i/out" 2>&1 & PID=$!
n=0; while [ ! -e "$GO.ready" ] && [ $n -lt 200 ]; do sleep 0.05; n=$((n+1)); done
check_contains "at the pause the archive holds the rows" "| W-2 |" "$(cat "$T/work-archive.md" 2>/dev/null)"
same "and the tracker still holds them" "$T/work.md" "$TMP/i/orig.md"
printf '| W-8 | a late edit | open |\n' >> "$T/work.md"
: > "$GO"; wait "$PID"; RC=$?
check_eq "exit 3" "3" "$RC"
check_contains "says the tracker changed" "changed while this ran" "$(cat "$TMP/i/out")"
check_contains "the late edit is kept" "a late edit" "$(cat "$T/work.md")"
check_contains "and the rows" "| W-2 |" "$(cat "$T/work.md")"
gone "the archive it made is removed" "$T/work-archive.md"

echo ""
results
