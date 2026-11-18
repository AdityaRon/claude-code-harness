#!/usr/bin/env bash
# The config/verify-checklist.tsv rows and tests/ suites a change calls for.
#   [BASE] [--run] [--stamp]  working tree vs merge base with BASE (origin/main)
#   BASE..HEAD                a committed range: a review or a replay
# --run runs the suites (exit: failures); --stamp also prints `Verified:`.
# The table is the merge base's plus new head ids: a branch cannot drop its rows.
set -u
TAB=$'\t'
TABLE=config/verify-checklist.tsv
die() { echo "verify-changed: $*" >&2; exit 2; }

RUN="" STAMP="" ARG=""
for a in "$@"; do
  case "$a" in
    --run) RUN=1 ;;
    --stamp) RUN=1 STAMP=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $a" ;;
    *) [[ -z "$ARG" ]] || die "give one BASE or BASE..HEAD"; ARG=$a ;;
  esac
done

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repo"
cd "$TOP" || exit 2

HEADREV=""   # empty: the working tree
if [[ "$ARG" == *..* ]]; then
  [[ "$ARG" != *...* ]] || die "BASE..HEAD takes two dots"
  BASE=${ARG%%..*} HEADREV=${ARG#*..}
  [[ -n "$BASE" && -n "$HEADREV" ]] || die "BASE..HEAD needs both ends"
  [[ -z "$RUN" ]] || die "--run runs the working tree: check out $HEADREV and give BASE alone"
  git rev-parse -q --verify "$HEADREV^{commit}" >/dev/null || die "no commit $HEADREV"
else
  BASE=${ARG:-origin/main}
fi
git rev-parse -q --verify "$BASE^{commit}" >/dev/null || die "no commit $BASE (git fetch origin, or name a BASE)"
MB=$(git merge-base "$BASE" "${HEADREV:-HEAD}" 2>/dev/null) || die "$BASE and ${HEADREV:-HEAD} share no history"
MBS=$(git rev-parse --short "$MB")

# STATUS<TAB>PATH for each changed file. A rename is a delete and an add, so a
# row on either name fires.
UNTRACKED=""
if [[ -n "$HEADREV" ]]; then
  CHANGES=$(git diff --no-renames --name-status "$MB" "$HEADREV" --)
  TO=$HEADREV
else
  UNTRACKED=$(git ls-files --others --exclude-standard)
  CHANGES=$( { git diff --no-renames --name-status "$MB" --
               [[ -z "$UNTRACKED" ]] || printf '%s\n' "$UNTRACKED" | sed "s/^/A$TAB/"; } | sort -t "$TAB" -k2,2 -u)
  TO="the working tree"
fi
PATHS=$(printf '%s\n' "$CHANGES" | cut -f2 | sed '/^$/d')
NFILES=$(printf '%s\n' "$PATHS" | grep -c .)

# The changed lines and hunk headers of PATHS: what a row's diff pattern reads.
# A hunk header names the function around it, so `read_input` matches a change
# inside read_input.
diff_of() {
  { if [[ -n "$HEADREV" ]]; then
      git diff --no-color --no-ext-diff --no-renames "$MB" "$HEADREV" -- "$@"
    else
      git diff --no-color --no-ext-diff --no-renames "$MB" -- "$@"
      local f
      for f in "$@"; do
        if printf '%s\n' "$UNTRACKED" | grep -qxF -- "$f"; then sed 's/^/+/' "$f"; fi
      done
    fi; } | awk '/^diff --git /{h=1; next} /^@@/{h=0} !h && /^(@@|[+-])/'
}

# ---- The table: the merge base's rows, then head's rows with a new id --------
head_table() {
  if [[ -n "$HEADREV" ]]; then git show "$HEADREV:$TABLE" 2>/dev/null; else cat "$TABLE" 2>/dev/null; fi
}
BASE_TABLE=$(git show "$MB:$TABLE" 2>/dev/null); HAVE_BASE=$?
HEAD_TABLE=$(head_table); HAVE_HEAD=$?
# Lines out: row<TAB>the five fields, note<TAB>text, or bad<TAB>text.
MERGED=$(awk -F'\t' -v OFS='\t' -v hb="$HAVE_BASE" -v hh="$HAVE_HEAD" '
  FNR == 1 { src++ }
  /^#/ || /^[[:space:]]*$/ { next }
  NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" {
    print "bad", (src == 1 ? "base" : "head") " table line " FNR ": want 5 non-empty tab-separated fields (- for no diff pattern)"; next }
  src == 1 && hb == 0 {
    if ($1 in base) { print "bad", "base table: id " $1 " twice"; next }
    base[$1] = $0; ids[++n] = $1; print "row", $0; next }
  src == 2 && hh == 0 {
    if ($1 in head) { print "bad", "head table: id " $1 " twice"; next }
    head[$1] = $0
    if (!($1 in base)) { print "row", $0; added++ }
    else if (base[$1] != $0) print "note", "head changes row " $1 "; the base row applies until it merges"
  }
  END {
    for (i = 1; i <= n; i++) if (hh == 0 && !(ids[i] in head)) print "note", "head drops row " ids[i] "; the base row applies until it merges"
    print "count", n + 0, added + 0
  }' <(printf '%s\n' "$BASE_TABLE") <(printf '%s\n' "$HEAD_TABLE"))
BAD=$(printf '%s\n' "$MERGED" | sed -n "s/^bad$TAB//p")
[[ -z "$BAD" ]] || die "$BAD"
ROWS=$(printf '%s\n' "$MERGED" | sed -n "s/^row$TAB//p")
read -r NBASE NADDED <<< "$(printf '%s\n' "$MERGED" | sed -n "s/^count$TAB//p" | tr '\t' ' ')"
NROWS=$((NBASE + NADDED))
[[ "$NROWS" -gt 0 ]] || die "no checklist rows: $TABLE is missing or empty at $MBS and in $TO"
if [[ "$HAVE_BASE" -ne 0 ]]; then SRC="$MBS has no table, so head's $NADDED rows"
elif [[ "$NADDED" -gt 0 ]]; then SRC="table from $MBS, plus $NADDED new in head"
else SRC="table from $MBS"; fi

# ---- Suites: which tests/*.test.sh cover each changed file ------------------
if [[ -n "$HEADREV" ]]; then
  ALL_SUITES=$(git ls-tree --name-only "$HEADREV" tests/ | grep -E '^tests/[^/]+\.test\.sh$')
  SMOKE=$(git show "$HEADREV:tests/smoke.list" 2>/dev/null)
else
  ALL_SUITES=$(for s in tests/*.test.sh; do [[ -f "$s" ]] && printf '%s\n' "$s"; done)
  SMOKE=$(cat tests/smoke.list 2>/dev/null)
fi
SMOKE=$(printf '%s\n' "$SMOKE" | tr -d '\r' | grep -E '^tests/[^/]+\.test\.sh$')
is_suite() { printf '%s\n' "$ALL_SUITES" | grep -qxF -- "$1"; }
# The suites whose text names PATH: by its last two parts (lib/io.sh,
# config/settings.json), or its name alone at the root, as a whole word.
naming() {
  local key re
  case "$1" in */*) key=${1%/*}; key="${key##*/}/${1##*/}" ;; *) key=$1 ;; esac
  re="(^|[^A-Za-z0-9_.-])$(printf '%s' "$key" | sed 's/[][\.*^$+?(){}|/]/\\&/g')([^A-Za-z0-9_.-]|\$)"
  if [[ -n "$HEADREV" ]]; then
    git grep -lE -e "$re" "$HEADREV" -- 'tests/*.test.sh' 2>/dev/null | sed 's/^[^:]*://'
  else
    # shellcheck disable=SC2086  # suite names hold no spaces
    [[ -z "$ALL_SUITES" ]] || grep -lE -e "$re" $ALL_SUITES 2>/dev/null
  fi
}
SUITE_WHY=""   # suite<TAB>why, one line per reason
want() { is_suite "$1" && SUITE_WHY="$SUITE_WHY$1$TAB$2"$'\n'; }
while IFS=$TAB read -r st p; do
  [[ -n "${p:-}" ]] || continue
  case "$p" in
    tests/lib.sh) for s in $ALL_SUITES; do want "$s" "$p"; done ;;
    tests/*.test.sh) want "$p" "$p" ;;
  esac
  b=${p##*/}; stem=${b%.*}
  case "$p" in hooks/*.sh|bin/*|tools/*|.github/*.sh) want "tests/$stem.test.sh" "$p" ;; esac
  for s in $(naming "$p"); do want "$s" "$p"; done
  case "$p" in hooks/lib.sh|hooks/lib/*) for s in $SMOKE; do want "$s" "$p (every wired hook sources it)"; done ;; esac
  case "$st$TAB$p" in
    [AD]"$TAB"*|*"$TAB"README.md|*"$TAB"docs/*|*"$TAB"rules/*|*"$TAB".github/*|*"$TAB"config/settings.json|*"$TAB"tests/smoke.list)
      want tests/repo-layout.test.sh "$p" ;;
  esac
done <<< "$CHANGES"

# ---- Rows -------------------------------------------------------------------
MATCHED="" K=0 TODO=""
while IFS=$TAB read -r id globs re check incident; do
  [[ -n "${id:-}" ]] || continue
  read -r -a G <<< "$globs"
  hit=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    for g in "${G[@]}"; do
      # shellcheck disable=SC2053  # the right side is the row's pattern
      if [[ "$p" == $g ]]; then hit+=("$p"); break; fi
    done
  done <<< "$PATHS"
  [[ ${#hit[@]} -gt 0 ]] || continue
  if [[ "$re" != "-" ]]; then diff_of "${hit[@]}" | grep -qE -e "$re" || continue; fi
  K=$((K+1))
  MATCHED="$MATCHED  $id: ${hit[*]}"$'\n'
  if [[ "$check" =~ ^(tests/[^[:space:]/]+\.test\.sh[[:space:]]*)+$ ]]; then
    MATCHED="$MATCHED    run: $check"$'\n'
    for s in $check; do
      if is_suite "$s"; then SUITE_WHY="$SUITE_WHY$s${TAB}row $id"$'\n'
      else MATCHED="$MATCHED    (row $id names $s, which is not in $TO)"$'\n'; fi
    done
  else
    MATCHED="$MATCHED    do: $check"$'\n'
    TODO="$TODO $id"
  fi
  MATCHED="$MATCHED    from: $incident"$'\n'
done <<< "$ROWS"

echo "verify-changed: $NFILES file(s) changed from $MBS (merge base with $BASE) to $TO"
echo "Checklist: $K of $NROWS rows matched ($SRC)"
printf '%s\n' "$MERGED" | sed -n "s/^note$TAB/  note: /p"
printf '%s' "$MATCHED"
SUITES=$(printf '%s' "$SUITE_WHY" | cut -f1 | sort -u | sed '/^$/d')
NSUITES=$(printf '%s\n' "$SUITES" | grep -c .)
if [[ "$NSUITES" -eq 0 ]]; then
  echo "Suites: none cover these files"
else
  echo "Suites ($NSUITES)$([[ -z "$RUN" ]] && echo ", which --run runs"):"
  for s in $SUITES; do
    why=$(printf '%s' "$SUITE_WHY" | awk -F'\t' -v s="$s" '$1 == s && !seen[$2]++ { w = w (n++ ? ", " : "") $2 } END { print w }')
    [[ ${#why} -le 100 ]] || why="${why:0:97}..."
    echo "  $s  ($why)"
  done
fi
[[ -n "$RUN" ]] || exit 0

# ---- --run and --stamp ------------------------------------------------------
# Guards write every deny and ask to the audit log; a suite run here must not
# fill the real ones, as doctor.sh arranges for a full run.
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$LOGS"' EXIT
export CLAUDE_AUDIT_LOG="$LOGS/audit.log" CLAUDE_GUARD_TIMING_LOG="$LOGS/guard-timing.log" CLAUDE_SHADOW_LOG="$LOGS/shadow.log"
echo ""
NFAIL=0 RAN=""
for s in $SUITES; do
  bash "$s" > "$LOGS/out" 2>&1 < /dev/null; rc=$?
  line=$(grep -E '^-+ Results:' "$LOGS/out" | tail -1)
  np=$(printf '%s\n' "$line" | sed -nE 's/.* Results: ([0-9]+) passed.*/\1/p')
  nsk=$(grep -cE '^[[:space:]]*SKIP' "$LOGS/out")
  tally="${np:-no Results line}${np:+ passed}$([[ "$nsk" -gt 0 ]] && echo ", $nsk skipped")"
  if [[ "$rc" -eq 0 ]]; then
    echo "  ok    $s ($tally)"
    RAN="$RAN${RAN:+; }bash $s ($tally)"
  else
    NFAIL=$((NFAIL+1))
    echo "  FAIL  $s (exit $rc; ${line:-no Results line})"
    grep -E '^[[:space:]]*(FAIL|TIMEOUT)' "$LOGS/out" | head -5 | sed 's/^[[:space:]]*/          /'
  fi
done
[[ -n "$STAMP" ]] || exit "$((NFAIL > 100 ? 100 : NFAIL))"
echo ""
if [[ "$NFAIL" -gt 0 ]]; then
  echo "No Verified line: $NFAIL suite(s) failed."
  exit "$((NFAIL > 100 ? 100 : NFAIL))"
fi
if [[ -z "$RAN" ]]; then
  echo "Verified: none (no suite covers these files)"
else
  echo "Verified: $RAN"
fi
[[ -z "$TODO" ]] || echo "Add what you did by hand for:$TODO, or say in the trailer why not."
exit 0
