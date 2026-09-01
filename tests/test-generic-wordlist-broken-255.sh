#!/bin/bash
# #255: rebuild-tsv.sh forked one `grep -Fxq` per keyword against the bundled
# generic-words list -- #251 grew that file from 196 words/~4KB to 103,776
# words/~1.0MB, so this fork became the dominant cost of a rebuild. The fix batches
# every keyword this run needs classified through ONE awk process instead of one grep
# per keyword.
#
# That batching moves where the wordlist is read: from "once per keyword, silently
# swallowing a permission-denied or truncated read (`-f` check plus `2>/dev/null`)" to
# "once per run" -- and a read that silently produced an empty set would classify every
# keyword as non-generic with nothing in CI to catch it, which is this repo's own
# defect class. This suite is the guard: a wordlist the JIT_CONTEXT_GENERIC_WORDS
# override points at that EXISTS but cannot be read (empty, or unreadable) must be a
# named, loud, non-zero outcome -- distinct from the documented "no wordlist configured
# at all" degrade, which stays silent and exit 0 on purpose (an index built before this
# feature landed must not start failing loudly for a reason nobody changed).
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
#
# Usage: bash tests/test-generic-wordlist-broken-255.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF -- "$want" <<<"$out"; then ok "$desc"
  else bad "$desc" "expected to contain: $want"; echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}
assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if grep -qF -- "$unwanted" <<<"$out"; then bad "$desc" "must NOT contain: $unwanted"; echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  else ok "$desc"
  fi
}
assert_rc() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "wanted exit $want, got exit $got"; fi
}

ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t jit255)"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
BASE="$ROOT/.claude/jit-context"
mkdir -p "$BASE/vocabulary/00-manual"

write_entry() {
  local path="$BASE/vocabulary/00-manual/$1"
  shift
  {
    echo "---"
    for l in "$@"; do echo "$l"; done
    echo "---"
    echo ""
    echo "Body for $(basename "$path")."
  } > "$path"
}

write_entry widget.md \
  "title: Widget" \
  "description: What a widget is here." \
  "keywords: context, uniquespecifictoken255"

ERR="$ROOT/rebuild.err"
RC=0
rebuild() {
  CLAUDE_PROJECT_DIR="$ROOT" JIT_CONTEXT_GENERIC_WORDS="${1:-}" bash "$REBUILD" >/dev/null 2>"$ERR"
  RC=$?
  return 0
}

echo "=== A. no wordlist configured at all (empty override): the documented degrade stays silent, exit 0 ==="
rebuild ""
assert_rc "an empty override exits 0" 0 "$RC"
assert_not_contains "and nothing FATAL is printed" "$(cat "$ERR")" "FATAL"

echo ""
echo "=== B. a wordlist path that does not exist: the documented degrade stays silent, exit 0 ==="
rebuild "$ROOT/does-not-exist.txt"
assert_rc "a missing wordlist file exits 0" 0 "$RC"
assert_not_contains "and nothing FATAL is printed" "$(cat "$ERR")" "FATAL"

echo ""
echo "=== C. a wordlist that EXISTS and is EMPTY: loud, exit 2, and the vocab index still gets written ==="
EMPTYFILE="$ROOT/empty-words.txt"
: > "$EMPTYFILE"
rebuild "$EMPTYFILE"
assert_rc "an empty-but-present wordlist exits 2" 2 "$RC"
assert_contains "and names the broken file" "$(cat "$ERR")" "$EMPTYFILE"
assert_contains "and says it is empty" "$(cat "$ERR")" "empty"
assert_contains "the vocabulary index is still written despite the broken wordlist" \
  "$(cat "$BASE/vocabulary/00-manual/00-index.tsv")" "widget.md"

echo ""
echo "=== D. a wordlist that EXISTS and is UNREADABLE: loud, exit 2 ==="
UNREADABLE="$ROOT/secret-words.txt"
printf 'context\n' > "$UNREADABLE"
chmod 000 "$UNREADABLE" 2>/dev/null
if [ -r "$UNREADABLE" ]; then
  echo "  SKIP-NOTE: chmod did not remove read permission here (running as root). Section D tested nothing."
else
  rebuild "$UNREADABLE"
  assert_rc "an unreadable wordlist exits 2" 2 "$RC"
  assert_contains "and names the broken file" "$(cat "$ERR")" "$UNREADABLE"
  assert_contains "and says it is not readable" "$(cat "$ERR")" "not readable"
fi
chmod 644 "$UNREADABLE" 2>/dev/null

echo ""
echo "=== E. positive control: a working wordlist classifies correctly and exits 0 ==="
GOODFILE="$ROOT/good-words.txt"
printf 'context\n' > "$GOODFILE"
rebuild "$GOODFILE"
assert_rc "a working wordlist exits 0" 0 "$RC"
assert_not_contains "and nothing FATAL is printed" "$(cat "$ERR")" "FATAL"
assert_contains "the listed keyword is marked generic" \
  "$(cat "$BASE/vocabulary/00-manual/00-index.tsv")" "$(printf 'context\twidget.md\tgeneric')"
assert_contains "an unlisted keyword degrades to specific (empty 3rd column)" \
  "$(cat "$BASE/vocabulary/00-manual/00-index.tsv")" "$(printf 'uniquespecifictoken255\twidget.md\t')"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
