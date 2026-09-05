#!/bin/bash
# Run every hook test suite. Exits non-zero if any suite fails.
#
# Usage: bash tests/run-all.sh [--shard N/M]
#
# --shard runs only every Mth suite starting at N, so M CI legs can split the wall clock
# between them. It makes nothing faster: the same suites run and the same minutes are
# billed. What it splits is the CLOCK, and only on the leg where that matters -- Windows
# ran this list sequentially in 1,305s against Linux's 162s for the same commit, because
# a process launch there costs roughly ten times what it costs elsewhere.
#
# The whole risk is that the partition stops being one: a suite in no shard runs NOWHERE,
# and a leg that ran 30 of 45 suites is green exactly the way a leg that ran all 45 is.
# tests/test-run-all-shard.sh asserts the union of every shard is the complete list and
# that nothing appears twice, which is the only assertion here that would catch that.
#
# Round-robin over the glob rather than N contiguous blocks, and that is what balances it:
# the glob is C-collated, so the seven suites that dominate the Windows clock
# (test-assertion-helpers, test-changelog-fragment-refs, test-dogfood-entries,
# test-jit-dry-run, test-layer-enumeration, test-pre-tool-hook, test-silent-drops) fall in
# alphabetical order and round-robin deals them one per shard. Contiguous blocks would put
# the two heaviest in the same one. Measured off the windows-latest timing block, not
# assumed -- re-read it rather than trusting this sentence if the shape of the suite list
# changes.

SHARD_I=1
SHARD_N=1

shard_refuse() {
  echo "SKIPPED: $1" >&2
  echo "         Nothing was run. Usage: bash tests/run-all.sh [--shard N/M]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --shard)
      # `[ $# -ge 2 ]` before the shift, for the reason jit-dry-run.sh's need_value()
      # spells out: `${2:-}` supplies an empty string and then `shift 2` fails, $1 never
      # advances, and this loop spins forever on a flag someone typed without a value.
      [ $# -ge 2 ] || shard_refuse "--shard needs a value of the form N/M"
      case "$2" in
        # Both halves digits, exactly one slash. A spec that does not parse is refused
        # rather than defaulted: a typo in a CI matrix expression would otherwise run the
        # FULL suite on every leg and read as merely slow.
        [0-9]*/[0-9]*)
          SHARD_I="${2%%/*}"
          SHARD_N="${2##*/}"
          case "$SHARD_I$SHARD_N" in *[!0-9]*) shard_refuse "--shard '$2' is not N/M" ;; esac
          # Round-trip the two halves against what was typed. `%%/*` and `##*/` take the
          # first and last field and IGNORE anything between them, so `1/4/2` parses as
          # 1 of 2 -- a spec nobody wrote, silently honoured, running a quarter of the
          # suites on a leg that thinks it ran half.
          [ "$SHARD_I/$SHARD_N" = "$2" ] || shard_refuse "--shard '$2' is not N/M"
          ;;
        *) shard_refuse "--shard '$2' is not N/M" ;;
      esac
      [ "$SHARD_N" -ge 1 ] 2> /dev/null || shard_refuse "--shard '$2': M must be 1 or more"
      [ "$SHARD_I" -ge 1 ] 2> /dev/null || shard_refuse "--shard '$2': N must be 1 or more"
      [ "$SHARD_I" -le "$SHARD_N" ] || shard_refuse "--shard '$2': N must not exceed M"
      shift 2
      ;;
    *) shard_refuse "unknown flag: $1" ;;
  esac
done

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

# Counted over every suite the glob returns, before the shard filter, so SELECTED and
# AVAILABLE are two different numbers and the report can print both. A shard that selected
# nothing must read as that rather than as a run with no failures -- run-all.sh already
# renders a skip green, and a silently empty shard would be greener still.
SUITE_N=0
SELECTED=0

for t in test-*.sh; do
  [ -f "$t" ] || continue
  SUITE_N=$((SUITE_N + 1))
  # Round-robin, 1-based: suite k goes to shard ((k - 1) mod M) + 1. With M=1 this is
  # every suite, which is what makes the unsharded path the same code rather than a
  # branch around it.
  [ "$(((SUITE_N - 1) % SHARD_N + 1))" -eq "$SHARD_I" ] || continue
  SELECTED=$((SELECTED + 1))
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
if [ "$SHARD_N" -gt 1 ]; then
  echo "shard $SHARD_I/$SHARD_N: ran $SELECTED of $SUITE_N suite(s) here."
  echo "The other $((SUITE_N - SELECTED)) run on the other shards -- this leg's verdict is about these $SELECTED."
fi
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
