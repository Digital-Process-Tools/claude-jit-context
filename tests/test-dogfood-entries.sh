#!/bin/bash
# Tests for THIS repository's own entries in .claude/jit-context/.
#
# Every other suite builds a synthetic tree and tests the hooks against it. That
# proves the engine works and says nothing about the rules we actually ship to
# ourselves — which is where an unanchored pattern hides, because it fires often
# enough to look alive and nobody checks what else it fired on.
#
# Both directions for every rule: a path it must match, and a near-miss it must not.
#
# Usage: bash tests/test-dogfood-entries.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

# Which rules fired for one sample path, as reported by the dry-run against this repo.
#
# cd into the repo: the dry-run resolves the tree it evaluates from the working
# directory, so running this from tests/ made EVERY sample return nothing — and the
# assert_silent cases all passed on that emptiness. A vacuous pass is the exact defect
# this suite is about, so the guard below fails loudly instead of trusting the silence.
fired_for() {
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$DRYRUN" --file "$1" 2>&1) \
    | awk '/pre-path-hook\.sh/ { $1=""; print }'
}

# Proves the harness can see the tree at all. Without it, every assert_silent below
# would pass in an environment where the dry-run silently evaluates nothing.
if ! fired_for "scripts/pre-path-hook.sh" | grep -q "hooks.md"; then
  echo "  FAIL: harness cannot evaluate this repo's own tree — every result below would be vacuous"
  exit 1
fi

assert_fires() {
  local desc="$1" path="$2" rule="$3" out
  out=$(fired_for "$path")
  if echo "$out" | grep -qF "$rule"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected $rule to fire for: $path"
    echo "    got: ${out:-<nothing>}"
  fi
}

assert_silent() {
  local desc="$1" path="$2" rule="$3" out
  out=$(fired_for "$path")
  if echo "$out" | grep -qF "$rule"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    $rule must NOT fire for: $path"
    echo "    got: $out"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

echo "=== entries.md fires on an entry, and only on an entry ==="
assert_fires  "our own entry tree"     ".claude/jit-context/paths/00-manual/hooks.md" "entries.md"
assert_fires  "the shipped examples"   "examples/jit-context/tools/00-manual/git.md"  "entries.md"
# The bug this suite was written for. The scratchpad path a Claude Code session hands
# out is derived from the project directory, so for THIS repo it contains the string
# "claude-jit-context" — and a pattern anchored on the bare fragment "jit-context/"
# matched every temporary .md file written during a session. Observed twice in one day.
assert_silent "a session scratchpad path" \
  "/private/tmp/claude-501/-Users-floriandavid-Documents-claude-jit-context/x/scratchpad/note.md" \
  "entries.md"
assert_silent "a doc that is not an entry" "docs/contributing.md" "entries.md"
assert_silent "the README"                 "README.md"            "entries.md"

echo ""
echo "=== hooks.md fires on a hook script, and only on one ==="
assert_fires  "a hook script"          "scripts/pre-path-hook.sh" "hooks.md"
assert_silent "a non-hook script"      "scripts/rebuild-tsv.sh"   "hooks.md"
assert_silent "a test for a hook"      "tests/test-pre-path-hook.sh" "hooks.md"

echo ""
echo "=== release.md fires on the manifest only ==="
assert_fires  "the plugin manifest"    ".claude-plugin/plugin.json" "release.md"
assert_silent "some other json"        ".supertool.json"            "release.md"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
