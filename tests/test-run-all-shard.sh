#!/bin/bash
# Tests for tests/run-all.sh --shard N/M.
#
# Windows runs the whole suite list sequentially in one job: 1,305s wall clock against
# 162s on Linux for the same commit, because every process launch on that platform costs
# roughly ten times what it costs elsewhere. Sharding does not make anything faster -- the
# billed minutes are identical -- it splits the wall clock across matrix legs that already
# run in parallel.
#
# The whole risk of a partition is that it stops being one. A suite in no shard runs
# NOWHERE, and a CI leg that ran 30 of 45 suites is green in exactly the way a leg that ran
# all 45 is green. So the assertion that matters here is not "shard 1 runs fewer suites",
# it is that the union of every shard is the complete list and that nothing appears twice.
# Everything else in this file is around that one.
#
# Usage: bash tests/test-run-all-shard.sh
#
# jit-drive: none -- every check here reads a captured file with plain grep/test, never a
# helper that takes an (description, output) pair.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ALL="$REPO/tests/run-all.sh"

PASS=0
FAIL=0

TMP="$(mktemp -d 2> /dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  [ $# -gt 0 ] && echo "    $*"
  return 0
}

# Nine stub suites, all trivially passing. Nine and not two: with four shards, a count that
# divides evenly would hide an off-by-one in the round-robin, and nine over four leaves a
# remainder in every shard but the last.
FIX="$TMP/fix"
mkdir -p "$FIX"
cp "$RUN_ALL" "$FIX/run-all.sh"
SUITES="test-a test-b test-c test-d test-e test-f test-g test-h test-i"
for s in $SUITES; do
  printf '#!/bin/bash\nexit 0\n' > "$FIX/$s.sh"
done
chmod +x "$FIX"/test-*.sh

# Which suites one invocation actually ran, read off the `########## <name> ##########`
# banner run-all.sh prints per suite. Read from a file, never through $( ) on the whole
# output: `paths/00-manual/tests.md` is explicit that command substitution drops NUL bytes,
# and a banner is the one thing this file's verdicts are built from.
ran_suites() { # shard-spec-or-empty -> names, one per line, into $TMP/ran
  if [ -n "$1" ]; then
    (cd "$FIX" && bash run-all.sh --shard "$1") > "$TMP/out" 2>&1
  else
    (cd "$FIX" && bash run-all.sh) > "$TMP/out" 2>&1
  fi
  RAN_RC=$?
  awk '/^########## .* ##########$/ { print $2 }' "$TMP/out" > "$TMP/ran"
}

echo "=== control: an unsharded run still runs every suite ==="
# The positive control for every count below. If run-all.sh cannot see this fixture at all,
# every shard would run 0 suites and the union assertion would compare two empty lists and
# pass. That is the vacuous shape this directory exists to refuse.
ran_suites ""
N_ALL=$(grep -c . "$TMP/ran")
if [ "$N_ALL" -eq 9 ]; then
  ok "an unsharded run runs all 9 stub suites"
else
  bad "an unsharded run runs all 9 stub suites" "ran $N_ALL"
  echo "    every assertion below would be comparing empty lists"
  echo ""
  echo "========================"
  echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
  echo "========================"
  exit 1
fi
cp "$TMP/ran" "$TMP/all"

echo ""
echo "=== the shards partition the list: every suite once, none twice, none lost ==="
: > "$TMP/union"
SHARD_COUNTS=""
for i in 1 2 3 4; do
  ran_suites "$i/4"
  cat "$TMP/ran" >> "$TMP/union"
  SHARD_COUNTS="$SHARD_COUNTS $(grep -c . "$TMP/ran")"
done
LC_ALL=C sort "$TMP/union" > "$TMP/union.sorted"
LC_ALL=C sort "$TMP/all" > "$TMP/all.sorted"

if diff -q "$TMP/union.sorted" "$TMP/all.sorted" > /dev/null 2>&1; then
  ok "the union of 1/4..4/4 is exactly the unsharded list (counts:$SHARD_COUNTS)"
else
  bad "the union of 1/4..4/4 is exactly the unsharded list" "counts:$SHARD_COUNTS"
  diff "$TMP/all.sorted" "$TMP/union.sorted" | sed 's/^/      /'
fi

N_UNION=$(grep -c . "$TMP/union")
N_UNIQ=$(LC_ALL=C sort -u "$TMP/union" | grep -c .)
if [ "$N_UNION" -eq "$N_UNIQ" ]; then
  ok "no suite is run by two shards ($N_UNION total, $N_UNIQ distinct)"
else
  bad "no suite is run by two shards" "$N_UNION runs over $N_UNIQ distinct suites"
  LC_ALL=C sort "$TMP/union" | uniq -d | sed 's/^/      /'
fi

echo ""
echo "=== a shard is a real subset, not the whole list under another name ==="
# Without this, a --shard that parsed its argument and then ignored it would satisfy both
# assertions above: four full runs union to the full list and would only fail the duplicate
# check... which is exactly why that check is there. This is the other half.
ran_suites "1/4"
N1=$(grep -c . "$TMP/ran")
if [ "$N1" -gt 0 ] && [ "$N1" -lt "$N_ALL" ]; then
  ok "shard 1/4 runs some suites but not all ($N1 of $N_ALL)"
else
  bad "shard 1/4 runs some suites but not all" "ran $N1 of $N_ALL"
fi

echo ""
echo "=== 1/1 is the whole list, so the flag has a no-op spelling ==="
ran_suites "1/1"
if [ "$(grep -c . "$TMP/ran")" -eq "$N_ALL" ]; then
  ok "--shard 1/1 runs every suite"
else
  bad "--shard 1/1 runs every suite" "ran $(grep -c . "$TMP/ran") of $N_ALL"
fi

echo ""
echo "=== the shard says what it selected, out of how many ==="
# A shard that selected nothing must be visible in the log as that, rather than as a run
# with no failures. run-all.sh renders a skip green already; a silently empty shard would
# be greener still.
ran_suites "2/4"
if grep -q 'shard 2/4' "$TMP/out"; then
  ok "the report names which shard ran"
else
  bad "the report names which shard ran" "no 'shard 2/4' line in the output"
fi

echo ""
echo "=== a shard spec that cannot be honoured is refused, never silently ignored ==="
# Exit 2, the same could-not-evaluate code every tool under scripts/ uses. NOT exit 1: a
# malformed flag is not a failing test suite, and CI reading it as one would send someone
# looking for a broken assertion. And never exit 0 with everything run -- a typo in a
# matrix expression would then run the full suite on all four legs and look merely slow.
for spec in "0/4" "5/4" "abc" "1/0" "-1/4" "1/4/2" ""; do
  (cd "$FIX" && bash run-all.sh --shard "$spec") > "$TMP/bad.out" 2>&1
  rc=$?
  n=$(awk '/^########## .* ##########$/ { print $2 }' "$TMP/bad.out" | grep -c .)
  if [ "$rc" -eq 2 ] && [ "$n" -eq 0 ]; then
    ok "--shard '$spec' is refused with exit 2 and runs nothing"
  else
    bad "--shard '$spec' is refused with exit 2 and runs nothing" \
      "exit $rc, $n suite(s) ran"
  fi
done

echo ""
echo "=== an unknown flag is refused too ==="
(cd "$FIX" && bash run-all.sh --nosuchflag) > "$TMP/bad.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "an unknown flag exits 2"
else
  bad "an unknown flag exits 2" "exit $rc"
fi

echo ""
echo "=== a failing suite still fails its own shard, and only its own ==="
printf '#!/bin/bash\nexit 1\n' > "$FIX/test-e.sh"
chmod +x "$FIX/test-e.sh"
FAILED_IN=""
for i in 1 2 3 4; do
  ran_suites "$i/4"
  [ "$RAN_RC" -ne 0 ] && FAILED_IN="$FAILED_IN $i"
done
if [ "$(printf '%s' "$FAILED_IN" | wc -w | tr -d '[:space:]')" = "1" ]; then
  ok "exactly one shard goes red for one failing suite (shard$FAILED_IN)"
else
  bad "exactly one shard goes red for one failing suite" "red in shard(s):${FAILED_IN:- none}"
fi
printf '#!/bin/bash\nexit 0\n' > "$FIX/test-e.sh"
chmod +x "$FIX/test-e.sh"

echo ""
echo "=== the timing block survives sharding ==="
# #304's block is what this whole arc was measured with. A shard that stopped printing it
# would take the instrument away at the moment it is most needed.
ran_suites "1/4"
if grep -q '^Timing (slowest first' "$TMP/out" && grep -q '^Total: ' "$TMP/out"; then
  ok "a sharded run still prints its timing block and total"
else
  bad "a sharded run still prints its timing block and total"
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
