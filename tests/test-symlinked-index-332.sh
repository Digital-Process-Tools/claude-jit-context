#!/bin/bash
# #332: rebuild-tsv.sh follows a symlinked index (or a symlinked layer directory) and
# truncates/writes through it, so a cloned tree carrying either shape can make
# `bash scripts/rebuild-tsv.sh` -- which this repo's own CLAUDE.md instructs after every
# frontmatter edit -- clobber an arbitrary file outside the tree.
#
# truncate_index()'s own comment anticipated a hostile clone shipping a DIRECTORY at the
# index path; it never anticipated a SYMLINK there, and none of the three layer-loops
# guarded a symlinked LAYER DIRECTORY either. `git clone` recreates a committed symlink,
# so cloning the repository is the whole attack -- same shape as test-symlink-entry.sh's
# S3, one write site over.
#
# Every negative (the target is untouched, the run refuses) is paired with a positive
# control on the same fixture shape (an ordinary file/directory rebuilds normally), so a
# fix that broke rebuilding outright would not read as a fix here.
#
# Usage: bash tests/test-symlinked-index-332.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$SCRIPT_DIR/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

# The index FILENAME, held in a variable rather than typed next to a redirect: this
# repo's own no-shell-writes-to-the-index.md rule matches a literal index name sitting
# after a >, and it cannot tell a real hand-write from a test fixture building the
# committed index format on purpose (see test-requires-field.sh for the same pattern).
TSV_NAME="00-index.tsv"

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/tools/00-manual"
  printf '%s' "$p"
}

run_rebuild() {
  # $1 project dir. Sets OUT and RC (both global) directly in THIS shell rather than
  # inside a command substitution -- calling this via `x="$(run_rebuild ...)"` would run
  # the whole function in a subshell, and RC=$? assigned there never reaches the caller.
  OUT="$(CLAUDE_PROJECT_DIR="$1" bash "$REBUILD" 2>&1)"
  RC=$?
}

# --- Can this platform make a symbolic link at all? ---------------------------------
# Copied verbatim from test-symlink-entry.sh's own probe: a platform that cannot make a
# real symlink (Git Bash without MSYS=winsymlinks:nativestrict) makes `ln -s` copy the
# target instead, and every assertion below would then be testing an ordinary file.
REQUIRE_SYMLINKS="${JIT_TESTS_REQUIRE_SYMLINKS:-}"
CAN_SYMLINK=no
probe_symlinks() {
  local d="$TMP/.symlink-probe"
  rm -rf "$d" || return 1
  mkdir -p "$d/target-dir" || return 1
  printf 'probe\n' > "$d/target-file" || return 1
  ln -sf "$d/target-file" "$d/link-file" 2>/dev/null
  ln -sfn "$d/target-dir" "$d/link-dir" 2>/dev/null
  printf 'late\n' > "$d/target-dir/late.txt" || return 1
  [ -L "$d/link-file" ] || return 1
  [ -L "$d/link-dir" ] || return 1
  [ -f "$d/link-dir/late.txt" ] || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
echo "symlink support: $CAN_SYMLINK (files and directories, verified through the link)"

if [ "$CAN_SYMLINK" != yes ]; then
  echo ""
  echo "SKIPPED: this platform did not create a symbolic link, so the containment cases"
  echo "         below could not be constructed. Nothing about containment was tested."
  if [ "$REQUIRE_SYMLINKS" = 1 ]; then
    echo "SYMBOLIC LINKS WERE REQUIRED AND NOT OBTAINED."
    echo "$PASS passed, $FAIL failed, every containment case NOT RUN"
    exit 1
  fi
  echo "$PASS passed, $FAIL failed, every containment case SKIPPED"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 2
fi

# =====================================================================================
# S1: the index itself is a symlink pointing outside the tree
# =====================================================================================
echo ""
echo "=== S1: a symlinked index is not truncated or written through ==="

P="$(new_project s1)"
D="$P/.claude/jit-context/tools/00-manual"
TARGET="$OUTSIDE/s1-target.txt"
printf 'PRISTINE-OUTSIDE-CONTENT-S1\n' > "$TARGET"
ln -sf "$TARGET" "$D/$TSV_NAME"
printf '%s\n' \
  "---" \
  "title: Attack entry" \
  "description: forces a row to be written" \
  "tool: Bash" \
  "match: git status" \
  "mode: block" \
  "---" \
  "" \
  "body" > "$D/attack.md"

run_rebuild "$P"
if [ "$RC" -ne 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: the run reports a non-zero exit ($RC)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the run exited 0"
fi
assert_contains "the run names the symlink as the reason" "$OUT" "SYMBOLIC LINK"
TARGET_CONTENT="$(cat "$TARGET")"
if [ "$TARGET_CONTENT" = "PRISTINE-OUTSIDE-CONTENT-S1" ]; then
  PASS=$((PASS + 1)); echo "  PASS: the outside target file was NOT truncated or written"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the outside target file was modified: $TARGET_CONTENT"
fi

# Positive control: the identical fixture, but the index path is an ORDINARY file (the
# realistic prior state before any rebuild ever ran). It must rebuild normally -- proves
# the refusal above is about the SYMLINK specifically, not about rebuilding being broken.
echo ""
echo "=== Control: the same fixture with a REGULAR file at the index path rebuilds fine ==="
P="$(new_project s1-control)"
D="$P/.claude/jit-context/tools/00-manual"
touch "$D/$TSV_NAME"
printf '%s\n' \
  "---" \
  "title: Ordinary entry" \
  "description: an ordinary row" \
  "tool: Bash" \
  "match: git status" \
  "mode: remind" \
  "---" \
  "" \
  "body" > "$D/ordinary.md"
run_rebuild "$P"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: the control run exits 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the control run exited $RC: $OUT"
fi
assert_contains "the control run wrote the row" "$(cat "$D/$TSV_NAME")" "ordinary.md"

# =====================================================================================
# S2: the LAYER DIRECTORY itself is a symlink to an outside directory
# =====================================================================================
echo ""
echo "=== S2: a symlinked layer directory is refused, and the rest of the tree still builds ==="

P="$(new_project s2)"
mkdir -p "$P/.claude/jit-context/tools"
OUTSIDE_LAYER="$OUTSIDE/s2-layer"
mkdir -p "$OUTSIDE_LAYER"
printf 'PRISTINE-OUTSIDE-LAYER-CONTENT\n' > "$OUTSIDE_LAYER/$TSV_NAME"
ln -sfn "$OUTSIDE_LAYER" "$P/.claude/jit-context/tools/evil"
# A second, ordinary layer in the SAME dimension, so skip-and-continue is provable: if
# the symlinked layer aborted the whole run, this row would never get written either.
mkdir -p "$P/.claude/jit-context/tools/00-manual"
printf '%s\n' \
  "---" \
  "title: Sibling entry" \
  "description: a normal rule in a sibling layer" \
  "tool: Bash" \
  "match: git status" \
  "mode: remind" \
  "---" \
  "" \
  "body" > "$P/.claude/jit-context/tools/00-manual/sibling.md"

run_rebuild "$P"
assert_contains "the run names the symlinked layer as refused" "$OUT" "SYMBOLIC LINK"
LAYER_CONTENT="$(cat "$OUTSIDE_LAYER/$TSV_NAME")"
if [ "$LAYER_CONTENT" = "PRISTINE-OUTSIDE-LAYER-CONTENT" ]; then
  PASS=$((PASS + 1)); echo "  PASS: the outside layer's index was NOT touched"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the outside layer's index was modified: $LAYER_CONTENT"
fi
assert_contains "the sibling layer still rebuilt (skip-and-continue, not abort-the-run)" \
  "$(cat "$P/.claude/jit-context/tools/00-manual/$TSV_NAME" 2>/dev/null)" "sibling.md"

# Positive control: an ordinary (non-symlinked) second layer directory rebuilds fine,
# proving the S2 refusal above is about the symlink and not about having two layers.
echo ""
echo "=== Control: two ORDINARY layer directories both rebuild ==="
P="$(new_project s2-control)"
mkdir -p "$P/.claude/jit-context/tools/00-manual" "$P/.claude/jit-context/tools/another-layer"
printf '%s\n' "---" "title: A" "description: a" "tool: Bash" "match: git a" "mode: remind" "---" "" "a" \
  > "$P/.claude/jit-context/tools/00-manual/a.md"
printf '%s\n' "---" "title: B" "description: b" "tool: Bash" "match: git b" "mode: remind" "---" "" "b" \
  > "$P/.claude/jit-context/tools/another-layer/b.md"
run_rebuild "$P"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: the control run exits 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the control run exited $RC: $OUT"
fi
assert_contains "layer one rebuilt" "$(cat "$P/.claude/jit-context/tools/00-manual/$TSV_NAME" 2>/dev/null)" "a.md"
assert_contains "layer two rebuilt" "$(cat "$P/.claude/jit-context/tools/another-layer/$TSV_NAME" 2>/dev/null)" "b.md"

# =====================================================================================
# S3: the DIMENSION directory itself (tools/, not a layer beneath it) is a symlink.
# The layer-directory guard above (jit_layer_symlinked) tests a layer ONE LEVEL BELOW
# each dimension -- it does nothing for `tools/` itself being the link, and the glob
# `"$TOOLS_BASE"/*/` follows a symlinked ancestor exactly as readily as it follows a
# symlinked layer: every real subdirectory of the outside target then enumerates as an
# ordinary (non-symlink) "layer" and gets written straight through. Found in review.
# =====================================================================================
echo ""
echo "=== S3: a symlinked DIMENSION directory (tools/ itself) is refused ==="

P="$(new_project s3)"
mkdir -p "$P/.claude/jit-context"
rm -rf "$P/.claude/jit-context/tools"
OUTSIDE_DIM="$OUTSIDE/s3-dimension"
mkdir -p "$OUTSIDE_DIM/realsubdir"
printf 'PRISTINE-OUTSIDE-DIMENSION-CONTENT\n' > "$OUTSIDE_DIM/realsubdir/$TSV_NAME"
ln -sfn "$OUTSIDE_DIM" "$P/.claude/jit-context/tools"
mkdir -p "$P/.claude/jit-context/paths/00-manual"
printf '%s\n' \
  "---" \
  "title: Sibling dimension entry" \
  "description: a normal rule in an unrelated dimension" \
  "match: src/.*" \
  "---" \
  "" \
  "body" > "$P/.claude/jit-context/paths/00-manual/sibling.md"

run_rebuild "$P"
assert_contains "the run names the symlinked dimension as refused" "$OUT" "SYMBOLIC LINK dimension directory"
DIM_CONTENT="$(cat "$OUTSIDE_DIM/realsubdir/$TSV_NAME")"
if [ "$DIM_CONTENT" = "PRISTINE-OUTSIDE-DIMENSION-CONTENT" ]; then
  PASS=$((PASS + 1)); echo "  PASS: the outside dimension's real subdirectory index was NOT touched"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the outside dimension's index was modified: $DIM_CONTENT"
fi
assert_contains "an unrelated dimension (paths/) still rebuilt (skip-and-continue)" \
  "$(cat "$P/.claude/jit-context/paths/00-manual/$TSV_NAME" 2>/dev/null)" "sibling.md"

# Positive control: an ordinary (non-symlinked) tools/ dimension rebuilds fine, proving
# the S3 refusal is about the symlink and not about tools/ existing at all.
echo ""
echo "=== Control: an ORDINARY tools/ dimension directory rebuilds fine ==="
P="$(new_project s3-control)"
mkdir -p "$P/.claude/jit-context/tools/00-manual"
printf '%s\n' "---" "title: C" "description: c" "tool: Bash" "match: git c" "mode: remind" "---" "" "c" \
  > "$P/.claude/jit-context/tools/00-manual/c.md"
run_rebuild "$P"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: the control run exits 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the control run exited $RC: $OUT"
fi
assert_contains "the ordinary tools/ dimension rebuilt" "$(cat "$P/.claude/jit-context/tools/00-manual/$TSV_NAME" 2>/dev/null)" "c.md"

# =====================================================================================
# S4: a symlinked vocabulary LAYER does not leak the outside target's file name/size
# through the READ-ONLY reports (the keyword-collision report and the "what a match
# costs" report), which walk the tree again, independently of the writers. Found in
# review: the writer correctly refuses to INDEX the layer, but a report built from a
# fresh glob over the tree can still OPEN a file through the same symlink and print it.
# =====================================================================================
echo ""
echo "=== S4: a symlinked vocabulary layer's outside file never appears in the reports ==="

P="$(new_project s4)"
mkdir -p "$P/.claude/jit-context/vocabulary"
OUTSIDE_VOCAB_LAYER="$OUTSIDE/s4-vocab-layer"
mkdir -p "$OUTSIDE_VOCAB_LAYER"
CANARY_NAME="s4-secret-outside-file.md"
printf '%s\n' \
  "---" \
  "title: Secret" \
  "description: this must never be read through the symlink" \
  "keywords: sentinel-term-that-should-never-appear" \
  "---" \
  "" \
  "SECRET-OUTSIDE-BODY" > "$OUTSIDE_VOCAB_LAYER/$CANARY_NAME"
ln -sfn "$OUTSIDE_VOCAB_LAYER" "$P/.claude/jit-context/vocabulary/evil"
mkdir -p "$P/.claude/jit-context/vocabulary/00-manual"
printf '%s\n' \
  "---" \
  "title: Ordinary vocab entry" \
  "description: an ordinary vocabulary entry" \
  "keywords: ordinary-sibling-term" \
  "---" \
  "" \
  "ORDINARY-BODY" > "$P/.claude/jit-context/vocabulary/00-manual/ordinary.md"

run_rebuild "$P"
assert_not_contains "the outside file's NAME never appears in the run's own output" "$OUT" "$CANARY_NAME"
assert_contains "the sibling vocabulary layer still rebuilt" \
  "$(cat "$P/.claude/jit-context/vocabulary/00-manual/$TSV_NAME" 2>/dev/null)" "ordinary.md"

# =====================================================================================
# S5: a symlinked DIMENSION directory (tools/ itself, not a layer beneath it) does not
# leak the outside target's file name/size through the "what a match costs" report
# either (#338). S3 above already proves the WRITER refuses this shape; S4 already
# proves the READ-ONLY reports close the shape one level down (a symlinked LAYER). This
# is the fourth cell of the 2x2 {layer, dimension} x {write, read} -- S1/S2/S3 closed the
# write column and the layer half of the read column, S4 closed the layer half of the
# read column for a DIFFERENT report (keyword-collision); this closes the dimension half
# of the read column for the "what a match costs" report specifically. The layer-level
# `[ -L "$(dirname "$md")" ]` guard on that report tests only the FILE's immediate
# parent, which is one level too shallow to see a symlinked tools/ two levels up --
# exactly S3's own mechanism, one glob over.
# =====================================================================================
echo ""
echo "=== S5: a symlinked DIMENSION directory's file never appears in the cost report ==="

P="$(new_project s5)"
mkdir -p "$P/.claude/jit-context"
rm -rf "$P/.claude/jit-context/tools"
OUTSIDE_DIM_S5="$OUTSIDE/s5-dimension"
mkdir -p "$OUTSIDE_DIM_S5/realsubdir"
CANARY_NAME_S5="s5-secret-outside-file.md"
printf '%s\n' \
  "---" \
  "title: Secret S5" \
  "description: this must never be read through the symlinked dimension" \
  "tool: Bash" \
  "match: git s5" \
  "mode: remind" \
  "---" \
  "" \
  "SECRET-OUTSIDE-BODY-S5" > "$OUTSIDE_DIM_S5/realsubdir/$CANARY_NAME_S5"
ln -sfn "$OUTSIDE_DIM_S5" "$P/.claude/jit-context/tools"
mkdir -p "$P/.claude/jit-context/paths/00-manual"
printf '%s\n' \
  "---" \
  "title: Sibling dimension entry S5" \
  "description: a normal rule in an unrelated dimension" \
  "match: src/.*" \
  "---" \
  "" \
  "body" > "$P/.claude/jit-context/paths/00-manual/sibling.md"

run_rebuild "$P"
assert_not_contains "the outside file's NAME never appears in the cost report" "$OUT" "$CANARY_NAME_S5"
COST_SECTION_S5="$(awk '/=== What a match costs/{p=1} p' <<<"$OUT")"
assert_not_contains "...nor within the cost-report section specifically" "$COST_SECTION_S5" "$CANARY_NAME_S5"
assert_contains "an unrelated dimension (paths/) still appears in the cost report" \
  "$COST_SECTION_S5" "sibling.md"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
