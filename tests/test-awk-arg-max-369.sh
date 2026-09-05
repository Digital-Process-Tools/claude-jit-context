#!/bin/bash
# #369: the awk PROGRAM this hook builds as ONE shell argument can exceed Linux's
# per-argument exec() cap.
#
# #364/#365's own fix added a small function plus a few comments to
# scripts/pre-tool-hook.sh's embedded awk program -- itself already the concatenation
# of every JIT_AWK_* macro in scripts/common.sh PLUS the literal awk source in the
# rest of pre-tool-hook.sh, delivered to `awk` as a SINGLE shell word (the double-quoted
# macro expansion and the single-quoted literal sit adjacent with no space between
# them, so bash concatenates them into one argument rather than two). That single
# argument was already 129890 bytes before #364/#365 touched it -- 1182 bytes under
# Linux's MAX_ARG_STRLEN (32 * PAGE_SIZE = 131072 bytes, a per-argument cap on
# execve(), separate from and much smaller than the total argv+envp cap most people
# mean by ARG_MAX). #364/#365's own addition pushed it to 132965 bytes, 1893 over.
#
# Nothing was wrong with the fix's logic. Every suite this repository ships was green
# on macOS, which enforces no such per-argument cap -- only the total argv+envp size,
# which this string is nowhere near. CI's ubuntu-latest leg failed all 26 suites that
# exercise scripts/pre-tool-hook.sh, on every awk engine in the matrix (gawk, mawk,
# nawk, one-true-awk), each with the identical stderr:
#
#   scripts/pre-tool-hook.sh: line 80: <path>/awk: Argument list too long
#
# Line 80 is exactly the LC_ALL=C awk simple command this file's own single huge
# argument feeds. A green run on the platform this was written on said nothing about
# the platform it was not run on -- the exact class CLAUDE.md's cross-platform section
# already names, one specific mechanism deeper: a STATIC byte count nobody had reason
# to watch, not a runtime value, not attacker-influenced data, and not something any
# existing ARG_MAX-aware code in this repo (JIT_SYMLINKS, config.env's cap) was built
# to catch, because those all bound DYNAMIC, environment-carried data -- this is the
# fixed program TEXT itself.
#
# THE FIX in scripts/pre-tool-hook.sh was cutting the added comments down without
# losing the reasoning (kept in git blame and the PR body instead of inline), buying
# back enough bytes to land under 131072 again. THIS TEST is the structural guard: a
# byte-count check that runs on any platform (it never execs anything, so the cap it
# is protecting against never fires here) and would have caught this before the first
# push rather than after. -uo pipefail (not -e): a genuinely broken sourcing chain must
# still let this test report FAIL rather than silently exiting.
#
# Usage: bash tests/test-awk-arg-max-369.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

# Linux's per-argument exec() cap (MAX_ARG_STRLEN = 32 * PAGE_SIZE on every page size
# this repository's CI runs under). This is the number that actually bit #369, not a
# margin invented for this test.
ARG_STRLEN_CAP=131072

if ! command -v python3 > /dev/null 2>&1; then
  echo "  SKIPPED: python3 unavailable here -- the byte-count check needs it (no shell-only extraction is both correct and simple; see this file's own header)."
  echo ""
  echo "========================"
  echo "  0/0 passed, 0 failed, 1 section(s) SKIPPED"
  echo "========================"
  exit 0
fi

# Every hook that builds its own awk program this way: a single JIT_AWK_* macro
# concatenation immediately followed (no space) by a single-quoted literal awk source
# block, both fed to awk as one shell word. Enumerated, not gathered by grep for the
# LC_ALL=C awk marker alone -- session-start-hook.sh and stop-hook.sh also match that
# marker but hand-roll their own small awk one-liners with no macro concatenation and
# no risk of approaching this cap, and folding them in here would need a second parser
# for a shape they do not have.
HOOKS="pre-tool-hook.sh pre-prompt-hook.sh pre-path-hook.sh post-tool-hook.sh"

for hook in $HOOKS; do
  path="$SCRIPTS/$hook"
  if [ ! -r "$path" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook exists and is readable -- nothing below can measure it"
    continue
  fi

  total=$(
    SIZE_HOOK="$path" SIZE_SCRIPT_DIR="$SCRIPT_DIR" python3 << 'PYEOF'
import os

path = os.environ["SIZE_HOOK"]
script_dir = os.environ["SIZE_SCRIPT_DIR"]
text = open(path, "r", encoding="utf-8", errors="surrogateescape").read()

# Every macro this repo's hooks concatenate, in the order common.sh defines them.
# Reading common.sh's OWN source for these -- not re-deriving the awk text by any
# other means -- is deliberate: a macro this test does not know about growing later
# must silently pass ONE bad check (that macro is measured as zero bytes here) rather
# than the whole test refusing to run, matching this repo's own "never fail hard,
# degrade to a named third state" posture one file over. Missing macros are counted
# as a warning line rather than a silent zero.
macro_names = [
    "JIT_AWK_GUARD", "JIT_AWK_ENTRY", "JIT_AWK_INJECT", "JIT_AWK_JSON",
    "JIT_AWK_FOLD", "JIT_AWK_BLK_BUILD", "JIT_AWK_ENVELOPE",
]

common_path = os.path.join(script_dir, "scripts", "common.sh")
common_text = open(common_path, "r", encoding="utf-8", errors="surrogateescape").read()

def macro_len(name):
    # NAME='...' (single-quoted bash literal), the shape every JIT_AWK_* macro in
    # common.sh takes. Finds the FIRST assignment only -- common.sh assigns each of
    # these exactly once, which tests/test-awk-locale-pins.sh's own reasoning about
    # this file already relies on elsewhere.
    marker = name + "='"
    i = common_text.find(marker)
    if i == -1:
        return None
    i += len(marker)
    j = common_text.find("'", i)
    if j == -1:
        return None
    return j - i

macro_total = 0
missing = []
for name in macro_names:
    n = macro_len(name)
    if n is None:
        missing.append(name)
    else:
        macro_total += n

# The literal awk program text embedded directly in the hook file, after the macro
# concatenation. Every one of these four hooks builds its command as
# LC_ALL=C awk ... -v ... "$JIT_AWK_..."'<literal source>', so the boundary is the
# LAST macro variable name immediately followed by a double quote then a single quote
# (closing the double-quoted expansion, opening the single-quoted literal), and the
# literal ends at the next unescaped single quote.
start_marker = "$JIT_AWK_ENVELOPE" + chr(34) + chr(39)
i = text.find(start_marker)
literal_len = 0
if i != -1:
    i += len(start_marker)
    j = text.find(chr(39), i)
    if j != -1:
        literal_len = j - i

total = macro_total + literal_len
print(total)
if missing:
    import sys
    sys.stderr.write("MISSING MACROS: " + ",".join(missing) + chr(10))
PYEOF
  )
  rc=$?

  if [ "$rc" -ne 0 ] || [ -z "$total" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook -- could not measure the awk program size at all"
    continue
  fi

  if [ "$total" -lt "$ARG_STRLEN_CAP" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $hook awk program is $total bytes, under the $ARG_STRLEN_CAP-byte Linux per-argument cap (#369)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook awk program is $total bytes -- at or over the $ARG_STRLEN_CAP-byte Linux per-argument cap (#369). This is the EXACT failure CI hit: every awk engine fails this hook own exec() with Argument list too long, on Linux only -- macOS enforces no such per-argument cap and will report this hook as healthy. Trim the newly added comments (keep the reasoning in git blame / the PR body) or move this hook awk program off the argv entirely (awk -f a generated tempfile)."
  fi
done

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
