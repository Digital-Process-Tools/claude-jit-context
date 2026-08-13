#!/bin/bash
# Three things this repository discarded or left uncovered while reporting success (#95).
#
# One shape, so one suite:
#   1. rebuild-tsv.sh drops a keyword matching VOCAB_KEYWORD_BLACKLIST and said nothing.
#   2. vocabulary/00-manual/jit-context.md carried `jit-context` and not `jit context`,
#      so the spelling a person types mid-sentence matched nothing.
#   3. paths/00-manual/entries.md was anchored on `.claude/` and `examples/` alone, so
#      editing the template entry we seed into every new project fired no rule at all.
#
# Every negative here is paired with a positive control in the same fixture. Without the
# pair, "the report is quiet" and "the harness is broken" are the same result -- which is
# the defect the whole issue is about, so a suite about it must not have it.
#
# Usage: bash tests/test-silent-drops.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
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
  if grep -qF -- "$want" <<<"$out"; then ok "$desc"
  else
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}

assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if grep -qF -- "$unwanted" <<<"$out"; then
    bad "$desc" "must NOT contain: $unwanted"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  else ok "$desc"
  fi
}

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "want [$want], got [$got]"; fi
}

TEST_DIR=$(mktemp -d) || { echo "  SKIPPED: no writable temp dir"; exit 2; }
trap 'rm -rf "$TEST_DIR"' EXIT

# --- 1. A dropped keyword is named at build time -----------------------------

# Two trees, identical but for one keyword. The clean one is the control: if the report
# names a keyword there, or names nothing in either, the assertions below are worthless.
mk_tree() {
  local root="$1" kws="$2"
  mkdir -p "$root/.claude/jit-context/vocabulary/00-manual" || return 1
  printf -- '---\ntitle: t\nkeywords: %s\n---\n\nbody\n' "$kws" \
    > "$root/.claude/jit-context/vocabulary/00-manual/invoicing.md"
}

CLEAN="$TEST_DIR/clean"
DIRTY="$TEST_DIR/dirty"
mk_tree "$CLEAN" "invoice, ledger" || { echo "  SKIPPED: could not build fixtures"; exit 2; }
mk_tree "$DIRTY" "file, invoice"   || { echo "  SKIPPED: could not build fixtures"; exit 2; }

echo "=== a keyword the blacklist drops is reported; a tree with none says so ==="

clean_out=$(CLAUDE_PROJECT_DIR="$CLEAN" bash "$REBUILD" 2>&1); clean_rc=$?
dirty_out=$(CLAUDE_PROJECT_DIR="$DIRTY" bash "$REBUILD" 2>&1); dirty_rc=$?

clean_rows=$(wc -l < "$CLEAN/.claude/jit-context/vocabulary/00-manual/00-index.tsv" | tr -d ' ')
dirty_rows=$(wc -l < "$DIRTY/.claude/jit-context/vocabulary/00-manual/00-index.tsv" | tr -d ' ')

# The harness probe. Both trees must have been indexed at all, and the drop must really
# happen -- otherwise "the report named it" could pass over an empty run.
assert_eq "control tree indexed both keywords"       "2" "$clean_rows"
assert_eq "blacklisted keyword really is dropped"    "1" "$dirty_rows"

# The quiet line is matched on its own words, not on "(none" -- the ambiguity report
# directly above prints "(none — all keywords appear in ≤5 files)", so the shorter
# needle passes over a tree where this section does not exist at all.
QUIET="every keyword in every entry was indexed"

assert_contains "the report has a section at all"    "$clean_out" "Keywords dropped"
assert_contains "a tree with no drops says so"       "$clean_out" "$QUIET"
assert_not_contains "and names no keyword"           "$clean_out" "invoicing.md:"

assert_contains "the dropped keyword is named"       "$dirty_out" '"file"'
assert_contains "with the entry it came from"        "$dirty_out" "invoicing.md"
assert_not_contains "and the tree is not called clean" "$dirty_out" "$QUIET"

# Advisory, like the ambiguity tally beside it: the keyword was listed for human
# searching and skipped by design, and the blacklist is project-configurable. Both trees
# exit 0, and the pair is what makes that assertion mean something.
assert_eq "a clean rebuild still exits 0"            "0" "$clean_rc"
assert_eq "a dropped keyword does not move the code" "0" "$dirty_rc"

# The report reads the blacklist actually in force, not a copy of the default list.
over_out=$(CLAUDE_PROJECT_DIR="$CLEAN" JIT_CONTEXT_KEYWORD_BLACKLIST='^(ledger)$' bash "$REBUILD" 2>&1)
assert_contains "an overridden blacklist is reported too" "$over_out" '"ledger"'
assert_not_contains "and the default word list is not consulted" "$over_out" '"invoice"'

# --- 2. The spelling people actually type ------------------------------------

echo ""
echo "=== jit-context.md answers both spellings, and nothing unrelated ==="

run_prompt() {
  printf '{"prompt":"%s"}' "$1" | CLAUDE_PROJECT_DIR="$REPO" bash "$PROMPT_HOOK" 2>/dev/null
}

# Vacuity guard: this drives the repository own committed index. If the hyphenated
# spelling does not fire, the tree is unreadable from here and every silence below is a
# statement about the harness rather than about the entry.
probe=$(run_prompt "how does jit-context work")
if ! grep -qF "jit-context.md" <<<"$probe"; then
  echo "  FAIL: harness cannot fire this repo own vocabulary tree -- results would be vacuous"
  echo "    got: ${probe:-<nothing>}"
  exit 1
fi
ok "the hyphenated spelling still fires"

assert_contains "the unhyphenated spelling fires" "$(run_prompt "how does jit context work")" "jit-context.md"
assert_not_contains "an unrelated prompt stays silent" \
  "$(run_prompt "please summarise the invoice run for last quarter")" "jit-context.md"

# --- 3. The seeded template entry is governed by entries.md ------------------

echo ""
echo "=== entries.md reaches the template we seed into every new project ==="

fired_for() {
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$DRYRUN" --file "$1" 2>&1) \
    | awk '/pre-path-hook[.]sh/ { $1=""; print }'
}

path_probe=$(fired_for "scripts/pre-path-hook.sh")
if ! grep -qF "hooks.md" <<<"$path_probe"; then
  echo "  FAIL: harness cannot evaluate this repo path tree -- every silence below is vacuous"
  exit 1
fi

assert_contains "the seeded template entry"  "$(fired_for "templates/jit-context/vocabulary/00-manual/writing-rules.md")" "entries.md"
assert_contains "our own entry tree still"   "$(fired_for ".claude/jit-context/paths/00-manual/hooks.md")" "entries.md"
assert_contains "the shipped examples still" "$(fired_for "examples/jit-context/tools/00-manual/git.md")" "entries.md"

# Widening for templates/ must reach templates/jit-context/ and nothing else.
assert_not_contains "a doc beside the template" "$(fired_for "templates/README.md")" "entries.md"
assert_not_contains "an unrelated jit-context path" "$(fired_for "docs/jit-context/notes.md")" "entries.md"
# The alternation is anchored on a path component, not on a fragment: a directory ENDING
# in the name is the same defect the scratchpad path below was.
assert_not_contains "a lookalike directory" "$(fired_for "mytemplates/jit-context/x.md")" "entries.md"
assert_not_contains "a session scratchpad path" \
  "$(fired_for "/private/tmp/claude-501/-Users-x-Documents-claude-jit-context/y/scratchpad/note.md")" "entries.md"

# tests/test-dogfood-entries.sh asserts this too, deliberately: the template is
# documentation, not one of the five tools. Repeated here because making entries.md reach
# templates/ is exactly the change that could drag tooling.md along with it.
assert_not_contains "and tooling.md still does not claim it" \
  "$(fired_for "templates/jit-context/vocabulary/00-manual/writing-rules.md")" "tooling.md"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
