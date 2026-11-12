#!/usr/bin/env bash
# Five places keep their own token-shape list: secret-scanner, redact_secrets
# (the audit log), permission-friction's mask, check_draft's TOKEN (Slack) and
# skill_lint's C3. Each shape goes through all five; a site catches it or names
# it in its OUT list with the reason. Samples are built from parts, so this
# file holds no token for secret-scanner to stop.
PASS=0; FAIL=0
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=../hooks/lib.sh
source hooks/lib.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.claude"
PY=$(bash skills/comms-hub/bin/python.sh 2>/dev/null) || { echo "  SKIP: no Python 3.10+ with a TOML reader"; echo "--- Results: 0 passed, 0 failed ---"; exit 0; }

r() { local n=$1 c=$2; printf "$c%.0s" $(seq 1 "$n"); }   # n copies of c
A=$(r 16 Q); B36=$(r 36 a); B40=$(r 40 b); B24=$(r 24 c); B20=$(r 20 d)
SHAPES=(
  "AWS key id"            "AK""IA$A"
  "AWS temporary key id"  "AS""IA$A"
  "GitHub classic PAT"    "gh""p_$B36"
  "GitHub OAuth token"    "gh""o_$B36"
  "GitHub user token"     "gh""u_$B36"
  "GitHub server token"   "gh""s_$B36"
  "GitHub refresh token"  "gh""r_$B36"
  "GitHub fine-grained"   "github""_pat_$(r 52 e)"
  "GitLab token"          "gl""pat-$B20"
  "npm token"             "np""m_$B36"
  "Slack bot token"       "xo""xb-1234567890-$B20"
  "Slack app token"       "xa""pp-1-$B20"
  "Google API key"        "AI""za$(r 35 f)"
  "Stripe live key"       "sk""_live_$B24"
  "Stripe test key"       "sk""_test_$B24"
  "Anthropic key"         "sk""-ant-$(r 40 g)"
  "OpenAI key"            "sk""-$B40$B20"
  "OpenAI project key"    "sk""-proj-$(r 40 h)"
  "JWT"                   "ey""J$(r 20 i).ey""J$(r 20 j).$(r 20 k)"
  "Slack webhook"         "https://hooks.slack.com/services/T0$(r 8 L)/B0$(r 8 M)/$(r 24 n)"
  "URL with a password"   "postgres://app:$(r 12 p)@db.internal:5432/x"
)
LABELS=(); for ((i = 0; i < ${#SHAPES[@]}; i += 2)); do LABELS+=("${SHAPES[$i]}"); done

# Each site's OUT list: the shapes it does not look for, and why.
# shellcheck disable=SC2034  # judge reads each by name
declare -a OUT_scanner=() OUT_redact=() OUT_friction=() OUT_draft=() OUT_lint=()

caught_scanner() {
  local out
  out=$(jq -nc --arg c "x = \"$1\"" '{tool_name:"Write", tool_input:{file_path:"/tmp/cfg.py", content:$c}, hook_event_name:"PreToolUse"}' \
        | HOME="$TMP/home" CLAUDE_AUDIT_LOG="$TMP/audit.log" bash hooks/secret-scanner.sh 2>/dev/null)
  [[ "$out" == *'"deny"'* ]]
}
caught_redact() { [[ "$(printf '%s' "x $1 y" | redact_secrets)" != "x $1 y" ]]; }

# The three Python sites, in one process: one line per shape, "friction draft lint".
mapfile_py() {
  local i
  for ((i = 1; i < ${#SHAPES[@]}; i += 2)); do printf '%s\n' "${SHAPES[$i]}"; done | "$PY" -c '
import importlib.util, sys
sys.path[:0] = ["skills/comms-hub/bin", "skills/skill-forge/bin"]
spec = importlib.util.spec_from_file_location("friction", "tools/permission-friction.py")
friction = importlib.util.module_from_spec(spec); spec.loader.exec_module(friction)
import check_draft, skill_lint
for s in sys.stdin.read().splitlines():
    t = f"x {s} y"
    print(int(friction.mask(t, 10000) != t), int(bool(check_draft.TOKEN.search(t))),
          int(any(rx.search(f"key = \"{s}\"") for _, rx in skill_lint.SECRET_RULES)))'
}
PYRES=(); while IFS= read -r ln; do PYRES+=("$ln"); done < <(mapfile_py)

judge() {   # site label caught(0/1) OUT-array-name
  local site=$1 label=$2 got=$3 arr="$4[@]" x out=0
  for x in "${!arr}"; do [[ "${x%%:*}" == "$label" ]] && out=1; done
  if (( got && !out )); then pass "$site catches $label"
  elif (( !got && out )); then pass "$site leaves $label, as its OUT list says"
  elif (( got && out )); then fail "$site catches $label" "but its OUT list says it does not: drop the entry"
  else fail "$site misses $label" "catch it, or name it in OUT_$site with the reason"; fi
}

echo "=== each token shape, through all five places that look for one ==="
for ((i = 0; i < ${#SHAPES[@]}; i += 2)); do
  label=${SHAPES[$i]}; s=${SHAPES[$((i + 1))]}; k=$((i / 2))
  read -r f d l <<<"${PYRES[$k]:-0 0 0}"
  caught_scanner "$s" && judge scanner "$label" 1 OUT_scanner || judge scanner "$label" 0 OUT_scanner
  caught_redact "$s" && judge redact "$label" 1 OUT_redact || judge redact "$label" 0 OUT_redact
  judge friction "$label" "$f" OUT_friction
  judge draft "$label" "$d" OUT_draft
  judge lint "$label" "$l" OUT_lint
done
[ "${#PYRES[@]}" = "${#LABELS[@]}" ] && pass "the Python sites read every shape" || fail "the Python sites" "${#PYRES[@]} of ${#LABELS[@]} lines"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
