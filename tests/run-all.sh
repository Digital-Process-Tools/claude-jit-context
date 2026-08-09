#!/bin/bash
# Run every hook test suite. Exits non-zero if any suite fails.
# Usage: bash tests/run-all.sh

cd "$(dirname "$0")" || exit 1

FAILED=""
for t in test-*.sh; do
  [ -f "$t" ] || continue
  echo ""
  echo "########## $t ##########"
  if bash "$t"; then
    :
  else
    FAILED="$FAILED $t"
  fi
done

echo ""
if [ -n "$FAILED" ]; then
  echo "FAILED suites:$FAILED"
  exit 1
fi
echo "All suites passed."
