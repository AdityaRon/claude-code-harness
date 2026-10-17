#!/usr/bin/env bash
# Tests for .github/approve-pr-ci.sh, with a fake gh and sleep on PATH.
set -u
SCRIPT=".github/approve-pr-ci.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_eq(){ if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=[$2] got=[$3]"; fi; }
check_contains(){ case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected [$2] in [$3]" ;; esac; }

SHA=d1b2287fea95fc4bca9e2214750d03507806ae23
OLD=5caf675e58f9c1ee088655391bedf91da3289c17
CI=.github/workflows/ci.yml DRIFT=.github/workflows/upstream-drift.yml

# GET serves runs.<n>.json for the n-th lookup, else runs.json. A run approved
# here reads back as queued, as on GitHub, unless FAKE_STAYS_HELD is set.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") [ -z "${FAKE_VIEW_FAIL:-}" ] || exit 1; printf '{"headRefOid":"%s"}\n' "$FAKE_SHA" ;;
  "api -X")
    printf '%s\n' "$*" >> "$FAKE_DIR/calls.log"
    ID=$(printf '%s' "$4" | sed -E 's|^repos/o/r/actions/runs/([0-9]+)/approve$|\1|')
    if [ "$ID" = "${FAKE_APPROVE_FAIL:-}" ]; then
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1
    fi
    echo "$ID" >> "$FAKE_DIR/approved" ;;
  "api repos/"*)
    printf 'GET %s\n' "$2" >> "$FAKE_DIR/calls.log"
    N=$(( $(cat "$FAKE_DIR/count" 2>/dev/null || echo 0) + 1 )); echo "$N" > "$FAKE_DIR/count"
    F="$FAKE_DIR/runs.$N.json"; [ -f "$F" ] || F="$FAKE_DIR/runs.json"
    OK="[$(paste -sd, "$FAKE_DIR/approved")]"; [ -z "${FAKE_STAYS_HELD:-}" ] || OK="[]"
    jq --argjson ok "$OK" '.workflow_runs |= map(.id as $i
      | if any($ok[]; . == $i) then .status = "queued" | .conclusion = null else . end)' "$F" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 99 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "$1" >> "$FAKE_DIR/sleeps"\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin/gh" "$TMP/bin/sleep"
export FAKE_DIR="$TMP" FAKE_SHA="$SHA"

# row <id> <path> <sha> <status> <conclusion|null>
row(){ c=$5; [ "$c" = null ] || c="\"$c\""
  printf '{"id":%s,"path":"%s","head_sha":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3" "$4" "$c"; }
held(){ row "$1" "$2" "${3:-$SHA}" completed action_required; }
runs(){ f=$1; shift; local IFS=,; printf '{"workflow_runs":[%s]}\n' "$*" > "$TMP/$f"; }
reset(){ rm -f "$TMP"/runs*.json "$TMP/count" "$TMP/sleeps"; : > "$TMP/calls.log"; : > "$TMP/approved"; }
# run <PR>: OUT is stdout, ERR stderr, RC the exit code.
run(){ OUT=$(PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=o/r bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
approved(){ sort -n "$TMP/approved" | tr '\n' ' '; }
gets(){ grep -c '^GET ' "$TMP/calls.log"; }
sleeps(){ if [ -f "$TMP/sleeps" ]; then wc -l < "$TMP/sleeps" | tr -d ' '; else echo 0; fi; }

echo "=== approves every held run on the head and reports the CI run ==="
reset
runs runs.json "$(held 101 $CI)" "$(held 102 $DRIFT)" "$(held 90 $CI $OLD)" \
  "$(row 103 .github/workflows/claude.yml $SHA completed success)"
run 99
check_eq "exit 0" "0" "$RC"
check_eq "prints the CI run id" "101" "$OUT"
check_eq "approves the CI and drift runs on the head only" "101 102 " "$(approved)"
check_contains "logs the approval" "approved run 101 ($CI) for #99." "$ERR"
check_contains "asks for the full head SHA's pull_request runs" "GET repos/o/r/actions/runs?head_sha=$SHA&event=pull_request" "$(cat "$TMP/calls.log")"
check_eq "re-reads once to see the CI run leave the held state" "2 1" "$(gets) $(sleeps)"

echo ""
echo "=== leaves runs that are not held alone ==="
reset
runs runs.json "$(row 201 $CI $SHA in_progress null)" "$(row 202 $DRIFT $SHA completed success)"
run 99
check_eq "exit 0" "0" "$RC"
check_eq "prints the running CI run id" "201" "$OUT"
check_eq "approves nothing" "" "$(approved)"
check_contains "says it is not held" "run 201 ($CI) for #99 is not held." "$ERR"
check_eq "one lookup, no wait" "1 0" "$(gets) $(sleeps)"

echo ""
echo "=== retries until the CI run itself appears ==="
reset
runs runs.1.json
runs runs.2.json "$(held 302 $DRIFT)"
runs runs.json "$(held 302 $DRIFT)" "$(held 301 $CI)"
run 99
check_eq "prints the CI run id, not the drift one" "301" "$OUT"
check_eq "approves each held run once" "301 302 " "$(approved)"
check_eq "four lookups, three waits of 6 s" "4 3 6" "$(gets) $(sleeps) $(sort -u "$TMP/sleeps")"

echo ""
echo "=== gives up after 10 lookups when no CI run appears ==="
reset
runs runs.json
run 99
check_eq "exit 0" "0" "$RC"
check_eq "prints nothing, so the caller dispatches" "" "$OUT"
check_contains "warns" "::warning::approve-pr-ci: no $CI pull_request run appeared for #99 at $SHA." "$ERR"
check_eq "10 lookups, 9 waits" "10 9" "$(gets) $(sleeps)"

echo ""
echo "=== a refused approval warns and exits 0 ==="
reset
runs runs.json "$(held 502 $DRIFT)" "$(held 501 $CI)"
FAKE_APPROVE_FAIL=501 run 99
check_eq "exit 0" "0" "$RC"
check_eq "prints nothing, so the caller dispatches" "" "$OUT"
check_contains "warns with GitHub's message" "::warning::approve-pr-ci: approval refused for run 501 ($CI): gh: Resource not accessible by integration (HTTP 403)" "$ERR"
check_eq "stops at the refusal" "1 0" "$(gets) $(sleeps)"
reset
runs runs.json "$(held 502 $DRIFT)" "$(held 501 $CI)"
FAKE_APPROVE_FAIL=502 run 99
check_eq "a refused drift run does not stop CI" "501" "$OUT"
check_contains "and is warned about" "approval refused for run 502 ($DRIFT)" "$ERR"

echo ""
echo "=== a run still held after approval is approved once, then given up ==="
reset
runs runs.json "$(held 601 $CI)"
FAKE_STAYS_HELD=1 run 99
check_eq "prints nothing" "" "$OUT"
check_eq "one approval in 10 lookups" "601 10" "$(approved)$(gets)"
check_contains "warns" "run 601 ($CI) for #99 is still held after approval." "$ERR"

echo ""
echo "=== bad input warns and exits 0 ==="
reset
run latest
check_eq "exit 0 on a bad PR number" "0 " "$RC $OUT"
check_contains "warns" "bad PR number [latest]" "$ERR"
FAKE_VIEW_FAIL=1 run 99
check_eq "exit 0 when the PR cannot be read" "0 " "$RC $OUT"
check_contains "warns" "could not read the head of #99" "$ERR"
check_eq "no lookup in either case" "0" "$(gets)"

echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
