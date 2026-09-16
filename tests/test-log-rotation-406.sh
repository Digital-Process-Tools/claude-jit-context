#!/bin/bash
# #406: hooks.log rotates automatically at a configurable size, and never deletes.
#
# Three pieces, three sections: jit_log_rotate() in common.sh (A), jit-misses.sh's
# handling of the rotation marker it leaves behind (B), and session-start-hook.sh
# wiring the two together end to end (C). Every negative here ("did not rotate",
# "nothing injected", "SKIPPED reads as ordinary") is paired with a positive control
# on the same fixture shape, per tests.md -- a fixture that never rotates and a hook
# that never ran would make every one of those true for a reason unrelated to the
# feature.
#
# Usage: bash tests/test-log-rotation-406.sh
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
# jit-drive: none -- assert_eq and assert_true compare two already-known values
#   (a byte count, an exit code, a boolean file-test expression) rather than
#   searching a captured OUTPUT string for a needle, the same reason
#   test-host-registry.sh and test-config-locale-collation.sh give for their own
#   assert_eq.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$REPO/scripts/common.sh"
MISSES="$REPO/scripts/jit-misses.sh"
HOOK="$REPO/scripts/session-start-hook.sh"
PASS=0
FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/jit-logrotate-XXXXXX" 2> /dev/null)" || {
  echo "test-log-rotation-406: SKIPPED -- could not create a temp directory"
  exit 2
}
trap 'rm -rf "$TMPROOT"' EXIT

if [ ! -f "$COMMON" ] || [ ! -f "$MISSES" ] || [ ! -f "$HOOK" ]; then
  echo "  FAIL: harness guard -- $COMMON, $MISSES or $HOOK does not exist, every assertion below is vacuous"
  exit 1
fi

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:400}"
  fi
}
assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:400}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}
assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    got:      $actual"
  fi
}
assert_true() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc ($cond)"
  fi
}

fixture() {
  # A fresh project tree with a log of ~50 pre-prompt lines (~3.2KB), and returns
  # PROJ/LOGDIR via the globals below.
  PROJ="$TMPROOT/proj-$1"
  LOGDIR="$PROJ/.claude/jit-context/.discovery/logs"
  mkdir -p "$LOGDIR" "$PROJ/.claude/jit-context"
  local i=0
  {
    while [ "$i" -lt 50 ]; do
      printf '[10:00:%02d.000] pre-prompt 1ms | (none) [shown:0] << word%d test\n' "$((i % 60))" "$i"
      i=$((i + 1))
    done
  } > "$LOGDIR/hooks.log"
}

echo "=== section A: jit_log_rotate() in common.sh ==="

fixture a1
ORIG_BYTES="$(wc -c < "$LOGDIR/hooks.log" | tr -d '[:space:]')"
CLAUDE_PROJECT_DIR="$PROJ" bash -c "source \"$COMMON\"; jit_log_rotate 999999999" 2> /dev/null
assert_true "A1 below threshold: no rotation (positive control for A2/A3)" '[ ! -e "$LOGDIR/hooks.log.1" ]'
assert_eq "A1 below threshold: hooks.log untouched" "$(wc -c < "$LOGDIR/hooks.log" | tr -d '[:space:]')" "$ORIG_BYTES"

fixture a2
CLAUDE_PROJECT_DIR="$PROJ" bash -c "source \"$COMMON\"; jit_log_rotate 500" 2> /dev/null
assert_true "A2 at/above threshold: rotation fires (hooks.log.1 exists)" '[ -f "$LOGDIR/hooks.log.1" ]'
ROTATED_BYTES="$(wc -c < "$LOGDIR/hooks.log.1" | tr -d '[:space:]')"
assert_eq "A2 rotated file is byte-for-byte the original log" "$ROTATED_BYTES" "$ORIG_BYTES"
assert_contains "A2 rotated .1 still ends on the last original line" "$(tail -1 "$LOGDIR/hooks.log.1")" "word49"
NEWSIZE="$(wc -c < "$LOGDIR/hooks.log" | tr -d '[:space:]')"
assert_true "A2 new hooks.log is small (just the marker)" "[ \"$NEWSIZE\" -lt 200 ]"
assert_contains "A2 new hooks.log carries the rotation marker" "$(cat "$LOGDIR/hooks.log")" "hooks.log rotated at $ORIG_BYTES bytes"

fixture a3
CLAUDE_PROJECT_DIR="$PROJ" bash -c "
  source \"$COMMON\"
  exec 9>> \"\$LOG_FILE\"
  jit_log_rotate 500
  printf 'concurrent-write-after-rotate\n' >&9
  exec 9>&-
" 2> /dev/null
assert_contains "A3 a writer holding the OLD path across the rename loses nothing" \
  "$(cat "$LOGDIR/hooks.log.1")" "concurrent-write-after-rotate"
CLAUDE_PROJECT_DIR="$PROJ" bash -c "source \"$COMMON\"; jit_log_write 'after-rotation-write'" 2> /dev/null
assert_contains "A3 a write AFTER rotation lands in the NEW hooks.log" \
  "$(cat "$LOGDIR/hooks.log")" "after-rotation-write"
assert_not_contains "A3 the after-rotation write did NOT also land in hooks.log.1" \
  "$(cat "$LOGDIR/hooks.log.1")" "after-rotation-write"

fixture a4
CLAUDE_PROJECT_DIR="$PROJ" bash -c "source \"$COMMON\"; jit_log_rotate 0" 2> /dev/null
assert_true "A4 JIT_CONTEXT_LOG_MAX_BYTES=0 means never rotate" '[ ! -e "$LOGDIR/hooks.log.1" ]'

fixture a5
OUT_MALFORMED="$(CLAUDE_PROJECT_DIR="$PROJ" bash -c "
  echo 'JIT_CONTEXT_LOG_MAX_BYTES=0100' > \"$PROJ/.claude/jit-context/config.env\"
  source \"$COMMON\"
  echo \"REFUSED_N=\$JIT_CONFIG_REFUSED_N\"
  echo \"\$JIT_CONFIG_REFUSED\"
" 2> /dev/null)"
assert_contains "A5 a leading-zero value is refused, not silently octal-parsed" "$OUT_MALFORMED" "REFUSED_N=1"
assert_contains "A5 the refusal names the line" "$OUT_MALFORMED" "not a byte count"
OUT_NEGATIVE="$(CLAUDE_PROJECT_DIR="$PROJ" bash -c "
  echo 'JIT_CONTEXT_LOG_MAX_BYTES=-5' > \"$PROJ/.claude/jit-context/config.env\"
  source \"$COMMON\"
  echo \"REFUSED_N=\$JIT_CONFIG_REFUSED_N\"
" 2> /dev/null)"
assert_contains "A5 a negative value is refused too" "$OUT_NEGATIVE" "REFUSED_N=1"
OUT_VALID="$(CLAUDE_PROJECT_DIR="$PROJ" bash -c "
  echo 'JIT_CONTEXT_LOG_MAX_BYTES=20000000' > \"$PROJ/.claude/jit-context/config.env\"
  source \"$COMMON\"
  echo \"REFUSED_N=\$JIT_CONFIG_REFUSED_N JIT_CONTEXT_LOG_MAX_BYTES=\$JIT_CONTEXT_LOG_MAX_BYTES\"
" 2> /dev/null)"
assert_contains "A5 positive control: a well-formed value is accepted and applied" "$OUT_VALID" "REFUSED_N=0 JIT_CONTEXT_LOG_MAX_BYTES=20000000"

fixture a6
chmod 555 "$LOGDIR"
ORIG_A6="$(wc -c < "$LOGDIR/hooks.log" | tr -d '[:space:]')"
CLAUDE_PROJECT_DIR="$PROJ" bash -c "source \"$COMMON\"; jit_log_rotate 500; echo rc=\$?" > "$TMPROOT/a6.out" 2> /dev/null
chmod 755 "$LOGDIR"
assert_contains "A6 an unwritable log directory: jit_log_rotate still returns success" "$(cat "$TMPROOT/a6.out")" "rc=0"
assert_true "A6 an unwritable log directory: no hooks.log.1 was created" '[ ! -e "$LOGDIR/hooks.log.1" ]'
assert_eq "A6 an unwritable log directory: hooks.log is untouched (positive control is A2 above)" \
  "$(wc -c < "$LOGDIR/hooks.log" | tr -d '[:space:]')" "$ORIG_A6"

fixture a7
ln -s /etc/passwd "$LOGDIR/hooks.log.1"
CLAUDE_PROJECT_DIR="$PROJ" bash -c "source \"$COMMON\"; jit_log_rotate 500" 2> /dev/null
assert_true "A7 a symlinked hooks.log.1 is never overwritten through" \
  '[ -L "$LOGDIR/hooks.log.1" ] && [ "$(readlink "$LOGDIR/hooks.log.1")" = "/etc/passwd" ]'

echo ""
echo "=== section B: jit-misses.sh reads the rotation marker, never hooks.log.1 ==="

fixture b1
printf '[19:40:05.231] hooks.log rotated at 75 bytes -- records before this line are in hooks.log.1\n' > "$LOGDIR/hooks.log"
OUT_B1="$(bash "$MISSES" --log "$LOGDIR/hooks.log" 2>&1)"
RC_B1=$?
assert_eq "B1 marker-only log: exit 2 (SKIPPED)" "$RC_B1" "2"
assert_contains "B1 marker-only log: names the rotation, not \"wrong format\"" "$OUT_B1" "hooks.log was rotated at"
assert_contains "B1 marker-only log: says older records are in hooks.log.1" "$OUT_B1" "hooks.log.1"
assert_not_contains "B1 marker-only log: does NOT read as the generic format error" "$OUT_B1" "the format changed"

fixture b2
{
  printf '[19:40:05.231] hooks.log rotated at 75 bytes -- records before this line are in hooks.log.1\n'
  printf '[19:41:00.000] pre-prompt 1ms | (none) [shown:0] << preprod deploy is broken\n'
  printf '[19:42:00.000] pre-prompt 1ms | (none) [shown:0] << preprod deploy again\n'
} > "$LOGDIR/hooks.log"
OUT_B2="$(bash "$MISSES" --log "$LOGDIR/hooks.log" 2>&1)"
RC_B2=$?
assert_eq "B2 marker + real records: exit 0 (findings, not SKIPPED)" "$RC_B2" "0"
assert_contains "B2 marker + real records: header states the window narrowed (#406)" "$OUT_B2" "hooks.log was rotated at"
assert_contains "B2 marker + real records: still finds the recurring miss (positive control)" "$OUT_B2" "preprod"
assert_contains "B2 the marker line itself is not counted as a prompt record (2, not 3)" "$OUT_B2" "2 prompt record(s)"

fixture b3
printf '[10:00:00.000] pre-prompt 1ms | (none) [shown:0] << preprod deploy is broken\n' > "$LOGDIR/hooks.log"
OUT_B3="$(bash "$MISSES" --log "$LOGDIR/hooks.log" 2>&1)"
assert_not_contains "B3 positive control: a log that never rotated prints no rotation line" "$OUT_B3" "hooks.log was rotated"

echo ""
echo "=== section C: session-start-hook.sh rotates before jit-misses.sh reads the log ==="

fixture c1
echo "JIT_CONTEXT_LOG_MAX_BYTES=500" > "$PROJ/.claude/jit-context/config.env"
OUT_C1="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" < /dev/null 2> /dev/null)"
assert_eq "C1 rotation this session: nothing injected (ordinary, like a brand new project)" "$OUT_C1" "{}"
assert_true "C1 rotation this session: hooks.log.1 now holds the original log" '[ -f "$LOGDIR/hooks.log.1" ]'
assert_true "C1 rotation this session: hooks.log is small (the marker only)" \
  "[ \"\$(wc -c < \"$LOGDIR/hooks.log\" | tr -d '[:space:]')\" -lt 200 ]"

fixture c2
echo "JIT_CONTEXT_LOG_MAX_BYTES=0" > "$PROJ/.claude/jit-context/config.env"
CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" < /dev/null > /dev/null 2>&1
assert_true "C2 positive control: JIT_CONTEXT_LOG_MAX_BYTES=0 never rotates from the hook either" \
  '[ ! -e "$LOGDIR/hooks.log.1" ]'

fixture c3
chmod 555 "$LOGDIR"
OUT_C3="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" < /dev/null 2> /dev/null)"
RC_C3=$?
chmod 755 "$LOGDIR"
assert_eq "C3 an unwritable log directory: the hook still exits 0" "$RC_C3" "0"
assert_eq "C3 an unwritable log directory: still valid, empty JSON (never fails hard)" "$OUT_C3" "{}"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
