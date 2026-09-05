#!/bin/bash
# #243: the age footer #233 added reads a filesystem mtime, and a fresh `git clone`
# resets every file's mtime to checkout time -- so the three audiences the footer was
# added for (a new contributor's first clone, a CI leg, a fresh plugin install) see
# "last edited 0d ago" on every entry, confidently wrong.
#
# Shape 3 from #243's own body ("detect and decline"): if every scanned file in a
# 00-manual layer sits within a short window of the SAME mtime, that is a checkout
# signature rather than a coincidence, and the footer omits the age entirely rather
# than print a number nobody can trust. Three states, not two: an age, no age, and
# never a wrong age.
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
#
# Usage: bash tests/test-entry-age-decline-243.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  [ $# -eq 0 ] || echo "    $*"
}

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF -- "$want" <<< "$out"; then
    ok "$desc"
  else
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  fi
}
assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if grep -qF -- "$unwanted" <<< "$out"; then
    bad "$desc" "must NOT contain: $unwanted"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  else
    ok "$desc"
  fi
}

run_prompt() {
  # $1 project dir, $2 prompt text
  printf '{"prompt":"%s"}' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$PROMPT_HOOK" 2> /dev/null
}

IDXNAME="00-index"
IDXNAME="$IDXNAME.tsv"

echo "=== A. every mtime in the 00-manual layer within seconds of each other: the footer omits the age (checkout signature) ==="
ROOT_A="$(mktemp -d 2> /dev/null || mktemp -d -t jit243a)"
trap 'chmod -R u+rwX "$ROOT_A" 2>/dev/null; rm -rf "$ROOT_A"' EXIT
BASE_A="$ROOT_A/proj/.claude/jit-context/vocabulary/00-manual"
mkdir -p "$BASE_A"
{
  printf 'onekw\tone.md\t\n'
  printf 'twokw\ttwo.md\t\n'
} > "$BASE_A/$IDXNAME"
echo "one body" > "$BASE_A/one.md"
echo "two body" > "$BASE_A/two.md"
# Both files were just written by this script -- an ordinary `git clone` produces
# exactly this shape, every mtime within the same instant.
OUT_A=$(run_prompt "$ROOT_A/proj" "tell me about onekw")
assert_contains "still matches (positive control: this run saw something)" "$OUT_A" "matched: onekw"
assert_not_contains "no age is claimed -- it would be wrong" "$OUT_A" "last edited"

echo ""
echo "=== B. mtimes genuinely spread across time: the footer still carries a real age (control) ==="
ROOT_B="$(mktemp -d 2> /dev/null || mktemp -d -t jit243b)"
trap 'chmod -R u+rwX "$ROOT_B" 2>/dev/null; rm -rf "$ROOT_B"; chmod -R u+rwX "$ROOT_A" 2>/dev/null; rm -rf "$ROOT_A"' EXIT
BASE_B="$ROOT_B/proj/.claude/jit-context/vocabulary/00-manual"
mkdir -p "$BASE_B"
{
  printf 'onekw\tone.md\t\n'
  printf 'twokw\ttwo.md\t\n'
} > "$BASE_B/$IDXNAME"
echo "one body" > "$BASE_B/one.md"
echo "two body" > "$BASE_B/two.md"
# One entry is old, one is fresh -- a real spread, not a checkout artefact.
touch -t 202001010000 "$BASE_B/one.md"
EXPECT_DAYS="$(perl -e 'print int(-M $ARGV[0])' "$BASE_B/one.md")"
OUT_B=$(run_prompt "$ROOT_B/proj" "tell me about onekw")
assert_contains "the real age still renders when the spread is genuine" "$OUT_B" "last edited ${EXPECT_DAYS}d ago"

echo ""
echo "=== C. the decline in case A is distinguishable in the log from a genuine absence of entries ==="
LOG_A="$ROOT_A/proj/.claude/jit-context/.discovery/logs/hooks.log"
if [ -f "$LOG_A" ]; then
  assert_contains "the log names the decline, not just silence" "$(cat "$LOG_A")" "checkout"
else
  bad "hooks.log was written for case A" "no such file: $LOG_A"
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
