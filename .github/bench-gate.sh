#!/usr/bin/env bash
# The hook benchmark gate, from the repo root: .github/bench-gate.sh BASE_REF
# The gate script and corpus come from BASE_REF so a change cannot loosen its own
# gate (docs/releases.md). Env: INTENDED, INTENDED_LAUNCHES, REMOVED (payload ids).
set -uo pipefail
BASE_REF=${1:?usage: bench-gate.sh BASE_REF}
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bench-gate.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

finish() {  # RC: bench.md to the job summary, and exit
  cat bench.md >> "$SUMMARY"
  exit "$1"
}

SHA=$(git rev-parse --short "$BASE_REF^{commit}" 2>/dev/null) || {
  echo "The gate could not resolve $BASE_REF." > bench.md
  echo "::error::bench-gate: no such ref: $BASE_REF"; finish 2; }
for f in tools/hook-bench.py tests/bench-corpus.jsonl; do
  git show "$BASE_REF:$f" > "$WORK/base-${f##*/}" 2>/dev/null || {
    echo "The gate could not read $f from $BASE_REF ($SHA)." > bench.md
    echo "::error::bench-gate: $f is not in $BASE_REF"; finish 2; }
done

# The base's corpus, with each payload the checkout removes or changes kept as
# on the base unless REMOVED names it, then the checkout's new ids.
python3 - "$WORK/base-bench-corpus.jsonl" tests/bench-corpus.jsonl "$WORK/corpus.jsonl" "${REMOVED:-}" \
  > "$WORK/corpus.md" <<'PY'
import json, re, sys
base_p, head_p, out_p, removed = sys.argv[1:5]

def load(path, side):
    rows = []
    try:
        with open(path) as f:
            for n, line in enumerate(f, 1):
                if not line.strip():
                    continue
                row = json.loads(line)
                if not isinstance(row, dict) or not isinstance(row.get('id'), str):
                    raise ValueError(f'line {n} has no id')
                rows.append(row)
    except (OSError, ValueError) as e:
        print(f'The {side} corpus could not be read: {e}.')
        sys.exit(2)
    ids = [r['id'] for r in rows]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        print(f"The {side} corpus repeats ids: {', '.join(dup)}.")
        sys.exit(2)
    return rows

base, head = load(base_p, 'base'), load(head_p, 'checkout')
named = set(re.split(r'[,\s]+', removed.strip())) - {''}
H, B = {r['id']: r for r in head}, {r['id'] for r in base}
out, dropped, taken, unnamed = [], [], [], []
for r in base:
    h = H.get(r['id'])
    if h == r:
        out.append(r)
    elif r['id'] in named:
        (dropped if h is None else taken).append(r['id'])
        if h is not None:
            out.append(h)
    else:
        unnamed.append(f"{r['id']} ({'removed' if h is None else 'changed'})")
        out.append(r)
new = [r['id'] for r in head if r['id'] not in B]
out += [r for r in head if r['id'] not in B]
with open(out_p, 'w') as f:
    f.writelines(json.dumps(r) + '\n' for r in out)
L = [f"{len(out)} payloads, {len(new)} of them new in this change" + (f": {', '.join(new)}." if new else '.')]
if dropped:
    L.append(f"Dropped by `removed-payloads:`: {', '.join(dropped)}.")
if taken:
    L.append(f"Run as changed here, by `removed-payloads:`: {', '.join(taken)}.")
if unnamed:
    L.append(f"FAILED: removed or changed here with no `removed-payloads:` line, so run as on the base: {', '.join(unnamed)}.")
print(' '.join(L))
sys.exit(1 if unnamed else 0)
PY
CORPUS_RC=$?
{ printf 'Gate script and corpus from `%s` (%s): ' "$SHA" "$BASE_REF"; cat "$WORK/corpus.md"; echo; } > "$WORK/head.txt"
[ "$CORPUS_RC" = 0 ] || echo "::error::payloads removed or changed without a removed-payloads: line; see the job summary."
[ "$CORPUS_RC" = 2 ] && { cp "$WORK/head.txt" bench.md; finish 2; }

# After the corpus check: a deletion merged with the bench skipped is gone from the next base.
if git diff --quiet "$BASE_REF" HEAD -- hooks config/settings.json; then
  { cat "$WORK/head.txt"
    echo "hooks/ and config/settings.json match $BASE_REF; benchmark skipped (both sides would run the same files)."; } > bench.md
  finish "$CORPUS_RC"
fi

ARGS=(--repo "$PWD" --corpus "$WORK/corpus.jsonl" --base "$BASE_REF" --head HEAD --gate --intended "${INTENDED:-}"
      --launches strace --intended-launches "${INTENDED_LAUNCHES:-}")
python3 "$WORK/base-hook-bench.py" "${ARGS[@]}" --md "$WORK/base.md" --json bench.json >/dev/null
BASE_RC=$?
[ "$BASE_RC" = 0 ] || echo "::error::the benchmark gate failed; see the job summary."
HEAD_RC=0
# A diff that errors runs it too.
if ! git diff --quiet "$BASE_REF" HEAD -- tools/hook-bench.py; then
  python3 tools/hook-bench.py "${ARGS[@]}" --md "$WORK/head.md" >/dev/null
  HEAD_RC=$?
  [ "$HEAD_RC" = 0 ] || echo "::error::the benchmark gate with this change's tools/hook-bench.py failed; see the job summary."
fi

{ cat "$WORK/head.txt"; echo
  cat "$WORK/base.md" 2>/dev/null || echo "The base's tools/hook-bench.py wrote no report (exit $BASE_RC)."
  if [ -e "$WORK/head.md" ] || [ "$HEAD_RC" != 0 ]; then
    echo; echo "This change edits tools/hook-bench.py, so the gate ran again with its copy (exit $HEAD_RC):"; echo
    cat "$WORK/head.md" 2>/dev/null || echo "It wrote no report."
  fi; } > bench.md
for rc in "$CORPUS_RC" "$BASE_RC" "$HEAD_RC"; do [ "$rc" = 0 ] || finish "$rc"; done
finish 0
