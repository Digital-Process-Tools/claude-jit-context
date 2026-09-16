#!/bin/bash
# #394: `mode: once` used to mean "once per session_id" -- and a spawned agent
# inherits its parent's session_id. Measured directly against real Claude Code
# transcripts on disk (not against a jit-context entry in this repo -- there is no
# entry here that discusses this): a spawned agent's own transcript file
# (subagents/agent-<hex>.jsonl) records the SAME sessionId as its parent transcript,
# while carrying its own distinct agentId. One shown set for the whole session meant
# the first agent to trip a `once` rule spent the budget for every spawn behind it,
# silently.
#
# `once` is redefined here to mean once per READER instead: the dedup key is
# transcript_path's basename (jit_agent_key(), common.sh), not session_id. For the
# main session the two values are identical (verified against real transcripts: a
# main session's own hook payload transcript_path basename IS its session_id), so
# this changes nothing there -- tests/test-pre-tool-hook.sh's existing `once` sections
# (#112, #139) already pin that. This file is about the ONE thing that changes: what
# happens when transcript_path diverges from session_id, which only a spawned agent's
# payload ever does.
#
# jit-drive: assert_contains contains capture
#
# Usage: bash tests/test-once-per-agent-394.sh

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
assert_path_contains() {
  local desc="$1" path="$2" needle="$3"
  if [ -f "$path" ] && LC_ALL=C grep -qF -- "$needle" "$path"; then ok "$desc"; else
    bad "$desc" "expected $path to contain: $needle" "got: $([ -f "$path" ] && cat "$path" || echo '<NO FILE>')"
  fi
}
assert_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then bad "$desc" "expected no file at: $path"; else ok "$desc"; fi
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

echo "=== #394: two calls, one session_id, two transcript_path values -- both inject ==="
# THE positive control for the whole feature: this is the assertion that failed before
# the fix (both calls shared session_id's marker file, so the second was suppressed).
T1=$(mktemp -d)
build_tree "$T1"
OUT_MAIN=$(run_hook "$T1" "s394a" "/proj/.claude/projects/x/s394a.jsonl")
assert_contains "the main-lane call injects" "$OUT_MAIN" "advisory rule body"
OUT_SPAWN=$(run_hook "$T1" "s394a" "/proj/.claude/projects/x/subagents/agent-af15dba0843f1839c.jsonl")
assert_contains "a spawn sharing the SAME session_id still injects" "$OUT_SPAWN" "advisory rule body"
# And each reader is still deduped against ITSELF -- this is not "once" turning into
# "remind" for everyone, only the cross-reader suppression is gone.
OUT_SPAWN_AGAIN=$(run_hook "$T1" "s394a" "/proj/.claude/projects/x/subagents/agent-af15dba0843f1839c.jsonl")
assert_not_contains "the SAME spawn calling twice is still deduped" "$OUT_SPAWN_AGAIN" "advisory rule body"
OUT_MAIN_AGAIN=$(run_hook "$T1" "s394a" "/proj/.claude/projects/x/s394a.jsonl")
assert_not_contains "the main lane calling twice is still deduped" "$OUT_MAIN_AGAIN" "advisory rule body"
rm -rf "$T1"

echo "=== #394: main-session transcript_path basename equals session_id -- old behaviour is byte-identical ==="
T2=$(mktemp -d)
build_tree "$T2"
OUT1=$(run_hook "$T2" "s394b" "/proj/.claude/projects/x/s394b.jsonl")
assert_contains "first call of a plain (unspawned) session injects" "$OUT1" "advisory rule body"
OUT2=$(run_hook "$T2" "s394b" "/proj/.claude/projects/x/s394b.jsonl")
assert_not_contains "second call of the same session_id AND same transcript_path is deduped" "$OUT2" "advisory rule body"
rm -rf "$T2"

echo "=== #394: no transcript_path at all -- degrades to firing on every call, like remind ==="
# The stated rule (common.sh, jit_session_key's own precedent): an absent field means NO
# marker and no dedup at all, never a guess. Never falls back to session_id either --
# that would silently reintroduce the exact bug this issue exists to close on any host
# that omits transcript_path.
T3=$(mktemp -d)
build_tree "$T3"
OUT1=$(run_hook "$T3" "s394c" "")
assert_contains "first call with no transcript_path injects" "$OUT1" "advisory rule body"
OUT2=$(run_hook "$T3" "s394c" "")
assert_contains "second call with no transcript_path injects too -- no cross-call dedup" "$OUT2" "advisory rule body"
# session_id IS present here (s394c) -- only transcript_path is missing -- so the
# ORDINARY session-keyed marker still exists; #394 changes nothing about that file.
# What must NOT exist is any SECOND vocab-shown-*.txt: that would mean the once-mode
# check silently fell back onto some other key when transcript_path was unusable,
# which is exactly the guess the stated policy forbids.
STATE_DIR="$T3/.claude/jit-context/.discovery/state"
EXTRA=""
if [ -d "$STATE_DIR" ]; then
  for f in "$STATE_DIR"/vocab-shown-*.txt; do
    [ -f "$f" ] || continue
    case "$f" in
      *"vocab-shown-s394c.txt") continue ;;
      *) EXTRA="$f" ;;
    esac
  done
fi
if [ -n "$EXTRA" ]; then
  bad "no marker beyond the ordinary session one is written when transcript_path is absent" "found: $EXTRA"
else
  ok "no marker beyond the ordinary session one is written when transcript_path is absent"
fi
rm -rf "$T3"

echo "=== #394: transcript_path whose basename carries a character outside the bare-name set -- no marker, never a sanitised guess ==="
T4=$(mktemp -d)
build_tree "$T4"
BAD_TP='/proj/.claude/projects/x/subagents/agent with spaces; rm -rf /.jsonl'
OUT1=$(run_hook "$T4" "s394d" "$BAD_TP")
assert_contains "call with a bad-basename transcript_path still injects (fires, not silently dropped)" "$OUT1" "advisory rule body"
STATE_DIR="$T4/.claude/jit-context/.discovery/state"
BAD_MARKER_FOUND=""
if [ -d "$STATE_DIR" ]; then
  for f in "$STATE_DIR"/vocab-shown-*.txt; do
    [ -f "$f" ] || continue
    case "$f" in
      *"vocab-shown-s394d.txt") continue ;; # the SESSION marker is expected and fine
      *) BAD_MARKER_FOUND="$f" ;;
    esac
  done
fi
if [ -n "$BAD_MARKER_FOUND" ]; then
  bad "no agent marker is written for a bad-basename transcript_path" "found: $BAD_MARKER_FOUND"
else
  ok "no agent marker is written for a bad-basename transcript_path"
fi
# And it does NOT dedup across two calls sharing that same bad transcript_path either --
# the degrade is "no marker", not "a marker under a sanitised name".
OUT2=$(run_hook "$T4" "s394d" "$BAD_TP")
assert_contains "a second call with the SAME bad-basename transcript_path still injects" "$OUT2" "advisory rule body"
rm -rf "$T4"

echo "=== #394: jit_agent_key() itself, both real transcript shapes, driven directly ==="
source "$SCRIPT_DIR/scripts/common.sh"
AK_MAIN=$(awk "$JIT_AWK_JSON"'
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  print jit_agent_key(raw, fs, fe, n)
}
' <<< '{"session_id":"sX","transcript_path":"/h/.claude/projects/p/2541d5ed-05ae-4dbc-b9cd-2dca77b9e6bc.jsonl"}')
assert_contains "a main session transcript basename is used whole" "$AK_MAIN" "2541d5ed-05ae-4dbc-b9cd-2dca77b9e6bc"

AK_SPAWN=$(awk "$JIT_AWK_JSON"'
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  print jit_agent_key(raw, fs, fe, n)
}
' <<< '{"session_id":"sX","transcript_path":"/h/.claude/projects/p/subagents/agent-a0942601ccf5c5a46.jsonl"}')
assert_contains "an agent-<hex> subagent transcript basename is used whole too" "$AK_SPAWN" "agent-a0942601ccf5c5a46"

if [ "$AK_MAIN" != "$AK_SPAWN" ]; then
  ok "the two real shapes draw DIFFERENT keys"
else
  bad "the two real shapes draw DIFFERENT keys" "both resolved to: $AK_MAIN"
fi

AK_WIN=$(awk "$JIT_AWK_JSON"'
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  print jit_agent_key(raw, fs, fe, n)
}
' <<< '{"session_id":"sX","transcript_path":"C:\\Users\\x\\.claude\\projects\\p\\subagents\\agent-b1.jsonl"}')
assert_contains "a Windows-style backslash-separated transcript_path still reduces to the basename" "$AK_WIN" "agent-b1"

echo "=== #394: a SPAWN firing a once-mode entry still records into the SESSION-keyed marker (#389 accounting) ==="
# The commit loop writes the per-agent mark AS WELL AS the ordinary session-keyed one --
# never instead of it -- so stop-hook.sh's own byte total (keyed on session_id alone,
# it never learns about a spawn's own transcript) keeps seeing everything a once-mode
# rule delivered, spawn or no spawn.
T5=$(mktemp -d)
build_tree "$T5"
run_hook "$T5" "s394e" "/proj/.claude/projects/x/subagents/agent-deadbeef01.jsonl" > /dev/null
assert_path_contains "the SESSION vocab marker names the entry the spawn delivered" \
  "$T5/.claude/jit-context/.discovery/state/vocab-shown-s394e.txt" "loc:tools:00-manual:adv.md"
assert_path_contains "the SESSION bytes marker records it too" \
  "$T5/.claude/jit-context/.discovery/state/bytes-shown-s394e.txt" "loc:tools:00-manual:adv.md"
rm -rf "$T5"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
