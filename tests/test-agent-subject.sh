#!/bin/bash
# #182: a tools-dimension rule with `tool: Agent` could never fire.
#
# pre-tool-hook.sh builds the subject it matches tool rules against out of four
# tool_input keys -- command, skill, file_path, pattern. An Agent dispatch carries
# none of them (its input is description, prompt, subagent_type), so `cmd` was empty
# and the hook printed `{}` and exited 59 lines before the layer loop that would have
# consulted any rule at all. The rule was written, validated, indexed, counted by every
# diagnostic -- and inert.
#
# TWO defects, and the second is the class:
#
#   1. Agent had no subject key. Fixed by reading `subagent_type` -- and ONLY
#      `subagent_type`. Section B is the negative half of that decision: a token that
#      appears only in `prompt` or `description` must NOT reach a rule, because those
#      are author-written prose that routinely quotes commands, and `cmd` is truncated
#      at the first ; & | or quote, so a prose subject is matched as an arbitrary prefix
#      (the #7 false-block shape).
#
#   2. EVERY tool whose input carries none of those keys is in the same position, and
#      the set is open -- TodoWrite, WebFetch, WebSearch, ExitPlanMode, and every MCP
#      tool, whose input schema this project cannot know. So the fix is not a list of
#      tool names anywhere: it is the third state at fire time. When a real dispatch
#      arrives, no subject can be built, and rules in the tree name that tool, the hook
#      SAYS SO once per session instead of exiting silently. Section D drives that.
#
# THE GUARD THIS SUITE NEEDS (tests.md): every "must not fire" assertion here sits in a
# fixture whose sibling "must fire" assertion is checked in the same section, under the
# same tree and the same hook. Without it, `{}` is indistinguishable from a rule that
# matched nothing, a layer that was not read, or a hook that died -- which is the exact
# ambiguity #182 is about, and it would be embarrassing to reproduce it in its own test.
#
# Every index here is written by scripts/rebuild-tsv.sh from real frontmatter, never by
# hand: half of what made this invisible is that the rebuild has always indexed a
# `tool: Agent` row happily.
#
# Usage: bash tests/test-agent-subject.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/jit-agent-XXXXXX")" || {
  echo "test-agent-subject: SKIPPED -- could not create a temp directory"
  exit 2
}
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
SID_FILE="$TMPROOT/.sid"
printf '0' > "$SID_FILE"
TAB="$(printf '\t')"

# jit-drive: assert_contains contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

# jit-drive: assert_missing not_contains capture
assert_missing() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should not contain: $unexpected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
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

rebuild() {
  CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/rebuild-tsv.sh" >/dev/null 2>&1
}

# A fresh session id per call unless one is named. Every notice in this hook is
# once-per-session, so reusing an id silently turns a real assertion into a dedup test --
# see the same trap, and the same file-not-variable counter, in
# tests/test-layer-enumeration.sh.
next_sid() {
  local n
  n=$(( $(cat "$SID_FILE") + 1 ))
  printf '%s' "$n" > "$SID_FILE"
  printf 'sess%03d' "$n"
}

# $1 project, $2 subagent_type, $3 prompt, $4 optional session id, $5 optional description
run_agent() {
  printf '{"tool_name":"Agent","tool_input":{"description":"%s","prompt":"%s","subagent_type":"%s"},"session_id":"%s"}' \
    "${5:-a description}" "$3" "$2" "${4:-$(next_sid)}" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null
}

# $1 project, $2 command
run_bash() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$2" "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null
}

# $1 project, $2 optional session id. TodoWrite carries no key this hook reads -- it is
# the stand-in for the open class, not a special case.
run_todo() {
  printf '{"tool_name":"TodoWrite","tool_input":{"todos":[]},"session_id":"%s"}' "${2:-$(next_sid)}" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "=== A: a tool: Agent rule fires at all ==="

PROJ="$TMPROOT/a"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual aexplore Agent 'explore'    remind
mk_tool_entry "$BASE" 00-manual actrl    Bash  'ctrltarget' remind
rebuild "$PROJ"

# The asymmetry that hid this: the rebuild has always indexed the Agent row.
if grep -q "^Agent$TAB" "$BASE/tools/00-manual/00-index.tsv"; then
  PASS=$((PASS + 1)); echo "  PASS: A rebuild-tsv.sh indexed the tool: Agent row"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: A no Agent row in the index -- the fixture is wrong, not the hook"
fi

OUT=$(run_bash "$PROJ" "ctrltarget now"); RC=$?
assert_rc0      "A the tool hook exits 0" "$RC"
assert_contains "A POSITIVE CONTROL: the Bash rule fires in this tree" "$OUT" "TOOLBODY-actrl"

OUT=$(run_agent "$PROJ" "explore" "go and look at the billing code"); RC=$?
assert_rc0      "A the tool hook exits 0 on an Agent dispatch" "$RC"
assert_contains "A the tool: Agent rule fires on subagent_type" "$OUT" "TOOLBODY-aexplore"

# A regex rule, and the broadest one there is -- the issue reproduction verbatim.
mk_tool_entry "$BASE" 00-manual aany Agent '~.*' remind
rebuild "$PROJ"
OUT=$(run_agent "$PROJ" "oss:developer" "implement issue 182")
assert_contains "A a match: ~.* Agent rule fires (the issue reproduction)" "$OUT" "TOOLBODY-aany"

# ---------------------------------------------------------------------------
echo ""
echo "=== B: the subject is subagent_type, NOT prompt and NOT description ==="

# The decision this fix makes, asserted on its negative side. `prompt` is author-written
# prose that routinely quotes shell commands, and `cmd` is cut at the first ; & | or
# quote -- so matching rules against it would fire deny-list rules on a description of a
# command and would compare substring rules against an arbitrary prefix.
#
# BOTH controls are in this fixture and both run below, so "did not fire" here can only
# mean the subject excluded the prompt: the same tree, the same hook and the same call
# shape produce a fire in the very next assertion.
PROJ="$TMPROOT/b"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual bsubj   Agent 'reviewer'      remind
mk_tool_entry "$BASE" 00-manual bprompt Agent 'promptonlytok' remind
mk_tool_entry "$BASE" 00-manual bdesc   Agent 'desconlytok'   remind
rebuild "$PROJ"

OUT=$(run_agent "$PROJ" "reviewer" "please check promptonlytok carefully" "" "a desconlytok task")
assert_contains "B POSITIVE CONTROL: the subagent_type rule fires on this very call" "$OUT" "TOOLBODY-bsubj"
assert_missing  "B a rule matching a token only in prompt does NOT fire"             "$OUT" "TOOLBODY-bprompt"
assert_missing  "B a rule matching a token only in description does NOT fire"        "$OUT" "TOOLBODY-bdesc"

# ---------------------------------------------------------------------------
echo ""
echo "=== C: an Agent rule can BLOCK ==="

# The tools dimension is the only one that can refuse a call, so an inert rule here
# fails OPEN. That is the half worth pinning.
PROJ="$TMPROOT/c"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual cblock Agent 'general-purpose' block
mk_tool_entry "$BASE" 00-manual cctrl  Bash  'ctrltarget'      remind
rebuild "$PROJ"

OUT=$(run_bash "$PROJ" "ctrltarget now")
assert_contains "C POSITIVE CONTROL: the Bash rule fires in this tree" "$OUT" "TOOLBODY-cctrl"

OUT=$(run_agent "$PROJ" "general-purpose" "do something"); RC=$?
assert_rc0      "C the hook still exits 0 when it blocks" "$RC"
assert_contains "C a mode:block Agent rule refuses the dispatch" "$OUT" '"decision":"block"'
assert_contains "C and the refusal carries the rule body"       "$OUT" "TOOLBODY-cblock"

OUT=$(run_agent "$PROJ" "Explore" "do something")
assert_missing  "C NEGATIVE CONTROL: a different subagent_type is not blocked" "$OUT" '"decision":"block"'

# ---------------------------------------------------------------------------
echo ""
echo "=== D: the third state -- a rule for a tool with no subject is NAMED ==="

# The class, not the instance. TodoWrite carries none of the keys this hook reads and
# nothing in this repo can enumerate the tools that do -- an MCP server defines its own
# input schema. So the report is driven by EVIDENCE at fire time (a real dispatch
# arrived, no subject could be built, rules in the tree name that tool) rather than by a
# list of tool names that would go stale exactly the way the layer list in #176 did.
PROJ="$TMPROOT/d"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual dtodo TodoWrite 'anything'   remind
mk_tool_entry "$BASE" 00-manual dctrl Bash      'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash "$PROJ" "ctrltarget now")
assert_contains "D POSITIVE CONTROL: the Bash rule fires in this tree" "$OUT" "TOOLBODY-dctrl"

OUT=$(run_todo "$PROJ"); RC=$?
assert_rc0      "D the hook exits 0 on a subject-less dispatch" "$RC"
assert_contains "D the unreachable rule is reported, not silent" "$OUT" "could build no subject"
assert_contains "D and it is named by POSITION, as every other refusal notice is" "$OUT" "tools/00-manual row"
# By position and never by the file-name column, which is untrusted free text (#35).
assert_missing  "D the entry file name is not echoed into the notice" "$OUT" "dtodo.md"

# Once per session, like every sibling notice.
SID="$(next_sid)"
OUT=$(run_todo "$PROJ" "$SID")
assert_contains "D POSITIVE CONTROL: the notice arrives on the first call of a session" "$OUT" "could build no subject"
OUT=$(run_todo "$PROJ" "$SID")
assert_missing  "D and does not repeat on the second call of the same session" "$OUT" "could build no subject"

# ---------------------------------------------------------------------------
echo ""
echo "=== E: no rule names the tool -- still silent, no new noise ==="

# The cost of D must be zero for the overwhelmingly common case. A tree whose rules name
# only Bash must answer a TodoWrite exactly as it did before this change.
PROJ="$TMPROOT/e"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual ectrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash "$PROJ" "ctrltarget now")
assert_contains "E POSITIVE CONTROL: the Bash rule fires in this tree" "$OUT" "TOOLBODY-ectrl"

OUT=$(run_todo "$PROJ"); RC=$?
assert_rc0      "E the hook exits 0" "$RC"
if [ "$OUT" = "{}" ]; then
  PASS=$((PASS + 1)); echo "  PASS: E a subject-less dispatch with no rule naming it is still {}"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: E a subject-less dispatch with no rule naming it is still {}"
  echo "    got: ${OUT:-<EMPTY>}"
fi

# And an Agent dispatch that carries NO subagent_type at all is subject-less too --
# the same third state, not a silent pass.
PROJ="$TMPROOT/e2"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual e2agent Agent 'explore'    remind
mk_tool_entry "$BASE" 00-manual e2ctrl  Bash  'ctrltarget' remind
rebuild "$PROJ"
OUT=$(run_bash "$PROJ" "ctrltarget now")
assert_contains "E POSITIVE CONTROL: the Bash rule fires in the second tree" "$OUT" "TOOLBODY-e2ctrl"
OUT=$(printf '{"tool_name":"Agent","tool_input":{"prompt":"no type given"},"session_id":"%s"}' "$(next_sid)" \
  | CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null)
assert_contains "E an Agent dispatch with no subagent_type is reported, not silent" "$OUT" "could build no subject"

# ---------------------------------------------------------------------------
echo ""
echo "=== F: the log line records it, and records it as NOT delivered ==="

PROJ="$TMPROOT/f"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual ftodo TodoWrite 'anything'   remind
mk_tool_entry "$BASE" 00-manual fctrl Bash      'ctrltarget' remind
rebuild "$PROJ"
LOG="$BASE/.discovery/logs/hooks.log"
rm -f "$LOG"
run_bash "$PROJ" "ctrltarget now" >/dev/null
run_todo "$PROJ" >/dev/null
LOGTXT="$(cat "$LOG" 2>/dev/null)"
assert_contains "F POSITIVE CONTROL: the delivered Bash rule is in the log" "$LOGTXT" "fctrl.md"
assert_contains "F the unreachable rule is in the log too"                  "$LOGTXT" "nosubject:"
assert_missing  "F and it is not logged as a delivery"                      "$LOGTXT" "ftodo.md("

# ---------------------------------------------------------------------------
echo ""
echo "=== G: the census is bounded, and says so, and cannot be cut by the OTHER list ==="

# jit_refuse_add() caps its list at 4096 bytes, adds a "the remaining rows are not listed
# here" line and leaves the COUNT uncapped -- a notice that quietly stopped at N would
# state a false total, which is what that whole mechanism exists to avoid. The census
# needs the same bound.
#
# It must not share the flag, and that is the half worth a fixture. jit_refuse_cut is
# program-scope so that whichever of the refusal sites overflows first adds the cut line
# once. Two DIFFERENT lists sharing it is not the same thing: the second list to overflow
# would drop every later row silently, with no cut line, under a count that still named
# the whole total. G2 builds a tree where both lists overflow on one call.
PROJ="$TMPROOT/g"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual gctrl Bash 'ctrltarget' remind
i=1
while [ "$i" -le 200 ]; do
  mk_tool_entry "$BASE" 00-manual "gtodo$i" TodoWrite "tok$i" remind
  i=$((i + 1))
done
rebuild "$PROJ"

OUT=$(run_bash "$PROJ" "ctrltarget now")
assert_contains "G POSITIVE CONTROL: the Bash rule fires in this tree" "$OUT" "TOOLBODY-gctrl"

OUT=$(run_todo "$PROJ")
assert_contains "G1 the census counts every unreachable row, not the ones it printed" "$OUT" "200 tools rule(s) name this tool"
assert_contains "G1 and says the list was cut rather than stopping quietly" "$OUT" "the remaining unreachable rows are not listed here"

# G2: both lists overflow on the same call. The 200 rows appended here are refused by
# jit_bad_entry_file (a separator in the file column) BEFORE the tool test, so they land
# in `refused` whatever tool is dispatched, while the 200 rebuilt rows above land in the
# census. Written after the rebuild, because rebuild-tsv.sh cannot produce such a column.
IDX="$BASE/tools/00-manual/00-index.tsv"
i=1
while [ "$i" -le 200 ]; do
  printf 'Bash\tzzz%s\t../evil%s.md\tremind\t\t\n' "$i" "$i" >> "$IDX"
  i=$((i + 1))
done

OUT=$(run_todo "$PROJ")
assert_contains "G2 the refused list is still reported"          "$OUT" "200 rule(s) could not be evaluated"
assert_contains "G2 and carries its own cut line"                "$OUT" "the remaining refused rows are not listed here"
assert_contains "G2 the census is still reported beside it"      "$OUT" "200 tools rule(s) name this tool"
assert_contains "G2 and carries its own cut line, not the other" "$OUT" "the remaining unreachable rows are not listed here"

# ---------------------------------------------------------------------------
echo ""
echo "=== H: a subject that was BUILT and then cut to nothing is not the same state ==="

# The census must fire on "no tool_input key yielded anything", never on "a key yielded
# something and the command-words cut reduced it to empty". Those are two states and the
# notice makes a factual claim about which one it is -- it says the dispatch carried none
# of the keys it reads.
#
# `cmd` is cut at the first ; & | or double quote, so a Bash command that is a lone quote,
# or that opens with a chain operator, leaves `cmd` empty with `command` present the whole
# time. Gating the census on `cmd` rather than on the whole subject made it report every
# Bash rule in the tree as unreachable, on a call that carried a command -- a false
# statement, and the loudest possible one, since it names rules that are fine.
#
# It is also the guard on the rest of the diff: this call must behave EXACTLY as it did
# before #182, which means silent. The positive control below proves the tree and the
# hook are live on the same fixture.
PROJ="$TMPROOT/h"; BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual hctrl Bash 'ctrltarget' remind
rebuild "$PROJ"

OUT=$(run_bash "$PROJ" "ctrltarget now")
assert_contains "H POSITIVE CONTROL: the Bash rule fires in this tree" "$OUT" "TOOLBODY-hctrl"

h_run() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$1" "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPTS/pre-tool-hook.sh" 2>/dev/null
}

# A lone double quote: the quote cut takes everything, `command` is present throughout.
OUT=$(h_run '\"'); RC=$?
assert_rc0     "H the hook exits 0 on a command that cuts to nothing" "$RC"
assert_missing "H a command that cut to nothing is NOT reported as carrying no key" "$OUT" "could build no subject"
if [ "$OUT" = "{}" ]; then
  PASS=$((PASS + 1)); echo "  PASS: H and the call is silent, exactly as it was before #182"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: H and the call is silent, exactly as it was before #182"
  echo "    got: ${OUT:-<EMPTY>}"
fi

# Leading chain operator: same shape, different cut.
OUT=$(h_run '; cat /tmp/x')
assert_missing "H a command cut at a leading ; is not reported as carrying no key" "$OUT" "could build no subject"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
