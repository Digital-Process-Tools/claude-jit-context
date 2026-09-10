#!/bin/bash
# Tests for {{dimension/layer/file.md}} transclusion (#378): one entry body carrying
# another entry's body directly, expanded at fire time.
#
# Every "must refuse" case below is paired with a "must successfully transclude" case in
# the SAME fixture set, per this repo's own rule that a negative assertion needs a
# positive control -- a silence assertion passes just as well when the harness itself is
# broken as when the refusal actually fired.
#
# Usage: bash tests/test-transclusion-378.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATH_HOOK="$SCRIPT_DIR/scripts/pre-path-hook.sh"
PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
BASE="$TEST_DIR/.claude/jit-context"
P="$BASE/paths/00-manual"
mkdir -p "$P"

run_path() { printf '%s' "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$1\"}}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2> /dev/null; }

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if [[ "$output" == *"$expected"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:400}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if [[ "$output" == *"$unexpected"* ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:400}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

INDEX="$P/00-index.tsv"

# =============================================
# SECTION 1: a bare transclusion splices the target body in, frontmatter stripped
# =============================================
echo "=== SECTION 1: an ordinary transclusion ==="

printf '%s\n' \
  "---" \
  "title: Included" \
  "description: The file that gets pulled in." \
  "keywords: neverfired" \
  "---" \
  "INCLUDED-BODY-MARKER" > "$P/inc.md"

printf '%s\n' \
  "---" \
  "title: Main" \
  "description: Transcludes inc.md." \
  "keywords: transonekw" \
  "---" \
  "before-marker" \
  "{{paths/00-manual/inc.md}}" \
  "after-marker" > "$P/main1.md"

printf '%s\t%s\n' transonekw main1.md > "$INDEX"

OUT=$(run_path "$TEST_DIR/transonekw.txt")
assert_contains "the included body is spliced in" "$OUT" "INCLUDED-BODY-MARKER"
assert_contains "text before it survives" "$OUT" "before-marker"
assert_contains "text after it survives" "$OUT" "after-marker"
assert_not_contains "the included file own frontmatter is stripped" "$OUT" "neverfired"
assert_not_contains "the braces themselves do not survive the splice" "$OUT" "{{paths/00-manual/inc.md}}"

# =============================================
# SECTION 2: a target that does not resolve is refused, named, in place
# =============================================
echo ""
echo "=== SECTION 2: an unresolvable target is refused, not silently dropped ==="

printf '%s\n' \
  "---" \
  "title: Dangling" \
  "description: Points at a file that is not there." \
  "keywords: transdangle" \
  "---" \
  "before-marker" \
  "{{paths/00-manual/does-not-exist.md}}" \
  "after-marker" > "$P/main2.md"

printf '%s\t%s\n' transdangle main2.md >> "$INDEX"

OUT=$(run_path "$TEST_DIR/transdangle.txt")
assert_contains "the refusal is named in the injected block itself" "$OUT" "transclusion refused"
assert_contains "text around the refused spot still arrives" "$OUT" "before-marker"
assert_contains "and after it too" "$OUT" "after-marker"

# =============================================
# SECTION 3: containment -- traversal and absolute-path shapes are refused
# =============================================
echo ""
echo "=== SECTION 3: containment is the syntax, not a bolt-on check ==="

printf '%s\n' \
  "---" \
  "title: Traversal attempt" \
  "description: Tries to climb out with dot-dot." \
  "keywords: transdotdot" \
  "---" \
  "{{../../../../etc/passwd}}" > "$P/main3.md"
printf '%s\t%s\n' transdotdot main3.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transdotdot.txt")
assert_contains "a dot-dot path is refused" "$OUT" "transclusion refused"
assert_not_contains "and nothing from outside the tree leaks into context" "$OUT" "root:"

printf '%s\n' \
  "---" \
  "title: Absolute path attempt" \
  "description: Tries a leading slash." \
  "keywords: transabs" \
  "---" \
  "{{/etc/passwd}}" > "$P/main4.md"
printf '%s\t%s\n' transabs main4.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transabs.txt")
assert_contains "an absolute-shaped spec is refused" "$OUT" "transclusion refused"
assert_not_contains "and nothing from outside the tree leaks into context (2)" "$OUT" "root:"

# The positive control for this whole section: SECTION 1 already proves an honest
# dimension/layer/file.md spec is NOT caught by this same refusal path.
assert_contains "positive control: an honest spec from section 1 still works" \
  "$(run_path "$TEST_DIR/transonekw.txt")" "INCLUDED-BODY-MARKER"

# =============================================
# SECTION 4: "${{ ... }}" -- GitHub Actions syntax is left completely alone
# =============================================
echo ""
echo "=== SECTION 4: a dollar-prefixed brace pair is not this syntax ==="

printf '%s\n' \
  "---" \
  "title: Quotes a workflow" \
  "description: Carries \${{ github.sha }} the way vendored-oss.md does." \
  "keywords: transdollar" \
  "---" \
  "run: \${{ github.sha }}" \
  "{{paths/00-manual/inc.md}}" > "$P/main5.md"
printf '%s\t%s\n' transdollar main5.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transdollar.txt")
assert_contains "a dollar-prefixed pair survives untouched" "$OUT" '${{ github.sha }}'
assert_not_contains "it is never treated as a refused transclusion either" "$OUT" "github.sha}} [jit] transclusion refused"
# Positive control in the SAME fixture: the ordinary transclusion on the next line still
# fires, so the dollar guard is not just eating every "{{" on the line above it.
assert_contains "paired: an ordinary transclusion on another line still fires" "$OUT" "INCLUDED-BODY-MARKER"

# =============================================
# SECTION 5: a fenced code block is left alone regardless of what it quotes
# =============================================
echo ""
echo "=== SECTION 5: fenced code is never expanded, even without the dollar guard ==="

printf '%s\n' \
  "---" \
  "title: Fenced example" \
  "description: Shows the syntax without using it." \
  "keywords: transfence" \
  "---" \
  "Copy the line you just watched fire:" \
  '```' \
  "{{paths/00-manual/inc.md}}" \
  '```' \
  "{{paths/00-manual/inc.md}}" > "$P/main6.md"
printf '%s\t%s\n' transfence main6.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transfence.txt")
assert_contains "inside the fence, the braces survive as literal text" "$OUT" "{{paths/00-manual/inc.md}}"
assert_contains "positive control: the SAME spec outside the fence still expands" "$OUT" "INCLUDED-BODY-MARKER"

# =============================================
# SECTION 6: a cycle is refused rather than hanging or exhausting memory
# =============================================
echo ""
echo "=== SECTION 6: a -> b -> a is refused, not an infinite loop ==="

printf '%s\n' \
  "---" \
  "title: Cycle A" \
  "description: Includes B." \
  "keywords: transcyclea" \
  "---" \
  "A-MARKER {{paths/00-manual/cycleb.md}}" > "$P/cyclea.md"
printf '%s\n' \
  "---" \
  "title: Cycle B" \
  "description: Includes A right back." \
  "keywords: neverfired2" \
  "---" \
  "B-MARKER {{paths/00-manual/cyclea.md}}" > "$P/cycleb.md"
printf '%s\t%s\n' transcyclea cyclea.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transcyclea.txt")
assert_contains "the cycle is refused, named, in place" "$OUT" "transclusion refused"
assert_contains "the first hop still delivered its own text" "$OUT" "A-MARKER"
assert_contains "and the second hop too, before the cycle closed" "$OUT" "B-MARKER"

# =============================================
# SECTION 7: depth beyond the cap is refused rather than expanded forever
# =============================================
echo ""
echo "=== SECTION 7: nesting past the depth cap is refused ==="

printf '%s\n' "---" "title: D4" "description: Leaf." "keywords: neverfired3" "---" "DEPTH4-MARKER" > "$P/d4.md"
printf '%s\n' "---" "title: D3" "description: ." "keywords: neverfired4" "---" "{{paths/00-manual/d4.md}}" > "$P/d3.md"
printf '%s\n' "---" "title: D2" "description: ." "keywords: neverfired5" "---" "{{paths/00-manual/d3.md}}" > "$P/d2.md"
printf '%s\n' "---" "title: D1" "description: ." "keywords: neverfired6" "---" "{{paths/00-manual/d2.md}}" > "$P/d1.md"
printf '%s\n' "---" "title: D0" "description: The one that fires." "keywords: transdepth" "---" "{{paths/00-manual/d1.md}}" > "$P/d0.md"
printf '%s\t%s\n' transdepth d0.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transdepth.txt")
assert_contains "nesting stops with a named refusal rather than silently truncating" "$OUT" "transclusion refused"
assert_not_contains "the deepest leaf never actually arrives" "$OUT" "DEPTH4-MARKER"

# =============================================
# SECTION 8: too many transclusions in one fire is refused past the total cap
# =============================================
echo ""
echo "=== SECTION 8: a per-fire total budget bounds how many files one match can pull ==="

MANY=""
for i in $(seq 1 20); do
  printf '%s\n' "---" "title: Many $i" "description: leaf $i" "keywords: neverfiredmany$i" "---" "LEAF-$i-MARKER" > "$P/many$i.md"
  MANY="$MANY{{paths/00-manual/many$i.md}}"$'\n'
done
{
  printf '%s\n' "---" "title: ManyRoot" "description: Includes twenty leaves." "keywords: transmany" "---"
  printf '%s' "$MANY"
} > "$P/manyroot.md"
printf '%s\t%s\n' transmany manyroot.md >> "$INDEX"
OUT=$(run_path "$TEST_DIR/transmany.txt")
assert_contains "the budget is enforced: at least one leaf is refused as over budget" "$OUT" "transclusion refused: this fire already spliced in"
assert_contains "and at least one leaf before the cap still arrived" "$OUT" "LEAF-1-MARKER"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
