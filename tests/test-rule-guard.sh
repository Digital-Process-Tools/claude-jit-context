#!/bin/bash
# Tests for the match-pattern guard shared by pre-tool-hook.sh and pre-path-hook.sh.
#
# Two distinct failures, both of which make a rule read as enforced while it is not:
#   1. an undefined escape — awk drops it, the pattern matches nothing, and exits 0
#   2. a malformed pattern (a[b) — awk exits 2 mid-scan, killing EVERY rule in the file
#
# Usage: bash tests/test-rule-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL_HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"
PATH_HOOK="$SCRIPT_DIR/scripts/pre-path-hook.sh"
PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
BASE="$TEST_DIR/.claude/jit-context"
TOOLS_DIR="$BASE/tools/00-manual"
PATHS_DIR="$BASE/paths"
mkdir -p "$TOOLS_DIR"
for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
  mkdir -p "$PATHS_DIR/$l" "$BASE/vocabulary/$l"
  : > "$PATHS_DIR/$l/00-index.tsv"
  : > "$BASE/vocabulary/$l/00-index.tsv"
done

# Tool index: a dead-escape block rule, a valid rule, a fatal rule, and one that uses
# the single escape awk really does honour. The valid rule sits BEFORE the fatal one on
# purpose: awk dies mid-scan, so even a rule that already matched never reaches the END
# block that prints the JSON.
{
  printf 'Bash\t~gh\\s+pr\tdead-escape.md\tblock\t\t\n'
  printf 'Bash\tgit push\tgood.md\tremind\t\t\n'
  printf 'Bash\t~a[b\tfatal.md\tremind\t\t\n'
  printf 'Bash\t~(^|[;&|\\n] *)zork\tnewline-ok.md\tremind\t\t\n'
  printf 'Bash\t~quux)ping\tparen-literal.md\tremind\t\t\n'
  printf 'Bash\t~zap[[:alnum:]\tclass-fatal.md\tremind\t\t\n'
  # #116. A backslash before a NON-ASCII byte. LC_ALL=C is pinned on the matcher, so the
  # guard's substr() sees one byte -- the lead byte of an accented character is never
  # [[:alnum:]], so this walked straight past the escape test and reached match().
  printf 'Bash\t~\\\xc3\xa9x\tnonascii-escape.md\tblock\t\t\n'
  # Its positive control, one row later: the SAME character with no backslash in front of
  # it. Without this row, "the escaped one does not fire" is satisfied by a matcher that
  # cannot handle the byte at all, and the assertion below would be about nothing.
  printf 'Bash\t~\xc3\xa9y\tnonascii-literal.md\tremind\t\t\n'
} > "$TOOLS_DIR/00-index.tsv"

echo "dead escape rule body" > "$TOOLS_DIR/dead-escape.md"
echo "good rule body" > "$TOOLS_DIR/good.md"
echo "fatal rule body" > "$TOOLS_DIR/fatal.md"
echo "newline anchored rule body" > "$TOOLS_DIR/newline-ok.md"
echo "paren literal rule body" > "$TOOLS_DIR/paren-literal.md"
echo "class fatal rule body" > "$TOOLS_DIR/class-fatal.md"
echo "nonascii escape rule body" > "$TOOLS_DIR/nonascii-escape.md"
echo "nonascii literal rule body" > "$TOOLS_DIR/nonascii-literal.md"

{
  printf 'Billing/\tbilling.md\n'
  printf 'src/[a\tpath-fatal.md\n'
  printf 'docs/\\s.*\\.md$\tpath-dead.md\n'
} > "$PATHS_DIR/00-manual/00-index.tsv"
echo "billing path body" > "$PATHS_DIR/00-manual/billing.md"
echo "fatal path body" > "$PATHS_DIR/00-manual/path-fatal.md"
echo "dead path body" > "$PATHS_DIR/00-manual/path-dead.md"

run_tool() { echo "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2>/dev/null; }
# The same call with stderr KEPT, written to a file. A hook that exits 0 having printed a
# diagnostic into a stranger's session has still failed, and 2>/dev/null above cannot see
# that -- which is how #116 lived under a green suite.
STDERR_FILE="$TEST_DIR/hook-stderr.txt"
run_tool_keep_stderr() {
  # $1 payload, $2 optional directory to put first on PATH (an awk shim)
  : > "$STDERR_FILE"
  if [ -n "${2:-}" ]; then
    echo "$1" | PATH="$2:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2>"$STDERR_FILE"
  else
    echo "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2>"$STDERR_FILE"
  fi
}
run_path() { echo "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2>/dev/null; }

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | cut -c1-300)"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: $(echo "$output" | cut -c1-300)"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

echo "=== a malformed pattern does not silence the rest of the file ==="
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')
assert_contains "valid rule still fires past a fatal row" "$OUT" "good rule body"
assert_not_contains "fatal rule body is not injected" "$OUT" "fatal rule body"

echo ""
echo "=== the refusal is reported, not silent ==="
assert_contains "names the count" "$OUT" "could not be evaluated"
# By POSITION, not by the file-name column. That column is attacker-controlled free text in
# a committed index -- #35 -- and the notice fires with no rule matched, so quoting it back
# was a prompt-injection channel needing no trigger. The name an author needs is in
# hooks.log and in jit-dry-run.sh, both of which still carry it.
assert_contains "locates the fatal rule by row" "$OUT" "tools/00-manual row 3"
assert_contains "locates the dead-escape rule by row" "$OUT" "tools/00-manual row 1"
assert_not_contains "and does not quote the file-name column back" "$OUT" "fatal.md"
assert_not_contains "nor the dead-escape one" "$OUT" "dead-escape.md"
assert_contains "names the construct" "$OUT" "\\s"
assert_contains "points at the dry-run" "$OUT" "jit-dry-run.sh"

echo ""
echo "=== a dead block rule does not read as enforced ==="
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}')
assert_not_contains "dead escape rule does not block" "$OUT" "decision"
assert_contains "and says so, by row" "$OUT" "tools/00-manual row 1"

echo ""
echo "=== the one escape awk honours keeps working: rules anchor on it ==="
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"zork --now"}}')
assert_contains "newline-anchored rule fires" "$OUT" "newline anchored rule body"
assert_not_contains "newline-anchored rule is not refused" "$OUT" "tools/00-manual row 4"

echo ""
echo "=== an unmatched ) is a literal in an ERE, and must NOT be refused ==="
# A false positive here is worse than the bug: it kills a rule that works today.
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"quux)ping now"}}')
assert_contains "literal-paren rule fires" "$OUT" "paren literal rule body"
assert_not_contains "and is not refused" "$OUT" "tools/00-manual row 5"

echo ""
echo "=== a POSIX class does not close the bracket expression it sits in ==="
# [[:alnum:] is a FATAL awk error. Scanning ] naively reads it as balanced, so the
# guard passes it through to match() and the whole file is silenced again.
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')
assert_contains "good rule survives the unterminated class" "$OUT" "good rule body"
assert_contains "unterminated class is refused" "$OUT" "tools/00-manual row 6"

echo ""
echo "=== a backslash before a NON-ASCII byte is refused like an escaped letter (#116) ==="
# The guard's escape test was `nx ~ /[[:alnum:]]/`. LC_ALL=C is pinned on the matcher, so
# substr() returns one BYTE: 0xC3 is in no character class at all under C -- measured, it
# is not alnum, not print and not cntrl -- so the test could never see it and the pattern
# went to match().
#
# What it actually did there is NOT "matched nothing". Measured on awk 20200816 and gawk
# 5.4.1: the escape is dropped and the pattern matches the BARE character, exactly as an
# escaped q does. So the row fires on the character with no backslash while the author
# wrote one, and on gawk the hook writes `regexp escape sequence ... is not a known
# regexp operator` into the session's stderr on its way to exit 0.
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"run éx now"}}')
assert_not_contains "an escaped non-ASCII byte does not block" "$OUT" "decision"
assert_not_contains "and its body is not injected" "$OUT" "nonascii escape rule body"
# Row and reason in ONE needle. Split into two, the reason half is satisfied by row 1's
# `undefined escape \s`, which is in this notice whatever row 7 does.
assert_contains "and it is NAMED, by row, with its reason" "$OUT" \
  "tools/00-manual row 7 (a block rule): undefined escape"

# The positive control, in the same fixture and on the same code path: the same character
# with no backslash. If this row goes quiet too, the four assertions above are about a
# matcher that cannot see the byte rather than about the guard.
OUT=$(run_tool '{"tool_name":"Bash","tool_input":{"command":"run éy now"}}')
assert_contains "the same character UNESCAPED still fires" "$OUT" "nonascii literal rule body"
assert_not_contains "and is not refused" "$OUT" "tools/00-manual row 8"

echo ""
echo "=== and no engine writes into the session on the way to exit 0 (#116) ==="
run_tool_keep_stderr '{"tool_name":"Bash","tool_input":{"command":"run éx now"}}' > /dev/null
if [ -s "$STDERR_FILE" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the hook wrote to stderr on the local awk"
  echo "    $(head -2 "$STDERR_FILE")"
else
  PASS=$((PASS + 1)); echo "  PASS: the hook wrote nothing to stderr on the local awk"
fi

# The local awk decides which half of #116 this leg can see. one-true-awk drops the
# escape in silence, so on a BSD/macOS runner the assertion above is green whatever the
# guard does -- it is gawk that warns. Shim gawk in as `awk` when it is installed, and
# say so out loud when it is not: a leg that could not look must never read as a leg that
# looked and found nothing.
if command -v gawk > /dev/null 2>&1; then
  SHIM="$TEST_DIR/awkshim"
  mkdir -p "$SHIM"
  printf '#!/bin/sh\nexec gawk "$@"\n' > "$SHIM/awk"
  chmod +x "$SHIM/awk"
  run_tool_keep_stderr '{"tool_name":"Bash","tool_input":{"command":"run éx now"}}' "$SHIM" > /dev/null
  if [ -s "$STDERR_FILE" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: the hook wrote to stderr under gawk"
    echo "    $(head -2 "$STDERR_FILE")"
  else
    PASS=$((PASS + 1)); echo "  PASS: the hook wrote nothing to stderr under gawk"
  fi
else
  echo "  (no gawk on this runner -- the gawk-only half of #116 was NOT checked here)"
fi

echo ""
echo "=== path hook: same two failures ==="
OUT=$(run_path '{"tool_name":"Read","tool_input":{"file_path":"/proj/Billing/Total.php"}}')
assert_contains "valid path rule fires past a fatal row" "$OUT" "billing path body"
assert_contains "path refusal is reported" "$OUT" "could not be evaluated"
assert_contains "locates the fatal path rule by row" "$OUT" "00-manual row 2"
assert_contains "locates the dead path rule by row" "$OUT" "00-manual row 3"

echo ""
echo "=== the log distinguishes 'nothing matched' from 'could not be evaluated' ==="
LOG="$BASE/.discovery/logs/hooks.log"
if [ -f "$LOG" ]; then
  assert_contains "log records the refusal" "$(cat "$LOG")" "refused:"
  # The compensating half of #35. The model-facing notice locates a refused row by position;
  # the FILE NAME an author actually needs to open is here, in a file a person reads and no
  # model does. Assert it, or the fix reads as "the name is gone" rather than "the name moved".
  assert_contains "log still names the fatal rule file for the author" "$(cat "$LOG")" "fatal.md"
  assert_contains "log still names the dead-escape rule file" "$(cat "$LOG")" "dead-escape.md"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: log file written"
fi

rm -rf "$TEST_DIR"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
