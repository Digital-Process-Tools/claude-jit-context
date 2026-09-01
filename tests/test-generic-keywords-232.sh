#!/bin/bash
# #232: a match on a GENERIC keyword (an ordinary English/French word) injects
# title+description only and does NOT mark the entry shown, so a later match on a
# SPECIFIC keyword still delivers the full body. A match on a specific keyword behaves
# exactly as before: full body, marked shown.
#
# Three things under test, each with its own fixture:
#   1. rebuild-tsv.sh writes a third TSV column: "generic" for an ordinary word, empty
#      for anything else -- including a keyword absent from the bundled wordlist, which
#      is the degrade-to-specific case #232 asks for.
#   2. pre-prompt-hook.sh reads that column and changes behaviour on it.
#   3. rebuild-tsv.sh separately reports a keyword that reads as an identifier before
#      normalisation and an ordinary word after it (the `jsOn` -> `json` shape).
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
#
# Usage: bash tests/test-generic-keywords-232.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
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

ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t jit232)"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
PROJ="$ROOT/proj"
BASE="$PROJ/.claude/jit-context"
mkdir -p "$BASE/vocabulary/00-manual"

write_entry() {
  local path="$BASE/vocabulary/00-manual/$1"
  shift
  {
    echo "---"
    for l in "$@"; do echo "$l"; done
    echo "---"
    echo ""
    echo "BODY-MARKER-FOR-$(basename "$path" .md)"
    echo "A gotcha only the full body carries."
  } > "$path"
}

write_entry generic-entry.md \
  "title: Generic entry title" \
  "description: Generic entry description line." \
  "keywords: context, uniquespecifictoken232"

write_entry identifier-entry.md \
  "title: Identifier entry" \
  "description: Has an identifier keyword that normalises to an ordinary word." \
  "keywords: jsOn"

echo "=== A. rebuild-tsv.sh writes a third column: generic verdict ==="
CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" >/dev/null 2>"$ROOT/rebuild.err"
IDX="$BASE/vocabulary/00-manual/00-index.tsv"
[ -f "$IDX" ] || bad "index was written" "no such file: $IDX"
assert_contains "the generic keyword's row is marked generic" "$(cat "$IDX")" "$(printf 'context\tgeneric-entry.md\tgeneric')"
assert_contains "a keyword absent from the wordlist degrades to specific (empty 3rd column)" "$(cat "$IDX")" "$(printf 'uniquespecifictoken232\tgeneric-entry.md\t')"

echo ""
echo "=== B. rebuild-tsv.sh reports an identifier that normalises to an ordinary word ==="
assert_contains "the jsOn -> json collision is reported by name" "$(cat "$ROOT/rebuild.err")" "jsOn"
assert_contains "and names the normalised form" "$(cat "$ROOT/rebuild.err")" "json"

echo ""
echo "=== C. pre-prompt-hook.sh: a match on the generic keyword alone injects summary only, and does not spend the shot ==="
# session_id present on every call so jit_shown_file() persists a shown-set file across
# these separate subprocess invocations -- without one, jit_session_key() returns "" and
# the shown set lives and dies inside a single invocation, which would make every
# "still fires" / "shot is spent" assertion below vacuous.
run_prompt() {
  local text="$1"
  printf '{"session_id":"jit232-test-session","prompt":"%s"}' "$text" \
    | CLAUDE_PROJECT_DIR="$PROJ" bash "$PROMPT_HOOK" 2>/dev/null
}
OUT1=$(run_prompt "what is the context here")
assert_contains "the title/description still arrive" "$OUT1" "Generic entry description line."
assert_not_contains "the full body did NOT arrive on a generic-only match" "$OUT1" "BODY-MARKER-FOR-generic-entry"

OUT2=$(run_prompt "what is the context here, second turn")
assert_contains "a second generic-only match still fires (the shot was never spent)" "$OUT2" "Generic entry description line."

echo ""
echo "=== D. a later match on the SPECIFIC keyword still delivers the full body ==="
OUT3=$(run_prompt "tell me about uniquespecifictoken232")
assert_contains "the full body arrives on the specific match" "$OUT3" "BODY-MARKER-FOR-generic-entry"

echo ""
echo "=== E. a specific-only match (positive control) behaves exactly as before: full body, one shot ==="
write_entry specific-only.md \
  "title: Specific only" \
  "description: Never mind the description." \
  "keywords: onlyspecifickeyword232"
CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" >/dev/null 2>/dev/null
OUT4=$(run_prompt "onlyspecifickeyword232 please")
assert_contains "full body on first match" "$OUT4" "BODY-MARKER-FOR-specific-only"
OUT5=$(run_prompt "onlyspecifickeyword232 again")
assert_not_contains "the shot is spent -- no second injection for a specific-only entry" "$OUT5" "BODY-MARKER-FOR-specific-only"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
