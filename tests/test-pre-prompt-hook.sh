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
REBUILD="$SCRIPT_DIR/scripts/rebuild-tsv.sh"
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
  if grep -q "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:200}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -q "$unexpected" <<<"$output"; then
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
    echo "    got: ${output:0:200}"
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
echo "=== SessionStart hook clears this session shown files ==="
# The markers are keyed on the payload session_id and live in the project, not on $PPID in
# /tmp (#17, #23) -- so this drives the hook with a session id and looks in the tree.
# tests/test-session-markers.sh carries the rest: another session is left alone, a
# traversing id is refused, and no /tmp file of anyone else is swept.
SESSION_STATE="$TEST_DIR/.claude/jit-context/.discovery/state"

if [ -f "$SESSION_HOOK" ]; then
  mkdir -p "$SESSION_STATE"
  touch "$SESSION_STATE/vocab-shown-testsess.txt"
  touch "$SESSION_STATE/path-shown-testsess.txt"
  printf '{"session_id":"testsess","hook_event_name":"SessionStart"}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$SESSION_HOOK" >/dev/null 2>&1
  if [ ! -f "$SESSION_STATE/vocab-shown-testsess.txt" ]; then
    PASS=$((PASS + 1)); echo "  PASS: clears vocab shown files"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: vocab shown file not cleared"
  fi
  if [ ! -f "$SESSION_STATE/path-shown-testsess.txt" ]; then
    PASS=$((PASS + 1)); echo "  PASS: clears path shown files"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: path shown file not cleared"
  fi
else
  echo "  SKIP: session-start-hook.sh not found"
fi

rm -f "$SESSION_STATE/vocab-shown-testsess.txt" "$SESSION_STATE/path-shown-testsess.txt"

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
    echo "    raw control byte in: $(LC_ALL=C perl -0777 -pe 's/([\x00-\x1f])/sprintf("<%02X>",ord($1))/ge; $_ = substr($_, 0, 200)' "$out")"
  fi
  rm -f "$out"
}

# --- Issue #68: a malformed UTF-8 byte must not silence the hook ---------------------
# A lone 0xE9 -- a Latin-1 `e-acute` pasted out of a non-UTF-8 file, or a multibyte
# sequence cut at a copy boundary -- made one-true-awk abort the END block with
# `illegal byte sequence`, print NOTHING (not even `{}`), write the diagnostic into the
# session and exit 0. gawk did not abort but printed `Invalid multibyte data detected`
# to the same place. Failing open AND being loud: the two things common.sh forbids.
#
# The guarantee asserted: a malformed byte anywhere in the prompt must not stop a valid
# ASCII keyword ELSEWHERE in that prompt from matching, and nothing may reach stderr.
#
# BOTH legs are needed and neither carries the other. "No error appeared" is true of a
# hook that never ran -- which is the failure being fixed -- so the keyword leg is the
# positive control, and it is taken from the SAME call rather than a neighbouring one.
#
# The locale is the caller's, and it matters: `C` is precisely where the bug does not
# reproduce, so a suite that happened to inherit `C` would assert nothing. This picks a
# UTF-8 locale when the machine has one. The hook pins the locale of its own awk, so
# what is chosen here only controls what the caller hands it.
pick_utf8_locale() {
  local c
  for c in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if [ "$(LC_ALL="$c" locale charmap 2>/dev/null)" = "UTF-8" ]; then
      printf '%s' "$c"; return 0
    fi
  done
  # No `locale` command, or no UTF-8 locale installed (Git Bash is the case in mind).
  # Falls back to whatever the caller already has rather than inventing one.
  printf '%s' "${LC_ALL:-${LANG:-C}}"
}
UTF8_LOCALE="$(pick_utf8_locale)"
BADBYTE="$(printf '\351')"
TRUNCSEQ="$(printf '\303')"
echo ""
echo "caller locale for the malformed-byte assertions: $UTF8_LOCALE"

# The bad byte has to reach awk under the caller locale chosen above, not the ambient
# one, or the assertion silently stops being about anything on a machine set to `C`.
run_hook_engine_utf8() {
  printf '%s\n' "$2" | LC_ALL="$UTF8_LOCALE" PATH="$ENGINE_BIN/$1:$PATH" \
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2>/dev/null
}

assert_survives_malformed() {
  local desc="$1" eng="$2" payload="$3" needle="$4" out err
  out=$(mktemp); err=$(mktemp)
  printf '%s\n' "$payload" | LC_ALL="$UTF8_LOCALE" PATH="$ENGINE_BIN/$eng:$PATH" \
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" > "$out" 2> "$err"
  if LC_ALL=C grep -qF "$needle" "$out"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc -- the ASCII keyword still matched"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc -- the ASCII keyword did NOT match"
    echo "    stdout: $(LC_ALL=C tr -c '[:print:]' '?' < "$out")"
    echo "    stderr: $(LC_ALL=C tr -c '[:print:]' '?' < "$err")"
  fi
  if [ -s "$err" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc -- the hook wrote into the session stderr"
    echo "    stderr: $(LC_ALL=C tr -c '[:print:]' '?' < "$err")"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc -- nothing reached stderr"
  fi
  rm -f "$out" "$err"
}

for eng in $ENGINES; do
  # Every fixture below is unique per engine AND per suite run. That was originally a guard
  # against the $PPID marker collision (#17, #23), which no test could name; the payloads
  # here carry no session_id, so since that fix the hook keeps no marker file at all and
  # nothing can carry between calls. Kept because two engines sharing one keyword would
  # still be one entry shown twice within a single run.
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
  # The middle line carries a CR that is NOT a line terminator. On Git Bash the awk that
  # reads this file opens it in text mode, so the CR of a CRLF is consumed by the runtime
  # before the awk program sees it -- there is no terminator CR left to escape, and an
  # assertion on one asserts a property of the C runtime rather than of this hook. A bare
  # mid-line CR survives that translation, so it is the one CR whose escaping can be
  # asserted everywhere. The CRLF terminators stay: on Linux and macOS they are real.
  printf 'CRLF body line one\r\nbare\rCR mid-line\r\nCRLF body line two\r\n' > "$VOCAB_DIR/00-manual/r-$u.md"
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

  echo "=== [$eng] Latin-1 accents fold to ASCII (issue #31) ==="
  # Surviving the character is not the same as folding it. #14 stopped an accent aborting
  # the END block; the accent still turned into a space, so `détail` and `detail` were
  # different keywords while the comment above the normalisation claimed they were one.
  printf 'detail%s\td-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  printf 'facade%s\tfa-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  # An index built BEFORE the fold carries the mangled spelling: rebuild-tsv.sh turned the
  # keyword `légacy` into the row `l gacy`, which matched an accented prompt by accident.
  # Folding the prompt alone would kill that row the moment the plugin is upgraded and the
  # index is not rebuilt -- silently, which is this repo's worst failure shape.
  printf 'l gacy%s\tlg-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  echo "accent fold body" > "$VOCAB_DIR/00-manual/d-$u.md"
  echo "cedilla fold body" > "$VOCAB_DIR/00-manual/fa-$u.md"
  echo "legacy mangled body" > "$VOCAB_DIR/00-manual/lg-$u.md"

  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"le détail$u de la facture\"}")
  assert_contains "[$eng] an accented prompt reaches an ASCII keyword" "$OUT" "accent fold body"

  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"la FAÇADE$u du batiment\"}")
  assert_contains "[$eng] an accented capital folds too" "$OUT" "cedilla fold body"

  # The other direction. A fold that fires on everything looks like success from one side:
  # dropping the accent must not also drop the letter it sat on.
  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"le dtail$u de la facture\"}")
  assert_empty "[$eng] folding does not make a near miss match" "$OUT"

  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"un légacy$u ancien\"}")
  assert_contains "[$eng] a pre-fold index row still fires" "$OUT" "legacy mangled body"

  echo "=== [$eng] an accented keyword is indexed folded (issue #31) ==="
  # The keyword side, driven through rebuild-tsv.sh rather than a hand-written row: the
  # index writer is what has to agree with the matcher, and folding only the prompt leaves
  # `keywords: détail` indexed as `d tail` and unreachable from the prompt `detail`.
  RB="$TEST_DIR/rebuild-$u"
  mkdir -p "$RB/.claude/jit-context/vocabulary/00-manual"
  printf -- '---\nkeywords: détail%s, FAÇADE%s\n---\naccented keyword body\n' "$u" "$u" \
    > "$RB/.claude/jit-context/vocabulary/00-manual/kw-$u.md"
  PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$RB" bash "$REBUILD" >/dev/null 2>&1
  IDX=$(cat "$RB/.claude/jit-context/vocabulary/00-manual/00-index.tsv")
  assert_contains "[$eng] an accented keyword indexes folded" "$IDX" "detail$u"
  assert_contains "[$eng] and an accented capital keyword too" "$IDX" "facade$u"
  assert_not_contains "[$eng] not as the fragment it used to be" "$IDX" "d tail$u"

  run_rebuilt() {
    echo "$1" | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$RB" bash "$HOOK" 2>/dev/null
  }
  OUT=$(run_rebuilt "{\"prompt\":\"le detail$u sans accent\"}")
  assert_contains "[$eng] an unaccented prompt reaches an accented keyword" "$OUT" "accented keyword body"

  OUT=$(run_rebuilt "{\"prompt\":\"le dtail$u sans accent\"}")
  assert_empty "[$eng] and a near miss still does not" "$OUT"

  # Folding the keyword makes two spellings collide, and `keywords: détail, detail` is the
  # pattern the README now tells an author they may write. rebuild-tsv.sh emits one row per
  # keyword and does not dedup, so both rows carry the same word and the same file, and the
  # injected header said `(matched: detail|detail)`. The entry is right and the receipt for
  # it is not, in text that goes into the model's context.
  printf -- '---\nkeywords: détail%s, detail%s\n---\ntwo spellings body\n' "$u" "$u" \
    > "$RB/.claude/jit-context/vocabulary/00-manual/dup-$u.md"
  rm -f "$RB/.claude/jit-context/vocabulary/00-manual/kw-$u.md"
  PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$RB" bash "$REBUILD" >/dev/null 2>&1
  OUT=$(run_rebuilt "{\"prompt\":\"le detail$u deux fois\"}")
  assert_contains "[$eng] two spellings of one keyword still fire" "$OUT" "two spellings body"
  assert_not_contains "[$eng] and are named once, not twice" "$OUT" "detail$u|detail$u"

  echo "=== [$eng] a malformed UTF-8 byte does not silence the hook (issue #68) ==="
  printf 'mojibake%s\tmb-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  echo "mojibake body" > "$VOCAB_DIR/00-manual/mb-$u.md"
  # The control first, in the same fixture: without it a green below could mean the entry
  # was unreachable for a reason that has nothing to do with the bad byte.
  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"mojibake$u please\"}")
  assert_contains "[$eng] control: the ASCII keyword matches with no bad byte" "$OUT" "mojibake body"
  assert_survives_malformed "[$eng] lone 0xE9 beside an ASCII keyword" "$eng" \
    "{\"prompt\":\"mojibake$u $BADBYTE please\"}" "mojibake body"
  # The other way this arrives: a paste cut at a copy boundary leaves a lead byte with no
  # continuation byte after it.
  assert_survives_malformed "[$eng] truncated multibyte sequence beside an ASCII keyword" "$eng" \
    "{\"prompt\":\"mojibake$u $TRUNCSEQ please\"}" "mojibake body"
  # And the negative direction, so this is not a rule that fires on everything: a bad byte
  # must not conjure a match the same prompt without it would not produce.
  OUT=$(run_hook_engine_utf8 "$eng" "{\"prompt\":\"mojibak$u $BADBYTE please\"}")
  assert_empty "[$eng] a bad byte does not make a near miss match" "$OUT"

  echo "=== [$eng] control characters in an entry body (issue #15) ==="
  OUT=$(run_hook_engine "$eng" "{\"prompt\":\"a crlf$u question\"}")
  assert_contains "[$eng] CRLF entry is injected" "$OUT" "CRLF body line one"
  assert_contains "[$eng] CR is escaped" "$OUT" 'bare\\rCR mid-line'
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
