#!/bin/bash
# #347: check_index_current() in jit-dry-run.sh reconstructs the expected TSV row by
# hand, but did not apply the two normalisations rebuild-tsv.sh (#333) actually makes:
#
#   * jit_tsv_field() -- an interior tab, CR or LF in a frontmatter value becomes a
#     single space, on every column that goes into the row.
#   * JIT_VALID_MODE_RE -- a tools entry whose ASSEMBLED mode is not remind/block/once
#     is refused at index time; rebuild-tsv.sh writes no row for it at all, permanently.
#
# Without those, check_index_current() reported false STALE for an entry rebuild-tsv.sh
# correctly and permanently omits (an invalid mode), and for any entry whose frontmatter
# carries a literal tab in a value rebuild-tsv.sh writes with the tab folded to a space.
# Positive controls throughout: a valid sibling entry must lint clean, and a genuinely
# drifted entry (edited after the index was built, never rebuilt) must still report
# STALE -- proving the fix does not just silence the check altogether.
#
# Usage: bash tests/test-tsv-normalisation-347.sh

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$SCRIPT_DIR/scripts/rebuild-tsv.sh"
DRYRUN="$SCRIPT_DIR/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF -- "$want" <<<"$out"; then ok "$desc"; else
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  fi
}

assert_not_contains() {
  local desc="$1" out="$2" unwanted="$3"
  if grep -qF -- "$unwanted" <<<"$out"; then
    bad "$desc" "must NOT contain: $unwanted"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  else
    ok "$desc"
  fi
}

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
BASE="$TEST_DIR/.claude/jit-context"
TOOLS_DIR="$BASE/tools/00-manual"
mkdir -p "$TOOLS_DIR" "$BASE/paths/00-manual" "$BASE/vocabulary/00-manual"

# --- Fixture 1: a valid sibling. Always must lint clean; the control the whole suite
# leans on -- if THIS goes stale, the fixtures below are meaningless.
printf '%s\n' \
  "---" \
  "title: Valid" \
  "description: An ordinary rule." \
  "tool: Bash" \
  "match: git valid-347" \
  "mode: remind" \
  "---" \
  "" \
  "VALID-347-BODY" > "$TOOLS_DIR/valid-347.md"

# --- Fixture 2: mode: warn -- not remind/block/once. rebuild-tsv.sh refuses to index
# this row at all (JIT_VALID_MODE_RE); check_index_current() must recognise the same
# refusal and skip it, not compare it against an index row that will never exist.
printf '%s\n' \
  "---" \
  "title: Bad mode" \
  "description: An entry with an unrecognised mode." \
  "tool: Bash" \
  "match: git badmode-347" \
  "mode: warn" \
  "---" \
  "" \
  "BADMODE-347-BODY" > "$TOOLS_DIR/badmode-347.md"

# --- Fixture 3: a literal TAB inside require:. rebuild-tsv.sh's jit_tsv_field() folds
# it to a space when writing the row; check_index_current() must apply the same fold
# before comparing, or the raw (tab-carrying) reconstruction never matches the written
# (space-carrying) row.
printf '%s\n' \
  "---" \
  "title: Tab in require" \
  "description: An entry whose require: value carries a literal tab." \
  "tool: Bash" \
  "match: git tabreq-347" \
  "mode: block" \
  $'require: --safe\t--extra' \
  "---" \
  "" \
  "TABREQ-347-BODY" > "$TOOLS_DIR/tabreq-347.md"

# --- Fixture 4: an @invocation MACRO whose command phrase carries a literal TAB.
# rebuild-tsv.sh folds tab->space on the raw match: value BEFORE handing it to
# jit_expand_match() (both build_tool_tsv() and build_path_tsv() do fold-then-expand),
# so the macro sees "git tabmacro-347" and expands cleanly into the compiled ERE that
# gets indexed. Folding AFTER expanding instead reverses that order: jit_expand_match()
# sees the raw tab in the macro's own argument list, its character-class guard refuses
# it as "not a plain command word," and the row is written through UNEXPANDED -- a
# different, and wrong, reconstruction that can never match the real (compiled,
# expanded) index row. This is the fold/expand ORDER, not just fold presence.
printf '%s\n' \
  "---" \
  "title: Tab in a macro" \
  "description: An @invocation match: whose command phrase carries a literal tab." \
  "tool: Bash" \
  $'match: ~@invocation git\ttabmacro-347' \
  "mode: remind" \
  "---" \
  "" \
  "TABMACRO-347-BODY" > "$TOOLS_DIR/tabmacro-347.md"

# --- Fixture 5: the PATHS dimension, which has no mode: column but goes through the
# same jit_tsv_field() fold on its match: value in build_path_tsv() -- the #347 fix
# must not be tools-only.
printf '%s\n' \
  "---" \
  "title: Tab in a paths match" \
  "description: A paths rule whose match: value carries a literal tab." \
  $'match: ^src/tab\tpaths-347\.php$' \
  "---" \
  "" \
  "TABPATH-347-BODY" > "$BASE/paths/00-manual/tabpath-347.md"

CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REBUILD" >/dev/null 2>&1

# Control on rebuild-tsv.sh itself: badmode-347.md must not be indexed at all, and
# tabreq-347.md's require column must have the tab folded to a space -- otherwise the
# fixtures below are not testing what they claim to.
IDX_CONTENT=$(cat "$TOOLS_DIR/00-index.tsv" 2>/dev/null || true)
if ! grep -qF "badmode-347.md" <<<"$IDX_CONTENT"; then
  ok "control: rebuild-tsv.sh refuses the invalid-mode entry"
else
  bad "control: rebuild-tsv.sh refuses the invalid-mode entry" "found it indexed"
fi
if grep -qF -- "--safe --extra" <<<"$IDX_CONTENT" \
   && ! printf '%s' "$IDX_CONTENT" | LC_ALL=C awk '/\t--safe\t--extra\t/ { found = 1 } END { exit !found }'; then
  ok "control: rebuild-tsv.sh folds the interior tab in require: to a space"
else
  bad "control: rebuild-tsv.sh folds the interior tab in require: to a space" "$IDX_CONTENT"
fi

DRYRUN_OUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$DRYRUN" --base "$BASE" 2>&1)

assert_not_contains "no STALE for the valid sibling" "$DRYRUN_OUT" "STALE"

# The two positive tests, checked by process of elimination against the assertion
# above: if STALE appeared anywhere at all in this run, one of these three files is
# the reason, since the sibling above is clean. Narrower per-file assertions below make
# the failure easy to place.
if grep -qF "badmode-347" <<<"$(printf '%s' "$DRYRUN_OUT" | grep STALE)"; then
  bad "no false STALE for the entry rebuild-tsv.sh correctly refused to index" \
    "$(printf '%s' "$DRYRUN_OUT" | grep STALE)"
else
  ok "no false STALE for the entry rebuild-tsv.sh correctly refused to index"
fi

if grep -qF "tabreq-347" <<<"$(printf '%s' "$DRYRUN_OUT" | grep STALE)"; then
  bad "no false STALE for the entry whose require: tab rebuild-tsv.sh folded to a space" \
    "$(printf '%s' "$DRYRUN_OUT" | grep STALE)"
else
  ok "no false STALE for the entry whose require: tab rebuild-tsv.sh folded to a space"
fi

if grep -qF "tabmacro-347" <<<"$(printf '%s' "$DRYRUN_OUT" | grep STALE)"; then
  bad "no false STALE for a macro match: whose tab-carrying arguments fold before expansion" \
    "$(printf '%s' "$DRYRUN_OUT" | grep STALE)"
else
  ok "no false STALE for a macro match: whose tab-carrying arguments fold before expansion"
fi

if grep -qF "tabpath-347" <<<"$(printf '%s' "$DRYRUN_OUT" | grep STALE)"; then
  bad "no false STALE for a paths entry whose match: value carries a literal tab" \
    "$(printf '%s' "$DRYRUN_OUT" | grep STALE)"
else
  ok "no false STALE for a paths entry whose match: value carries a literal tab"
fi

# --- Positive control: a GENUINE drift must still be caught. Edit valid-347.md's
# match: after the index was built, without rebuilding -- this must NOT be swallowed
# by whatever change made the two cases above quiet.
printf '%s\n' \
  "---" \
  "title: Valid" \
  "description: An ordinary rule." \
  "tool: Bash" \
  "match: git valid-347-drifted" \
  "mode: remind" \
  "---" \
  "" \
  "VALID-347-BODY" > "$TOOLS_DIR/valid-347.md"

DRIFT_OUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$DRYRUN" --base "$BASE" 2>&1)
assert_contains "a genuinely drifted entry is still reported STALE" \
  "$(printf '%s' "$DRIFT_OUT" | grep STALE || true)" "valid-347.md"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
