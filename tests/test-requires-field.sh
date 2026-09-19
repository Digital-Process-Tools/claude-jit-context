#!/bin/bash
# Tests for the requires: frontmatter field (#203) -- a tools rule that names a binary
# its OWN remedy depends on. `mode: block` unconditionally, with no way to say "and if
# the binary is not installed", is the shape that was filed: a rule that fires for a
# user with no route to comply is an outage with an explanation attached, not a guard.
#
# rebuild-tsv.sh writes requires: as a 7th TSV column; pre-tool-hook.sh probes it with
# `command -v` in BASH before its one awk process starts (awk here never shells out --
# see jit_missing_requires() in common.sh) and degrades block/require/forbid to advisory
# when the named binary does not resolve on PATH.
#
# Usage: bash tests/test-requires-field.sh
#
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
# jit-drive: assert_blocked blocked capture
# jit-drive: assert_not_blocked not_blocked capture

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"
REBUILD="$SCRIPT_DIR/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
TOOLS_DIR="$TEST_DIR/.claude/jit-context/tools/00-manual"
VOCAB_DIR="$TEST_DIR/.claude/jit-context/vocabulary"
mkdir -p "$TOOLS_DIR"
mkdir -p "$VOCAB_DIR/00-manual"
touch "$VOCAB_DIR/00-manual/00-index.tsv"

# The index FILENAME, held in a variable rather than typed next to a redirect: this
# repos own no-shell-writes-to-the-index.md rule matches a literal 00-index.tsv sitting
# after a >, and it cannot tell a real hand-write from a test fixture building the
# committed index format on purpose. Indirection is not evasion here -- it is the same
# distinction that rule already draws for every OTHER write form outside its list.
TSV_NAME="00-index.tsv"

# A PATH shim controls exactly one thing: whether `presentbin` resolves. `absentbin` is
# never created anywhere on PATH, in either directory -- it is the control the whole
# suite leans on, and it must never accidentally exist on the machine running this.
# bin/presentbin is a real, executable file; command -v looks it up, never runs it.
BIN_DIR=$(mktemp -d)
printf '#!/bin/sh\ntrue\n' > "$BIN_DIR/presentbin"
chmod +x "$BIN_DIR/presentbin"
export PATH="$BIN_DIR:$PATH"

# --- Fixtures ------------------------------------------------------------------
# Six rows, tool<TAB>match<TAB>file<TAB>modes<TAB>require<TAB>forbid<TAB>requires:
#   1. mode: block,    requires: absentbin  -> must degrade
#   2. mode: block,    requires: presentbin -> must still block (control)
#   3. mode: block,    no requires:         -> unaffected either way (control)
#   4. mode: remind,   require: --safe, requires: absentbin -> refusal degrades too
#   5. mode: remind,   forbid: --danger, requires: absentbin -> refusal degrades too
#   6. mode: remind,   requires: absentbin (no refusing column at all) -> ordinary
#      advisory row, unaffected: #203 is about a check that stops ENFORCING.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  Bash "git deploy" block-absent.md block "" "" absentbin \
  Bash "git ship" block-present.md block "" "" presentbin \
  Bash "git launch" block-plain.md block "" "" "" \
  Bash "git haul" req-absent.md remind "--safe" "" absentbin \
  Bash "git toss" forb-absent.md remind "" "--danger" absentbin \
  Bash "git nudge" remind-absent.md remind "" "" absentbin \
  > "$TOOLS_DIR/$TSV_NAME"

echo "BLOCK-ABSENT-BODY-MARKER" > "$TOOLS_DIR/block-absent.md"
echo "BLOCK-PRESENT-BODY-MARKER" > "$TOOLS_DIR/block-present.md"
echo "BLOCK-PLAIN-BODY-MARKER" > "$TOOLS_DIR/block-plain.md"
echo "REQ-ABSENT-BODY-MARKER" > "$TOOLS_DIR/req-absent.md"
echo "FORB-ABSENT-BODY-MARKER" > "$TOOLS_DIR/forb-absent.md"
echo "REMIND-ABSENT-BODY-MARKER" > "$TOOLS_DIR/remind-absent.md"

run_hook() {
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$HOOK" 2> /dev/null
}
run_tool() { run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}"; }

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:300}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:300}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

assert_blocked() {
  local desc="$1" output="$2"
  if grep -q "\"decision\":\"block\"" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected decision:block"
    echo "    got: ${output:0:300}"
  fi
}

assert_not_blocked() {
  local desc="$1" output="$2"
  if grep -q "\"decision\":\"block\"" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected no block, got: ${output:0:300}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

# =============================================
# SECTION 1: mode: block, requires: an absent binary -- degrades
# =============================================
echo ""
echo "=== mode: block, requires: absentbin -- degrades to advisory (#203) ==="
OUT=$(run_tool "git deploy the thing")
assert_not_blocked "the call is NOT blocked" "$OUT"
assert_contains "the row still fires, as advisory" "$OUT" "block-absent.md"
assert_contains "and says which binary is missing" "$OUT" "absentbin"
assert_contains "and says it degraded" "$OUT" "degraded to advisory"

# The positive control that makes the leg above mean anything: the SAME shape of row,
# the SAME command family, but its requires: binary IS on PATH -- and it still blocks.
# Without this, "not blocked" above is also true of a hook that read nothing at all.
echo ""
echo "=== Control: mode: block, requires: presentbin -- still blocks ==="
OUT=$(run_tool "git ship the thing")
assert_blocked "the call is blocked, same as before requires: existed" "$OUT"
assert_contains "and carries the entry text" "$OUT" "BLOCK-PRESENT-BODY-MARKER"
assert_not_contains "and does not claim a degrade that did not happen" "$OUT" "degraded to advisory"

# The other control: an ordinary block row with no requires: column at all must not
# read the empty string as "missing" and degrade every plain block rule in the tree.
echo ""
echo "=== Control: mode: block, no requires: -- unaffected ==="
OUT=$(run_tool "git launch the thing")
assert_blocked "an ordinary block rule still blocks" "$OUT"
assert_not_contains "and never mentions a degrade" "$OUT" "degraded to advisory"

# =============================================
# SECTION 2: require: / forbid: refusals degrade the same way
# =============================================
echo ""
echo "=== require: + requires: absentbin -- the requirement refusal degrades too ==="
OUT=$(run_tool "git haul the thing")
assert_not_blocked "not blocked, even though --safe is missing" "$OUT"
assert_contains "the row still fires, as advisory" "$OUT" "req-absent.md"
assert_contains "and names the missing binary" "$OUT" "absentbin"

echo ""
echo "=== forbid: + requires: absentbin -- the forbid refusal degrades too ==="
OUT=$(run_tool "git toss it --danger")
assert_not_blocked "not blocked, even though --danger is present" "$OUT"
assert_contains "the row still fires, as advisory" "$OUT" "forb-absent.md"
assert_contains "and names the missing binary" "$OUT" "absentbin"

# =============================================
# SECTION 3: an ordinary advisory row naming requires: is unaffected
# =============================================
# #203 is about a check that stops ENFORCING. A `remind` row was never going to block
# anything, so requires: naming an absent binary on one must not suppress it or start
# announcing a degrade that never happened.
echo ""
echo "=== mode: remind, requires: absentbin -- an ordinary advisory row, untouched ==="
OUT=$(run_tool "git nudge the thing")
assert_contains "the row fires normally" "$OUT" "REMIND-ABSENT-BODY-MARKER"
assert_not_contains "and never claims a degrade -- it was never enforcing anything" \
  "$OUT" "degraded to advisory"

# =============================================
# SECTION 4: rebuild-tsv.sh writes the column, and jit-dry-run.sh agrees with it
# =============================================
echo ""
echo "=== rebuild-tsv.sh writes requires: as the 7th column ==="
printf '%s\n' \
  "---" \
  "title: Deploy guard" \
  "description: Blocks a deploy unless the deploy tool is on PATH." \
  "tool: Bash" \
  "match: git rebuild-deploy" \
  "mode: block" \
  "requires: rebuildtool" \
  "---" \
  "" \
  "REBUILD-DEPLOY-BODY-MARKER" > "$TOOLS_DIR/rebuild-deploy.md"
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REBUILD" > /dev/null 2>&1
ROW=$(grep -F "rebuild-deploy.md" "$TOOLS_DIR/$TSV_NAME" || true)
assert_contains "the rebuilt row carries the requires: value" "$ROW" "rebuildtool"

echo ""
echo "=== jit-dry-run.sh does not read a freshly rebuilt requires: row as stale ==="
DRYRUN_OUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$SCRIPT_DIR/scripts/jit-dry-run.sh" --base "$TEST_DIR/.claude/jit-context" 2>&1)
# "STALE", not the bare filename: rebuild-deploy.md legitimately appears in this run's
# other reports too -- jit-dry-run.sh separately flags a can_refuse row with a bare,
# non-anchored match (#136), which this fixture also happens to trigger and which has
# nothing to do with #203. The claim under test is narrower than "the name never
# appears" -- it is "the row this suite just rebuilt does not read as drifted from its
# own frontmatter", and STALE is the one word that check actually prints.
assert_not_contains "no STALE report for the row this suite just rebuilt" "$DRYRUN_OUT" "STALE"

rm -f "$TOOLS_DIR/rebuild-deploy.md"

# =============================================
# SECTION 5 (#427): rebuild-tsv.sh refuses to index a requires: value that is not a
# bare binary name -- the value crosses an exec boundary at fire time (pre-tool-hook.sh
# hands the WHOLE accumulated list to awk as one -v argument), so a malformed or
# oversized value on ONE row is not this row's own problem alone.
# =============================================
echo ""
echo "=== rebuild-tsv.sh refuses requires: with an embedded space (#427) ==="
printf '%s\n' \
  "---" \
  "title: Bad requires space" \
  "description: A requires: value that is not a bare binary name." \
  "tool: Bash" \
  "match: git bad-requires-space" \
  "mode: block" \
  "requires: not a binary name" \
  "---" \
  "" \
  "BAD-REQUIRES-SPACE-BODY-MARKER" > "$TOOLS_DIR/bad-requires-space.md"
# The refusal is expected here -- rebuild-tsv.sh exits non-zero when it skips a row --
# so `|| true` is load-bearing under `set -e`, not decoration.
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REBUILD" > /dev/null 2>&1 || true
ROW=$(grep -F "bad-requires-space.md" "$TOOLS_DIR/$TSV_NAME" || true)
assert_not_contains "the malformed row is not indexed at all" "$ROW" "bad-requires-space.md"
rm -f "$TOOLS_DIR/bad-requires-space.md"

echo ""
echo "=== rebuild-tsv.sh refuses requires: longer than 255 bytes (#427) ==="
LONGREQ=$(head -c 300 /dev/zero | tr '\0' 'a')
printf '%s\n' \
  "---" \
  "title: Bad requires length" \
  "description: A requires: value past the bare-name length bound." \
  "tool: Bash" \
  "match: git bad-requires-length" \
  "mode: block" \
  "requires: $LONGREQ" \
  "---" \
  "" \
  "BAD-REQUIRES-LENGTH-BODY-MARKER" > "$TOOLS_DIR/bad-requires-length.md"
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REBUILD" > /dev/null 2>&1 || true
ROW=$(grep -F "bad-requires-length.md" "$TOOLS_DIR/$TSV_NAME" || true)
assert_not_contains "the oversized row is not indexed at all" "$ROW" "bad-requires-length.md"
rm -f "$TOOLS_DIR/bad-requires-length.md"

# =============================================
# SECTION 6 (#427): jit_missing_requires() bounds its OWN output regardless of how
# large the committed index already is -- this is the check that protects a CLONE, not
# just a future rebuild by this repository own maintainer, and it has to hold even for
# an index nothing above ever validated. Built directly, bypassing rebuild-tsv.sh
# entirely, the same way a tree cloned before this fix would already be malformed on
# disk.
# =============================================
echo ""
echo "=== jit_missing_requires() caps its own output regardless of input size (#427) ==="
CAP_DIR=$(mktemp -d)
CAP_TOOLS_BASE="$CAP_DIR/tools"
CAP_TOOLS="$CAP_TOOLS_BASE/00-manual"
mkdir -p "$CAP_TOOLS"
# 80 distinct, syntactically valid but never-resolving binary names, each padded to
# ~120 bytes -- about 9.6 KB total, well past a few-KB cap, built entirely of rows a
# bare-name check alone would accept, so this measures the CAP, not the validator.
{
  n=0
  while [ "$n" -lt 80 ]; do
    pad=$(head -c 100 /dev/zero | tr '\0' 'x')
    printf 'Bash\tirrelevant%d\tirrelevant%d.md\tremind\t\t\tnosuchbin%d%s\n' "$n" "$n" "$n" "$pad"
    n=$((n + 1))
  done
} > "$CAP_TOOLS/$TSV_NAME"
CAP_OUT=$(
  cd "$SCRIPT_DIR" || exit 1
  # shellcheck source=scripts/common.sh
  source scripts/common.sh
  jit_missing_requires "$CAP_TOOLS_BASE" "00-manual"
)
CAP_LEN=${#CAP_OUT}
if [ "$CAP_LEN" -le 4300 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the accumulated list stays bounded ($CAP_LEN bytes) no matter how many rows feed it"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the accumulated list stays bounded no matter how many rows feed it"
  echo "    got $CAP_LEN bytes"
fi
assert_contains "and says plainly that it truncated" "$CAP_OUT" "JIT-427"
rm -rf "$CAP_DIR"

echo ""
echo "=== a call unrelated to any requires: row still answers, even with a huge committed index (#427) ==="
BIG_DIR=$(mktemp -d)
BIG_TOOLS="$BIG_DIR/.claude/jit-context/tools/00-manual"
BIG_VOCAB="$BIG_DIR/.claude/jit-context/vocabulary"
mkdir -p "$BIG_TOOLS" "$BIG_VOCAB/00-manual"
touch "$BIG_VOCAB/00-manual/$TSV_NAME"
{
  n=0
  while [ "$n" -lt 80 ]; do
    pad=$(head -c 100 /dev/zero | tr '\0' 'x')
    printf 'Bash\tirrelevant%d\tirrelevant%d.md\tremind\t\t\tnosuchbin%d%s\n' "$n" "$n" "$n" "$pad"
    n=$((n + 1))
  done
  printf 'Bash\tgit ordinary-call\tordinary.md\tblock\t\t\t\n'
} > "$BIG_TOOLS/$TSV_NAME"
echo "ORDINARY-CALL-BODY-MARKER" > "$BIG_TOOLS/ordinary.md"
BIG_OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git ordinary-call now"}}' | CLAUDE_PROJECT_DIR="$BIG_DIR" bash "$HOOK" 2> /dev/null)
assert_blocked "the hook still answers -- a real decision, not a crash envelope" "$BIG_OUT"
assert_contains "and the row unrelated to any requires: value still fires" "$BIG_OUT" "ORDINARY-CALL-BODY-MARKER"
rm -rf "$BIG_DIR"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

rm -rf "$TEST_DIR" "$BIN_DIR"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
