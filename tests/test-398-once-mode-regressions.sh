#!/bin/bash
# #398: two regressions #394 (PR #395, merged c9b0573) shipped a few hours before this
# fixture was written, both driven by the v0.10.0 release audit against real hooks.
#
# 1. Every once-mode delivery in a main, non-spawned session wrote its marker line
#    TWICE. #394 added jit_shown_mark(agent_shown_file, hk) beside the existing
#    jit_shown_mark(shown_file, hk); for a plain session the two paths are the SAME
#    file (#394's own changelog leans on this), so one delivery appended the same line
#    twice. Invisible below stop-hook.sh's 500-key cap (the total still comes out
#    exact), visible only past it, where JIT_FIRED_OVERFLOW is incremented before the
#    JIT_FIRED_KEYS dedup runs.
#
# 2. `mode: once` degraded to firing on EVERY call, with an unbounded marker file, when
#    the payload carries no transcript_path. #394 moved the dedup CHECK from `shown` to
#    `agent_shown`, which is only ever populated from agent_shown_file -- and that is ""
#    when jit_agent_key() has nothing usable to key on. The check then reads a
#    permanently empty set while the session-wide mark keeps being written on every
#    call, growing without bound.
#
# tests/test-once-per-agent-394.sh is thorough on the spawn case and compares the new
# behaviour against itself -- neither regression shows up that way, because both need
# v0.9.0's behaviour beside the new one to be visible at all. So every assertion below
# is pinned to what v0.9.0 (aacd6ab, the commit immediately before #394) actually did,
# not only to what #394 intended:
#   - one once-mode delivery in a main session writes exactly ONE marker line.
#   - a once row with a session_id but no transcript_path fires on call 1, then goes
#     quiet on calls 2 and 3 -- session-keyed dedup, matching v0.9.0 exactly. This
#     supersedes test-once-per-agent-394.sh's OWN assertion that this case fires every
#     time; #398 argues that "no dedup" default was worse than falling back to
#     session_id, and this pins the chosen behaviour rather than the one #394 shipped.
#
# jit-drive: assert_contains contains capture assert_eq
#
# Usage: bash tests/test-398-once-mode-regressions.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  [ $# -gt 0 ] && echo "    $*"
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$haystack"; then ok "$desc"; else
    bad "$desc" "expected to contain: $needle" "got: ${haystack:-<EMPTY>}"
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$haystack"; then
    bad "$desc" "should NOT contain: $needle" "got: $haystack"
  else ok "$desc"; fi
}
assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then ok "$desc"; else
    bad "$desc" "expected: $expected" "got: $actual"
  fi
}

build_tree() {
  local d="$1" t idx
  idx=00-index.tsv
  t="$d/.claude/jit-context/tools/00-manual"
  mkdir -p "$t"
  mkdir -p "$d/.claude/jit-context/vocabulary/00-manual" \
    "$d/.claude/jit-context/vocabulary/10-auto" \
    "$d/.claude/jit-context/vocabulary/20-grouped" \
    "$d/.claude/jit-context/vocabulary/30-crosscutting"
  for l in 00-manual 10-auto 20-grouped 30-crosscutting; do : > "$d/.claude/jit-context/vocabulary/$l/$idx"; done
  printf 'Bash\tsrc/Billing\tadv.md\tonce,remind\t\t\n' > "$t/$idx"
  echo "advisory rule body" > "$t/adv.md"
}

run_hook() {
  # $1 = base dir, $2 = session_id, $3 = transcript_path (may be empty -> field omitted)
  local d="$1" sid="$2" tp="$3" out
  if [ -n "$tp" ]; then
    out=$(printf '{"session_id":"%s","transcript_path":"%s","tool_name":"Bash","tool_input":{"command":"cat src/Billing/x.php"}}\n' "$sid" "$tp" \
      | CLAUDE_PROJECT_DIR="$d" bash "$HOOK" 2> /dev/null)
  else
    out=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"cat src/Billing/x.php"}}\n' "$sid" \
      | CLAUDE_PROJECT_DIR="$d" bash "$HOOK" 2> /dev/null)
  fi
  printf '%s' "$out"
}

echo "=== #398 regression 1: one once-mode delivery in a main session writes ONE marker line, not two ==="
T1=$(mktemp -d)
build_tree "$T1"
OUT1=$(run_hook "$T1" "r398a" "/proj/.claude/projects/x/r398a.jsonl")
assert_contains "the call injects" "$OUT1" "advisory rule body"
MARK1="$T1/.claude/jit-context/.discovery/state/vocab-shown-r398a.txt"
if [ -f "$MARK1" ]; then
  N1=$(wc -l < "$MARK1" | tr -d ' ')
else
  N1="<no file>"
fi
# v0.9.0 wrote exactly 1 line here; #394 wrote 2 (the same line appended twice, because
# agent_shown_file and shown_file are the identical path for a main session).
assert_eq "the marker file holds exactly one line, matching v0.9.0, not #394 doubled" "$N1" "1"
rm -rf "$T1"

echo "=== #398 regression 2: a once row with session_id but no transcript_path dedups across calls, matching v0.9.0 ==="
T2=$(mktemp -d)
build_tree "$T2"
OUT1=$(run_hook "$T2" "r398b" "")
assert_contains "call 1 (no transcript_path) injects" "$OUT1" "advisory rule body"
OUT2=$(run_hook "$T2" "r398b" "")
# v0.9.0: silent (session-keyed dedup already saw this key). #394: fired again, and kept
# firing on every subsequent call too, with the marker file growing by one line each time.
assert_not_contains "call 2 (same session_id, still no transcript_path) is deduped, not fired again" "$OUT2" "advisory rule body"
OUT3=$(run_hook "$T2" "r398b" "")
assert_not_contains "call 3 stays deduped too -- not unbounded" "$OUT3" "advisory rule body"
MARK2="$T2/.claude/jit-context/.discovery/state/vocab-shown-r398b.txt"
if [ -f "$MARK2" ]; then
  N2=$(wc -l < "$MARK2" | tr -d ' ')
else
  N2="<no file>"
fi
assert_eq "the marker file holds exactly one line after three calls, matching v0.9.0" "$N2" "1"
rm -rf "$T2"

echo "=== #398 regression 1, past the same path taken by a real spawn: still no double write ==="
# Guards against a fix that special-cases "no transcript_path" but leaves the ordinary
# main-session (transcript_path present, equal to session_id) path still doubling.
T3=$(mktemp -d)
build_tree "$T3"
run_hook "$T3" "r398c" "/proj/.claude/projects/x/r398c.jsonl" > /dev/null
MARK3="$T3/.claude/jit-context/.discovery/state/vocab-shown-r398c.txt"
N3=$(wc -l < "$MARK3" 2> /dev/null | tr -d ' ')
assert_eq "a main session with transcript_path present still writes exactly one line" "${N3:-0}" "1"
rm -rf "$T3"

echo "=== #394's own spawn isolation is not undone by the #398 fix ==="
# The #398 fix must not turn `once` back into pure session-wide dedup: a spawn sharing
# its parent session_id but carrying its own transcript_path still gets its own budget.
T4=$(mktemp -d)
build_tree "$T4"
OUT_MAIN=$(run_hook "$T4" "r398d" "/proj/.claude/projects/x/r398d.jsonl")
assert_contains "the main-lane call injects" "$OUT_MAIN" "advisory rule body"
OUT_SPAWN=$(run_hook "$T4" "r398d" "/proj/.claude/projects/x/subagents/agent-deadbeef01.jsonl")
assert_contains "a spawn sharing the SAME session_id still injects (not suppressed by the main lane)" "$OUT_SPAWN" "advisory rule body"
rm -rf "$T4"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
