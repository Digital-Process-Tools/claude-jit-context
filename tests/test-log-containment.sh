#!/bin/bash
# S4: the hooks write their log through a path a CLONED REPOSITORY controls.
#
# common.sh built the log path by concatenation and checked nothing:
#
#   LOG_DIR="$JIT_BASE/.discovery/logs"; mkdir -p "$LOG_DIR"; LOG_FILE="$LOG_DIR/hooks.log"
#
# `mkdir -p` follows a symlink and `>>` follows a symlink, and git tracks symlinks as mode
# 120000 -- so `.discovery/logs/hooks.log -> ~/.zshenv` in a cloned repo means one prompt
# appends attacker-chosen text to the victim rc file, and it runs at the next shell start.
# Reproduced 2026-08-12 with NO keyword match, NO rule fired and NO entry file present:
# the refusal path on its own writes a line.
#
# Four link positions reach the same write, and each is driven separately:
#   S4a  hooks.log itself
#   S4b  .discovery/logs
#   S4c  .discovery
#   S4d  .claude/jit-context, and .claude
#
# The content half is here too: the refusal path put the index row file-name column into
# the log verbatim, including for a name that FAILED the bare-name check -- the exact
# string jit_bad_entry_file() withholds from the model. The log is a file on the victim
# disk, not a safe sink.
#
# THE GUARD THIS SUITE NEEDS: "nothing was written outside the tree" passes when nothing
# happened at all -- a typo in the payload, a hook that exited early, a harness that never
# reached the code. So every negative is preceded by a positive control on the SAME shape:
# the honest tree must produce a log line, and the hook must still inject its notice while
# refusing to log. If those go red, the negatives below mean nothing and say so.
#
# Usage: bash tests/test-log-containment.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF "$expected"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF "$unexpected"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    this path should not exist: $path"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RC_MARKER="# rc"
PROMPT_PAYLOAD='{"prompt":"hello"}'

# A project whose vocabulary index carries one row with a NON-BARE file name. That row is
# refused without any keyword matching and without the file existing, so every hook run
# below has something to log -- which is what makes the negatives meaningful.
new_hostile() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/vocabulary/00-manual" \
           "$p/.claude/jit-context/paths/00-manual" \
           "$p/.claude/jit-context/tools/00-manual"
  printf '%s\t%s\n' 'zzz' '../x-CANARY-ROW' > "$p/.claude/jit-context/vocabulary/00-manual/00-index.tsv"
  printf '%s' "$p"
}

new_rc() {
  local f="$TMP/$1"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$RC_MARKER" > "$f"
  printf '%s' "$f"
}

# Subject to the same known flake as tests/test-symlink-entry.sh, which carries the
# measurement: under $( ) the hook inherits the command-substitution subshell as $PPID, and
# a recycled pid brings a stale once-per-session marker with it. When that happens the hook
# prints {} and the "hook still injects its notice" control below goes red. Re-run before
# treating it as a finding.
run_prompt() {
  printf '%s' "$PROMPT_PAYLOAD" | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-prompt-hook.sh" 2>&1
}

echo "=== Positive control: the honest tree logs, so the negatives below mean something ==="

P="$(new_hostile honest)"
OUT="$(run_prompt "$P")"; RC=$?
LOG="$P/.claude/jit-context/.discovery/logs/hooks.log"
assert_rc0 "honest tree: hook exits 0" "$RC"
assert_contains "honest tree: the hook injects its refusal notice" "$OUT" "could not be evaluated"
if [ -f "$LOG" ]; then
  PASS=$((PASS + 1)); echo "  PASS: honest tree: a log line is written inside the project"
  assert_contains "honest tree: that line is this run" "$(cat "$LOG")" "pre-prompt"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: honest tree: NO log was written inside the project."
  echo "        Every 'nothing was written outside the tree' assertion below is vacuous"
  echo "        until this passes -- the harness cannot see the write at all."
fi

echo ""
echo "=== S4a: hooks.log is a symlink to a file outside the project ==="

P="$(new_hostile s4a)"
RCFILE="$(new_rc victim-a/.zshenv)"
mkdir -p "$P/.claude/jit-context/.discovery/logs"
ln -sf "$RCFILE" "$P/.claude/jit-context/.discovery/logs/hooks.log"
OUT="$(run_prompt "$P")"; RC=$?
assert_rc0 "linked hooks.log: hook still exits 0" "$RC"
assert_contains "linked hooks.log: hook still injects its notice" "$OUT" "could not be evaluated"
assert_contains "linked hooks.log: the victim file still exists and is readable" "$(cat "$RCFILE")" "$RC_MARKER"
assert_not_contains "linked hooks.log: nothing was appended to the victim file" "$(cat "$RCFILE")" "pre-prompt"
assert_not_contains "linked hooks.log: the row name did not reach the victim file" "$(cat "$RCFILE")" "CANARY-ROW"

echo ""
echo "=== S4b: .discovery/logs is a symlink to a directory outside the project ==="

P="$(new_hostile s4b)"
OUTDIR="$TMP/victim-b"; mkdir -p "$OUTDIR"
mkdir -p "$P/.claude/jit-context/.discovery"
ln -sfn "$OUTDIR" "$P/.claude/jit-context/.discovery/logs"
OUT="$(run_prompt "$P")"; RC=$?
assert_rc0 "linked logs dir: hook still exits 0" "$RC"
assert_contains "linked logs dir: hook still injects its notice" "$OUT" "could not be evaluated"
assert_no_file "linked logs dir: no log was created in the linked directory" "$OUTDIR/hooks.log"

echo ""
echo "=== S4c: .discovery is a symlink to a directory outside the project ==="

P="$(new_hostile s4c)"
OUTDIR="$TMP/victim-c"; mkdir -p "$OUTDIR"
ln -sfn "$OUTDIR" "$P/.claude/jit-context/.discovery"
OUT="$(run_prompt "$P")"; RC=$?
assert_rc0 "linked .discovery: hook still exits 0" "$RC"
assert_contains "linked .discovery: hook still injects its notice" "$OUT" "could not be evaluated"
assert_no_file "linked .discovery: no logs directory was created outside the tree" "$OUTDIR/logs"

echo ""
echo "=== S4d: an ancestor of the log path is a symlink out of the tree ==="

# .claude/jit-context and .claude are refused for ENTRY reading by the S3 sweep, but the
# log path is built by a different concatenation and was not covered by it.
P="$TMP/s4d-jit"; rm -rf "$P"; mkdir -p "$P/.claude"
OUTDIR="$TMP/victim-d1"; mkdir -p "$OUTDIR/vocabulary/00-manual"
printf '%s\t%s\n' 'zzz' '../x-CANARY-ROW' > "$OUTDIR/vocabulary/00-manual/00-index.tsv"
ln -sfn "$OUTDIR" "$P/.claude/jit-context"
OUT="$(run_prompt "$P")"; RC=$?
assert_rc0 "linked jit-context: hook still exits 0" "$RC"
# Paired on this shape too, not only on S4a-c: without it, "no log outside the tree" is
# equally satisfied by a hook that bailed out before reading anything.
assert_contains "linked jit-context: hook still injects its notice" "$OUT" "could not be evaluated"
assert_no_file "linked jit-context: no log was created outside the tree" "$OUTDIR/.discovery"

P="$TMP/s4d-claude"; rm -rf "$P"; mkdir -p "$P"
OUTDIR="$TMP/victim-d2"; mkdir -p "$OUTDIR/jit-context/vocabulary/00-manual"
printf '%s\t%s\n' 'zzz' '../x-CANARY-ROW' > "$OUTDIR/jit-context/vocabulary/00-manual/00-index.tsv"
ln -sfn "$OUTDIR" "$P/.claude"
OUT="$(run_prompt "$P")"; RC=$?
assert_rc0 "linked .claude: hook still exits 0" "$RC"
assert_contains "linked .claude: hook still injects its notice" "$OUT" "could not be evaluated"
assert_no_file "linked .claude: no log was created outside the tree" "$OUTDIR/jit-context/.discovery"

echo ""
echo "=== S4e: what the log is allowed to say about a refused row ==="

# The log line for a row whose NAME failed the bare-name check must identify the row by
# POSITION, the way the model-facing notice already does. That name is unvalidated
# attacker text and a person reads this file.
#
# Driven against the opposite case in the same section, because a fix that stopped naming
# ANY refused entry would satisfy the negative on its own: a row whose name PASSED the
# bare-name check and whose pattern is what got refused must still be named, which is what
# an author fixing it needs.

P="$(new_hostile s4e-name)"
run_prompt "$P" > /dev/null
LOG="$(cat "$P/.claude/jit-context/.discovery/logs/hooks.log")"
assert_contains "unbare name: something was logged for the refused row" "$LOG" "refused:"
assert_contains "unbare name: the row is identified by position" "$LOG" "00-manual row 1"
assert_not_contains "unbare name: the raw name is not written to the log" "$LOG" "CANARY-ROW"
assert_contains "unbare name: the reason survives" "$LOG" "not a bare file name"

P="$(new_hostile s4e-pattern)"
printf '%s\t%s\t%s\t\t\t\n' 'Bash' '~gh\d pr' 'note-NAMED-OK.md' > "$P/.claude/jit-context/tools/00-manual/00-index.tsv"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/pre-tool-hook.sh" >/dev/null 2>&1
LOG="$(cat "$P/.claude/jit-context/.discovery/logs/hooks.log")"
assert_contains "bare name, bad pattern: the file is still named in the log" "$LOG" "note-NAMED-OK.md"
assert_contains "bare name, bad pattern: the reason survives" "$LOG" "undefined escape"

echo ""
echo "=== Negative control: an honest tree logs exactly as before ==="

P="$TMP/plain"; rm -rf "$P"
mkdir -p "$P/.claude/jit-context/vocabulary/00-manual"
D="$P/.claude/jit-context/vocabulary/00-manual"
printf 'vocab body\n' > "$D/good.md"
printf '%s\t%s\n' 'sectarget' 'good.md' > "$D/00-index.tsv"
OUT="$(printf '{"prompt":"tell me about sectarget"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/pre-prompt-hook.sh" 2>&1)"
assert_contains "honest tree: the entry still fires" "$OUT" "vocab body"
LOG="$(cat "$P/.claude/jit-context/.discovery/logs/hooks.log")"
assert_contains "honest tree: the match is still logged by file name" "$LOG" "good.md"
assert_not_contains "honest tree: nothing is refused" "$LOG" "refused:"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
