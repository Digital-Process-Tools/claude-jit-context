#!/bin/bash
# #388: jit_load_config's key check is `[[ "$key" =~ ^(JIT_CONTEXT|DYNAMIC_RULES|DVSI)_[A-Za-z0-9_]+$ ]]`.
# A bracket range inside `[[ =~ ]]` is matched by the locale's collation order, not by byte
# value. Turkish collation (and Azerbaijani) does not place I inside A..Z, so under
# LC_ALL=tr_TR.UTF-8 every real setting whose name carries an I AFTER the prefix --
# JIT_CONTEXT_INJECT, JIT_CONTEXT_MISSES, JIT_CONTEXT_COLLISION_BYTES,
# DYNAMIC_RULES_MODULE_PREFIX among them -- is refused as "unknown setting" and dropped.
#
# This is a glibc collation behaviour. Darwin's libc does not collate bracket ranges at
# all, so this suite CANNOT construct the attack on macOS -- probed below rather than
# assumed from `uname`, because whether a given host's libc collates is exactly the fact
# in question. Three outcomes, never two: COVERED when a collating locale was probed and
# built, FLAGGED never applies here (there is nothing this suite can assert without the
# locale), and NOT EVALUATED -- exit 2, a SKIPPED block -- when no collating locale could
# be produced on this host at all. Folding "could not build the fixture" into a pass would
# print a sentence about coverage nobody has, same as tests/test-symlink-entry.sh's
# ln -s gate on Windows.
#
# Every negative here is paired with a positive control on the same code path: a real
# unknown key must still be refused under the SAME locale that stops refusing real keys,
# so a fix that broke refusal outright (e.g. an unconditional early return) would not
# read as green.
#
# THIS SUITE ALSO MEASURES THE ISSUE'S CLAIM 1, rather than letting it stay an
# inference. tests/test-locale-collation-scope.sh's source guard is scoped to `[[ =~ ]]`
# only -- it does not flag a `case` pattern or a `${v//[!...]/}` parameter expansion
# carrying the same kind of bracket range. That scope rests entirely on #388's own
# claim that those two forms compare bytes and do not collate, measured there on
# ubuntu-latest / bash 5.2 and reported here (see the developer lane's notes) as
# REASONED rather than OBSERVED, for lack of a glibc host at the time. This suite
# already builds a real collating locale on any host that can produce one, and CI runs
# a glibc leg, so the claim is measurable here for free -- there is no reason to keep
# shipping an unverified inference when the fixture to check it already exists.
#
# Under the built locale this suite asserts DIRECTLY that the three non-`=~` shapes do
# NOT move (produce byte-identical results to the same shapes under LC_ALL=C), with a
# positive control beside them proving the locale is genuinely collating: `[[ =~ ]]`
# itself MUST diverge from its C behaviour, or the whole comparison is meaningless --
# a locale that fails to build could otherwise pass every "did not move" assertion for
# the wrong reason. If any of the three non-`=~` shapes DOES move, that is not a
# COVERED failure to be argued down: it means the scope of
# tests/test-locale-collation-scope.sh is wrong and must be widened, and this suite
# fails loudly saying so rather than passing quietly. Same three states as everywhere
# else in this suite: on a host with no collating locale, this section is folded into
# the same NOT EVALUATED / SKIPPED block below as the rest -- never a silent pass.
#
# Usage: bash tests/test-config-locale-collation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

# jit-drive: none -- assert_eq compares two already-extracted strings (an env var
# capture and a fixed constant), never a captured hook/tool OUTPUT or a PATH argument;
# it is not one of the drivable shapes test-assertion-helpers.sh's harness feeds.
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    want: $want"
    echo "    got:  $got"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Find a locale on THIS host whose regex collation actually moves, rather than
# trusting `locale -a` or `uname` to say so. A locale can be listed and still not
# collate (this is exactly what darwin does), and localedef can succeed and still
# produce something the regex engine does not use for collation.
COLL_LOCALE=""
COLL_LOCPATH=""

probe_locale() {
  # $1 = LC_ALL value, $2 = LOCPATH value (may be empty)
  local out
  out="$(LOCPATH="$2" LC_ALL="$1" bash -c '[[ "I" =~ ^[A-Z]$ ]] && echo match || echo nomatch' 2> /dev/null)"
  [ "$out" = "nomatch" ]
}

# `locale -a` written to a file rather than piped into `grep -q`: this repo's own
# tests/test-assertion-helpers.sh structurally refuses `| grep -q` and `| head` in
# every suite under tests/ (#56 -- an early-exiting reader under pipefail can report
# the opposite of what was found once output crosses the pipe buffer).
LOCALE_LIST="$TMP/locale-a.txt"
locale -a > "$LOCALE_LIST" 2> /dev/null
for cand in tr_TR.UTF-8 tr_TR az_AZ.UTF-8 az_AZ; do
  if grep -qxF "$cand" "$LOCALE_LIST"; then
    if probe_locale "$cand" ""; then
      COLL_LOCALE="$cand"
      COLL_LOCPATH=""
      break
    fi
  fi
done

if [ -z "$COLL_LOCALE" ] && command -v localedef > /dev/null 2>&1; then
  mkdir -p "$TMP/loc"
  if LOCPATH="$TMP/loc" localedef -i tr_TR -f UTF-8 "$TMP/loc/tr_TR.UTF-8" > /dev/null 2>&1; then
    if probe_locale "tr_TR.UTF-8" "$TMP/loc"; then
      COLL_LOCALE="tr_TR.UTF-8"
      COLL_LOCPATH="$TMP/loc"
    fi
  fi
fi

if [ -z "$COLL_LOCALE" ]; then
  echo "=== Probing for a locale whose [[ =~ ]] collation actually moves ==="
  echo ""
  echo "SKIPPED: this host could not produce a locale under which"
  echo "         [[ \"I\" =~ ^[A-Z]\$ ]] fails to match. That is the exact behaviour"
  echo "         #388 depends on, so nothing about it could be tested here."
  echo ""
  echo "         Darwin's libc does not collate bracket ranges inside [[ =~ ]] at all --"
  echo "         if this ran on macOS, that is expected and not a defect in the fix."
  echo "         On glibc hosts (Linux CI) this is expected to succeed via localedef;"
  echo "         if it fails there instead, that IS worth investigating."
  echo ""
  echo "0 passed, 0 failed, every collation case NOT RUN"
  exit 2
fi

echo "=== Using locale for collation cases: LC_ALL=$COLL_LOCALE LOCPATH=${COLL_LOCPATH:-<unset>} ==="
echo ""

CFG="$TMP/config.env"
cat > "$CFG" << 'CFGEOF'
JIT_CONTEXT_INJECT=full
JIT_CONTEXT_MISSES=on
JIT_CONTEXT_COLLISION_BYTES=4096
DYNAMIC_RULES_MODULE_PREFIX=src/
NOT_A_REAL_SETTING=nope
CFGEOF

OUT="$TMP/out.txt"
LOCPATH="$COLL_LOCPATH" LC_ALL="$COLL_LOCALE" bash -c '
  source "'"$SCRIPTS"'/common.sh"
  jit_load_config "'"$CFG"'"
  printf "REFUSED_N=%s\n" "$JIT_CONFIG_REFUSED_N"
  printf "INJECT=%s\n" "${JIT_CONTEXT_INJECT:-<unset>}"
  printf "MISSES=%s\n" "${JIT_CONTEXT_MISSES:-<unset>}"
  printf "COLLISION=%s\n" "${JIT_CONTEXT_COLLISION_BYTES:-<unset>}"
  printf "MODPREFIX=%s\n" "${DYNAMIC_RULES_MODULE_PREFIX:-<unset>}"
  # The caller locale must not have leaked out of jit_load_config: a probe run AFTER
  # the call, in the same shell, must still show the collating behaviour -- proving
  # "local LC_ALL=C" restored on return rather than an unconditional global reassignment
  # that would also silently fix this by breaking every OTHER locale-sensitive thing in
  # the caller for the rest of the process.
  [[ "I" =~ ^[A-Z]$ ]] && printf "POST_PROBE=match\n" || printf "POST_PROBE=nomatch\n"
' > "$OUT" 2> /dev/null

assert_eq "JIT_CONTEXT_INJECT (has I after the prefix) is read, not refused" \
  "$(grep '^INJECT=' "$OUT")" "INJECT=full"
assert_eq "JIT_CONTEXT_MISSES (has I after the prefix) is read, not refused" \
  "$(grep '^MISSES=' "$OUT")" "MISSES=on"
assert_eq "JIT_CONTEXT_COLLISION_BYTES (has I after the prefix) is read, not refused" \
  "$(grep '^COLLISION=' "$OUT")" "COLLISION=4096"
assert_eq "DYNAMIC_RULES_MODULE_PREFIX (has I after the prefix) is read, not refused" \
  "$(grep '^MODPREFIX=' "$OUT")" "MODPREFIX=src/"
# Positive control: a genuinely unknown key is still refused under the SAME locale --
# proves the fix did not just disable refusal outright.
assert_eq "a genuinely unknown key is still refused (positive control)" \
  "$(grep '^REFUSED_N=' "$OUT")" "REFUSED_N=1"
# The caller's locale must not have leaked out of the function.
assert_eq "the caller's own collation is unaffected after jit_load_config returns" \
  "$(grep '^POST_PROBE=' "$OUT")" "POST_PROBE=nomatch"

echo ""
echo "=== Claim 1: measuring, not inferring, whether case/parameter-expansion collate ==="
echo ""

# One script, run twice -- once under the built collating locale, once under LC_ALL=C --
# so every shape is compared against a REAL baseline run on this exact host and shell,
# never a hardcoded expected string that could itself be wrong on a platform nobody
# tested. `v` is set inside the script (not exported in) so both runs build it fresh.
SHAPES_SCRIPT='
v="SESS-I"
case "I" in
  [A-Z]) echo "CASE_LETTER=match" ;;
  *) echo "CASE_LETTER=nomatch" ;;
esac
case "SESS-I" in
  *[!A-Za-z0-9._-]*) echo "CASE_STAR=hasbad" ;;
  *) echo "CASE_STAR=clean" ;;
esac
printf "PARAM_EXP=%s\n" "${v//[!a-zA-Z0-9]/-}"
[[ "I" =~ ^[A-Z]$ ]] && echo "REGEX_CTRL=match" || echo "REGEX_CTRL=nomatch"
'
LOCALE_SHAPES="$TMP/shapes-locale.txt"
C_SHAPES="$TMP/shapes-c.txt"
LOCPATH="$COLL_LOCPATH" LC_ALL="$COLL_LOCALE" bash -c "$SHAPES_SCRIPT" > "$LOCALE_SHAPES" 2> /dev/null
LC_ALL=C bash -c "$SHAPES_SCRIPT" > "$C_SHAPES" 2> /dev/null

# Positive control FIRST: if this locale does not actually diverge from C on the one
# shape #388 is about, the three "did not move" assertions below are not measuring
# anything -- they would pass on a locale that failed to build too.
assert_eq "positive control: [[ =~ ]] DOES collate under $COLL_LOCALE (proves the locale is real)" \
  "$(grep '^REGEX_CTRL=' "$LOCALE_SHAPES")" "REGEX_CTRL=nomatch"
assert_eq "positive control: the same [[ =~ ]] check does NOT collate under LC_ALL=C (baseline)" \
  "$(grep '^REGEX_CTRL=' "$C_SHAPES")" "REGEX_CTRL=match"

# Claim 1 itself. Each of these compares the collating-locale run's line to the C run's
# line, not to a hardcoded string -- if they ever differ, tests/test-locale-collation-scope.sh's
# `[[ =~ ]]`-only scope is WRONG and must be widened to cover this shape too. This is
# not a finding to argue down: a real divergence here means the scanner is silently
# not guarding a construct #388's own bug class actually reaches.
assert_eq "claim 1: case \"I\" in [A-Z]) ... does not collate under $COLL_LOCALE (must equal the LC_ALL=C baseline, or the scanner's =~-only scope is wrong)" \
  "$(grep '^CASE_LETTER=' "$LOCALE_SHAPES")" "$(grep '^CASE_LETTER=' "$C_SHAPES")"
assert_eq "claim 1: case \"SESS-I\" in *[!A-Za-z0-9._-]*) ... does not collate under $COLL_LOCALE (must equal the LC_ALL=C baseline, or the scanner's =~-only scope is wrong)" \
  "$(grep '^CASE_STAR=' "$LOCALE_SHAPES")" "$(grep '^CASE_STAR=' "$C_SHAPES")"
assert_eq "claim 1: \${v//[!a-zA-Z0-9]/-} does not collate under $COLL_LOCALE (must equal the LC_ALL=C baseline, or the scanner's =~-only scope is wrong)" \
  "$(grep '^PARAM_EXP=' "$LOCALE_SHAPES")" "$(grep '^PARAM_EXP=' "$C_SHAPES")"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
