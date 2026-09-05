#!/bin/bash
# #186: a subject that was BUILT and then cut to nothing reached no rule at all, and
# said nothing.
#
# pre-tool-hook.sh builds `full_command` from the tool_input keys, then cuts it at the
# first ; & | or double quote to get `cmd` -- the command WORDS. On `; git push` the cut
# takes everything, so `cmd` is empty while `full_command` is not, and the hook printed
# `{}` and exited before the layer loop.
#
# That exit was a SHORT-CIRCUIT on the wrong variable. Three consumers below it read
# something other than `cmd`:
#
#   - the regex arm of the tool matcher matches `full_command`, deliberately, so that
#     `cd x && git push` is testable at all;
#   - the vocabulary pass lifts path tokens out of the WHOLE command, never `cmd`;
#   - the per-row refusal notices need no subject.
#
# Only the substring arm reads `cmd`, and it needs no early exit: index("", term) is 0
# for the non-empty term rebuild-tsv.sh guarantees. So a `mode: block` REGEX rule failed
# open on any command whose first byte is one of the cut bytes -- read as enforced,
# never run.
#
# WHAT THIS SUITE DOES NOT ASSERT, on purpose. A SUBSTRING rule still does not see past
# the cut: a rule about git push does not fire on `; git push`, exactly as it does not
# fire on `true; git push` today. That cut is issue #7 -- it is what stops a substring
# rule about git push firing on an echo of the same words -- and section C pins it as
# kept rather than quietly narrowed.
#
# THE GUARD THIS SUITE NEEDS (tests.md): every must-not-fire assertion sits beside a
# must-fire one in the same section, same tree, same hook. `{}` is what a dead tree, an
# unread layer and a hook that died all produce, and this issue is precisely about not
# being able to tell those apart.
#
# Every index is written by scripts/rebuild-tsv.sh from real frontmatter.
#
# Usage: bash tests/test-cut-to-nothing.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/jit-cut-XXXXXX")" || {
  echo "test-cut-to-nothing: SKIPPED -- could not create a temp directory"
  exit 2
}
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
SID_FILE="$TMPROOT/.sid"
printf '0' > "$SID_FILE"

# jit-drive: assert_contains contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

# jit-drive: assert_missing not_contains capture
assert_missing() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should not contain: $unexpected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (exit $rc)"
  fi
}

# $1 base, $2 layer, $3 name, $4 tool column, $5 match, $6 mode
mk_tool_entry() {
  mkdir -p "$1/tools/$2"
  {
    printf -- '---\n'
    printf 'title: tool rule %s\n' "$3"
    printf 'tool: %s\n' "$4"
    printf 'match: %s\n' "$5"
    printf 'mode: %s\n' "$6"
    printf -- '---\n\n'
    printf 'TOOLBODY-%s\n' "$3"
  } > "$1/tools/$2/$3.md"
}

# $1 base, $2 layer, $3 name, $4 keywords
mk_vocab_entry() {
  mkdir -p "$1/vocabulary/$2"
  {
    printf -- '---\n'
    printf 'title: vocab %s\n' "$3"
    printf 'description: a vocabulary entry named %s\n' "$3"
    printf 'keywords: %s\n' "$4"
    printf -- '---\n\n'
    printf 'VOCABBODY-%s\n' "$3"
  } > "$1/vocabulary/$2/$3.md"
}

rebuild() {
  CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/rebuild-tsv.sh" > /dev/null 2>&1
}

# A fresh session id per call unless one is named -- every notice in this hook is
# once-per-session, so a reused id turns a real assertion into a dedup test.
next_sid() {
  local n
  n=$(($(cat "$SID_FILE") + 1))
  printf '%s' "$n" > "$SID_FILE"
  printf 'sess%03d' "$n"
}

# $1 project, $2 command, ALREADY JSON-escaped by the caller. The commands this suite
# drives start with the bytes the cut looks for, and one of the four IS the double
# quote, so there is no way to write these through a naive quoting helper.
run_bash_raw() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$2" "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2> /dev/null
}

# $1 project. TodoWrite carries no key this hook reads: the #182 no-subject state.
run_todo() {
  printf '{"tool_name":"TodoWrite","tool_input":{"todos":[]},"session_id":"%s"}' "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2> /dev/null
}

# ---------------------------------------------------------------------------
echo "=== A: a ~match rule reaches a command the cut emptied ==="

PROJ="$TMPROOT/a"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual are Bash '~git[[:space:]]+push' remind
mk_tool_entry "$BASE" 00-manual actrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash_raw "$PROJ" "ctrltarget now")
RC=$?
assert_rc0 "A the hook exits 0" "$RC"
assert_contains "A POSITIVE CONTROL: an unrelated rule fires in this tree" "$OUT" "TOOLBODY-actrl"

OUT=$(run_bash_raw "$PROJ" "git push origin main")
assert_contains "A POSITIVE CONTROL: the regex rule fires without the leading semicolon" "$OUT" "TOOLBODY-are"

OUT=$(run_bash_raw "$PROJ" "; git push origin main")
RC=$?
assert_rc0 "A the hook exits 0 on a cut-to-nothing command" "$RC"
assert_contains "A the regex rule fires on a leading-semicolon command (the reproduction)" "$OUT" "TOOLBODY-are"

# The regex arm has always matched the WHOLE command, which is why `cd x && git push`
# works. A leading `;` is the same subject with one byte in front of it.
OUT=$(run_bash_raw "$PROJ" "cd /tmp && git push origin main")
assert_contains "A POSITIVE CONTROL: and still fires after a chain operator" "$OUT" "TOOLBODY-are"

# ---------------------------------------------------------------------------
echo ""
echo "=== B: a mode:block ~match rule no longer fails open ==="

# The tools dimension is the only one that can refuse a call. A block rule that reads as
# enforced and is not is the worst outcome this repository names.
PROJ="$TMPROOT/b"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual bblock Bash '~git[[:space:]]+push' block
mk_tool_entry "$BASE" 00-manual bctrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash_raw "$PROJ" "ctrltarget now")
assert_contains "B POSITIVE CONTROL: an unrelated rule fires in this tree" "$OUT" "TOOLBODY-bctrl"

OUT=$(run_bash_raw "$PROJ" "git push origin main")
assert_contains "B POSITIVE CONTROL: the block rule refuses the uncut command" "$OUT" '"decision":"block"'

OUT=$(run_bash_raw "$PROJ" "; git push origin main")
RC=$?
assert_rc0 "B the hook still exits 0 when it blocks" "$RC"
assert_contains "B the block rule refuses a leading-semicolon command" "$OUT" '"decision":"block"'
assert_contains "B and the refusal carries the rule body" "$OUT" "TOOLBODY-bblock"

# NEGATIVE CONTROL, and it is the one that keeps B from being a test that passes because
# everything is blocked: a cut-to-nothing command the rule does not describe goes through.
OUT=$(run_bash_raw "$PROJ" "; ls -la")
assert_missing "B NEGATIVE CONTROL: a cut-to-nothing command the rule does not match is not blocked" "$OUT" '"decision":"block"'

# ---------------------------------------------------------------------------
echo ""
echo "=== C: the #7 cut is KEPT -- a substring rule still does not see past it ==="

# Not a limitation this fix is allowed to quietly remove. Cutting at the first ; & | or
# quote is what stops a substring rule about git push firing on an echo of those words,
# and `; git push` is the degenerate case of `true; git push`, which is silent today and
# stays silent.
PROJ="$TMPROOT/c"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual csub Bash 'git push' remind
mk_tool_entry "$BASE" 00-manual cctrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash_raw "$PROJ" "git push origin main")
assert_contains "C POSITIVE CONTROL: the substring rule fires on the uncut command" "$OUT" "TOOLBODY-csub"

# {"command":"echo \"git push\""} -- the #7 shape, JSON-escaped.
OUT=$(run_bash_raw "$PROJ" 'echo \"git push\"')
assert_missing "C the #7 shape stays unmatched: an echo of the same words" "$OUT" "TOOLBODY-csub"

OUT=$(run_bash_raw "$PROJ" "true; git push origin main")
assert_missing "C a substring rule does not see past a chain operator (unchanged)" "$OUT" "TOOLBODY-csub"

OUT=$(run_bash_raw "$PROJ" "; git push origin main")
RC=$?
assert_rc0 "C the hook exits 0" "$RC"
assert_missing "C nor past a LEADING one -- the same cut, not a new hole" "$OUT" "TOOLBODY-csub"

# ---------------------------------------------------------------------------
echo ""
echo "=== D: every byte the cut looks for, not just the semicolon ==="

PROJ="$TMPROOT/d"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual dre Bash '~cutmarker' remind
mk_tool_entry "$BASE" 00-manual dctrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash_raw "$PROJ" "ctrltarget now")
assert_contains "D POSITIVE CONTROL: an unrelated rule fires in this tree" "$OUT" "TOOLBODY-dctrl"
OUT=$(run_bash_raw "$PROJ" "cutmarker plain")
assert_contains "D POSITIVE CONTROL: the regex rule fires on an uncut command" "$OUT" "TOOLBODY-dre"

OUT=$(run_bash_raw "$PROJ" "; cutmarker after a semicolon")
assert_contains "D a leading semicolon no longer hides the command" "$OUT" "TOOLBODY-dre"
OUT=$(run_bash_raw "$PROJ" "& cutmarker after an ampersand")
assert_contains "D a leading ampersand no longer hides the command" "$OUT" "TOOLBODY-dre"
OUT=$(run_bash_raw "$PROJ" "| cutmarker after a pipe")
assert_contains "D a leading pipe no longer hides the command" "$OUT" "TOOLBODY-dre"
# {"command":"\"cutmarker in quotes\""} -- the cut byte that is not a chain operator.
OUT=$(run_bash_raw "$PROJ" '\"cutmarker in quotes\"')
assert_contains "D a leading double quote no longer hides the command" "$OUT" "TOOLBODY-dre"
# ` --flag` is the fourth strip, and it empties cmd when it is the first thing there.
OUT=$(run_bash_raw "$PROJ" " --cutmarker-flag only")
assert_contains "D a command that is nothing but a flag no longer hides it" "$OUT" "TOOLBODY-dre"

# ---------------------------------------------------------------------------
echo ""
echo "=== E: the #182 census is NOT widened -- these are different states ==="

# A subject that was built and then cut is not a subject that could not be built. #184
# reported the second; reporting the first would tell an author that every Bash rule in
# their tree is unreachable on a call that carried a command the whole time.
PROJ="$TMPROOT/e"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual etodo TodoWrite 'anything' remind
mk_tool_entry "$BASE" 00-manual ectrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_todo "$PROJ")
assert_contains "E POSITIVE CONTROL: a genuinely subject-less dispatch is still reported" "$OUT" "could build no subject"

OUT=$(run_bash_raw "$PROJ" "; cat /etc/hosts")
RC=$?
assert_rc0 "E the hook exits 0 on a cut-to-nothing command" "$RC"
assert_missing "E a cut-to-nothing command does NOT claim the Bash rules are unreachable" "$OUT" "could build no subject"

# And with no rule matching it, the answer is still exactly {} -- the cost of this fix on
# the overwhelmingly common call is zero.
PROJ="$TMPROOT/e2"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual e2ctrl Bash 'ctrltarget' remind
rebuild "$PROJ"
OUT=$(run_bash_raw "$PROJ" "ctrltarget now")
assert_contains "E POSITIVE CONTROL: the rule fires in the second tree" "$OUT" "TOOLBODY-e2ctrl"
OUT=$(run_bash_raw "$PROJ" "; cat /etc/hosts")
if [ "$OUT" = "{}" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: E a cut-to-nothing command matching no rule is still {}"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: E a cut-to-nothing command matching no rule is still {}"
  echo "    got: ${OUT:-<EMPTY>}"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== F: the vocabulary pass binds on the path it was always reading ==="

# tt is built from `command` -- the WHOLE command -- never from `cmd`. It was the early
# exit alone that skipped this pass, so `; cat src/Billingz/x.php` said nothing while
# `true; cat src/Billingz/x.php` bound Billingz the whole time.
#
# "billingz", not "billing" (#251): a plain "billing" is an ordinary English word, and
# once data/generic-words.txt carries a real SCOWL export, an exact-match keyword like
# that is classified generic -- which downgrades this fixture's own entry to
# title+description and drops VOCABBODY-fbilling from the injection, failing this
# section for a reason that has nothing to do with what it tests. A keyword no
# dictionary carries keeps this section a test of the cut-to-nothing fix, not of the
# generic-word list's current contents.
PROJ="$TMPROOT/f"
BASE="$PROJ/.claude/jit-context"
mk_vocab_entry "$BASE" 00-manual fbilling 'billingz'
mk_tool_entry "$BASE" 00-manual fctrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash_raw "$PROJ" "ctrltarget now")
assert_contains "F POSITIVE CONTROL: a tool rule fires in this tree" "$OUT" "TOOLBODY-fctrl"
OUT=$(run_bash_raw "$PROJ" "cat src/Billingz/x.php")
assert_contains "F POSITIVE CONTROL: the vocab entry binds on an uncut command" "$OUT" "VOCABBODY-fbilling"
OUT=$(run_bash_raw "$PROJ" "true; cat src/Billingz/x.php")
assert_contains "F POSITIVE CONTROL: and after a chain operator (always did)" "$OUT" "VOCABBODY-fbilling"

OUT=$(run_bash_raw "$PROJ" "; cat src/Billingz/x.php")
RC=$?
assert_rc0 "F the hook exits 0" "$RC"
assert_contains "F and now on a cut-to-nothing command too" "$OUT" "VOCABBODY-fbilling"

# NEGATIVE CONTROL: a cut-to-nothing command naming no path binds nothing. Without it,
# F would pass on a hook that injected every vocabulary entry unconditionally.
OUT=$(run_bash_raw "$PROJ" "; echo hello")
assert_missing "F NEGATIVE CONTROL: a cut-to-nothing command naming no path binds nothing" "$OUT" "VOCABBODY-fbilling"

# ---------------------------------------------------------------------------
echo ""
echo "test-cut-to-nothing: PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
