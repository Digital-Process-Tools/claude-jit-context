#!/bin/bash
# Tests for double quotes in a `match:` (and `require:`) frontmatter value.
#
# The frontmatter reader used to delete EVERY double quote from a value on its way to the
# index (#19). An author anchoring on a quoted argument -- `["]`, the shape that separates
# a quoted payload from a bare word -- had half their pattern removed silently: the .md on
# disk still showed what they wrote, the index carried something else, and only the index
# runs. No error, no log line, no way to see it from either end.
#
# The rule now: a matching pair of double quotes around the WHOLE value is YAML-style
# quoting and is removed. A quote anywhere else is part of the pattern and survives.
#
# Every silence assertion here is paired with a fire assertion on the same fixture, and the
# suite aborts loudly if the index it reads is not the one it just built -- otherwise a
# harness that has stopped seeing the tree reads as a pass.
#
# Usage: bash tests/test-frontmatter-quotes.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/pre-tool-hook.sh"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF "$want" <<<"$out"; then
    ok "$desc"
  else
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}

assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if grep -qF "$unwanted" <<<"$out"; then
    bad "$desc" "must NOT contain: $unwanted"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  else
    ok "$desc"
  fi
}

assert_equals() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted [$want], got [$got]"
  fi
}

# --- A project tree whose rules carry double quotes ---------------------------
ROOT=$(mktemp -d)
BASE="$ROOT/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual" "$BASE/paths/00-manual"

write_entry() {
  # $1 path relative to BASE, $2.. frontmatter lines
  local path="$BASE/$1" l
  shift
  {
    echo "---"
    for l in "$@"; do echo "$l"; done
    echo "---"
    echo ""
    echo "Body for $(basename "$path")."
  } > "$path"
}

rebuild() { CLAUDE_PROJECT_DIR="$ROOT" bash "$REBUILD"; }

# The quote is INSIDE a bracket expression, mid-pattern -- the house style for a literal
# metacharacter, and the shape #19 deleted.
write_entry tools/00-manual/quoted-arg.md \
  "title: Quote the payload" \
  "tool: Bash" \
  'match: ~echo[[:space:]]+["]hi["]' \
  "mode: remind"

# `require` is free text on the same reader, so it loses quotes the same way. Kept on its
# own entry: a require turns a matching rule into a block, which would mask the verdict the
# quoted-arg rule is here to prove.
write_entry tools/00-manual/require-quotes.md \
  "title: Say it politely" \
  "tool: Bash" \
  'match: ~grep[[:space:]]+["]x["]' \
  "mode: block" \
  'require: say "please"' \
  'forbid: "a" or "b"'

# YAML-style quoting of the whole value. This has always worked and must keep working.
write_entry tools/00-manual/yaml-quoted.md \
  "title: Long listing" \
  "tool: Bash" \
  'match: "~ls[[:space:]]+-la"' \
  "mode: remind"

# YAML-style quoting with trailing whitespace after the closing quote.
write_entry tools/00-manual/trailing-space.md \
  "title: Print the directory" \
  "tool: Bash" \
  'match: "~pwd" ' \
  "mode: remind"

# A paths value quoted the same way.
write_entry paths/00-manual/quoted-path.md \
  "title: Config tree" \
  'match: "(^|/)config/"'

rebuild >/dev/null 2>&1

TOOLS_TSV="$BASE/tools/00-manual/00-index.tsv"
PATHS_TSV="$BASE/paths/00-manual/00-index.tsv"

echo "=== the harness can see the tree at all ==="
ROWS=0
[ -f "$TOOLS_TSV" ] && ROWS=$(wc -l < "$TOOLS_TSV" | tr -d ' ')
assert_equals "the tools index has one row per entry" "$ROWS" "4"
if [ "$ROWS" != "4" ]; then
  echo "  ABORT: no usable index -- every silence assertion below would pass vacuously."
  rm -rf "$ROOT"
  exit 1
fi

INDEX="$(cat "$TOOLS_TSV")"

echo ""
echo "=== a quote inside the pattern reaches the index intact ==="
assert_contains     "the bracketed quote survives"    "$INDEX" '["]hi["]'
# The exact shape the old strip produced. `[hi]` -- the obvious guess -- was never in any
# index, so asserting its absence would pass with the defect still present.
assert_not_contains "and is not collapsed to []hi[]" "$INDEX" '[]hi[]'
assert_contains     "require keeps its quotes too"   "$INDEX" 'say "please"'
# A value that starts and ends with a quote WITHOUT being one quoted scalar. Preserved
# verbatim: the old strip made it `a or b`, and a greedy `^".*"$` test would make it
# `a" or "b` -- both rewrites of something the author wrote.
assert_equals "an unwrapped pair is left alone" \
  "$(awk -F'\t' '$3 == "require-quotes.md" {print $6}' "$TOOLS_TSV")" '"a" or "b"'

echo ""
# Three of the four below are COMPATIBILITY guards and pass with the defect present by
# design: YAML-style quoting of a whole value has always worked and must not be retired
# here. Only the trailing-space one discriminates. The assertions that actually fail
# without the fix are the four above, that one, and four of the six hook verdicts.
echo "=== a matching pair around the whole value is still stripped ==="
assert_contains     "the YAML-quoted pattern is bare" "$INDEX" '~ls[[:space:]]+-la'
assert_not_contains "no surrounding quote is indexed" "$INDEX" '"~ls'
assert_equals "trailing space after the closing quote" \
  "$(awk -F'\t' '$3 == "trailing-space.md" {print $2}' "$TOOLS_TSV")" '~pwd'
assert_equals "a quoted paths value is stripped too" \
  "$(awk -F'\t' '{print $1}' "$PATHS_TSV")" '(^|/)config/'

# --- Driving the real hook, both directions -----------------------------------
drive() {
  # $1 command, already JSON-escaped
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null
}

verdict() {
  local out
  out="$(drive "$1")"
  case "$out" in
    *'"decision":"block"'*) echo "BLOCK" ;;
    *'JIT Context'*)        echo "REMIND" ;;
    *)                      echo "silent" ;;
  esac
}

assert_verdict() {
  local desc="$1" cmd="$2" want="$3" got
  got="$(verdict "$cmd")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted $want, got $got -- for: $cmd"
  fi
}

echo ""
echo "=== the quoted-argument rule fires on the quoted call and only on it ==="
assert_verdict "the double-quoted argument"    'echo \"hi\"'   REMIND
assert_verdict "the same word unquoted"        'echo hi'       silent
assert_verdict "a single letter from the pair" 'echo h'        silent

echo ""
echo "=== the YAML-quoted rules still fire ==="
assert_verdict "the stripped pattern matches"  'ls -la'        REMIND
assert_verdict "and its near-miss is silent"   'ls'            silent
assert_verdict "trailing-space rule matches"   'pwd'           REMIND

rm -rf "$ROOT"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
