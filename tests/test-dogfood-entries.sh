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
# jit-init.sh must never inherit "every failure path exits 0" -- it exits 1 to refuse an
# overwrite and 2 when it cannot evaluate the request.
assert_silent "the project seeder"     "scripts/jit-init.sh"       "hooks.md"

echo ""
echo "=== tooling.md fires on the five build, diagnostic and release scripts ==="
assert_fires  "the index writer"       "scripts/rebuild-tsv.sh"    "tooling.md"
# Seeds a project and refuses rather than overwriting, so it is run deliberately by a
# person and fails loudly (#81). It carried no rule at all until this file named it --
# hooks.md's pattern does not reach it either, so it was a script in scripts/ that the
# repo's own knowledge said nothing about.
assert_fires  "the project seeder"     "scripts/jit-init.sh"       "tooling.md"
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
assert_silent "the seeder's own suite"  "tests/test-jit-init.sh"   "tooling.md"
# The template the seeder copies is documentation, not one of the tools.
assert_silent "the seeded template"     "templates/jit-context/vocabulary/00-manual/writing-rules.md" "tooling.md"

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
echo "=== every file under scripts/ is governed by some paths/ rule ==="
# The class behind #83 rather than the instance. `hooks.md` matches the hooks and
# `common.sh`; `tooling.md` names its tools by hand, one alternation per script. A file that
# is neither matched nothing, and `scripts/jit-init.sh` shipped exactly like that: the
# repository's own knowledge said nothing about the file its author was editing, and an
# absence produced by the tool is unreadable from an absence in the world. Widening one
# `match` fixed that file; only a red leg fixes the next one.
#
# COVERED MEANS ANY paths/ RULE FIRES, not a rule from a fixed set. "hooks.md or tooling.md"
# would be the stronger assertion and it would freeze today's two-way split into the suite:
# a script under a third contract would be red while being perfectly documented, and the
# leg would then be asserting the shape of the tree rather than its coverage. The question
# asked here is the one the defect was about -- does this repository say anything at all
# when you open this file?
#
# The consequence is why #83's option 2, a catch-all entry matching `scripts/` broadly, was
# NOT built alongside this: such an entry satisfies every assertion below by construction,
# and this leg could never go red again. The test and the catch-all do not compose.
#
# Scope is `scripts/`: what ships inside the plugin and runs in a user's project.
# `.github/scripts/` is CI, and `tooling.md` reaches it today only because
# `assemble_changelog.py` is named there -- requiring a jit-context rule for every future
# workflow helper is a bar nobody has agreed to.

# Positive control for the reading below, and it earned its place on the first run: a
# governed file is one whose dry-run line names a `.md`, NOT one whose line is non-empty.
# jit-dry-run.sh prints the words "no rule fired" for a miss, precisely so a hook that
# matched nothing cannot read as a hook that fired -- so the first draft of this section
# tested for non-empty output and reported a deliberately uncovered script as covered.
# That is the defect this whole suite is about, reproduced inside the fix for it.
uncovered_probe=$(fired_for "docs/nothing-governs-this.txt")
if grep -qE '[^[:space:]]+[.]md' <<<"$uncovered_probe"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: control -- an ungoverned path must name no rule"
  echo "    got: $uncovered_probe"
  echo "    every coverage assertion below is vacuous"
else
  PASS=$((PASS + 1)); echo "  PASS: control -- an ungoverned path names no rule"
fi

# Enumerated from the repository, not listed here: a list in this file is the same
# enumeration the defect is about, one directory further away.
#
# `git ls-files`, not `find`: the question is what SHIPS in scripts/, and find also returns
# a .DS_Store, an editor backup and a merge .orig, each of which would redden this section
# for a reason that has nothing to do with rule coverage. The cost is that a brand-new
# script is invisible here until it is staged, which is before CI sees it either.
script_list=$(cd "$REPO" && git ls-files -- scripts | LC_ALL=C sort)
if ! grep -q '^scripts/common[.]sh$' <<<"$script_list"; then
  echo "  FAIL: could not enumerate scripts/ -- every coverage assertion below would be vacuous"
  exit 1
fi

while IFS= read -r script; do
  [ -n "$script" ] || continue
  fired=$(fired_for "$script")
  if grep -qE '[^[:space:]]+[.]md' <<<"$fired"; then
    PASS=$((PASS + 1)); echo "  PASS: $script is governed by:$fired"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $script matches no rule in .claude/jit-context/paths/"
    echo "    a new script starts uncovered, and an uncovered script reads exactly like one"
    echo "    with nothing to say about it (#83). Widen a match in paths/00-manual/, or write"
    echo "    the entry that states its contract, then rebuild: bash scripts/rebuild-tsv.sh"
  fi
done <<<"$script_list"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
