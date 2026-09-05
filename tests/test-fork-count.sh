#!/bin/bash
# Tests that this plugin's scripts do the work they are asked to and do not fork for the
# rest -- the six hooks, which run per tool call, and jit-dry-run.sh, which CI and every
# author runs over a whole tree.
#
# The hooks run in someone else's session on every prompt and every tool call, and on
# Windows (Git Bash) a process spawn is the expensive thing -- the same fact that made
# tests/test-dogfood-entries.sh cost 442s on that leg while costing 33s locally. So the
# count of external commands one hook invocation makes is a behaviour worth pinning, not
# a performance note: it is the same on a miss as on a hit, which means every session
# pays it on every call whether a rule fires or not.
#
# Counted with a PATH shim -- one `exec` wrapper per command name, ahead of $PATH, each
# appending its own name to a file. It measures what the hook actually ran rather than
# what the source appears to call, which is the point: a fork inside a function three
# files away counts the same as one on the line you are reading.
#
# What is NOT asserted here, deliberately: milliseconds. What a spawn costs in Git Bash
# is not measurable from this machine, and a threshold nobody can reproduce on the leg it
# is about is a number that rots into noise. Counts are exact and portable; times are not.
#
# Usage: bash tests/test-hook-spawn-count.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# jit-drive: none -- every helper here runs a real hook and counts its forks; none takes hook output as an argument

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jit-spawn.XXXXXXXX" 2> /dev/null)" || {
  echo "  SKIPPED: could not create a work directory -- nothing was measured"
  exit 2
}
trap 'rm -rf "$WORK"' EXIT

SHIM="$WORK/shim"
COUNT="$WORK/count"
mkdir -p "$SHIM"
: > "$COUNT"

# Every command a hook could plausibly reach for. A name with no real binary behind it is
# skipped rather than shimmed into a wrapper that would exec nothing -- a shim that broke
# the command it wraps would redden this suite for a reason that has nothing to do with
# forks.
SHIMMED=""
for c in awk grep sed tr wc cat head tail sort uniq cut date mkdir rm mv cp touch ls \
  dirname basename expr stat find perl mktemp chmod; do
  real=""
  for d in /usr/bin /bin /usr/local/bin; do
    if [ -x "$d/$c" ]; then
      real="$d/$c"
      break
    fi
  done
  [ -n "$real" ] || continue
  {
    printf '#!/bin/sh\n'
    printf 'echo %s >> "%s"\n' "$c" "$COUNT"
    printf 'exec %s "$@"\n' "$real"
  } > "$SHIM/$c"
  chmod +x "$SHIM/$c" 2> /dev/null || continue
  SHIMMED="$SHIMMED $c"
done

# How many times one hook invocation spawned one named command.
spawns_of() {
  local n
  n=$(grep -c -x -F "$1" "$COUNT" 2> /dev/null)
  printf '%s' "${n:-0}"
}

# Run one hook against this repo's own tree with the shim in front of PATH, and leave the
# tally in $COUNT for spawns_of to read.
run_hook() {
  local hook="$1" payload="$2"
  : > "$COUNT"
  printf '%s' "$payload" \
    | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/scripts/$hook" \
      > "$WORK/out.json" 2> /dev/null
}

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  local l
  for l in "$@"; do echo "    $l"; done
}

FILE_PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"scripts/common.sh"}}'
PROMPT_PAYLOAD='{"prompt":"how does rebuild-tsv work"}'
SESSION_PAYLOAD='{"session_id":"jit-spawn-probe"}'

echo "=== control: the shim sees the hooks fork at all ==="
# Every assertion below is a count that must be ZERO, and zero is what "the hook stopped
# forking that" looks like AND what "the shim was never in front of PATH", "the hook never
# ran" and "the payload was malformed" look like. So this control comes first and the suite
# stops here: awk IS the matcher, so a hook that answered anything at all ran one.
run_hook pre-path-hook.sh "$FILE_PAYLOAD"
if [ "$(spawns_of awk)" -ge 1 ]; then
  pass "the shim counted the matcher's own awk"
else
  fail "the shim counted the matcher's own awk" \
    "counted: $(wc -l < "$COUNT" | tr -d '[:space:]') spawn(s), none of them awk" \
    "every zero-count assertion below would be vacuous, so this suite stops here" \
    "shimmed:$SHIMMED"
  echo ""
  echo "========================"
  echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
  echo "========================"
  exit 1
fi
# Second half of the same control: the hook has to have actually answered. A hook that
# fell over early still runs one awk on its way past.
if [ -s "$WORK/out.json" ]; then
  pass "control: the hook produced a verdict"
else
  fail "control: the hook produced a verdict" "empty output -- nothing below is evidence"
fi

echo ""
echo "=== no hook resolves its own directory by forking dirname ==="
# `$(dirname "$0")` at the top of every hook, and `$(dirname "${BASH_SOURCE[0]}")` in
# common.sh for host.sh. Two forks on every invocation of every hook, on every platform,
# for a string operation bash does natively. Parameter expansion has to carry the
# no-slash case explicitly -- `${0%/*}` returns $0 unchanged when there is no slash to
# strip, where dirname returns "." -- which is what the section below this one checks.
for h in pre-path-hook pre-tool-hook pre-prompt-hook session-start-hook post-tool-hook stop-hook; do
  case "$h" in
    pre-prompt-hook) p="$PROMPT_PAYLOAD" ;;
    session-start-hook) p="$SESSION_PAYLOAD" ;;
    *) p="$FILE_PAYLOAD" ;;
  esac
  run_hook "$h.sh" "$p"
  n=$(spawns_of dirname)
  if [ "$n" -eq 0 ]; then
    pass "$h.sh forks no dirname"
  else
    fail "$h.sh forks no dirname" "counted $n"
  fi
done

echo ""
echo '=== SCRIPT_DIR still resolves, with and without a slash in $0 ==='
# The whole risk of the change above. Driven against a real hook rather than asserted
# about the expansion in the abstract: a SCRIPT_DIR that resolved to the wrong place would
# fail to source common.sh, and the hook would answer nothing -- which reads exactly like
# a clean miss.
OUT_ABS=$(printf '%s' "$FILE_PAYLOAD" \
  | CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/scripts/pre-path-hook.sh" 2> /dev/null)
if grep -q "hooks.md" <<< "$OUT_ABS"; then
  pass 'an absolute $0 still finds common.sh and the tree'
else
  fail 'an absolute $0 still finds common.sh and the tree' "got: ${OUT_ABS:0:200}"
fi

# The no-slash case: $0 is a bare filename, which is what a hook invoked from inside its
# own directory gets. dirname answers "."; `${0%/*}` answers the filename itself, which
# would make SCRIPT_DIR a path that is not a directory at all.
OUT_BARE=$(cd "$REPO/scripts" && printf '%s' "$FILE_PAYLOAD" \
  | CLAUDE_PROJECT_DIR="$REPO" bash pre-path-hook.sh 2> /dev/null)
if grep -q "hooks.md" <<< "$OUT_BARE"; then
  pass 'a bare $0 with no slash still finds common.sh and the tree'
else
  fail 'a bare $0 with no slash still finds common.sh and the tree' "got: ${OUT_BARE:0:200}"
fi

echo ""
echo "=== the clock is read by a builtin where the shell has one ==="
# _ms() and _ts() in common.sh each fork perl. Three forks per hook invocation: T_START,
# T_END and the log timestamp. $EPOCHREALTIME is a bash 5.0 builtin that answers both
# without a process -- Git Bash ships 5.2 and Linux CI runs 5.x, so the two legs where a
# spawn is expensive lose all three. macOS ships bash 3.2, which has no such variable, and
# keeps the perl path: that is a fallback, not a failure, and it is asserted separately
# below rather than left as the only tested path.
if [ -n "${EPOCHREALTIME:-}" ]; then
  : > "$COUNT"
  ms=$(PATH="$SHIM:$PATH" bash -c ". \"$REPO/scripts/common.sh\" 2>/dev/null; _ms")
  if [ "$(spawns_of perl)" -eq 0 ]; then
    pass '_ms forks no perl on a bash with $EPOCHREALTIME'
  else
    fail '_ms forks no perl on a bash with $EPOCHREALTIME' "counted $(spawns_of perl)"
  fi
  case "$ms" in
    '' | *[!0-9]*) fail "_ms answers whole milliseconds" "got: ${ms:-<nothing>}" ;;
    *) pass "_ms answers whole milliseconds" ;;
  esac

  : > "$COUNT"
  ts=$(PATH="$SHIM:$PATH" bash -c ". \"$REPO/scripts/common.sh\" 2>/dev/null; _ts")
  if [ "$(spawns_of perl)" -eq 0 ]; then
    pass '_ts forks no perl on a bash with $EPOCHREALTIME'
  else
    fail '_ts forks no perl on a bash with $EPOCHREALTIME' "counted $(spawns_of perl)"
  fi
  if [[ "$ts" =~ ^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9]$ ]]; then
    pass "_ts answers HH:MM:SS.mmm"
  else
    fail "_ts answers HH:MM:SS.mmm" "got: ${ts:-<nothing>}"
  fi
else
  echo "  SKIPPED: this bash has no \$EPOCHREALTIME (${BASH_VERSION:-unknown})."
  echo "           The builtin path went untested here. It is the path Git Bash and"
  echo "           Linux CI take, so it is covered on those legs and not on this one."
fi

echo ""
echo "=== ...and the perl fallback still answers when it does not ==="
# The other half, and it is not optional: every failure path in a hook must exit 0 saying
# nothing, so a clock that answered nothing on bash 3.2 would degrade silently into
# timings that read as 0ms rather than as unmeasured. Forced by unsetting the variable,
# which is deterministic on any bash -- on 3.2 this is simply the only path there is.
fb_ms=$(bash -c "unset EPOCHREALTIME; . \"$REPO/scripts/common.sh\" 2>/dev/null; _ms")
case "$fb_ms" in
  '' | *[!0-9]*) fail '_ms answers with no $EPOCHREALTIME' "got: ${fb_ms:-<nothing>}" ;;
  *) pass '_ms answers with no $EPOCHREALTIME' ;;
esac
fb_ts=$(bash -c "unset EPOCHREALTIME; . \"$REPO/scripts/common.sh\" 2>/dev/null; _ts")
if [[ "$fb_ts" =~ ^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9]$ ]]; then
  pass '_ts answers HH:MM:SS.mmm with no $EPOCHREALTIME'
else
  fail '_ts answers HH:MM:SS.mmm with no $EPOCHREALTIME' "got: ${fb_ts:-<nothing>}"
fi

echo ""

echo ""
echo '=== the builtin clock arithmetic, driven with a frozen $EPOCHREALTIME ==='
# This machine's bash is 3.2 and has no $EPOCHREALTIME, so the section above skips and the
# builtin path would otherwise ship having never been executed anywhere a human watched.
# What bash contributes is a variable holding `<seconds>.<microseconds>`; what THIS
# repository contributes is the conversion, and that half is exercisable on any bash by
# setting the variable to a literal. A frozen clock is not a substitute for the real one
# -- it says nothing about whether bash 5 populates the variable, which is bash's job --
# but it is the difference between an untested conversion and an untested builtin.
#
# $EPOCHREALTIME is DYNAMIC on the bash that has it: bash regenerates the value on every
# read, so an assignment does not stick and `EPOCHREALTIME=1000000000.5` is followed
# immediately by the real clock. That is not a detail -- it means the frozen-clock checks
# below can only run on a bash where the variable is an ordinary one, which is exactly the
# bash that does NOT take the builtin path. So they test the conversion on the platform
# that does not use it. The arithmetic is the same code, so that is worth having; it is
# not the same claim, and the skip below says so rather than reading as coverage.
#
# Found by CI, not here. This section passed on the bash 3.2 it was written against and
# failed on both other legs, reporting the real clock as a wrong conversion -- a false red
# in the suite whose whole job is catching false greens.
#
# Probed rather than gated on a version number: assign a known value and read it back.
frozen_probe=$(bash -c 'EPOCHREALTIME=1000000000.500000; printf %s "$EPOCHREALTIME"')
if [ "$frozen_probe" != "1000000000.500000" ]; then
  echo "  SKIPPED: \$EPOCHREALTIME is dynamic on this bash (${BASH_VERSION:-unknown}), so it"
  echo "           cannot be frozen and the conversion cannot be driven against a known"
  echo "           value here. Covered on a bash where the variable is an ordinary one."
else
  # 1000000000.500000 is 1000000000500 ms exactly. A conversion that truncated the
  # fractional part, multiplied in the wrong order, or lost a leading zero in the
  # microseconds field lands on a different number, and each of those is a real way to get
  # this wrong in shell arithmetic.
  frozen_ms=$(bash -c "EPOCHREALTIME=1000000000.500000; . \"$REPO/scripts/common.sh\" 2>/dev/null; _ms")
  if [ "$frozen_ms" = "1000000000500" ]; then
    pass 'the builtin path converts $EPOCHREALTIME to whole milliseconds'
  else
    fail 'the builtin path converts $EPOCHREALTIME to whole milliseconds' \
      "expected 1000000000500, got: ${frozen_ms:-<nothing>}"
  fi

  # A microsecond field with leading zeros. `10#` is what stops bash reading 040000 as
  # octal, and octal is the failure that produces a plausible wrong number rather than an
  # error -- 040000 base 8 is 16384, so this would answer ...016 instead of ...040.
  frozen_ms=$(bash -c "EPOCHREALTIME=1000000000.040000; . \"$REPO/scripts/common.sh\" 2>/dev/null; _ms")
  if [ "$frozen_ms" = "1000000000040" ]; then
    pass 'a microsecond field with leading zeros is not read as octal'
  else
    fail 'a microsecond field with leading zeros is not read as octal' \
      "expected 1000000000040, got: ${frozen_ms:-<nothing>}"
  fi

  # A locale whose decimal separator is a comma. bash writes $EPOCHREALTIME through the
  # locale, so on a fr_FR session the variable reads `1000000000,500000` -- and a split on
  # "." then hands the whole string to arithmetic and fails. The hooks already pin LC_ALL=C
  # around every awk for the same class of reason.
  frozen_ms=$(bash -c "EPOCHREALTIME=1000000000,500000; . \"$REPO/scripts/common.sh\" 2>/dev/null; _ms")
  case "$frozen_ms" in
    '' | *[!0-9]*) fail 'a comma decimal separator still answers whole milliseconds' \
      "got: ${frozen_ms:-<nothing>}" ;;
    *) pass 'a comma decimal separator still answers whole milliseconds' ;;
  esac
fi

echo "=== no hook puts a cat in front of something that reads stdin itself ==="
# Four hooks opened with `cat | awk` (or `cat | jit_path_awk`, a two-line wrapper around
# one). awk reads stdin perfectly well by itself, and pre-path-hook.sh already calls that
# same wrapper with no cat elsewhere in the file, so the fork bought nothing anywhere.
#
# post-tool-hook.sh is pinned at ONE rather than zero, and the one it keeps is a different
# question: `PT_FP="$(cat)"` reads whatever remains of the parsed here-string, and its own
# comment says why it is last on the line -- file_path is free text that may carry a real
# newline, so it is read with no shape assumed. `read -r -d ""` is not a drop-in for that:
# it stops at the first NUL byte where command substitution drops it and reads on, and
# this repository has a suite about exactly that difference.
#
# Exact counts, never upper bounds. A floor of 1 is also satisfied by the wrong 1, and a
# bound alone lets a new fork in unnoticed.
for h in pre-path-hook pre-tool-hook pre-prompt-hook session-start-hook post-tool-hook stop-hook; do
  case "$h" in
    pre-prompt-hook) p="$PROMPT_PAYLOAD" ;;
    session-start-hook) p="$SESSION_PAYLOAD" ;;
    *) p="$FILE_PAYLOAD" ;;
  esac
  case "$h" in
    post-tool-hook)
      want=1
      why=" (the free-text field, deliberately)"
      ;;
    *)
      want=0
      why=""
      ;;
  esac
  run_hook "$h.sh" "$p"
  n=$(spawns_of cat)
  if [ "$n" -eq "$want" ]; then
    pass "$h.sh forks cat $want time(s)$why"
  else
    fail "$h.sh forks cat $want time(s)$why" "counted $n, expected $want"
  fi
done

echo ""
echo "=== no hook forks a text tool to slice a string it already holds ==="
# sed, tr and wc reading a variable the shell is already holding. bash slices, substitutes
# and counts natively, and each of these is one fork on a path that runs per tool call.
#
# session-start-hook.sh is NOT in this list, and the reason is not that it is clean: it
# spawns wc, tr and tail today. They come from jit-misses.sh, a separate script it invokes,
# and session-start runs ONCE per session rather than once per tool call -- so those forks
# are not on the hot path, and rewriting a build tool to save three of them on one
# invocation is a change with more risk in it than value. Named here rather than left out
# silently, because a hook missing from a list reads exactly like a hook that passed.
for h in pre-path-hook pre-tool-hook pre-prompt-hook post-tool-hook stop-hook; do
  case "$h" in
    pre-prompt-hook) p="$PROMPT_PAYLOAD" ;;
    *) p="$FILE_PAYLOAD" ;;
  esac
  run_hook "$h.sh" "$p"
  for t in sed tr wc; do
    n=$(spawns_of "$t")
    if [ "$n" -eq 0 ]; then
      pass "$h.sh forks no $t"
    else
      fail "$h.sh forks no $t" "counted $n"
    fi
  done
done

# stop-hook.sh's two seds were `sed -n 1p` and `sed -n 2p` over its own two-line awk
# output, replaced by two `read`s. That the fields still ARRIVE is not asserted here, and
# deliberately so: an attempt at it in this file was written, went red, and was removed
# rather than weakened. Driving the hook with stop_hook_active true and then false gives
# the same empty JSON either way unless the session has fired-entry state on disk, so the
# "control" comparing the two answers was measuring nothing and reported it as a defect in
# a change that had none.
#
# tests/test-stop-hook.sh is where that behaviour is already proven, and it proves it
# properly -- it builds the fired-entry state first, so its false branch has something to
# report and the true branch's silence means something. Its sections A, I, J, K, L, M and P
# drive both fields, including the key missing entirely and a raw NUL placed ahead of it.
# A second, weaker copy of that here would be a green line nobody could rely on.

echo ""
echo "=== jit_path_dir / jit_path_base answer without a fork of any kind ==="
# The factored replacements for `$(dirname X)` and `$(basename X)`. They assign into a
# NAMED VARIABLE rather than printing, and that is the whole point: `$(jit_path_dir "$x")`
# would still fork a subshell to capture the output -- cheaper than fork+exec of
# /usr/bin/dirname, but not free, and a fork is exactly what is expensive on the leg this
# is about. `printf -v` writes the answer in the caller's own shell. It is bash 3.2, so
# there is no version gate here and no fallback to keep working.
# shellcheck disable=SC1090
. "$REPO/scripts/common.sh" 2> /dev/null

check_split() {
  local desc="$1" input="$2" want_dir="$3" want_base="$4" got_dir="" got_base=""
  jit_path_dir got_dir "$input"
  jit_path_base got_base "$input"
  if [ "$got_dir" = "$want_dir" ] && [ "$got_base" = "$want_base" ]; then
    pass "$desc"
  else
    fail "$desc" \
      "input:    $input" \
      "dir:      got '$got_dir', want '$want_dir'" \
      "base:     got '$got_base', want '$want_base'"
  fi
}

# Every case dirname and basename disagree with naive parameter expansion on. `${x%/*}`
# returns x UNCHANGED with no slash, and `${x##*/}` returns "" on a trailing slash -- both
# are wrong answers that look like right ones.
check_split "an ordinary path" "a/b/c.md" "a/b" "c.md"
check_split "no slash at all" "c.md" "." "c.md"
check_split "one leading slash" "/c.md" "" "c.md"
check_split "an absolute path" "/a/b/c.md" "/a/b" "c.md"
check_split "a path with a space" "a b/c d.md" "a b" "c d.md"
check_split "a dot directory" "./c.md" "." "c.md"

# Positive control on the helpers themselves: the two above are only meaningful if the
# functions exist. An unsourced or renamed helper leaves both variables at "" and would
# score the no-slash case as a pass on emptiness.
if [ "$(type -t jit_path_dir)" = function ] && [ "$(type -t jit_path_base)" = function ]; then
  pass "control: both helpers are defined by common.sh"
else
  fail "control: both helpers are defined by common.sh" \
    "every split assertion above passed on emptiness"
fi

echo ""
echo "=== jit-dry-run.sh forks no dirname, basename or tr over this repo's own tree ==="
# 346 external commands for one bare lint of a 17-entry tree, and 121 of them were dirname
# and basename -- `$(basename "$(dirname "$tsv")")` is two forks, per index file, per
# dimension, per layer. Another 16 were `tr -d ' '` cleaning up after `wc -c`, which
# arithmetic expansion does for nothing.
#
# This is the tool CI runs over a whole tree and the one tests/test-dogfood-entries.sh
# calls, so its fork count is paid by every author on every run, not once.
: > "$COUNT"
(cd "$REPO" && PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$REPO" \
  bash "$REPO/scripts/jit-dry-run.sh" > "$WORK/lint.out" 2>&1)
lint_rc=$?

# Control first, again: a lint that did not run forks nothing and would pass every count
# below it. awk is the tool's actual work and it runs well over a hundred of them.
if [ "$(spawns_of awk)" -ge 10 ] && [ -s "$WORK/lint.out" ]; then
  pass "control: the lint ran and did its awk work (exit $lint_rc)"
else
  fail "control: the lint ran and did its awk work" \
    "exit $lint_rc, $(spawns_of awk) awk spawn(s), $(wc -c < "$WORK/lint.out" | tr -d '[:space:]') bytes of report" \
    "the counts below would be vacuous"
fi

for t in dirname basename; do
  n=$(spawns_of "$t")
  if [ "$n" -eq 0 ]; then
    pass "jit-dry-run.sh forks no $t"
  else
    fail "jit-dry-run.sh forks no $t" "counted $n"
  fi
done

# tr had TWO sources here and only one of them is version-dependent:
#
#   * `wc -c < "$md" | tr -d ' '`, one per whole-body entry, stripping the padding some wc
#     implementations add. `$(( ))` discards that for nothing, on every bash.
#   * the lowercase fold at the `inject:` column, two per row. `${var,,}` is bash 4, so on
#     the bash macOS ships this one legitimately stays.
#
# A count cannot tell the two apart, so this is asserted where it CAN be answered -- on a
# bash with the builtin, where both sources are gone and the only honest number is zero.
# An attempt to assert it version-independently (tr must not outnumber wc) was written and
# removed: it is arithmetic that happens to hold on one platform, not a statement about
# either source, and on bash 3.2 it is false while nothing is wrong.
# One tr is legitimate and stays: `tr '\t' '\002'` converts the index's tabs to STX before
# the row loop reads it, because bash `read` treats a tab in IFS as IFS WHITESPACE and
# collapses a run of them whatever IFS is set to (#203). It is one process per index loop,
# not per row, and it is the reason this is a ceiling rather than a floor of zero. CI is
# what established the number: the first version of this assertion demanded zero, and the
# two legs with the fold builtin reported the two STX conversions as a defect.
IDX_FILES=$(find "$REPO/.claude/jit-context" -name 00-index.tsv 2> /dev/null | grep -c . | tr -d '[:space:]')
tr_n=$(spawns_of tr)
wc_n=$(spawns_of wc)
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  if [ "$tr_n" -le "${IDX_FILES:-0}" ]; then
    pass "jit-dry-run.sh forks tr at most once per index file ($tr_n over ${IDX_FILES:-?}, wc=$wc_n)"
  else
    fail "jit-dry-run.sh forks tr at most once per index file" \
      "counted $tr_n over ${IDX_FILES:-?} index file(s), wc=$wc_n" \
      "one per index is the STX conversion (#203); anything above that is the wc padding" \
      "strip or the inject fold still forking"
  fi
else
  echo "  SKIPPED: this bash is ${BASH_VERSION:-unknown}, so the inject fold still forks tr"
  echo "           by design (two per row) and a count cannot separate it from the wc"
  echo "           padding strip or the per-index STX conversion."
  echo "           Untested here: that the wc strip is gone. Covered on the Linux and"
  echo "           Windows legs, where the fold is a builtin and the only tr left is the"
  echo "           one STX conversion per index file."
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
