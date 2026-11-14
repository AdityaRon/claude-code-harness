#!/usr/bin/env bash
# Five places keep their own token-shape list: secret-scanner, redact_secrets
# (the audit log), permission-friction's mask, check_draft's TOKEN (Slack) and
# skill_lint's C3. Each shape goes through all five; a site catches it or names
# it in its OUT list with the reason. Samples are built from parts, so this
# file holds no token for secret-scanner to stop.
PASS=0; FAIL=0
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=../hooks/lib.sh
source hooks/lib.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.claude"
PY=$(bash skills/comms-hub/bin/python.sh 2>/dev/null) || { PY=""; echo "  SKIP: friction, draft and lint: no Python 3.10+ with a TOML reader"; }

r() { local n=$1 c=$2; printf "$c%.0s" $(seq 1 "$n"); }   # n copies of c
A=$(r 16 Q); B36=$(r 36 a); B40=$(r 40 b); B24=$(r 24 c); B20=$(r 20 d)
SHAPES=(
  "AWS Access Key ID"     "AK""IA$A"
  "AWS Session/Temp Key"  "AS""IA$A"
  "GitHub PAT (classic)"  "gh""p_$B36"
  "GitHub OAuth token"    "gh""o_$B36"
  "GitHub user-server token" "gh""u_$B36"
  "GitHub server-server token" "gh""s_$B36"
  "GitHub refresh token"  "gh""r_$B36"
  "GitHub fine-grained PAT" "github""_pat_$(r 52 e)"
  "GitLab token"          "gl""pat-$B20"
  "npm token"             "np""m_$B36"
  "Slack bot/app token"   "xo""xb-1234567890-$B20"
  "Slack app-level token" "xa""pp-1-$B20"
  "Google API key"        "AI""za$(r 35 f)"
  "Stripe live key"       "sk""_live_$B24"
  "Stripe test key"       "sk""_test_$B24"
  "Anthropic API key"     "sk""-ant-$(r 40 g)"
  "OpenAI API key"        "sk""-$B40$B20"
  "OpenAI project key"    "sk""-proj-$(r 40 h)"
  "JWT"                   "ey""J$(r 20 i).ey""J$(r 20 j).$(r 20 k)"
  "Slack incoming webhook" "https://hooks.slack.com/services/T0$(r 8 L)/B0$(r 8 M)/$(r 24 n)"
  "Database URL with a password" "postgres://app:$(r 12 p)@db.internal:5432/x"
  "AWS secret access key" "aws_secret""_access_key=$(r 40 S)"
  "AWS secret access key in escaped JSON" "{\\\"aws_secret""_access_key\\\":\\\"$(r 40 S)\\\"}"
  "PEM private key header" "-----BEGIN RSA PRIVATE"" KEY-----"
  "PGP private key block" "-----BEGIN PGP PRIVATE KEY"" BLOCK-----"
  "GCP private key field" "\"private_key\": \"-----BEGIN PRIVATE"" KEY-----"
)
LABELS=(); for ((i = 0; i < ${#SHAPES[@]}; i += 2)); do LABELS+=("${SHAPES[$i]}"); done
# Every shape secret-scanner blocks has a row here, by its own label: one it adds
# and this list misses fails below, so the other four sites are held to it too.
SCANNER_LABELS=(); while IFS= read -r l; do SCANNER_LABELS+=("$l"); done < <(
  sed -n '/^PATTERNS=(/,/^)/p' hooks/secret-scanner.sh | sed -nE "s/^[[:space:]]*[\"']([^:\"']+)::.*/\1/p")
# And the entries, counted apart from reading their labels: one this reader cannot
# parse (a label with a colon or a quote) would otherwise drop out unseen.
SCANNER_ENTRIES=$(sed -n '/^PATTERNS=(/,/^)/p' hooks/secret-scanner.sh | grep -v '^[[:space:]]*#' | grep -c '::')
# Samples vendors publish, which secret-scanner lets through on purpose. The three
# sites that block (scanner, draft, lint) must too; redact and friction only mask.
JWTIO="ey""JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ey""JzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
SAMPLES=(
  "AWS's doc key"           "AK""IAIOSFODNN7EXAMPLE"
  "AWS's doc secret"        "aws_secret""_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  "jwt.io's sample"         "$JWTIO"
  "a <password> URL"        "postgres://app:<password>@db:5432/x"
  "a \${VAR} URL"           "https://user:\${TOKEN}@github.com/x"
  "a changeme URL"          "postgres://app:changeme@db/x"
)
# Words that share a prefix with a token and are none: no site may touch them.
NOT_TOKENS=(
  "npm variables"           "echo \$npm_config_registry \$npm_package_version_and_dependencies_list"
  "an ASIA_ word"           "ASIA_PACIFIC_REGION_DEFAULT"
)

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

# The three Python sites, in one process: one line per sample, "friction draft lint".
# friction counts only its own markers: its <EMAIL> and <LONG> masks change most
# samples whatever the token rules say. HOME is the probe's, so no site masks
# file on this machine takes part.
py_sites() {   # samples on stdin
  [ -n "$PY" ] || return 0
  HOME="$TMP/home" "$PY" -c '
import importlib.util, re, sys
sys.path[:0] = ["skills/comms-hub/bin", "skills/skill-forge/bin"]
spec = importlib.util.spec_from_file_location("friction", "tools/permission-friction.py")
friction = importlib.util.module_from_spec(spec); spec.loader.exec_module(friction)
import check_draft, skill_lint
for s in sys.stdin.read().splitlines():
    t = f"x {s} y"
    print(int(bool(re.search(r"<(TOKEN|JWT|MASKED)>", friction.mask(t, 10000)))), int(bool(check_draft.TOKEN.search(t))),
          int(any(rx.search(f"key = \"{s}\"") for _, rx in skill_lint.SECRET_RULES)))'
}
PYRES=(); while IFS= read -r ln; do PYRES+=("$ln"); done < <(for ((i = 1; i < ${#SHAPES[@]}; i += 2)); do printf '%s\n' "${SHAPES[$i]}"; done | py_sites)
SAMPRES=(); while IFS= read -r ln; do SAMPRES+=("$ln"); done < <(for ((i = 1; i < ${#SAMPLES[@]}; i += 2)); do printf '%s\n' "${SAMPLES[$i]}"; done | py_sites)
NOTRES=(); while IFS= read -r ln; do NOTRES+=("$ln"); done < <(for ((i = 1; i < ${#NOT_TOKENS[@]}; i += 2)); do printf '%s\n' "${NOT_TOKENS[$i]}"; done | py_sites)

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
  [ -n "$PY" ] || continue
  judge friction "$label" "$f" OUT_friction
  judge draft "$label" "$d" OUT_draft
  judge lint "$label" "$l" OUT_lint
done
if [ -n "$PY" ]; then
  [ "${#PYRES[@]}" = "${#LABELS[@]}" ] && pass "the Python sites read every shape" || fail "the Python sites" "${#PYRES[@]} of ${#LABELS[@]} lines"
fi
for site in scanner redact friction draft lint; do
  arr="OUT_${site}[@]"
  for x in "${!arr}"; do
    printf '%s\n' "${LABELS[@]}" | grep -qxF -- "${x%%:*}" || fail "OUT_$site names \"${x%%:*}\"" "which is no shape here: fix or drop the entry"
  done
done

[[ "${#SCANNER_LABELS[@]}" -ge 20 && "${#SCANNER_LABELS[@]}" -eq "$SCANNER_ENTRIES" ]] \
  && pass "read the label of each of secret-scanner's $SCANNER_ENTRIES PATTERNS entries" \
  || fail "secret-scanner's labels" "read ${#SCANNER_LABELS[@]} of $SCANNER_ENTRIES entries: one has a label this test cannot read"
MISSING=""; for l in "${SCANNER_LABELS[@]}"; do printf '%s\n' "${LABELS[@]}" | grep -qxF -- "$l" || MISSING="$MISSING [$l]"; done
[ -z "$MISSING" ] && pass "every shape secret-scanner blocks has a row here" || fail "shapes with no row" "$MISSING"

# redact_secrets runs on the whole audit line: a key's body goes, the fields after it stay.
HDR="-----BEGIN RSA PRIVATE"" KEY-----"
LINE="2026-11-13T00:00:00Z | GUARD | deny | x | printf '$HDR MIIE$(r 40 Z)' > k.pem | /w/proj"
GOT=$(printf '%s\n' "$LINE" | redact_secrets)
[[ "$GOT" == *"$HDR***"* && "$GOT" == *" | /w/proj" && "$GOT" != *MIIE* ]] \
  && pass "a key's body is masked to the field's end; the line's later fields stay" || fail "audit line fields" "$GOT"
# The audit line's key=value rule takes an escaped quote too: JSON echoed from a command.
GOT=$(printf '%s\n' 'x | echo "{\"pass''word\":\"hunter2hunter2\"}" > c.json | /w' | redact_secrets)
[[ "$GOT" != *hunter2* && "$GOT" == *" | /w" ]] && pass "redact masks a password in escaped JSON" || fail "redact escaped JSON" "$GOT"
# friction's samples keep their newlines: a key's body lines go, the command after its END line stays.
if [ -n "$PY" ]; then
  KEYCMD=$(printf "cat > k.pem <<'EOF'\n%s\nMIIEshortline\n%s\nEOF\nchmod 600 k.pem" "$HDR" "-----END RSA PRIVATE"" KEY-----")
  GOT=$(printf '%s' "$KEYCMD" | HOME="$TMP/home" "$PY" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("friction", "tools/permission-friction.py")
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
print(f.mask(sys.stdin.read(), 10000))')
  [[ "$GOT" == *"<MASKED>"* && "$GOT" != *MIIE* && "$GOT" == *"chmod 600 k.pem"* ]] \
    && pass "friction masks a key's lines to its END line; the command after stays" || fail "friction multi-line key" "$GOT"
fi

echo ""
echo "=== a vendor's published sample passes where a site blocks ==="
for ((i = 0; i < ${#SAMPLES[@]}; i += 2)); do
  label=${SAMPLES[$i]}; s=${SAMPLES[$((i + 1))]}
  caught_scanner "$s" && fail "secret-scanner blocks $label" "[$s]" || pass "secret-scanner lets $label through"
  [ -n "$PY" ] || continue
  read -r _ d l <<<"${SAMPRES[$((i / 2))]:-1 1 1}"
  [ "$d" = 0 ] && pass "draft lets $label through" || fail "draft blocks $label" "[$s]"
  [ "$l" = 0 ] && pass "lint lets $label through" || fail "lint flags $label" "[$s]"
done

echo ""
echo "=== a word that only shares a token's prefix is left alone ==="
for ((i = 0; i < ${#NOT_TOKENS[@]}; i += 2)); do
  label=${NOT_TOKENS[$i]}; s=${NOT_TOKENS[$((i + 1))]}
  caught_scanner "$s" && fail "secret-scanner blocks $label" "[$s]" || pass "secret-scanner leaves $label"
  caught_redact "$s" && fail "redact_secrets rewrites $label" "[$(printf '%s' "$s" | redact_secrets)]" || pass "redact_secrets leaves $label"
  [ -n "$PY" ] || continue
  read -r f d l <<<"${NOTRES[$((i / 2))]:-1 1 1}"
  [ "$f" = 0 ] && pass "friction leaves $label" || fail "friction masks $label" "[$s]"
  [ "$d" = 0 ] && pass "draft leaves $label" || fail "draft blocks $label" "[$s]"
  [ "$l" = 0 ] && pass "lint leaves $label" || fail "lint flags $label" "[$s]"
done

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
