#!/bin/bash
# #260: README.md carried the pitch AND the whole reference manual -- awk-vs-PCRE
# gotchas, invocation anchoring, layer precedence, config.env, hook timing -- in one
# 1169-line file, with the getting-started arc buried under roughly 800 lines of
# material CLAUDE.md's own Voice section says belongs elsewhere: "The README sells
# the outcome, never the mechanism."
#
# Nothing was deleted. The reference sections moved to docs/*.md, and README.md
# links to them. This suite is the guard against the split silently drifting back
# together -- a README that regrows past a size bound, or a docs/ file that stops
# being reachable from it.
#
# jit-drive: none -- this suite reads tracked files and greps their content

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  [ $# -gt 1 ] && echo "    $2"
}

README="$REPO/README.md"

# --- 1. README stays short --------------------------------------------------

readme_lines=$(wc -l < "$README" | tr -d ' ')
BOUND=500
if [ "$readme_lines" -lt "$BOUND" ]; then
  pass "README.md is under $BOUND lines ($readme_lines)"
else
  fail "README.md is under $BOUND lines" "got: $readme_lines lines"
fi

# --- 2. the version badge is still a README site, not moved -----------------

if grep -q 'img.shields.io/badge/version' "$README"; then
  pass "the version badge is still in README.md"
else
  fail "the version badge is still in README.md" "not found"
fi

# --- 3. every reference doc exists and is linked from README ----------------

for f in writing-entries patterns keyword-matching layers configuration performance diagnostics; do
  doc="$REPO/docs/$f.md"
  if [ -f "$doc" ]; then
    pass "docs/$f.md exists"
  else
    fail "docs/$f.md exists" "not found at $doc"
    continue
  fi
  if grep -q "docs/$f.md" "$README"; then
    pass "README.md links to docs/$f.md"
  else
    fail "README.md links to docs/$f.md" "no reference found"
  fi
done

# --- 4. content actually moved, not merely duplicated ------------------------
# The awk-vs-PCRE table used to live in README.md itself. If it is still there in
# full, the split did not happen -- it was copied, and the README is exactly as
# long as before, just with an extra file nobody reads.

if grep -q 'PCRE shorthand classes do not exist' "$README"; then
  fail "the awk-vs-PCRE explanation is not duplicated into README.md" \
    "found the full sentence in README.md; it should live only in docs/patterns.md"
else
  pass "the awk-vs-PCRE explanation is not duplicated into README.md"
fi

if grep -q 'PCRE shorthand classes do not exist' "$REPO/docs/patterns.md" 2> /dev/null; then
  pass "the awk-vs-PCRE explanation lives in docs/patterns.md"
else
  fail "the awk-vs-PCRE explanation lives in docs/patterns.md" "not found"
fi

echo ""
echo "========================"
echo "  $PASS passed, $FAIL failed"
echo "========================"
[ "$FAIL" -eq 0 ]
