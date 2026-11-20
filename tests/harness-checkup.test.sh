#!/usr/bin/env bash
# Tests for bin/harness-checkup.py, on tests/lib/transcripts.py's corpus in a temp HOME: three
# ranked costs with n and window, no prompt text, no dollar amount, no network, nothing written,
# and the same from a flat install in ~/.claude.
set -u
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null || { echo "  SKIP: no python3"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
command -v jq >/dev/null || { echo "  SKIP: no jq (memory-verify needs it)"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
REPO=$PWD
H="$TMP/home"
CANARY=CANARY-7f3a91c2

# The corpus: 46% of its cache-write tokens are ttl-gap rewrites (75k of 162k), one approved guard ask.
python3 "$REPO/tests/lib/transcripts.py" "$H/.claude/projects" --canary "$CANARY" >/dev/null
# bash-guards' timing log: interpreter-guard at 1.5 s on every call, p95 1,500 ms.
mkdir -p "$H/.claude/logs" "$H/.claude/jobs/0a1b2c3d"
AT=$(( $(date +%s) - 3600 ))
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'toolu_t%s\tBash\tgit-guard=0.020:0:allow\tinterpreter-guard=1.500:0:allow\tat=%s\n' "$i" "$AT"
done > "$H/.claude/logs/guard-timing.log"
echo '{}' > "$H/.claude/jobs/0a1b2c3d/state.json"
# A memory store: a 150-line index (75% of 200), and a GitHub claim offline mode must not look up.
M="$H/.claude/projects/-work-proj/memory"; mkdir -p "$M"
{ echo "- [Fix](fix.md) — the fix"; for i in $(seq 2 150); do echo "- line $i"; done; } > "$M/MEMORY.md"
printf -- '---\nname: fix\ndescription: d\nmetadata:\n  type: project\n---\nverify:\n  - gh acme/api#1 merged\n\nLanded.\n' > "$M/fix.md"

# Every network client on PATH logs and fails; git logs its subcommand and runs.
STUB="$TMP/stub"; LOG="$TMP/net.log"; mkdir -p "$STUB"; : > "$LOG"
for c in gh curl wget claude ssh nc; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 1\n' "$c" "$LOG" > "$STUB/$c"; chmod +x "$STUB/$c"
done
GIT=$(command -v git)
printf '#!/usr/bin/env bash\necho "git $*" >> "%s.git"\nexec "%s" "$@"\n' "$LOG" "$GIT" > "$STUB/git"; chmod +x "$STUB/git"

check() {  # check SCRIPT: run it as this HOME would, with the stubs first on PATH
  OUT=$(HOME="$H" PATH="$STUB:$PATH" MEMORY_VERIFY_GH_CMD="" CLAUDE_GUARD_TIMING_LOG="" python3 "$1" 2>&1); RC=$?
  JSON=$(HOME="$H" PATH="$STUB:$PATH" MEMORY_VERIFY_GH_CMD="" CLAUDE_GUARD_TIMING_LOG="" python3 "$1" --json 2>&1)
}
has() { [[ "$OUT" == *"$1"* ]] && pass "$2" || fail "$2" "wanted: $1"$'\n'"$OUT"; }
# Python's own bytecode cache for a fresh HOME (macOS's python3 keeps it there) is not the checkup's.
snapshot() { (cd "$H" && find . -type f ! -path './Library/Caches/*' | LC_ALL=C sort); }

suite() {  # suite WHERE SCRIPT
  local before; before=$(snapshot)
  check "$2"
  [[ $RC -eq 0 ]] && pass "$1: exit 0" || fail "$1: exit $RC" "$OUT"
  local lines; lines=$(printf '%s\n' "$OUT" | grep -E '^[123]\. ')
  [[ "$(printf '%s\n' "$lines" | grep -cE '^[123]\. [^:]+: [0-9][0-9,.]*[ %].*, [0-9]+\.[0-9]x the line of [0-9]')" == 3 ]] \
    && pass "$1: three costs, each a number and a multiple of its line" || fail "$1: three costs with numbers" "$OUT"
  [[ "$(printf '%s\n' "$OUT" | grep -cE '^   n = [0-9][0-9,]* .*; (last 7 days, [0-9-]+ to [0-9-]+|now);')" == 3 ]] \
    && pass "$1: each with its n and its window" || fail "$1: n and window" "$OUT"
  has '1. cache rewrites after a lapsed TTL: 46% of cache-write tokens, 4.6x the line of 10%' "$1: ranked first, the ttl-gap share"
  has '2. slowest Bash guard, p95 per call: 1,500 ms, 1.5x' "$1: then the guard p95 from the timing log"
  has '3. the largest memory index: 75% of its load limit, 0.8x' "$1: then the memory index"
  [[ "$(printf '%s\n' "$OUT" | grep '^Below these: ')" == *'waits on prompts that were then approved 0.00x'*'job folders'* \
     || "$(printf '%s\n' "$OUT" | grep '^Below these: ')" == *'job folders on disk 0.00x'*'waits on prompts'* ]] \
    && pass "$1: the other two are named below the three" || fail "$1: below the three" "$OUT"
  [[ "$OUT$JSON" != *"$CANARY"* ]] && pass "$1: no prompt text, text or --json" || fail "$1: prompt text printed" "$OUT"
  [[ "$OUT$JSON" != *'$'* && "$OUT$JSON" != *USD* ]] && pass "$1: no dollar amount" || fail "$1: a dollar amount" "$OUT"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); x=[c["x"] for c in d["costs"]]
assert len(x) == 5 and x == sorted(x, reverse=True) and not d["errors"]' "$JSON" 2>/dev/null \
    && pass "$1: --json has all five costs, ranked" || fail "$1: --json" "$JSON"
  [[ ! -s "$LOG" ]] && pass "$1: no gh, curl, wget, claude, ssh or nc ran" || fail "$1: a network client ran" "$(cat "$LOG")"
  ! grep -qE '^git (fetch|clone|pull|push|ls-remote|remote)' "$LOG.git" 2>/dev/null \
    && pass "$1: git never reached a remote" || fail "$1: git reached a remote" "$(cat "$LOG.git")"
  [[ "$(snapshot)" == "$before" ]] && pass "$1: wrote nothing under HOME" || fail "$1: wrote under HOME" "$(diff <(echo "$before") <(snapshot))"
}

echo "=== from the clone ==="
suite clone "$REPO/bin/harness-checkup.py"
has 'memory-verify.sh --offline; 0 findings need attention; 1 GitHub claims not checked, offline' \
  "memory-verify ran offline: its GitHub claim was skipped, not looked up"

echo ""
echo "=== installed flat in ~/.claude, as install.sh does ==="
for f in "$REPO"/bin/*; do [[ -f "$f" ]] && cp "$f" "$H/.claude/"; done
mkdir -p "$H/.claude/hooks/lib"; cp "$REPO/hooks/lib/memory-limits.sh" "$H/.claude/hooks/lib/"
suite installed "$H/.claude/harness-checkup.py"

echo ""
echo "=== a tool that fails is named, and the rest still rank ==="
mv "$H/.claude/spend-report.py" "$H/.claude/spend-report.off"
check "$H/.claude/harness-checkup.py"
has 'Not measured: spend-report exited 2.' "the failed tool is named with its exit status"
has '1. slowest Bash guard' "the others still rank"
[[ $RC -eq 0 && "$OUT" != *Traceback* ]] && pass "and the checkup still exits 0" || fail "failed tool" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit "$FAIL"
