#!/bin/bash
# vocabulary/01-oss/01-paths.tsv must be tracked, so rebuild-tsv.sh regenerating it does
# not dirty an otherwise-clean clone (#277).
#
# 0dfe259 (#234) untracked this repo's copy of vocabulary/01-oss/01-paths.tsv while saying
# the current oss release "no longer ships" it -- but that sentence is about the SCAFFOLD's
# own template for the layer's *content* files (oss-state.md, plugin-currency.md), not
# about rebuild-tsv.sh's own generated index. rebuild-tsv.sh treats every vocabulary layer
# identically (`for dir in "$VOCAB_BASE"/*/`, scripts/rebuild-tsv.sh) and always writes a
# 01-paths.tsv beside each layer's 00-index.tsv -- confirmed still true for 01-oss by
# test-layer-enumeration.sh's own section E, which builds a 01-oss vocab entry carrying a
# "## Modules" section and asserts BOTH that rebuild-tsv.sh writes a non-empty
# vocabulary/01-oss/01-paths.tsv AND that the path hook fires from it. That is a real,
# tested capability -- disabling generation for 01-oss (the fix this suite's first draft
# took) silently breaks it. The bug was only ever that the file was untracked while its
# sibling vocabulary/00-manual/01-paths.tsv -- also empty today, since jit-context.md
# carries no "## Modules" section -- IS tracked; the fix tracks it too, not teach the
# generator to skip the layer.
#
# jit-drive: none -- ok()/bad() below are local, one-line pass/fail counters over plain
# `[ -e ... ]` / `[ -s ... ]` / `git status --porcelain` checks, the same shape
# test-commands.sh already declares `none` for; nothing here is a captured-output
# assertion of the shared contains/lacks/marker shape test-assertion-helpers.sh drives.
#
# Usage: bash tests/test-vocab-oss-paths-277.sh

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

echo "=== A: this repo's own tree -- the regression itself ==="
# The actual repro from the issue: a clean checkout, `rebuild-tsv.sh`, `git status
# --porcelain` must still be empty. Run against THIS repo (not a synthetic fixture)
# because the bug is specifically about whether the real vocabulary/01-oss/01-paths.tsv is
# tracked -- a fixture tree would only prove the mechanism, not this repo's own state.
if git -C "$REPO" diff --quiet -- . && [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  ok "A the checkout is clean before this suite touches anything"
else
  bad "A the checkout is clean before this suite touches anything" \
    "this suite must run against a clean tree -- commit or stash first"
fi

# A plain temp file, never "$REPO/.git/..." -- inside a `git worktree`, `.git` is a FILE
# (a gitdir pointer), not a directory, so a path under it fails with ENOTDIR rather than
# writing anything (#277 was itself found and fixed from inside a worktree).
# CLAUDE_PROJECT_DIR explicitly set to $REPO: run-all.sh cd's into tests/ before running
# each suite, and this session's own CLAUDE_PROJECT_DIR (inherited from the harness that
# started it) points at a DIFFERENT checkout entirely -- rebuild-tsv.sh's own #231
# cross-tree guard then refuses (exit 2) rather than silently writing the wrong tree,
# which is the guard working as intended, not a bug in this test. Pin it here the same
# way test-jit-init.sh and test-cross-tree-write-231.sh already do for their own targets.
ERR_A="$(mktemp 2> /dev/null || mktemp -t jit277a)"
CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/scripts/rebuild-tsv.sh" > /dev/null 2> "$ERR_A"
RC=$?
if [ "$RC" = 0 ]; then
  ok "A rebuild-tsv.sh exits 0"
else
  bad "A rebuild-tsv.sh exits 0" "exit $RC -- see $ERR_A"
fi
rm -f "$ERR_A"

DIRTY="$(git -C "$REPO" status --porcelain -- .claude/jit-context/vocabulary/01-oss/01-paths.tsv)"
if [ -z "$DIRTY" ]; then
  ok "A vocabulary/01-oss/01-paths.tsv is untouched by git status after a rebuild (tracked and unchanged)"
else
  bad "A vocabulary/01-oss/01-paths.tsv is untouched by git status after a rebuild" "$DIRTY"
fi

if git -C "$REPO" ls-files --error-unmatch .claude/jit-context/vocabulary/01-oss/01-paths.tsv > /dev/null 2>&1; then
  ok "A vocabulary/01-oss/01-paths.tsv is tracked"
else
  bad "A vocabulary/01-oss/01-paths.tsv is tracked" "git ls-files does not know this path"
fi

echo ""
echo "=== B: a synthetic fixture -- 01-oss keeps generating real path mappings ==="
# The positive control test-layer-enumeration.sh section E already drives in full; this
# is the narrow slice of it that matters here: a 01-oss vocab entry with a "## Modules"
# section still produces rows in 01-paths.tsv. If a future change reintroduces the
# "skip 01-oss" fix this suite's first draft took, this is what catches it.
if ! git --version > /dev/null 2>&1; then
  echo "SKIP-NOTE: no git on PATH -- section B needs a real git tree for rebuild-tsv.sh's"
  echo "           cross-tree guard to pass. A and its verdict above still stand."
else
  ROOT="$(mktemp -d 2> /dev/null || mktemp -d -t jit277b)"
  trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

  TREE="$ROOT/repo"
  mkdir -p "$TREE/.claude/jit-context/vocabulary/01-oss"
  if (
    cd "$TREE" \
      && git init -q \
      && git config user.email "t@example.com" \
      && git config user.name "t" \
      && git commit -q --allow-empty -m init
  ) > "$ROOT/git-init.log" 2>&1; then
    {
      echo "---"
      echo "title: OSS module"
      echo "description: Carries a Modules section."
      echo "keywords: oss module"
      echo "---"
      echo ""
      echo "## Modules"
      echo ""
      echo "Bmodule"
    } > "$TREE/.claude/jit-context/vocabulary/01-oss/b-entry.md"

    (cd "$TREE" && CLAUDE_PROJECT_DIR="$TREE" bash "$REPO/scripts/rebuild-tsv.sh") > /dev/null 2> "$ROOT/rebuild.err"
    RC=$?
    PATHS_TSV="$TREE/.claude/jit-context/vocabulary/01-oss/01-paths.tsv"
    if [ "$RC" = 0 ] && [ -s "$PATHS_TSV" ] && grep -qF "Bmodule/" "$PATHS_TSV"; then
      ok "B a 01-oss \"## Modules\" section still produces a path mapping"
    else
      bad "B a 01-oss \"## Modules\" section still produces a path mapping" \
        "exit=$RC, contents: $(cat "$PATHS_TSV" 2> /dev/null || echo '<missing>')"
    fi
  else
    echo "SKIP-NOTE: could not initialise a git repo here -- see $ROOT/git-init.log."
    echo "           Section B was not tested."
  fi
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
