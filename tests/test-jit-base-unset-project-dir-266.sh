#!/bin/bash
# #266: with CLAUDE_PROJECT_DIR unset, common.sh's fallback made JIT_BASE relative
# ("./.claude/jit-context") while post-tool-hook.sh compares it against file_path, which
# always arrives absolute in a real tool payload. A `case "$PT_FP" in "$JIT_BASE"/*)`
# prefix test between a relative pattern and an absolute subject can never match, for any
# input -- so the edit marker was never written, and stop-hook.sh (#244) then asserted
# "none updated" as a measured fact about a session where the entry genuinely was edited.
#
# THE GUARD THIS SUITE NEEDS, the same shape test-post-tool-hook.sh already states: every
# "does not mark" case is paired with a "does mark" case on the same fixture, so a fix
# that happens to suppress everything cannot pass by satisfying only the negative half.
#
# jit-drive: none -- helpers take a path, a bare exit code, or compare against a literal.
#
# Usage: bash tests/test-jit-base-unset-project-dir-266.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    this path should exist and be a regular file: $path"
  fi
}

assert_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    this path should not exist: $path"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should not contain: $unexpected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/vocabulary/00-manual"
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }

# Every call below runs with CLAUDE_PROJECT_DIR deliberately unset AND with cwd set to
# the project root -- the shape a hand-run or misconfigured invocation of these hooks
# would actually have, and the one the fallback `${CLAUDE_PROJECT_DIR:-.}` was written
# to cover.
run_post_tool_no_project_dir() {
  local p="$1" sid="$2" tool="$3" fp="$4"
  (cd "$p" && env -u CLAUDE_PROJECT_DIR bash -c '
      printf '"'"'{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}'"'"' \
        "'"$sid"'" "'"$tool"'" "'"$fp"'" | bash "'"$SCRIPTS"'/post-tool-hook.sh"
    ') 2>&1
}

run_stop_no_project_dir() {
  local p="$1" sid="$2"
  (cd "$p" && env -u CLAUDE_PROJECT_DIR bash -c '
      printf '"'"'{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}'"'"' "'"$sid"'" \
        | bash "'"$SCRIPTS"'/stop-hook.sh"
    ') 2>&1
}

echo "=== A: CLAUDE_PROJECT_DIR unset, an edit UNDER the tree still drops a marker ==="

P="$(new_project a)"
FP="$P/.claude/jit-context/vocabulary/00-manual/bridge.md"
OUT="$(run_post_tool_no_project_dir "$P" "sess-a" "Edit" "$FP")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_file "an edit marker is written even with CLAUDE_PROJECT_DIR unset" \
  "$(state_of "$P")/edited-sess-a.txt"

echo ""
echo "=== B: CLAUDE_PROJECT_DIR unset, an edit OUTSIDE the tree still marks nothing ==="
# The negative half of A on the same fixture shape -- a fix that made JIT_BASE absolute
# by widening it to match everything would pass A by making the prefix test vacuous.

P="$(new_project b)"
FP="$P/src/app.php"
OUT="$(run_post_tool_no_project_dir "$P" "sess-b" "Edit" "$FP")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_no_file "no marker was written for a file outside the tree" \
  "$(state_of "$P")/edited-sess-b.txt"

echo ""
echo "=== C: composition -- CLAUDE_PROJECT_DIR unset, entry fired AND edited -- stop-hook must not claim otherwise ==="
# This is the exact shape #266 reports: post-tool-hook.sh silently failing to write the
# marker made stop-hook.sh assert 'none updated' as fact about a session where the entry
# genuinely was edited.

P="$(new_project c)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-c.txt"
FP="$P/.claude/jit-context/vocabulary/00-manual/bridge.md"
run_post_tool_no_project_dir "$P" "sess-c" "Edit" "$FP" > /dev/null
OUT="$(run_stop_no_project_dir "$P" "sess-c")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_not_contains "stop-hook does not falsely claim nothing was updated" "$OUT" "none updated"

echo ""
echo "=== D: composition control -- CLAUDE_PROJECT_DIR unset, entry fired and NOT edited -- still reports it ==="
# The pair to C on the same fixture shape: without this, a fix that made post-tool-hook.sh
# write a marker unconditionally would pass C by construction.

P="$(new_project d)"
mkdir -p "$(state_of "$P")"
# #291/#295: stop-hook.sh now only reports a fired entry as "none updated" when a real
# 00-manual file backs it (there is nobody else to curate it) -- this fixture's whole
# point is that entry, so it needs a real file the same way test-stop-hook.sh's own
# sections do.
: > "$P/.claude/jit-context/vocabulary/00-manual/bridge.md"
# #300: the model-facing report is off by default now -- this fixture asserts the
# message's own TEXT, so it needs the same JIT_CONTEXT_STOP_REPORT=1 twin
# tests/test-stop-hook.sh gives every one of its own message-asserting sections.
printf 'JIT_CONTEXT_STOP_REPORT=1\n' > "$P/.claude/jit-context/config.env"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-d.txt"
OUT="$(run_stop_no_project_dir "$P" "sess-d")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "stop-hook still reports the honest 'none updated' when nothing was" "$OUT" "none updated"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
