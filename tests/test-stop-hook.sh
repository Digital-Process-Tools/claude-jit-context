#!/bin/bash
# #244 (part 2 of #233): the Stop hook that reads the injected-vs-edited comparison back.
# The numerator (what fired) already existed as the `shown` marks; post-tool-hook.sh
# (#244, same issue) is what makes the denominator (was anything edited) exist at all.
#
# THREE STATES, and the issue is explicit that the third must never render as the first:
# entries fired and none edited (the numbered list); entries fired and some edited
# (silence -- the healthy case, same posture SessionStart's own "ok" already takes);
# and COULD NOT TELL whether anything was edited, which must say so rather than pass as
# clean. This suite drives all three, plus the "nothing fired at all" case, which is a
# fourth, uncontroversial kind of silence (there is nothing to compare).
#
# jit-drive: assert_contains contains capture
#
# Usage: bash tests/test-stop-hook.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

assert_empty_json() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected exactly {} - got: ${output:-<EMPTY>}"
  fi
}

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/vocabulary/00-manual"
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }

run_stop() {
  local p="$1" sid="$2"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$sid" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/stop-hook.sh" 2>&1
}

echo "=== A: entries fired, nothing edited -- the numbered list ==="

P="$(new_project a)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\ncache.md\n' > "$(state_of "$P")/vocab-shown-sess-a.txt"
OUT="$(run_stop "$P" "sess-a")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the message names the fired entry" "$OUT" "bridge.md"
assert_contains "and the other one too" "$OUT" "cache.md"
assert_contains "and says none were updated" "$OUT" "none updated"

echo ""
echo "=== B: entries fired, something WAS edited this session -- silence ==="
# The healthy case. This is the pair to A: without it, a hook that always prints the
# numbered list regardless of the edit marker would pass A by construction.

P="$(new_project b)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-b.txt"
: > "$(state_of "$P")/edited-sess-b.txt"
OUT="$(run_stop "$P" "sess-b")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- edits happened" "$OUT"

echo ""
echo "=== C: nothing fired at all this session -- silence, there is nothing to compare ==="

P="$(new_project c)"
mkdir -p "$(state_of "$P")"
OUT="$(run_stop "$P" "sess-c")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- no injections this session" "$OUT"

echo ""
echo "=== D: an unwritable tree -- COULD NOT TELL, never silence ==="
# The state directory degrades to empty on a checkout this process cannot write to
# (common.sh). Nothing here can tell whether anything fired or was edited, and #244 is
# explicit that this must not render as the clean case in B/C.

D_SKIPPED=0
P="$(new_project d)"
chmod 555 "$P/.claude/jit-context" 2>/dev/null
if [ -w "$P/.claude/jit-context" ]; then
  D_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section D tested nothing."
else
  OUT="$(run_stop "$P" "sess-d")"; RC=$?
  assert_rc0 "the hook exits 0" "$RC"
  assert_contains "it says it could not tell" "$OUT" "could not tell"
  if [ "$OUT" = "{}" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: could-not-tell rendered as silence"
  else
    PASS=$((PASS + 1)); echo "  PASS: could-not-tell did not render as silence"
  fi
fi
chmod 755 "$P/.claude/jit-context" 2>/dev/null

echo ""
echo "=== E: no jit-context tree at all -- fully inert ==="

P="$TMP/e"
mkdir -p "$P"
OUT="$(run_stop "$P" "sess-e")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing at all" "$OUT"
if [ -e "$P/.claude" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a .claude directory was materialised for a tree-less project"
else
  PASS=$((PASS + 1)); echo "  PASS: no .claude directory is materialised"
fi

echo ""
echo "=== F: sentinel keys in the shown marks are not reported as fired entries ==="

P="$(new_project f)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\njit-refused-vocab\njit-no-subject\n' > "$(state_of "$P")/vocab-shown-sess-f.txt"
OUT="$(run_stop "$P" "sess-f")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the real entry is named" "$OUT" "bridge.md"
SENTINEL_HIT=0
grep -qF -- "jit-refused-vocab" <<<"$OUT" && SENTINEL_HIT=1
grep -qF -- "jit-no-subject" <<<"$OUT" && SENTINEL_HIT=1
if [ "$SENTINEL_HIT" = 1 ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a sentinel key was reported as a fired entry"
  echo "    got: $OUT"
else
  PASS=$((PASS + 1)); echo "  PASS: no sentinel key was reported as a fired entry"
fi

echo ""
echo "=== G: the same entry fired through both marker files is only counted once ==="

P="$(new_project g)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-g.txt"
printf 'bridge.md\n' > "$(state_of "$P")/path-shown-sess-g.txt"
OUT="$(run_stop "$P" "sess-g")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
COUNT="$(grep -o 'bridge\.md' <<<"$OUT" | wc -l | tr -d ' ')"
if [ "$COUNT" = "1" ]; then
  PASS=$((PASS + 1)); echo "  PASS: the entry is listed exactly once"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the entry appeared $COUNT times, expected 1"
  echo "    got: $OUT"
fi

echo ""
echo "=== H: the dedup scan is bounded, not quadratic in an untrusted marker file ==="
# The collection pass re-scans its own accumulator on every line (a plain `case`, no
# associative array -- bash 3.2 has none); left unbounded that is quadratic in the
# number of distinct names two marker files can hold. This does not prove the bound
# fires at exactly the right count -- it proves a marker file bigger than any real
# session produces still answers, and answers with every name accounted for one way
# or the other (listed, or named in the overflow line).

P="$(new_project h)"
mkdir -p "$(state_of "$P")"
JIT_HI=600
_jit_seq=1
: > "$(state_of "$P")/vocab-shown-sess-h.txt"
while [ "$_jit_seq" -le "$JIT_HI" ]; do
  printf 'entry-%s.md\n' "$_jit_seq" >> "$(state_of "$P")/vocab-shown-sess-h.txt"
  _jit_seq=$((_jit_seq + 1))
done
OUT="$(run_stop "$P" "sess-h")"; RC=$?
assert_rc0 "the hook exits 0 on 600 distinct fired entries" "$RC"
assert_contains "the reported total accounts for all 600" "$OUT" "$JIT_HI entries injected"
assert_contains "the overflow past the cap is named, not silently dropped" "$OUT" "more past this hook's own"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
