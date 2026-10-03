#!/bin/bash
# #461: the Anthropic directory validator holds COMMAND_SCRIPT_NOT_FOLLOWED, listing a
# bare `.` as the further file, while a shipped script carries a quote character written
# alone inside the other kind of quote: '"' or "'". Bisected on post-tool-hook.sh
# (2026-10-03): jit_cfg_unquote alone held with `[ "$q" = '"' ] || [ "$q" = "'" ]`
# (release-preview-u1) and cleared with the two characters taken from printf escapes
# (release-preview-s1). docs/directory-validator.md has the whole bisection.
#
# This suite sweeps scripts/*.sh for either literal outside comments, each side proven
# on a planted fixture first.
#
# Usage: bash tests/test-no-lone-quote-literals-461.sh
#
# jit-drive: none -- this suite scans tracked files for a text shape; it defines no assertion helper

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

sweep() {
  perl -ne 'next if /^\s*#/; print "$.: $_" if /\x27"\x27|"\x27"/' "$1"
}

echo "=== controls ==="
fixture="$(mktemp)"
safe="$(mktemp)"
trap 'rm -f "$fixture" "$safe"' EXIT
printf '%s\n' \
  "  if [ \"\$q\" = '\"' ]; then" \
  "  if [ \"\$q\" = \"'\" ]; then" \
  > "$fixture"
printf '%s\n' \
  "  printf -v dq '\\042'" \
  "  echo \"it's fine\"" \
  "  # a comment may show '\"' and \"'\"" \
  > "$safe"
n=$(sweep "$fixture" | awk 'END { print NR }')
if [ "$n" -eq 2 ]; then
  ok "control: both planted lone-quote literals are found"
else
  bad "control: found $n of 2 planted literals -- the sweep below is not trustworthy"
fi
hits="$(sweep "$safe")"
if [ -z "$hits" ]; then
  ok "control: printf escapes, apostrophes in prose and comments are left alone"
else
  bad "control: a safe shape is flagged" "$hits"
fi

echo ""
echo "=== no lone quote-character literal in any shipped script ==="
for f in "$REPO"/scripts/*.sh; do
  hits="$(sweep "$f")"
  if [ -z "$hits" ]; then
    ok "$(basename "$f")"
  else
    bad "$(basename "$f"): lone quote-character literal" "$hits"
  fi
done

echo ""
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
