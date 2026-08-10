#!/bin/bash
# Tests for scripts/jit-dry-run.sh — evaluate a tree's rules where they are written.
#
# The point of the script: JIT_BASE resolves against $CLAUDE_PROJECT_DIR, so a tree that
# is not the session's project dir (a git worktree, a checkout under review) cannot load
# or test its own rules, and nothing says so. The dry-run reads the tree you point it at.
#
# Usage: bash tests/test-jit-dry-run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRYRUN="$SCRIPT_DIR/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF "$expected"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF "$unexpected"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_status() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $actual, expected $expected)"
  fi
}

# --- A clean tree and a broken tree, each a full project dir ---
CLEAN=$(mktemp -d)
BROKEN=$(mktemp -d)
ELSEWHERE=$(mktemp -d)

make_tree() {
  local root="$1" base
  base="$root/.claude/jit-context"
  mkdir -p "$base/tools/00-manual"
  for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
    mkdir -p "$base/paths/$l" "$base/vocabulary/$l"
    : > "$base/paths/$l/00-index.tsv"
    : > "$base/vocabulary/$l/00-index.tsv"
  done
  printf 'Bash\t~(^|[;&|\\n] *)git[[:space:]]+push\tgit-push.md\tblock\t\t\n' > "$base/tools/00-manual/00-index.tsv"
  echo "do not push" > "$base/tools/00-manual/git-push.md"
  printf 'Billing/\tbilling.md\n' > "$base/paths/00-manual/00-index.tsv"
  echo "billing body" > "$base/paths/00-manual/billing.md"
}

make_tree "$CLEAN"
make_tree "$BROKEN"
printf 'Bash\t~gh\\s+pr\tdead.md\tblock\t\t\n' >> "$BROKEN/.claude/jit-context/tools/00-manual/00-index.tsv"
echo "dead body" > "$BROKEN/.claude/jit-context/tools/00-manual/dead.md"
printf 'src/[a\tfatal.md\n' >> "$BROKEN/.claude/jit-context/paths/00-manual/00-index.tsv"
echo "fatal body" > "$BROKEN/.claude/jit-context/paths/00-manual/fatal.md"

# ELSEWHERE is a valid project dir with NO rules at all. It is what CLAUDE_PROJECT_DIR is
# set to throughout, so any result that depends on it is a result about the wrong tree.
mkdir -p "$ELSEWHERE/.claude/jit-context/tools/00-manual"

echo "=== a clean tree passes ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 on a clean tree" "$ST" "0"
assert_contains "reports the rule it checked" "$OUT" "git-push.md"
assert_not_contains "no refusals" "$OUT" "REFUSED"

echo ""
echo "=== a broken tree is refused, and names the construct ==="
OUT=$(cd "$BROKEN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" 2>&1) && ST=0 || ST=$?
assert_status "exit 1 when a pattern cannot be honoured" "$ST" "1"
assert_contains "names the dead-escape rule" "$OUT" "dead.md"
assert_contains "names the escape" "$OUT" "\\s"
assert_contains "suggests the POSIX class" "$OUT" "[[:space:]]"
assert_contains "names the malformed path rule" "$OUT" "fatal.md"
assert_contains "says REFUSED" "$OUT" "REFUSED"

echo ""
echo "=== --base reads the tree it is given, not CLAUDE_PROJECT_DIR ==="
OUT=$(cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --base "$BROKEN/.claude/jit-context" 2>&1) && ST=0 || ST=$?
assert_status "exit 1 for the tree named by --base" "$ST" "1"
assert_contains "linted the --base tree" "$OUT" "dead.md"

echo ""
echo "=== a sample tool call reports which rule fired, in the given tree ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command 'cd /x && git push origin main' 2>&1) && ST=0 || ST=$?
assert_status "exit 0" "$ST" "0"
assert_contains "reports the rule fired" "$OUT" "git-push.md"
assert_contains "reports that it blocks" "$OUT" "BLOCK"

echo ""
echo "=== a sample call that matches nothing says so, and does not read as a pass ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command 'ls -la' 2>&1) && ST=0 || ST=$?
assert_contains "says no rule fired" "$OUT" "no rule fired"

echo ""
echo "=== a path sample fires a path rule ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --file "src/Billing/Total.php" 2>&1) && ST=0 || ST=$?
assert_contains "path rule fired" "$OUT" "billing.md"

echo ""
echo "=== a tree with no rules at all is 'skipped', never 'ok' ==="
OUT=$(cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$CLEAN" bash "$DRYRUN" 2>&1) && ST=0 || ST=$?
assert_status "exit 2 — could not evaluate" "$ST" "2"
assert_contains "says skipped" "$OUT" "SKIPPED"

echo ""
echo "=== every regex row gets an engine verdict as well as a structural one ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" 2>&1) && ST=0 || ST=$?
assert_contains "reports the live awk that evaluated it" "$OUT" "engine:"

rm -rf "$CLEAN" "$BROKEN" "$ELSEWHERE"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
