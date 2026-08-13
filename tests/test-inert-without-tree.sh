#!/bin/bash
# #51: a project that has never heard of this plugin gets a .discovery/ directory anyway,
# and common.sh carried a comment asserting the opposite.
#
#   # Gated on JIT_BASE existing too: a session with no jit-context tree at all should
#   # not have one materialised under its cwd.
#
# The gate was real and it did not hold, because it guarded the STATE mkdir only and the
# LOG's own ungated `mkdir -p "$LOG_DIR"` runs first in the same file -- creating
# $JIT_BASE, and with it the parent the state gate was testing for. One prompt in an
# empty directory produced, reproduced 2026-08-12 on this branch:
#
#   ./.claude/jit-context/.discovery/logs/hooks.log
#   ./.claude/jit-context/.discovery/state
#
# The cost is a user-visible one: only THIS repository .gitignore covers that path, so in
# anyone else project `git status` shows untracked files after installing a global plugin
# and making no local change.
#
# THE GUARD THIS SUITE NEEDS: every assertion here is "this directory does not exist",
# and all of them pass on a hook that never ran, a fixture built in the wrong place and a
# payload with a typo. So section A is a positive control on the same code path -- with a
# tree present the same hook MUST create the same directories and write a log line -- and
# each negative section asserts the hook produced its JSON, so silence is never read as
# compliance.
#
# Usage: bash tests/test-inert-without-tree.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/jit-inert-XXXXXX")" || {
  echo "test-inert-without-tree: SKIPPED -- could not create a temp directory"
  exit 2
}
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# jit-drive: assert_contains contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_exists() {
  local desc="$1" p="$2"
  if [ -e "$p" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to exist: $p"
  fi
}

assert_absent() {
  local desc="$1" p="$2"
  if [ -e "$p" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should not exist: $p"
    find "$p" 2>/dev/null | sed 's/^/      /'
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

# Every hook, with a payload each one recognises. A change that leaves one of the four
# still creating the tree is the same bug with a smaller blast radius, so all four run.
run_all_hooks() {
  local proj="$1"
  printf '{"prompt":"hello there","session_id":"sessI"}' \
    | CLAUDE_PROJECT_DIR="$proj" bash "$SCRIPTS/pre-prompt-hook.sh" 2>/dev/null
  printf '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
    | CLAUDE_PROJECT_DIR="$proj" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null
  printf '{"tool_name":"Read","tool_input":{"file_path":"/x/y/a.php"}}' \
    | CLAUDE_PROJECT_DIR="$proj" bash "$SCRIPTS/pre-path-hook.sh" 2>/dev/null
  printf '{"session_id":"sessI"}' \
    | CLAUDE_PROJECT_DIR="$proj" bash "$SCRIPTS/session-start-hook.sh" 2>/dev/null
}

echo "=== A: the positive control -- with a tree, the same hooks DO write ==="

# Without this section, "nothing was created" below is satisfied by a harness that never
# ran a hook at all.
PROJ="$(mktemp -d "$TMPROOT/withtree-XXXXXX")"
BASE="$PROJ/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual"
printf 'entry body A\n' > "$BASE/tools/00-manual/a.md"
printf 'Bash\tatarget\ta.md\t\t\t\n' > "$BASE/tools/00-manual/00-index.tsv"
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"atarget now"}}' \
  | CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null); RC=$?
assert_rc0 "A the hook exits 0" "$RC"
assert_contains "A the rule fires, so the fixture is live" "$OUT" "entry body A"
assert_exists "A the log is written where a tree exists" "$BASE/.discovery/logs/hooks.log"
assert_exists "A and the state directory is created there too" "$BASE/.discovery/state"

echo ""
echo "=== B: a project with no .claude at all gets nothing ==="

PROJ="$(mktemp -d "$TMPROOT/bare-XXXXXX")"
OUT="$(run_all_hooks "$PROJ")"
# The hooks ran and answered. Four `{}` bodies, one per hook: this is what stops the
# absence below from being an absence of hooks.
assert_contains "B the hooks answered" "$OUT" "{}"
if [ "$(grep -c '{}' <<<"$OUT")" -ge 4 ]; then
  PASS=$((PASS + 1)); echo "  PASS: B all four hooks answered"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: B fewer than four hooks answered -- the absence below proves nothing"
  echo "    got: $OUT"
fi
assert_absent "B no .claude directory is materialised" "$PROJ/.claude"

echo ""
echo "=== C: a project with .claude but no jit-context tree gets nothing either ==="

# The likelier real case: a project that uses Claude Code, has settings and commands, and
# has never opted into this plugin.
PROJ="$(mktemp -d "$TMPROOT/claudeonly-XXXXXX")"
mkdir -p "$PROJ/.claude/commands"
OUT="$(run_all_hooks "$PROJ")"
assert_contains "C the hooks answered" "$OUT" "{}"
assert_absent "C no jit-context tree is materialised" "$PROJ/.claude/jit-context"

echo ""
echo "=== D: git status stays clean, which is the symptom users actually see ==="

if ! command -v git >/dev/null 2>&1; then
  echo "  SKIPPED: git is not on PATH here, so the user-visible symptom went undriven"
else
  PROJ="$(mktemp -d "$TMPROOT/git-XXXXXX")"
  ( cd "$PROJ" && git init -q . && git config user.email t@example.com && git config user.name t ) >/dev/null 2>&1
  printf 'hello\n' > "$PROJ/README.md"
  ( cd "$PROJ" && git add -A && git commit -qm init ) >/dev/null 2>&1
  BEFORE="$( cd "$PROJ" && git status --porcelain )"
  if [ -n "$BEFORE" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: D the fixture repository was not clean to begin with"
    echo "    got: $BEFORE"
  else
    PASS=$((PASS + 1)); echo "  PASS: D the fixture repository starts clean"
    run_all_hooks "$PROJ" >/dev/null
    AFTER="$( cd "$PROJ" && git status --porcelain )"
    if [ -z "$AFTER" ]; then
      PASS=$((PASS + 1)); echo "  PASS: D and it is still clean after every hook has run"
    else
      FAIL=$((FAIL + 1)); echo "  FAIL: D the hooks dirtied a repository that never opted in"
      echo "    got: $AFTER"
    fi
  fi
fi

echo ""
echo "=== E: the log going quiet never costs an injection (#50) ==="

# The half of this change that could go wrong. A tree that exists but cannot be written to
# must still inject: the log is a convenience for the author, the injection is the product.
PROJ="$(mktemp -d "$TMPROOT/ro-XXXXXX")"
BASE="$PROJ/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual"
printf 'entry body E\n' > "$BASE/tools/00-manual/e.md"
printf 'Bash\tetarget\te.md\t\t\t\n' > "$BASE/tools/00-manual/00-index.tsv"
chmod a-w "$BASE" 2>/dev/null
if ( : > "$BASE/.jit-write-probe" ) 2>/dev/null; then
  rm -f "$BASE/.jit-write-probe"
  chmod u+w "$BASE" 2>/dev/null
  echo "  SKIPPED: this filesystem or user ignores the write bit, so the unwritable-tree"
  echo "           case went undriven -- it is neither a pass nor a failure here"
else
  OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"etarget now"}}' \
    | CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null); RC=$?
  assert_rc0 "E the hook exits 0 on an unwritable tree" "$RC"
  assert_contains "E and the entry still reaches the model" "$OUT" "entry body E"
  chmod u+w "$BASE" 2>/dev/null
  assert_absent "E and nothing was forced into place" "$BASE/.discovery"
fi

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
