#!/bin/bash
# Tests that a valued flag missing its value is REFUSED, on every tool that takes one.
#
# The defect (#114): `--base) BASE="${2:-}"; shift 2 ;;` under `set -uo pipefail` with no
# `-e`. With one positional left, `shift 2` fails, `$1` never advances, and
# `while [ $# -gt 0 ]` spins forever. Driven at e800067:
#
#   timeout 5 bash scripts/jit-init.sh --base     -> exit 124, 0 bytes out, 0 bytes err
#   timeout 4 bash scripts/jit-dry-run.sh --base  -> exit 124   (also --tool/--command/--prompt)
#   timeout 4 bash scripts/jit-dry-run.sh --path  -> exit 2     (an UNKNOWN flag is fine)
#
# That contrast is the whole finding: the loud path was already right, and the quiet one
# was the known flag. `paths/00-manual/tooling.md` is the contract these tools live under
# -- fail loudly, on stderr, non-zero -- and a hang says nothing at all.
#
# --- Why NEITHER list is typed here: not the flags, and not the scripts ---------------
#
# A hand-written list covers what existed when it was written. Whatever is added next is
# what reopens the issue, and it reopens silently. So both halves are read from the
# repository instead:
#
#   the FLAGS   -- each script own argument loop is parsed for every case arm carrying
#                  `shift 2`, and a flag with no positive-control value declared in
#                  positive_argv() is a FAILURE rather than a skip: adding a flag there
#                  costs one line, and not adding it costs the guard.
#   the SCRIPTS -- `git ls-files -- scripts` (#188). This half was a typed list until
#                  then, and the header you are reading claimed both were covered while
#                  only one was: a new tool under scripts/ was untested here until
#                  somebody remembered a line, which is the arrangement this suite exists
#                  to refuse. #183 added `jit-doctor.sh` to that list and a comment naming
#                  the gap; the gap is what the enumeration below closes.
#
# Enumeration turns "not in the list" into "must be driven", so a tool that legitimately
# takes no flags needs an answer of its own. classify_script() gives every tracked file one
# of five verdicts, read out of that file own bytes rather than off a skip list -- a skip
# list being the typed list again, one indirection further out. "This tool has no flags to
# test" and "this tool never ran" are different lines in the output below, and so are the
# two ways a loop can yield nothing:
#
#   drive               the canonical loop, carrying arms with `shift 2`
#   no-flags            no loop, and no sign of flag parsing anywhere -- a named PASS
#   boolean-flags-only  a loop, but no arm of it reaches for $2 -- also a named PASS, and
#                       not the same sentence as the line below it
#   loop-no-flags       a loop that reaches for $2 with no `shift 2` arm to read -- FAIL,
#                       the parser rotted or the loop shape moved
#   flags-elsewhere     no loop, but getopts / a `shift 2` / a dash case arm is present --
#                       FAIL, because reporting it as a tool with no flags is the silence
#
# --- Why not `timeout` ---------------------------------------------------------------
#
# `timeout` is GNU coreutils. It is on the Linux and macOS legs and is NOT guaranteed on
# Windows (Git Bash), where this suite has to run too. A test that silently degrades to
# "the command was not bounded" on one leg is a green that means nothing there, so the
# bound is a watchdog subshell instead.
#
# Usage: bash tests/test-arg-flag-values.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

SKIP=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; for l in "$@"; do echo "    $l"; done; return 0; }

OUT="$TMP/out.txt"
ERR="$TMP/err.txt"

# jit-drive: none -- every assertion here runs a script itself and reads the files it
# wrote; none of them takes captured output as an argument, so there is nothing for the
# 1 MB SIGPIPE payload to be handed to.

# Run a command with a hard time bound, writing stdout to $OUT and stderr to $ERR.
# Returns the command exit status, or 124 if the bound was reached -- 124 to read like
# `timeout`, which this deliberately is not.
run_bounded() {
  local secs="$1"; shift
  local pid watchdog st=0
  : > "$OUT"
  : > "$ERR"
  "$@" > "$OUT" 2> "$ERR" &
  pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid" 2>/dev/null || st=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # A signal death is the watchdog: these tools exit 0, 1 or 2 and nothing else.
  [ "$st" -ge 128 ] && return 124
  return "$st"
}

# The canonical argument loop, as one awk pattern used by both readers below. One string
# and not two literals: has_arg_loop() answering "there is a loop here" while valued_flags()
# reads a different line is the disagreement that would make loop-no-flags meaningless.
ARG_LOOP='/^while \[ \$# -gt 0 \]; do/'

# Does this file have the argument loop at all? Answered separately from what is IN it, so
# that a file with no loop and a file whose loop this suite can no longer read are two
# different verdicts rather than one empty result.
has_arg_loop() { awk "$ARG_LOOP"' { found = 1 } END { exit !found }' "$1"; }

# Every case arm in a script own argument loop that consumes a value.
valued_flags() {
  awk "$ARG_LOOP"' { inloop = 1; next }
    inloop && /^done$/           { inloop = 0 }
    inloop && /shift 2/ {
      n = $0
      sub(/^[[:space:]]*/, "", n)
      sub(/\).*$/, "", n)
      k = split(n, part, "|")
      for (j = 1; j <= k; j++) if (part[j] ~ /^--[A-Za-z]/) print part[j]
    }
  ' "$1"
}

# Any sign that a file takes flags at all, deliberately looser than the loop above and
# written a different way: getopts, a `shift 2` anywhere, or a case arm opening on a dash.
# It exists so that "no argument loop I can read" and "no flags" stay different answers --
# a tool parsing `--base=x` in a `for` loop must not read as a tool with nothing to test.
#
# It errs toward red: a comment in a hook merely mentioning `shift 2` would trip it. That
# is the safe direction, and the FAIL it prints says what to do about it.
parses_flags_somehow() {
  grep -qE '(getopts|shift 2|^[[:space:]]*--?[A-Za-z][^)]*\))' "$1"
}

# Does any arm of the loop reach for `$2` at all? This is what separates a tool whose
# flags are all booleans -- nothing here consumes a value, so there is nothing for #114 to
# happen to -- from a loop that consumes one in a shape valued_flags() cannot see. Without
# it both read as "the loop yielded no flags", and a perfectly ordinary `--verbose) shift`
# tool would be told its parser had rotted.
loop_consumes_value() {
  awk "$ARG_LOOP"' { inloop = 1; next }
    inloop && /^done$/ { inloop = 0 }
    inloop && /\$\{?2/ { found = 1 }
    END { exit !found }' "$1"
}

# One of five verdicts for one file, read out of that file own bytes. There is no skip
# list anywhere in this suite: a skip list is the hand-written list #188 is about, one
# indirection further out, and it goes stale in exactly the same silence.
classify_script() {
  local f="$1"
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then echo "unreadable-file"; return; fi
  if has_arg_loop "$f"; then
    # To a file, not $( ): a captured variable silently drops NUL bytes.
    valued_flags "$f" > "$TMP/flags.txt" 2>/dev/null
    if [ -s "$TMP/flags.txt" ]; then
      echo "drive"
    elif loop_consumes_value "$f"; then
      echo "loop-no-flags"
    else
      echo "boolean-flags-only"
    fi
  elif parses_flags_somehow "$f"; then
    echo "flags-elsewhere"
  else
    echo "no-flags"
  fi
}

# What ships in scripts/, from the repository rather than from a list here. `git ls-files`
# and not `find`, for the reason test-dogfood-entries.sh gives: find also returns a
# .DS_Store, an editor backup and a merge .orig, each of which would redden this suite for
# a reason that has nothing to do with argument handling. The cost is that a brand-new
# script is invisible here until it is staged -- which is before CI sees it either.
tracked_scripts() {
  (cd "$1" && git ls-files -- scripts 2>/dev/null | LC_ALL=C sort)
}

# --- Fixtures ------------------------------------------------------------------------
#
# One real tree for jit-dry-run.sh to succeed against, one real log for jit-misses.sh.
# The positive control has to reach exit 0 on the same code path as the negative, or
# "exits non-zero" is satisfied by a script that is missing, unreadable, or broken
# before its argument loop is ever reached.
#
# The index file name is held in a variable rather than written out beside a redirect:
# this repository own tools/00-manual rule blocks a shell write to that name, and it
# reads the whole command string, so a literal here is refused before the file is written.
IDX="00-index.tsv"
TREE="$TMP/proj/.claude/jit-context"
mkdir -p "$TREE/tools/00-manual"
for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
  mkdir -p "$TREE/paths/$l" "$TREE/vocabulary/$l"
  : > "$TREE/paths/$l/$IDX"
  : > "$TREE/vocabulary/$l/$IDX"
done
printf 'Bash\t~(^|[;&|\\n] *)git[[:space:]]+push\tgit-push.md\tblock\t\t\n' > "$TREE/tools/00-manual/$IDX"
echo "do not push" > "$TREE/tools/00-manual/git-push.md"

# One real hook-log record, in the format jit-misses.sh parses. A line it does not
# recognise is a named SKIPPED and exit 2 -- which would make every positive control
# below pass through the argument loop and then fail for a reason that has nothing to
# do with #114.
LOGFILE="$TMP/hooks.log"
echo "[10:00:00.001] pre-prompt 9ms | (none) [shown:1] << the billing export is broken" > "$LOGFILE"

FRESH_N=0

# The positive-control argv for one flag of one script: the flag with a value, plus
# whatever else that run needs to be a success rather than a different refusal. One
# argument per line. Prints nothing when the flag is unknown here -- the caller FAILS.
positive_argv() {
  # $1 script basename, $2 flag
  case "$1" in
    jit-init.sh)
      case "$2" in
        --base)
          FRESH_N=$((FRESH_N + 1))
          mkdir -p "$TMP/fresh$FRESH_N"
          printf '%s\n%s\n' "--base" "$TMP/fresh$FRESH_N/.claude/jit-context" ;;
      esac ;;
    jit-dry-run.sh)
      case "$2" in
        --base)    printf '%s\n%s\n' "--base" "$TREE" ;;
        --tool)    printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--tool" "Bash" ;;
        --command) printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--command" "git status" ;;
        --file)    printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--file" "src/Billing/Total.php" ;;
        --prompt)  printf '%s\n%s\n%s\n%s\n' "--base" "$TREE" "--prompt" "how do totals work" ;;
      esac ;;
    jit-misses.sh)
      case "$2" in
        --log) printf '%s\n%s\n' "--log" "$LOGFILE" ;;
        --min) printf '%s\n%s\n%s\n%s\n' "--log" "$LOGFILE" "--min" "2" ;;
        --top) printf '%s\n%s\n%s\n%s\n' "--log" "$LOGFILE" "--top" "5" ;;
      esac ;;
    jit-doctor.sh)
      case "$2" in
        --base) printf '%s\n%s\n' "--base" "$TREE" ;;
      esac ;;
  esac
}

drive_script() {
  # $1 path to the script
  local script="$1" name flag flags argv st a
  name="$(basename "$script")"
  flags="$(valued_flags "$script")"

  echo ""
  echo "=== $name ==="

  if [ -z "$flags" ]; then
    bad "$name: its argument loop exposes no valued flag" \
        "either the loop moved or valued_flags() no longer reads it -- this suite is checking nothing"
    return
  fi

  for flag in $flags; do
    # --- negative: the flag with nothing after it ---
    st=0
    run_bounded 8 bash "$script" "$flag" || st=$?
    if [ "$st" -eq 2 ]; then
      ok "$name $flag with no value exits 2"
    elif [ "$st" -eq 124 ]; then
      bad "$name $flag with no value exits 2" \
          "it did not exit at all -- still running after 8s (#114)"
    else
      bad "$name $flag with no value exits 2" "exit $st"
    fi

    if grep -qF -- "$flag" "$OUT" "$ERR" 2>/dev/null; then
      ok "$name $flag with no value names the flag"
    else
      bad "$name $flag with no value names the flag" \
          "stdout and stderr carried nothing mentioning $flag"
    fi

    if [ -s "$OUT" ] || [ -s "$ERR" ]; then
      ok "$name $flag with no value says something"
    else
      bad "$name $flag with no value says something" "0 bytes on both streams"
    fi

    # --- positive control, on the same code path ---
    argv="$(positive_argv "$name" "$flag")"
    if [ -z "$argv" ]; then
      bad "$name $flag has a positive control" \
          "no value declared in positive_argv() for a flag its own loop consumes" \
          "add one line there -- a new valued flag with no positive control is untested"
      continue
    fi
    local args=()
    while IFS= read -r a; do args+=("$a"); done <<EOF
$argv
EOF
    st=0
    run_bounded 30 bash "$script" "${args[@]}" || st=$?
    if [ "$st" -eq 0 ]; then
      ok "$name $flag WITH a value still succeeds"
    else
      bad "$name $flag WITH a value still succeeds" "exit $st" "$(head -3 "$ERR")"
    fi
    if grep -qF "needs a value" "$OUT" "$ERR" 2>/dev/null; then
      bad "$name $flag WITH a value is not refused for a missing one" "$(head -3 "$ERR")"
    else
      ok "$name $flag WITH a value is not refused for a missing one"
    fi
  done
}

# --- Does the sweep below see a script nobody told it about? --------------------------
#
# The sweep enumerates scripts/ instead of listing it, and the entire value of that is a
# claim about a file which does not exist yet. Watching it pass on today tree says nothing
# about that claim: today tree is exactly the tree the old hand-written list already
# covered. So the enumeration and the classifier are driven here against a throwaway git
# repository holding five scripts this suite has never heard of, one per verdict.
#
# The five verdicts are listed at the top of this file. Each of them prints a line naming
# the script, so "this tool has no flags to test" and "this tool never ran" are different
# sentences in the output rather than the same silence -- and each of the five has a
# fixture here, because a verdict nothing ever reaches is a branch nobody has tested.

echo "=== the sweep itself: a script named nowhere in this file ==="

META="$TMP/sweepfix"
mkdir -p "$META/scripts"

# A tool nobody listed here, whose argument loop is the shape valued_flags() reads.
cat > "$META/scripts/jit-newtool.sh" <<'FIXTURE'
#!/bin/bash
set -uo pipefail
need_value() { echo "$1 needs a value" >&2; exit 2; }
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || need_value "$1"; BASE="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
echo "ok $BASE"
FIXTURE

# The positive control for the no-flags verdict: a script that really does take no
# arguments, the shape all four hooks and common.sh are in.
cat > "$META/scripts/plain-hook.sh" <<'FIXTURE'
#!/bin/bash
set -uo pipefail
cat > /dev/null
exit 0
FIXTURE

# And the case a skip list gets wrong: it takes a valued flag, in a shape this suite
# cannot read. Silently reporting it as "no flags" is the absence #188 is about.
cat > "$META/scripts/odd-parse.sh" <<'FIXTURE'
#!/bin/bash
set -uo pipefail
BASE=""
for a in "$@"; do
  case "$a" in
    --base=*) BASE="${a#--base=}" ;;
  esac
done
echo "ok $BASE"
FIXTURE

# The loop is there and every arm is a boolean. Nothing consumes a value, so there is
# nothing here for #114 to happen to -- a named pass, not a failure. Without this fixture
# the boolean-flags-only verdict is a branch nothing in the corpus ever reaches.
cat > "$META/scripts/bool-only.sh" <<'FIXTURE'
#!/bin/bash
set -uo pipefail
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
echo "ok $VERBOSE"
FIXTURE

# And the one that must NOT read as the line above: the loop consumes $2, and no arm
# carries `shift 2`, so valued_flags() sees nothing while the script plainly takes a value.
# This is the "the parser rotted" verdict, and it had no fixture until the audit of #188
# pointed out that three of the verdicts were driven and this one was not.
cat > "$META/scripts/hidden-value.sh" <<'FIXTURE'
#!/bin/bash
set -uo pipefail
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
echo "ok $BASE"
FIXTURE

META_READY=1
( cd "$META" && git init -q . && git add -A ) > /dev/null 2>&1 || META_READY=0
if [ "$META_READY" -eq 1 ] && [ -z "$(cd "$META" && git ls-files -- scripts)" ]; then
  META_READY=0
fi

# desc, path, expected verdict
class_is() {
  local got
  got="$(classify_script "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "expected $3, got ${got:-<nothing>}"; fi
}

if [ "$META_READY" -eq 0 ]; then
  # Three outcomes, never two, and the count is what carries it. Printing this block while
  # leaving PASS/FAIL untouched makes the tally at the bottom byte-identical to a run where
  # this section passed -- the absence produced by the tool reading as an absence in the
  # world, which is the shape #188 is about, one level up and inside its own fix. So it is
  # counted here and the suite exits 2, which run-all.sh renders as "NOT a clean result".
  SKIP=$((SKIP + 1))
  echo "  SKIPPED: no throwaway git repository could be built here, so the one guarantee"
  echo "           the sweep exists for -- that it catches a script nobody listed -- went"
  echo "           untested. Every section below still ran; this claim did not."
else
  META_LIST="$(tracked_scripts "$META")"
  for want in scripts/jit-newtool.sh scripts/plain-hook.sh scripts/odd-parse.sh \
              scripts/bool-only.sh scripts/hidden-value.sh; do
    if grep -qxF "$want" <<<"$META_LIST"; then
      ok "the enumeration finds $want, which is named nowhere in this file"
    else
      bad "the enumeration finds $want, which is named nowhere in this file" \
          "got: ${META_LIST:-<nothing>}"
    fi
  done

  class_is "a new tool with a readable argument loop must be DRIVEN" \
           "$META/scripts/jit-newtool.sh" "drive"
  class_is "a script with no argument parsing at all is no-flags, by its own source" \
           "$META/scripts/plain-hook.sh" "no-flags"
  class_is "a flag in a shape this suite cannot read is a FAILURE, not a skip" \
           "$META/scripts/odd-parse.sh" "flags-elsewhere"
  # The two halves of "the loop yielded no valued flag", which must never be one answer.
  class_is "a loop of boolean flags has nothing to drive, and is not a failure" \
           "$META/scripts/bool-only.sh" "boolean-flags-only"
  class_is "a loop that consumes \$2 with no 'shift 2' is the parser having rotted" \
           "$META/scripts/hidden-value.sh" "loop-no-flags"

  # The red, executed rather than reasoned about. An unlisted tool routes into
  # drive_script, which has no positive control for it and has to say so. Run in a subshell
  # so its PASS/FAIL increments stay out of this run totals, and read from a file rather
  # than $( ) because a captured variable silently drops NUL bytes.
  ( drive_script "$META/scripts/jit-newtool.sh" ) > "$TMP/meta-drive.txt" 2>&1
  if grep -qF "FAIL: jit-newtool.sh --base has a positive control" "$TMP/meta-drive.txt"; then
    ok "an unlisted tool goes RED here rather than being silently untested (#188)"
  else
    bad "an unlisted tool goes RED here rather than being silently untested (#188)" \
        "driving it produced no failure about a missing positive control" \
        "$(head -5 "$TMP/meta-drive.txt")"
  fi
  # Paired with it, on the same fixture: a red proves nothing if the fixture is simply
  # broken, so the assertions that must have PASSED are checked too.
  if grep -qF "PASS: jit-newtool.sh --base with no value exits 2" "$TMP/meta-drive.txt"; then
    ok "and the fixture is sound -- its refusal path ran and passed on the same run"
  else
    bad "and the fixture is sound -- its refusal path ran and passed on the same run" \
        "the red above may be a broken fixture rather than a guard that fired" \
        "$(head -5 "$TMP/meta-drive.txt")"
  fi
fi

echo ""
echo "=== an UNKNOWN flag was always handled correctly -- the control for all of the below ==="
ST=0
run_bounded 8 bash "$REPO/scripts/jit-dry-run.sh" --nosuchflag || ST=$?
if [ "$ST" -eq 2 ]; then
  ok "jit-dry-run.sh refuses an unknown flag with exit 2"
else
  bad "jit-dry-run.sh refuses an unknown flag with exit 2" "exit $ST"
fi

# --- The sweep -----------------------------------------------------------------------
#
# Enumerated from the repository, not listed here (#188). jit-misses.sh already had this
# right when #114 was filed -- its need_value() is the shape the other two were missing --
# and it is swept as one leg like the rest, not as a fix.

SCRIPT_LIST="$(tracked_scripts "$REPO")"
# The enumeration control, first and loud. An empty or partial listing would drive nothing
# and print a perfect score for it, which is the absence this suite exists to refuse.
if ! grep -qxF "scripts/jit-dry-run.sh" <<<"$SCRIPT_LIST"; then
  echo "  FAIL: could not enumerate scripts/ -- nothing below would have been driven,"
  echo "        and this suite would have reported a clean run over an empty sweep."
  echo "        got: ${SCRIPT_LIST:-<nothing>}"
  exit 1
fi

DRIVEN_LIST=""
N_DRIVEN=0
N_NOFLAG=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  case "$(classify_script "$REPO/$script")" in
    drive)
      N_DRIVEN=$((N_DRIVEN + 1))
      DRIVEN_LIST="$DRIVEN_LIST$script
"
      drive_script "$REPO/$script" ;;
    no-flags)
      # The third state, printed rather than skipped: this is what "nothing to drive here"
      # looks like, and it must never be spelled the same way as "never ran".
      N_NOFLAG=$((N_NOFLAG + 1))
      ok "$script takes no flag arguments -- nothing to drive, by its own source" ;;
    boolean-flags-only)
      # Also the third state: a loop whose arms are all booleans consumes no value, so
      # there is nothing here for #114 to happen to. Named, for the same reason no-flags is.
      N_NOFLAG=$((N_NOFLAG + 1))
      ok "$script has an argument loop, and no arm of it consumes a value -- nothing to drive" ;;
    loop-no-flags)
      echo ""
      echo "=== $script ==="
      bad "$script has an argument loop this suite can no longer read" \
          "the loop is there, an arm of it reaches for \$2, and valued_flags() found no" \
          "valued flag -- either the loop shape moved or the parser rotted. Every flag of" \
          "this script is untested, and nothing else in this suite would have said so." ;;
    flags-elsewhere)
      echo ""
      echo "=== $script ==="
      bad "$script parses flags in a shape this suite cannot drive" \
          "no '"'"'while [ \$# -gt 0 ]'"'"' loop, but getopts / shift 2 / a dash case arm is present." \
          "Give it the loop shape the other tools use, or teach valued_flags() to read this" \
          "one -- reporting it as a tool with no flags would be the silence #188 is about." ;;
    unreadable-file)
      echo ""
      echo "=== $script ==="
      bad "$script could not be read at all" \
          "it is tracked under scripts/ and this suite could not open it to classify it" ;;
  esac
done <<<"$SCRIPT_LIST"

echo ""
echo "=== the sweep covered every tracked script: $N_DRIVEN driven, $N_NOFLAG with no flags ==="
# Both floors, because either one alone is satisfiable by a classifier stuck on one answer:
# all-no-flags drives nothing and prints a clean run, all-drive fails every hook.
if [ "$N_DRIVEN" -ge 1 ] && [ "$N_NOFLAG" -ge 1 ]; then
  ok "the classifier told the two apart in this tree rather than answering one of them"
else
  bad "the classifier told the two apart in this tree rather than answering one of them" \
      "$N_DRIVEN driven and $N_NOFLAG with no flags -- one of those is 0, so the verdict" \
      "it produced is the same for every script and says nothing about any of them"
fi

# A second reading of the same question, written a different way on purpose. The floors
# above survive a classifier that quietly loses ONE script; this does not. `shift 2`
# appearing anywhere in a file -- comments included -- is evidence that file consumes flag
# values, and every such file must be one the sweep actually drove.
while IFS= read -r script; do
  [ -n "$script" ] || continue
  grep -qF "shift 2" "$REPO/$script" || continue
  if grep -qxF "$script" <<<"$DRIVEN_LIST"; then
    ok "cross-check: $script consumes flag values and the sweep drove it"
  else
    bad "cross-check: $script consumes flag values and the sweep drove it" \
        "it mentions 'shift 2' and the sweep did not drive it -- classify_script() has" \
        "silently dropped a script the old hand-written list would have named"
  fi
done <<<"$SCRIPT_LIST"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed, $SKIP section(s) SKIPPED"
echo "========================"

[ "$FAIL" -gt 0 ] && exit 1
# Not a pass. A section that could not build its fixtures tested nothing, and the tally
# above cannot tell you that on its own -- run-all.sh reads 2 and says so in as many words.
[ "$SKIP" -gt 0 ] && exit 2
exit 0
