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
# Both hosts' own (non-alias) signatures present at once -- a real configuration
# (a Codex session launched from inside a Claude Code session inherits the
# parent's CLAUDE_CODE_* vars alongside its own freshly-set CODEX_* ones,
# remember's #463). Registry order decides, deliberately: claude-code is
# listed first in scripts/host.sh.
assert_eq "both signatures present -> claude-code wins (registry order)" "claude-code" \
  "$(run_detect env CLAUDE_CODE_SESSION_ID=abc CODEX_SESSION_ID=xyz)"
# #288 captured all 54 variables of a real Codex PreToolUse hook environment and found
# no CODEX_ variable among them, so the two fixtures that used to sit here
# ("CODEX_SESSION_ID alone -> codex", "CODEX_THREAD_ID alone -> codex") asserted a
# signature that could never fire on a real machine. They are removed rather than
# inverted: there is nothing left to detect codex BY. What replaces them is the
# misdetection fixture in the #289 block below -- the failure that actually happens --
# together with the two envelope-equality assertions that make it cost nothing.
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
assert_eq "codex state is OBSERVED (#288 watched it fire)" "OBSERVED"      "$(run_lookup jit_host_state codex)"
assert_eq "gemini-cli state is UNKNOWN"          "UNKNOWN"                 "$(run_lookup jit_host_state gemini-cli)"
assert_eq "a name with no row is UNKNOWN"        "UNKNOWN"                 "$(run_lookup jit_host_state bogus-host)"
assert_eq "jit_host_detect own miss value is UNKNOWN" "UNKNOWN"            "$(run_lookup jit_host_state unknown)"

assert_eq "claude-code inject envelope is its own shape" "claude-hookSpecificOutput" "$(run_lookup jit_host_inject_envelope claude-code)"
assert_eq "codex inject envelope is Claude Code's own shape (#288)" "claude-hookSpecificOutput" "$(run_lookup jit_host_inject_envelope codex)"
assert_eq "gemini-cli inject envelope is UNKNOWN"     "UNKNOWN"            "$(run_lookup jit_host_inject_envelope gemini-cli)"

# The third state, by name. Every one of these five must NOT read as
# "claude-decision-block" (a false yes) and must NOT read as "unsupported" (a
# false, and much stronger, no) -- "refusal-not-established" is the only
# honest answer for a host whose PreToolUse refusal has never been watched.
assert_eq "claude-code refusal is the one OBSERVED contract" "claude-decision-block"   "$(run_lookup jit_host_refusal_state claude-code)"
assert_eq "codex refusal is the same OBSERVED contract (#288)" "claude-decision-block" "$(run_lookup jit_host_refusal_state codex)"
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
echo "=== #289: the codex row, after #288's live observation ==="
# Every assertion below is grounded in real codex-cli 0.150.1 runs captured for #288,
# not in Codex's documentation and not in remember's observation of its own
# inject-only hooks. Four runs: one passthrough, one {"decision":"block"}, one
# permissionDecision:deny, one additionalContext. Both refusal shapes stopped the call
# ("hook: PreToolUse Blocked", and the command never ran); additionalContext let it
# through, which is correct.
assert_eq "codex honours the same block envelope Claude Code does" \
  "claude-decision-block" "$(run_lookup jit_host_refusal_state codex)"
assert_eq "codex takes the same inject envelope Claude Code does" \
  "claude-hookSpecificOutput" "$(run_lookup jit_host_inject_envelope codex)"

# The two above are what make a misdetection between these hosts harmless: their
# contracts are byte-identical, so nothing emitted can differ. That is the whole
# reason jit_host_detect() is safe to leave best-effort.
assert_eq "claude-code and codex agree on the refusal envelope" \
  "$(run_lookup jit_host_refusal_state claude-code)" "$(run_lookup jit_host_refusal_state codex)"
assert_eq "claude-code and codex agree on the inject envelope" \
  "$(run_lookup jit_host_inject_envelope claude-code)" "$(run_lookup jit_host_inject_envelope codex)"

# gemini-cli is still unobserved and must not have been swept along by #288.
assert_eq "gemini-cli was not swept along -- still not established" \
  "refusal-not-established" "$(run_lookup jit_host_refusal_state gemini-cli)"
assert_eq "gemini-cli was not swept along -- still UNKNOWN" \
  "UNKNOWN" "$(run_lookup jit_host_state gemini-cli)"

echo ""
echo "=== #289: hook-not-trusted is its own state, and is not permission ==="
# Observed for #288: a Codex hook with no trusted_hash in ~/.codex/config.toml is
# silently skipped -- no warning, no non-zero exit, no transcript line, the tool call
# simply proceeds. remember's four hooks firing in that same run is the positive
# control, so the silence was trust and only trust. That is a THIRD thing:
# "unsupported" says the host cannot block, "refusal-not-established" says nobody
# checked, and this says the host can, we asked, and it declined to run us.
assert_eq "hook-not-trusted is recognised and returned as itself" \
  "hook-not-trusted" "$(run_lookup jit_host_refusal_state_for_envelope hook-not-trusted)"
assert_eq "an unrecognised envelope normalises to the safe third state" \
  "refusal-not-established" "$(run_lookup jit_host_refusal_state_for_envelope bogus-envelope)"
assert_eq "a refusal is honoured for claude-decision-block" \
  "yes" "$(run_lookup jit_host_refusal_honoured claude-decision-block)"
assert_eq "a refusal is NOT honoured when the hook is not trusted" \
  "no" "$(run_lookup jit_host_refusal_honoured hook-not-trusted)"
assert_eq "a refusal is NOT honoured when unsupported" \
  "no" "$(run_lookup jit_host_refusal_honoured unsupported)"
assert_eq "a refusal is NOT honoured when not established" \
  "no" "$(run_lookup jit_host_refusal_honoured refusal-not-established)"

echo ""
echo "=== #289: detection is best-effort, and the registry says so ==="
# Captured live for #288: a Codex hook launched from inside a Claude Code shell
# inherits CLAUDE_CODE_ENTRYPOINT and CLAUDE_CODE_SESSION_ID from its parent, so
# detection answers claude-code for a genuine Codex hook. One agent CLI launching
# another is the normal way this plugin gets exercised, and no environment variable
# survives it -- remember reached the same place from the other side, its own
# detect_host() ending with zero production consumers.
assert_eq "an inherited CLAUDE_CODE_ENTRYPOINT makes detection answer claude-code under Codex" \
  "claude-code" "$(run_detect CLAUDE_CODE_ENTRYPOINT=cli PLUGIN_ROOT=/x/.codex/plugins/cache/mk/p/0.0.1)"
assert_eq "detection is documented as best-effort" \
  "yes" "$(grep -q 'BEST-EFFORT' "$HOST_SH" && echo yes || echo no)"
assert_eq "the codex row no longer claims a signature that cannot fire" \
  "no" "$(grep -q '^codex|CODEX_' "$HOST_SH" && echo yes || echo no)"

echo ""
echo "=== #289: the Codex install layer ships, and matches the Claude one ==="
CODEX_MANIFEST="$REPO/.codex-plugin/plugin.json"
CODEX_HOOKS="$REPO/hooks/hooks.codex.json"
CLAUDE_HOOKS="$REPO/hooks/hooks.json"
CLAUDE_MANIFEST="$REPO/.claude-plugin/plugin.json"
MARKETPLACE="$REPO/.agents/plugins/marketplace.json"
assert_eq "a Codex plugin manifest ships"    "yes" "$( [ -r "$CODEX_MANIFEST" ] && echo yes || echo no )"
assert_eq "a Codex hooks manifest ships"     "yes" "$( [ -r "$CODEX_HOOKS" ] && echo yes || echo no )"
assert_eq "a self-referential marketplace entry ships" "yes" "$( [ -r "$MARKETPLACE" ] && echo yes || echo no )"
assert_eq "the Codex manifest points at the Codex hooks file, relatively" \
  "yes" "$(grep -q '"\./hooks/hooks\.codex\.json"' "$CODEX_MANIFEST" 2>/dev/null && echo yes || echo no)"
assert_eq "the Codex hooks manifest uses PLUGIN_ROOT, not CLAUDE_PLUGIN_ROOT" \
  "no" "$(grep -q 'CLAUDE_PLUGIN_ROOT' "$CODEX_HOOKS" 2>/dev/null && echo yes || echo no)"

# One plugin, one version. remember's own test_codex_manifest_410.py carries this
# assertion for the same reason: a second manifest that drifts from the first ships
# stale metadata silently.
assert_eq "the two manifests declare the same version" \
  "$(grep -o '"version"[^,]*' "$CLAUDE_MANIFEST" | head -1)" \
  "$(grep -o '"version"[^,]*' "$CODEX_MANIFEST" | head -1)"

# Every script one manifest binds, the other must bind. A hook that ships on one host
# and silently not the other is this repo's own defect class wearing a manifest.
for _s in session-start-hook pre-prompt-hook pre-tool-hook pre-path-hook post-tool-hook stop-hook; do
  assert_eq "hooks.codex.json binds $_s.sh" \
    "yes" "$(grep -q "$_s\.sh" "$CODEX_HOOKS" 2>/dev/null && echo yes || echo no)"
  assert_eq "hooks.json binds $_s.sh (positive control)" \
    "yes" "$(grep -q "$_s\.sh" "$CLAUDE_HOOKS" 2>/dev/null && echo yes || echo no)"
done

# Codex documents exactly eleven lifecycle events. A manifest naming one it does not
# document registers nothing, silently -- the same shape as an untrusted hook.
CODEX_DOCUMENTED='SessionStart SessionEnd SubagentStart SubagentStop PreToolUse PostToolUse PermissionRequest PreCompact PostCompact UserPromptSubmit Stop'
_undocumented=""
for _ev in $(grep -oE '^    "[A-Za-z]+": \[' "$CODEX_HOOKS" | tr -d ' ":[' ); do
  case " $CODEX_DOCUMENTED " in
    *" $_ev "*) ;;
    *) _undocumented="$_undocumented $_ev" ;;
  esac
done
assert_eq "hooks.codex.json names only events Codex documents" "" "$_undocumented"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
