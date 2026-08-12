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
# SECTION 2b: multi-line commands (issue #6)
# =============================================

echo ""
echo "=== supertool call on the second line of a multi-line command ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cd repo\n./supertool '\''read:src/Billing/Module.class.php'\''"}}')
assert_contains "php rule fires for a supertool call after a decoded newline" "$OUT" "php coding rules"

echo ""
echo "=== multi-line command with no supertool call stays silent ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cd repo\ncat src/Billing/Module.class.php"}}')
assert_empty "no rule fires without a supertool call" "$OUT"

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

# =============================================
# SECTION: control characters in an entry body (issue #15)
# =============================================
# This hook has no CamelCase loop, so issue #14 never reached it. It shares the JSON
# output escaping, which handled backslash, quote, tab and newline and left the rest of
# U+0000-U+001F raw. CRLF is the Windows default and a user's project carries no
# .gitattributes of ours. Run once per awk on this machine anyway — the CI legs do not
# run the same engine, and the escaping is where the two dimensions meet.
ENGINE_BIN=$(mktemp -d)
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2>/dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

run_hook_engine() {
  echo "$2" | PATH="$ENGINE_BIN/$1:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2>/dev/null
}

# RFC 8259 forbids a raw U+0000-U+001F inside a JSON string; a strict parser is entitled
# to reject the whole object, which renders as the hook having said nothing.
# This one re-runs the hook and pipes it straight into perl instead of taking a captured
# string. A $( ) capture silently DROPS NUL bytes, so an assertion reading a shell variable
# cannot fail for the one byte that most needs checking -- gawk carries an embedded NUL
# through getline and would emit it raw. The first draft of this helper did exactly that
# and passed against output that contained a raw 0x00.
assert_no_raw_controls() {
  local desc="$1" eng="$2" payload="$3" out
  out=$(mktemp)
  echo "$payload" | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" > "$out" 2>/dev/null
  if ! LC_ALL=C perl -0777 -ne 'exit(/additionalContext|"reason"/ ? 0 : 1)' "$out"; then
    # A hook that injected nothing trivially carries no control byte. Without this leg the
    # assertion passes for the wrong reason -- which is the defect class this repo keeps
    # finding in its own product.
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc -- nothing was injected, so the check was vacuous"
  elif LC_ALL=C perl -0777 -ne 's/\n\z//; exit(/[\x00-\x1f]/ ? 1 : 0)' "$out"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    raw control byte in: $(LC_ALL=C perl -0777 -pe 's/([\x00-\x1f])/sprintf("<%02X>",ord($1))/ge' "$out" | head -c 200)"
  fi
  rm -f "$out"
}

# The middle line carries a CR that is NOT a line terminator. On Git Bash the awk that
# reads this file opens it in text mode, so the CR of a CRLF is consumed by the runtime
# before the awk program sees it -- there is no terminator CR left to escape, and an
# assertion on one asserts a property of the C runtime rather than of this hook. A bare
# mid-line CR survives that translation, so it is the one CR whose escaping can be asserted
# everywhere. The CRLF terminators stay: on Linux and macOS they are real.
printf 'CRLF rule line one\r\nbare\rCR mid-line\r\nCRLF rule line two\r\n' > "$PATHS_DIR/00-manual/crlf.md"
# The NUL on the second line is the engine-divergent case: gawk carries an embedded NUL
# through getline and would emit it raw, one-true-awk truncates the line at it. Neither may
# put a raw byte in the JSON, and assert_no_raw_controls holds for both readings.
printf 'control \001 and \014 and \037 here\nnul \000 tail\n' > "$PATHS_DIR/00-manual/ctrl.md"

for eng in $ENGINES; do
  # Four rules per engine, each fired exactly once. This hook marks a rule file shown on
  # every fire and the marker is keyed on a $PPID no test can name, so a rule fired twice
  # is suppressed the second time whenever the OS recycles a PID -- which it does, and
  # which is why the assertions below own their fixtures rather than sharing two.
  for kind in a raw; do
    printf 'CrlfR%s%s/\tcrlf-%s-%s.md\n' "$eng" "$kind" "$eng" "$kind" >> "$PATHS_DIR/00-manual/00-index.tsv"
    printf 'CtrlR%s%s/\tctrl-%s-%s.md\n' "$eng" "$kind" "$eng" "$kind" >> "$PATHS_DIR/00-manual/00-index.tsv"
    cp "$PATHS_DIR/00-manual/crlf.md" "$PATHS_DIR/00-manual/crlf-$eng-$kind.md"
    cp "$PATHS_DIR/00-manual/ctrl.md" "$PATHS_DIR/00-manual/ctrl-$eng-$kind.md"
  done

  echo ""
  echo "=== [$eng] CRLF and control characters in a path entry ==="
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/CrlfR${eng}a/x.txt\"}}")
  assert_contains "[$eng] CRLF entry is injected" "$OUT" "CRLF rule line one"
  assert_contains "[$eng] CR is escaped" "$OUT" 'bare\\rCR mid-line'
  assert_no_raw_controls "[$eng] CRLF entry emits no raw control byte" "$eng" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/CrlfR${eng}raw/x.txt\"}}"

  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/CtrlR${eng}a/x.txt\"}}")
  assert_contains "[$eng] control chars escaped as \u00XX" "$OUT" 'control \\u0001 and \\u000c and \\u001f here'
  assert_no_raw_controls "[$eng] control-char entry emits no raw control byte" "$eng" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/CtrlR${eng}raw/x.txt\"}}"

  # The other direction: a path no rule names still says nothing at all.
  OUT=$(run_hook_engine "$eng" '{"tool_name":"Read","tool_input":{"file_path":"/project/src/OtherDir/x.txt"}}')
  assert_empty "[$eng] unmatched path stays silent" "$OUT"
done

rm -rf "$ENGINE_BIN"

# --- Cleanup ---
rm -rf "$TEST_DIR"

# --- Summary ---
echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
