#!/bin/bash
# #389: the third marker file, bytes-shown-<session>.txt, written at every delivery
# site alongside the entry's own jit_shown_mark() call -- never for a refusal or a
# no-subject sentinel, which never had a body to measure.
#
# Sites covered here, the ones #389's own issue body names:
#   * pre-prompt-hook.sh   -- the vocabulary pass
#   * pre-path-hook.sh     -- both its own dimension (paths) and the vocabulary pass
#   * pre-tool-hook.sh     -- the held-advisory commit loop (tools) and its vocabulary
#                             pass
#
# Every positive assertion below is paired with a shape a broken write would also
# satisfy trivially -- an empty marker directory, a hook that never fired -- so each
# section first proves the entry itself was delivered before checking what got
# written about it.
#
# The end-to-end control (section F) drives all three hooks against ONE session id
# and then runs stop-hook.sh over the state they left behind, proving the write side
# here and the read side in stop-hook.sh agree on one format without either being
# mocked.
#
# jit-drive: assert_contains contains capture
#
# Usage: bash tests/test-byte-marks-389.sh

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

TMP="$(mktemp -d 2> /dev/null || mktemp -d -t jit389)"
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
  # `once` is load-bearing: only a once-mode advisory is ever held and committed
  # through jit_shown_mark() at all (see pre-tool-hook.sh's own `key` gate) -- a
  # plain `remind` row is delivered every call and never marked shown, so it would
  # never carry a byte line either, by the same rule a refusal never does.
  printf 'Bash\ttoolcanary\ttool-note.md\tremind, once\t\t\n' > "$base/tools/00-manual/$IDXNAME"
  printf 'tool note body, also real\n' > "$base/tools/00-manual/tool-note.md"
  printf 'zorkword\tvocab-note.md\n' > "$base/vocabulary/00-manual/$IDXNAME"
  printf 'vocab note body text\n' > "$base/vocabulary/00-manual/vocab-note.md"
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }

run_path() {
  local p="$1" sid="$2"
  printf '{"session_id":"%s","tool_name":"Read","tool_input":{"file_path":"/x/app.php"}}' "$sid" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/pre-path-hook.sh" 2>&1
}
run_tool() {
  local p="$1" sid="$2"
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"toolcanary now"}}' "$sid" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/pre-tool-hook.sh" 2>&1
}
run_prompt() {
  local p="$1" sid="$2"
  printf '{"session_id":"%s","prompt":"zorkword please"}' "$sid" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/pre-prompt-hook.sh" 2>&1
}
run_stop() {
  local p="$1" sid="$2"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$sid" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/stop-hook.sh" 2>&1
}

echo "=== A: pre-prompt-hook.sh's vocabulary pass writes a byte line beside the entry mark ==="

P="$(new_project a)"
OUT="$(run_prompt "$P" "sess-a")"
assert_contains "the entry was actually delivered" "$OUT" "vocab note body text"
BFILE="$(state_of "$P")/bytes-shown-sess-a.txt"
if [ -f "$BFILE" ]; then
  ok "the bytes marker file exists"
else
  bad "the bytes marker file was not written at all"
fi
CONTENT="$(cat "$BFILE" 2> /dev/null)"
assert_contains "the line names the delivered entry's loc: key" "$CONTENT" "loc:vocabulary:00-manual:vocab-note.md"
if grep -qE $'loc:vocabulary:00-manual:vocab-note\\.md\t[1-9][0-9]*$' "$BFILE" 2> /dev/null; then
  ok "and pairs it with a positive byte count on the SAME line"
else
  bad "the byte count is missing, zero, or on a different line" "got: $CONTENT"
fi

echo ""
echo "=== B: pre-path-hook.sh's own dimension (paths) writes a byte line too ==="

P="$(new_project b)"
OUT="$(run_path "$P" "sess-b")"
assert_contains "the entry was actually delivered" "$OUT" "php coding rules, a real body"
BFILE="$(state_of "$P")/bytes-shown-sess-b.txt"
CONTENT="$(cat "$BFILE" 2> /dev/null)"
assert_contains "the line names the delivered entry's loc: key" "$CONTENT" "loc:paths:00-manual:php-coding.md"
if grep -qE $'loc:paths:00-manual:php-coding\\.md\t[1-9][0-9]*$' "$BFILE" 2> /dev/null; then
  ok "and pairs it with a positive byte count on the SAME line"
else
  bad "the byte count is missing, zero, or on a different line" "got: $CONTENT"
fi

echo ""
echo "=== C: pre-tool-hook.sh's held-advisory commit writes a byte line for the tools mark ==="

P="$(new_project c)"
OUT="$(run_tool "$P" "sess-c")"
assert_contains "the entry was actually delivered" "$OUT" "tool note body, also real"
BFILE="$(state_of "$P")/bytes-shown-sess-c.txt"
CONTENT="$(cat "$BFILE" 2> /dev/null)"
assert_contains "the line names the delivered entry's loc: key" "$CONTENT" "loc:tools:00-manual:tool-note.md"
if grep -qE $'loc:tools:00-manual:tool-note\\.md\t[1-9][0-9]*$' "$BFILE" 2> /dev/null; then
  ok "and pairs it with a positive byte count on the SAME line"
else
  bad "the byte count is missing, zero, or on a different line" "got: $CONTENT"
fi

echo ""
echo "=== D: pre-tool-hook.sh's OWN vocabulary pass writes a byte line, same file, same session ==="

P="$(new_project d)"
# The tool hook's own vocabulary pass binds on PATH tokens, not on the free-text
# command -- a slash-bearing token is what reaches the keyword lookup at all.
OUT="$(printf '{"session_id":"sess-d","tool_name":"Read","tool_input":{"file_path":"src/zorkword/x.php"}}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/pre-tool-hook.sh" 2>&1)"
assert_contains "the vocabulary entry fired through the tool hook's own pass" "$OUT" "vocab note body text"
BFILE="$(state_of "$P")/bytes-shown-sess-d.txt"
CONTENT="$(cat "$BFILE" 2> /dev/null)"
assert_contains "the line names the delivered entry's loc: key" "$CONTENT" "loc:vocabulary:00-manual:vocab-note.md"

echo ""
echo "=== E: a refusal marks a sentinel but never a byte line -- nothing was delivered to measure ==="

P="$(new_project e)"
BASE="$P/.claude/jit-context"
printf '%s\t%s\n' '[unterminated' 'bad-pattern.md' > "$BASE/paths/00-manual/$IDXNAME"
: > "$BASE/paths/00-manual/bad-pattern.md"
OUT="$(run_path "$P" "sess-e")"
assert_contains "the refusal notice fired" "$OUT" "could not be evaluated"
BFILE="$(state_of "$P")/bytes-shown-sess-e.txt"
if [ -f "$BFILE" ]; then
  bad "a bytes marker file was written for a refusal, which delivered nothing"
else
  ok "no bytes marker file at all -- a refusal is not a delivery"
fi

echo ""
echo "=== F: end to end -- three hooks write, stop-hook.sh reads back a real, matching total ==="

P="$(new_project f)"
run_path "$P" "sess-f" > /dev/null
run_tool "$P" "sess-f" > /dev/null
run_prompt "$P" "sess-f" > /dev/null
OUT="$(run_stop "$P" "sess-f")"
assert_contains "the total names three entries" "$OUT" "3 entries"
assert_contains "and points at the skill this issue adds" "$OUT" "/jit:stats for more info"
if grep -qE '"JIT : 3 entries, [0-9]+(\.[0-9])?[bk] this session \+ /jit:stats for more info"' <<< "$OUT"; then
  ok "the size rendered is a real, non-zero figure, not withheld"
else
  bad "no size was rendered even though every one of the three hooks wrote a byte line" "got: $OUT"
fi

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
