#!/bin/bash
# A comment in one file may not cite a line NUMBER in another.
#
# A line number is the most precise pointer available and the only one that is wrong the
# moment somebody inserts a line above it -- silently, because a rotted citation reads
# exactly like a live one. The reader follows it, lands on a plausible-looking comment,
# and believes it. That is this repository own defect class pointed at its own source.
#
# Counted on merged main at 98386f1, outside the assembled changelog: nine citations of
# this shape existed. Six pointed at the wrong thing, one had drifted off the block it
# named, two were still right. #191 names three of the six; this sweep found the other
# three. #185 added one of them three hours before #190 moved it. Nothing here is a
# hypothetical rot rate.
#
# WHAT REPLACES A LINE NUMBER. A function name, a distinctive literal, or an issue
# number. All three are greppable, all three survive an insertion above them, and the
# issue number additionally says WHY rather than WHERE. The trade is real -- none of them
# is as precise as a line -- and it is taken knowingly: a slightly vaguer pointer that
# stays true beats an exact one that quietly stops being.
#
# SAME-FILE citations are in scope too. They rot at the same rate; there are zero of them
# in the tree today, so covering them costs nothing and closes the shape rather than half
# of it.
#
# WHAT IS ENFORCED, AND WHAT IS ONLY REPORTED. Three outcomes, not two:
#
#   ENFORCED   tracked scripts and tests shell files -- a hit here fails this suite.
#   ADVISORY   every other tracked file except the changelog -- a hit is PRINTED, in
#              full, and does not fail. One instance lives in an entry held by another
#              branch (#192) at the time #191 was implemented, and reddening a file this
#              change may not edit is how a check gets disabled in its first week.
#              Widening this to enforced is one awk pattern below, and #191 asks for it
#              once that branch lands.
#   NOT SWEPT  the assembled changelog. It is written by .oss/assemble_changelog.py and
#              never hand-edited, so a finding there is unactionable by construction.
#              Stated rather than silently skipped.
#
# THE FALSE-POSITIVE SURFACE, costed before the check was written rather than after.
# The needle is a TRACKED BASENAME followed by a colon and a digit. Measured over all 96
# tracked basenames and every tracked file in this repository: 10 hits, 10 of them real
# citations, 0 false. The shapes that were considered and do NOT match --
#
#   awk: cmd. line:3                 no basename before the colon
#   scripts/common.sh: line 7        bash diagnostic form, space before the number
#   In scripts/common.sh line 7:     shellcheck form
#   line 7 of scripts/common.sh      the recommended prose form, if a line must be said
#   mycommon.sh:7                    a longer basename is not a reference to a shorter one
#
# -- which leaves one honest residual: `grep -n` output quoted verbatim in a comment
# would match, and that is a line number in a citation position however it got there.
# The escape hatch is prose, not an allowlist: write "line 7 of scripts/common.sh". An
# allowlist would rot at exactly the rate the numbers do, which is the thing being fixed.
#
# Usage: bash tests/test-line-citations.sh

# jit-drive: none -- this suite scans tracked files for a text shape; it defines no assertion helper
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ADVISORY=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ $# -gt 1 ] && echo "    $2"; }

if ! command -v git >/dev/null 2>&1; then
  echo "SKIPPED: no git on PATH, so the set of tracked files cannot be established"
  echo "  The needle set IS the tracked basenames, and the swept set is the tracked files."
  echo "  Neither can be read off whatever happens to be in the working directory."
  exit 2
fi
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIPPED: $REPO is not a git working tree"
  exit 2
fi

WORK=$(mktemp -d) || { echo "SKIPPED: could not create a scratch directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- the needle ----------------------------------------------------------------------
#
# Every tracked basename, deduplicated, regex-quoted. Every character outside
# [A-Za-z0-9_-] is backslash-escaped rather than only the dot: a basename is whatever
# somebody committed, and one unescaped metacharacter would silently widen the sweep.
git -C "$REPO" ls-files -z > "$WORK/tracked0" || {
  echo "SKIPPED: git ls-files failed"; exit 2; }
tr '\0' '\n' < "$WORK/tracked0" > "$WORK/tracked"

SCANNED=$(awk 'END { print NR + 0 }' "$WORK/tracked")
if [ "$SCANNED" -lt 20 ]; then
  echo "SKIPPED: git ls-files reported only $SCANNED tracked file(s)"
  echo "  This repository has many more than that, so the list is wrong and a clean sweep"
  echo "  over it would mean nothing."
  exit 2
fi

sed 's#.*/##' "$WORK/tracked" | sed '/^$/d' | sort -u > "$WORK/basenames"
BASE_N=$(awk 'END { print NR + 0 }' "$WORK/basenames")
if [ "$BASE_N" -lt 10 ]; then
  echo "SKIPPED: only $BASE_N tracked basename(s) survived the split"
  exit 2
fi

ALT=$(sed 's/[^A-Za-z0-9_-]/\\&/g' "$WORK/basenames" | paste -sd'|' -)
# Left edge: not a name character, so a longer basename is not a reference to a shorter
# one. An optional slash-separated directory prefix is accepted, so a path-qualified
# citation and a bare-basename one are the same finding.
CITE_RE="(^|[^A-Za-z0-9_.-])([A-Za-z0-9_.-]+/)*($ALT):[0-9]"

cites_in() { grep -nIE -- "$CITE_RE" "$1" 2>/dev/null; }

# --- the controls, first -------------------------------------------------------------
#
# A sweep that found nothing because its needle was broken is indistinguishable from a
# clean tree, and this whole suite is one negative assertion. So both directions are
# driven against planted fixtures before a single real file is read.
#
# That covers the needle failing to COMPILE as well as it covers a wrong one. A basename
# holding a byte the quoting above cannot express would make `grep -E` exit 2 with an
# invalid expression on every file, and `cites_in` returns nothing on exactly the same
# path it returns nothing when the tree is clean. The control below is what tells those
# two apart, and it exits 1 rather than printing a sweep nobody performed.
#
# The planted text is composed with printf %s rather than written literally, because this
# file is itself in the ENFORCED set: a literal basename followed by a colon and a digit
# in this source would be a finding against this suite.
CTRL=$(sed -n 's#^scripts/\(pre-tool-hook\.sh\)$#\1#p' "$WORK/tracked")
[ -n "$CTRL" ] || CTRL=$(awk 'NR == 1 { print }' "$WORK/basenames")

printf '# see %s:127-144 for the truncation\n' "$CTRL" > "$WORK/planted.sh"
{
  printf '# see the truncation in %s, which is greppable\n' "$CTRL"
  printf '# awk: cmd. line:3\n'
  printf '# line 7 of scripts/common.sh\n'
  printf '# In scripts/common.sh line 7:\n'
  printf '# my%s:7 is a different file\n' "$CTRL"
} > "$WORK/clean.sh"

planted=$(cites_in "$WORK/planted.sh")
if [ -n "$planted" ]; then
  pass "control: a planted line-number citation is seen"
else
  fail "control: the planted citation was found NOWHERE -- every result below is vacuous" \
       "needle over $BASE_N basename(s) matched nothing in the planted fixture"
  echo ""
  echo "  Stopping here rather than printing a clean sweep nobody performed."
  exit 1
fi

clean=$(cites_in "$WORK/clean.sh")
if [ -n "$clean" ]; then
  fail "control: the recommended forms and a longer basename are NOT citations" \
       "$(printf '%s' "$clean" | tr '\n' ' ')"
else
  pass "control: the recommended forms and a longer basename are NOT citations"
fi

# --- the enforced sweep --------------------------------------------------------------
echo ""
echo "=== no tracked shell file under scripts or tests cites a line number ==="
awk '/^(scripts|tests)\/[^\/]*\.sh$/ { print }' "$WORK/tracked" > "$WORK/enforced"
ENF_N=$(awk 'END { print NR + 0 }' "$WORK/enforced")
if [ "$ENF_N" -lt 10 ]; then
  echo "SKIPPED: only $ENF_N enforced file(s) matched -- the list is wrong, and a clean"
  echo "  sweep over it would mean nothing."
  exit 2
fi
echo "  ($ENF_N file(s), needle over $BASE_N tracked basename(s))"

hits=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ -f "$REPO/$file" ] || continue
  found=$(cites_in "$REPO/$file")
  [ -n "$found" ] && hits="$hits$file: $found
"
done < "$WORK/enforced"

if [ -n "$hits" ]; then
  fail "a line-number citation is present in an enforced file"
  printf '%s\n' "$hits" > "$WORK/hits"
  while IFS= read -r line; do
    [ -n "$line" ] && echo "    $line"
  done < "$WORK/hits"
  echo "    Replace the number with something that survives an edit above it: a function"
  echo "    name, a distinctive literal, or the issue number. If a line genuinely must be"
  echo "    named, write it as prose -- line 7 of scripts/common.sh -- so it reads as the"
  echo "    approximation it is."
else
  pass "no enforced file cites a line number in any tracked file"
fi

# --- the advisory sweep --------------------------------------------------------------
echo ""
echo "=== everything else: reported, NOT enforced ==="
awk '$0 != "CHANGELOG.md" && $0 !~ /^(scripts|tests)\/[^\/]*\.sh$/ { print }' \
  "$WORK/tracked" > "$WORK/advisory"
ADV_N=$(awk 'END { print NR + 0 }' "$WORK/advisory")

adv=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ -f "$REPO/$file" ] || continue
  found=$(cites_in "$REPO/$file")
  [ -n "$found" ] && adv="$adv$file: $found
"
done < "$WORK/advisory"

if [ -n "$adv" ]; then
  ADVISORY=1
  echo "  NOT ENFORCED, and these are findings rather than noise:"
  printf '%s\n' "$adv" > "$WORK/adv"
  while IFS= read -r line; do
    [ -n "$line" ] && echo "    $line"
  done < "$WORK/adv"
  echo "  Prose outside scripts and tests is advisory only while #192 holds one of the"
  echo "  files it would flag. Fixing these is welcome; #191 asks for the flag to move"
  echo "  once that branch lands."
else
  echo "  Clean across $ADV_N file(s)."
fi

echo ""
echo "  NOT SWEPT: the assembled changelog -- written by .oss/assemble_changelog.py and"
echo "  never hand-edited, so a finding in it is unactionable by construction."

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
[ "$ADVISORY" -eq 1 ] && echo "  plus advisory findings above, which do not fail this suite"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
