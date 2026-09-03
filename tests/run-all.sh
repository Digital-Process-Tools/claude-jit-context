#!/bin/bash
# Run every hook test suite. Exits non-zero if any suite fails.
# Usage: bash tests/run-all.sh

cd "$(dirname "$0")" || exit 1

# Three outcomes, never two. A suite that could not build its fixtures on this platform
# exits 2 -- the same "could not evaluate" jit-dry-run.sh uses -- and that is neither a
# pass nor a failure. Folding it into either one would print a sentence about coverage
# that nobody has: on Windows, `ln -s` copies instead of linking, so the containment
# suites cannot construct the attack they exist to refuse, and "All suites passed" would
# be the tool reporting an absence it produced itself.
FAILED=""
SKIPPED=""

# #304: time each suite, wall-clock, and report the times after the tally -- slowest
# first, plus a total. This never changes the exit code and never fails on a slow
# suite; it only reports.
#
# `date +%s.%N` is a GNU extension: BSD `date` on macOS prints a literal "N" for that
# field, which would silently report garbage seconds on one of the three CI legs with
# nothing asserting on it. bash's own $SECONDS avoids that split entirely -- it is a
# builtin on every bash this script runs under (macOS's bash 3.2, GNU bash on Linux,
# Git Bash's MSYS bash on Windows), needs no `date` call at all, and so has no GNU/BSD
# fallback to get wrong.
#
# TIMING_AVAILABLE is 0 only when this script is not actually running under bash (for
# example invoked as `sh tests/run-all.sh`), in which case $SECONDS is not guaranteed
# to exist or advance. That state prints as "n/a", never as "0s" -- a suite that took
# no measurable time and a suite nobody could time must not render identically.
# RUN_ALL_SIMULATE_NO_TIMING exists only so tests/test-run-all-timing.sh can exercise
# that path deterministically; it plays no role otherwise.
TIMING_AVAILABLE=1
if [ -z "${BASH_VERSION:-}" ] || [ -n "${RUN_ALL_SIMULATE_NO_TIMING:-}" ]; then
  TIMING_AVAILABLE=0
fi

NAMES=()
TIMES=()

for t in test-*.sh; do
  [ -f "$t" ] || continue
  echo ""
  echo "########## $t ##########"
  if [ "$TIMING_AVAILABLE" = 1 ]; then
    SECONDS=0
    bash "$t"
    rc=$?
    elapsed=$SECONDS
  else
    bash "$t"
    rc=$?
    elapsed=""
  fi
  NAMES+=("$t")
  TIMES+=("$elapsed")
  case "$rc" in
    0) : ;;
    2) SKIPPED="$SKIPPED $t" ;;
    *) FAILED="$FAILED $t" ;;
  esac
done

EXIT_CODE=0
echo ""
if [ -n "$FAILED" ]; then
  echo "FAILED suites:$FAILED"
  [ -n "$SKIPPED" ] && echo "SKIPPED suites (could not build their fixtures here):$SKIPPED"
  EXIT_CODE=1
elif [ -n "$SKIPPED" ]; then
  echo "SKIPPED suites (could not build their fixtures here):$SKIPPED"
  echo "Every other suite passed. This is NOT a clean result for the skipped ones —"
  echo "read their SKIPPED block for what went untested and why."
else
  echo "All suites passed."
fi

echo ""
echo "Timing (slowest first, wall-clock seconds):"
if [ "$TIMING_AVAILABLE" = 1 ]; then
  TOTAL=0
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    TOTAL=$((TOTAL + TIMES[i]))
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    printf '%s\t%s\n' "${TIMES[$i]}" "${NAMES[$i]}"
    i=$((i + 1))
  done | sort -t "$(printf '\t')" -k1,1rn | awk -F'\t' '{printf "  %5ss  %s\n", $1, $2}'
  echo "Total: ${TOTAL}s"
else
  echo "n/a -- \$SECONDS is a bash builtin and this run could not use it"
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    echo "    n/a  ${NAMES[$i]}"
    i=$((i + 1))
  done
fi

exit "$EXIT_CODE"
