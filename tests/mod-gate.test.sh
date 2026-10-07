#!/usr/bin/env bash
# Tests for mod-gate.sh: a mod Claude writes is reviewed with `claude plugin
# validate`; hooks that override permission decisions are denied, everything
# else is allowed and shown to the person.
#
# Needs a Claude Code with mods (2.1.287+). CLAUDE_MOD_GATE_CLI points at one;
# without it the suite says so and skips rather than passing on nothing.
set -u
HOOK="hooks/mod-gate.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AUDIT_LOG="$TMP/audit.log"
pass(){ echo "  OK: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
decision(){ printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow; }

echo "=== mod-gate.sh ==="

# The miss path runs on every Write and Edit, with or without a CLI.
OUT=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/x/notes.md",content:"hi"}}' | bash "$HOOK")
[[ -z "$OUT" ]] && pass "a non-mod file passes silently" || fail "a non-mod file passes silently" "$OUT"
OUT=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/x/src/app.ts",content:"x"}}' | bash "$HOOK")
[[ -z "$OUT" ]] && pass "a .ts file outside any plugin passes silently" || fail "a .ts file outside any plugin passes silently" "$OUT"

# A validator that fails or prints no JSON is no review: ask, never pass.
D="$TMP/deep"
mkdir -p "$D/.claude-plugin" "$D/a/b/c/d/e/f/g"
printf '{"name":"deep","version":"0.1.0"}' > "$D/.claude-plugin/plugin.json"
printf '#!/bin/sh\nexit 1\n' > "$TMP/cli-fails"; printf '#!/bin/sh\necho not json\n' > "$TMP/cli-junk"
chmod +x "$TMP/cli-fails" "$TMP/cli-junk"
deep(){ jq -nc --arg f "$D/a/b/c/d/e/f/g/register.js" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' \
  | CLAUDE_MOD_GATE_CLI="$1" bash "$HOOK"; }
[[ "$(decision "$(deep "$TMP/cli-fails")")" == "ask" ]] && pass "validate fails: ask, seven folders down" || fail "validate fails" "$(deep "$TMP/cli-fails")"
[[ "$(decision "$(deep "$TMP/cli-junk")")" == "ask" ]] && pass "validate prints no JSON: ask" || fail "validate junk" "$(deep "$TMP/cli-junk")"

CLI=${CLAUDE_MOD_GATE_CLI:-$(command -v claude)}
if [[ -z "$CLI" ]] || ! "$CLI" plugin validate --help >/dev/null 2>&1; then
  echo "  SKIP: no Claude Code with 'plugin validate' (set CLAUDE_MOD_GATE_CLI); mod reviews untested"
  echo ""; echo "--- Results: $PASS passed, $FAIL failed ---"; exit $FAIL
fi
export CLAUDE_MOD_GATE_CLI="$CLI"

M="$TMP/mods/counter"
mkdir -p "$M/.claude-plugin" "$M/hooks"
printf '{"name":"counter","version":"0.1.0","description":"test","author":{"name":"t"}}' > "$M/.claude-plugin/plugin.json"
printf '{"modules":["./register.js"]}' > "$M/hooks/hooks.json"
cat > "$TMP/benign.js" <<'EOF'
let n = 0
export function register(on) {
  on('tool.call', async ($, e, next) => { n += 1; $.ui.invalidate('ui.render'); return next(e) })
  on('ui.render', { component: 'Spinner' }, async ($, e, next) => next({ ...e, props: { ...e.props, suffix: ' ' + n } }))
}
EOF
cat > "$TMP/override.js" <<'EOF'
export function register(on) {
  on('tool.check', async ($, e, next) => next(e))
}
EOF
cat > "$TMP/nocalls.js" <<'EOF'
export function register(on) {
  on('session.start', async ($, e, next) => next(e))
}
EOF
cat > "$TMP/unlisted.js" <<'EOF'
export function register(on) {
  on('session.start', async ($, e, next) => { const ui = $.ui; return next(e) })
}
EOF
write(){ jq -nc --arg f "$M/hooks/register.js" --rawfile c "$1" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}' | bash "$HOOK"; }

# Versions before mods (2.1.287) print no hooks: line, and this suite would pass on nothing.
cp "$TMP/benign.js" "$M/hooks/register.js"
if ! (cd "$M" && "$CLI" plugin validate "$M" 2>&1) | grep -q 'hooks: '; then
  echo "  SKIP: $("$CLI" --version 2>/dev/null) lists no mod hooks; mod reviews untested"
  echo ""; echo "--- Results: $PASS passed, $FAIL failed ---"; exit $FAIL
fi
rm -f "$M/hooks/register.js"

OUT=$(write "$TMP/benign.js")
[[ "$(decision "$OUT")" == "ask" ]] && pass "a counter mod hooking tool.call asks" || fail "a counter mod hooking tool.call asks" "$OUT"
case "$OUT" in *"will hook: tool.call, ui.render"*) pass "the person is told what it hooks" ;; *) fail "the person is told what it hooks" "$OUT" ;; esac
case "$OUT" in *"answer a call itself"*) pass "a tool.call hook is called out" ;; *) fail "a tool.call hook is called out" "$OUT" ;; esac
[[ ! -f "$M/hooks/register.js" ]] && pass "the review never writes the real mod" || fail "the review never writes the real mod" "register.js exists"

OUT=$(write "$TMP/override.js")
[[ "$(decision "$OUT")" == "deny" ]] && pass "a tool.check hook is denied" || fail "a tool.check hook is denied" "$OUT"

OUT=$(write "$TMP/nocalls.js")
case "$OUT" in *"will hook: session.start."*) ;; *) fail "a mod with no calls is described" "$OUT" ;; esac
case "$OUT" in *"It calls"*) fail "a mod with no calls lists none" "$OUT" ;; *"will hook"*) pass "a mod with no calls lists none" ;; esac

OUT=$(write "$TMP/unlisted.js")
case "$OUT" in *"will not load it yet"*) pass "a module validation rejects is allowed, with a notice" ;; *) fail "a module validation rejects is allowed, with a notice" "$OUT" ;; esac

# An Edit is reviewed as the file will be after it, not as it is now.
cp "$TMP/benign.js" "$M/hooks/register.js"
NEW="export function register(on) {
  on('tool.check', async (\$, e, next) => next(e))"
OUT=$(jq -nc --arg f "$M/hooks/register.js" --arg n "$NEW" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"export function register(on) {",new_string:$n}}' | bash "$HOOK")
[[ "$(decision "$OUT")" == "deny" ]] && pass "an Edit that adds tool.check is denied" || fail "an Edit that adds tool.check is denied" "$OUT"

# Writing the manifest last still triggers a review of code already on disk.
rm -f "$M/.claude-plugin/plugin.json"; cp "$TMP/override.js" "$M/hooks/register.js"
OUT=$(jq -nc --arg f "$M/.claude-plugin/plugin.json" '{tool_name:"Write",tool_input:{file_path:$f,content:"{\"name\":\"counter\",\"version\":\"0.1.0\",\"description\":\"t\",\"author\":{\"name\":\"t\"}}"}}' | bash "$HOOK")
[[ "$(decision "$OUT")" == "deny" ]] && pass "writing the manifest after the code is reviewed too" || fail "writing the manifest after the code is reviewed too" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
