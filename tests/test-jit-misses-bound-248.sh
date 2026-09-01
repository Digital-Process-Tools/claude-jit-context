#!/bin/bash
# Tests for #248: jit-misses.sh read the WHOLE hooks.log with no bound, and
# session-start-hook.sh (#233 part 3) now calls it on every session. This pins the
# --tail bound, the always-present byte-size header, and the --size-threshold note --
# and that none of it changes what a plain, unbounded, small-log run reports.
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
#
# Usage: bash tests/test-jit-misses-bound-248.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MISSES="$SCRIPT_DIR/scripts/jit-misses.sh"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_status() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $actual, expected $expected)"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$MISSES" ]; then
  echo "  FAIL: harness guard -- $MISSES does not exist, every assertion below is vacuous"
  exit 1
fi

# --- Fixture: an old miss ("legacy") only near the top of the log, and a different
# recurring miss ("preprod") only in the last 3 lines. --tail 3 must see "preprod" and
# must NOT see "legacy" -- the harness guard for this whole file, on the same shape the
# real assertions use, so a --tail that silently reads the whole log anyway (an
# unbounded read that merely CLAIMS to be bounded) cannot pass by accident.
LOG="$TMP/hooks.log"
{
  printf '[10:00:00.000] pre-prompt 1ms | (none) [shown:0] << legacy migration is stuck\n'
  printf '[10:00:01.000] pre-prompt 1ms | (none) [shown:0] << the legacy migration failed again\n'
  printf '[10:00:02.000] pre-prompt 1ms | (none) [shown:0] << unrelated one-off question\n'
  printf '[10:00:03.000] pre-prompt 1ms | (none) [shown:0] << how do I configure preprod deploy\n'
  printf '[10:00:04.000] pre-prompt 1ms | (none) [shown:0] << preprod deploy is still broken\n'
  printf '[10:00:05.000] pre-prompt 1ms | (none) [shown:0] << can we automate preprod deploy\n'
} > "$LOG"
[ -s "$LOG" ] || { echo "  FAIL: harness guard -- fixture log is empty"; exit 1; }

echo ""
echo "=== unbounded (no --tail): sees the old miss, matches today's behaviour ==="
OUT_FULL=$(bash "$MISSES" --log "$LOG" 2>&1) && ST_FULL=0 || ST_FULL=$?
assert_status "exit 0 -- readable" "$ST_FULL" "0"
assert_contains "sees the miss near the top of the log" "$OUT_FULL" "legacy"
assert_contains "sees the miss at the end of the log too" "$OUT_FULL" "preprod"
assert_not_contains "unbounded reads never claim to be bounded" "$OUT_FULL" "bounded read"

echo ""
echo "=== --tail 3: bounds the READ, not just the report (positive control above) ==="
OUT_TAIL=$(bash "$MISSES" --log "$LOG" --tail 3 2>&1) && ST_TAIL=0 || ST_TAIL=$?
assert_status "exit 0 -- readable" "$ST_TAIL" "0"
assert_contains "sees the miss inside the window" "$OUT_TAIL" "preprod"
assert_not_contains "does not see a miss outside the window" "$OUT_TAIL" "legacy"
assert_contains "says the read was bounded" "$OUT_TAIL" "bounded read"
assert_contains "names the window size" "$OUT_TAIL" "--tail 3"

echo ""
echo "=== the header always names the log's byte size, bounded or not ==="
BYTES=$(wc -c < "$LOG" | tr -d '[:space:]')
assert_contains "unbounded header carries the byte count" "$OUT_FULL" "($BYTES bytes)"
assert_contains "bounded header carries the byte count too" "$OUT_TAIL" "($BYTES bytes)"

echo ""
echo "=== --size-threshold: names the log when it is at or past the watch size ==="
OUT_OVER=$(bash "$MISSES" --log "$LOG" --size-threshold 1 2>&1) && ST_OVER=0 || ST_OVER=$?
assert_status "exit 0 -- a threshold note is not a refusal" "$ST_OVER" "0"
assert_contains "names the threshold crossing" "$OUT_OVER" "watch threshold"
assert_contains "names the log's own size in that sentence" "$OUT_OVER" "$BYTES bytes"

echo ""
echo "=== a log under the threshold: no watch-threshold note (control) ==="
OUT_UNDER=$(bash "$MISSES" --log "$LOG" --size-threshold 999999999 2>&1) && ST_UNDER=0 || ST_UNDER=$?
assert_status "exit 0" "$ST_UNDER" "0"
assert_not_contains "no threshold note when nowhere near it" "$OUT_UNDER" "watch threshold"

echo ""
echo "=== --tail rejects the same shape --min and --top do ==="
OUT_BAD=$(bash "$MISSES" --log "$LOG" --tail nope 2>&1) && ST_BAD=0 || ST_BAD=$?
assert_status "a non-numeric --tail is refused, exit 2" "$ST_BAD" "2"
assert_contains "the refusal names --tail" "$OUT_BAD" "SKIPPED -- --tail"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
