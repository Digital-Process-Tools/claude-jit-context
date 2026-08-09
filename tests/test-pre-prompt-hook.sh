#!/bin/bash
# Tests for pre-prompt-hook.sh (TSV-based vocabulary matching on user prompts)
# Usage: bash tests/test-pre-prompt-hook.sh
#
# NOTE: "once mode" cannot be reliably tested because each subprocess gets
# a different $PPID. Once mode works in production where $PPID is stable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/pre-prompt-hook.sh"
SESSION_HOOK="$SCRIPT_DIR/scripts/session-start-hook.sh"
PASS=0
FAIL=0

# --- Setup: temp dir with TSV indexes + vocab files ---
TEST_DIR=$(mktemp -d)
VOCAB_DIR="$TEST_DIR/.claude/jit-context/vocabulary"
mkdir -p "$VOCAB_DIR/00-manual" "$VOCAB_DIR/10-auto" "$VOCAB_DIR/20-grouped" "$VOCAB_DIR/30-crosscutting"

# Vocabulary TSV: keyword<TAB>file
cat > "$VOCAB_DIR/00-manual/00-index.tsv" <<'TSV'
billing	billing.md
payments	payments.md
stripe	payments.md
pipeline	pipeline.md
docs example com	site.md
security	security.md
TSV

echo "billing context" > "$VOCAB_DIR/00-manual/billing.md"
echo "payments context" > "$VOCAB_DIR/00-manual/payments.md"
echo "pipeline context" > "$VOCAB_DIR/00-manual/pipeline.md"
echo "site with url context" > "$VOCAB_DIR/00-manual/site.md"
echo "security context" > "$VOCAB_DIR/00-manual/security.md"

# Second layer with different content
printf 'deployment\tdeployment.md\n' > "$VOCAB_DIR/10-auto/00-index.tsv"
echo "deployment context" > "$VOCAB_DIR/10-auto/deployment.md"

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

# =============================================
# SECTION 1: Basic keyword matching
# =============================================

echo "=== Simple keyword match ==="
OUT=$(run_hook '{"prompt":"I want to work on the billing"}')
assert_contains "billing matches" "$OUT" "billing context"
assert_contains "has Vocabulary header" "$OUT" "Vocabulary: billing.md"
assert_contains "shows matched keyword" "$OUT" "matched: billing"

echo ""
echo "=== Case-insensitive match ==="
OUT=$(run_hook '{"prompt":"The BILLING needs updating"}')
assert_contains "BILLING matches (case-insensitive)" "$OUT" "billing context"

echo ""
echo "=== No match on unrelated text ==="
OUT=$(run_hook '{"prompt":"fix the button color"}')
assert_empty "no match" "$OUT"

# =============================================
# SECTION 2: Multiple keywords → same file
# =============================================

echo ""
echo "=== First keyword for file ==="
OUT=$(run_hook '{"prompt":"check the payments dashboard"}')
assert_contains "payments keyword matches" "$OUT" "payments context"

echo ""
echo "=== Alternative keyword for same file ==="
OUT=$(run_hook '{"prompt":"open stripe and check the balance"}')
assert_contains "stripe matches payments.md" "$OUT" "payments context"

# =============================================
# SECTION 3: Multiple matches in one prompt
# =============================================

echo ""
echo "=== Multiple keywords in one prompt ==="
OUT=$(run_hook '{"prompt":"check the billing and payments dashboard"}')
assert_contains "billing matched" "$OUT" "billing context"
assert_contains "payments matched" "$OUT" "payments context"

echo ""
echo "=== Three matches in one prompt ==="
OUT=$(run_hook '{"prompt":"billing post about the payments pipeline"}')
assert_contains "billing" "$OUT" "billing context"
assert_contains "payments" "$OUT" "payments context"
assert_contains "pipeline" "$OUT" "pipeline context"

# =============================================
# SECTION 4: URL matching
# =============================================

echo ""
# A dotted keyword must be stored pre-normalized ("docs example com"), because the
# matcher strips dots from the prompt before comparing. rebuild-tsv.sh does this at
# build time; a hand-written dotted keyword in the TSV would be permanently dead.
echo "=== Domain keyword inside URL ==="
OUT=$(run_hook '{"prompt":"https://docs.example.com/page.html can go online"}')
assert_contains "URL keyword matches" "$OUT" "site with url context"

# =============================================
# SECTION 5: Multi-layer matching
# =============================================

echo ""
echo "=== Keyword in second layer ==="
OUT=$(run_hook '{"prompt":"start the deployment process"}')
assert_contains "10-auto layer matches" "$OUT" "deployment context"

echo ""
echo "=== Keywords across layers in one prompt ==="
OUT=$(run_hook '{"prompt":"billing deployment is ready"}')
assert_contains "00-manual layer" "$OUT" "billing context"
assert_contains "10-auto layer" "$OUT" "deployment context"

# =============================================
# SECTION 6: Edge cases
# =============================================

echo ""
echo "=== Empty prompt ==="
OUT=$(run_hook '{"prompt":""}')
assert_empty "empty prompt" "$OUT"

echo ""
echo "=== Missing prompt field ==="
OUT=$(run_hook '{"something":"else"}')
assert_empty "missing prompt" "$OUT"

echo ""
echo "=== Empty JSON ==="
OUT=$(run_hook '{}')
assert_empty "empty JSON" "$OUT"

echo ""
echo "=== Prompt with only spaces ==="
OUT=$(run_hook '{"prompt":"   "}')
assert_empty "whitespace prompt" "$OUT"

echo ""
echo "=== Very long prompt (no match) ==="
LONG=$(printf 'x%.0s' {1..500})
OUT=$(run_hook "{\"prompt\":\"$LONG\"}")
assert_empty "long prompt no match" "$OUT"

echo ""
echo "=== Missing config dir ==="
OUT=$(echo '{"prompt":"billing"}' | CLAUDE_PROJECT_DIR="/tmp/nonexistent" bash "$HOOK" 2>/dev/null)
assert_empty "missing config dir" "$OUT"

echo ""
# Matching is space-bounded: "microbilling" must NOT fire the "billing" entry.
# Substring matching was the old behaviour and made short keywords fire everywhere.
echo "=== Keyword as substring (must NOT match) ==="
OUT=$(run_hook '{"prompt":"microbilling report"}')
assert_not_contains "substring does not match" "$OUT" "billing context"

echo ""
echo "=== Security keyword ==="
OUT=$(run_hook '{"prompt":"we need to talk about security"}')
assert_contains "security matches" "$OUT" "security context"

# =============================================
# SECTION 7: Session-start cleanup
# =============================================

echo ""
echo "=== SessionStart hook clears shown files ==="
# Create fake shown files mimicking all three naming patterns
touch /tmp/claude-vocab-shown-$$.txt
touch /tmp/claude-path-shown-$$.txt

if [ -f "$SESSION_HOOK" ]; then
  bash "$SESSION_HOOK" >/dev/null 2>&1
  if [ ! -f /tmp/claude-vocab-shown-$$.txt ]; then
    PASS=$((PASS + 1)); echo "  PASS: clears vocab shown files"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: vocab shown file not cleared"
  fi
  if [ ! -f /tmp/claude-path-shown-$$.txt ]; then
    PASS=$((PASS + 1)); echo "  PASS: clears path shown files"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: path shown file not cleared"
  fi
else
  echo "  SKIP: session-start-hook.sh not found"
fi

# Cleanup test files if they survived
rm -f /tmp/claude-vocab-shown-$$.txt /tmp/claude-path-shown-$$.txt

# --- Cleanup ---
rm -rf "$TEST_DIR"

# --- Summary ---
echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
