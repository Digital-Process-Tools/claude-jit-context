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
# Captured first, not piped: `grep -q` exits on the match and the writer on the left of
# the pipe takes SIGPIPE, which under pipefail turns a found string into a non-zero
# status. That is issue #56, and here it would have inverted the guard itself.
harness_probe=$(fired_for "scripts/pre-path-hook.sh")
if ! grep -q "hooks.md" <<<"$harness_probe"; then
  echo "  FAIL: harness cannot evaluate this repo's own tree — every result below would be vacuous"
  exit 1
fi

assert_fires() {
  local desc="$1" path="$2" rule="$3" out
  out=$(fired_for "$path")
  if grep -qF "$rule" <<<"$out"; then
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
  if grep -qF "$rule" <<<"$out"; then
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
echo "=== hooks.md fires on code that runs in someone else session ==="
assert_fires  "a hook script"          "scripts/pre-path-hook.sh"  "hooks.md"
assert_fires  "the session-start hook" "scripts/session-start-hook.sh" "hooks.md"
# common.sh is sourced by all four hooks, so every sentence in hooks.md applies to it
# verbatim -- and it is where every containment fix in 0.3.0 landed. It carried no rule
# at all until #42.
assert_fires  "the shared library"     "scripts/common.sh"         "hooks.md"
# The three tooling scripts must NOT get this entry. "Every failure path exits 0" is
# actively wrong for rebuild-tsv.sh, and jit-dry-run.sh exits 1 and 2 on purpose. A false
# rule fires more expensively than no rule, because it arrives with the same authority.
assert_silent "the index writer"       "scripts/rebuild-tsv.sh"    "hooks.md"
assert_silent "the linter"             "scripts/jit-dry-run.sh"    "hooks.md"
assert_silent "the miss reporter"      "scripts/jit-misses.sh"     "hooks.md"
assert_silent "a test for a hook"      "tests/test-pre-path-hook.sh" "hooks.md"
# Same defect class as the scratchpad path above: an unanchored pattern matches the
# fragment wherever it appears, so a directory ENDING in "scripts" claims the rule.
assert_silent "a lookalike directory"  "myscripts/common.sh"       "hooks.md"

echo ""
echo "=== tooling.md fires on the four build, diagnostic and release scripts ==="
assert_fires  "the index writer"       "scripts/rebuild-tsv.sh"    "tooling.md"
assert_fires  "the linter"             "scripts/jit-dry-run.sh"    "tooling.md"
assert_fires  "the miss reporter"      "scripts/jit-misses.sh"     "tooling.md"
# Same contract, same reason: it is run at a tag by a person, never in a stranger's
# session, so it fails loudly with exit codes that mean distinct things (#66).
assert_fires  "the changelog assembler" ".github/scripts/assemble_changelog.py" "tooling.md"
assert_silent "a lookalike outside .github"  "scripts/assemble_changelog.py" "tooling.md"
# The inverse of the split above: these run in someone else session and are governed by
# hooks.md, so the tooling contract must not reach them.
assert_silent "a hook script"          "scripts/pre-tool-hook.sh"  "tooling.md"
assert_silent "the shared library"     "scripts/common.sh"         "tooling.md"
assert_silent "a suite about a tool"   "tests/test-jit-dry-run.sh" "tooling.md"
assert_silent "a lookalike directory"  "vendor/subscripts/jit-misses.sh" "tooling.md"

echo ""
echo "=== tests.md fires on a suite, and only on a suite ==="
assert_fires  "a hook suite"           "tests/test-pre-path-hook.sh" "tests.md"
assert_fires  "the runner"             "tests/run-all.sh"          "tests.md"
assert_silent "a hook script"          "scripts/pre-path-hook.sh"  "tests.md"
assert_silent "the shared library"     "scripts/common.sh"         "tests.md"
assert_silent "a fixture below tests/" "tests/fixtures/tree/setup.sh" "tests.md"
assert_silent "a lookalike directory"  "contests/entry.sh"         "tests.md"

echo ""
echo "=== release.md fires on the manifest only ==="
assert_fires  "the plugin manifest"    ".claude-plugin/plugin.json" "release.md"
assert_silent "some other json"        ".supertool.json"            "release.md"

echo ""
echo "=== changelog.md fires on the assembled file, and not on the fragments ==="
assert_fires  "the assembled file"     "CHANGELOG.md"               "changelog.md"
assert_fires  "it from a subdirectory" "vendor/thing/CHANGELOG.md"  "changelog.md"
# The directory documents itself, and a rule saying "do not edit this, write a fragment"
# arriving while you write a fragment is the rule firing against its own advice.
assert_silent "the convention page"    "changelog.d/README.md"      "changelog.md"
assert_silent "a fragment"             "changelog.d/70.fixed.md"    "changelog.md"
assert_silent "a lookalike name"       "docs/CHANGELOG.md.tmpl"     "changelog.md"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
