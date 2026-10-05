#!/bin/bash
# The Anthropic directory validator holds COMMAND_SCRIPT_NOT_FOLLOWED on a case pattern
# written with its optional leading parenthesis, `case "$-" in (*x*)`. Found on
# claude-remember (2026-10-05, release-preview @ c108980): every one of its 121 case
# patterns rewritten without the `(` cleared the hooks that held. Recorded as trigger 11
# in the shared directory-publishing notes. jit-context ships no such pattern today; this
# suite keeps it that way.
#
# An awk rule opening on a parenthesised condition, `(FILENAME in isgenericfile) {`,
# looks alike and is NOT this shape: v0.16.0 carried three of them and the portal raised
# nothing on them. So the needle wants one pattern word (or `|`-joined words) with no
# space inside the parentheses, and never a `{` after them. Both sides are proven on a
# planted fixture first, because a sweep that finds nothing must be told apart from a
# needle that never matches.
#
# Usage: bash tests/test-no-paren-case-patterns.sh
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

# A case arm opening on `(`: at the start of a line or after `case ... in`, a `(` not followed by
# a space or another `(` (a subshell or `((...))`), pattern words with no space, closed
# by `)`, and no `{` after it (an awk rule). perl, for the lookaheads.
sweep() {
  perl -ne 'next if /^\s*#/; print "$.: $_" if /(^\s*|\bcase\s.*\bin\s+)\((?![\s(])[^\s()]+(?:\s*\|\s*[^\s()]+)*\)(?!\s*\{)/' "$1"
}

echo "=== controls: the needle matches a parenthesised case arm, and nothing else ==="
fixture="$(mktemp)"
safe="$(mktemp)"
trap 'rm -f "$fixture" "$safe"' EXIT
printf '%s\n' \
  '  case "$-" in (*x*) set +x ;; esac' \
  '    (*.md) echo md ;;' \
  '    (a | b) : ;;' \
  '    (--help|-h)' \
  > "$fixture"
printf '%s\n' \
  '(FILENAME in isgenericfile) {' \
  '  (NR > 1) { next }' \
  '  ( cd "$dir" && pwd )' \
  '  ((i++))' \
  '    *.md) echo md ;;' \
  '  words=(a b c)' \
  '  # a comment may show (*x*)' \
  '  echo "standing in (#417)." >&2' \
  > "$safe"
n=$(sweep "$fixture" | awk 'END { print NR }')
if [ "$n" -eq 4 ]; then
  ok "control: all 4 planted parenthesised arms are found"
else
  bad "control: found $n of 4 planted arms -- the sweep below is not trustworthy" "$(sweep "$fixture")"
fi
hits="$(sweep "$safe")"
if [ -z "$hits" ]; then
  ok "control: awk rules, subshells, arithmetic, arrays, plain arms and comments are left alone"
else
  bad "control: a safe shape is flagged" "$hits"
fi

echo ""
echo "=== no parenthesised case pattern in any shipped script ==="
for f in "$REPO"/scripts/*.sh; do
  hits="$(sweep "$f")"
  if [ -z "$hits" ]; then
    ok "$(basename "$f")"
  else
    bad "$(basename "$f"): case pattern opening on (" "$hits"
  fi
done

echo ""
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
