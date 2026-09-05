#!/bin/bash
# #348: list_whole() in jit-dry-run.sh reads the frontmatter's first line with
# `IFS= read -r _fm_first < "$md" 2>/dev/null`. Redirections apply left to right, so
# the INPUT redirect (`< "$md"`) is set up before the `2>/dev/null` on the read builtin
# takes effect -- an unreadable entry file makes bash print its own "Permission denied"
# to the REAL stderr before the read's own redirect ever runs, exactly the leak
# truncate_index() in rebuild-tsv.sh and jit_log_write() in common.sh already document
# and fix by putting 2>/dev/null FIRST. The comment directly above the line claims the
# opposite: that an unreadable file leaves $_fm_first empty and takes the same branch
# silently.
#
# The neighbouring `size=$(( $(wc -c < "$md") ))` has the identical ordering problem and
# no suppression at all.
#
# Usage: bash tests/test-list-whole-stderr-348.sh

# jit-drive: none -- this suite has no assert_* helper; every verdict is a direct grep
# against a file this test itself wrote, checked inline against ok()/bad()

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
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

if [ "$(id -u 2> /dev/null || echo 1)" = "0" ]; then
  echo "  SKIPPED: running as root -- a permission-denied fixture cannot be built (root reads everything)"
  exit 2
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
BASE="$TEST_DIR/.claude/jit-context"
TOOLS_DIR="$BASE/tools/00-manual"
mkdir -p "$TOOLS_DIR" "$BASE/paths/00-manual" "$BASE/vocabulary/00-manual"

# --- Positive control: an ORDINARY, readable entry must still list and print nothing
# to stderr about it -- the leak has to be specific to the unreadable file, not a
# symptom of every entry now going silent.
printf '%s\n' \
  "---" \
  "title: Readable" \
  "description: An ordinary readable entry." \
  "tool: Bash" \
  "match: git readable-348" \
  "mode: remind" \
  "---" \
  "" \
  "READABLE-348-BODY" > "$TOOLS_DIR/readable-348.md"

# --- The unreadable fixture: exists, has content, but chmod 000 denies the read.
UNREADABLE="$TOOLS_DIR/unreadable-348.md"
printf '%s\n' \
  "---" \
  "title: Unreadable" \
  "description: An entry this process cannot read." \
  "tool: Bash" \
  "match: git unreadable-348" \
  "mode: remind" \
  "---" \
  "" \
  "UNREADABLE-348-BODY" > "$UNREADABLE"

# jit-dry-run.sh refuses to run at all over a tree with no 00-index.tsv anywhere
# (SKIPPED, exit 2) -- list_whole() scans the *.md glob directly and does not need an
# index, but the script it lives in gates on one existing first. Build the index while
# the fixture is still readable, then lock it down -- this test is about the READ in
# list_whole(), not about whether rebuild-tsv.sh itself can see the file.
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO/scripts/rebuild-tsv.sh" > /dev/null 2>&1
chmod 000 "$UNREADABLE"

# Control on the fixture itself: if this process can still read a chmod-000 file (root,
# an ACL, a filesystem that ignores the bit), the whole test is vacuous.
if [ -r "$UNREADABLE" ]; then
  echo "  SKIPPED: this process can still read a chmod 000 file -- nothing was measured"
  chmod 644 "$UNREADABLE" 2> /dev/null
  exit 2
fi

STDOUT_F="$TEST_DIR/out.txt"
STDERR_F="$TEST_DIR/err.txt"
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$DRYRUN" --base "$BASE" > "$STDOUT_F" 2> "$STDERR_F"
RC=$?

chmod 644 "$UNREADABLE" 2> /dev/null

if grep -q "readable-348" "$STDOUT_F"; then
  ok "control: the readable sibling is reported on"
else
  bad "control: the readable sibling is reported on" "$(cat "$STDOUT_F")"
fi

if [ "$RC" -le 2 ]; then
  ok "control: the lint completed (exit $RC)"
else
  bad "control: the lint completed" "exit $RC"
fi

# The needle is bash's OWN redirect-failure diagnostic ("script: line N: path:
# Permission denied"), not any "Permission denied" byte anywhere in stderr: a separate,
# already-existing awk invocation a few lines above this (jit_frontmatter_many(), which
# hands the same unreadable path to awk as an argument) fails with its own "awk: can't
# open file" message, in a different format with no bash line number, and that leak is
# not what #348 is about -- widening this assertion to swallow it would make this test
# pass by accident on a tree that fixed nothing.
if grep -Eq "jit-dry-run\.sh: line [0-9]+: .*Permission denied" "$STDERR_F"; then
  bad "list_whole()'s read/wc on an unreadable entry leak nothing to real stderr" \
    "stderr: $(cat "$STDERR_F")"
else
  ok "list_whole()'s read/wc on an unreadable entry leak nothing to real stderr"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
