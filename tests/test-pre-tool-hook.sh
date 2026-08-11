#!/bin/bash
# Tests for pre-tool-hook.sh (TSV-based: tool rules + vocabulary matching)
# Usage: bash tests/test-pre-tool-hook.sh
#
# NOTE: "once mode" cannot be reliably tested because each subprocess gets
# a different $PPID. Once mode works in production where $PPID is stable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"
PASS=0
FAIL=0

# --- Setup: temp dir with TSV indexes + rule/vocab files ---
TEST_DIR=$(mktemp -d)
TOOLS_DIR="$TEST_DIR/.claude/jit-context/tools/00-manual"
VOCAB_DIR="$TEST_DIR/.claude/jit-context/vocabulary"
mkdir -p "$TOOLS_DIR"
mkdir -p "$VOCAB_DIR/00-manual" "$VOCAB_DIR/10-auto" "$VOCAB_DIR/20-grouped" "$VOCAB_DIR/30-crosscutting"

# Tool rules TSV: tool<TAB>match<TAB>file<TAB>modes<TAB>require<TAB>forbid
cat > "$TOOLS_DIR/00-index.tsv" <<'TSV'
Bash	git push	git-push.md	remind		
Bash	git commit	git-commit.md	remind		
Bash	bin/phpunit	phpunit.md	remind	--no-coverage	--filter
Bash	bin/phpstan	phpstan.md	once,remind		
Skill	~.*	skill-loaded.md	once,remind		
TSV

echo "git push rule context" > "$TOOLS_DIR/git-push.md"
echo "git commit rule context" > "$TOOLS_DIR/git-commit.md"
echo "phpunit rule context" > "$TOOLS_DIR/phpunit.md"
echo "phpstan rule context" > "$TOOLS_DIR/phpstan.md"
echo "skill loaded rule context" > "$TOOLS_DIR/skill-loaded.md"

# Two more rows, written with printf so the backslash reaches the TSV verbatim.
# The first is anchored on command position: the escape inside the character class is a
# REAL newline to awk, so this row can only ever fire on a multi-line command once the
# JSON newline escape is decoded before matching (issue #6).
printf 'Bash\t~(^|[;&|\\n] *)gh[[:space:]]+pr[[:space:]]+view\tgh-pr.md\tremind\t\t\n' >> "$TOOLS_DIR/00-index.tsv"
# `require` on a command that routinely carries an embedded quoted argument (issue #7).
printf 'Bash\tgh pr list\tgh-list.md\tremind\t--limit\t\n' >> "$TOOLS_DIR/00-index.tsv"
echo "gh pr view rule context" > "$TOOLS_DIR/gh-pr.md"
echo "gh pr list rule context" > "$TOOLS_DIR/gh-list.md"

# Vocabulary TSV: keyword<TAB>file
printf 'blog\tblog.md\n' > "$VOCAB_DIR/00-manual/00-index.tsv"
printf 'crypto\tcrypto.md\n' >> "$VOCAB_DIR/00-manual/00-index.tsv"
printf 'pipeline\tpipeline.md\n' >> "$VOCAB_DIR/00-manual/00-index.tsv"
echo "blog vocabulary" > "$VOCAB_DIR/00-manual/blog.md"
echo "crypto vocabulary" > "$VOCAB_DIR/00-manual/crypto.md"
echo "pipeline vocabulary" > "$VOCAB_DIR/00-manual/pipeline.md"

touch "$VOCAB_DIR/10-auto/00-index.tsv"
touch "$VOCAB_DIR/20-grouped/00-index.tsv"
touch "$VOCAB_DIR/30-crosscutting/00-index.tsv"

# --- Helpers ---
run_hook() {
  echo "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2>/dev/null
}

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if echo "$output" | grep -q "$expected"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | head -c 200)"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -q "$unexpected"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_empty() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected: {}"
    echo "    got: $(echo "$output" | head -c 200)"
  fi
}

assert_blocked() {
  local desc="$1" output="$2"
  if echo "$output" | grep -q '"decision":"block"'; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected decision:block"
    echo "    got: $(echo "$output" | head -c 200)"
  fi
}

# =============================================
# SECTION 1: Tool rule matching
# =============================================

echo "=== git push ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')
assert_contains "matches git-push rule" "$OUT" "git push rule context"
assert_contains "has additionalContext" "$OUT" "additionalContext"
assert_contains "has JIT Context header" "$OUT" "JIT Context: git-push.md"

echo ""
echo "=== git commit ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}')
assert_contains "matches git-commit rule" "$OUT" "git commit rule context"

echo ""
echo "=== git commit with push in message (no false positive) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix git push detection\""}}')
assert_contains "matches git-commit" "$OUT" "git commit rule context"
assert_not_contains "does NOT match git-push" "$OUT" "git push rule context"

echo ""
echo "=== phpunit with --no-coverage (valid) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./vendor/bin/phpunit --no-coverage tests/"}}')
assert_contains "phpunit reminds" "$OUT" "phpunit rule context"
assert_contains "has additionalContext (not blocked)" "$OUT" "additionalContext"

echo ""
echo "=== phpunit without --no-coverage (blocked: require) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./vendor/bin/phpunit tests/"}}')
assert_blocked "phpunit blocked" "$OUT"
assert_contains "mentions --no-coverage" "$OUT" "Missing required: --no-coverage"

echo ""
echo "=== phpunit with --filter (blocked: forbid) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./vendor/bin/phpunit --no-coverage --filter testSomething"}}')
assert_blocked "phpunit --filter blocked" "$OUT"
assert_contains "mentions --filter" "$OUT" "Forbidden: --filter"

echo ""
echo "=== Skill tool with regex match ==="
OUT=$(run_hook '{"tool_name":"Skill","tool_input":{"skill":"unit-test"}}')
assert_contains "Skill regex matches" "$OUT" "skill loaded rule context"

echo ""
echo "=== Non-matching command ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')
# ls -la won't match tool rules, and has no vocab keywords → could be empty
# unless "la" matches something in vocab. Let's just check no tool rule matched.
assert_not_contains "no tool rule matched" "$OUT" "git push rule context"
assert_not_contains "no phpunit rule" "$OUT" "phpunit rule context"

echo ""
echo "=== Wrong tool name ==="
OUT=$(run_hook '{"tool_name":"Read","tool_input":{"command":"git push"}}')
assert_not_contains "Read tool doesn't match Bash rules" "$OUT" "git push rule context"

echo ""
echo "=== Chained command — only matches first ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\" && git push"}}')
assert_contains "chained: matches git commit" "$OUT" "git commit rule context"
assert_not_contains "chained: stripped git push" "$OUT" "git push rule context"

# =============================================
# SECTION 2: Vocabulary matching via tool hook
# =============================================

echo ""
echo "=== Vocab: keyword as PATH token in command (binds to location) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool read:src/pipeline/config.yml"}}')
assert_contains "pipeline vocab via command path token" "$OUT" "pipeline vocabulary"

echo ""
echo "=== Vocab: keyword only in command VERB/non-path (no false fire) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"check the blog runner"}}')
assert_not_contains "blog NOT matched from non-path command word" "$OUT" "blog vocabulary"

echo ""
echo "=== Vocab: keyword only in DESCRIPTION (dropped — no false fire) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hello","description":"check crypto dashboard"}}')
assert_not_contains "crypto NOT matched from description" "$OUT" "crypto vocabulary"

echo ""
echo "=== Vocab: keyword in file_path (location channel kept) ==="
OUT=$(run_hook '{"tool_name":"Read","tool_input":{"file_path":"/project/pipeline/config.yml"}}')
assert_contains "pipeline vocab via file_path" "$OUT" "pipeline vocabulary"

echo ""
echo "=== Vocab: no keyword match ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}')
assert_empty "no vocab match" "$OUT"

# =============================================
# SECTION 3: Edge cases
# =============================================

echo ""
echo "=== Empty input ==="
OUT=$(run_hook '{}')
assert_empty "empty input" "$OUT"

echo ""
echo "=== Empty tool_name ==="
OUT=$(run_hook '{"tool_name":"","tool_input":{"command":"git push"}}')
assert_empty "empty tool_name" "$OUT"

echo ""
echo "=== Missing config dir ==="
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | CLAUDE_PROJECT_DIR="/tmp/nonexistent" bash "$HOOK" 2>/dev/null)
assert_empty "missing config" "$OUT"

# =============================================
# SECTION 4: JSON string decoding (issues #6, #7)
# =============================================

echo ""
echo "=== Anchored rule, single-line command (control) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr view 1 --json state"}}')
assert_contains "anchored rule fires at start of command" "$OUT" "gh pr view rule context"

echo ""
echo "=== Anchored rule, MULTI-LINE command (issue #6) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo x\ngh pr view 1 --json state"}}')
assert_contains "anchored rule fires after a decoded newline" "$OUT" "gh pr view rule context"

echo ""
echo "=== Anchored rule still discriminates (the other direction) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo the gh pr view docs"}}')
assert_not_contains "no fire: mid-line, no separator before gh" "$OUT" "gh pr view rule context"
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo x\necho gh pr view 1"}}')
assert_not_contains "no fire: after a newline but not the first word" "$OUT" "gh pr view rule context"

echo ""
echo "=== A backslash the user actually typed is not a newline ==="
# The command itself contains a backslash followed by n, so the JSON carries an escaped
# backslash. A decoder that simply gsubs the two-character sequence would fire here.
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"printf x\\ngh pr view"}}')
assert_not_contains "an escaped backslash is not a separator" "$OUT" "gh pr view rule context"

echo ""
echo "=== a MULTI-LINE commit message is not read as a command (issue #7) ==="
# The quoted argument spans lines. Nothing in the command words is `gh pr list`; the
# words only appear inside prose the author is writing ABOUT the command.
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix the matcher\n\nmentions gh pr list and git push in passing\""}}')
assert_contains "matches git-commit" "$OUT" "git commit rule context"
assert_not_contains "does NOT match gh pr list from the message body" "$OUT" "gh pr list rule context"
assert_not_contains "does NOT match git push from the message body" "$OUT" "git push rule context"

echo ""
echo "=== require: flag sits after an embedded quote (issue #7) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr list --search \"foo bar\" --limit 20"}}')
assert_not_contains "not blocked — --limit is present" "$OUT" '"decision":"block"'
assert_contains "reminds instead" "$OUT" "gh pr list rule context"

echo ""
echo "=== require: same flags, other order (control) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr list --limit 20 --search \"foo bar\""}}')
assert_not_contains "not blocked, either order" "$OUT" '"decision":"block"'

echo ""
echo "=== require: genuinely absent, still blocks ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr list --search \"foo bar\""}}')
assert_blocked "blocked when --limit really is missing" "$OUT"

# --- Cleanup ---
rm -rf "$TEST_DIR"

# --- Summary ---
echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
