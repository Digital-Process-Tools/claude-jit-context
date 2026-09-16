#!/bin/bash
# Tests for #403: the UNCAPTURED awk path (jit_awk_capture()'s `[ -z "$f" ]` branch,
# common.sh -- TMPDIR unwritable, no scratch file to capture through) still failed open.
#
# #397/#400 fixed the CAPTURED path: a SIGSEGV awk (exit 139, #393's own measured
# mechanism) is caught because the exit status of "$@" > "$f" is read and the file's
# content inspected before anything is printed. The uncaptured branch never had either:
# it ran "LC_ALL=C "$@"" straight to real stdout and returned 0 unconditionally, so a
# crash there printed 0 bytes and the hook still exited 0 -- a `mode: block` rule that
# does not block. #403 is that gap.
#
# grep -n uncaptured scripts/*.sh tests/*.sh docs/*.md returned five hits, all in
# scripts/, before this file existed: nothing tested this path at all.
#
# Both directions, on the SAME path (unwritable TMPDIR), because the point is that the
# degrade contract (rules still fire when TMPDIR is gone -- tests/test-hook-tmpfile.sh
# section C, predating #397) and the crash-refusal contract (#397) must BOTH hold on
# this one corner at once:
#   * healthy awk, unwritable TMPDIR -> the entry is still delivered, the rule still
#     decides (the positive control, and it runs FIRST -- an unwritable TMPDIR that
#     silently broke rule delivery would make every assertion below pass for the wrong
#     reason: a hook that injects/blocks nothing either way).
#   * crashed awk, unwritable TMPDIR -> refuses on pre-tool-hook.sh (the one hook with a
#     `mode: block` decision to fail closed with), degrades over systemMessage without a
#     new decision field on the other two, and every case is EXACTLY one JSON value on
#     stdout -- never zero (the #403 bug), never two (the #397 self-review class:
#     test-marker-degradation.sh section D was found THIS MORNING to be a false pass
#     because it matched a substring the fabricated crash message also happened to
#     contain, so assert_single_valid_json below counts decoded objects, the same
#     discipline test-awk-crash-397.sh already uses, rather than grepping for one).
#
# If this host's shell cannot make a shimmed "awk" exit 139 via kill -SEGV $$, OR cannot
# make a directory genuinely unwritable to this process (running as root, or a
# filesystem without POSIX modes), the positive control cannot be built at all -- SKIPPED
# below, exit 2, nothing else runs. Both preconditions are checked before anything else,
# because a script silently skipping its OWN positive control is the shape this suite's
# whole purpose is to catch one level up.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# --- Precondition 1: a shimmed awk can actually be made to exit 139 here -----------
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/awk" << 'SHIMEOF'
#!/bin/sh
kill -SEGV $$
SHIMEOF
chmod +x "$SHIM_DIR/awk"
PATH="$SHIM_DIR:$PATH" awk 'BEGIN { print "unreachable" }' > /dev/null 2>&1
PROBE_RC=$?
if [ "$PROBE_RC" -ne 139 ]; then
  echo "SKIPPED: this host's shell cannot make a shimmed 'awk' exit 139 via kill -SEGV \$\$" >&2
  echo "         (got exit $PROBE_RC instead) -- #403's crash-handling assertions are UNTESTED here." >&2
  echo "         Nothing else in this suite ran." >&2
  rm -rf "$SHIM_DIR"
  exit 2
fi

# --- Precondition 2: a directory can be made genuinely unwritable to this process ---
UNWRITABLE_TMPDIR=$(mktemp -d)/notmp
mkdir -p "$UNWRITABLE_TMPDIR"
chmod 555 "$UNWRITABLE_TMPDIR" 2> /dev/null
if [ -w "$UNWRITABLE_TMPDIR" ]; then
  echo "SKIPPED: chmod did not remove write permission on $UNWRITABLE_TMPDIR here" >&2
  echo "         (running as root, or a filesystem without POSIX modes) -- #403's" >&2
  echo "         whole subject (an unwritable \$TMPDIR) cannot be built on this host." >&2
  echo "         Nothing else in this suite ran." >&2
  rm -rf "$SHIM_DIR"
  chmod 755 "$UNWRITABLE_TMPDIR" 2> /dev/null
  rm -rf "$(dirname "$UNWRITABLE_TMPDIR")"
  exit 2
fi

# --- Fixture: one tree, all three dimensions, reused by every hook below ---
TEST_DIR=$(mktemp -d)
IDX="00-index.tsv"
TOOLS_DIR="$TEST_DIR/.claude/jit-context/tools/00-manual"
VOCAB_DIR="$TEST_DIR/.claude/jit-context/vocabulary"
PATHS_DIR="$TEST_DIR/.claude/jit-context/paths/00-manual"
mkdir -p "$TOOLS_DIR" "$PATHS_DIR"
mkdir -p "$VOCAB_DIR/00-manual" "$VOCAB_DIR/10-auto" "$VOCAB_DIR/20-grouped" "$VOCAB_DIR/30-crosscutting"

printf 'Bash\trmrfxyz403\tdeny403.md\tblock\t\t\n' > "$TOOLS_DIR/$IDX"
echo "deny body 403" > "$TOOLS_DIR/deny403.md"
printf 'hello403\thello403.md\n' > "$VOCAB_DIR/00-manual/$IDX"
echo "hello vocab 403" > "$VOCAB_DIR/00-manual/hello403.md"
for l in 10-auto 20-grouped 30-crosscutting; do : > "$VOCAB_DIR/$l/$IDX"; done
: > "$PATHS_DIR/$IDX"

# jit-drive: assert_has contains capture
# jit-drive: assert_lacks not_contains capture
# jit-drive: none -- assert_single_valid_json counts DECODED json objects (must equal
#   exactly one), a semantic this harness's contains/not_contains vocabulary does not
#   model -- test-awk-crash-397.sh already carries this same exemption for the
#   byte-identical helper.
# jit-drive: none -- assert_nonempty checks for the presence of any output at all; there
#   is no needle to drive it against.

# --- Helpers (same shapes as tests/test-awk-crash-397.sh) ---------------------------
assert_has() {
  local desc="$1" output="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to find: $needle"
    echo "    got: ${output:0:300}"
  fi
}
assert_lacks() {
  local desc="$1" output="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $needle"
    echo "    got: ${output:0:300}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}
# Counts DECODED json objects, not a substring -- test-marker-degradation.sh section D
# was measured this morning to be a false pass because it matched a substring the
# fabricated crash message also contained. This is the discriminating check.
assert_single_valid_json() {
  local desc="$1" output="$2"
  if ! command -v python3 > /dev/null 2>&1; then
    echo "  SKIP (no python3 on this host): $desc"
    return
  fi
  if printf '%s' "$output" | python3 -c '
import sys, json
data = sys.stdin.read().strip()
dec = json.JSONDecoder()
idx = 0
n = 0
while idx < len(data):
    obj, end = dec.raw_decode(data, idx)
    n += 1
    idx = end
    while idx < len(data) and data[idx].isspace():
        idx += 1
if n != 1:
    sys.exit(1)
' 2> /dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected exactly one valid JSON object"
    echo "    got: ${output:0:300}"
  fi
}
assert_nonempty() {
  local desc="$1" output="$2"
  if [ -n "$output" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected non-empty stdout, got nothing"
  fi
}

echo "=== pre-tool-hook.sh: unwritable TMPDIR, healthy awk -- the positive control (#403) ==="

TOOL_HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"

CONTROL_OUT=$(printf '{"session_id":"s403a","transcript_path":"/tmp/s403a.jsonl","tool_name":"Bash","tool_input":{"command":"rmrfxyz403 now"}}\n' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" TMPDIR="$UNWRITABLE_TMPDIR" bash "$TOOL_HOOK" 2> /dev/null)
assert_nonempty "unwritable TMPDIR alone does not go silent" "$CONTROL_OUT"
assert_has "the entry is still delivered -- the rule still decides" "$CONTROL_OUT" '"decision":"block"'
assert_has "and carries the rule's own reason" "$CONTROL_OUT" "deny body 403"
assert_single_valid_json "the control reply is exactly one valid JSON object" "$CONTROL_OUT"

echo "=== pre-tool-hook.sh: unwritable TMPDIR + crashed awk -- refuses, not permits (#403) ==="

CRASH_OUT=$(printf '{"session_id":"s403b","transcript_path":"/tmp/s403b.jsonl","tool_name":"Bash","tool_input":{"command":"rmrfxyz403 now"}}\n' \
  | PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" TMPDIR="$UNWRITABLE_TMPDIR" bash "$TOOL_HOOK" 2> /dev/null)
assert_nonempty "the #403 bug: a crashed uncaptured awk must not print zero bytes" "$CRASH_OUT"
assert_has "a crashed awk fails CLOSED, not open" "$CRASH_OUT" '"decision":"block"'
assert_has "and names the crash rather than staying quiet" "$CRASH_OUT" "could not evaluate"
assert_lacks "the crash reason is not the rule's own body -- no rule ran" "$CRASH_OUT" "deny body 403"
assert_single_valid_json "the crash reply is exactly one valid JSON object, not zero or two" "$CRASH_OUT"

echo "=== pre-prompt-hook.sh: unwritable TMPDIR -- both arms (#403) ==="

PROMPT_HOOK="$SCRIPT_DIR/scripts/pre-prompt-hook.sh"

CONTROL_OUT=$(printf '{"session_id":"s403c","transcript_path":"/tmp/s403c.jsonl","prompt":"hello403 there"}\n' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" TMPDIR="$UNWRITABLE_TMPDIR" bash "$PROMPT_HOOK" 2> /dev/null)
assert_has "control: unwritable TMPDIR, healthy awk still injects" "$CONTROL_OUT" "hello vocab 403"
assert_single_valid_json "control reply is exactly one valid JSON object" "$CONTROL_OUT"

CRASH_OUT=$(printf '{"session_id":"s403d","transcript_path":"/tmp/s403d.jsonl","prompt":"hello403 there"}\n' \
  | PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" TMPDIR="$UNWRITABLE_TMPDIR" bash "$PROMPT_HOOK" 2> /dev/null)
assert_nonempty "the #403 bug: a crashed uncaptured awk must not print zero bytes" "$CRASH_OUT"
assert_has "a crashed awk speaks over systemMessage instead of staying quiet" "$CRASH_OUT" '"systemMessage"'
assert_lacks "never invents a decision field this hook has never had" "$CRASH_OUT" '"decision"'
assert_lacks "no vocabulary body reaches the reply -- no rule ran" "$CRASH_OUT" "hello vocab 403"
assert_single_valid_json "the crash reply is exactly one valid JSON object, not zero or two" "$CRASH_OUT"

echo "=== pre-path-hook.sh: unwritable TMPDIR -- both arms (#403) ==="

PATH_HOOK="$SCRIPT_DIR/scripts/pre-path-hook.sh"

CONTROL_OUT=$(printf '{"session_id":"s403e","transcript_path":"/tmp/s403e.jsonl","tool_name":"Bash","tool_input":{"command":"grep -r x deny403.md"}}\n' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" TMPDIR="$UNWRITABLE_TMPDIR" bash "$PATH_HOOK" 2> /dev/null)
assert_nonempty "control: unwritable TMPDIR alone does not go silent" "$CONTROL_OUT"
assert_single_valid_json "control reply is exactly one valid JSON object" "$CONTROL_OUT"

CRASH_OUT=$(printf '{"session_id":"s403f","transcript_path":"/tmp/s403f.jsonl","tool_name":"Bash","tool_input":{"command":"grep -r x deny403.md"}}\n' \
  | PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" TMPDIR="$UNWRITABLE_TMPDIR" bash "$PATH_HOOK" 2> /dev/null)
assert_nonempty "the #403 bug: a crashed uncaptured awk must not print zero bytes" "$CRASH_OUT"
assert_has "a crashed awk speaks over systemMessage instead of staying quiet" "$CRASH_OUT" '"systemMessage"'
assert_lacks "never invents a decision field this hook has never had" "$CRASH_OUT" '"decision"'
assert_single_valid_json "the crash reply is exactly one valid JSON object, not zero or two" "$CRASH_OUT"

rm -rf "$SHIM_DIR" "$TEST_DIR"
chmod 755 "$UNWRITABLE_TMPDIR" 2> /dev/null
rm -rf "$(dirname "$UNWRITABLE_TMPDIR")"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
