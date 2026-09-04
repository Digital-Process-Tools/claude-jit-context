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

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
