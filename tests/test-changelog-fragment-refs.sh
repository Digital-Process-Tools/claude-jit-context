#!/bin/bash
# Nothing outside changelog.d/ may name a fragment that is currently on disk.
#
# The release CONSUMES fragments: .oss/assemble_changelog.py folds the prose
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

# jit-drive: none -- this suite scans tracked files for a filename; it defines no assertion helper at all
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

# Which tracked files name this fragment. -I skips binaries; the fragment itself and
# anything else inside changelog.d/ are excluded by the caller, not here.
#
# The left edge is anchored on a non-digit, and a plain -F substring scan is what made
# that necessary: every fragment name is a substring of the ones whose issue number it is
# a prefix of — `<n>.fixed.md` sits inside `<n>7.fixed.md` — so a document naming one of
# those was reported as naming the other. The name is matched rather than the
# `changelog.d/` path because #1231 upstream was a bare filename in a tuple of paths and
# never wrote the directory at all. Dots are escaped; a fragment name holds nothing else
# an ERE reads.
names_it() {
  local needle="$1"
  shift
  local re="${needle//./\.}"
  grep -lIE -- "(^|[^0-9])$re" "$@" 2>/dev/null
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

# A fragment name is a substring of every longer-numbered one sharing its prefix, and a
# -F scan reported that as a reference. It is not a cosmetic loss: the finding tells an
# author to remove a reference that is not in the file, which is unactionable, and the
# only way out of it is to renumber the issue.
#
# Both numbers here are far outside any issue this tracker will hand out, on purpose:
# this file is itself swept below, so a control written with a plausible number would
# flag the very fragment that number belongs to on the day it is filed.
printf 'a doc that names changelog.d/9999997.fixed.md by path\n' > "$WORK/prefix.md"
false_positive=$(names_it "999997.fixed.md" "$WORK/prefix.md")
if [ -n "$false_positive" ]; then
  fail "control: a name that is a prefix of a longer one is not a reference to it" \
       "999997.fixed.md was found in a document that names only 9999997.fixed.md"
else
  pass "control: a name that is a prefix of a longer one is not a reference to it"
fi

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
