#!/bin/bash
# rebuild-tsv.sh: a worktree whose session inherited a stale CLAUDE_PROJECT_DIR must not
# silently rewrite another tree's index (#231).
#
# JIT_BASE resolves against CLAUDE_PROJECT_DIR, never the working directory (common.sh,
# untouched by this branch). Inside an ordinary `git worktree`, an agent's cwd moves into
# the worktree but CLAUDE_PROJECT_DIR keeps pointing at the main clone -- and because a
# worktree and its clone share one `.git`, a rebuild run there used to write the CLONE's
# 00-index.tsv and report success. This suite drives that exact shape: two real git
# worktrees, one JIT-context tree per side, and asserts on WHICH tree's index moved --
# not merely on the exit code, which a script could get right while still writing the
# wrong file.
#
# Every "did not write the wrong tree" assertion here is paired with a positive control
# that proves this harness can see a write happen at all: JIT_CONTEXT_ALLOW_CROSS_TREE=1
# takes the identical setup and writes the SAME file the refusal protected, so a silent
# harness bug cannot pass by never detecting any write anywhere.
#
# Usage: bash tests/test-cross-tree-write-231.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; }

# Here-string, never a pipe: `| grep -q` exits on the first match and the writer takes
# SIGPIPE, which under pipefail reports the opposite of what was found (#56, carried from
# test-rebuild-exit-codes.sh).
# jit-drive: assert_contains contains capture
assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF -- "$want" <<<"$out"; then
    ok "$desc"
  else
    bad "$desc" "expected to contain: $want"
    echo "    got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
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

if ! git --version >/dev/null 2>&1; then
  echo "SKIP-NOTE: no git on PATH -- this suite tests the git-worktree case specifically"
  echo "           and cannot construct it without git. Nothing here was tested."
  exit 2
fi

ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t jit231)"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

MAIN="$ROOT/main"
mkdir -p "$MAIN"
if ! (
  cd "$MAIN" &&
  git init -q &&
  git config user.email "t@example.com" &&
  git config user.name "t" &&
  git commit -q --allow-empty -m init
) >"$ROOT/git-init.log" 2>&1; then
  echo "SKIP-NOTE: could not initialise a git repo here -- see $ROOT/git-init.log."
  echo "           Nothing here was tested."
  exit 2
fi

write_entry() {
  # $1 base dir, $2 path relative to base/.claude/jit-context, $3.. frontmatter lines
  local base="$1" path l
  path="$base/.claude/jit-context/$2"
  shift 2
  mkdir -p "$(dirname "$path")"
  {
    echo "---"
    for l in "$@"; do echo "$l"; done
    echo "---"
    echo ""
    echo "Body for $(basename "$path")."
  } > "$path"
}

write_entry "$MAIN" tools/00-manual/main-entry.md \
  "title: Main tree entry" \
  "description: Lives in the clone, not the worktree." \
  "tool: Bash" \
  "match: main-tree-literal" \
  "mode: remind"

if ! (cd "$MAIN" && git worktree add -q "$ROOT/wt" -b jit231-wt) >"$ROOT/worktree-add.log" 2>&1; then
  echo "SKIP-NOTE: 'git worktree add' failed on this platform -- see $ROOT/worktree-add.log."
  echo "           Nothing here was tested."
  exit 2
fi
WT="$ROOT/wt"
write_entry "$WT" tools/00-manual/wt-entry.md \
  "title: Worktree entry" \
  "description: Lives in the worktree, not the clone." \
  "tool: Bash" \
  "match: worktree-literal" \
  "mode: remind"

MAIN_TSV="$MAIN/.claude/jit-context/tools/00-manual/00-index.tsv"
WT_TSV="$WT/.claude/jit-context/tools/00-manual/00-index.tsv"

echo "=== A. positive control: matching cwd and CLAUDE_PROJECT_DIR writes THAT tree ==="
# Proves the harness can see the worktree's own index move before section B asks it to
# prove something never moved.
ERR="$ROOT/normal.err"
( cd "$WT" && CLAUDE_PROJECT_DIR="$WT" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "cwd == CLAUDE_PROJECT_DIR still exits 0" 0 "$RC"
if [ -f "$WT_TSV" ]; then
  ok "the worktree's own index was written"
else
  bad "the worktree's own index was written" "no file at $WT_TSV"
fi
assert_contains "and the receipt line names the tree it wrote" "$(cat "$ERR")" \
  "writing JIT_BASE=$WT/.claude/jit-context"
rm -f "$WT_TSV" "$MAIN_TSV"

echo ""
echo "=== B. cwd inside the worktree, CLAUDE_PROJECT_DIR stale at the clone: refused ==="
# This is #231 itself: an agent's session cwd moved into the worktree, but
# CLAUDE_PROJECT_DIR is whatever the harness set when the session started -- the clone.
ERR="$ROOT/stale.err"
( cd "$WT" && CLAUDE_PROJECT_DIR="$MAIN" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "a stale CLAUDE_PROJECT_DIR from inside the worktree is refused" 2 "$RC"
assert_contains "and says why" "$(cat "$ERR")" "cwd's git tree is not CLAUDE_PROJECT_DIR's"
assert_contains "and names the escape hatch" "$(cat "$ERR")" "JIT_CONTEXT_ALLOW_CROSS_TREE"
if [ -f "$MAIN_TSV" ]; then
  bad "the clone's index was NOT written" "found $MAIN_TSV"
else
  ok "the clone's index was NOT written"
fi
if [ -f "$WT_TSV" ]; then
  bad "the worktree's own index was NOT written either -- the run refused before writing anything" \
    "found $WT_TSV"
else
  ok "the worktree's own index was NOT written either -- the run refused before writing anything"
fi

echo ""
echo "=== C. the escape hatch takes the identical setup and DOES write the clone ==="
# The positive control for section B: same cwd, same stale CLAUDE_PROJECT_DIR, one env
# var different. If B's silence were actually the harness never detecting any write, this
# section would be silent too.
ERR="$ROOT/escape.err"
( cd "$WT" && JIT_CONTEXT_ALLOW_CROSS_TREE=1 CLAUDE_PROJECT_DIR="$MAIN" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "the escape hatch exits 0" 0 "$RC"
if [ -f "$MAIN_TSV" ]; then
  ok "and this time the clone's index WAS written"
else
  bad "and this time the clone's index WAS written" "no file at $MAIN_TSV"
fi
assert_contains "and the receipt line says which tree, even under the escape hatch" \
  "$(cat "$ERR")" "writing JIT_BASE=$MAIN/.claude/jit-context"
rm -f "$MAIN_TSV" "$WT_TSV"

echo ""
echo "=== D. the escape hatch is compared by VALUE, not by presence ==="
# =0 is a plausible spelling for "leave the guard ON" (the opposite of =1). A check that
# merely asked [ -z ... ] would treat any non-empty value as "disable", including this
# one, and silently defeat the guard on the spelling most likely to be tried by someone
# who means the opposite.
ERR="$ROOT/zero.err"
( cd "$WT" && JIT_CONTEXT_ALLOW_CROSS_TREE=0 CLAUDE_PROJECT_DIR="$MAIN" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "JIT_CONTEXT_ALLOW_CROSS_TREE=0 still refuses" 2 "$RC"
if [ -f "$MAIN_TSV" ]; then
  bad "and the clone's index was NOT written" "found $MAIN_TSV"
else
  ok "and the clone's index was NOT written"
fi

echo ""
echo "=== E. cwd is not inside any git tree: the guard cannot evaluate, and says so (#240) ==="
# JIT_CWD_TOP comes back empty here -- not "no git worktree", just no git tree at all under
# cwd. That is #240's own shape: the guard's [ -n ... ] && [ -n ... ] precondition is false,
# so section B's FATAL never fires, and nothing before this issue said the check itself
# never ran. A caller sees the same silence whether the check ran and agreed or could not
# run at all -- this asserts the run now tells those two apart on stderr.
NOTGIT="$ROOT/notgit"
mkdir -p "$NOTGIT"
ERR="$ROOT/notgit.err"
( cd "$NOTGIT" && CLAUDE_PROJECT_DIR="$MAIN" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "a cwd with no git tree at all still writes CLAUDE_PROJECT_DIR's tree" 0 "$RC"
if [ -f "$MAIN_TSV" ]; then
  ok "and CLAUDE_PROJECT_DIR's own index was written (the guard did not block this)"
else
  bad "and CLAUDE_PROJECT_DIR's own index was written" "no file at $MAIN_TSV"
fi
assert_contains "and stderr names the check as unable to run, not silent" "$(cat "$ERR")" \
  "cross-tree check"
assert_contains "and says which side could not resolve a git tree" "$(cat "$ERR")" \
  "cwd is not inside a git tree"
rm -f "$MAIN_TSV" "$WT_TSV"

echo ""
echo "=== F. CLAUDE_PROJECT_DIR does not resolve to a git tree: the other empty side (#240) ==="
# Section E left cwd empty and CLAUDE_PROJECT_DIR resolvable; this is the other half of the
# elif in rebuild-tsv.sh -- cwd resolvable, CLAUDE_PROJECT_DIR empty -- so the message text
# for that branch is exercised too, not just traced by reading the code.
ERR="$ROOT/notgit-proj.err"
( cd "$WT" && CLAUDE_PROJECT_DIR="$NOTGIT" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "a CLAUDE_PROJECT_DIR with no git tree at all is a FATAL, not a silent write" 2 "$RC"
assert_contains "and stderr names the check as unable to run" "$(cat "$ERR")" \
  "cross-tree check"
assert_contains "and says CLAUDE_PROJECT_DIR's side, not cwd's" "$(cat "$ERR")" \
  "CLAUDE_PROJECT_DIR does not resolve to a git tree"
if [ -f "$WT_TSV" ]; then
  bad "and the worktree's own index was NOT rewritten" "found $WT_TSV"
else
  ok "and the worktree's own index was NOT rewritten"
fi

echo ""
echo "=== G. both sides fail to resolve a git tree: the combined message (#240) ==="
# Sections E and F each left one side resolvable. This is the third and last branch of the
# elif in rebuild-tsv.sh -- neither side resolves -- so its own combined-message text is
# exercised too, per the auditor review of the first commit: reading the code says the
# branch is correct, only a passing assertion proves it stayed correct.
NOTGIT2="$ROOT/notgit2"
mkdir -p "$NOTGIT2"
ERR="$ROOT/notgit-both.err"
( cd "$NOTGIT" && CLAUDE_PROJECT_DIR="$NOTGIT2" bash "$REBUILD" >/dev/null 2>"$ERR" )
RC=$?
assert_rc "neither side resolving a git tree is a FATAL, not a silent write" 2 "$RC"
assert_contains "and stderr names the check as unable to run" "$(cat "$ERR")" \
  "cross-tree check"
assert_contains "and says both sides, not just one" "$(cat "$ERR")" \
  "cwd is not inside a git tree, and CLAUDE_PROJECT_DIR does not resolve to one either"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
