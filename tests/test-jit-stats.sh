#!/bin/bash
# #389: scripts/jit-stats.sh -- the detail #367 pulled off the Stop line, read back on
# demand. A deliberate, hand-run tool (paths/00-manual/tooling.md's contract): fail
# loudly, exit codes carry meaning.
#
# Usage: bash tests/test-jit-stats.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
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
  [ $# -eq 0 ] || echo "    $*"
}

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF -- "$want" <<< "$out"; then
    ok "$desc"
  else
    bad "$desc" "expected to contain: $want" "got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}

TMP="$(mktemp -d 2> /dev/null || mktemp -d -t jitstats389)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

IDXNAME="00-index"; IDXNAME="$IDXNAME.tsv"

new_project() {
  local p="$TMP/proj-$1"
  local base
  rm -rf "$p"
  base="$p/.claude/jit-context"
  mkdir -p "$base/paths/00-manual" "$base/paths/10-auto" "$base/paths/20-grouped" \
    "$base/paths/30-crosscutting" "$base/tools/00-manual" "$base/vocabulary/00-manual"
  printf '%s\t%s\n' '\.php' 'php-coding.md' > "$base/paths/00-manual/$IDXNAME"
  printf 'php coding rules, a real body\n' > "$base/paths/00-manual/php-coding.md"
  : > "$base/paths/10-auto/$IDXNAME"
  : > "$base/paths/20-grouped/$IDXNAME"
  : > "$base/paths/30-crosscutting/$IDXNAME"
  printf 'zorkword\tvocab-note.md\n' > "$base/vocabulary/00-manual/$IDXNAME"
  printf 'vocab note body text\n' > "$base/vocabulary/00-manual/vocab-note.md"
  printf '%s' "$p"
}

echo "=== A: exit 2 -- no jit-context tree at all ==="
P="$TMP/no-tree"
mkdir -p "$P"
OUT="$(CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/jit-stats.sh" 2>&1)"
RC=$?
[ "$RC" -eq 2 ] && ok "exit 2" || bad "expected exit 2, got $RC"
assert_contains "says so on the line itself" "$OUT" "no jit-context tree"

echo ""
echo "=== B: exit 1 -- a tree exists, nothing has fired yet ==="
P="$(new_project b)"
OUT="$(CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/jit-stats.sh" 2>&1)"
RC=$?
[ "$RC" -eq 1 ] && ok "exit 1" || bad "expected exit 1, got $RC"
assert_contains "says nothing has fired, never guesses a session" "$OUT" "nothing has fired yet"

echo ""
echo "=== C: a real session -- name, dimension, layer, match and bytes all print ==="
P="$(new_project c)"
printf '{"session_id":"sess-c","prompt":"zorkword please"}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/pre-prompt-hook.sh" > /dev/null
OUT="$(CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/jit-stats.sh" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC"
assert_contains "names the session key" "$OUT" "session key: sess-c"
assert_contains "names the entry" "$OUT" "vocab-note.md"
assert_contains "names the dimension" "$OUT" "dim=vocabulary"
assert_contains "names the layer" "$OUT" "layer=00-manual"
assert_contains "names the matched word" "$OUT" "matched=zorkword"
if grep -qE 'bytes=[1-9][0-9]*' <<< "$OUT"; then
  ok "a real positive byte count, not 'unknown' and not 0"
else
  bad "the byte count is missing or unknown" "got: $OUT"
fi
assert_contains "and relays the misses report" "$OUT" "recurring misses"

echo ""
echo "=== D: --base overrides CLAUDE_PROJECT_DIR resolution, same as the other tools ==="
P="$(new_project d)"
printf '{"session_id":"sess-d","prompt":"zorkword please"}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/pre-prompt-hook.sh" > /dev/null
OUT="$(bash "$SCRIPTS/jit-stats.sh" --base "$P/.claude/jit-context" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC"
assert_contains "the override reached the same tree" "$OUT" "vocab-note.md"

echo ""
echo "=== E: an unknown flag is refused loudly, not silently ignored ==="
OUT="$(bash "$SCRIPTS/jit-stats.sh" --nope 2>&1)"
RC=$?
[ "$RC" -eq 2 ] && ok "exit 2 on an unknown flag" || bad "expected exit 2, got $RC"


echo "=== F: #389 self-review finding -- bytes_for() must not borrow an unrelated line's byte count ==="

P="$(new_project f)"
STATE="$(dirname "$(dirname "$0")")/proj-f-state-unused"
mkdir -p "$P/.claude/jit-context/.discovery/state"
printf 'loc:paths:00-manual:md\n' > "$P/.claude/jit-context/.discovery/state/path-shown-sess-f.txt"
printf 'loc:paths:00-manual:x-loc:paths:00-manual:md\t999\nloc:paths:00-manual:md\t5\n' \
  > "$P/.claude/jit-context/.discovery/state/bytes-shown-sess-f.txt"
OUT="$(CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/jit-stats.sh" 2>&1)"
assert_contains "the entry's own 5-byte record is reported" "$OUT" "bytes=5"
if grep -qF "bytes=999" <<< "$OUT"; then
  bad "the unrelated, longer line's 999-byte count must never be borrowed" "got: $OUT"
else
  ok "999 is never attributed to this entry"
fi

echo "=== G: #389 self-review finding -- match_for() must not borrow a pattern from an unrelated log token ==="

P="$(new_project g)"
mkdir -p "$P/.claude/jit-context/.discovery/state" "$P/.claude/jit-context/.discovery/logs"
printf 'loc:vocabulary:00-manual:md\n' > "$P/.claude/jit-context/.discovery/state/vocab-shown-sess-g.txt"
# A crafted earlier token, "xtra:md(", shares the file's own ":md(" suffix but
# belongs to a DIFFERENT layer ("xtra") and a different word entirely --
# match_for() must not attribute XTRA-PATTERN to the real "00-manual:md" entry
# further down the same line.
printf '[12:00:00.000] pre-prompt (na) 1ms | xtra:md(XTRA-PATTERN), 00-manual:md(REAL-PATTERN)\n' \
  > "$P/.claude/jit-context/.discovery/logs/hooks.log"
OUT="$(CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/jit-stats.sh" 2>&1)"
assert_contains "the entry's OWN layer-qualified token is what gets reported" "$OUT" "matched=REAL-PATTERN"
if grep -qF "matched=XTRA-PATTERN" <<< "$OUT"; then
  bad "an unrelated layer's token must never be borrowed" "got: $OUT"
else
  ok "XTRA-PATTERN is never attributed to this entry"
fi
echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
