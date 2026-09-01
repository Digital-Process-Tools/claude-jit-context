#!/bin/bash
# Tests for #233 part 3: session-start-hook.sh calls jit-misses.sh and surfaces
# recurring misses at the one moment nothing else is competing for the agent's
# attention -- SessionStart, before any task has begun.
#
# jit-drive: none -- every assertion here runs a real session-start-hook.sh subprocess
# against a real hooks.log fixture and greps its JSON output for a fixed literal shape.
#
# Usage: bash tests/test-session-start-misses-233.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/session-start-hook.sh"
PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:400}"
  fi
}
assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:400}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}
assert_valid_json_shape() {
  local desc="$1" output="$2"
  case "$output" in
    '{}'|'{"hookSpecificOutput"'*) PASS=$((PASS + 1)); echo "  PASS: $desc" ;;
    *) FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; echo "    got: ${output:0:400}" ;;
  esac
}

run_start() {
  # No stdin (a tty in the real harness never has one either) -- session-start-hook.sh
  # already guards `[ ! -t 0 ]` before it reads a session_id, and the SAME `< /dev/null`
  # this suite otherwise relies on for a non-interactive shell to behave like one.
  CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" < /dev/null 2>/dev/null
}

echo "=== a log with a real recurring miss: the session-start hook names it ==="
PROJ="$TMP/proj1"
LOGDIR="$PROJ/.claude/jit-context/.discovery/logs"
mkdir -p "$LOGDIR"
{
  printf '[10:00:00.000] pre-prompt 1ms | (none) [shown:0] << how do I configure preprod deploy\n'
  printf '[10:01:00.000] pre-prompt 1ms | (none) [shown:0] << preprod deploy is still broken\n'
  printf '[10:02:00.000] pre-prompt 1ms | (none) [shown:0] << can we automate preprod deploy\n'
} > "$LOGDIR/hooks.log"
OUT=$(run_start)
assert_valid_json_shape "still valid JSON-object shaped output" "$OUT"
assert_contains "names the recurring miss" "$OUT" "recurring misses"
assert_contains "carries the actual repeated token" "$OUT" "preprod"
assert_contains "carries the actual count" "$OUT" "x3"

echo ""
echo "=== the same project, but with only ONE-OFF misses: no recurring-misses line (control) ==="
PROJ2="$TMP/proj2"
LOGDIR2="$PROJ2/.claude/jit-context/.discovery/logs"
mkdir -p "$LOGDIR2"
printf '[10:00:00.000] pre-prompt 1ms | (none) [shown:0] << totally unique one-off question here\n' > "$LOGDIR2/hooks.log"
OUT2=$(CLAUDE_PROJECT_DIR="$PROJ2" bash "$HOOK" < /dev/null 2>/dev/null)
assert_valid_json_shape "still valid JSON-object shaped output" "$OUT2"
assert_not_contains "no recurring misses reported when nothing recurs" "$OUT2" "recurring misses"

echo ""
echo "=== no log at all yet: the hook still never fails hard ==="
PROJ3="$TMP/proj3"
mkdir -p "$PROJ3/.claude/jit-context"
OUT3=$(CLAUDE_PROJECT_DIR="$PROJ3" bash "$HOOK" < /dev/null 2>/dev/null)
RC3=$?
if [ "$RC3" = 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: exits 0 with no log present"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: did not exit 0 with no log present (exit $RC3)"
fi
assert_valid_json_shape "still valid JSON-object shaped output with no log" "$OUT3"
assert_not_contains "no recurring misses reported when there is no log" "$OUT3" "recurring misses"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
