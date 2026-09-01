#!/bin/bash
# Tests for #248, the session-start-hook.sh half: the automatic call to jit-misses.sh
# (#233 part 3) is now bounded (--tail), and the header this hook parses back out for
# the size-watch note is threaded into the injected context -- nothing else surfaces
# jit-misses.sh's own stdout to the agent on this path.
#
# jit-drive: none -- every assertion here runs a real session-start-hook.sh subprocess.
# Section B drives it against a STUBBED jit-misses.sh rather than the real one, so the
# size-watch wiring is provable without a multi-megabyte fixture: jit-misses.sh's own
# threshold VALUE is pinned by test-jit-misses-bound-248.sh, and this file pins that
# session-start-hook.sh correctly reads back whatever jit-misses.sh says.
#
# Usage: bash tests/test-session-start-bound-248.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/session-start-hook.sh"
MISSES="$REPO/scripts/jit-misses.sh"
COMMON="$REPO/scripts/common.sh"
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

if [ ! -f "$HOOK" ] || [ ! -f "$MISSES" ] || [ ! -f "$COMMON" ]; then
  echo "  FAIL: harness guard -- $HOOK, $MISSES or $COMMON does not exist, every assertion below is vacuous"
  exit 1
fi

echo "=== section A: against the REAL jit-misses.sh, the automatic call names its window ==="
PROJ="$TMP/proj1"
LOGDIR="$PROJ/.claude/jit-context/.discovery/logs"
mkdir -p "$LOGDIR"
{
  printf '[10:00:00.000] pre-prompt 1ms | (none) [shown:0] << how do I configure preprod deploy\n'
  printf '[10:01:00.000] pre-prompt 1ms | (none) [shown:0] << preprod deploy is still broken\n'
  printf '[10:02:00.000] pre-prompt 1ms | (none) [shown:0] << can we automate preprod deploy\n'
} > "$LOGDIR/hooks.log"
OUT=$(CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" < /dev/null 2>/dev/null)
assert_valid_json_shape "still valid JSON-object shaped output" "$OUT"
assert_contains "still names the recurring miss (unchanged behaviour, small log)" "$OUT" "preprod"
assert_contains "says WHICH window the findings came from (#248)" "$OUT" "line(s) of the log"

echo ""
echo "=== section B: a STUBBED jit-misses.sh drives the size-watch wiring itself ==="
# The stub speaks exactly the shape jit-misses.sh's real END block speaks -- a
# "SKIPPED"-free exit 0, then the header lines the hook's own awk passes parse -- so
# this exercises session-start-hook.sh's JIT_SIZE_NOTE extraction and JSON-embedding
# without needing a real log anywhere near the byte threshold.
STUBDIR="$TMP/scripts"
mkdir -p "$STUBDIR"
cp "$HOOK" "$STUBDIR/session-start-hook.sh"
cp "$COMMON" "$STUBDIR/common.sh"
cat > "$STUBDIR/jit-misses.sh" <<'STUB'
#!/bin/bash
# Test stub for #248 -- speaks the exact header shape session-start-hook.sh parses.
printf 'jit-misses: /fake/hooks.log (999999999 bytes)\n'
printf '  bounded read -- last 5000 line(s) requested (--tail 5000)\n'
printf '  the log has reached 999999999 bytes, at or past the 10000000 byte watch threshold (#248) -- reads may be getting slower; consider --tail or rotating\n'
printf '  1 line(s) read, 1 prompt record(s), 1 with no vocabulary match\n'
printf '  ok -- no token is shared by 2 or more of them; nothing here is a repeated gap\n'
exit 0
STUB
chmod +x "$STUBDIR/jit-misses.sh"

PROJ2="$TMP/proj2"
mkdir -p "$PROJ2/.claude/jit-context"
OUT2=$(CLAUDE_PROJECT_DIR="$PROJ2" bash "$STUBDIR/session-start-hook.sh" < /dev/null 2>/dev/null)
assert_valid_json_shape "still valid JSON-object shaped output against the stub" "$OUT2"
assert_contains "threads the size-watch note through when nothing else fired" "$OUT2" "watch threshold"
assert_contains "carries the log's own reported byte size" "$OUT2" "999999999 bytes"
assert_not_contains "an 'ok, nothing recurs' stub does not fabricate a recurring-misses line" "$OUT2" "recurring misses ("

echo ""
echo "=== section B control: the same stub, but under threshold -- no size note ==="
cat > "$STUBDIR/jit-misses.sh" <<'STUB'
#!/bin/bash
printf 'jit-misses: /fake/hooks.log (40 bytes)\n'
printf '  bounded read -- last 5000 line(s) requested (--tail 5000)\n'
printf '  1 line(s) read, 1 prompt record(s), 1 with no vocabulary match\n'
printf '  ok -- no token is shared by 2 or more of them; nothing here is a repeated gap\n'
exit 0
STUB
chmod +x "$STUBDIR/jit-misses.sh"
OUT3=$(CLAUDE_PROJECT_DIR="$PROJ2" bash "$STUBDIR/session-start-hook.sh" < /dev/null 2>/dev/null)
assert_valid_json_shape "still valid JSON-object shaped output, under threshold" "$OUT3"
assert_not_contains "no size note when jit-misses.sh printed none (control)" "$OUT3" "watch threshold"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
