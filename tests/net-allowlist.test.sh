#!/usr/bin/env bash
# Tests for bin/net-allowlist.sh
set -u
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_LOCAL_SETTINGS_DIR="$TMP/ls"
export CLAUDE_AUDIT_LOG="$TMP/audit.log"
unset CLAUDE_NET_ALLOWLIST
T="bin/net-allowlist.sh"
F="$CLAUDE_LOCAL_SETTINGS_DIR/net-allowlist.json"
PASS=0; FAIL=0
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
hosts() { jq -c '.netAllowlist' "$F" 2>/dev/null; }

echo "=== add ==="
OUT=$(bash "$T" add Logs.Corp.Example. flags.vendor.example 2>&1); rc=$?
[[ $rc == 0 && "$(hosts)" == '["flags.vendor.example","logs.corp.example"]' ]] \
  && pass "adds, lower-cased, trailing dot dropped, sorted" || fail "adds" "rc=$rc $(hosts) $OUT"
OUT=$(bash "$T" add com 2>&1); rc=$?
[[ $rc == 1 && "$OUT" == *"public suffix"* || $rc == 1 && "$OUT" == *"with a dot"* ]] && [[ "$(hosts)" == '["flags.vendor.example","logs.corp.example"]' ]] \
  && pass "refuses com, file unchanged" || fail "refuses com" "rc=$rc $(hosts) $OUT"
OUT=$(bash "$T" add a.example x.ngrok-free.app 2>&1); rc=$?
[[ $rc == 1 && "$OUT" == *"tunnel or request-capture"* && "$(hosts)" == *'"a.example"'* && "$(hosts)" != *ngrok* ]] \
  && pass "mixed: adds the good one, refuses the tunnel, exits 1" || fail "mixed add" "rc=$rc $(hosts) $OUT"
bash "$T" add a.example >/dev/null 2>&1
[[ "$(jq '.netAllowlist | map(select(. == "a.example")) | length' "$F")" == 1 ]] \
  && pass "adding twice keeps one entry" || fail "adding twice" "$(hosts)"
jq '. + {note: "kept"}' "$F" > "$F.t" && mv "$F.t" "$F"
bash "$T" add b.example >/dev/null 2>&1
[[ "$(jq -r .note "$F")" == kept ]] && pass "other keys in the file survive" || fail "other keys survive" "$(cat "$F")"

echo ""
echo "=== remove ==="
printf '%s' '{"netAllowlist":["a.example"]}' > "$CLAUDE_LOCAL_SETTINGS_DIR/work.json"
OUT=$(bash "$T" remove a.example 2>&1); rc=$?
[[ $rc == 0 && "$(hosts)" != *'"a.example"'* && "$OUT" == *"still listed in work.json"* ]] \
  && pass "removes, and names another file still listing it" || fail "remove" "rc=$rc $(hosts) $OUT"
OUT=$(bash "$T" remove B.Example. gone.example 2>&1); rc=$?
[[ $rc == 0 && "$(hosts)" != *'"b.example"'* && "$OUT" == *"b.example removed"* && "$OUT" == *"gone.example was not in"* ]] \
  && pass "remove lower-cases, drops a trailing dot, and says when a host was not listed" || fail "remove normalises" "rc=$rc $(hosts) $OUT"

echo ""
echo "=== a symlinked net-allowlist.json ==="
mkdir -p "$TMP/repo"; mv "$F" "$TMP/repo/net-allowlist.json"; ln -s "$TMP/repo/net-allowlist.json" "$F"
OUT=$(bash "$T" add sym.example 2>&1); rc=$?
[[ $rc == 0 && -L "$F" && "$(jq -r '.netAllowlist | index("sym.example") != null' "$TMP/repo/net-allowlist.json")" == true ]] \
  && pass "add writes the symlink's target and keeps the link" || fail "add through a symlink" "rc=$rc $(ls -l "$F") $OUT"
OUT=$(bash "$T" remove sym.example 2>&1); rc=$?
[[ $rc == 0 && -L "$F" && "$OUT" != *"still listed"* ]] \
  && pass "remove through the symlink does not report its own target" || fail "remove through a symlink" "rc=$rc $OUT"
rm "$F"; mv "$TMP/repo/net-allowlist.json" "$F"

echo ""
echo "=== a broken file ==="
cp "$F" "$TMP/good.json"; printf '%s' '{not json' > "$F"
OUT=$(bash "$T" add c.example 2>&1); rc=$?
[[ $rc == 1 && "$(cat "$F")" == '{not json' ]] && pass "add leaves a broken file alone" || fail "add on broken" "rc=$rc $OUT"
OUT=$(bash "$T" list 2>&1)
[[ "$OUT" == *"net-allowlist.json: not JSON"* && "$OUT" == *"a.example"*"work.json"* ]] \
  && pass "list names the broken file and still lists the others" || fail "list with broken" "$OUT"
cp "$TMP/good.json" "$F"

echo ""
echo "=== list ==="
printf '%s' '{"netAllowlist":["co.uk","ok.example"]}' > "$CLAUDE_LOCAL_SETTINGS_DIR/work.json"
OUT=$(CLAUDE_NET_ALLOWLIST="env.example" bash "$T" list 2>&1)
[[ "$OUT" == *"ok.example"* && "$OUT" == *"co.uk"*"refused, a public suffix"* && "$OUT" == *"env.example"*"CLAUDE_NET_ALLOWLIST"* ]] \
  && pass "lists entries, refusals with a reason, and the env list" || fail "list" "$OUT"

echo ""
echo "=== candidates ==="
NOW=$(date -u +%FT%TZ)
{
  echo "$NOW | GUARD | ask | network-guard | curl -s https://logs.corp.example/_search?q=a | /x"
  echo "$NOW | GUARD | ask | network-guard | curl -s https://logs.corp.example/_cat/indices | /x"
  echo "$NOW | GUARD | ask | network-guard | curl -sG https://logs.corp.example/_search --data-urlencode q=a | /x"
  echo "$NOW | GUARD | ask | network-guard | curl -s https://abc.ngrok-free.app/ | /x"
  echo "$NOW | GUARD | ask | network-guard | curl -s https://flags.vendor.example/ | /x"
  echo "$NOW | GUARD | deny | network-guard | curl -s https://denied.example/ | /x"
  echo "2020-01-01T00:00:00Z | GUARD | ask | network-guard | curl -s https://old.example/ | /x"
} > "$CLAUDE_AUDIT_LOG"
bash "$T" remove logs.corp.example >/dev/null 2>&1
OUT=$(bash "$T" candidates 30 2>&1)
LINE=$(grep 'logs.corp.example' <<<"$OUT")
[[ "$LINE" =~ ^[[:space:]]+2[[:space:]]+1[[:space:]] && "$LINE" == *"add with: net-allowlist.sh add logs.corp.example"* ]] \
  && pass "counts GET and body asks per host and suggests the add" || fail "candidate counts" "$OUT"
[[ "$OUT" == *"abc.ngrok-free.app"*"refused as an entry"* ]] && pass "a tunnel host is shown as refused" || fail "tunnel candidate" "$OUT"
[[ "$(grep 'flags.vendor.example' <<<"$OUT")" == *"allowed now"* ]] && pass "an already-listed host reads allowed now" || fail "allowed now" "$OUT"
[[ "$OUT" != *denied.example* && "$OUT" != *old.example* ]] && pass "skips denies and asks older than the window" || fail "window and denies" "$OUT"
[[ "$(grep -c GUARD "$CLAUDE_AUDIT_LOG")" == 7 ]] && pass "its own guard probes are not audited" || fail "audit untouched" "$(cat "$CLAUDE_AUDIT_LOG")"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
