#!/bin/bash
# Tests for scripts/host.sh -- the host descriptor registry (#252).
#
# What this suite is really guarding: the THIRD STATE. jit_host_detect(),
# jit_host_state() and jit_host_refusal_state() must never guess a host or a
# contract into existence -- an unrecognised host, a host with no row, or a row
# whose state is not OBSERVED must all read as "not established", distinct from
# both "yes" and "no". A registry that quietly defaulted an unknown host to
# claude-code's contract is the exact defect #252 opens with: a forbid: rule
# reading as enforced on a host nobody watched refuse anything.
#
# Also guarded here: the drift between JIT_AWK_ENVELOPE (scripts/common.sh) and
# the JSON shapes the hooks still hand-roll with their own printf. That
# fragment is not wired into any hook yet -- see its own header comment -- so
# nothing else would notice the two drifting apart.
#
# Usage: bash tests/test-host-registry.sh
#
# jit-drive: none -- assert_eq compares two plain strings (host names, states, envelope
# identifiers), not hook output; there is no payload to make long. assert_literal_in
# checks two candidate literal substrings against a whole SOURCE FILE (a hook or
# common.sh itself), not a captured hook payload -- the drift guard this suite exists
# for is about the plugin's own source text, which is outside what path-arg/capture
# describe.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST_SH="$REPO/scripts/host.sh"
COMMON_SH="$REPO/scripts/common.sh"
PASS=0
FAIL=0

if [ ! -r "$HOST_SH" ]; then
  echo "  FAIL: scripts/host.sh does not exist or is not readable -- nothing below can run"
  exit 1
fi

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    wanted: $want"
    echo "    got:    $got"
  fi
}

# Every call below runs in a CLEAN environment (env -i) plus exactly the
# variables the case sets -- PATH is kept so bash itself can start, nothing
# else leaks in from this suite's own process (which is itself a real Claude
# Code session and carries CLAUDE_CODE_ENTRYPOINT for real -- proven below,
# not assumed, since trusting that without a check is exactly the vacuous-pass
# shape paths/00-manual/tests.md warns about elsewhere in this tree).
run_detect() {
  env -i PATH="$PATH" "$@" bash -c 'source "'"$HOST_SH"'" >/dev/null 2>&1; jit_host_detect'
}

echo "=== control: this suite can drive host.sh at all ==="
ctrl=$(run_detect)
if [ "$ctrl" != "unknown" ]; then
  echo "  FAIL: a clean environment must detect unknown -- got: $ctrl"
  echo "        every assertion below would be built on a harness that cannot answer cleanly"
  exit 1
fi
PASS=$((PASS + 1)); echo "  PASS: a clean environment detects unknown"

echo ""
echo "=== jit_host_detect: signature vars, and only signature vars, decide the host ==="
assert_eq "no signature at all -> unknown, never guessed" "unknown" "$(run_detect)"
assert_eq "an unrelated var set -> still unknown" "unknown" "$(run_detect env FOO_BAR_252=1)"
assert_eq "CLAUDE_CODE_ENTRYPOINT alone -> claude-code" "claude-code" "$(run_detect env CLAUDE_CODE_ENTRYPOINT=cli)"
assert_eq "CLAUDE_CODE_SESSION_ID alone -> claude-code" "claude-code" "$(run_detect env CLAUDE_CODE_SESSION_ID=abc)"
# CLAUDE_PLUGIN_ROOT / CLAUDE_PROJECT_DIR must NOT be signatures: they are the
# project-dir/plugin-root columns, and Codex sets CLAUDE_PLUGIN_ROOT too, as a
# compatibility alias (remember's own host.py docstring) -- a variable a second
# host also sets can never be what tells the two apart.
assert_eq "CLAUDE_PROJECT_DIR alone -> still unknown, not a signature" "unknown" "$(run_detect env CLAUDE_PROJECT_DIR=/tmp/x)"
assert_eq "CLAUDE_PLUGIN_ROOT alone -> still unknown, not a signature" "unknown" "$(run_detect env CLAUDE_PLUGIN_ROOT=/tmp/x)"
assert_eq "CODEX_SESSION_ID alone -> codex" "codex" "$(run_detect env CODEX_SESSION_ID=xyz)"
assert_eq "CODEX_THREAD_ID alone -> codex" "codex" "$(run_detect env CODEX_THREAD_ID=xyz)"
# Both hosts' own (non-alias) signatures present at once -- a real configuration
# (a Codex session launched from inside a Claude Code session inherits the
# parent's CLAUDE_CODE_* vars alongside its own freshly-set CODEX_* ones,
# remember's #463). Registry order decides, deliberately: claude-code is
# listed first in scripts/host.sh.
assert_eq "both signatures present -> claude-code wins (registry order)" "claude-code" \
  "$(run_detect env CLAUDE_CODE_SESSION_ID=abc CODEX_SESSION_ID=xyz)"
# Gemini CLI carries no signature at all -- it is never the RESULT of
# detection, by design (scripts/host.sh's own comment on this row, matching
# remember's registry). Nothing to assert it detects AS; the case that matters
# is that nothing spurious detects as gemini-cli, which no fixture here can do.

echo ""
echo "=== jit_host_state / jit_host_inject_envelope / jit_host_refusal_state: three answers, never two ==="
run_lookup() {
  env -i PATH="$PATH" bash -c 'source "'"$HOST_SH"'" >/dev/null 2>&1; '"$1"' "'"$2"'"'
}
assert_eq "claude-code state is OBSERVED"        "OBSERVED"                "$(run_lookup jit_host_state claude-code)"
assert_eq "codex state is UNKNOWN"               "UNKNOWN"                 "$(run_lookup jit_host_state codex)"
assert_eq "gemini-cli state is UNKNOWN"          "UNKNOWN"                 "$(run_lookup jit_host_state gemini-cli)"
assert_eq "a name with no row is UNKNOWN"        "UNKNOWN"                 "$(run_lookup jit_host_state bogus-host)"
assert_eq "jit_host_detect own miss value is UNKNOWN" "UNKNOWN"            "$(run_lookup jit_host_state unknown)"

assert_eq "claude-code inject envelope is its own shape" "claude-hookSpecificOutput" "$(run_lookup jit_host_inject_envelope claude-code)"
assert_eq "codex inject envelope is UNKNOWN -- not observed for THIS plugin" "UNKNOWN" "$(run_lookup jit_host_inject_envelope codex)"
assert_eq "gemini-cli inject envelope is UNKNOWN"     "UNKNOWN"            "$(run_lookup jit_host_inject_envelope gemini-cli)"

# The third state, by name. Every one of these five must NOT read as
# "claude-decision-block" (a false yes) and must NOT read as "unsupported" (a
# false, and much stronger, no) -- "refusal-not-established" is the only
# honest answer for a host whose PreToolUse refusal has never been watched.
assert_eq "claude-code refusal is the one OBSERVED contract" "claude-decision-block"   "$(run_lookup jit_host_refusal_state claude-code)"
assert_eq "codex refusal is not-established, not a guess"    "refusal-not-established" "$(run_lookup jit_host_refusal_state codex)"
assert_eq "gemini-cli refusal is not-established"            "refusal-not-established" "$(run_lookup jit_host_refusal_state gemini-cli)"
assert_eq "an unrecognised host is not-established"          "refusal-not-established" "$(run_lookup jit_host_refusal_state bogus-host)"
assert_eq "the empty string is not-established"              "refusal-not-established" "$(env -i PATH="$PATH" bash -c 'source "'"$HOST_SH"'" >/dev/null 2>&1; jit_host_refusal_state ""')"

echo ""
echo "=== common.sh sources host.sh and exports JIT_HOST / JIT_HOST_REFUSAL_STATE (#252) ==="
export_probe() {
  env -i PATH="$PATH" "$@" bash -c 'source "'"$COMMON_SH"'" >/dev/null 2>&1; printf "%s|%s" "$JIT_HOST" "$JIT_HOST_REFUSAL_STATE"'
}
assert_eq "a clean host, sourced through common.sh" "unknown|refusal-not-established" "$(export_probe)"
assert_eq "a real Claude Code signature, sourced through common.sh" "claude-code|claude-decision-block" \
  "$(export_probe env CLAUDE_CODE_ENTRYPOINT=cli)"

echo ""
echo "=== drift guard: JIT_AWK_ENVELOPE matches the shape the hooks still hand-roll (#252) ==="
# JIT_AWK_ENVELOPE is infrastructure, not yet wired into any hook (see its own
# comment in common.sh) -- so nothing calls both sides of a real comparison
# yet. This compares the literal, fixed JSON text around each shape's one
# interpolated field, which survives a variable rename on either side and
# still catches a key rename, a re-ordering, or the two quietly diverging
# while nothing wires them together to notice.
# Two spellings of the same skeleton: pre-tool-hook.sh, pre-prompt-hook.sh and
# pre-path-hook.sh build their printf format inside a DOUBLE-quoted shell
# string, so a literal JSON quote is written as a backslash-quote pair --
# session-start-hook.sh builds the same shape inside a SINGLE-quoted printf
# format, where a literal JSON quote needs no shell escaping at all. Either
# spelling counts: this guard is about the JSON shape drifting, not about
# which shell quoting a hook happens to use.
assert_literal_in() {
  local desc="$1" needle_escaped="$2" needle_plain="$3" file="$4" found=0
  grep -qF -- "$needle_escaped" "$file" 2>/dev/null && found=1
  grep -qF -- "$needle_plain" "$file" 2>/dev/null && found=1
  if [ "$found" = 1 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to find, escaped or plain, in $file:"
    echo "    $needle_escaped"
    echo "    $needle_plain"
  fi
}

BLOCK_SKELETON_ESC='{\"decision\":\"block\",\"reason\":\"'
BLOCK_SKELETON_PLAIN='{"decision":"block","reason":"'
assert_literal_in "common.sh envelope carries the block skeleton" "$BLOCK_SKELETON_ESC" "$BLOCK_SKELETON_PLAIN" "$COMMON_SH"
assert_literal_in "pre-tool-hook.sh still hand-rolls the identical block skeleton" \
  "$BLOCK_SKELETON_ESC" "$BLOCK_SKELETON_PLAIN" "$REPO/scripts/pre-tool-hook.sh"

INJECT_HEAD_ESC='{\"hookSpecificOutput\":{\"hookEventName\":\"'
INJECT_HEAD_PLAIN='{"hookSpecificOutput":{"hookEventName":"'
INJECT_TAIL_ESC='\",\"additionalContext\":\"'
INJECT_TAIL_PLAIN='","additionalContext":"'
assert_literal_in "common.sh envelope carries the inject head" "$INJECT_HEAD_ESC" "$INJECT_HEAD_PLAIN" "$COMMON_SH"
assert_literal_in "common.sh envelope carries the inject tail" "$INJECT_TAIL_ESC" "$INJECT_TAIL_PLAIN" "$COMMON_SH"
for hook in pre-tool-hook.sh pre-prompt-hook.sh pre-path-hook.sh session-start-hook.sh; do
  assert_literal_in "$hook still hand-rolls the identical inject head" \
    "$INJECT_HEAD_ESC" "$INJECT_HEAD_PLAIN" "$REPO/scripts/$hook"
  assert_literal_in "$hook still hand-rolls the identical inject tail" \
    "$INJECT_TAIL_ESC" "$INJECT_TAIL_PLAIN" "$REPO/scripts/$hook"
done

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
