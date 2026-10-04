#!/bin/bash
# #461: the Anthropic directory validator holds COMMAND_SCRIPT_NOT_FOLLOWED
# ("Scripts the validator couldn't follow") on every hook while jit_load_config, the
# config.env reader compiled into all six, carries a case pattern with a POSIX
# character class: `export[[:space:]]*)` and `*[[:space:]]#*)`. Bisected on
# post-tool-hook.sh (2026-10-03): every variant with such a pattern held, every one
# without cleared, and the same class inside a ${...} expansion (`${line#[[:space:]]}`)
# never held. The test is in docs/directory-validator.md.
#
# This suite sweeps scripts/*.sh for a case-arm pattern carrying `[[:name:]]`. A pattern
# is recognised by its shape -- a line whose first word ends in `)` and holds a class --
# so an awk regex (`sub(/[[:space:]]+/, ...)`) and an expansion are not matched; each
# side is proven on a planted fixture first, because a sweep that finds nothing must be
# told apart from a pattern that never matches.
#
# Usage: bash tests/test-no-class-case-patterns-461.sh
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

# A case arm: optional indent, then a pattern word (no space, no `(`, no `=`) holding
# `[[:name:]]`, optionally `|`-joined with more words, closed by `)`. perl, not awk: an
# awk ERE cannot spell a literal `[[:` without reading it as the start of a class.
sweep() {
  perl -ne 'next if /^\s*#/; print "$.: $_" if /^\s*[^\s(=#]*\[\[:[a-z]+:\]\][^\s()]*(?:\s*\|\s*[^\s()]+)*\)/' "$1"
}

echo "=== controls: the needle matches a class in a case arm, and nothing else ==="
fixture="$(mktemp)"
safe="$(mktemp)"
trap 'rm -f "$fixture" "$safe"' EXIT
printf '%s\n' \
  '      export[[:space:]]*)' \
  '          *[[:space:]]#*) value="${value%%[[:space:]]#*}" ;;' \
  '    *[[:space:]]*)' \
  > "$fixture"
printf '%s\n' \
  '    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done' \
  '   sub(/^[[:space:]]+/, "", trimmed)' \
  '    value="${value%%[[:space:]]#*}"' \
  '      *=*)' \
  '      # a comment may show export[[:space:]]*)' \
  > "$safe"
n=$(sweep "$fixture" | awk 'END { print NR }')
if [ "$n" -eq 3 ]; then
  ok "control: all 3 planted case arms with a class are found"
else
  bad "control: found $n of 3 planted arms -- the sweep below is not trustworthy" "$(sweep "$fixture")"
fi
hits="$(sweep "$safe")"
if [ -z "$hits" ]; then
  ok "control: expansions, awk regexes, plain arms and comments are left alone"
else
  bad "control: a safe shape is flagged" "$hits"
fi

echo ""
echo "=== no POSIX class in a case pattern of any shipped script ==="
for f in "$REPO"/scripts/*.sh; do
  hits="$(sweep "$f")"
  if [ -z "$hits" ]; then
    ok "$(basename "$f")"
  else
    bad "$(basename "$f"): case pattern with a POSIX class" "$hits"
  fi
done

echo ""
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
