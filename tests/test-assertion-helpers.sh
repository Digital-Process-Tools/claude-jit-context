#!/bin/bash
# The harness asserting about itself.
#
# Every suite here decides PASS/FAIL by piping the captured output into `grep -q`.
# `grep -q` exits the instant it matches; the writer on the left of the pipe is then
# writing into a closed pipe and takes SIGPIPE; under `set -o pipefail` the pipeline
# status is non-zero. So the helper reports the OPPOSITE of what it found -- but only
# once the output is longer than the pipe buffer, which is exactly when someone is
# already debugging whatever made it long. Issue #56.
#
# Both directions, and the second one is the dangerous half:
#   assert_contains     with a present needle  -> reports FAIL  (false red)
#   assert_not_contains with a present needle  -> reports PASS  (false GREEN)
#
# The writer is not the cause: printf takes the signal exactly as echo does. The cause
# is the early exit on the right.
#
# This suite does not go through a hook. It extracts each suite real helper functions
# and calls them directly with a controlled 1 MB payload, because "long enough to fill
# the pipe buffer" is a platform-dependent number and guessing it per-platform is the
# thing this test exists in order not to do. 1 MB is ~16x the largest pipe buffer any
# of the three CI platforms uses, so the signal is raised on all three or on none.
#
# Usage: bash tests/test-assertion-helpers.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
DROVE=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
  FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift
  for l in "$@"; do echo "    $l"; done
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t jit56)"
trap 'rm -rf "$WORK"' EXIT

# --- The payload -------------------------------------------------------------------
#
# The needle is FIRST. grep matches on line 1 and exits immediately, which is the worst
# case for the writer and the one the bug needs.
NEEDLE="NEEDLEXYZ"
ABSENT="ABSENTXYZ"
FILLER="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BIG="$NEEDLE"
i=0
while [ "$i" -lt 15 ]; do
  BIG="$BIG
$FILLER"
  BIG="$BIG$BIG"
  i=$((i + 1))
done
BYTES=${#BIG}
if [ "$BYTES" -lt 1000000 ]; then
  echo "  FAIL: payload is only $BYTES bytes -- too small to raise SIGPIPE reliably"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi
echo "Payload: $BYTES bytes, needle on line 1"

# Row-shaped variants, for the helpers that match a whole line rather than a substring.
TOKEN="tokenxyz"
BIGROW="  2x  $TOKEN
$BIG"
BLOCKLINE=$(printf %s "{" ; printf %s "\"decision\":\"block\"}")
BIGBLOCK="$BLOCKLINE
$BIG"

# --- Driving a real helper ----------------------------------------------------------
#
# Extract every function definition from a suite into a file we can source. Line-range
# extraction on `name() {` .. `}` at column 0, which is how every suite here is
# written. A suite that yields nothing is reported by the DROVE floor below, never
# skipped silently.
extract_funcs() {
  awk '
    /^[a-z_][a-z0-9_]*\(\)/ {
      print
      infunc = ($0 ~ /\}[[:space:]]*$/) ? 0 : 1
      next
    }
    infunc { print }
    /^\}$/ { infunc = 0 }
  ' "$1"
}

# Call one helper of one suite in a subshell and report the verdict it printed:
# exactly "PASS", "FAIL" or "ERR".
verdict() {
  local funcs="$1" fn="$2"
  shift 2
  (
    set -uo pipefail
    PASS=0
    FAIL=0
    # shellcheck disable=SC1090
    . "$funcs" 2>/dev/null || { echo ERR; exit 0; }
    "$fn" "$@" >/dev/null 2>&1
    if [ "$PASS" = 1 ] && [ "$FAIL" = 0 ]; then echo PASS
    elif [ "$FAIL" = 1 ] && [ "$PASS" = 0 ]; then echo FAIL
    else echo ERR
    fi
  )
}

# suite, funcs file, helper name, expected verdict, then the helper own args.
check() {
  local suite="$1" funcs="$2" fn="$3" want="$4"
  shift 4
  local got
  got=$(verdict "$funcs" "$fn" "$@")
  DROVE=$((DROVE + 1))
  if [ "$got" = "$want" ]; then
    pass "$suite: $fn reports $want"
  else
    fail "$suite: $fn should report $want" "got: $got"
  fi
}

for suite in "$TESTS_DIR"/test-*.sh; do
  name="$(basename "$suite")"
  [ "$name" = "test-assertion-helpers.sh" ] && continue
  funcs="$WORK/$name.funcs"
  extract_funcs "$suite" > "$funcs"

  if grep -qF "assert_contains() {" "$funcs"; then
    check "$name" "$funcs" assert_contains PASS "d" "$BIG" "$NEEDLE"
    check "$name" "$funcs" assert_contains FAIL "d" "$BIG" "$ABSENT"
  fi
  if grep -qF "assert_not_contains() {" "$funcs"; then
    check "$name" "$funcs" assert_not_contains PASS "d" "$BIG" "$ABSENT"
    check "$name" "$funcs" assert_not_contains FAIL "d" "$BIG" "$NEEDLE"
  fi
  if grep -qF "assert_token_row() {" "$funcs"; then
    check "$name" "$funcs" assert_token_row PASS "d" "$BIGROW" "$TOKEN"
  fi
  if grep -qF "assert_no_token_row() {" "$funcs"; then
    check "$name" "$funcs" assert_no_token_row FAIL "d" "$BIGROW" "$TOKEN"
  fi
  if grep -qF "assert_blocked() {" "$funcs"; then
    check "$name" "$funcs" assert_blocked PASS "d" "$BIGBLOCK"
  fi
done

# A run that drove nothing would print a clean sweep having tested no helper at all --
# the same vacuous pass the dogfood suite guards against. The floor sits below the
# current count so adding a suite does not break it, and far above zero.
if [ "$DROVE" -lt 20 ]; then
  fail "drove only $DROVE helper calls -- extraction found almost nothing" \
       "every result above is vacuous; expected at least 20"
else
  pass "drove $DROVE real helper calls across the suites"
fi

# --- Structural guard ---------------------------------------------------------------
#
# Catches reintroduction, and covers helper names this suite does not enumerate.
# `grep -q` and `head` are the two early-exiting right-hand sides in this tree.
echo ""
echo "Structural: nothing pipes into an early-exiting reader"
SCANNED=0
for f in "$TESTS_DIR"/*.sh; do
  SCANNED=$((SCANNED + 1))
  hits=$(grep -nE '\|[[:space:]]*(grep[[:space:]]+-[a-zA-Z]*q|head[[:space:]])' "$f")
  if [ -n "$hits" ]; then
    fail "$(basename "$f"): pipes into an early-exiting reader" "$hits"
  fi
done
if [ "$SCANNED" -lt 10 ]; then
  fail "scanned only $SCANNED files -- the structural guard saw no suites"
else
  pass "scanned $SCANNED files for the pipe shape"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
