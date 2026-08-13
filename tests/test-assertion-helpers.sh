#!/bin/bash
# The harness asserting about itself.
#
# Every suite here decides PASS/FAIL by piping the captured output into `grep -q`.
# `grep -q` exits the instant it matches; the writer on the left of the pipe is then
# writing into a closed pipe and takes SIGPIPE; under `set -o pipefail` the pipeline
# status is non-zero. So the helper reports the OPPOSITE of what it found -- but only
# once the output is longer than the pipe buffer, which is exactly when someone is
# already debugging whatever made it long. Issue #56.
#
# Both directions, and the second one is the dangerous half:
#   assert_contains     with a present needle  -> reports FAIL  (false red)
#   assert_not_contains with a present needle  -> reports PASS  (false GREEN)
#
# The writer is not the cause: printf takes the signal exactly as echo does. The cause
# is the early exit on the right.
#
# This suite does not go through a hook. It extracts each suite real helper functions
# and calls them directly with a controlled 1 MB payload, because "long enough to fill
# the pipe buffer" is a platform-dependent number and guessing it per-platform is the
# thing this test exists in order not to do. 1 MB is ~16x the largest pipe buffer any
# of the three CI platforms uses, so the signal is raised on all three or on none.
#
# --- How it picks its subjects, and why not by name (#110) --------------------------
#
# It used to bind on the helper NAME: any `assert_blocked()` it found was driven with
# the signature it assumed, (description, captured-output). That is not the only correct
# signature. `$( )` silently drops NUL bytes, so this repository tells suite authors to
# write hook output to a FILE and assert against the file -- and a helper written that
# way takes a path or a needle, not a captured string. Handed the 1 MB payload as a
# needle, it reported a defect in a file that had none: a false red in the suite whose
# job is to catch false greens.
#
# So a suite now DECLARES what it exposes, one line per drivable helper:
#
#   # jit-drive: <function> <semantic> <source>
#   # jit-drive: none -- <reason this suite exposes nothing payload-shaped>
#
#   <semantic> is what the helper MEANS, not what it is called -- decoupling those two
#              is the whole fix. One of:
#                contains       needle present  -> PASS, absent -> FAIL
#                not_contains   needle absent   -> PASS, present -> FAIL
#                blocked        a block payload -> PASS
#                not_blocked    no block        -> PASS
#                token_row      a matching row  -> PASS
#                no_token_row   a matching row  -> FAIL
#   <source>   is where the helper reads that output from:
#                capture        (desc, OUTPUT, needle)  -- the classic signature
#                file:VAR       (desc, needle), reading the path held in $VAR
#                path-arg       (desc, PATH, needle)
#
# Three outcomes, never two:
#   covered        -- declared, driven, verdict as expected
#   flagged        -- driven and wrong, or declared for a function that is not there
#   not evaluated  -- declared `none`, or a helper the suite never declared
#
# The third is REPORTED, in full, at the bottom of every run. A suite that declares
# nothing at all is a FAILURE, not a silence: escaping coverage by saying nothing is
# this repository own defect class, and the tool built to prevent it does not get to
# have it. Escaping by writing a reason down is fine -- that is a line in a diff someone
# reviews.
#
# The structural scan near the end is name-blind and declaration-blind: it reads every
# file in the directory regardless. No declaration can opt out of it.
#
# Usage:
#   bash tests/test-assertion-helpers.sh
#   bash tests/test-assertion-helpers.sh --subjects DIR    # used by the self-test below

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBJECTS="$TESTS_DIR"
DEFAULT_MODE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --subjects)
      SUBJECTS="${2:-}"
      [ -n "$SUBJECTS" ] || { echo "--subjects needs a directory" >&2; exit 2; }
      DEFAULT_MODE=0
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$SUBJECTS" ] || { echo "no such directory: $SUBJECTS" >&2; exit 2; }

PASS=0
FAIL=0
DROVE=0
NOT_EVALUATED=""
UNDECLARED=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
  FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift
  for l in "$@"; do echo "    $l"; done
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t jit56)"
trap 'rm -rf "$WORK"' EXIT

# --- The payload -------------------------------------------------------------------
#
# The needle is FIRST. grep matches on line 1 and exits immediately, which is the worst
# case for the writer and the one the bug needs.
NEEDLE="NEEDLEXYZ"
ABSENT="ABSENTXYZ"
FILLER="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BIG="$NEEDLE"
i=0
while [ "$i" -lt 15 ]; do
  BIG="$BIG
$FILLER"
  BIG="$BIG$BIG"
  i=$((i + 1))
done
BYTES=${#BIG}
if [ "$BYTES" -lt 1000000 ]; then
  echo "  FAIL: payload is only $BYTES bytes -- too small to raise SIGPIPE reliably"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi
echo "Payload: $BYTES bytes, needle on line 1"

# Row-shaped variants, for the helpers that match a whole line rather than a substring.
TOKEN="tokenxyz"
BIGROW="  2x  $TOKEN
$BIG"
BLOCKLINE=$(printf %s "{" ; printf %s "\"decision\":\"block\"}")
BIGBLOCK="$BLOCKLINE
$BIG"

# The same payloads on disk, for the helpers that read a file rather than a variable.
BIGFILE="$WORK/big.out"
BIGBLOCKFILE="$WORK/bigblock.out"
printf '%s\n' "$BIG" > "$BIGFILE"
printf '%s\n' "$BIGBLOCK" > "$BIGBLOCKFILE"

# --- Driving a real helper ----------------------------------------------------------
#
# Extract every function definition from a suite into a file we can source. Line-range
# extraction on `name() {` .. `}` at column 0, which is how every suite here is
# written. A suite that yields nothing is reported by the DROVE floor below, never
# skipped silently.
extract_funcs() {
  awk '
    /^[a-z_][a-z0-9_]*\(\)/ {
      print
      infunc = ($0 ~ /\}[[:space:]]*$/) ? 0 : 1
      next
    }
    infunc { print }
    /^\}$/ { infunc = 0 }
  ' "$1"
}

# Every assertion-shaped function a suite defines, declared or not.
helper_names() {
  awk '/^(assert|expect)[a-z0-9_]*\(\)/ { n = $0; sub(/\(\).*$/, "", n); print n }' "$1"
}

# The `# jit-drive:` lines, stripped of their prefix.
declarations() {
  awk '
    /^#[[:space:]]*jit-drive:/ {
      sub(/^#[[:space:]]*jit-drive:[[:space:]]*/, "")
      if (length($0)) print
    }
  ' "$1"
}

# Call one helper of one suite in a subshell and report the verdict it printed:
# exactly "PASS", "FAIL" or "ERR". `var`/`path` set the output-file variable that a
# file-reading helper resolves; both are empty for a capture-shaped helper.
verdict() {
  local funcs="$1" fn="$2" var="$3" path="$4"
  shift 4
  (
    set -uo pipefail
    PASS=0
    FAIL=0
    if [ -n "$var" ]; then eval "$var=\$path"; fi
    # shellcheck disable=SC1090
    . "$funcs" 2>/dev/null || { echo ERR; exit 0; }
    "$fn" "$@" >/dev/null 2>&1
    if [ "$PASS" = 1 ] && [ "$FAIL" = 0 ]; then echo PASS
    elif [ "$FAIL" = 1 ] && [ "$PASS" = 0 ]; then echo FAIL
    else echo ERR
    fi
  )
}

# suite, funcs file, helper name, expected verdict, output-var, output-path, then the
# helper own arguments.
check() {
  local suite="$1" funcs="$2" fn="$3" want="$4" var="$5" path="$6"
  shift 6
  local got
  got=$(verdict "$funcs" "$fn" "$var" "$path" "$@")
  DROVE=$((DROVE + 1))
  if [ "$got" = "$want" ]; then
    pass "$suite: $fn reports $want"
  else
    fail "$suite: $fn should report $want" "got: $got"
  fi
}

# One declared helper, driven in both directions wherever both directions exist.
drive_declared() {
  local suite="$1" funcs="$2" fn="$3" sem="$4" src="$5" var=""
  case "$src" in
    capture|path-arg) ;;
    file:*)
      var="${src#file:}"
      case "$var" in
        ""|[0-9]*|*[!A-Za-z0-9_]*)
          fail "$suite: $fn declares an unusable output variable" "source: $src"
          return ;;
      esac
      ;;
    *) fail "$suite: $fn declares an unknown source" "source: $src"; return ;;
  esac

  case "$src:$sem" in
    capture:contains)
      check "$suite" "$funcs" "$fn" PASS "" "" "d" "$BIG" "$NEEDLE"
      check "$suite" "$funcs" "$fn" FAIL "" "" "d" "$BIG" "$ABSENT" ;;
    capture:not_contains)
      check "$suite" "$funcs" "$fn" PASS "" "" "d" "$BIG" "$ABSENT"
      check "$suite" "$funcs" "$fn" FAIL "" "" "d" "$BIG" "$NEEDLE" ;;
    capture:token_row)
      check "$suite" "$funcs" "$fn" PASS "" "" "d" "$BIGROW" "$TOKEN" ;;
    capture:no_token_row)
      check "$suite" "$funcs" "$fn" FAIL "" "" "d" "$BIGROW" "$TOKEN" ;;
    capture:blocked)
      check "$suite" "$funcs" "$fn" PASS "" "" "d" "$BIGBLOCK" ;;
    capture:not_blocked)
      check "$suite" "$funcs" "$fn" FAIL "" "" "d" "$BIGBLOCK" ;;

    file:*:contains)
      check "$suite" "$funcs" "$fn" PASS "$var" "$BIGFILE" "d" "$NEEDLE"
      check "$suite" "$funcs" "$fn" FAIL "$var" "$BIGFILE" "d" "$ABSENT" ;;
    file:*:not_contains)
      check "$suite" "$funcs" "$fn" PASS "$var" "$BIGFILE" "d" "$ABSENT"
      check "$suite" "$funcs" "$fn" FAIL "$var" "$BIGFILE" "d" "$NEEDLE" ;;
    file:*:blocked)
      check "$suite" "$funcs" "$fn" PASS "$var" "$BIGBLOCKFILE" "d" "$NEEDLE"
      check "$suite" "$funcs" "$fn" FAIL "$var" "$BIGBLOCKFILE" "d" "$ABSENT" ;;
    file:*:not_blocked)
      check "$suite" "$funcs" "$fn" PASS "$var" "$BIGFILE" "d"
      check "$suite" "$funcs" "$fn" FAIL "$var" "$BIGBLOCKFILE" "d" ;;

    path-arg:contains)
      check "$suite" "$funcs" "$fn" PASS "" "" "d" "$BIGFILE" "$NEEDLE"
      check "$suite" "$funcs" "$fn" FAIL "" "" "d" "$BIGFILE" "$ABSENT" ;;
    path-arg:not_contains)
      check "$suite" "$funcs" "$fn" PASS "" "" "d" "$BIGFILE" "$ABSENT"
      check "$suite" "$funcs" "$fn" FAIL "" "" "d" "$BIGFILE" "$NEEDLE" ;;

    *)
      fail "$suite: $fn declares a semantic this harness cannot drive" \
           "semantic: $sem, source: $src" ;;
  esac
}

for suite in "$SUBJECTS"/test-*.sh; do
  [ -f "$suite" ] || continue
  name="$(basename "$suite")"
  [ "$name" = "test-assertion-helpers.sh" ] && continue

  funcs="$WORK/$name.funcs"
  extract_funcs "$suite" > "$funcs"

  decls="$WORK/$name.decls"
  declarations "$suite" > "$decls"

  declared=""
  if [ ! -s "$decls" ]; then
    fail "$name: declares nothing" \
         "every suite carries at least one '# jit-drive:' line, so that a helper this" \
         "harness does not drive is a written decision rather than a silence." \
         "Declare a helper --   # jit-drive: assert_contains contains capture" \
         "or the absence   --   # jit-drive: none -- <why>"
  fi

  while IFS= read -r decl; do
    # shellcheck disable=SC2086
    set -- $decl
    if [ "${1:-}" = "none" ]; then
      shift
      [ "${1:-}" = "--" ] && shift
      reason="$*"
      case "$reason" in
        ""|"--")
          fail "$name: 'jit-drive: none' carries no reason" \
               "say what this suite exposes instead, on the same line" ;;
        *)
          NOT_EVALUATED="$NOT_EVALUATED
  $name: $reason" ;;
      esac
      continue
    fi
    fn="${1:-}"; sem="${2:-}"; src="${3:-}"
    if [ -z "$fn" ] || [ -z "$sem" ] || [ -z "$src" ]; then
      fail "$name: malformed declaration" "jit-drive: $decl" \
           "expected: <function> <semantic> <source>"
      continue
    fi
    if ! grep -qF "$fn() {" "$funcs"; then
      fail "$name: declares $fn, which this suite does not define" \
           "a rename left the declaration behind, and nothing was driven for it"
      continue
    fi
    declared="$declared $fn"
    drive_declared "$name" "$funcs" "$fn" "$sem" "$src"
  done < "$decls"

  # Helpers the suite defines and did not declare. Undecidable from here -- a helper may
  # genuinely not be payload-shaped -- so this is reported, never guessed at.
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    case " $declared " in
      *" $h "*) ;;
      *) UNDECLARED="$UNDECLARED
  $name: $h" ;;
    esac
  done < <(helper_names "$suite")
done

# A run that drove nothing would print a clean sweep having tested no helper at all --
# the same vacuous pass the dogfood suite guards against. The floor sits below the
# current count so adding a suite does not break it, and far above zero. It is a claim
# about this repository own tests/ directory, so it is not asserted about an arbitrary
# --subjects fixture.
if [ "$DEFAULT_MODE" = 1 ]; then
  if [ "$DROVE" -lt 20 ]; then
    fail "drove only $DROVE helper calls -- extraction found almost nothing" \
         "every result above is vacuous; expected at least 20"
  else
    pass "drove $DROVE real helper calls across the suites"
  fi
fi

# --- Structural guard ---------------------------------------------------------------
#
# Catches reintroduction, and covers helper names no declaration mentions. It is
# deliberately independent of every declaration above: a file cannot opt out of it.
# `grep -q` and `head` are the two early-exiting right-hand sides in this tree.
echo ""
echo "Structural: nothing pipes into an early-exiting reader"
# Comments are skipped: this repository documents the rule in the suites it applies to,
# and a scan that cannot tell a prohibition from an occurrence punishes writing it down.
# The control below proves the skip did not disarm the scan.
scan_file() {
  awk '/^[[:space:]]*#/ { next }
       /\|[[:space:]]*(grep[[:space:]]+-[a-zA-Z]*q|head[[:space:]])/ { print FNR ": " $0 }' "$1"
}

CONTROL_FIXTURE="$WORK/scan-control.sh"
# Assembled rather than written out: this file is itself scanned, and a literal
# occurrence here would be indistinguishable from the thing being prohibited.
Q="q"
printf '%s\n' \
  "# a piped read, in prose -- must not flag: cmd | grep -$Q needle" \
  "cmd | grep -$Q needle" > "$CONTROL_FIXTURE"
control_hits=$(scan_file "$CONTROL_FIXTURE")
case "$control_hits" in
  *"2: "*) case "$control_hits" in
             *"1: "*) fail "control: the scan flagged the commented line" "$control_hits" ;;
             *)       pass "control: the scan flags real code and skips the comment" ;;
           esac ;;
  *) fail "control: the scan found nothing -- every result below is vacuous" "$control_hits" ;;
esac

SCANNED=0
for f in "$SUBJECTS"/*.sh; do
  [ -f "$f" ] || continue
  SCANNED=$((SCANNED + 1))
  hits=$(scan_file "$f")
  if [ -n "$hits" ]; then
    fail "$(basename "$f"): pipes into an early-exiting reader" "$hits"
  fi
done
if [ "$DEFAULT_MODE" = 1 ]; then
  if [ "$SCANNED" -lt 10 ]; then
    fail "scanned only $SCANNED files -- the structural guard saw no suites"
  else
    pass "scanned $SCANNED files for the pipe shape"
  fi
fi

# --- The third outcome, said out loud -----------------------------------------------
#
# Neither list below is a failure on its own. Both are the coverage this harness does
# NOT have, and printing them is the whole reason the declaration exists: a meta-suite
# that silently skips a file is worth less than no meta-suite at all.
echo ""
if [ -n "$NOT_EVALUATED" ]; then
  echo "NOT EVALUATED -- suites declaring they expose nothing payload-shaped:$NOT_EVALUATED"
else
  echo "NOT EVALUATED -- none: every suite declared at least one drivable helper."
fi
echo ""
if [ -n "$UNDECLARED" ]; then
  echo "NOT EVALUATED -- helpers defined but never declared, so never driven:$UNDECLARED"
  echo ""
  echo "  Each is either genuinely not payload-shaped, or coverage nobody has yet."
  echo "  Declaring one is a single '# jit-drive:' line above its definition."
else
  echo "NOT EVALUATED -- no undeclared helpers: every assert_/expect_ function is driven."
fi

# --- Self-test: the harness on a controlled tree ------------------------------------
#
# Three fixtures in one run, because each is the other control:
#   test-file-reader.sh  a CORRECT helper in the documented file-reading shape. Before
#                        #110 it was driven with the capture signature and reported as a
#                        defect. It must come out green.
#   test-broken.sh       a genuinely broken helper, the `| grep -q` shape. It must still
#                        come out red -- otherwise "no longer falsely flagged" is only
#                        evidence that the harness evaluated nothing.
#   test-undeclared.sh   a suite that declares nothing. It must be reported, not skipped.
if [ "$DEFAULT_MODE" = 1 ]; then
  echo ""
  echo "Self-test: the harness driven against a controlled tree"
  FIX="$WORK/fixtures"
  mkdir -p "$FIX"

  {
    echo '#!/bin/bash'
    echo '# jit-drive: assert_blocked blocked file:OUT'
    echo 'PASS=0'
    echo 'FAIL=0'
    echo 'ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }'
    echo 'bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; return 0; }'
    echo 'assert_blocked() {'
    echo '  if grep -qF -- '"'"'"decision":"block"'"'"' "$OUT" && grep -qF -- "$2" "$OUT"; then'
    echo '    ok "$1"'
    echo '  else'
    echo '    bad "$1"'
    echo '  fi'
    echo '}'
  } > "$FIX/test-file-reader.sh"

  # Assembled with $Q so the prohibited shape never appears literally in this file.
  {
    echo '#!/bin/bash'
    echo '# jit-drive: assert_contains contains capture'
    echo 'PASS=0'
    echo 'FAIL=0'
    echo 'ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }'
    echo 'bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; return 0; }'
    echo 'assert_contains() {'
    echo "  if echo \"\$2\" | grep -${Q}F \"\$3\"; then ok \"\$1\"; else bad \"\$1\"; fi"
    echo '}'
  } > "$FIX/test-broken.sh"

  {
    echo '#!/bin/bash'
    echo 'PASS=0'
    echo 'FAIL=0'
    echo 'ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }'
    echo 'bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; return 0; }'
    echo 'assert_contains() {'
    echo '  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac'
    echo '}'
  } > "$FIX/test-undeclared.sh"

  SELF="$WORK/self.out"
  bash "$0" --subjects "$FIX" > "$SELF" 2>&1
  SELF_RC=$?

  self_has() {
    if grep -qF -- "$2" "$SELF"; then pass "self-test: $1"; else
      fail "self-test: $1" "expected in the sub-run output: $2"
    fi
  }
  self_lacks() {
    if grep -qF -- "$2" "$SELF"; then
      fail "self-test: $1" "must NOT appear in the sub-run output: $2"
    else pass "self-test: $1"; fi
  }

  # The control first: if the harness caught nothing, every assertion under it is vacuous.
  self_has "the genuinely broken helper is still flagged" \
           "FAIL: test-broken.sh: assert_contains should report PASS"
  self_has "the file-reading helper is driven, and passes" \
           "PASS: test-file-reader.sh: assert_blocked reports PASS"
  self_has "the file-reading helper is driven the other way too" \
           "PASS: test-file-reader.sh: assert_blocked reports FAIL"
  self_lacks "the file-reading helper is not falsely flagged (#110)" \
             "FAIL: test-file-reader.sh"
  self_has "a suite that declares nothing is reported, not skipped" \
           "FAIL: test-undeclared.sh: declares nothing"
  self_has "its undriven helper is named in the third-outcome list" \
           "test-undeclared.sh: assert_contains"
  if [ "$SELF_RC" -ne 0 ]; then
    pass "self-test: the sub-run exits non-zero on its two planted defects"
  else
    fail "self-test: the sub-run exited 0 with two planted defects" "rc: $SELF_RC"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
