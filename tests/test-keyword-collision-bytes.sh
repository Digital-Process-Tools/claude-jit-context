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

# jit-drive: assert_has contains path-arg
# jit-drive: assert_lacks not_contains path-arg
assert_has() {
  if LC_ALL=C grep -qF -- "$3" "$2"; then ok "$1"; else
    bad "$1" "expected to contain: $3"
    echo "    --- got ---"
    cat "$2"
  fi
}
assert_lacks() {
  if LC_ALL=C grep -qF -- "$3" "$2"; then
    bad "$1" "expected NOT to contain: $3"
    echo "    --- got ---"
    cat "$2"
  else
    ok "$1"
  fi
}

# The report is TWO lines per collision -- a header naming the keyword, then an indented
# files: line -- and sorting them by bytes without keeping the two lines PAIRED is exactly
# how a keyword ends up printed beside somebody else's files (found live in review: an
# isort() call that reordered bytes/count/files but left the keyword array out of its own
# argument list, so every row after the first swap was labelled with the wrong term).
# jit-drive: none -- these two take a KEYWORD and a WANT/NOPE needle, both against a
# derived slice of the file (the line right after the keyword's own header), not a single
# needle against the whole file or a capture -- outside the shapes this harness drives.
assert_block_has() {
  local desc="$1" file="$2" kwtext="$3" want="$4" got
  got=$(LC_ALL=C grep -A1 -F "\"$kwtext\"" "$file" | tail -n1)
  case "$got" in
    *"$want"*) ok "$desc" ;;
    *)
      bad "$desc" "the files: line right after \"$kwtext\" was expected to contain: $want"
      echo "    got: $got"
      ;;
  esac
}
assert_block_lacks() {
  local desc="$1" file="$2" kwtext="$3" nope="$4" got
  got=$(LC_ALL=C grep -A1 -F "\"$kwtext\"" "$file" | tail -n1)
  case "$got" in
    *"$nope"*)
      bad "$desc" "the files: line right after \"$kwtext\" was expected NOT to contain: $nope"
      echo "    got: $got"
      ;;
    *) ok "$desc" ;;
  esac
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
JIT_CONTEXT_COLLISION_BYTES=1000 CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" > /dev/null 2> "$ERR"

echo ""
echo "=== #204: cross-layer, byte-ranked collision report, floor=1000 ==="
assert_has "the cross-layer keyword is reported at all" "$ERR" "modern nav"
assert_has "layer A's file is named with its own layer" "$ERR" "gate.md[vocabulary/00-manual]"
assert_has "layer B's file is named with its own layer, not folded into A's tally" \
  "$ERR" "component.md[vocabulary/10-auto]"
assert_has "the entry count for a 2-file cross-layer collision is 2" "$ERR" "2 entr(ies)"

assert_has "the same-layer collision still fires" "$ERR" "a11y runtime"
assert_has "and both its files are named" "$ERR" "a11y-one.md[vocabulary/00-manual]"
assert_has "both of them, not just one" "$ERR" "a11y-two.md[vocabulary/00-manual]"

assert_lacks "six tiny files under the byte floor are NOT reported, file count notwithstanding" \
  "$ERR" "six pack"

echo ""
echo "=== #204: the floor is configurable, and the default is stated ==="
ERR2=$(mktemp)
CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" > /dev/null 2> "$ERR2"
assert_has "the header states the floor in effect (unset -> the 4096-byte default)" "$ERR2" ">4096b"
rm -f "$ERR2"

rm -f "$ERR"
rm -rf "$PROJ"

# ============================================================================
# A DEDICATED fixture for the pairing itself: two collisions, deliberately inserted in
# BYTE-ASCENDING order (small keyword first, because its file sorts first alphabetically)
# so that printing byte-DESCENDING requires a real reorder -- the exact case an isort()
# call missing an array from its argument list gets right on a single-item report and
# wrong the moment there is a second item to swap past.
# ============================================================================
echo ""
echo "=== #204: sorted output keeps each keyword paired with ITS OWN bytes and files ==="
SPROJ=$(mktemp -d)
SBASE="$SPROJ/.claude/jit-context/vocabulary/00-manual"
mkdir -p "$SBASE"
printf -- '---\ntitle: t\nkeywords: aaa small kw\n---\n\n%s' "$(pad 100)" > "$SBASE/aaa-one.md"
printf -- '---\ntitle: t\nkeywords: aaa small kw\n---\n\n%s' "$(pad 100)" > "$SBASE/aaa-two.md"
printf -- '---\ntitle: t\nkeywords: zzz big kw\n---\n\n%s' "$(pad 3000)" > "$SBASE/zzz-one.md"
printf -- '---\ntitle: t\nkeywords: zzz big kw\n---\n\n%s' "$(pad 3000)" > "$SBASE/zzz-two.md"

SERR=$(mktemp)
JIT_CONTEXT_COLLISION_BYTES=50 CLAUDE_PROJECT_DIR="$SPROJ" bash "$REBUILD" > /dev/null 2> "$SERR"

assert_block_has "the small (alphabetically-first, byte-ascending) keyword keeps its OWN files" \
  "$SERR" "aaa small kw" "aaa-one.md"
assert_block_lacks "not the big keyword's files" "$SERR" "aaa small kw" "zzz-one.md"
assert_block_has "the big keyword keeps ITS OWN files" "$SERR" "zzz big kw" "zzz-one.md"
assert_block_lacks "not the small keyword's files" "$SERR" "zzz big kw" "aaa-one.md"

# The bigger collision is printed FIRST (descending by bytes), even though its keyword was
# inserted SECOND (zzz sorts after aaa alphabetically, and files are globbed in that
# order) -- so this line only passes if a real reorder happened, not merely if insertion
# order and byte order already agreed.
BIGLINE=$(grep -n '"zzz big kw"' "$SERR" | cut -d: -f1)
SMALLLINE=$(grep -n '"aaa small kw"' "$SERR" | cut -d: -f1)
if [ -n "$BIGLINE" ] && [ -n "$SMALLLINE" ] && [ "$BIGLINE" -lt "$SMALLLINE" ]; then
  ok "the bigger collision prints before the smaller one, despite the opposite insertion order"
else
  bad "the bigger collision prints before the smaller one, despite the opposite insertion order" \
    "zzz big kw at line ${BIGLINE:-?}, aaa small kw at line ${SMALLLINE:-?}"
fi

rm -f "$SERR"
rm -rf "$SPROJ"

# ============================================================================
# A keyword only ONE file carries is not a COLLISION -- nothing else loads alongside it.
# ============================================================================
echo ""
echo "=== #204: a keyword with only ONE file is not reported as a collision ==="
OPROJ=$(mktemp -d)
OBASE="$OPROJ/.claude/jit-context/vocabulary/00-manual"
mkdir -p "$OBASE"
printf -- '---\ntitle: t\nkeywords: solo fat entry\n---\n\n%s' "$(pad 3000)" > "$OBASE/solo.md"

OERR=$(mktemp)
JIT_CONTEXT_COLLISION_BYTES=50 CLAUDE_PROJECT_DIR="$OPROJ" bash "$REBUILD" > /dev/null 2> "$OERR"
assert_lacks "a single fat entry, however far over the floor, is not an ambiguity finding" \
  "$OERR" "solo fat entry"
rm -f "$OERR"
rm -rf "$OPROJ"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
