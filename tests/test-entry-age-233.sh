#!/bin/bash
# Tests for #233 part 1: the injection header for a 00-manual vocabulary entry carries
# the entry's on-disk age ("last edited Nd ago"), read once per hook invocation via a
# single perl process over the 00-manual layer directory -- never per matched row, the
# same architectural bound jit_scan_layers() already holds for the directory listing.
#
# jit-drive: none -- every assertion here runs a real hook subprocess and greps its
# output for a fixed literal shape; there is no payload-driven helper for the harness to
# drive.
#
# Usage: bash tests/test-entry-age-233.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
TOOL_HOOK="$REPO/scripts/pre-tool-hook.sh"
PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"
BASE="$PROJ/.claude/jit-context"
VOCAB="$BASE/vocabulary"
mkdir -p "$VOCAB/00-manual" "$VOCAB/10-auto"

IDXNAME="00-index"; IDXNAME="$IDXNAME.tsv"

printf 'bridgekw\tbridge.md\n' > "$VOCAB/00-manual/$IDXNAME"
echo "bridge entry body" > "$VOCAB/00-manual/bridge.md"
printf 'cachekw\tcache.md\n' > "$VOCAB/10-auto/$IDXNAME"
echo "cache entry body" > "$VOCAB/10-auto/cache.md"

# Old, known mtime on the 00-manual entry -- POSIX `touch -t`, same form
# tests/test-jit-doctor.sh already relies on.
touch -t 202001010000 "$VOCAB/00-manual/bridge.md"
# The 10-auto entry keeps a fresh mtime (the control: it still matches, and must not
# grow an age it was never asked to carry).

EXPECT_DAYS="$(perl -e 'print int(-M $ARGV[0])' "$VOCAB/00-manual/bridge.md")"

run_prompt() {
  echo "$1" | CLAUDE_PROJECT_DIR="$PROJ" bash "$PROMPT_HOOK" 2>/dev/null
}
run_tool() {
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$PROJ" bash "$TOOL_HOOK" 2>/dev/null
}

# Vocabulary matching in pre-tool-hook.sh binds to WHERE the tool acts, not what the
# payload says (see the comment above cmd_paths in pre-tool-hook.sh) -- so the fixture
# has to be a path-like token carrying the keyword, not a bare command word.

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:400}"
  fi
}
assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:400}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

echo "=== pre-prompt-hook.sh: 00-manual entry header carries its age ==="
OUT=$(run_prompt '{"prompt":"tell me about bridgekw"}')
assert_contains "shows the matched keyword" "$OUT" "matched: bridgekw"
assert_contains "shows the real on-disk age" "$OUT" "last edited ${EXPECT_DAYS}d ago"

echo ""
echo "=== pre-prompt-hook.sh: a non-00-manual entry matches and carries NO age (control) ==="
OUT2=$(run_prompt '{"prompt":"tell me about cachekw"}')
assert_contains "still matches (positive control: this run saw something)" "$OUT2" "matched: cachekw"
assert_not_contains "does not carry a last-edited age" "$OUT2" "last edited"

echo ""
echo "=== pre-tool-hook.sh: the same 00-manual entry, matched via a Bash command, also carries its age ==="
OUT3=$(run_tool '{"tool_name":"Edit","tool_input":{"file_path":"src/bridgekw.md"}}')
assert_contains "shows the matched keyword" "$OUT3" "matched: bridgekw"
assert_contains "shows the real on-disk age" "$OUT3" "last edited ${EXPECT_DAYS}d ago"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
