#!/bin/bash
# Tests for pre-tool-hook.sh (TSV-based: tool rules + vocabulary matching)
# Usage: bash tests/test-pre-tool-hook.sh
#
# `once` mode IS driven here, in the #112 section at the bottom. The note that used to sit
# on this line -- that it could not be, because each subprocess gets a different $PPID --
# stopped being true when the session marker moved off $PPID and onto the payload's
# session_id (#17, #23). A payload that carries one gets a real marker file, so a suite can
# spend a once-budget in one call and observe it gone in the next.

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
cat > "$TOOLS_DIR/00-index.tsv" << 'TSV'
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
  echo "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2> /dev/null
}

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
# jit-drive: assert_blocked blocked capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -q -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:200}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -q -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
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
    echo "    got: ${output:0:200}"
  fi
}

assert_blocked() {
  local desc="$1" output="$2"
  if grep -q '"decision":"block"' <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected decision:block"
    echo "    got: ${output:0:200}"
  fi
}

# Reads the subject out of a FILE named on the command line, so one pair covers hook
# stdout, the session marker and hooks.log without a variable per subject. `$( )` drops
# NUL bytes, which is why the subject is a path at all (#78) -- and grep is handed the
# file directly rather than a pipe, so there is no reader to exit early and no SIGPIPE to
# invert the verdict (#56).
#
# A missing path is an ABSENCE, not an error: the session marker does not exist until
# something is marked, and "the blocked call marked nothing" is exactly the assertion that
# has to hold before that file is there. Every not_contains below is therefore paired with
# a contains on the same path.
# jit-drive: assert_path_contains contains path-arg
# jit-drive: assert_path_not_contains not_contains path-arg
assert_path_contains() {
  local desc="$1" path="$2" needle="$3"
  if LC_ALL=C grep -qF -- "$needle" "$path" 2> /dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected $path to contain: $needle"
    echo "    got: $(LC_ALL=C tr -c '[:print:]' '?' < "$path" 2> /dev/null | cut -c1-300)"
  fi
}

assert_path_not_contains() {
  local desc="$1" path="$2" needle="$3"
  if LC_ALL=C grep -qF -- "$needle" "$path" 2> /dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    $path should NOT contain: $needle"
    echo "    got: $(LC_ALL=C tr -c '[:print:]' '?' < "$path" 2> /dev/null | cut -c1-300)"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
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
echo "=== Vocab: a path token survives when CLAUDE_PROJECT_DIR is unset (issue #361) ==="
# Under Codex, CLAUDE_PROJECT_DIR is never set, so the awk-side `project` var (a `-v`
# fallback of the single byte ".") used to reach gsub(project "/", "", tt) UNESCAPED --
# and "." is an ERE wildcard, so the pattern matched "any char, then /" at every slash
# in `tt`, not just a leading project prefix. `src/pipeline/config.yml` was mangled to
# `srpipelinconfig.yml`, which no longer contains the keyword "pipeline" at all: a real
# vocabulary match silently stopped firing, not just a cosmetic log truncation.
#
# `cd` into TEST_DIR rather than relying on $PWD alone -- common.sh's own JIT_BASE
# fallback is "${CLAUDE_PROJECT_DIR:-${PWD:-.}}" (#266), so the bash-side tree
# resolution is unaffected either way; only the awk-side `-v project=` fallback still
# reads the bare ".", which is what this test pins.
T361_LOG="$TEST_DIR/.claude/jit-context/.discovery/logs/hooks.log"
: > "$T361_LOG"
T361_OUT=$(cd "$TEST_DIR" && env -u CLAUDE_PROJECT_DIR bash "$HOOK" \
  <<< '{"tool_name":"Bash","tool_input":{"command":"./supertool read:src/pipeline/config.yml"}}' \
  2> /dev/null)
assert_contains "[#361] pipeline vocab still matches with no CLAUDE_PROJECT_DIR" "$T361_OUT" "pipeline vocabulary"
assert_path_contains "[#361] the log tail keeps every slash" "$T361_LOG" "src/pipeline/config.yml"
assert_path_not_contains "[#361] the log tail is not missing the dropped bytes" "$T361_LOG" "srpipelinconfig.yml"

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
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | CLAUDE_PROJECT_DIR="/tmp/nonexistent" bash "$HOOK" 2> /dev/null)
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

# =============================================
# SECTION: awk engine matrix — multibyte paths, control characters in entries
# =============================================
# See the same section in test-pre-prompt-hook.sh: issue #14 aborted the END block under
# one-true-awk and passed under gawk, and the CI legs do not run the same awk. Every
# assertion below runs once per awk on this machine, reached through a PATH shim.
ENGINE_BIN=$(mktemp -d)
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2> /dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

run_hook_engine() {
  echo "$2" | PATH="$ENGINE_BIN/$1:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2> /dev/null
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
  echo "$payload" | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" > "$out" 2> /dev/null
  if ! LC_ALL=C perl -0777 -ne 'exit(/additionalContext|"reason"/ ? 0 : 1)' "$out"; then
    # A hook that injected nothing trivially carries no control byte. Without this leg the
    # assertion passes for the wrong reason -- which is the defect class this repo keeps
    # finding in its own product.
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc -- nothing was injected, so the check was vacuous"
  elif LC_ALL=C perl -0777 -ne 's/\n\z//; exit(/[\x00-\x1f]/ ? 1 : 0)' "$out"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    raw control byte in: $(LC_ALL=C perl -0777 -pe 's/([\x00-\x1f])/sprintf("<%02X>",ord($1))/ge; $_ = substr($_, 0, 200)' "$out")"
  fi
  rm -f "$out"
}

# CRLF is the Windows default and a user's project carries no .gitattributes of ours.
# The blocked branch escapes its reason separately from the reminder branch, so both
# are driven (issue #15).
printf 'Bash\tcrlfcmd\tcrlf-rule.md\tremind\t\t\n' >> "$TOOLS_DIR/00-index.tsv"
printf 'Bash\tblockcmd\tblock-rule.md\tremind\t--needed\t\n' >> "$TOOLS_DIR/00-index.tsv"
# The middle line carries a CR that is NOT a line terminator. On Git Bash the awk that
# reads this file opens it in text mode, so the CR of a CRLF is consumed by the runtime
# before the awk program ever sees it -- on that platform there is no terminator CR left to
# escape, and asserting on one asserts a property of the C runtime, not of this hook. A bare
# mid-line CR is not touched by that translation, so it is the one CR whose escaping can be
# asserted on every platform. The CRLF terminators stay: on Linux and macOS they are real
# and assert_no_raw_controls still has to cope with them.
printf 'CRLF rule line one\r\nbare\rCR mid-line\r\nCRLF rule line two\r\n' > "$TOOLS_DIR/crlf-rule.md"
# The NUL on the second line is the engine-divergent case: gawk carries an embedded NUL
# through getline and would emit it raw, one-true-awk truncates the line at it. Neither may
# put a raw byte in the JSON, and assert_no_raw_controls holds for both readings.
printf 'blocked \001 reason \014 text \037 here\nnul \000 tail\n' > "$TOOLS_DIR/block-rule.md"

# --- Issue #68: a malformed UTF-8 byte must not silence the hook ---------------------
# The same defect as in test-pre-prompt-hook.sh, reached through a tool command instead
# of a prompt, and worse here: on one-true-awk a lone 0xE9 anywhere in the command made
# the END block abort, so a `block` rule that was indexed, correctly written and
# genuinely matched did NOT block. `git push \351 origin` returned nothing at all while
# `git push origin` was refused. Failing OPEN on the one dimension that can refuse a
# call. gawk did not abort but printed a multibyte warning into the session.
#
# Both legs are needed and neither carries the other: "no error appeared" is true of a
# hook that never ran, which is the failure being fixed.
#
# The locale is the caller's and it matters: `C` is where the bug does not reproduce.
pick_utf8_locale() {
  local c
  for c in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if [ "$(LC_ALL="$c" locale charmap 2> /dev/null)" = "UTF-8" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  # No `locale` command, or no UTF-8 locale installed (Git Bash is the case in mind).
  printf '%s' "${LC_ALL:-${LANG:-C}}"
}
UTF8_LOCALE="$(pick_utf8_locale)"
# Whether what came back is ACTUALLY a UTF-8 locale. On a runner with no `locale` command
# or no UTF-8 locale installed -- Git Bash is the case in mind -- the fallback is the
# caller own, which is normally `C`, and `C` is precisely where the bug does not reproduce.
# The assertions below would then still pass, and pass for the wrong reason: they could not
# tell the fix from its absence. Said out loud rather than gone quietly green, on the
# pattern section A of tests/test-hook-tmpfile.sh already uses for symbolic links.
UTF8_LOCALE_REAL=no
if [ "$(LC_ALL="$UTF8_LOCALE" locale charmap 2> /dev/null)" = "UTF-8" ]; then UTF8_LOCALE_REAL=yes; fi
if [ "$UTF8_LOCALE_REAL" != yes ]; then
  echo "  SKIP-NOTE: no UTF-8 locale on this machine ($UTF8_LOCALE). The malformed-byte"
  echo "             assertions below run under a byte locale, where the defect does not"
  echo "             reproduce -- they still assert the guarantee, they just cannot fail"
  echo "             for it here."
  if [ "${JIT_TESTS_REQUIRE_UTF8_LOCALE:-}" = 1 ]; then
    FAIL=$((FAIL + 1))
    echo ""
    echo "  FAIL: A UTF-8 LOCALE WAS REQUIRED AND NOT OBTAINED."
    echo "        JIT_TESTS_REQUIRE_UTF8_LOCALE=1 says this environment was configured to"
    echo "        have one, so the note above is a broken configuration and not a platform"
    echo "        without the capability. Failed rather than noted because run-all.sh"
    echo "        renders a note green. Nothing here is a defect in the hooks."
  fi
fi
BADBYTE="$(printf '\351')"
echo ""
echo "caller locale for the malformed-byte assertions: $UTF8_LOCALE"

run_hook_engine_utf8() {
  printf '%s\n' "$2" | LC_ALL="$UTF8_LOCALE" PATH="$ENGINE_BIN/$1:$PATH" \
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2> /dev/null
}

assert_survives_malformed() {
  local desc="$1" eng="$2" payload="$3" needle="$4" out err
  out=$(mktemp)
  err=$(mktemp)
  printf '%s\n' "$payload" | LC_ALL="$UTF8_LOCALE" PATH="$ENGINE_BIN/$eng:$PATH" \
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" > "$out" 2> "$err"
  if LC_ALL=C grep -qF -- "$needle" "$out"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc -- the rule still fired"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc -- the rule did NOT fire"
    echo "    stdout: $(LC_ALL=C tr -c '[:print:]' '?' < "$out")"
    echo "    stderr: $(LC_ALL=C tr -c '[:print:]' '?' < "$err")"
  fi
  if [ -s "$err" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc -- the hook wrote into the session stderr"
    echo "    stderr: $(LC_ALL=C tr -c '[:print:]' '?' < "$err")"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc -- nothing reached stderr"
  fi
  rm -f "$out" "$err"
}

for eng in $ENGINES; do
  # Vocabulary matches are deduped per session. That used to mean a /tmp file keyed on
  # $PPID, which no test could name and which a recycled pid could poison (#17, #23); the
  # payloads here carry no session_id, so the hook now keeps no marker file at all. Keywords
  # stay unique per engine anyway, because one keyword shared by two engines would be one
  # entry shown twice inside a single call. The rule rows below stay static -- they are
  # `remind`, so nothing dedupes them.
  u="${eng}$$"
  printf 'plain%s\tp-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  printf 'camel%s\tc-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  echo "plain vocabulary body" > "$VOCAB_DIR/00-manual/p-$u.md"
  echo "camel vocabulary body" > "$VOCAB_DIR/00-manual/c-$u.md"

  echo ""
  echo "=== [$eng] non-ASCII path token (issue #14) ==="
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/Détail/plain$u.php\"}}")
  assert_contains "[$eng] non-ASCII path token still matches vocabulary" "$OUT" "plain vocabulary body"

  OUT=$(run_hook_engine "$eng" '{"tool_name":"Bash","tool_input":{"command":"cat src/Détail/facade.php"}}')
  assert_empty "[$eng] non-ASCII path token with no keyword stays silent" "$OUT"

  echo "=== [$eng] Latin-1 accents fold to ASCII (issue #31) ==="
  # This hook reads the same vocabulary index as pre-prompt-hook.sh, so it has to normalise
  # a path token the same way rebuild-tsv.sh normalises the keyword. Without the fold here,
  # a folded index row is reachable from a prompt and dead from a file path.
  printf 'detail%s\td-%s.md\n' "$u" "$u" >> "$VOCAB_DIR/00-manual/00-index.tsv"
  echo "accent fold vocabulary body" > "$VOCAB_DIR/00-manual/d-$u.md"

  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/Détail$u/a.php\"}}")
  assert_contains "[$eng] an accented path token reaches an ASCII keyword" "$OUT" "accent fold vocabulary body"

  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/Dtail$u/a.php\"}}")
  assert_empty "[$eng] folding does not make a near miss match" "$OUT"

  # The CamelCase split is the loop that aborted. It is the only thing that makes this
  # keyword visible, so the same token lowercased must produce silence -- a rule that fires
  # on everything looks like success from one side.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/DétailCamel$u/x.php\"}}")
  assert_contains "[$eng] CamelCase split survives a non-ASCII path" "$OUT" "camel vocabulary body"

  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/détailcamel$u/x.php\"}}")
  assert_empty "[$eng] no case transition, no match" "$OUT"

  echo "=== [$eng] a malformed UTF-8 byte does not defeat a block rule (issue #68) ==="
  # `require` with no `remind`: the row blocks whenever --safe is absent, which is the
  # strongest thing this hook does and the thing that must not fail open.
  printf 'Bash\tmojiblock%s\tmbk-%s.md\tremind\t--safe\t\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  echo "mojiblock rule context" > "$TOOLS_DIR/mbk-$u.md"
  # The control, in the same fixture and the same run: an ordinary command blocks.
  OUT=$(run_hook_engine_utf8 "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mojiblock$u now\"}}")
  assert_blocked "[$eng] control: the rule blocks on a clean command" "$OUT"
  assert_survives_malformed "[$eng] a bad byte in the command does not defeat the block" "$eng" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mojiblock$u $BADBYTE now\"}}" \
    '"decision":"block"'
  # Both directions: the bad byte must not start blocking things the rule never matched.
  # assert_empty rather than assert_not_contains, because "no block appeared" is also
  # true of a hook that printed nothing at all -- which is the defect being fixed.
  OUT=$(run_hook_engine_utf8 "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mojiblok$u $BADBYTE now\"}}")
  assert_empty "[$eng] and does not block a command the rule never matched" "$OUT"

  echo "=== [$eng] non-ASCII tool-rule terms fold like vocabulary does (issue #76) ==="
  # #68 pinned LC_ALL=C on this awk. Under `C` neither engine's tolower() folds a multibyte
  # capital, and the tool matcher -- unlike the vocabulary half -- never called the Latin-1
  # fold table. So a rule whose term carries an accent stopped matching the uppercase
  # spelling of the same word: a `forbid` that blocked the command started injecting
  # advisory text instead, exit 0, nothing on stderr. Failing OPEN on the one dimension
  # that can refuse a call.
  #
  # Every assertion is inside the per-engine PATH shim because the defect is a property of
  # tolower() and the two engines differ about it. Both directions are driven for each
  # rule kind: the accented rule must fire on the uppercase AND the lowercase spelling,
  # and a near miss must still produce {} -- folding may not widen matching into a rule
  # that fires on everything.
  printf 'Bash\tdeploy%s\tfb-%s.md\tremind\t\tclé-privée\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  printf 'Bash\tship%s\trq-%s.md\tremind\tvalidé\t\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  printf 'Bash\tdonnées%s\tmt-%s.md\tremind\t\t\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  printf 'Bash\t~supprimer[[:space:]]+les[[:space:]]+données%s\trx-%s.md\tremind\t\t\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  printf 'Bash\tasciirule%s\tas-%s.md\tremind\t\tsecret\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  echo "accented forbid rule context" > "$TOOLS_DIR/fb-$u.md"
  echo "accented require rule context" > "$TOOLS_DIR/rq-$u.md"
  echo "accented match rule context" > "$TOOLS_DIR/mt-$u.md"
  echo "accented regex rule context" > "$TOOLS_DIR/rx-$u.md"
  echo "ascii control rule context" > "$TOOLS_DIR/as-$u.md"

  # forbid -- the reproduction in the issue. Fails open when it regresses.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"deploy$u --key CLÉ-PRIVÉE\"}}")
  assert_blocked "[$eng] accented forbid term blocks the uppercase spelling" "$OUT"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"deploy$u --key clé-privée\"}}")
  assert_blocked "[$eng] accented forbid term still blocks the lowercase spelling" "$OUT"
  # The other direction. The rule still MATCHES here, so the reminder is injected and {}
  # would be the wrong assertion -- what must be absent is the block.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"deploy$u --key CLE-PUBLIQUE\"}}")
  assert_contains "[$eng] near miss: the forbid rule still fires as a reminder" "$OUT" "accented forbid rule context"
  assert_not_contains "[$eng] near miss on the forbid term does not block" "$OUT" '"decision":"block"'

  # require -- the mirror. Fails CLOSED when it regresses: a command that satisfies the
  # requirement is refused. Safer direction, still wrong.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ship$u --flag VALIDÉ\"}}")
  assert_contains "[$eng] accented require rule still fires" "$OUT" "accented require rule context"
  assert_not_contains "[$eng] uppercase spelling satisfies an accented require term" "$OUT" '"decision":"block"'
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ship$u --flag validé\"}}")
  assert_not_contains "[$eng] lowercase spelling still satisfies it" "$OUT" '"decision":"block"'
  # The positive control for the two above: without the term at all, the row must block.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ship$u now\"}}")
  assert_blocked "[$eng] control: the require row does block when the term is absent" "$OUT"

  # plain match: term compared with index() against the truncated command.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"wipe DONNÉES$u now\"}}")
  assert_contains "[$eng] accented match term matches the uppercase spelling" "$OUT" "accented match rule context"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"wipe données$u now\"}}")
  assert_contains "[$eng] accented match term matches the lowercase spelling" "$OUT" "accented match rule context"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"wipe DONNES$u now\"}}")
  assert_empty "[$eng] a near miss on the accented match term stays silent" "$OUT"

  # regex match: an ERE out of the index compiled against the folded subject. Folding one
  # side alone is the same bug one level down -- an accented PATTERN becomes unmatchable.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"SUPPRIMER LES DONNÉES$u\"}}")
  assert_contains "[$eng] accented regex pattern matches the uppercase spelling" "$OUT" "accented regex rule context"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"supprimer les données$u\"}}")
  assert_contains "[$eng] accented regex pattern matches the lowercase spelling" "$OUT" "accented regex rule context"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"supprimer les donnes$u\"}}")
  assert_empty "[$eng] a near miss on the accented regex pattern stays silent" "$OUT"

  # A `~match` PATTERN is folded but deliberately not lowercased -- the subject is, the
  # pattern never was, so an ASCII capital in a pattern matches nothing. That is unchanged
  # by #76 and would be green without it; it is here because the README now states it as a
  # contract, and a documented contract with no assertion is one nobody notices breaking.
  printf 'Bash\t~SUPPRIMER[[:space:]]+TOUT%s\tuc-%s.md\tremind\t\t\n' "$u" "$u" >> "$TOOLS_DIR/00-index.tsv"
  echo "uppercase regex rule context" > "$TOOLS_DIR/uc-$u.md"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"SUPPRIMER TOUT$u\"}}")
  assert_empty "[$eng] an ASCII capital in a ~match pattern still matches nothing" "$OUT"

  # The control that catches a fold applied too broadly: an ASCII-only rule must behave
  # exactly as it does today, in all three directions.
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"asciirule$u --key SECRET\"}}")
  assert_blocked "[$eng] ASCII forbid term still blocks, unchanged" "$OUT"
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"asciirule$u --key public\"}}")
  assert_contains "[$eng] ASCII rule still fires as a reminder" "$OUT" "ascii control rule context"
  assert_not_contains "[$eng] ASCII rule does not block without the term" "$OUT" '"decision":"block"'
  OUT=$(run_hook_engine "$eng" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"asciirul$u --key SECRET\"}}")
  assert_empty "[$eng] ASCII near miss stays silent" "$OUT"

  echo "=== [$eng] control characters in an entry body (issue #15) ==="
  OUT=$(run_hook_engine "$eng" '{"tool_name":"Bash","tool_input":{"command":"crlfcmd now"}}')
  assert_contains "[$eng] CRLF rule is injected" "$OUT" "CRLF rule line one"
  assert_contains "[$eng] CR is escaped in the reminder" "$OUT" 'bare\\rCR mid-line'
  assert_no_raw_controls "[$eng] reminder emits no raw control byte" "$eng" '{"tool_name":"Bash","tool_input":{"command":"crlfcmd now"}}'

  OUT=$(run_hook_engine "$eng" '{"tool_name":"Bash","tool_input":{"command":"blockcmd now"}}')
  assert_blocked "[$eng] blockcmd without --needed is blocked" "$OUT"
  assert_contains "[$eng] block reason escapes control chars" "$OUT" 'blocked \\u0001 reason \\u000c text \\u001f here'
  assert_no_raw_controls "[$eng] block reason emits no raw control byte" "$eng" '{"tool_name":"Bash","tool_input":{"command":"blockcmd now"}}'
  echo "=== [$eng] a refused row is still reported on the block path (issue #103) ==="
  # Two refusals reach n_refused by different routes, and only one of them survives being
  # suppressed on a blocked call:
  #
  #   at LOAD -- an undefined escape in a `~match`. Counted on every call whose tool_name
  #     the row names, whatever the command was, so a later call that is not blocked
  #     counts it again and the notice is merely DEFERRED.
  #   at MATCH -- a body jit_read_body() cannot deliver. Counted only on a command the row
  #     actually matched, so when that command is also the one a block rule refuses, no
  #     later call ever counts it again and the notice is DROPPED for the session.
  #
  # Both are driven here, in a tree of their own: a row refused at load is refused for
  # every call, so leaving one in the shared fixture would put a refusal notice on top of
  # every other assertion in this file.
  #
  # Inside the per-engine shim because the match-refused half is jit_read_body(), which is
  # exactly where the engines diverged in #97.
  R103_NOTICE='could not be evaluated, so they did NOT run'

  r103_tree() {
    local d="$1" kind="$2" t v tsv vtsv l
    t="$d/.claude/jit-context/tools/00-manual"
    v="$d/.claude/jit-context/vocabulary"
    mkdir -p "$t" "$v/00-manual" "$v/10-auto" "$v/20-grouped" "$v/30-crosscutting"
    for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
      vtsv="$v/$l/00-index.tsv"
      : > "$vtsv"
    done
    tsv="$t/00-index.tsv"
    : > "$tsv"
    if [ "$kind" = dark ]; then
      # Refused at load: `\s` is PCRE, awk compiles it to a bare `s`.
      printf 'Bash\t~dark\\s+rule\tdk.md\tremind\t\t\n' >> "$tsv"
      echo "dark rule body" > "$t/dk.md"
      # Refused at match: gone.md is never created, so this row is counted on `blkcmd`
      # and on nothing else -- and `blkcmd` is the command the row below blocks.
      printf 'Bash\tblkcmd\tgone.md\tremind\t\t\n' >> "$tsv"
    fi
    printf 'Bash\tblkcmd\tblkr.md\tblock\t\t\n' >> "$tsv"
    echo "blkr rule body" > "$t/blkr.md"
  }

  # Read from a FILE, never from $( ): a command substitution silently drops NUL bytes,
  # and these assertions are about what actually reached stdout.
  r103_run() {
    printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}\n' "$2" "$3" \
      | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" > "$R103_OUT" 2> /dev/null
  }
  assert_file_contains() {
    if LC_ALL=C grep -qF "$2" "$R103_OUT"; then
      PASS=$((PASS + 1))
      echo "  PASS: $1"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $1"
      echo "    expected to contain: $2"
      echo "    got: $(LC_ALL=C tr -c '[:print:]' '?' < "$R103_OUT" | cut -c1-300)"
    fi
  }
  assert_file_not_contains() {
    if LC_ALL=C grep -qF "$2" "$R103_OUT"; then
      FAIL=$((FAIL + 1))
      echo "  FAIL: $1"
      echo "    should NOT contain: $2"
    else
      PASS=$((PASS + 1))
      echo "  PASS: $1"
    fi
  }

  R103_OUT=$(mktemp)
  R103_DARK=$(mktemp -d)
  R103_CLEAN=$(mktemp -d)
  r103_tree "$R103_DARK" dark
  r103_tree "$R103_CLEAN" clean

  # 1. The blocked call. The block reason itself is asserted in the same output as the
  #    positive control: "the notice is there" is also true of a hook that never spoke,
  #    and "the notice is missing" is true of one that died before the decision.
  r103_run "$R103_DARK" "s103-$u" "blkcmd now"
  assert_file_contains "[$eng] control: the block rule still blocks" '"decision":"block"'
  assert_file_contains "[$eng] control: the block reason is its own text" "blkr rule body"
  assert_file_contains "[$eng] a refused row is reported on the blocked call" "$R103_NOTICE"
  assert_file_contains "[$eng] both refusals are counted on the blocked call" "2 rule(s)"

  # 2. Same session, a call that is not blocked. The `break` at the block rule truncates
  #    the row scan, so the list delivered above may be short -- which is why the blocked
  #    call must NOT consume the once-per-session marker. The complete notice still lands.
  r103_run "$R103_DARK" "s103-$u" "echo hello"
  assert_file_contains "[$eng] the blocked call did not consume the once-marker" "$R103_NOTICE"
  # One, not two: `echo hello` matches neither the block rule nor the row beside it, so
  # the match-refused row is not counted here at all. That is the whole point of the
  # assertion above -- it is the row this list is MISSING that had no other way out.
  assert_file_contains "[$eng] and the deferred list is the load-refused row only" "1 rule(s)"

  # 3. And that marker is real: the next clean call of the same session is silent.
  r103_run "$R103_DARK" "s103-$u" "echo hello again"
  assert_file_not_contains "[$eng] the notice is still once per session" "$R103_NOTICE"

  # 4. The other direction, in the same shape of fixture: an honest tree gains no notice
  #    from being blocked. A notice that appears whatever the tree says is not a report.
  r103_run "$R103_CLEAN" "s103c-$u" "blkcmd now"
  assert_file_contains "[$eng] control: the honest tree blocks too" '"decision":"block"'
  assert_file_not_contains "[$eng] an honest tree gains no refusal notice when blocked" "$R103_NOTICE"

  rm -rf "$R103_DARK" "$R103_CLEAN"
  rm -f "$R103_OUT"

  echo "=== [$eng] a blocked call burns nothing it never delivered (issue #112) ==="
  # The vocabulary pass runs AFTER the rule loop has broken on a block, and the block path
  # discards `matched`. Every entry it matched was marked shown anyway -- in the marker file
  # pre-prompt-hook.sh reads too -- so the entry was spent for the session, in both
  # dimensions, having been delivered to nobody. hooks.log then reported it as `[shown:N]`,
  # which is exactly what a correct delivery looks like.
  #
  # The shape asserted here, of the three that were on the table:
  #   the pass still RUNS -- a vocabulary row that cannot be evaluated is reported beside
  #     the block reason, and on a command that is always blocked that is its only channel
  #     (#103), so skipping the pass would re-create #103 one dimension over;
  #   it delivers NOTHING beside the block reason -- #103 folded the refusal notices in and
  #     deliberately left `matched` out, because an advisory entry has another channel and
  #     a report about the tree has none. That line does not move here;
  #   and therefore it marks nothing and logs nothing as shown.
  #
  # Four controls, because every assertion below passes for a wrong reason on its own:
  #   * a session with no blocked call MUST inject -- "it still fires later" is true of a
  #     harness that never fired anything at all;
  #   * the second identical call in that session MUST be silent -- otherwise the dedup is
  #     simply broken and the delivery after the block proves nothing;
  #   * the marker MUST name the entry once it is delivered -- otherwise "the marker does
  #     not name it" is true of a path this test spelled wrong;
  #   * the control log line MUST carry the delivered token and MUST NOT carry `withheld[`
  #     -- a marker that appears on every line marks nothing.
  #
  # Inside the per-engine loop: the pass turns on jit_entry_load(), which is where the two
  # awks diverged in #97, and the block path is the one that had no JSON at all there.
  t112_tree() {
    local d="$1" t v l idx
    idx=00-index.tsv
    t="$d/.claude/jit-context/tools/00-manual"
    v="$d/.claude/jit-context/vocabulary"
    mkdir -p "$t" "$v/00-manual" "$v/10-auto" "$v/20-grouped" "$v/30-crosscutting"
    for l in 10-auto 20-grouped 30-crosscutting; do : > "$v/$l/$idx"; done
    printf 'billing\tbilling.md\n' > "$v/00-manual/$idx"
    echo "billing vocabulary body" > "$v/00-manual/billing.md"
    # The advisory row comes FIRST, so it is matched and marked before the row below ends
    # the scan. Its match is the path, not the verb, so a later command that is not blocked
    # still reaches it -- which is what makes the once-marker observable.
    printf 'Bash\tsrc/Billing\tadv.md\tonce,remind\t\t\n' > "$t/$idx"
    printf 'Bash\tblkcmd\tblkr.md\tblock\t\t\n' >> "$t/$idx"
    echo "advisory rule body" > "$t/adv.md"
    echo "blkr rule body" > "$t/blkr.md"
  }
  t112_run() {
    printf '{"session_id":"%s","tool_name":"%s","tool_input":%s}\n' "$2" "$3" "$4" \
      | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" > "$T112_OUT" 2> /dev/null
  }

  T112_OUT=$(mktemp)
  T112_BLK=$(mktemp -d)
  T112_CTL=$(mktemp -d)
  t112_tree "$T112_BLK"
  t112_tree "$T112_CTL"
  T112_BLK_LOG="$T112_BLK/.claude/jit-context/.discovery/logs/hooks.log"
  T112_CTL_LOG="$T112_CTL/.claude/jit-context/.discovery/logs/hooks.log"
  T112_BLK_MARK="$T112_BLK/.claude/jit-context/.discovery/state/vocab-shown-s112b$u.txt"
  T112_CTL_MARK="$T112_CTL/.claude/jit-context/.discovery/state/vocab-shown-s112c$u.txt"

  # 1. The blocked call. Both dimensions match it and neither is delivered.
  t112_run "$T112_BLK" "s112b$u" Bash '{"command":"blkcmd src/Billing/x.php"}'
  assert_path_contains "[$eng] control: the block rule still blocks" "$T112_OUT" '"decision":"block"'
  assert_path_contains "[$eng] control: the block reason is its own text" "$T112_OUT" "blkr rule body"
  assert_path_not_contains "[$eng] the vocabulary body is not in the block reason" "$T112_OUT" "billing vocabulary body"
  assert_path_not_contains "[$eng] the advisory rule body is not in the block reason" "$T112_OUT" "advisory rule body"
  assert_path_not_contains "[$eng] the blocked call did not mark the vocabulary entry" "$T112_BLK_MARK" "billing.md"
  assert_path_not_contains "[$eng] the blocked call did not mark the once rule" "$T112_BLK_MARK" "rule:adv.md"
  assert_path_contains "[$eng] the log does not count an undelivered entry as shown" "$T112_BLK_LOG" "[shown:0]"
  assert_path_contains "[$eng] the log names what was withheld instead" "$T112_BLK_LOG" "withheld["

  # 2. Same session, a call the block rule does not match. Both entries are still there.
  t112_run "$T112_BLK" "s112b$u" Bash '{"command":"cat src/Billing/x.php"}'
  assert_path_contains "[$eng] the vocabulary entry survived the blocked call" "$T112_OUT" "billing vocabulary body"
  assert_path_contains "[$eng] the once rule survived the blocked call" "$T112_OUT" "advisory rule body"
  assert_path_contains "[$eng] control: NOW the marker names the vocabulary entry" "$T112_BLK_MARK" "billing.md"
  assert_path_contains "[$eng] control: and the once rule" "$T112_BLK_MARK" "rule:adv.md"

  # 3. The positive control, in a tree of its own: a session with no blocked call injects
  #    on the first call and is silent on the second. Without this pair, everything above
  #    is also true of a hook that injects nothing and marks nothing, ever.
  t112_run "$T112_CTL" "s112c$u" Bash '{"command":"cat src/Billing/x.php"}'
  assert_path_contains "[$eng] control: an unblocked session injects the vocabulary" "$T112_OUT" "billing vocabulary body"
  assert_path_contains "[$eng] control: and the once rule" "$T112_OUT" "advisory rule body"
  assert_path_contains "[$eng] control: the log names the delivered entry" "$T112_CTL_LOG" "00-manual:billing.md(billing)"
  assert_path_not_contains "[$eng] control: nothing is withheld when nothing blocked" "$T112_CTL_LOG" "withheld["
  assert_path_contains "[$eng] control: the marker names it" "$T112_CTL_MARK" "billing.md"

  t112_run "$T112_CTL" "s112c$u" Bash '{"command":"cat src/Billing/x.php"}'
  assert_path_not_contains "[$eng] control: the second identical call is deduped" "$T112_OUT" "billing vocabulary body"
  assert_path_not_contains "[$eng] control: the once rule is deduped too" "$T112_OUT" "advisory rule body"

  rm -rf "$T112_BLK" "$T112_CTL"
  rm -f "$T112_OUT"

  echo "=== [$eng] once does not spend its budget on a refusal (issue #139) ==="
  # `mode: once, block` refused the first matching call of a session and permitted every
  # one after it: the block branch marked the once-key, and the next call skipped the row
  # before it ever reached the decision. An injection is knowledge the agent now has, so
  # repeating it is waste; a refusal is a decision, and a decision that expires was never
  # enforced.
  #
  # Both halves in the same fixture, because each is vacuous alone: the block rule must
  # refuse on calls 1 AND 2, and the plain `once, remind` row beside it must still inject
  # on call 1 and be silent on call 2. Without that second pair, "the block still fires"
  # is equally true of a build where `once` stopped working altogether.
  t139_tree() {
    local d="$1" t v l idx
    idx=00-index.tsv
    t="$d/.claude/jit-context/tools/00-manual"
    v="$d/.claude/jit-context/vocabulary"
    mkdir -p "$t" "$v/00-manual" "$v/10-auto" "$v/20-grouped" "$v/30-crosscutting"
    for l in 00-manual 10-auto 20-grouped 30-crosscutting; do : > "$v/$l/$idx"; done
    printf 'Bash\tpushcmd\tob139.md\tonce,block\t\t\n' > "$t/$idx"
    printf 'Bash\tadvcmd\tadv139.md\tonce,remind\t\t\n' >> "$t/$idx"
    printf 'Bash\treqcmd\trq139.md\tonce,remind\t--safe\t\n' >> "$t/$idx"
    echo "once block rule body" > "$t/ob139.md"
    echo "once advisory rule body" > "$t/adv139.md"
    echo "once require rule body" > "$t/rq139.md"
  }
  T139_OUT=$(mktemp)
  T139=$(mktemp -d)
  t139_tree "$T139"
  T139_MARK="$T139/.claude/jit-context/.discovery/state/vocab-shown-s139$u.txt"
  t139_run() {
    printf '{"session_id":"s139%s","tool_name":"Bash","tool_input":{"command":"%s"}}\n' "$u" "$1" \
      | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$T139" bash "$HOOK" > "$T139_OUT" 2> /dev/null
  }

  t139_run "pushcmd now"
  assert_path_contains "[$eng] control: a once,block rule refuses the first call" "$T139_OUT" '"decision":"block"'
  assert_path_contains "[$eng] and the reason is its own text" "$T139_OUT" "once block rule body"
  t139_run "pushcmd now"
  assert_path_contains "[$eng] the SECOND call of the session is refused too" "$T139_OUT" '"decision":"block"'
  assert_path_contains "[$eng] with the same reason, not an empty one" "$T139_OUT" "once block rule body"
  t139_run "pushcmd now"
  assert_path_contains "[$eng] and the third" "$T139_OUT" '"decision":"block"'
  assert_path_not_contains "[$eng] a refusal spends no once-budget" "$T139_MARK" "rule:ob139.md"

  # A `once` rule carrying `require` is the same shape: the refusal must survive, and the
  # advisory injection beside it must still be once. Call 1 satisfies the requirement and
  # injects; call 2 satisfies it and is silent; call 3 does not, and is refused.
  t139_run "reqcmd --safe"
  assert_path_contains "[$eng] control: a once,require rule injects on call 1" "$T139_OUT" "once require rule body"
  t139_run "reqcmd --safe"
  assert_path_not_contains "[$eng] and is silent on call 2, once still meaning once" "$T139_OUT" "once require rule body"
  t139_run "reqcmd now"
  assert_path_contains "[$eng] but the require refusal still fires after the budget is gone" "$T139_OUT" '"decision":"block"'

  # The positive control for every silence above. If `once` had simply been disabled, the
  # assertions on the require row would still pass and this pair would not.
  t139_run "advcmd now"
  assert_path_contains "[$eng] control: a plain once rule injects on call 1" "$T139_OUT" "once advisory rule body"
  assert_path_contains "[$eng] control: and marks itself shown" "$T139_MARK" "rule:adv139.md"
  t139_run "advcmd now"
  assert_path_not_contains "[$eng] control: and is silent on call 2" "$T139_OUT" "once advisory rule body"

  rm -rf "$T139"
  rm -f "$T139_OUT"

  echo "=== [$eng] a refused-name block row refuses the call (issue #140) ==="
  # jit_bad_entry_file() drops a row whose file column carries a separator -- right, and
  # not in question. What was wrong is what happened next when that row said `block`: the
  # row was skipped before the tool and match columns were ever read, so the call was
  # PERMITTED and the only trace was a once-per-session notice.
  #
  # The entry files below are deliberately NOT created. The row is refused on its name
  # alone, before any read, and a file literally named `back\slash.md` cannot exist on
  # Windows -- where a backslash IS the separator, which is why the guard refuses it.
  t140_tree() {
    local d="$1" t v l idx
    idx=00-index.tsv
    t="$d/.claude/jit-context/tools/00-manual"
    v="$d/.claude/jit-context/vocabulary"
    mkdir -p "$t" "$v/00-manual" "$v/10-auto" "$v/20-grouped" "$v/30-crosscutting"
    for l in 00-manual 10-auto 20-grouped 30-crosscutting; do : > "$v/$l/$idx"; done
    printf 'Bash\tblkbs\tback\\slash.md\tblock\t\t\n' > "$t/$idx"
    printf 'Bash\tadvbs\tother\\name.md\tremind\t\t\n' >> "$t/$idx"
    printf 'Bash\tokcmd\tok140.md\tblock\t\t\n' >> "$t/$idx"
    echo "honest block rule body" > "$t/ok140.md"
  }
  T140_OUT=$(mktemp)
  T140=$(mktemp -d)
  t140_tree "$T140"
  T140_NOTICE='could not be evaluated, so they did NOT run'
  t140_run() {
    printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}\n' "$1" "$2" \
      | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$T140" bash "$HOOK" > "$T140_OUT" 2> /dev/null
  }

  t140_run "s140a$u" "blkbs now"
  assert_path_contains "[$eng] a block row whose name was refused still refuses the call" "$T140_OUT" '"decision":"block"'
  assert_path_contains "[$eng] and says why in place of the body" "$T140_OUT" "was not delivered: not a bare file name"
  assert_path_not_contains "[$eng] without echoing the refused name back" "$T140_OUT" "slash.md"
  t140_run "s140a$u" "blkbs now"
  assert_path_contains "[$eng] the second call of the session is refused too" "$T140_OUT" '"decision":"block"'

  # The other direction, and the one that makes this a rule rather than a blanket refusal:
  # the row is refused on EVERY call, so a command it never matched must still go through.
  t140_run "s140b$u" "echo hello"
  assert_path_not_contains "[$eng] a command the refused row never matched is not blocked" "$T140_OUT" '"decision":"block"'
  assert_path_contains "[$eng] control: it still carries the refusal notice" "$T140_OUT" "$T140_NOTICE"

  # An ADVISORY row with the same bad name keeps the old behaviour exactly: the notice,
  # and nothing else. A fresh session, because that notice is once per session.
  t140_run "s140c$u" "advbs now"
  assert_path_contains "[$eng] an advisory refused row still produces its notice" "$T140_OUT" "$T140_NOTICE"
  assert_path_not_contains "[$eng] and does not refuse the call" "$T140_OUT" '"decision":"block"'
  assert_path_not_contains "[$eng] and injects no substitute body" "$T140_OUT" "was not delivered"

  # Control: an honest block row in the same index still blocks with its own text, so
  # none of the above passes because the fixture stopped working.
  t140_run "s140d$u" "okcmd now"
  assert_path_contains "[$eng] control: an honest block row still blocks" "$T140_OUT" '"decision":"block"'
  assert_path_contains "[$eng] control: with its own body as the reason" "$T140_OUT" "honest block rule body"

  rm -rf "$T140"
  rm -f "$T140_OUT"
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
