#!/bin/bash
# #244 (part 2 of #233): the EDIT signal the Stop hook needs. This is a PostToolUse hook
# keyed on Write|Edit that observes a write under $JIT_BASE and drops a marker beside the
# `shown` marks -- existence only, same directory, same session keying, same ageing-out
# session-start-hook.sh already performs. It never fails hard: every branch answers `{}`.
#
# THE GUARD THIS SUITE NEEDS, the same shape test-session-markers.sh already states: every
# "does not mark" case (a tool this hook does not watch, a path outside the tree, a
# traversal) is paired with a "does mark" case on the same fixture, so a hook that is
# broken outright (never marks anything, ever) cannot pass by satisfying every negative at
# once.
#
# jit-drive: none -- every helper here takes a path or a bare exit code
# (assert_rc0, assert_file, assert_no_file) or compares output against the fixed
# literal `{}` (assert_empty_json); none takes captured hook output plus a needle, so
# there is no payload-shaped helper here for test-assertion-helpers.sh to drive.
#
# Usage: bash tests/test-post-tool-hook.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_empty_json() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected exactly {} - got: ${output:-<EMPTY>}"
  fi
}

assert_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    this path should exist and be a regular file: $path"
  fi
}

assert_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    this path should not exist: $path"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
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

run_post_tool() {
  local p="$1" sid="$2" tool="$3" fp="$4"
  printf '{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$sid" "$tool" "$fp" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/post-tool-hook.sh" 2>&1
}

echo "=== A: an Edit under the tree drops a marker ==="

P="$(new_project a)"
FP="$P/.claude/jit-context/vocabulary/00-manual/bridge.md"
OUT="$(run_post_tool "$P" "sess-a" "Edit" "$FP")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook answers empty JSON" "$OUT"
assert_file "an edit marker is written for this session" "$(state_of "$P")/edited-sess-a.txt"

echo ""
echo "=== B: a Write under the tree also drops a marker ==="

P="$(new_project b)"
FP="$P/.claude/jit-context/vocabulary/00-manual/new.md"
OUT="$(run_post_tool "$P" "sess-b" "Write" "$FP")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_file "a write marker is written for this session too" "$(state_of "$P")/edited-sess-b.txt"

echo ""
echo "=== C: a tool this hook does not watch marks nothing (the negative half of A) ==="

P="$(new_project c)"
FP="$P/.claude/jit-context/vocabulary/00-manual/bridge.md"
OUT="$(run_post_tool "$P" "sess-c" "Read" "$FP")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook answers empty JSON" "$OUT"
assert_no_file "no marker was written for a tool that only reads" "$(state_of "$P")/edited-sess-c.txt"

echo ""
echo "=== D: a path outside the tree marks nothing (the negative half of A) ==="

P="$(new_project d)"
FP="$P/src/app.php"
OUT="$(run_post_tool "$P" "sess-d" "Edit" "$FP")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_no_file "no marker was written for a file outside the tree" "$(state_of "$P")/edited-sess-d.txt"

echo ""
echo "=== E: a traversal riding on the prefix is refused, not treated as inside the tree ==="

P="$(new_project e)"
FP="$P/.claude/jit-context/vocabulary/00-manual/../../../../etc/passwd"
OUT="$(run_post_tool "$P" "sess-e" "Edit" "$FP")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_no_file "no marker was written for a path that escapes via .." "$(state_of "$P")/edited-sess-e.txt"

echo ""
echo "=== F: no session_id means no marker, never a wrong guess (same posture as the shown marks) ==="

P="$(new_project f)"
FP="$P/.claude/jit-context/vocabulary/00-manual/bridge.md"
OUT="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$FP" \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/post-tool-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
if [ -d "$(state_of "$P")" ] && [ -n "$(ls -A "$(state_of "$P")" 2>/dev/null)" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: no session_id wrote a marker anyway"
  ls -A "$(state_of "$P")"
else
  PASS=$((PASS + 1)); echo "  PASS: no session_id wrote no marker at all"
fi

echo ""
echo "=== G: a project with no jit-context tree at all stays inert ==="

P="$TMP/g"
mkdir -p "$P"
OUT="$(printf '{"session_id":"sess-g","tool_name":"Edit","tool_input":{"file_path":"%s/x.md"}}' "$P" \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/post-tool-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook answers empty JSON" "$OUT"
assert_no_file "no .claude directory is materialised" "$P/.claude"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
