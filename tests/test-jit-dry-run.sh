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
echo "=== a sample command carrying a quote reaches the hook intact ==="
# The sample is hand-built JSON. An unescaped quote used to end the value early, so the
# rule was tested against `echo ` and reported as not firing.
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command 'echo "hi" ; git push origin main' 2>&1) && ST=0 || ST=$?
# Anchored on the verdict, not on the name: phase 1 lists git-push.md as a linted pattern
# on every run, so a bare name check passes whether or not the rule ever fired.
assert_contains "rule fires after a quoted argument" "$OUT" "BLOCK  pre-tool-hook.sh"

echo ""
echo "=== ...and still declines when the quote is all there is ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command 'echo "git push" | cat' 2>&1) && ST=0 || ST=$?
assert_contains "no rule fired on quoted prose" "$OUT" "no rule fired"

echo ""
echo "=== a multi-line sample command fires the anchored rule ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command "$(printf 'echo x\ngit push origin main')" 2>&1) && ST=0 || ST=$?
assert_contains "anchored rule fires for a pasted multi-line command" "$OUT" "BLOCK  pre-tool-hook.sh"

echo ""
echo "=== a backslash in the sample stays a backslash ==="
# Two characters, not a newline. The sample is what the caller typed, so the rule must
# decline here for the same reason it fires above — and a backslash that reached the
# payload unescaped would have made this a newline and blocked.
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command 'echo x\ngit push origin main' 2>&1) && ST=0 || ST=$?
assert_contains "no rule fires on a literal backslash-n" "$OUT" "no rule fired"

echo ""
echo "=== a sample ending in a backslash still builds valid JSON ==="
# Smoke test, not the decisive one — the assertion above is what proves the escaping.
# Unescaped, this trailing backslash escapes the closing quote of the hand-built payload
# and the value swallows the rest of the object.
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --file 'C:\repo\src\Billing\' 2>&1) && ST=0 || ST=$?
assert_status "exit 0 on a backslash-laden sample" "$ST" "0"
assert_contains "both hooks still answered" "$OUT" "pre-path-hook.sh"

echo ""
echo "=== a path sample fires a path rule ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --file "src/Billing/Total.php" 2>&1) && ST=0 || ST=$?
assert_contains "path rule fired" "$OUT" "billing.md"

echo ""
echo "=== the injected refusal notice is not reported as a rule that fired ==="
# The notice header is "# JIT Context: N rule(s) could not be evaluated". Reading rule
# names out of the injected text naively picks up N and prints it as a fired rule --
# a non-match reading as a match, which is the defect this whole script exists for.
OUT=$(cd "$BROKEN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --tool Bash --command 'ls -la' 2>&1) && ST=0 || ST=$?
assert_contains "says no rule fired" "$OUT" "no rule fired"

echo ""
echo "=== a tree with no rules at all is 'skipped', never 'ok' ==="
OUT=$(cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$CLEAN" bash "$DRYRUN" 2>&1) && ST=0 || ST=$?
assert_status "exit 2 — could not evaluate" "$ST" "2"
assert_contains "says skipped" "$OUT" "SKIPPED"

echo ""
echo "=== every regex row gets an engine verdict as well as a structural one ==="
OUT=$(cd "$CLEAN" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" 2>&1) && ST=0 || ST=$?
assert_contains "reports the live awk that evaluated it" "$OUT" "engine:"

echo ""
echo "=== config.env is linted for the tree named by --base, not the session ==="
# JIT_BASE resolves from $CLAUDE_PROJECT_DIR in common.sh, so sourcing it parsed the
# SESSION config and never the tree being linted. A tree carrying `touch /tmp/nope` and
# `PATH=/evil` reported "0 refused" and said nothing at all -- an absence produced by the
# tool, read as an absence in the world, in the tool written to report exactly that.
#
# The notices that send a reader here tell them to treat config.env as hostile because it
# arrived with the repository, so silence on it is the worst of the three answers.
#
# Three outcomes, never two: refused lines, honoured lines, or no file. Each is driven.

CONFTREE=$(mktemp -d)
make_tree "$CONFTREE"
CANARY_FILE="$CONFTREE/EXECUTED-CANARY"
printf 'touch %s\nPATH=/evil\nJIT_CONTEXT_VOCAB_PATHS=1\n' "$CANARY_FILE" \
  > "$CONFTREE/.claude/jit-context/config.env"
OUT=$(cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --base "$CONFTREE/.claude/jit-context" 2>&1) && ST=0 || ST=$?
assert_contains "the hostile config.env is reported at all" "$OUT" "config.env"
assert_contains "the shell line is named by position" "$OUT" "line 1"
assert_contains "and by reason" "$OUT" "not a KEY=VALUE assignment"
assert_contains "the PATH line is named too" "$OUT" "line 2"
assert_contains "and says why it is not settable" "$OUT" "unknown setting"
assert_status "exit 1 when a tree carries a config.env line that cannot be honoured" "$ST" "1"
# common.sh reports the line NUMBER and never the line TEXT, because the premise is that
# this file may be hostile. The linter prints to a terminal a person is reading.
assert_not_contains "the refused line text is never echoed" "$OUT" "PATH=/evil"
assert_not_contains "nor the shell it would have been" "$OUT" "touch "
# The linter must READ that file, never run it, and never adopt its settings.
if [ -e "$CANARY_FILE" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the linter EXECUTED the tree's config.env"
else
  PASS=$((PASS + 1)); echo "  PASS: the linter did not execute the tree's config.env"
fi

# Positive control on the same shape: a config.env whose every line IS honourable must be
# reported as read and must not push the exit code. Without this, "names the refused
# lines" is satisfied by a linter that refuses every config.env it ever sees.
printf 'JIT_CONTEXT_VOCAB_PATHS=1\n# a comment\n\n' > "$CONFTREE/.claude/jit-context/config.env"
OUT=$(cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --base "$CONFTREE/.claude/jit-context" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 when every config.env line is honourable" "$ST" "0"
assert_contains "an honourable config.env is still reported as read" "$OUT" "config.env"
assert_not_contains "nothing is refused" "$OUT" "line 1:"

# Third outcome: no config.env at all. Distinct from "read and clean", because the reader
# needs to tell "there is nothing to check" from "I checked and found nothing".
rm -f "$CONFTREE/.claude/jit-context/config.env"
OUT=$(cd "$ELSEWHERE" && CLAUDE_PROJECT_DIR="$ELSEWHERE" bash "$DRYRUN" --base "$CONFTREE/.claude/jit-context" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 when the tree has no config.env" "$ST" "0"
assert_contains "and says so rather than staying silent" "$OUT" "no config.env"

rm -rf "$CONFTREE"

rm -rf "$CLEAN" "$BROKEN" "$ELSEWHERE"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
