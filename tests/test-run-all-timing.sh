#!/bin/bash
# Tests for tests/run-all.sh -- #304, per-suite timing.
#
# run-all.sh reported pass/fail but never how long a suite took, so nothing here --
# including CI -- could say which suite was slow versus hung. This suite proves three
# things about the timing block it now prints: it appears after the pass/fail tally
# (the tally stays the verdict), it orders slowest-first, and it does not change the
# exit code in either the passing or the failing case.
#
# It also proves the negative/positive pair `paths/00-manual/tests.md` asks for: a
# suite that could not be timed prints "n/a", never "0s" -- because a genuinely fast
# suite (real elapsed time rounds down to 0s) and an unmeasured one must not render the
# same way. run-all.sh cannot be made to lose $SECONDS on any of the three real CI
# platforms (it is a bash builtin, not a `date` extension), so the fallback path is
# exercised through RUN_ALL_SIMULATE_NO_TIMING=1, a hook run-all.sh documents as
# existing only for this suite. The positive case (real platforms) is exercised by
# every other assertion below, which runs with that hook unset.
#
# Usage: bash tests/test-run-all-timing.sh
#
# jit-drive: none -- every check here reads a captured file with plain grep/test,
# never a helper that takes an (description, output) pair.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ALL="$REPO/tests/run-all.sh"

PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -gt 0 ] && echo "    $*"; return 0; }

# A minimal fixture directory: run-all.sh cds to its own dirname and globs test-*.sh
# there, so a copy of it plus a couple of stub suites is a complete sandbox -- nothing
# from this repo's real suites needs to run.
build_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$RUN_ALL" "$dir/run-all.sh"
  cat > "$dir/test-a-fast.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$dir/test-b-slow.sh" <<'EOF'
#!/bin/bash
sleep 1
exit 0
EOF
  chmod +x "$dir"/test-*.sh
}

# --- Passing fixture: both suites exit 0 ---
build_fixture "$TMP/pass"
OUT_PASS="$TMP/pass-out.txt"
(cd "$TMP/pass" && bash run-all.sh) > "$OUT_PASS" 2>&1
RC_PASS=$?

if [ "$RC_PASS" -eq 0 ]; then
  ok "a passing fixture still exits 0 with timing added"
else
  bad "a passing fixture still exits 0 with timing added" "exit=$RC_PASS"
  cat "$OUT_PASS"
fi

if grep -q '^All suites passed\.$' "$OUT_PASS"; then
  ok "the tally line is unchanged"
else
  bad "the tally line is unchanged"
  cat "$OUT_PASS"
fi

if grep -q 'Timing' "$OUT_PASS"; then
  ok "a timing block is printed"
else
  bad "a timing block is printed"
  cat "$OUT_PASS"
fi

# The tally must come first -- "prints them slowest first after the pass/fail tally".
TALLY_LINE=$(grep -n '^All suites passed\.$' "$OUT_PASS" | sed -n '1p' | cut -d: -f1)
TIMING_LINE=$(grep -n 'Timing' "$OUT_PASS" | sed -n '1p' | cut -d: -f1)
if [ -n "$TALLY_LINE" ] && [ -n "$TIMING_LINE" ] && [ "$TIMING_LINE" -gt "$TALLY_LINE" ]; then
  ok "the timing block comes after the tally, not before it"
else
  bad "the timing block comes after the tally, not before it" "tally=$TALLY_LINE timing=$TIMING_LINE"
fi

# Slowest first: test-b-slow.sh (sleep 1) must be listed before test-a-fast.sh.
SLOW_LINE=$(grep -n 'test-b-slow\.sh' "$OUT_PASS" | tail -1 | cut -d: -f1)
FAST_LINE=$(grep -n 'test-a-fast\.sh' "$OUT_PASS" | tail -1 | cut -d: -f1)
if [ -n "$SLOW_LINE" ] && [ -n "$FAST_LINE" ] && [ "$SLOW_LINE" -lt "$FAST_LINE" ]; then
  ok "the slower suite is listed before the faster one"
else
  bad "the slower suite is listed before the faster one" "slow_line=$SLOW_LINE fast_line=$FAST_LINE"
  cat "$OUT_PASS"
fi

# A total is printed with a real number in it.
if grep -qE 'Total: [0-9]+s' "$OUT_PASS"; then
  ok "a total wall-clock time is printed"
else
  bad "a total wall-clock time is printed"
  cat "$OUT_PASS"
fi

# Positive control for the timing itself: the slow suite's own line names a number of
# seconds greater than 0 -- this is the case "would this pass if the code did nothing"
# is aimed at: a stub that always printed "1s" for every suite would pass every
# assertion above except this one.
SLOW_TIME_LINE=$(grep 'test-b-slow\.sh' "$OUT_PASS" | tail -1)
if grep -qE '^ *[1-9][0-9]*s' <<<"$SLOW_TIME_LINE"; then
  ok "the slow suite (sleep 1) is timed at 1 second or more, not 0"
else
  bad "the slow suite (sleep 1) is timed at 1 second or more, not 0" "$SLOW_TIME_LINE"
fi

# --- Failing fixture: the exit code and the tally text must not change shape ---
build_fixture "$TMP/fail"
cat > "$TMP/fail/test-c-fail.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TMP/fail/test-c-fail.sh"
OUT_FAIL="$TMP/fail-out.txt"
(cd "$TMP/fail" && bash run-all.sh) > "$OUT_FAIL" 2>&1
RC_FAIL=$?

if [ "$RC_FAIL" -eq 1 ]; then
  ok "a failing fixture still exits 1 with timing added"
else
  bad "a failing fixture still exits 1 with timing added" "exit=$RC_FAIL"
  cat "$OUT_FAIL"
fi

if grep -q '^FAILED suites:.*test-c-fail\.sh' "$OUT_FAIL"; then
  ok "the FAILED line still names the failing suite"
else
  bad "the FAILED line still names the failing suite"
  cat "$OUT_FAIL"
fi

TIMING_BLOCK=$(awk '/Timing/{p=1} p' "$OUT_FAIL")
if grep -q 'test-c-fail\.sh' "$OUT_FAIL" && grep -qF 'test-c-fail.sh' <<<"$TIMING_BLOCK"; then
  ok "a failed suite is still timed, in the timing block"
else
  bad "a failed suite is still timed, in the timing block"
  cat "$OUT_FAIL"
fi

# --- The "could not measure" path: forced via the documented testing hook ---
build_fixture "$TMP/notime"
OUT_NOTIME="$TMP/notime-out.txt"
(cd "$TMP/notime" && RUN_ALL_SIMULATE_NO_TIMING=1 bash run-all.sh) > "$OUT_NOTIME" 2>&1
RC_NOTIME=$?

if [ "$RC_NOTIME" -eq 0 ]; then
  ok "the fallback path still exits 0 on a passing fixture"
else
  bad "the fallback path still exits 0 on a passing fixture" "exit=$RC_NOTIME"
  cat "$OUT_NOTIME"
fi

if grep -q 'n/a' "$OUT_NOTIME"; then
  ok "an untimeable suite prints n/a"
else
  bad "an untimeable suite prints n/a"
  cat "$OUT_NOTIME"
fi

# The negative half: no suite line in the fallback output claims a numeric time --
# specifically it must never print "0s", which would be indistinguishable from a
# suite that really did take no measurable time.
if grep -qE '(^| )0s( |$)' "$OUT_NOTIME"; then
  bad "the fallback path never prints 0s for an untimed suite" "$(grep -E '(^| )0s( |$)' "$OUT_NOTIME")"
else
  ok "the fallback path never prints 0s for an untimed suite"
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
