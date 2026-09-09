#!/bin/bash
# #379 review finding: collapsing the per-keyword classify loop to one awk process per
# file (scripts/rebuild-tsv.sh, build_vocab_tsv) widened the blast radius of a malformed
# VOCAB_KEYWORD_BLACKLIST (JIT_CONTEXT_KEYWORD_BLACKLIST, project-configurable, arrives
# with the clone) from "one keyword's grep call exits 2, read as not-blacklisted" to
# "the whole awk process for this FILE aborts on the first ~ evaluation, silently
# dropping every keyword on the file with an actively wrong 'normalised to nothing'
# reason". Both the reviewer (Explore) and the auditor (oss:auditor) found this
# independently against the first version of the fix; this pins the repair: a bad
# pattern is validated ONCE, loudly, and every keyword on every file still gets
# indexed rather than silently vanishing.
#
# Usage: bash tests/test-rebuild-blacklist-regex-379.sh

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
  shift
  local l
  for l in "$@"; do echo "    $l"; done
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jit-blacklist-regex.XXXXXXXX" 2> /dev/null)" || {
  echo "  SKIPPED: could not create a work directory -- nothing was measured"
  exit 2
}
trap 'rm -rf "$WORK"' EXIT

PROJ="$WORK/proj"
mkdir -p "$PROJ/.claude/jit-context/vocabulary/00-manual"
cat > "$PROJ/.claude/jit-context/vocabulary/00-manual/e1.md" << 'MD'
---
title: bad regex repro
description: test
keywords: alpha, bravo, charlie, delta, echo
---
body
MD

OUT="$WORK/out.log"
IDX="$PROJ/.claude/jit-context/vocabulary/00-manual/00-index.tsv"

(cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" JIT_CONTEXT_KEYWORD_BLACKLIST='^(' \
  bash "$REPO/scripts/rebuild-tsv.sh" > "$OUT" 2>&1)
rc=$?

echo "=== a malformed blacklist regex is reported, exits non-zero (#379) ==="
if [ "$rc" -ne 0 ]; then
  pass "rebuild-tsv.sh exits non-zero on a malformed VOCAB_KEYWORD_BLACKLIST (got $rc)"
else
  fail "rebuild-tsv.sh exits non-zero on a malformed VOCAB_KEYWORD_BLACKLIST" "got exit 0"
fi
if grep -q "FATAL.*VOCAB_KEYWORD_BLACKLIST is not a valid extended regular expression" "$OUT"; then
  pass "the FATAL names the real cause"
else
  fail "the FATAL names the real cause" "$(cat "$OUT")"
fi

echo ""
echo "=== ...and every keyword is still indexed, not silently dropped ==="
if [ -f "$IDX" ]; then
  n=$(wc -l < "$IDX" | tr -d '[:space:]')
  if [ "${n:-0}" -eq 5 ]; then
    pass "all 5 keywords survived a malformed blacklist (the same safe degrade grep gave)"
  else
    fail "all 5 keywords survived a malformed blacklist" \
      "got $n row(s) in $IDX" "$(cat "$IDX" 2> /dev/null)"
  fi
else
  fail "all 5 keywords survived a malformed blacklist" "no index file was written at all"
fi

echo ""
echo "=== ...and the misleading 'normalised to nothing' reason is NOT printed ==="
# This is the review finding's sharpest edge: before the fix, a crashed classify pass
# fell through to the pre-existing kw_written==0 branch and blamed the NORMALISER for
# keywords ("alpha", "bravo", ...) that never touched it.
if grep -q "normalised to nothing" "$OUT"; then
  fail "the misleading normalised-to-nothing reason is not printed" "$(cat "$OUT")"
else
  pass "the misleading normalised-to-nothing reason is not printed"
fi

echo ""
echo "=== a VALID blacklist still drops exactly the terms it should ==="
PROJ2="$WORK/proj2"
mkdir -p "$PROJ2/.claude/jit-context/vocabulary/00-manual"
cat > "$PROJ2/.claude/jit-context/vocabulary/00-manual/e2.md" << 'MD'
---
title: valid blacklist
description: test
keywords: ledger, alpha
---
body
MD
(cd "$PROJ2" && CLAUDE_PROJECT_DIR="$PROJ2" JIT_CONTEXT_KEYWORD_BLACKLIST='^(ledger)$' \
  bash "$REPO/scripts/rebuild-tsv.sh" > "$WORK/out2.log" 2>&1)
rc2=$?
IDX2="$PROJ2/.claude/jit-context/vocabulary/00-manual/00-index.tsv"
if [ "$rc2" -eq 0 ]; then
  pass "a valid blacklist still exits 0"
else
  fail "a valid blacklist still exits 0" "got $rc2, $(cat "$WORK/out2.log")"
fi
if [ -f "$IDX2" ] && grep -q '^alpha' "$IDX2" && ! grep -q '^ledger' "$IDX2"; then
  pass "a valid blacklist still drops exactly the blacklisted term"
else
  fail "a valid blacklist still drops exactly the blacklisted term" \
    "$(cat "$IDX2" 2> /dev/null)"
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
