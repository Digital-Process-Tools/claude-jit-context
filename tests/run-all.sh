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
for t in test-*.sh; do
  [ -f "$t" ] || continue
  echo ""
  echo "########## $t ##########"
  bash "$t"
  case "$?" in
    0) : ;;
    2) SKIPPED="$SKIPPED $t" ;;
    *) FAILED="$FAILED $t" ;;
  esac
done

echo ""
if [ -n "$FAILED" ]; then
  echo "FAILED suites:$FAILED"
  [ -n "$SKIPPED" ] && echo "SKIPPED suites (could not build their fixtures here):$SKIPPED"
  exit 1
fi
if [ -n "$SKIPPED" ]; then
  echo "SKIPPED suites (could not build their fixtures here):$SKIPPED"
  echo "Every other suite passed. This is NOT a clean result for the skipped ones —"
  echo "read their SKIPPED block for what went untested and why."
  exit 0
fi
echo "All suites passed."
