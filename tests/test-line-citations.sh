#!/bin/bash
# A comment in one file may not cite a line NUMBER in another.
#
# A line number is the most precise pointer available and the only one that is wrong the
# moment somebody inserts a line above it -- silently, because a rotted citation reads
# exactly like a live one. The reader follows it, lands on a plausible-looking comment,
# and believes it. That is this repository own defect class pointed at its own source.
#
# Counted on merged main at 5b46095, outside the assembled changelog: ELEVEN citations of
# this shape existed. Seven pointed at the wrong thing, one had drifted off the block it
# named, three were still right. #191 names three of the seven; this sweep found the rest.
#
# The rot rate is measured, not asserted, and the measurement got sharper while this
# branch was open. It was nine citations at 98386f1, the commit this branch was cut from.
# #194 then merged and added TWO more -- both to this directory, in a file this branch
# does not touch -- and one of the two was already wrong on the day it was written, its
# line number landing three lines past the sentence it names. The interval between the
# branch point and the rebase was hours. Earlier, #185 added one three hours before #190
# moved it. That is the whole argument for a check rather than a cleanup: the citations
# this sweep first went red on were not the ones it was written for.
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
#   ENFORCED   tracked scripts and tests shell files, AND every tracked markdown file
#              outside the two exclusions below -- a hit here fails this suite.
#   ADVISORY   everything else tracked: the generated indexes, json, yml, and the
#              vendored .oss/ tree -- a hit is PRINTED, in full, and does not fail.
#              Two different reasons, both of them "the fix does not belong in the file
#              the finding names": 00-index.tsv is written by rebuild-tsv.sh, so a
#              finding there is fixed in the ENTRY; .oss/ is vendored and rewritten by
#              every `/oss:scaffold --apply`, so a fix there is lost on the next run.
#              Reported rather than not swept, because seeing it still costs nothing.
#   NOT SWEPT  the assembled changelog. It is written by .oss/assemble_changelog.py and
#              never hand-edited, so a finding there is unactionable by construction.
#              Stated rather than silently skipped.
#
# MARKDOWN MOVED FROM ADVISORY TO ENFORCED IN #198, and the scope of that move was the
# open question rather than the move itself. It is every markdown file, not the
# .claude/jit-context/ entries alone. The rule CLAUDE.md states is unconditional, so
# enforcing it on one directory while merely REPORTING it on every other markdown file
# in the tree rebuilds the half-closed shape one level in; and examples/ and templates/ are
# the shape a stranger copies into their own repo, which makes a rotted citation there
# worse than one in a dogfood entry rather than better. What it binds is this
# repository's contributor path only. The plugin manifest carries no file list, so an
# installed plugin cache does hold a copy of this directory -- but nothing there ever
# RUNS it: Claude Code runs hooks, not suites, and run-all.sh is invoked by CI and by
# whoever is editing this repo. The population this widening can red is exactly the
# population the shell half already reds. The advisory half was advisory because its one
# finding lived in an entry held by PR #192; that reason was spent when #192 landed,
# and the finding itself is fixed in the same commit as this widening.
#
# THE FALSE-POSITIVE SURFACE, costed before the check was written rather than after.
# The needle is a TRACKED BASENAME followed by a colon and a digit. Measured twice: on
# 98386f1 (96 basenames, 10 hits, 0 false) and again on 5b46095 after the rebase (98
# basenames, 12 hits, 0 false). Every hit both times was a real citation.
#
# Those counts are pinned to a commit rather than restated as a present-tense fact about
# the tree, because both grow with every file added and a number nobody re-measures is
# the shape this suite exists to refuse. The re-measure is the point of the pin: the
# first pin was two commits stale within a day, and it said so instead of reading true.
# The counts the sweep prints when it runs are the live ones.
#
# The shapes that were considered and do NOT match --
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

# Every "could not build the fixtures here" floor below exits 2, which run-all.sh maps
# to SKIPPED rather than FAILED or passed -- correctly, for a floor that fires before
# any control has run. But several floors in this script fire AFTER a control already
# ran: the selector control before the enforced-sweep floor, and the enforced sweep
# itself before the advisory-sweep floor. Exiting 2 at that point discards a recorded
# failure -- `$FAIL` is only read at the very last line of this script, and every exit
# between a `fail` call and that line leaves before the exit code is computed, so a
# control that ran, failed, and printed its failure could still end the run green
# (#201). skip_or_fail is the one place that decides between the two: if a failure was
# already recorded, it exits 1 (this run failed) instead of 2 (this run could not be
# evaluated) so `$FAIL` is never silently thrown away by a floor that runs after it.
skip_or_fail() {
  if [ "$FAIL" -gt 0 ]; then
    echo "  ($FAIL control failure(s) recorded above take priority over this skip.)"
    exit 1
  fi
  exit 2
}

if ! command -v git >/dev/null 2>&1; then
  echo "SKIPPED: no git on PATH, so the set of tracked files cannot be established"
  echo "  The needle set IS the tracked basenames, and the swept set is the tracked files."
  echo "  Neither can be read off whatever happens to be in the working directory."
  skip_or_fail
fi
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIPPED: $REPO is not a git working tree"
  skip_or_fail
fi

WORK=$(mktemp -d) || { echo "SKIPPED: could not create a scratch directory"; skip_or_fail; }
trap 'rm -rf "$WORK"' EXIT

# --- the needle ----------------------------------------------------------------------
#
# Every tracked basename, deduplicated, regex-quoted. Every character outside
# [A-Za-z0-9_-] is backslash-escaped rather than only the dot: a basename is whatever
# somebody committed, and one unescaped metacharacter would silently widen the sweep.
git -C "$REPO" ls-files -z > "$WORK/tracked0" || {
  echo "SKIPPED: git ls-files failed"; skip_or_fail; }
tr '\0' '\n' < "$WORK/tracked0" > "$WORK/tracked"

SCANNED=$(awk 'END { print NR + 0 }' "$WORK/tracked")
if [ "$SCANNED" -lt 20 ]; then
  echo "SKIPPED: git ls-files reported only $SCANNED tracked file(s)"
  echo "  This repository has many more than that, so the list is wrong and a clean sweep"
  echo "  over it would mean nothing."
  skip_or_fail
fi

sed 's#.*/##' "$WORK/tracked" | sed '/^$/d' | sort -u > "$WORK/basenames"
BASE_N=$(awk 'END { print NR + 0 }' "$WORK/basenames")
if [ "$BASE_N" -lt 10 ]; then
  echo "SKIPPED: only $BASE_N tracked basename(s) survived the split"
  skip_or_fail
fi

ALT=$(sed 's/[^A-Za-z0-9_-]/\\&/g' "$WORK/basenames" | paste -sd'|' -)
# Left edge: not a name character, so a longer basename is not a reference to a shorter
# one. An optional slash-separated directory prefix is accepted, so a path-qualified
# citation and a bare-basename one are the same finding.
CITE_RE="(^|[^A-Za-z0-9_.-])([A-Za-z0-9_.-]+/)*($ALT):[0-9]"

cites_in() { grep -nIE -- "$CITE_RE" "$1" 2>/dev/null; }

# Distinguishes grep's own three outcomes -- 0 (a citation was found), 1 (no citation,
# a genuinely clean read), 2+ (the file could not be read at all, an unreadable file
# among the causes) -- because `cites_in` on its own only hands back stdout, and stdout
# is empty in BOTH the "clean" and the "could not read it" cases. $RC is grep's raw
# exit status, captured immediately after the command substitution so nothing runs
# between the two and clobbers it. One helper, called at both of the sites that sweep
# real tracked files (the enforced and the advisory loops below), so the exit-status
# discipline lives in one place rather than two copies that can drift apart.
read_citations() {
  CITES=$(cites_in "$1")
  RC=$?
}

# --- the bucket selectors ------------------------------------------------------------
#
# ONE definition of each, read by the two sweeps AND by the control that proves them, so
# a selector cannot drift from the thing that demonstrates it works. `[.]` and not `\.`
# because these travel through `awk -v`, which processes escape sequences in the VALUE:
# `\.` is an undefined escape there and implementations disagree about what it becomes.
#
# `.*` and not `[^/]*` in the shell arm: a script that lands in a subdirectory one day
# would otherwise fall silently into ADVISORY and stay there, which is the ENFORCED
# label understating its own reach.
NOT_SWEPT_RE='^CHANGELOG[.]md$'
VENDORED_RE='^[.]oss/'
# The markdown arm is the whole of #198, and it is deliberately not `.claude/jit-context/`
# only. The rule CLAUDE.md states is unconditional -- never cite a line number in another
# file -- so enforcing it on one directory and merely REPORTING it on every other
# markdown file in the tree rebuilds the shape #198 was filed to close, one level in.
# `examples/` and `templates/` are the shape a stranger copies into their own repo, which
# makes a rotted citation there worse than one in a dogfood entry rather than better.
#
# What binds is this repository's contributor path only -- an installed plugin cache
# holds a copy of this directory but never runs it. Measured false positives across the
# whole markdown surface: zero, three times -- 98386f1, 5b46095, and f3a3228, where the
# one hit was the real citation this change fixes.
#
# Non-markdown stays ADVISORY rather than being swept in with it: `00-index.tsv` is
# generated by rebuild-tsv.sh, so a finding there is fixed in the entry and failing on
# the file would name the wrong place; json and yml are not prose. That keeps the
# advisory bucket a live third state with real files in it rather than a branch that
# can no longer fire.
ENFORCED_RE='^(scripts|tests)/.*[.]sh$|[.]md$'

# Exactly one bucket per path, and the order of the tests is the precedence.
BUCKET_AWK='{ b = ($0 ~ ns) ? "not-swept" : (($0 ~ vend) ? "advisory" : (($0 ~ enf) ? "enforced" : "advisory")) }'

# Reads paths on stdin, prints the ones in bucket $1.
in_bucket() {
  awk -v want="$1" -v enf="$ENFORCED_RE" -v ns="$NOT_SWEPT_RE" -v vend="$VENDORED_RE" \
    "$BUCKET_AWK"' b == want { print }'
}

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
# The dir-prefix branch of the needle gets its own control. A bare basename and a
# path-qualified one are meant to be the same finding, and without this the branch that
# accepts `scripts/` in front of the name is never driven -- the enforced set happens to
# hold only bare-basename citations, so a broken prefix branch would read as clean.
printf '# see %s:7 for this\n' "scripts/$CTRL" > "$WORK/planted-path.sh"
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

planted_path=$(cites_in "$WORK/planted-path.sh")
if [ -n "$planted_path" ]; then
  pass "control: a path-qualified citation is seen too"
else
  fail "control: the path-qualified citation was found NOWHERE" \
       "the dir-prefix branch of the needle is dead, and no enforced file exercises it"
fi

clean=$(cites_in "$WORK/clean.sh")
if [ -n "$clean" ]; then
  fail "control: the recommended forms and a longer basename are NOT citations" \
       "$(printf '%s' "$clean" | tr '\n' ' ')"
else
  pass "control: the recommended forms and a longer basename are NOT citations"
fi

# --- the control on UNREADABLE FILES --------------------------------------------------
#
# A tracked file that exists but cannot be read -- permission denied, or a gitlink/path
# that vanished between `git ls-files` and this loop -- must not be mistaken for a clean
# sweep: `grep` exits 2 for a read failure and 1 for "no match", and stdout is empty
# either way. `chmod 000` cannot be driven here honestly: it is a no-op on Windows and
# defeated by root on some CI images, so it would be green on two of three legs while
# claiming to cover all three -- the exact trap #200 was filed to name. A path that is
# fed straight to `read_citations` without existing on disk provokes the SAME grep exit
# 2 everywhere: no platform, no root, no CI image changes what `grep` does when the path
# it was handed is not there.
read_citations "$WORK/does-not-exist-$$"
if [ "$RC" -eq 1 ]; then
  fail "control: a read failure is reported as a CLEAN sweep, not as unreadable" \
       "grep exit 1 (no match) and grep exit 2+ (could not read it) must not collapse"
elif [ "$RC" -ge 2 ]; then
  pass "control: a read failure is distinguished from a clean sweep (grep exit $RC)"
else
  fail "control: reading a nonexistent path unexpectedly reported a citation" \
       "grep exit $RC, expected 2 or more"
fi

# --- the control on the SELECTORS ----------------------------------------------------
#
# The three controls above prove the NEEDLE sees a citation. None of them proves that a
# file lands in the bucket whose label claims it, and that is the half #198 moved. A
# markdown file quietly classified ADVISORY would print its findings and pass forever,
# which is exactly the half-closed state #198 exists to end -- and the tree cannot
# demonstrate the difference, because a correct sweep and a mis-bucketed one both come
# back green once the one real finding is fixed. So the selectors are driven against
# planted paths, not against today's tree.
#
# Positive and negative cases sit in the SAME table on purpose. A classifier that
# returned nothing, or the empty string for every input, would satisfy every "must NOT
# be enforced" row on its own; the `enforced` rows are what refuse that.
sel_fail=0
sel_n=0
while IFS=' ' read -r want path; do
  [ -n "$want" ] || continue
  sel_n=$((sel_n + 1))
  got=$(printf '%s\n' "$path" | awk -v enf="$ENFORCED_RE" -v ns="$NOT_SWEPT_RE" \
        -v vend="$VENDORED_RE" "$BUCKET_AWK"' { print b }')
  if [ "$got" != "$want" ]; then
    sel_fail=$((sel_fail + 1))
    echo "    $path -> ${got:-<nothing>}, expected $want"
  fi
done <<'CASES'
enforced scripts/pre-tool-hook.sh
enforced tests/test-line-citations.sh
enforced .claude/jit-context/paths/00-manual/tooling.md
enforced .claude/jit-context/tools/00-manual/no-hand-editing-the-index.md
enforced examples/jit-context/tools/00-manual/git-push.example.md
enforced templates/jit-context/vocabulary/00-manual/writing-rules.md
enforced changelog.d/README.md
enforced README.md
enforced CLAUDE.md
not-swept CHANGELOG.md
advisory .oss/README.md
advisory .oss/assemble_changelog.py
advisory .claude/jit-context/paths/00-manual/00-index.tsv
advisory .github/workflows/ci.yml
advisory .claude-plugin/plugin.json
CASES

# A table that failed to be read at all would leave sel_fail at 0 and pass. The floor is
# the same third state both file sets get: nothing checked is not a clean check.
if [ "$sel_n" -lt 10 ]; then
  fail "control: only $sel_n selector case(s) were read -- the table did not arrive" \
       "every bucket claim below rests on a control that did not run"
elif [ "$sel_fail" -eq 0 ]; then
  pass "control: all $sel_n sample paths land in the bucket their label claims"
else
  fail "control: $sel_fail of $sel_n sample path(s) landed in the wrong bucket" \
       "the labels below would describe coverage this sweep does not have"
fi

# --- the enforced sweep --------------------------------------------------------------
echo ""
echo "=== no enforced file cites a line number ==="
in_bucket enforced < "$WORK/tracked" > "$WORK/enforced"
ENF_N=$(awk 'END { print NR + 0 }' "$WORK/enforced")
if [ "$ENF_N" -lt 10 ]; then
  echo "SKIPPED: only $ENF_N enforced file(s) matched -- the list is wrong, and a clean"
  echo "  sweep over it would mean nothing."
  skip_or_fail
fi
echo "  ($ENF_N file(s), needle over $BASE_N tracked basename(s))"

# A tracked path that is not a readable file is COUNTED, not skipped in silence: a
# gitlink, a path deleted between `ls-files` and this loop, OR a file that exists but
# cannot be opened (permission denied) would otherwise leave the header above claiming
# a file count the sweep never reached -- and the permission case is the one `-f` alone
# cannot see, because `-f` is true for a file mode 000 forbids reading. `read_citations`
# is what tells "no citation" (grep exit 1) apart from "could not be read" (grep exit
# 2+), so RC is checked rather than only testing whether $CITES came back non-empty.
hits=""
unread=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if [ ! -f "$REPO/$file" ]; then unread=$((unread + 1)); continue; fi
  read_citations "$REPO/$file"
  case "$RC" in
    0) hits="$hits$file: $CITES
" ;;
    1) : ;;
    *) unread=$((unread + 1)) ;;
  esac
done < "$WORK/enforced"
if [ "$unread" -gt 0 ]; then
  fail "$unread of $ENF_N enforced path(s) were not readable files -- that many went unswept"
fi

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
echo "=== generated and vendored files: reported, NOT enforced ==="
in_bucket advisory < "$WORK/tracked" > "$WORK/advisory"
ADV_N=$(awk 'END { print NR + 0 }' "$WORK/advisory")
# The same floor the enforced set gets, for the same reason. `Clean across 0 file(s)` and
# a genuinely clean tree are one sentence apart in the log and IDENTICAL in the exit code,
# and run-all.sh reads only the exit code. A selector that broke would report coverage
# nobody has, which is the defect this repository is named after.
if [ "$ADV_N" -lt 10 ]; then
  echo "SKIPPED: only $ADV_N advisory file(s) matched -- the selector is wrong, and a"
  echo "  clean report over it would mean nothing."
  skip_or_fail
fi

adv=""
adv_unread=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if [ ! -f "$REPO/$file" ]; then adv_unread=$((adv_unread + 1)); continue; fi
  read_citations "$REPO/$file"
  case "$RC" in
    0) adv="$adv$file: $CITES
" ;;
    1) : ;;
    *) adv_unread=$((adv_unread + 1)) ;;
  esac
done < "$WORK/advisory"

if [ -n "$adv" ]; then
  ADVISORY=1
  echo "  NOT ENFORCED, and these are findings rather than noise:"
  printf '%s\n' "$adv" > "$WORK/adv"
  while IFS= read -r line; do
    [ -n "$line" ] && echo "    $line"
  done < "$WORK/adv"
  echo "  Generated and vendored files are REPORTED rather than enforced, because the fix"
  echo "  does not belong in the file the finding names: an index is rewritten by"
  echo "  rebuild-tsv.sh from the entry, and .oss/ is rewritten by /oss:scaffold --apply."
  echo "  Fix it at the source. This half is NOT a bucket for prose -- since #198 every"
  echo "  tracked markdown file except the assembled changelog is enforced."
else
  echo "  Clean across $((ADV_N - adv_unread)) file(s)."
fi
if [ "$adv_unread" -gt 0 ]; then
  echo "  $adv_unread of $ADV_N advisory path(s) were not readable files and went unswept."
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
