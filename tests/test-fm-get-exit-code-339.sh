#!/bin/bash
# #339: jit_fm_get()'s own comment claimed its exit status on a missing field agrees
# with jit_frontmatter()'s -- it did not. jit_frontmatter() ends with
# `[ -n "$_out" ] || return 0`, so a missing field is status 0; jit_fm_get() hit its
# `*) ... ;;` branch and did `return 1` on the identical case. The two disagreed while
# the comment said they matched.
#
# No caller checked the status either function returns on a miss -- every call site in
# jit-dry-run.sh tests the OUTPUT variable with `[ -n "$var" ]` and discards the exit
# code -- so unifying the contract costs nothing today. This test pins the unified
# contract: both functions return 0 on an absent field, and both leave VAR empty.
#
# Usage: bash tests/test-fm-get-exit-code-339.sh
#
# jit-drive: none -- assert_status/assert_equals compare an exit code or an exact
# string against a fixed expected value; neither is a needle-in-payload check this
# harness's drive_declared() semantics (contains/not_contains/blocked/token_row) can
# drive.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$REPO/scripts/common.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

assert_status() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted exit $want, got $got"
  fi
}

assert_equals() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted [$want], got [$got]"
  fi
}

# shellcheck source=../scripts/common.sh
. "$COMMON"

ROOT=$(mktemp -d)
ENTRY="$ROOT/entry.md"
{
  echo "---"
  echo "title: Has a title, no match field"
  echo "tool: Bash"
  echo "---"
  echo ""
  echo "Body."
} > "$ENTRY"

echo ""
echo "=== jit_frontmatter_many() + jit_fm_get() on a field the entry does not carry ==="
fm=""
jit_frontmatter_many fm "$ENTRY" match
out=""
jit_fm_get out "$fm" match
status=$?
assert_status "jit_fm_get() exit status on a miss"  "$status"  0
assert_equals "jit_fm_get() leaves VAR empty on a miss" "$out" ""

echo ""
echo "=== jit_frontmatter() directly, on the same missing field -- the contract jit_fm_get() must match ==="
direct="$(LC_ALL=C jit_frontmatter match "$ENTRY")"
direct_status=$?
assert_status "jit_frontmatter() exit status on a miss" "$direct_status" 0
assert_equals "jit_frontmatter() prints nothing on a miss" "$direct" ""

echo ""
echo "=== a field the entry DOES carry still round-trips through both, as a positive control ==="
fm2=""
jit_frontmatter_many fm2 "$ENTRY" title
title_out=""
jit_fm_get title_out "$fm2" title
title_status=$?
assert_status "jit_fm_get() exit status on a hit" "$title_status" 0
assert_equals "jit_fm_get() returns the value on a hit" "$title_out" "Has a title, no match field"

rm -rf "$ROOT"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
