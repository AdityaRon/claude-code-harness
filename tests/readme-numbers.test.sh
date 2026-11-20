#!/usr/bin/env bash
# README.md's numbers and figures, against docs/data/readme-numbers.json and the
# files it cites. The README kept a 2026-10-17 wait of 54.5 ms for a month in which
# the guards were rewritten; numbers read from this repo are read again here by
# code that shares nothing with tools/readme-figures.py.
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source tests/lib.sh || exit 1
DATA=docs/data/readme-numbers.json
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

same() {  # "a b ..." "c d ...": the same numbers, read as numbers (64.0 is 64)
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, " "); if (n == 0 || n != split(b, y, " ")) exit 1
    for (i = 1; i <= n; i++) if (x[i] + 0 != y[i] + 0) exit 1 }'
}
entry() {  # RELEASE: its CHANGELOG.md entry, without the heading
  awk -v h="## $1 (" 'index($0, h) == 1 { f = 1; next } f && /^## v/ { exit } f' CHANGELOG.md
}
pairs() {  # CELLS...: from table cells "62.2 → 62.6 ms (+1%)", the two numbers of each
  local c; for c in "$@"; do printf '%s ' "$(printf '%s' "$c" | sed -E 's/^ *([0-9.]+) → ([0-9.]+).*/\1 \2/')"; done
}

echo "=== Regenerating changes nothing ==="
if OUT=$(python3 tools/readme-figures.py --check 2>&1); then
  pass "README.md's blocks, the JSON's series and docs/figures/ are what --write makes"
else
  fail "README.md's blocks, the JSON's series and docs/figures/ are what --write makes" "$OUT"
fi

echo ""
echo "=== The cited release's Bash row, read again from CHANGELOG.md ==="
REL=$(jq -r .cited_release "$DATA")
ROW=$(entry "$REL" | grep -m1 '^| Bash |')
IFS='|' read -r _ _ CALLS P50 _ P95 _ <<< "$ROW"
GOT="$(pairs "$P50" "$P95")"
WANT=$(jq -r '.summary[] | select(.id == "bash-wait") | .values | "\(.p50_base) \(.p50_head) \(.p95_base) \(.p95_head)"' "$DATA")
[ -n "$ROW" ] && pass "$REL has a Bash row" || fail "$REL has a Bash row" "(none in its entry)"
[ "$(jq -r '.summary[] | select(.id == "bash-wait") | .release' "$DATA")" = "$REL" ] \
  && pass "the Bash row cited is the cited release's" || fail "the Bash row cited is the cited release's" "release differs from $REL"
same "$GOT" "$WANT" && pass "p50 and p95, base and head, match: $GOT" || fail "p50 and p95 match" "changelog: $GOT, JSON: $WANT"
NCELL=$(jq -r '.summary[] | select(.id == "bash-wait") | .n' "$DATA")
[ "${NCELL%% *}" = "${CALLS// /}" ] && pass "n is the row's ${CALLS// /} Bash calls" || fail "n is the row's Bash calls" "row: $CALLS, JSON: $NCELL"
LAST=$(jq -r '.series.bash_wait_runs[-1] | "\(.p50_ms[0]) \(.p50_ms[1]) \(.p95_ms[0]) \(.p95_ms[1])"' "$DATA")
same "$GOT" "$LAST" && pass "the chart's last point is that row" || fail "the chart's last point is that row" "series: $LAST"

echo ""
echo "=== bash-guards.sh exec counts, read again from CHANGELOG.md ==="
execs_row() {  # RELEASE: payloads and the base and head execs from its first launches table
  entry "$1" | awk -F'|' '/\| execs per payload \|/ { t = 1; next } t && !/^\|/ { exit }
    t && $2 ~ /^ bash-guards\.sh / { print $3 "|" $4; exit }'
}
FOUND=0; BAD=""
for r in $(awk -v h="## $REL (" 'index($0, h) == 1 { f = 1 } f && /^## v/ { print $2 }' CHANGELOG.md); do
  ROW=$(execs_row "$r"); [ -n "$ROW" ] || continue
  FOUND=$((FOUND + 1))
  GOT="${ROW%%|*} $(pairs "${ROW#*|}")"
  WANT=$(jq -r --arg r "$r" '.series.bash_guards_execs[] | select(.release == $r) | "\(.payloads) \(.execs_per_payload[0]) \(.execs_per_payload[1])"' "$DATA")
  same "$GOT" "$WANT" || BAD="$BAD $r(changelog: $GOT; JSON: ${WANT:-none})"
done
NJSON=$(jq '.series.bash_guards_execs | length' "$DATA")
[ "$FOUND" -gt 0 ] && [ "$FOUND" = "$NJSON" ] \
  && pass "$FOUND launches tables from $REL down, $NJSON in the JSON" \
  || fail "every launches table is in the JSON" "changelog: $FOUND, JSON: $NJSON"
[ -z "$BAD" ] && pass "payloads and execs per payload match for each" || fail "payloads and execs per payload match" "$BAD"
XREL=$(jq -r '.summary[] | select(.id == "execs") | .release' "$DATA")
ROW=$(execs_row "$XREL")
GOT="$(pairs "${ROW#*|}")"
WANT=$(jq -r '.summary[] | select(.id == "execs") | .values | "\(.base) \(.head)"' "$DATA")
same "$GOT" "$WANT" && pass "the summary's execs row is $XREL's: $GOT" || fail "the summary's execs row is $XREL's" "changelog: $GOT, JSON: $WANT"
NCELL=$(jq -r '.summary[] | select(.id == "execs") | .n' "$DATA")
NROW="${ROW%%|*}"; NROW="${NROW// /}"
[ -n "$NROW" ] && [ "${NCELL%% *}" = "$NROW" ] \
  && pass "its n is the table's $NROW payloads" || fail "its n is the table's payload count" "table: $NROW, JSON: $NCELL"

echo ""
echo "=== Each summary row's numbers are in the sentences it quotes ==="
# A quote with a url is a PR or issue body, which a test cannot fetch: it holds the value, not the source.
python3 - "$DATA" > "$TMP/quotes" 2>&1 <<'PY'
import json, re, sys
WORDS = dict((w, i) for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve".split()))
SKIP = r"v\d+(?:\.\d+)+|#\d+|\d{4}-\d{2}-\d{2}|\bp\d+\b"

def numbers(text, words=False):
    text = re.sub(SKIP, " ", text)
    out = {float(m.replace(",", "")) for m in re.findall(r"\d[\d,]*(?:\.\d+)?", text)}
    if words:
        out |= {float(WORDS[w]) for w in re.findall(r"[a-z]+", text.lower()) if w in WORDS}
    return out

def show(v):
    return ("%d" % v) if isinstance(v, int) else (v if isinstance(v, str) else repr(v))

rows, bad, files, urls = json.load(open(sys.argv[1], encoding="utf-8"))["summary"], [], 0, 0
for r in rows:
    quoted = ""
    for q in r.get("quotes", []):
        quoted += " " + q["text"]
        if "file" in q:
            files += 1
            try:
                found = q["text"] in open(q["file"], encoding="utf-8").read()
            except OSError:
                found = False
            if not found:
                bad.append("%s: not in %s: %s" % (r["id"], q["file"], q["text"]))
        else:
            urls += 1
    unused = [k for k in r["values"] if "{%s}" % k not in r["measured"]]
    if unused:
        bad.append("%s: values not in measured: %s" % (r["id"], unused))
    text = r["measured"].format(**{k: show(v) for k, v in r["values"].items()}) + " " + r["n"]
    missing = sorted(numbers(text) - numbers(quoted, words=True))
    if missing:
        bad.append("%s: %s in no quote" % (r["id"], ", ".join("%g" % m for m in missing)))
print("%d rows, %d quotes from files, %d from PR and issue bodies" % (len(rows), files, urls))
for b in bad:
    print(b)
sys.exit(1 if bad or len(rows) < 6 else 0)
PY
RC=$?
[ "$RC" = 0 ] && pass "$(head -n 1 "$TMP/quotes"): every file quote found, every number quoted" \
  || fail "every file quote found, every number quoted" "$(cat "$TMP/quotes")"

echo ""
echo "=== README.md's links and anchors resolve ==="
python3 - README.md > "$TMP/links" 2>&1 <<'PY'
import os, re, sys

def slugs(path):
    out, seen, fence = set(), {}, False
    for line in open(path, encoding="utf-8"):
        if line.lstrip().startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", m.group(1))
        s = re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")
        k = seen.get(s, 0)
        seen[s] = k + 1
        out.add(s if k == 0 else "%s-%d" % (s, k))
    for m in re.finditer(r'<a (?:name|id)="([^"]+)"', open(path, encoding="utf-8").read()):
        out.add(m.group(1))
    return out

readme = sys.argv[1]
text = open(readme, encoding="utf-8").read()
body = re.sub(r"```.*?```", "", text, flags=re.S)
targets = re.findall(r"\]\(([^)\s]+)\)", body) + re.findall(r'(?:src|srcset|href)="([^"]+)"', body)
bad, n = [], 0
for t in targets:
    if re.match(r"[a-z]+:", t):
        continue
    n += 1
    path, _, anchor = t.partition("#")
    full = os.path.join(os.path.dirname(readme) or ".", path) if path else readme
    if not os.path.exists(full):
        bad.append("%s (no such file)" % t)
    elif anchor and full.endswith(".md") and anchor not in slugs(full):
        bad.append("%s (no such heading)" % t)
print("%d links" % n)
for b in bad:
    print("broken: " + b)
sys.exit(1 if bad or n < 10 else 0)
PY
RC=$?
[ "$RC" = 0 ] && pass "$(head -n 1 "$TMP/links"), all resolve" || fail "every link resolves" "$(cat "$TMP/links")"

echo ""
echo "=== Every figure parses, and README.md shows each light and dark pair ==="
if OUT=$(python3 -c 'import sys, xml.etree.ElementTree as E; [E.parse(f) for f in sys.argv[1:]]' docs/figures/*.svg 2>&1); then
  pass "docs/figures/*.svg parse as XML"
else
  fail "docs/figures/*.svg parse as XML" "$OUT"
fi
UNSHOWN=""
for f in docs/figures/*.svg; do grep -qF "\"$f\"" README.md || UNSHOWN="$UNSHOWN $f"; done
[ -z "$UNSHOWN" ] && pass "README.md shows every figure" || fail "README.md shows every figure" "not shown:$UNSHOWN"

echo ""
echo "=== README.md's own prose carries no number ==="
# --check sees only the generated blocks, so a number typed into the prose would go stale unseen.
# Code spans, link targets, dates, versions, issue numbers and bash versions are not counts.
PROSE=$(awk '/<!-- readme-figures:[a-z-]+:begin -->/{g=1} /<!-- readme-figures:[a-z-]+:end -->/{g=0; next}
  /^```/{f=!f; next} !g && !f' README.md)
HITS=$(printf '%s\n' "$PROSE" | sed -E 's/`[^`]*`//g; s/\]\([^)]*\)/]/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}//g;
  s/v[0-9]+(\.[0-9]+)+//g; s/#[0-9]+//g; s/bash [0-9]+(\.[0-9]+)*//g' | grep -nE '[0-9]')
[ -n "$PROSE" ] && [ -z "$HITS" ] && pass "no number outside the generated blocks" \
  || fail "no number outside the generated blocks" "${HITS:-(no prose found)}"

echo ""
echo "=== No private paths, em dashes or dollar amounts ==="
PUBLIC="README.md $DATA $(ls docs/figures/*.svg)"
# shellcheck disable=SC2086  # the names hold no spaces
HITS=$(grep -nE '/Users/|/home/|/tmp/|/private/|/var/folders/|[A-Za-z]:\\Users|~[a-z][a-z0-9_-]*/' $PUBLIC)
[ -z "$HITS" ] && pass "no machine paths" || fail "no machine paths" "$HITS"
# shellcheck disable=SC2086
HITS=$(grep -n '—' $PUBLIC)
[ -z "$HITS" ] && pass "no em dashes" || fail "no em dashes" "$HITS"
# shellcheck disable=SC2086
HITS=$(grep -nE '\$ ?[0-9]|[0-9] ?(USD|dollars)' $PUBLIC)
[ -z "$HITS" ] && pass "no dollar amounts" || fail "no dollar amounts" "$HITS"

echo ""
results
