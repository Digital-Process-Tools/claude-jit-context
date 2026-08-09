#!/bin/bash
# Tests for pre-path-hook.sh (TSV-based, supertool-aware)
# Usage: bash tests/test-pre-path-hook.sh
#
# NOTE: "once mode" (shown-file deduplication) cannot be tested here because
# each `run_hook` call creates a subprocess with a different $PPID, so the
# shown file is unique per call. Once mode works in production where $PPID
# is the stable Claude Code process PID.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/pre-path-hook.sh"
PASS=0
FAIL=0

# --- Setup: temp rules dir with TSV index + rule files ---
TEST_DIR=$(mktemp -d)
PATHS_DIR="$TEST_DIR/.claude/jit-context/paths"
mkdir -p "$PATHS_DIR/00-manual" "$PATHS_DIR/10-auto" "$PATHS_DIR/20-grouped" "$PATHS_DIR/30-crosscutting"

printf '\.php\tphp-coding.md\n' > "$PATHS_DIR/00-manual/00-index.tsv"
printf 'Components/\tpattern-component.md\n' >> "$PATHS_DIR/00-manual/00-index.tsv"
printf 'BusinessEntities/\tpattern-entity.md\n' >> "$PATHS_DIR/00-manual/00-index.tsv"
printf 'I18N/\ti18n.md\n' >> "$PATHS_DIR/00-manual/00-index.tsv"
printf 'vendor/framework/\tfwk-distribution.md\n' >> "$PATHS_DIR/00-manual/00-index.tsv"

echo "php coding rules" > "$PATHS_DIR/00-manual/php-coding.md"
echo "component pattern" > "$PATHS_DIR/00-manual/pattern-component.md"
echo "entity pattern" > "$PATHS_DIR/00-manual/pattern-entity.md"
echo "i18n rules" > "$PATHS_DIR/00-manual/i18n.md"
echo "framework distribution" > "$PATHS_DIR/00-manual/fwk-distribution.md"

touch "$PATHS_DIR/10-auto/00-index.tsv"
touch "$PATHS_DIR/20-grouped/00-index.tsv"
touch "$PATHS_DIR/30-crosscutting/00-index.tsv"

# --- Helpers ---
run_hook() {
  echo "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2>/dev/null
}

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if echo "$output" | grep -q "$expected"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | head -c 200)"
  fi
}

assert_empty() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected: {}"
    echo "    got: $(echo "$output" | head -c 200)"
  fi
}

# =============================================
# SECTION 1: Standard tool calls (file_path/path)
# =============================================

echo "=== Read: PHP file ==="
OUT=$(run_hook '{"tool_name":"Read","tool_input":{"file_path":"/project/src/Billing/Module.class.php"}}')
assert_contains "matches php-coding" "$OUT" "php coding rules"
assert_contains "has additionalContext" "$OUT" "additionalContext"
assert_contains "has JIT Context header" "$OUT" "JIT Context: php-coding.md"

echo ""
echo "=== Edit: Component PHP file (multi-rule) ==="
OUT=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/project/src/Billing/Components/ProjectForm.class.php"}}')
assert_contains "matches component" "$OUT" "component pattern"
assert_contains "matches php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Read: Entity PHP file ==="
OUT=$(run_hook '{"tool_name":"Read","tool_input":{"file_path":"/project/src/Shared/BusinessEntities/Project.class.php"}}')
assert_contains "matches entity" "$OUT" "entity pattern"
assert_contains "matches php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Read: i18n XML file ==="
OUT=$(run_hook '{"tool_name":"Read","tool_input":{"file_path":"/project/src/Billing/Resources/I18N/fr_all/permissions.xml"}}')
assert_contains "matches i18n" "$OUT" "i18n rules"

echo ""
echo "=== Glob: path field ==="
OUT=$(run_hook '{"tool_name":"Glob","tool_input":{"path":"/project/src/Billing/Components/"}}')
assert_contains "Glob matches component" "$OUT" "component pattern"

echo ""
echo "=== Grep: path field ==="
OUT=$(run_hook '{"tool_name":"Grep","tool_input":{"path":"/project/src/Shared/BusinessEntities/"}}')
assert_contains "Grep matches entity" "$OUT" "entity pattern"

echo ""
echo "=== Non-matching file ==="
OUT=$(run_hook '{"tool_name":"Read","tool_input":{"file_path":"/project/README.md"}}')
assert_empty "README.md returns empty" "$OUT"

# =============================================
# SECTION 2: Supertool via Bash
# =============================================

echo ""
echo "=== Supertool: read:PATH ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''read:src/Billing/Module.class.php'\''"}}')
assert_contains "read matches php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Supertool: read vendored framework path ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''read:vendor/framework/Foundations/Controllers/Characterizations/CharacterizationHtmlString.class.php'\''"}}')
assert_contains "matches fwk rule" "$OUT" "framework distribution"
assert_contains "matches php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Supertool: grep:PATTERN:PATH ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''grep:StripDangerous:src/Core/BusinessEntities/:10'\''"}}')
assert_contains "grep matches entity" "$OUT" "entity pattern"

echo ""
echo "=== Supertool: around:PATTERN:PATH ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''around:cast:vendor/framework/:15'\''"}}')
assert_contains "around matches fwk" "$OUT" "framework distribution"

echo ""
echo "=== Supertool: glob:PATTERN (dir prefix) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''glob:src/Billing/Components/**/*.xml'\''"}}')
assert_contains "glob matches component" "$OUT" "component pattern"

echo ""
echo "=== Supertool: map:PATH ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''map:src/Billing/Components/ProjectForm.class.php'\''"}}')
assert_contains "map matches component" "$OUT" "component pattern"
assert_contains "map matches php" "$OUT" "php coding rules"

echo ""
echo "=== Supertool: check:PRESET:PATH ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''check:phpstan:src/Billing/Module.class.php'\''"}}')
assert_contains "check matches php" "$OUT" "php coding rules"

echo ""
echo "=== Supertool: multi-op batch ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''read:vendor/framework/test.php'\'' '\''grep:pattern:src/Billing/Components/:10'\'' '\''glob:src/Shared/BusinessEntities/**/*.php'\''"}}')
assert_contains "batch: fwk" "$OUT" "framework distribution"
assert_contains "batch: component" "$OUT" "component pattern"
assert_contains "batch: entity" "$OUT" "entity pattern"
assert_contains "batch: php-coding" "$OUT" "php coding rules"

# =============================================
# SECTION 3: Bash non-supertool (should NOT match)
# =============================================

echo ""
echo "=== Non-supertool Bash: git status ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git status"}}')
assert_empty "git status returns empty" "$OUT"

echo ""
echo "=== Non-supertool Bash: ls command ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la src/Billing/"}}')
assert_empty "ls returns empty" "$OUT"

echo ""
echo "=== Non-supertool Bash: cat a PHP file ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat src/Billing/Module.class.php"}}')
assert_empty "cat returns empty (not supertool)" "$OUT"

# =============================================
# SECTION 4: Edge cases
# =============================================

echo ""
echo "=== Empty input ==="
OUT=$(run_hook '{}')
assert_empty "empty input" "$OUT"

echo ""
echo "=== No file_path or command ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"description":"test"}}')
assert_empty "no path or command" "$OUT"

echo ""
echo "=== Supertool with no ops ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool"}}')
assert_empty "supertool no args" "$OUT"

echo ""
echo "=== Supertool: meta ops (no path) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''ops'\'' '\''introduction'\''"}}')
assert_empty "meta ops return empty" "$OUT"

echo ""
echo "=== Supertool: read with offset/limit (path still extracted) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''read:src/Billing/Components/Form.class.php:10:50'\''"}}')
assert_contains "read with offset matches component" "$OUT" "component pattern"

# --- Cleanup ---
rm -rf "$TEST_DIR"

# --- Summary ---
echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
