#!/bin/bash
# rebuild-tsv.sh: the exit code says which of three things happened (#47).
#
# The index writer detected a macro it could not expand, said so on stderr, and returned
# 0. So a clean rebuild and a rebuild that indexed a row the matcher will refuse at load
# time were the same result -- unreadable to CI, to a pre-commit hook, and to anyone who
# redirected stderr. An index built by a warned rebuild looks exactly like a good one on
# disk, and it is committed and lives for months.
#
#   0  the index was written and every row can be honoured
#   1  the index was written, and at least one row will be REFUSED by the matcher
#   2  the index was not written, or not completely -- what is on disk is not this run
#
# 1 is reachable only through a `~@macro` the author wrote and got wrong; a pattern that
# is not a macro is returned unchanged and cannot produce it. That is why this is not a
# --strict flag: the person whose `&&` chain stops is the person who just wrote the dead
# rule, and a flag only CI passes would hand the interactive author back the exit 0 that
# is the bug. The ADVISORY reports -- ambiguous keywords, keywords the blacklist dropped,
# entries with no description:, and entries that produced no index row (#44) -- never move
# the code, and section E holds that line.
#
# Every non-zero case here is paired with a clean tree that still exits 0 in the same
# fixture. Without that pair, "always exit 1" would pass this suite.
#
# Usage: bash tests/test-rebuild-exit-codes.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

# Here-string, never a pipe: `| grep -q` exits on the first match and the writer takes
# SIGPIPE, which under pipefail reports the opposite of what was found (#56).
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
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

assert_rc() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted exit $want, got exit $got"
  fi
}

ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t jit47)"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
BASE="$ROOT/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual" "$BASE/paths/00-manual" "$BASE/vocabulary/00-manual"

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

ERR="$ROOT/rebuild.err"
RC=0
# Runs the real script the way a person does, and keeps BOTH halves: an exit code with no
# stderr beside it cannot show that the reason reached a reader.
rebuild() {
  CLAUDE_PROJECT_DIR="${1:-$ROOT}" bash "$REBUILD" >/dev/null 2>"$ERR"
  RC=$?
  return 0
}

write_entry tools/00-manual/git-push.md \
  "title: Open a merge request instead" \
  "description: git push to a shared branch goes through review." \
  "tool: Bash" \
  "match: ~@invocation git push" \
  "mode: block"

write_entry paths/00-manual/hooks-file.md \
  "title: The hook contract" \
  "description: Hooks never fail hard." \
  "match: (^|/)scripts/[a-z-]+-hook[.]sh$"

write_entry vocabulary/00-manual/widget.md \
  "title: Widget" \
  "description: What a widget is here." \
  "keywords: widget-alpha, widget-core"

echo "=== A. a tree whose every row can be honoured exits 0 ==="
rebuild
assert_rc "a clean rebuild exits 0" 0 "$RC"
assert_contains "and the honourable rule was indexed" \
  "$(cat "$BASE/tools/00-manual/00-index.tsv")" "git-push.md"

echo ""
echo "=== B. a macro the writer cannot expand exits 1, and still writes the row ==="
write_entry tools/00-manual/bogus.md \
  "title: Bogus" \
  "description: A macro nobody defined." \
  "tool: Bash" \
  "match: ~@invokation git push" \
  "mode: block"
rebuild
assert_rc "a refused macro exits 1" 1 "$RC"
assert_contains "and names the entry"     "$(cat "$ERR")" "bogus.md"
assert_contains "and names the macro"     "$(cat "$ERR")" "@invokation"
# Written through unexpanded on purpose -- the hook then refuses that row by name. An
# exit 1 that also DROPPED the rule would be a different, worse change.
assert_contains "the row is written through unexpanded" \
  "$(cat "$BASE/tools/00-manual/00-index.tsv")" "@invokation"
assert_contains "and the honourable rule beside it is still indexed" \
  "$(cat "$BASE/tools/00-manual/00-index.tsv")" "git-push.md"

echo ""
echo "=== C. remove it and the same tree exits 0 again ==="
# The pair that makes B mean something: without it, "always exit 1" passes section B.
rm -f "$BASE/tools/00-manual/bogus.md"
rebuild
assert_rc "the repaired tree exits 0" 0 "$RC"

echo ""
echo "=== D. a macro in paths is refused too, and moves the code the same way ==="
write_entry paths/00-manual/wrong.md \
  "title: Wrong dimension" \
  "description: A command macro on a file path." \
  "match: ~@invocation git push"
rebuild
assert_rc "a paths macro exits 1" 1 "$RC"
assert_contains "and names that entry" "$(cat "$ERR")" "wrong.md"
rm -f "$BASE/paths/00-manual/wrong.md"
rebuild
assert_rc "and removing it returns to 0" 0 "$RC"

echo ""
echo "=== E. an ADVISORY report never moves the exit code ==="
# An ambiguous keyword and a missing description: are both costs, not broken rows. The
# entries fire correctly; nothing is refused. If either moved the code, the default tree
# -- inject=full, descriptions optional by documented design -- would exit non-zero for
# a state the README calls fine, and every author would learn to ignore the status.
i=1
while [ "$i" -le 6 ]; do
  write_entry "vocabulary/00-manual/ambig-$i.md" \
    "title: Ambiguous $i" \
    "description: One of six entries sharing a keyword." \
    "keywords: sharedterm, ambig-$i"
  i=$((i + 1))
done
write_entry tools/00-manual/nodesc.md \
  "title: No description here" \
  "tool: Bash" \
  "match: some-literal-substring" \
  "mode: remind"
rebuild
assert_rc "an ambiguous keyword and a missing description: still exit 0" 0 "$RC"
assert_contains "the ambiguity report still fired" "$(cat "$ERR")" "sharedterm"
# The no-description report belongs to the injection budget (#1) and is not on this
# branch. What #47 asserts here is only that an advisory finding never moves the code:
# the entry with no description: is still indexed, and the run still exits 0 above.
# And the codes are not simply unreachable on this fixture: put the bad macro back beside
# the advisories and 1 comes through them.
write_entry tools/00-manual/bogus.md \
  "title: Bogus" \
  "description: A macro nobody defined." \
  "tool: Bash" \
  "match: ~@invokation git push" \
  "mode: block"
rebuild
assert_rc "a refused row beside the advisories still exits 1" 1 "$RC"
rm -f "$BASE/tools/00-manual/bogus.md"
rebuild
assert_rc "and the tree is clean again" 0 "$RC"

echo ""
echo "=== F. no entry tree at all is 2 -- could not evaluate, not a clean rebuild ==="
# JIT_BASE resolves against CLAUDE_PROJECT_DIR and never the working directory, so
# rebuilding from the wrong root indexed nothing and reported success. That is the exact
# state this repository calls its second trap, and it read as green.
EMPTY="$(mktemp -d 2>/dev/null || mktemp -d -t jit47b)"
rebuild "$EMPTY"
assert_rc "a project with no jit-context tree exits 2" 2 "$RC"
assert_contains "and names the path it looked for" "$(cat "$ERR")" "$EMPTY/.claude/jit-context"
assert_not_contains "and does not claim to have indexed anything" "$(cat "$ERR")" "entr(ies) indexed"
# The base DIRECTORY is not the assertion, and since #51 it is not created here either:
# common.sh creates "$JIT_BASE/.discovery/logs" when it is sourced only where "$JIT_BASE"
# already exists, which in this fixture it does not. What must be true is what was always
# the point -- that no index was written, since an index is the thing whose absence exit 0
# would deny. Asserting on the directory instead would now pass for a second reason and
# stop being evidence about this script at all.
if [ -n "$(find "$EMPTY" -name "00-index.tsv" -print 2>/dev/null)" ]; then
  bad "it wrote no index under a root it could not evaluate"
else
  ok "it wrote no index under a root it could not evaluate"
fi
rm -rf "$EMPTY"
rebuild
assert_rc "the real tree beside it still exits 0" 0 "$RC"

echo ""
echo "=== G. an index it cannot write is 2, not a count read back off the stale file ==="
# Truncating the index failing left the previous one in place while the run reported the
# rule count it read back OUT of that stale file -- success, with a number, for an index
# nobody rebuilt.
TSV="$BASE/tools/00-manual/00-index.tsv"
chmod 444 "$TSV" 2>/dev/null
# The probe is an actual open-for-write, not `[ -w ]`. Root passes `-w` on a mode nobody
# can write, and Git Bash answers it from an emulated attribute -- both of which decide
# this section by a proxy for the capability rather than the capability. An append of zero
# bytes takes the same permission check as the truncation and changes nothing.
if printf %s "" >> "$TSV" 2>/dev/null; then
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section G tested nothing."
else
  rebuild
  assert_rc "an unwritable index exits 2" 2 "$RC"
  # The phrase, not the path: bash prints its own "Permission denied" naming the file
  # whatever this script does, so a bare name grep passed before the fix existed.
  assert_contains "and says that index is now stale" "$(cat "$ERR")" "was NOT rebuilt"
fi
chmod 644 "$TSV" 2>/dev/null
rebuild
assert_rc "and once it is writable again, 0" 0 "$RC"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
