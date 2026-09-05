#!/bin/bash
# #232 (the part PR #250 left owed): an entry whose keywords are ALL generic must not
# sit at description-only permanently. rebuild-tsv.sh computes, per entry, whether it
# owns at least one specific keyword; when it does not, every "generic" verdict on that
# entry's rows is cleared back to empty so the hook treats every keyword as specific --
# exactly today's (pre-#232) behaviour for that entry: full body, one shot spent.
#
# An entry with a MIX of generic and specific keywords is the positive control: the
# fallback must NOT touch it, so its generic keyword still downgrades and does not spend
# the shot (test-generic-keywords-232.sh already covers this end to end; this suite
# re-asserts the TSV column alone, which is the layer the fallback lives in).
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
#
# Usage: bash tests/test-generic-fallback-232.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
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
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}
assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if grep -qF -- "$unwanted" <<< "$out"; then
    bad "$desc" "must NOT contain: $unwanted"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  else
    ok "$desc"
  fi
}

ROOT="$(mktemp -d 2> /dev/null || mktemp -d -t jit232fb)"
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

# All keywords are dictionary words the bundled list classifies generic (#232's own
# examples: template, security).
write_entry all-generic.md \
  "title: All generic entry" \
  "description: Every keyword here is an ordinary word." \
  "keywords: template, security"

# One generic, one specific -- the fallback must leave this entry alone.
write_entry mixed.md \
  "title: Mixed entry" \
  "description: One ordinary keyword, one specific one." \
  "keywords: template, uniquespecifictoken232fb"

echo "=== A. rebuild-tsv.sh: an entry with ONLY generic keywords gets every verdict cleared ==="
CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" > /dev/null 2> "$ROOT/rebuild.err"
IDX="$BASE/vocabulary/00-manual/00-index.tsv"
[ -f "$IDX" ] || bad "index was written" "no such file: $IDX"
IDXOUT="$(cat "$IDX")"
assert_not_contains "template row for all-generic.md is NOT marked generic (fallback applied)" "$IDXOUT" "$(printf 'template\tall-generic.md\tgeneric')"
assert_contains "template row for all-generic.md is written with an empty verdict instead" "$IDXOUT" "$(printf 'template\tall-generic.md\t')"
assert_not_contains "security row for all-generic.md is NOT marked generic either" "$IDXOUT" "$(printf 'security\tall-generic.md\tgeneric')"

echo ""
echo "=== B. positive control: the mixed entry's generic keyword is UNTOUCHED by the fallback ==="
assert_contains "template row for mixed.md is still marked generic" "$IDXOUT" "$(printf 'template\tmixed.md\tgeneric')"

echo ""
echo "=== C. pre-prompt-hook.sh: a match on the all-generic entry delivers the full body and spends the shot ==="
run_prompt() {
  local text="$1"
  printf '{"session_id":"jit232fb-test-session","prompt":"%s"}' "$text" \
    | CLAUDE_PROJECT_DIR="$PROJ" bash "$PROMPT_HOOK" 2> /dev/null
}
OUT1=$(run_prompt "what does the template say")
assert_contains "the full body arrives on the first match (no permanent description-only)" "$OUT1" "BODY-MARKER-FOR-all-generic"

OUT2=$(run_prompt "what does the template say, again")
assert_not_contains "the shot was spent -- no second injection" "$OUT2" "BODY-MARKER-FOR-all-generic"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
