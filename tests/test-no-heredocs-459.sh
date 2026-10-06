#!/bin/bash
# #459: the Anthropic directory validator holds COMMAND_SCRIPT_NOT_FOLLOWED on any
# command script that "hands a here-document to a program" -- a real `<<WORD` /
# `<<-WORD` heredoc operator anywhere under scripts/, regardless of whether the body
# is read by a loop rather than piped to an external interpreter. Every one that
# existed (stop-hook.sh, common.sh, host.sh, jit-doctor.sh, jit-misses.sh,
# jit-dry-run.sh) was rewritten as a here-string (`<<<`) in this same change; this
# suite is the regression guard so a future edit cannot silently reintroduce one.
#
# A real heredoc operator must be told apart from three things that are NOT one and
# must never be flagged: a here-string (`<<<`, one more `<` than a heredoc), a
# heredoc operator's OWN spelling appearing as data inside a quoted string (the
# `" << "` token jit-misses.sh/jit-doctor.sh use to format a hook-log line, or the
# `"[^<]<<-?[ \t]*"` regex fragment common-awk.sh builds as a string to detect one),
# and a comment describing any of the above (common-awk.sh's own extensive heredoc
# commentary). detect_heredoc_lines() below is exercised by its own positive and
# negative controls on a planted fixture before it is trusted against the real tree,
# because a sweep that finds nothing can mean "there is nothing" or "the pattern
# never matched anything, ever" and those two must not look the same.
#
# Usage: bash tests/test-no-heredocs-459.sh
#
# jit-drive: none -- this suite scans tracked files for a text shape; it defines no assertion helper

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

# Single and double quote bytes, built the way common-awk.sh builds its own quote
# class (`sprintf("%c", 39)`), rather than embedding a literal quote inside an ERE
# string where bash's own quoting would have to be threaded around it.
Q1=$(printf '\047')
Q2=$(printf '\042')

# A real heredoc opener: `<<` or `<<-`, not immediately followed by a third `<`
# (which would make it a here-string), then optional whitespace, an optional single
# or double quote, and the identifier that is the heredoc delimiter. The `(^|[^<])`
# prefix is load-bearing: it refuses to let a match start on the SECOND `<` of a
# `<<<` by requiring the character immediately before the matched `<<` not itself be
# a `<` -- so neither alignment attempt over a `<<<` sequence can match. The
# delimiter's own first character is `[A-Za-z0-9_]`, not `[A-Za-z_]` (self-review
# on #459): a bash heredoc delimiter is an ordinary shell word and bash accepts one
# that starts with a digit (`cat <<1EOF` is a real, working heredoc) -- a
# letter-only start would have let exactly that shape back in undetected.
HEREDOC_PATTERN="(^|[^<])<<-?[[:space:]]*[${Q1}${Q2}]?[A-Za-z0-9_][A-Za-z0-9_]*"

# detect_heredoc_lines FILE -- prints "LINENO: TEXT" for every line that opens a real
# heredoc, comment lines excluded. Blanks comment lines rather than deleting them
# (awk) before the grep -nE pass, so the line numbers grep reports stay the file's
# own.
#
# #478: awk's own exit status is captured BEFORE the grep -nE pass, not folded
# into the pipeline's "|| true". A file that vanishes, loses read permission,
# or otherwise makes awk fail produces the exact same empty string as a file
# that was genuinely read and found clean -- the caller could not tell "no
# heredoc here" from "could not read this file at all". Return 2 on an awk
# failure so a caller can tell the two apart instead of treating both as the
# same empty, clean result.
detect_heredoc_lines() {
  local filtered awk_rc
  filtered=$(awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$1" 2>&1)
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "AWK_READ_FAILED($1): $filtered" >&2
    return 2
  fi
  printf '%s\n' "$filtered" | grep -nE -- "$HEREDOC_PATTERN" || true
}

echo "=== DETECTOR SELF-TEST: a planted fixture, both directions ==="

TMPD=$(mktemp -d 2> /dev/null || mktemp -d -t jitheredoc)
trap 'rm -rf "$TMPD"' EXIT
FIXTURE="$TMPD/fixture.sh"
cat > "$FIXTURE" << 'FIXTURE_EOF'
#!/bin/bash
# a comment mentioning << EOF must never trip the detector
# `[shown:1] << git push` is log-format text in a comment, not a heredoc
_log_hook() { :; }
_log_hook "pre-tool" "1" "x" "[shown:1] << $AWK_TEXT"
q_literal="index(rest, \" << \")"
while IFS= read -r line; do
  n=$((n + 1))
done <<< "$pats"
IFS='|' read -r _ _ _ <<< "$row"
while IFS= read -r body_line; do
  echo "$body_line"
done << REAL_HEREDOC
this is a real heredoc body
REAL_HEREDOC
while IFS= read -r body_line; do
  echo "$body_line"
done <<1EOF
a heredoc whose delimiter starts with a digit is still a real heredoc
1EOF
FIXTURE_EOF

FIXTURE_HITS="$(detect_heredoc_lines "$FIXTURE")"

if grep -q '^13:' <<< "$FIXTURE_HITS"; then
  ok "POSITIVE: the planted real \`done << REAL_HEREDOC\` (line 13) is caught"
else
  bad "POSITIVE: the planted real heredoc was NOT caught -- the detector cannot see a real one" \
    "$FIXTURE_HITS"
fi

if grep -q '^18:' <<< "$FIXTURE_HITS"; then
  ok "POSITIVE: a planted \`done <<1EOF\` (line 18) -- a digit-leading delimiter, a real heredoc bash accepts -- is caught"
else
  bad "POSITIVE: the digit-leading heredoc was NOT caught -- a letter-only identifier class would let this class of delimiter back in undetected" \
    "$FIXTURE_HITS"
fi

FALSE_POSITIVE_LINES="2 3 5 6 8 9"
ANY_FALSE_POSITIVE=0
for ln in $FALSE_POSITIVE_LINES; do
  if grep -q "^${ln}:" <<< "$FIXTURE_HITS"; then
    ANY_FALSE_POSITIVE=1
    bad "NEGATIVE: line $ln (a comment, a quoted log token, a here-string, or an IFS read <<<) was wrongly flagged"
  fi
done
[ "$ANY_FALSE_POSITIVE" -eq 0 ] && ok "NEGATIVE: comments, quoted \"<< \" tokens, and here-strings (<<<) are not flagged"

# #478: an unreadable/vanished file must render distinguishably from a clean
# one -- both used to produce the same empty string. Positive control (a
# genuine read failure IS reported) paired with the clean-file negative
# control already proven above, so a harness that reports nothing for
# everything cannot pass this pair.
detect_heredoc_lines "$TMPD/does-not-exist-478.sh" > /dev/null 2> /dev/null
UNREADABLE_RC=$?
if [ "$UNREADABLE_RC" -eq 2 ]; then
  ok "POSITIVE: a vanished/unreadable file is reported as a read failure (rc=2), not silently 'clean'"
else
  bad "POSITIVE: a vanished/unreadable file should return rc=2, got rc=$UNREADABLE_RC -- indistinguishable from a clean file"
fi

detect_heredoc_lines "$FIXTURE" > /dev/null 2> /dev/null
CLEAN_RC=$?
[ "$CLEAN_RC" -eq 0 ] \
  && ok "NEGATIVE: a real, readable file still returns rc=0 (the read-failure path does not fire on a clean read)" \
  || bad "NEGATIVE: a readable file should return rc=0, got rc=$CLEAN_RC"

echo ""
echo "=== LIVE SWEEP: every tracked file under scripts/ ==="

cd "$REPO" || exit 1
SCRIPTS_FILES=$(git ls-files scripts)
if [ -z "$SCRIPTS_FILES" ]; then
  bad "git ls-files scripts returned nothing -- the sweep below would pass for the wrong reason"
else
  VIOLATIONS=""
  UNREADABLE=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    HITS="$(detect_heredoc_lines "$REPO/$f" 2> /dev/null)"
    DETECT_RC=$?
    if [ "$DETECT_RC" -eq 2 ]; then
      UNREADABLE="$UNREADABLE
$f"
      continue
    fi
    [ -n "$HITS" ] || continue
    VIOLATIONS="$VIOLATIONS
$f:
$HITS"
  done <<< "$SCRIPTS_FILES"

  if [ -n "$UNREADABLE" ]; then
    bad "could not scan every tracked file under scripts/ -- the sweep below is incomplete, not clean" \
      "$UNREADABLE"
  elif [ -z "$VIOLATIONS" ]; then
    ok "no tracked file under scripts/ opens a real here-document"
  else
    bad "a real here-document was found under scripts/ -- the directory validator holds on this" \
      "$VIOLATIONS"
  fi
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
