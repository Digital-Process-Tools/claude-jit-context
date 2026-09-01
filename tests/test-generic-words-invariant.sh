#!/bin/bash
# #251: data/generic-words.txt must never carry a row that cannot survive
# jit_fold_latin1() -- the classifier folds a KEYWORD before comparing it against this
# file (scripts/rebuild-tsv.sh, the `LC_ALL=C grep -Fxq -- "$kw" "$GENERIC_WORDS_FILE"` call),
# but never folds the file itself. A row stored with an accent, or with anything outside
# [a-z], can therefore never be reached by any normalised keyword -- it is a permanently
# dead row. #232 found three such rows in the PR #250 stand-in this file replaced (meme,
# detail, equipe, stored accented); this suite is the regression guard so that class of
# row cannot re-enter silently, whether from a hand-edit or from a future change to
# JIT_AWK_FOLD's own accent table making an existing entry's fold form change underneath
# it without anyone re-running the fold over this file.
#
# Usage: bash tests/test-generic-words-invariant.sh
#
# jit-drive: none -- every check below is a direct `grep -qF`/`grep -vE` against a
# known-short (single-word or single-line) needle; nothing here delegates to a reusable
# assert_* helper that could itself silently invert on a large payload (#56).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORDLIST="$REPO/data/generic-words.txt"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

echo "=== the bundled wordlist itself: every data row is a bare [a-z]+ word ==="

[ -f "$WORDLIST" ] || { echo "FAIL: $WORDLIST does not exist"; exit 1; }

BAD_LINES=$(LC_ALL=C grep -vE '^(#.*)?$' "$WORDLIST" | LC_ALL=C grep -vE '^[a-z]+$' || true)
if [ -z "$BAD_LINES" ]; then
  ok "no data row carries an accent, a digit, punctuation, whitespace or a capital"
else
  # Truncated by array slicing, never by piping into an early-exiting reader (#56's own
  # class -- this suite's sibling test-assertion-helpers.sh refuses a `| head` on sight).
  BAD_ARR=()
  while IFS= read -r line; do BAD_ARR+=("$line"); done <<<"$BAD_LINES"
  bad "found row(s) outside [a-z]+ -- these can never match a folded keyword" \
    "${BAD_ARR[*]:0:5}"
fi

echo ""
echo "=== POSITIVE CONTROL: the check above actually looks -- an accented row is caught ==="
# Without this, the PASS above could mean "the grep found nothing" for the wrong reason
# (a typo in the pattern, an empty file) as easily as for the right one.
TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t jitwordlist)
trap 'rm -rf "$TMPD"' EXIT
BAD_COPY="$TMPD/generic-words.txt"
cp "$WORDLIST" "$BAD_COPY"
printf 'detail\n' >> "$BAD_COPY"          # already-clean row: must NOT trip the check
printf '\xc3\xa9quipe\n' >> "$BAD_COPY"    # "équipe", accented: MUST trip the check

CONTROL_BAD=$(LC_ALL=C grep -vE '^(#.*)?$' "$BAD_COPY" | LC_ALL=C grep -vE '^[a-z]+$' || true)
if printf '%s' "$CONTROL_BAD" | LC_ALL=C grep -qF $'\xc3\xa9quipe'; then
  ok "an accented row planted in a copy is caught by the same check"
else
  bad "the check did not catch a planted accented row -- it would not catch a real one either"
fi

echo ""
echo "=== the classifier itself: a folded keyword reaches an ASCII-folded French entry ==="
# Not just "the file looks right" -- the thing #232 named as broken (meme, detail,
# equipe) must actually be reachable through the real matcher's own literal comparison,
# the same LC_ALL=C grep -Fxq rebuild-tsv.sh runs.
for w in meme detail equipe; do
  if LC_ALL=C grep -Fxq -- "$w" "$WORDLIST"; then
    ok "\"$w\" (the #232 dead-row example) is present and reachable"
  else
    bad "\"$w\" (the #232 dead-row example) is NOT reachable via grep -Fxq"
  fi
done

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
