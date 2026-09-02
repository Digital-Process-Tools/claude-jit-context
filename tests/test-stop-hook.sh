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
  local p="$1" sid="$2" active="${3:-false}"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$sid" "$active" \
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
echo "=== I: stop_hook_active=true -- a re-entry caused by this hook's own output, never re-report ==="
# #279: the harness re-invokes Stop when a previous Stop's own additionalContext blocked
# the turn from ending, and sets stop_hook_active=true on that re-entry. Section A is this
# case's positive control on the same code path: the same fired-entries fixture, with
# stop_hook_active=false, must still produce the numbered list. Without that pairing this
# assertion would pass for free if the hook simply exited early on a malformed payload.

P="$(new_project i)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\ncache.md\n' > "$(state_of "$P")/vocab-shown-sess-i.txt"
OUT="$(run_stop "$P" "sess-i" "true")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "stop_hook_active=true means no additionalContext, even though entries fired" "$OUT"

echo ""
echo "=== J: stop_hook_active is missing from the payload entirely -- treated as false ==="
# A distinct code path from I/A explicit false: jit_stop_hook_active() falls off its own
# scan loop and returns 0 via the final fallthrough, never matching the key at all. An
# older harness, or a hand-run reproduction, can omit the field outright.

P="$(new_project j)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-j.txt"
OUT="$(printf '{"session_id":"sess-j","hook_event_name":"Stop"}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "a payload with no stop_hook_active key at all still reports" "$OUT" "bridge.md"

echo ""
echo "=== K: an escaped quote earlier in the payload must not desync the field scan ==="
# jit_json_fields() merges raw[] segments across an escaped quote, so its LOGICAL field
# count (n) can sit below the PHYSICAL raw[] position stop_hook_active own value lives
# at. A bound check written against n instead of the physical array would refuse a
# genuinely in-range raw[] read and misreport a real true as false here -- silently
# reopening #279 for exactly the sessions whose cwd or transcript_path contains a
# literal double quote.

P="$(new_project k)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\ncache.md\n' > "$(state_of "$P")/vocab-shown-sess-k.txt"
OUT="$(printf '{"session_id":"sess-k","cwd":"C:\\quo\\"te","stop_hook_active":true}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "an escaped quote ahead of stop_hook_active does not hide a real true" "$OUT"

echo ""
echo "=== L: awk cannot run at all -- unknown, not false, taking the safe (true-like) silent branch (#284) ==="
# The parsed STOP_HOOK_ACTIVE variable is empty when the awk parse cannot run at all
# (stub awk, a broken interpreter). Reading that empty string identically to a parsed
# "false" falls through to the "could not tell" branch further down, which EMITS
# additionalContext -- exactly the output that blocks a turn from ending and reopens
# #279's re-entry loop, in the one state where the hook is least able to notice. A
# third value, distinct from both true and false, must take the SAME silent early
# return "true" does.

P="$(new_project l)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-l.txt"
FAKE_AWK_DIR="$TMP/fake-awk-l"
mkdir -p "$FAKE_AWK_DIR"
cat > "$FAKE_AWK_DIR/awk" <<'FAKE_AWK'
#!/bin/sh
exit 127
FAKE_AWK
chmod +x "$FAKE_AWK_DIR/awk"
OUT="$(printf '{"session_id":"sess-l","stop_hook_active":true}' \
  | PATH="$FAKE_AWK_DIR:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "an unusable awk renders as silence, never as the could-not-tell additionalContext" "$OUT"

echo ""
echo "=== M: a fired session with a REAL awk and stop_hook_active=false is the positive control for L ==="
# Without this pairing, L would pass for free if the fix simply silenced this hook
# whenever anything at all goes wrong -- section A already proves the ordinary awk
# path still reports; this repeats that proof with the SAME fixture shape as L (a
# single fired entry) so a reader can compare the two runs directly.

P="$(new_project m)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-m.txt"
OUT="$(run_stop "$P" "sess-m")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "a real awk on the same fixture shape still reports the fired entry" "$OUT" "bridge.md"

echo ""
echo "=== N: a symlink-refused edit marker (#285) renders as its own fourth state, distinct from B and D ==="
# post-tool-hook.sh drops a distinguishable declined-marker when its own symlink guard
# trips on the edit marker's write. This must render differently from B (nothing was
# edited at all) and from D (the state directory itself could not be trusted) -- a
# reader must be able to tell "an edit happened but its evidence was refused" apart
# from both.

P="$(new_project n)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-n.txt"
: > "$(state_of "$P")/edited-declined-sess-n.txt"
OUT="$(run_stop "$P" "sess-n")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "it says an edit could not be confirmed" "$OUT" "could not be confirmed"
if [ "$OUT" = "{}" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the declined-marker state rendered as silence"
else
  PASS=$((PASS + 1)); echo "  PASS: the declined-marker state did not render as silence"
fi
if grep -qF -- "none updated" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the declined-marker state rendered identically to case B (none updated)"
else
  PASS=$((PASS + 1)); echo "  PASS: the declined-marker state text differs from case B"
fi
if grep -qF -- "could not tell whether any entry fired" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the declined-marker state rendered identically to case D (state dir unknown)"
else
  PASS=$((PASS + 1)); echo "  PASS: the declined-marker state text differs from case D"
fi

echo ""
echo "=========================================="
if [ "$D_SKIPPED" -eq 0 ]; then
  echo "Results: $PASS passed, $FAIL failed"
else
  # The same third state this whole file exists to test for, one level up: a section
  # that could not run must not render as a suite that ran clean. `run-all.sh` already
  # gives exit 2 its own bucket -- "SKIPPED suites (could not build their fixtures
  # here)" -- distinct from a run of all-green suites, the same convention
  # test-session-markers.sh/test-marker-degradation.sh/test-hook-tmpfile.sh/
  # test-log-containment.sh already use for a chmod that could not bite (root, or a
  # filesystem without POSIX modes). Followed here rather than invented: D_SKIPPED
  # existed with nothing reading it, which is the identical defect class section D is
  # itself about, one layer up.
  echo "Results: $PASS passed, $FAIL failed, 1 section(s) SKIPPED"
fi
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
[ "$D_SKIPPED" -eq 0 ] || exit 2
exit 0
