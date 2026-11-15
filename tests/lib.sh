#!/usr/bin/env bash
# Sourced by the suites in tests/: the counts each one reports on its
# "--- Results: N passed, M failed ---" line, which doctor.sh reads.
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
# A case that ran out of time measures the machine's load, not the code: it is
# counted apart, and doctor.sh reads a suite with timeouts and no failures as TIMEOUT.
TIMED=0
timed_out() { echo "  TIMEOUT: $1  ${2:-}"; TIMED=$((TIMED+1)); }
results() {  # the Results line, with ", T timed out" when any did; exits with the misses, at most 100
  local n=$((FAIL + TIMED))
  echo "--- Results: $PASS passed, $FAIL failed$( [ "$TIMED" -gt 0 ] && echo ", $TIMED timed out") ---"
  [ "$n" -gt 100 ] && n=100
  exit "$n"
}

# No suite reaches GitHub: install.sh fetches claude-code-skills, so a suite
# that wants the skills points HARNESS_SKILLS_URL at a local clone itself.
export HARNESS_SKILLS_URL=/nonexistent/claude-code-skills
# A claude-code-skills clone holding the commit config/skills.pin names, from
# $CCH_SKILLS_CLONE or ~/.claude/skills-src: call it before moving HOME.
skills_src() {   # REPO
  local sha tag c
  sha=$(sed -n 's/^commit=//p' "$1/config/skills.pin" 2>/dev/null); tag=$(sed -n 's/^tag=//p' "$1/config/skills.pin" 2>/dev/null)
  for c in "${CCH_SKILLS_CLONE:-}" "$HOME/.claude/skills-src"; do
    [[ -n "$c" && -n "$sha" && "$(git -C "$c" rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)" == "$sha" ]] \
      && { echo "$c"; return 0; }
  done
  return 1
}
skills_tree() {   # SRC REPO DEST PATH...: the pinned commit's PATHs, extracted into DEST
  local src=$1 sha; sha=$(sed -n 's/^commit=//p' "$2/config/skills.pin"); mkdir -p "$3"
  git -C "$src" archive "$sha" "${@:4}" | tar -xf - -C "$3"
}
# Without a clone a suite skips what needs one, except in CI, which clones it.
no_skills() {   # WHAT
  if [[ -n "${CI:-}" ]]; then fail "$1" "no claude-code-skills clone at the pinned commit: set CCH_SKILLS_CLONE"
  else echo "  SKIP: $1: no claude-code-skills clone at the pinned commit (set CCH_SKILLS_CLONE)"; fi
}

# A guard in shadow mode (hooks/lib/shadow.sh) answers nothing and writes a line
# to $CLAUDE_SHADOW_LOG. shadow_run CMD... runs CMD on stdin and prints what it
# answered, or else that line's would-be answer with "shadow":RULE beside it, so
# a row still checks what the guard finds and can tell a live answer from it.
shadow_run() {
  local out rc
  : > "$CLAUDE_SHADOW_LOG"
  out=$("$@"); rc=$?
  if [[ -z "$out" && -s "$CLAUDE_SHADOW_LOG" ]]; then
    jq -c '{shadow: .rule, hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: .would, permissionDecisionReason: .reason}}' \
      "$CLAUDE_SHADOW_LOG" | head -n 1
  else
    printf '%s' "$out"
  fi
  return "$rc"
}
