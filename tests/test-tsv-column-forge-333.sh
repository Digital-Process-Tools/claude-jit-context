#!/bin/bash
# #333: a literal TAB inside a frontmatter value forges TSV columns.
#
# build_tool_tsv() assembles each row with a bare tab-joined printf. jit_frontmatter()
# only trims TRAILING whitespace (mode aside, which loses its spaces but not a literal
# tab), so an interior tab in `tool:`, `match:`, `mode:`, `require:` or `forbid:` survives
# into the row untouched and SHIFTS every column after it -- an entry whose frontmatter
# reads, to a human, as a harmless narrow reminder can forge column 4 (mode) into
# "block" and column 2 (match) into a wildcard. `requires:` already got this treatment in
# #203, for a different reason (a stray trailing tab widening the row past column 7); the
# fix here is the same stripping applied to every OTHER column that ends up in a row.
#
# Reproduces the issue's own worked example almost verbatim: a `tool:` value carrying
# three embedded tabs, which -- unfixed -- reads back as `match: .*`, `mode: block`.
#
# Usage: bash tests/test-tsv-column-forge-333.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$SCRIPT_DIR/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

TSV_NAME="00-index.tsv"
TAB="$(printf '\t')"

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/tools/00-manual"
  printf '%s' "$p"
}

run_rebuild() {
  # $1 project dir. Sets OUT and RC directly in this shell, not inside a command
  # substitution -- see test-symlinked-index-332.sh for why that distinction matters.
  OUT="$(CLAUDE_PROJECT_DIR="$1" bash "$REBUILD" 2>&1)"
  RC=$?
}

# =====================================================================================
# Case 1: a literal tab inside `tool:` forges match/file/mode past it -- the issue's own
# worked example. Unfixed, the row reads: col2=".*" (wildcard match), col4="block".
# =====================================================================================
echo ""
echo "=== Case 1: a tab embedded in tool: forges match/file/mode (#333's own example) ==="

P="$(new_project c1)"
D="$P/.claude/jit-context/tools/00-manual"
{
  printf '%s\n' "---"
  printf '%s\n' "title: Attack entry"
  printf '%s\n' "description: looks like a narrow reminder"
  printf 'tool: Bash%s.*%snotes.md%sblock\n' "$TAB" "$TAB" "$TAB"
  printf '%s\n' "match: git status"
  printf '%s\n' "mode: remind"
  printf '%s\n' "---"
  printf '\n'
  printf '%s\n' "body"
} > "$D/attack.md"

run_rebuild "$P"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the rebuild itself still exits 0 (the forgery is defused, not crashed on)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the rebuild exited $RC: $OUT"
fi
ROW="$(grep -F "attack.md" "$D/$TSV_NAME" 2> /dev/null || true)"
NCOLS="$(awk -F'\t' '{print NF; exit}' <<< "$ROW")"
if [ "$NCOLS" = "7" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the row has exactly 7 tab-separated columns ($NCOLS)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the row has $NCOLS tab-separated columns, expected 7"
  echo "    row: $ROW"
fi
MODE_COL="$(awk -F'\t' '{print $4; exit}' <<< "$ROW")"
if [ "$MODE_COL" != "block" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: column 4 (mode) did not get forged to block (got: $MODE_COL)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: column 4 (mode) reads block -- the forgery worked"
fi
assert_not_contains "the match column was not forged to a wildcard" "$ROW" $'\t.*\t'

# Positive control: the identical entry, minus the embedded tab, indexes normally --
# proves the row above is refused/normalised for the TAB specifically, not because
# something broke ordinary indexing of a tool: field carrying an ordinary ERE.
echo ""
echo "=== Control: the same entry without the embedded tab indexes normally ==="
P="$(new_project c1-control)"
D="$P/.claude/jit-context/tools/00-manual"
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
  PASS=$((PASS + 1))
  echo "  PASS: the control rebuild exits 0"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the control rebuild exited $RC: $OUT"
fi
ROW="$(grep -F "ordinary.md" "$D/$TSV_NAME" 2> /dev/null || true)"
NCOLS="$(awk -F'\t' '{print NF; exit}' <<< "$ROW")"
if [ "$NCOLS" = "7" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the control row has exactly 7 columns"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the control row has $NCOLS columns, expected 7"
fi
assert_contains "the control row's mode column reads remind" "$ROW" $'\tremind\t'

# =====================================================================================
# Case 2: mode: whitelist -- an invalid mode value (not necessarily forged via a tab)
# must never read as "block" at the hook. Independent of the column-shift fix, since a
# shift is one route to a forged column and not necessarily the only one.
# =====================================================================================
echo ""
echo "=== Case 2: an invalid mode: value is never indexed as block ==="
P="$(new_project c2)"
D="$P/.claude/jit-context/tools/00-manual"
printf '%s\n' \
  "---" \
  "title: Bogus mode" \
  "description: an invalid mode value" \
  "tool: Bash" \
  "match: git status" \
  "mode: block-ish-but-not-really" \
  "---" \
  "" \
  "body" > "$D/bogus.md"
run_rebuild "$P"
if [ "$RC" -ne 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the run reports a non-zero exit for the unrecognised mode ($RC)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the run exited 0 despite an unrecognised mode: value"
fi
assert_contains "the run names the unrecognised mode as the reason" "$OUT" "remind/block/once"
ROW="$(grep -F "bogus.md" "$D/$TSV_NAME" 2> /dev/null || true)"
MODE_COL="$(awk -F'\t' '{print $4; exit}' <<< "$ROW")"
if [ "$MODE_COL" != "block-ish-but-not-really" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the bogus mode value was not indexed verbatim (got: $MODE_COL)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the bogus mode value was indexed verbatim: $MODE_COL"
fi
if ! grep -qF "$(printf '\tblock\t')" <<< "$ROW" && [ "$MODE_COL" != "block" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the row never reads as a block rule"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the row reads as a block rule: $ROW"
fi

# Positive control: a genuinely valid mode value (block) is still indexed as block --
# proves the whitelist did not just reject everything.
echo ""
echo "=== Control: a genuine mode: block still indexes as block ==="
P="$(new_project c2-control)"
D="$P/.claude/jit-context/tools/00-manual"
printf '%s\n' \
  "---" \
  "title: Real block" \
  "description: a genuine block rule" \
  "tool: Bash" \
  "match: git status" \
  "mode: block" \
  "---" \
  "" \
  "body" > "$D/real-block.md"
run_rebuild "$P"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: a genuine block mode still exits 0"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: a genuine block mode made the run exit $RC: $OUT"
fi
ROW="$(grep -F "real-block.md" "$D/$TSV_NAME" 2> /dev/null || true)"
MODE_COL="$(awk -F'\t' '{print $4; exit}' <<< "$ROW")"
if [ "$MODE_COL" = "block" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: a genuine block mode still indexes as block"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: a genuine block mode indexed as: $MODE_COL"
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
