#!/bin/bash
# The contract between the runner's symlink configuration and the two containment suites.
#
# tests/test-symlink-entry.sh and tests/test-log-containment.sh construct their fixtures
# with `ln -s`. On Git Bash the MSYS runtime COPIES the target instead of linking it, so
# those suites probe for the capability and skip when it is absent (exit 2). Issue #33
# turns the capability on for Windows CI: the workflow exports MSYS=winsymlinks:nativestrict
# and declares the requirement with JIT_TESTS_REQUIRE_SYMLINKS=1.
#
# This suite covers the case the workflow change cannot cover itself: the environment asked
# for symbolic links and did NOT get them. That is a broken configuration, not a platform
# without the capability, and the two must not print the same verdict -- a skip that CI
# renders green is exactly the hole #33 was filed about. So:
#
#   requirement NOT declared, no symlinks  -> honest skip, exit 2, quiet
#   requirement declared, no symlinks      -> loud, exit 1, never a pass
#   requirement declared, symlinks present -> completely unaffected, exit 0
#
# "No symlinks" is FABRICATED here with a copying `ln` on PATH -- the MSYS behaviour, made
# reproducible on a platform that has real links. Every fabricated-negative case is paired
# with the same command run without the stub, because a stub that broke the suites for some
# unrelated reason would satisfy the negative half on its own.
#
# Usage: bash tests/test-symlink-required.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$SCRIPT_DIR/tests"
PASS=0
FAIL=0

REQUIRED_MARKER="SYMBOLIC LINKS WERE REQUIRED AND NOT OBTAINED"

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_rc() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected exit $want, got exit $got"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Does THIS platform make real symbolic links? ----------------------------
# The same property the two suites probe: content written to the target after the link
# exists must be visible through the link. Without it the "requirement declared and
# honoured" half below cannot be driven, and this suite says so instead of passing.
CAN_SYMLINK=no
probe_symlinks() {
  local d="$TMP/.symlink-probe"
  rm -rf "$d" || return 1
  mkdir -p "$d/target-dir" || return 1
  printf 'probe\n' > "$d/target-file" || return 1
  ln -sf "$d/target-file" "$d/link-file" 2>/dev/null
  ln -sfn "$d/target-dir" "$d/link-dir" 2>/dev/null
  printf 'late\n' > "$d/target-dir/late.txt" || return 1
  [ -L "$d/link-file" ] || return 1
  [ -L "$d/link-dir" ] || return 1
  [ -f "$d/link-dir/late.txt" ] || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
echo "symlink support: $CAN_SYMLINK (files and directories, verified through the link)"
echo ""

# --- The copying `ln`, which is MSYS without winsymlinks:nativestrict --------
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/ln" <<'STUBEOF'
#!/bin/bash
# Stands in for the MSYS `ln`, which copies the target instead of linking it.
src=""; dst=""
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) if [ -z "$src" ]; then src="$a"; else dst="$a"; fi ;;
  esac
done
[ -n "$src" ] && [ -n "$dst" ] || exit 1
rm -rf "$dst"
cp -R "$src" "$dst" 2>/dev/null
exit 0
STUBEOF
chmod +x "$STUB/ln"

# run_suite <suite> <require 0|1> <stubbed 0|1>
run_suite() {
  local suite="$1" require="$2" stubbed="$3" path="$PATH"
  [ "$stubbed" = 1 ] && path="$STUB:$PATH"
  if [ "$require" = 1 ]; then
    PATH="$path" JIT_TESTS_REQUIRE_SYMLINKS=1 bash "$TESTS/$suite" 2>&1
  else
    PATH="$path" JIT_TESTS_REQUIRE_SYMLINKS='' bash "$TESTS/$suite" 2>&1
  fi
}

echo "=== Control: the stub really removes the capability, and only the stub does ==="

# Without this pair, every "the suite skipped" assertion below could hold because the stub
# broke something unrelated rather than because it copied.
STUBPROBE="$TMP/stubprobe"; mkdir -p "$STUBPROBE"
printf 'x\n' > "$STUBPROBE/target"
PATH="$STUB:$PATH" ln -sf "$STUBPROBE/target" "$STUBPROBE/link"
if [ -L "$STUBPROBE/link" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: stub ln produced a real symbolic link"
else
  PASS=$((PASS + 1)); echo "  PASS: stub ln produced a copy, not a link"
fi
if [ -f "$STUBPROBE/link" ]; then
  PASS=$((PASS + 1)); echo "  PASS: stub ln still produced the destination, as a copy does"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: stub ln produced nothing at all -- that is not the MSYS behaviour"
fi

echo ""
echo "=== Requirement NOT declared, platform cannot link: the honest skip is unchanged ==="

for suite in test-symlink-entry.sh test-log-containment.sh; do
  OUT="$(run_suite "$suite" 0 1)"; RC=$?
  assert_rc "$suite: exits 2, this repo's could-not-evaluate" 2 "$RC"
  assert_contains "$suite: says it skipped" "$OUT" "SKIPPED"
  assert_contains "$suite: reports the probe as no" "$OUT" "symlink support: no"
  assert_not_contains "$suite: does not claim a broken configuration" "$OUT" "$REQUIRED_MARKER"
done

echo ""
echo "=== Requirement declared, platform cannot link: loud, and never a pass ==="

for suite in test-symlink-entry.sh test-log-containment.sh; do
  OUT="$(run_suite "$suite" 1 1)"; RC=$?
  assert_rc "$suite: exits 1 -- a configuration we asked for and did not get is a failure" 1 "$RC"
  assert_contains "$suite: names the broken configuration" "$OUT" "$REQUIRED_MARKER"
  assert_contains "$suite: names the variable that declared it" "$OUT" "JIT_TESTS_REQUIRE_SYMLINKS"
  assert_contains "$suite: names what the runner needs" "$OUT" "winsymlinks:nativestrict"
  # run-all.sh renders exit 2 green, so the platform-cannot verdict must not be the one
  # this run closes on. Each suite has its own wording for it.
  case "$suite" in
    test-symlink-entry.sh)   SKIPVERDICT="every containment case SKIPPED" ;;
    test-log-containment.sh) SKIPVERDICT="SKIPPED (no symbolic links on this platform)" ;;
    *)                       SKIPVERDICT="__no such suite__" ;;
  esac
  assert_not_contains "$suite: does not close on the platform-cannot verdict" "$OUT" "$SKIPVERDICT"
done

echo ""
if [ "$CAN_SYMLINK" != yes ]; then
  echo "=== SKIPPED: requirement declared AND honoured ==="
  echo "    This platform does not create symbolic links, so the half that proves"
  echo "    JIT_TESTS_REQUIRE_SYMLINKS=1 leaves a healthy machine alone cannot be driven."
  echo "    Only the fabricated-negative half above ran."
  echo ""
  echo "$PASS passed, $FAIL failed, the honoured-requirement section SKIPPED"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 2
fi

echo "=== Requirement declared AND honoured: the suites are untouched ==="

# The child suite's own exit code is asserted here, not only its wording. Until #43 those
# two suites reddened at random from a once-per-session marker keyed on a recycled $PPID,
# and this half deliberately did not look at their verdict; the marker now keys on a
# session_id these payloads do not carry, so exit 0 is a claim that holds every run and a
# non-zero one is a finding.
for suite in test-symlink-entry.sh test-log-containment.sh; do
  case "$suite" in
    test-symlink-entry.sh)   RAN_MARKER="=== S3a" ;;
    test-log-containment.sh) RAN_MARKER="=== S4a" ;;
    *)                       RAN_MARKER="__no such suite__" ;;
  esac
  OUT="$(run_suite "$suite" 1 0)"; RC=$?
  assert_rc "$suite: still passes clean with the requirement declared" 0 "$RC"
  assert_contains "$suite: reports the probe as yes" "$OUT" "symlink support: yes"
  assert_contains "$suite: the requirement is stated in the log" "$OUT" "REQUIRED by this environment"
  assert_contains "$suite: the containment sections actually ran" "$OUT" "$RAN_MARKER"
  assert_not_contains "$suite: nothing is skipped" "$OUT" "SKIPPED"
  assert_not_contains "$suite: no broken-configuration verdict" "$OUT" "$REQUIRED_MARKER"
done

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
