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
# SECTION 2b: JSON string decoding (issue #6)
# =============================================

echo ""
echo "=== Keyword after a newline in the prompt ==="
OUT=$(run_hook '{"prompt":"check the billing\npayments dashboard"}')
assert_contains "billing matched" "$OUT" "billing context"
assert_contains "payments matched across the decoded newline" "$OUT" "payments context"

echo ""
echo "=== Keyword after an escaped quote in the prompt ==="
OUT=$(run_hook '{"prompt":"he said \"hello\" and then asked about billing"}')
assert_contains "keyword after an escaped quote is still seen" "$OUT" "billing context"

echo ""
echo "=== Prompt with no keyword stays silent ==="
OUT=$(run_hook '{"prompt":"he said \"hello\" and left"}')
assert_empty "no match after an escaped quote either" "$OUT"

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

# =============================================
# SECTION: awk engine matrix — multibyte prompts, control characters in entries
# =============================================
# gawk and one-true-awk do not agree on multibyte handling, and the CI legs do not run
# the same awk: Linux ships gawk, macOS and Git Bash ship a one-true-awk derivative.
# Issue #14 passed under gawk and aborted the END block under one-true-awk, printing
# nothing while still exiting 0 — indistinguishable from having nothing to say. A green
# run on one engine is therefore not evidence about the other, so every assertion below
# runs once per awk on this machine, reached through a PATH shim.
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
# to reject the whole object, which renders as the hook having said nothing. perl is
# already a hard dependency of common.sh, so this assertion adds none.
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

for eng in $ENGINES; do
  # Every fixture below is unique per engine AND per suite run. The hook dedupes matches
  # in /tmp/claude-vocab-shown-$PPID.txt, which no test can name; a $PPID reused from an
  # earlier suite run carries a stale marker and would suppress a match for a reason that
  # has nothing to do with the fix. Observed once. A suite-unique keyword cannot collide.
  u="${eng}$$"
  printf 'facture%s\tf-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  printf 'camel%s\tc-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  printf 'crlf%s\tr-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  printf 'ctrl%s\tk-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  # assert_no_raw_controls runs the hook itself, so it gets its own entries. Sharing them
  # with the assert_contains calls above would mean a second match of an entry the hook has
  # already marked shown, and a suppressed match trips the vacuous-pass leg.
  printf 'crlfraw%s\trr-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  printf 'ctrlraw%s\trk-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  echo "facture body" > "$VOCAB_DIR/00-manual/f-$u.md"
  echo "camel body" > "$VOCAB_DIR/00-manual/c-$u.md"
  # This repo's .gitattributes forces eol=lf on *.md; a user's project has no such
  # guarantee and CRLF is the Windows default (issue #15).
  printf 'CRLF body line one\r\nCRLF body line two\r\n' > "$VOCAB_DIR/00-manual/r-$u.md"
  # The NUL on the second line is the engine-divergent case: gawk carries an embedded NUL
  # through getline and would emit it raw, one-true-awk truncates the line at it. Neither
  # may put a raw byte in the JSON, and assert_no_raw_controls holds for both readings.
  printf 'control \001 and \014 and \037 here\nnul \000 tail\n' > "$VOCAB_DIR/00-manual/k-$u.md"
  cp "$VOCAB_DIR/00-manual/r-$u.md" "$VOCAB_DIR/00-manual/rr-$u.md"
  cp "$VOCAB_DIR/00-manual/k-$u.md" "$VOCAB_DIR/00-manual/rk-$u.md"

  echo ""
  echo "=== [$eng] non-ASCII prompt (issue #14) ==="
  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"détail de la facture$u\"}")
  assert_contains "[$eng] non-ASCII prompt still matches a keyword" "$OUT" "facture body"

  OUT=$(run_hook_engine "$eng" '{"prompt":"détail de la façade"}')
  assert_empty "[$eng] non-ASCII prompt with no keyword stays silent" "$OUT"

  # The CamelCase split is the loop that aborted. Drive it both ways: the split is the only
  # thing that makes this keyword visible, so the same token without the case transition
  # must produce silence. A rule that fires on everything looks like success from one side.
  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"parlons de DétailCamel$u\"}")
  assert_contains "[$eng] CamelCase split survives a non-ASCII token" "$OUT" "camel body"

  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"parlons de détailcamel$u\"}")
  assert_empty "[$eng] no case transition, no match" "$OUT"

  echo "=== [$eng] control characters in an entry body (issue #15) ==="
  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"a crlf$u question\"}")
  assert_contains "[$eng] CRLF entry is injected" "$OUT" "CRLF body line one"
  assert_contains "[$eng] CR is escaped" "$OUT" 'one\\r\\nCRLF'
  assert_no_raw_controls "[$eng] CRLF entry emits no raw control byte" "$eng" "{\"prompt\":\"a crlfraw$u question\"}"

  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"a ctrl$u question\"}")
  assert_contains "[$eng] control chars escaped as \u00XX" "$OUT" 'control \\u0001 and \\u000c and \\u001f here'
  assert_no_raw_controls "[$eng] control-char entry emits no raw control byte" "$eng" "{\"prompt\":\"a ctrlraw$u question\"}"
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
