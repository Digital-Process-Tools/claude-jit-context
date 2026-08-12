#!/bin/bash
# Tests for pre-path-hook.sh (TSV-based, supertool-aware)
# Usage: bash tests/test-pre-path-hook.sh
#
# NOTE: the shown-file deduplication is not exercised here, and no longer by accident.
# It used to key on $PPID, which under `$( )` is the command-substitution subshell -- a
# recycled pid brought a stale marker with it and suppressed an assertion at random
# (#17, #23). The key is the payload session_id now, and the payloads below carry none,
# so this hook keeps no marker file at all and every call here starts clean.
# tests/test-session-markers.sh drives dedup itself, in both directions.

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
  if grep -q "$expected" <<<"$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:200}"
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
echo "=== multi-line command naming a file that is not there stays silent ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cd repo\ncat src/Billing/Absent.class.php"}}')
assert_empty "no rule fires for a path that does not exist" "$OUT"

# =============================================
# SECTION 3: Bash commands that are not supertool calls (issue #85)
# =============================================
# The path dimension used to collect nothing from a Bash payload unless the command
# matched a supertool invocation, so `vim src/x.php` reached NO path rule while a Read of
# the same file reached every one of them. A token is a path candidate now, and the gate
# that makes guessing safe is that it names an EXISTING REGULAR FILE inside the project.
#
# Over-firing is not a defect here and is not asserted against: `grep foo src/x.php`
# firing the php rule is correct -- the rule is about that file and the agent is about to
# read it. No verb is inspected.
#
# EVERY silence assertion below is paired with a positive control built from the same
# fixture, differing only in the property under test. A negative assertion passes when the
# harness is broken, which is how three of these would otherwise have shipped green.

REALDIR="$TEST_DIR/src/Billing"
mkdir -p "$REALDIR/Components"
: > "$REALDIR/Module.class.php"
: > "$REALDIR/Components/ProjectForm.class.php"
# A tree OUTSIDE the project holding a file whose NAME matches a path rule. Every
# containment case below aims at this file: reached by traversal, by absolute path, or
# through a link. If any of them injected, the rule fired for a file the project does not
# contain.
OUTSIDE=$(mktemp -d)
OUTSIDE_NAME=$(basename "$OUTSIDE")
: > "$OUTSIDE/Module.class.php"

echo ""
echo "=== Bash: a relative path that exists ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat src/Billing/Module.class.php"}}')
assert_contains "cat of an existing php file fires php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Bash: an editor, an absolute path inside the project ==="
OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vim $TEST_DIR/src/Billing/Module.class.php\"}}")
assert_contains "absolute path inside the project fires php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Bash: several rules from one command ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ src/Billing/Components/ProjectForm.class.php"}}')
assert_contains "sed -i fires the component rule" "$OUT" "component pattern"
assert_contains "sed -i fires php-coding too" "$OUT" "php coding rules"

echo ""
echo "=== Bash: a quoted token ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat '\''src/Billing/Module.class.php'\''"}}')
assert_contains "a single-quoted path fires php-coding" "$OUT" "php coding rules"

echo ""
echo "=== Bash: a supertool call still works ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"./supertool '\''read:src/Billing/Module.class.php'\''"}}')
assert_contains "the supertool extractor still fires" "$OUT" "php coding rules"

echo ""
echo "=== Bash: a path that does not exist (the existence gate) ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat src/Billing/Absent.class.php"}}')
assert_empty "a token naming no file on disk is not a candidate" "$OUT"

echo ""
echo "=== Bash: no path tokens at all ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git status"}}')
assert_empty "git status returns empty" "$OUT"

# A DIRECTORY token decides where the existence check can live. macOS ships one-true-awk,
# which raises a FATAL i/o error from getline on a directory -- stderr into the stranger
# session, exit 2 -- so the check is `[ -f ] || [ -d ]` in bash and never a probe in awk.
# The rule firing is what makes the stderr half non-vacuous: a hook that collected nothing
# would trivially have opened no directory.
echo ""
echo "=== Bash: a directory token fires, and quietly ==="
ERRFILE=$(mktemp)
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"grep -r getAmount src/Billing/Components"}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2>"$ERRFILE")
RC=$?
assert_contains "a directory candidate fires the component rule" "$OUT" "component pattern"
if [ ! -s "$ERRFILE" ] && [ "$RC" = 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: a directory token writes nothing to stderr and exits 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: a directory token wrote to stderr or exited non-zero"
  echo "    rc=$RC stderr: $(head -c 200 "$ERRFILE")"
fi
rm -f "$ERRFILE"

# --- Containment. Each of the four aims at $OUTSIDE/Module.class.php, which EXISTS and
# whose name matches the php rule -- so the only thing keeping each one silent is the
# confinement rule under test. The positive control is the first case in this section.
echo ""
echo "=== Bash: .. traversal out of the project ==="
OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat ../$OUTSIDE_NAME/Module.class.php\"}}")
assert_empty "a traversal candidate is refused" "$OUT"

echo ""
echo "=== Bash: .. traversal that lands back inside ==="
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat src/../src/Billing/Module.class.php"}}')
assert_empty "a .. component is refused even when it resolves inside" "$OUT"

echo ""
echo "=== Bash: an absolute path outside the project ==="
OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $OUTSIDE/Module.class.php\"}}")
assert_empty "an absolute path outside the project is refused" "$OUT"

echo ""
echo "=== Bash: a symbolic link inside the project pointing out of it ==="
ln -s "$OUTSIDE/Module.class.php" "$TEST_DIR/Escape.class.php"
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat Escape.class.php"}}')
assert_empty "a linked candidate is refused" "$OUT"

echo ""
echo "=== Bash: a linked DIRECTORY on the way to the candidate ==="
ln -s "$OUTSIDE" "$TEST_DIR/escape"
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat escape/Module.class.php"}}')
assert_empty "a link anywhere on the path is refused" "$OUT"

# The link named AS the directory, which is the one shape the leaf test cannot answer:
# `[ -L x/ ]` follows the link and is false for a link to a directory, so it is the
# component walk that has to catch this. The name matches a rule, so a hook that admitted
# it would inject; the case above it, on a real directory of the same name, does.
echo ""
echo "=== Bash: a linked directory whose own NAME matches a rule ==="
ln -s "$OUTSIDE" "$TEST_DIR/Components"
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la Components/"}}')
assert_empty "a linked directory named after a rule is refused" "$OUT"
OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la src/Billing/Components"}}')
assert_contains "control: the real directory of that name fires" "$OUT" "component pattern"

# A FIFO opens for reading and BLOCKS until someone writes, so a candidate that is one
# would stall the hook for the whole hook timeout. `[ -f ]` is false for a fifo, which is
# why the gate is -f and not -e. Skipped where mkfifo is unavailable (Git Bash).
echo ""
echo "=== Bash: a fifo candidate neither fires nor blocks ==="
if mkfifo "$TEST_DIR/Pipe.class.php" 2>/dev/null; then
  OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"cat Pipe.class.php"}}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" perl -e 'alarm 15; exec("bash", $ARGV[0]) or exit 1' "$HOOK" 2>/dev/null) || true
  assert_empty "a fifo is not a path candidate" "$OUT"
  rm -f "$TEST_DIR/Pipe.class.php"
else
  echo "  SKIP: mkfifo unavailable on this platform"
fi

# The constraint at pre-path-hook.sh: a Write payload body must NEVER be reassembled into
# path candidates. It cannot be, because candidates are only collected when the payload
# carries no file_path -- and the control below proves the fixture would have fired.
echo ""
echo "=== Write: a path named in the BODY is not a candidate ==="
OUT=$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/project/notes.txt","content":"see src/Billing/Module.class.php for the rules"}}')
if grep -q "php coding rules" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a Write body was reassembled into a path candidate"
else
  PASS=$((PASS + 1)); echo "  PASS: a Write body is not a path candidate"
fi
OUT=$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/project/src/Billing/Module.class.php","content":"body"}}')
assert_contains "control: the same Write with a php file_path does fire" "$OUT" "php coding rules"

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
    echo "    raw control byte in: $(LC_ALL=C perl -0777 -pe 's/([\x00-\x1f])/sprintf("<%02X>",ord($1))/ge; $_ = substr($_, 0, 200)' "$out")"
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

# --- Issue #68: a malformed UTF-8 byte must not silence the hook ---------------------
# Filed against pre-prompt-hook.sh and reached here too: a lone 0xE9 in a file path made
# one-true-awk abort the END block, so the hook printed NOTHING -- not even `{}` -- wrote
# `illegal byte sequence` into the session and exited 0. gawk did not abort but printed a
# multibyte warning to the same place. A path carrying a Latin-1 byte is not exotic: a
# checkout made on a machine with a different filesystem encoding produces one.
#
# Both legs are needed and neither carries the other: "no error appeared" is true of a
# hook that never ran, which is the failure being fixed.
#
# The locale is the caller's and it matters: `C` is where the bug does not reproduce.
pick_utf8_locale() {
  local c
  for c in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if [ "$(LC_ALL="$c" locale charmap 2>/dev/null)" = "UTF-8" ]; then
      printf '%s' "$c"; return 0
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
if [ "$(LC_ALL="$UTF8_LOCALE" locale charmap 2>/dev/null)" = "UTF-8" ]; then UTF8_LOCALE_REAL=yes; fi
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
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2>/dev/null
}

assert_survives_malformed() {
  local desc="$1" eng="$2" payload="$3" needle="$4" out err
  out=$(mktemp); err=$(mktemp)
  printf '%s\n' "$payload" | LC_ALL="$UTF8_LOCALE" PATH="$ENGINE_BIN/$eng:$PATH" \
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" > "$out" 2> "$err"
  if LC_ALL=C grep -qF "$needle" "$out"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc -- the rule still fired"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc -- the rule did NOT fire"
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
  # Four rules per engine, each fired exactly once. This hook marks a rule file shown on
  # every fire, and within ONE call that mark still applies -- so the assertions below own
  # their fixtures rather than sharing two. The cross-call half of that reasoning is gone
  # with the $PPID key (#17, #23): these payloads name no session, so nothing persists.
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

  echo "=== [$eng] a malformed UTF-8 byte does not silence the hook (issue #68) ==="
  printf 'MojiP%s/\tmoji-%s.md\n' "$eng" "$eng" >> "$PATHS_DIR/00-manual/00-index.tsv"
  echo "mojibake path body" > "$PATHS_DIR/00-manual/moji-$eng.md"
  # The control first, in the same fixture: without it a green below could mean the rule
  # was unreachable for a reason that has nothing to do with the bad byte.
  OUT=$(run_hook_engine_utf8 "$eng" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/MojiP$eng/x.txt\"}}")
  assert_contains "[$eng] control: the rule matches with no bad byte" "$OUT" "mojibake path body"
  # This hook marks a rule shown on every fire, but these payloads name no session, so
  # nothing carries between calls and the same rule may fire again below.
  assert_survives_malformed "[$eng] a bad byte elsewhere in the path does not lose the rule" "$eng" \
    "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/MojiP$eng/${BADBYTE}x.txt\"}}" \
    "mojibake path body"
  # Both directions, and assert_empty rather than a not-contains: "the rule did not fire"
  # is also true of a hook that printed nothing at all, which is the defect being fixed.
  OUT=$(run_hook_engine_utf8 "$eng" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/src/MojiQ$eng/${BADBYTE}x.txt\"}}")
  assert_empty "[$eng] and a bad byte does not make an unnamed path match" "$OUT"
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
