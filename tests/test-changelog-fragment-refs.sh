#!/bin/bash
# Nothing outside changelog.d/ may name a fragment that is currently on disk.
#
# The release CONSUMES fragments: .github/scripts/assemble_changelog.py folds the prose
# into CHANGELOG.md and deletes the file. So a test, a doc example, a fixture or a
# jit-context entry keyed to `changelog.d/<n>.<section>.md` is green for exactly the
# window between the PR that adds it and the next tag, and red on that tag and every tag
# after — and the window is invisible from inside that PR, because the file is there the
# whole time its CI runs.
#
# That shipped four times upstream in `claude-supertool`: #941 reddened five legs on
# v0.26.0, #953 thirteen of twenty on v0.27.0, and #1231 thirteen of twenty-two on
# v0.33.0. That last one was not an assertion at all — just a filename in a tuple of
# paths a test swept — which is why "do not assert a fragment exists" was too narrow a
# rule (#1293) and why this scans for the NAME rather than for an assertion shape.
#
# Naming an ALREADY CONSUMED fragment is fine and expected: `changelog.d/README.md`'s own
# examples are of that kind. Nothing the next tag deletes is called that.
#
# This is the bash port of upstream's tests/test_changelog_findable_1293.py. Its sibling
# — assert_change_is_findable() and the meta-test that parses the suite for its shape —
# is NOT ported: it backs a per-change convention this repository does not have, and a
# harness for an assertion nobody writes is coverage of nothing.
#
# Usage: bash tests/test-changelog-fragment-refs.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ $# -gt 1 ] && echo "    $2"; }

if ! command -v git >/dev/null 2>&1; then
  echo "SKIPPED: no git on PATH, so the set of tracked files cannot be established"
  echo "  Scanning the working tree instead would sweep build output and ignored files,"
  echo "  and a rule about what is COMMITTED cannot be read off what happens to be there."
  exit 2
fi
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIPPED: $REPO is not a git working tree"
  exit 2
fi

# Which tracked files name this string. -I skips binaries; the fragment itself and
# anything else inside changelog.d/ are excluded by the caller, not here.
names_it() {
  local needle="$1"
  shift
  grep -lIF -- "$needle" "$@" 2>/dev/null
}

# --- the control, first --------------------------------------------------------------
#
# A scan that found nothing because it was looking in the wrong place, or with a broken
# needle, is indistinguishable from a clean tree. So plant the exact shape being
# prohibited in a scratch file and require the scanner to see it.
WORK=$(mktemp -d) || { echo "SKIPPED: could not create a scratch directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

printf 'a doc that names changelog.d/999.fixed.md by path\n' > "$WORK/planted.md"
printf 'a doc that names nothing of the kind\n' > "$WORK/clean.md"
control=$(names_it "999.fixed.md" "$WORK/planted.md" "$WORK/clean.md")
case "$control" in
  *planted.md*)
    case "$control" in
      *clean.md*) fail "control: the scan flagged a file that names no fragment" "$control" ;;
      *)          pass "control: the scan sees a planted reference and only that file" ;;
    esac ;;
  *) fail "control: the scan found the planted reference nowhere — every result below is vacuous" \
          "got: ${control:-<nothing>}"
     echo ""
     echo "  Stopping here rather than printing a clean sweep nobody performed."
     exit 1 ;;
esac

# --- the real tree -------------------------------------------------------------------
FRAGMENTS=""
for path in "$REPO"/changelog.d/*.md; do
  [ -f "$path" ] || continue
  base="${path##*/}"
  [ "$base" = "README.md" ] && continue
  FRAGMENTS="$FRAGMENTS$base
"
done

COUNT=$(printf '%s' "$FRAGMENTS" | awk 'NF { n++ } END { print n + 0 }')
if [ "$COUNT" -eq 0 ]; then
  echo ""
  echo "  changelog.d/ holds no fragments right now — this is what the tree looks like"
  echo "  immediately after a release. There is nothing for the rule to be about, and"
  echo "  that is stated rather than reported as a clean sweep."
  echo ""
  echo "========================"
  echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
  echo "========================"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# Every tracked file except changelog.d/ itself. A fragment naming its own filename is
# not a thing that happens, and the directory's README documents the convention.
TRACKED="$WORK/tracked"
( cd "$REPO" && git ls-files -z ) > "$WORK/tracked0" || {
  echo "SKIPPED: git ls-files failed"; exit 2; }
( cd "$REPO" && tr '\0' '\n' < "$WORK/tracked0" ) \
  | awk '$0 !~ /^changelog\.d\// { print }' > "$TRACKED"

SCANNED=$(awk 'END { print NR + 0 }' "$TRACKED")
if [ "$SCANNED" -lt 20 ]; then
  echo "SKIPPED: git ls-files reported only $SCANNED file(s) outside changelog.d/"
  echo "  This repository has many more than that, so the list is wrong and a clean"
  echo "  sweep over it would mean nothing."
  exit 2
fi

echo "=== no tracked file names a fragment that is still on disk ==="
echo "  ($COUNT fragment(s), $SCANNED tracked file(s) scanned)"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  hits=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$REPO/$file" ] || continue
    found=$(names_it "$name" "$REPO/$file")
    [ -n "$found" ] && hits="$hits$file
"
  done < "$TRACKED"
  if [ -n "$hits" ]; then
    fail "changelog.d/$name is named by a tracked file outside changelog.d/" \
         "$(printf '%s' "$hits" | tr '\n' ' ')"
    echo "    The next release deletes that file. Point at CHANGELOG.md instead, where"
    echo "    this fragment's prose lands and stays."
  else
    pass "changelog.d/$name is named nowhere else"
  fi
done <<EOF
$FRAGMENTS
EOF

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
