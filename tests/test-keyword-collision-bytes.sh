#!/bin/bash
# Keyword collisions reported cross-layer, ranked by bytes, with a byte floor (#204).
#
# Before this: the ambiguity report grouped per LAYER and thresholded on FILE COUNT (>5).
# Neither survives a real tree. The dominant shape is one concept restated ACROSS
# 00-manual/10-auto/20-grouped/30-crosscutting -- invisible to a per-layer tally, because
# each layer's own count never crosses the threshold on its own. And a 2-entry collision
# between two fat entries costs more than a 9-entry collision between stubs -- invisible to
# a file-count threshold, because it counts files instead of the bytes a match actually
# pulls.
#
# Three things this fixture proves, all in ONE tree with ONE floor, because the negative
# ("six tiny files sharing a keyword are NOT reported") is meaningless without a positive
# ("two fat files sharing a keyword ARE reported") beside it in the same run:
#
#   1. POSITIVE, cross-layer: two entries in DIFFERENT vocabulary layers sharing a keyword,
#      together over the floor -- reported, and named with which layer each file is in.
#   2. POSITIVE, same-layer: two entries in the SAME layer sharing a different keyword,
#      together over the floor -- still reported (the cross-layer widening must not have
#      broken the within-layer case it grew out of).
#   3. NEGATIVE: six tiny entries in one layer sharing a third keyword, comfortably UNDER
#      the floor even summed -- not reported, despite the file count (6) being exactly the
#      shape the OLD ">5 files" threshold would have flagged. This is the control that
#      proves the file-count heuristic is gone, not just widened.
#
# Usage: bash tests/test-keyword-collision-bytes.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

# jit-drive: assert_has contains path-arg
# jit-drive: assert_lacks not_contains path-arg
assert_has() {
  if LC_ALL=C grep -qF -- "$3" "$2"; then ok "$1"; else
    bad "$1" "expected to contain: $3"
    echo "    --- got ---"; cat "$2"
  fi
}
assert_lacks() {
  if LC_ALL=C grep -qF -- "$3" "$2"; then
    bad "$1" "expected NOT to contain: $3"
    echo "    --- got ---"; cat "$2"
  else
    ok "$1"
  fi
}

PROJ=$(mktemp -d)
BASE="$PROJ/.claude/jit-context"
LAYER_A="$BASE/vocabulary/00-manual"
LAYER_B="$BASE/vocabulary/10-auto"
mkdir -p "$LAYER_A" "$LAYER_B"

pad() {
  # $1 = target body byte count, roughly -- one repeated line, newline-terminated.
  local n="$1" line
  line=$(printf 'x%.0s' $(seq 1 60))
  local out="" total=0
  while [ "$total" -lt "$n" ]; do
    out="$out$line
"
    total=$((total + 61))
  done
  printf '%s' "$out"
}

# 1. Cross-layer positive: "modern nav" in layer A and layer B, together over the floor.
#    Each file is padded well past the floor's per-pair share on its own (~630 bytes),
#    so the pair (~1260 bytes) comfortably clears a floor of 1000.
printf -- '---\ntitle: t\nkeywords: modern nav\n---\n\n%s' "$(pad 600)" > "$LAYER_A/gate.md"
printf -- '---\ntitle: t\nkeywords: modern nav\n---\n\n%s' "$(pad 600)" > "$LAYER_B/component.md"

# 2. Same-layer positive: "a11y runtime" in layer A twice, together over the floor.
printf -- '---\ntitle: t\nkeywords: a11y runtime\n---\n\n%s' "$(pad 600)" > "$LAYER_A/a11y-one.md"
printf -- '---\ntitle: t\nkeywords: a11y runtime\n---\n\n%s' "$(pad 600)" > "$LAYER_A/a11y-two.md"

# 3. Negative: "six pack" shared by six TINY entries in layer A -- 6 files (over the OLD
#    ">5 files" threshold) but comfortably under the byte floor even summed (~44b each,
#    ~264b total -- well under 1000).
for i in 1 2 3 4 5 6; do
  printf -- '---\ntitle: t\nkeywords: six pack\n---\n\ntiny.\n' > "$LAYER_A/stub$i.md"
done

ERR=$(mktemp)
JIT_CONTEXT_COLLISION_BYTES=1000 CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" >/dev/null 2>"$ERR"

echo ""
echo "=== #204: cross-layer, byte-ranked collision report, floor=1000 ==="
assert_has   "the cross-layer keyword is reported at all" "$ERR" "modern nav"
assert_has   "layer A's file is named with its own layer" "$ERR" "gate.md[vocabulary/00-manual]"
assert_has   "layer B's file is named with its own layer, not folded into A's tally" \
  "$ERR" "component.md[vocabulary/10-auto]"
assert_has   "the entry count for a 2-file cross-layer collision is 2" "$ERR" "2 entr(ies)"

assert_has   "the same-layer collision still fires" "$ERR" "a11y runtime"
assert_has   "and both its files are named" "$ERR" "a11y-one.md[vocabulary/00-manual]"
assert_has   "both of them, not just one" "$ERR" "a11y-two.md[vocabulary/00-manual]"

assert_lacks "six tiny files under the byte floor are NOT reported, file count notwithstanding" \
  "$ERR" "six pack"

echo ""
echo "=== #204: the floor is configurable, and the default is stated ==="
ERR2=$(mktemp)
CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" >/dev/null 2>"$ERR2"
assert_has "the header states the floor in effect (unset -> the 4096-byte default)" "$ERR2" ">4096b"
rm -f "$ERR2"

rm -f "$ERR"
rm -rf "$PROJ"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
