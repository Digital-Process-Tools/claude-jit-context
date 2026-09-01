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
echo "=== a filename with a literal tab in a 00-manual layer never reaches the age table (#233 review finding) ==="
# jit_scan_entry_ages()'s table uses TAB and NEWLINE as its own field/record separators.
# A directory entry whose NAME contains one of those bytes -- reachable via an ordinary
# `git clone`, the same threat model the symlink guards above jit_scan_layers() already
# name -- would fold onto, or split, a genuine neighbour's row if it ever reached the
# table at all. Checked directly against the table jit_scan_entry_ages() builds, rather
# than through a full hook round trip: which row wins a collision depends on this
# filesystem's own readdir() order, which this suite does not control and must not rely
# on, but whether the poisoned name is EXCLUDED from the table in the first place does
# not depend on that order at all.
TABPROJ="$TMP/tabproj"
TABBASE="$TABPROJ/.claude/jit-context/vocabulary"
mkdir -p "$TABBASE/00-manual"
IDXNAME="00-index"; IDXNAME="$IDXNAME.tsv"
printf 'bridgekw\tbridge.md\n' > "$TABBASE/00-manual/$IDXNAME"
echo "bridge entry body" > "$TABBASE/00-manual/bridge.md"
touch -t 202001010000 "$TABBASE/00-manual/bridge.md"
# The adversarial neighbour: a name that starts with the legitimate one's bytes plus a
# real TAB, so a naive first-tab split would fold this row onto "bridge.md"'s key.
perl -e 'my $n = "bridge.md" . "\t" . "1"; open(my $fh, ">", "'"$TABBASE"'/00-manual/$n") or exit 0; print $fh "poisoned\n"; close $fh;' 2>/dev/null

TABLE="$(bash -c '
  set -u
  CLAUDE_PROJECT_DIR="$1"
  export CLAUDE_PROJECT_DIR
  SCRIPT_DIR="$2"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/common.sh"
  jit_scan_layers "$3" vocabulary
  jit_scan_entry_ages "$3"
  printf "%s" "$JIT_ENTRY_AGES"
' _ "$TABPROJ" "$REPO/scripts" "$TABBASE")"
assert_not_contains "the tab-poisoned name does not reach the age table at all" "$TABLE" "$(printf 'bridge.md\t1\t')"
assert_contains "the genuine entry is still in the table, once, with its real age" "$TABLE" "00-manual/bridge.md	"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
