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
# #371: this test's own byte count PASSED (131052 under 131072) on the exact commit CI
# still hit real E2BIG on. The gap was this file measuring a Python STR index as a byte
# count: `open(path, "r", encoding="utf-8", ...).read()` decodes the file, and a decoded
# str's `len()`/slicing counts CODE POINTS, not bytes. Every accented-letter fold table
# and em-dash this repo's own prose carries (JIT_AWK_FOLD's Latin-1 table alone: dozens
# of them, 2 bytes each in the file, 1 python character each) was undercounted by
# exactly the gap between chars and bytes -- 58 bytes on JIT_AWK_FOLD alone, enough on
# its own to explain the 20-byte "headroom" this test reported being fake. Re-measured in
# real bytes, pre-tool-hook.sh's composed program was 131146 bytes: 74 OVER the cap, not
# 20 under it -- the exact E2BIG CI hit, now reproduced as a plain byte count with no
# exec() involved. Fixed by encoding every extracted substring back to UTF-8 bytes
# (errors="surrogateescape", matching the read) before taking its length.
#
# #371 also moved pre-tool-hook.sh's composed program off the argv entirely: it is
# written to a generated tempfile and invoked via `awk -f`, which removes the cap from
# consideration regardless of the program's size. A hook that has made this move is
# structurally exempt from the byte-cap check below (detected by the naming convention
# the fix adopted: VAR="$JIT_AWK_...'...'" later invoked as `awk ... -f "$VAR_FILE"`) --
# reported as such rather than measured against a cap that no longer bounds it.
#
# jit-drive: none -- every check here is a byte-count comparison against a fixed
# threshold, printed and counted inline; nothing takes captured hook output or a
# needle, so there is no payload-shaped helper here for test-assertion-helpers.sh
# to drive.
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
# block, both fed to awk as one shell word (or, since #371, written whole to a tempfile
# and fed via `awk -f`). Enumerated, not gathered by grep for the LC_ALL=C awk marker
# alone -- session-start-hook.sh and stop-hook.sh also match that marker but hand-roll
# their own small awk one-liners with no macro concatenation and no risk of approaching
# this cap, and folding them in here would need a second parser for a shape they do not
# have.
HOOKS="pre-tool-hook.sh pre-prompt-hook.sh pre-path-hook.sh post-tool-hook.sh"

for hook in $HOOKS; do
  path="$SCRIPTS/$hook"
  if [ ! -r "$path" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook exists and is readable -- nothing below can measure it"
    continue
  fi

  result=$(
    SIZE_HOOK="$path" SIZE_SCRIPT_DIR="$SCRIPT_DIR" python3 << 'PYEOF'
import os
import re

path = os.environ["SIZE_HOOK"]
script_dir = os.environ["SIZE_SCRIPT_DIR"]
raw = open(path, "rb").read()
text = raw.decode("utf-8", errors="surrogateescape")

common_path = os.path.join(script_dir, "scripts", "common.sh")
common_raw = open(common_path, "rb").read()
common_text = common_raw.decode("utf-8", errors="surrogateescape")

def byte_len(s):
    # #371: the file is read and decoded as UTF-8 text so string patterns can be
    # searched with re; every byte-count taken from a SLICE of that decoded string
    # must be re-encoded before it is trusted as a byte count, or a multibyte
    # character (this repo's own accented prose and fold tables carry plenty)
    # silently reads as one byte short (or more) of what it really costs on argv.
    return len(s.encode("utf-8", errors="surrogateescape"))

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
    return byte_len(common_text[i:j])

# WHICH macros a hook concatenates is read off the HOOK, not off a list kept here
# (#299/#367 self-review, found by oss:auditor). This block used to hold a hardcoded
# seven-name list plus a hardcoded boundary marker, "$JIT_AWK_ENVELOPE" followed by a
# double quote and a single quote -- and both halves went silently blind the moment a
# hook stopped matching them. `pre-prompt-hook.sh` gained an eighth macro
# ($JIT_AWK_ENVELOPE_SYSMSG) at the END of its concatenation, so the marker no longer
# occurred in the file at all and `literal_len` fell back to its silent 0: the test
# went on printing a confident, passing, WRONG byte count (57782 against a real 79675)
# that could never grow again, for exactly the hook whose growth it exists to watch.
# `pre-path-hook.sh` had been blind the same way since before that change, because its
# concatenation is a bare VAR=$JIT_AWK_...' assignment with no double quote for the
# marker to anchor on -- nobody noticed, because a silent zero reads exactly like a
# small literal.
#
# So the shape is matched instead: one or more adjacent $JIT_AWK_<NAME> references,
# optionally wrapped in double quotes, immediately followed by the single quote that
# opens the literal awk source. That covers both shapes this repo actually writes, and
# a hook that matches NEITHER is reported as unmeasurable rather than measured as
# zero -- the same "a third state must not render as the first" rule this repository
# applies to its hooks, applied to the test watching them.
run_re = re.compile(r'(?:\$JIT_AWK_[A-Z_]+)+' + chr(34) + '?' + chr(39))
m = run_re.search(text)
if m is None:
    print("UNMEASURABLE")
    raise SystemExit(0)

# #371: a hook whose composed program is ASSIGNED to a variable (VAR="$JIT_AWK_...")
# rather than fed straight to awk positionally may since have moved it off the argv
# entirely -- written to a tempfile and read via `awk -f "$VAR_FILE"`. Detected by the
# naming convention that move adopted, not by re-parsing the awk invocation itself:
# look at what immediately precedes this match for `VAR="` touching the match start,
# then check whether `-f "$VAR_FILE"` occurs anywhere later in the file.
prefix = text[max(0, m.start() - 80):m.start()]
assign_m = re.search(r'([A-Za-z_][A-Za-z0-9_]*)="$', prefix)
if assign_m is not None:
    varname = assign_m.group(1)
    needle = '-f ' + chr(34) + '$' + varname + '_FILE' + chr(34)
    if needle in text:
        print("TEMPFILE:" + varname)
        raise SystemExit(0)

macro_names = re.findall(r'\$(JIT_AWK_[A-Z_]+)', m.group(0))
macro_total = 0
missing = []
for name in macro_names:
    n = macro_len(name)
    if n is None:
        missing.append(name)
    else:
        macro_total += n

# The literal awk source runs from the single quote this match ends on to the next one.
i = m.end()
j = text.find(chr(39), i)
if j == -1:
    print("UNMEASURABLE")
    raise SystemExit(0)
literal_len = byte_len(text[i:j])

total = macro_total + literal_len
print(total)
if missing:
    import sys
    sys.stderr.write("MISSING MACROS: " + ",".join(missing) + chr(10))
PYEOF
  )
  rc=$?

  if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook -- the byte-count extraction itself did not run cleanly (rc=$rc)."
    continue
  fi

  case "$result" in
    UNMEASURABLE)
      FAIL=$((FAIL + 1))
      echo "  FAIL: $hook -- could not find its macro-concatenation/literal boundary, so its"
      echo "        awk program size was NOT measured. This is the silent-zero shape #369's"
      echo "        own guard fell into once already: fix the extraction above rather than"
      echo "        letting an unmeasured hook read as a small one."
      continue
      ;;
    TEMPFILE:*)
      PASS=$((PASS + 1))
      echo "  PASS: $hook writes its composed awk program (${result#TEMPFILE:}) to a tempfile"
      echo "        and invokes it with -f -- off the argv entirely, so the ${ARG_STRLEN_CAP}-byte"
      echo "        Linux per-argument cap does not bound it regardless of size (#371)."
      continue
      ;;
  esac

  total="$result"

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

echo ""
echo "=== D: a hook that moved its program off the argv never falls back onto it (#371) ==="
# #371 self-review: pre-tool-hook.sh's own EXIT-trap tempfile can fail to be created or
# written (unwritable/missing $TMPDIR), and the first cut of this fix fell back to the
# OLD positional form in that case -- which re-triggers the exact E2BIG this fix exists
# to remove, on the one hook that is already 74 bytes over the cap TODAY. A fallback that
# still hands the full program to awk as a bare positional argument is not a fallback at
# all here; it must stay off the argv (a generated tempfile, or -f on a process
# substitution) in EVERY branch, not just the happy one.
for hook in $HOOKS; do
  path="$SCRIPTS/$hook"
  [ -f "$path" ] || continue
  # Only hooks that have made the #371 move (VAR="$JIT_AWK_..." later read via -f) are
  # in scope here -- a hook still on the plain positional form everywhere is #369's own
  # concern above, not this one.
  if ! grep -q '\-f "\$JIT_AWK_PROGRAM_FILE"' "$path" 2> /dev/null; then
    continue
  fi
  # Every remaining reference to the composed program variable, anywhere in the file,
  # must be reached through -f -- never handed to awk as a bare positional word.
  bare="$(awk '
    /awk[^\n]*"\$JIT_AWK_PROGRAM"[[:space:]]*$/ && $0 !~ /-f/ { print FILENAME ":" FNR ": " $0 }
  ' "$path")"
  if [ -z "$bare" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $hook -- every reference to \$JIT_AWK_PROGRAM is reached through -f, in every branch"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $hook -- a fallback still hands the composed program to awk positionally:"
    echo "$bare"
  fi
done

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
