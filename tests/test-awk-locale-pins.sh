#!/bin/bash
# Four awk sites diverged by locale, silently (#195, #196), and the fix is pinning them
# to LC_ALL=C plus checking what an unchecked failure used to hide.
#
# #195 filed the reporter/append half first, on purpose: pinning the divergent sites
# without it trades a LOUD one-engine abort (one-true-awk under a UTF-8 locale) for a
# QUIET pass-through on mawk, the default awk on ubuntu-latest. This suite drives both
# halves together because they now ship in one change.
#
# The locale is CHOSEN BY DRIVING, never by reading `locale -a` -- the same rule
# test-jit-dry-run.sh's #163 section states and this file inherits: a name lookup is the
# name plus an assumption about the engine, and `locale -a` on this very machine lists no
# UTF-8 locale at all while `LC_ALL=en_US.UTF-8 awk` visibly aborts under it. So every
# locale/engine pair below is proven to diverge before anything is asserted against it,
# and a machine where nothing diverges reports NOT_EVALUATED rather than a false pass.
#
# Usage: bash tests/test-awk-locale-pins.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$SCRIPT_DIR/scripts/rebuild-tsv.sh"
DRYRUN="$SCRIPT_DIR/scripts/jit-dry-run.sh"
PASS=0
FAIL=0
NOT_EVALUATED=""

# Assertions read from a FILE, never from $( ): #78's whole point is that a captured
# variable drops what a locale abort writes, and this suite's entire subject is bytes a
# decoder chokes on.
#
# `LC_ALL=C` on the grep itself, and this was found by driving, not assumed: under this
# suite's own ambient locale (LC_CTYPE=UTF-8, set by the terminal, present with no LANG
# or LC_ALL exported at all), BSD grep silently failed to find an ASCII needle that
# occurs AFTER an invalid byte on the same line -- a decoder fault in the very tool used
# to prove the fixture landed, indistinguishable from the needle being absent. Pinning
# the reader is as load-bearing as pinning the writer.
# jit-drive: assert_has contains path-arg
# jit-drive: assert_lacks not_contains path-arg
assert_has() {
  local desc="$1" path="$2" needle="$3"
  if LC_ALL=C grep -qF -- "$needle" "$path"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $needle"
    echo "    in file: $path"
  fi
}
assert_lacks() {
  local desc="$1" path="$2" needle="$3"
  if LC_ALL=C grep -qF -- "$needle" "$path"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $needle"
    echo "    in file: $path"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}
assert_status() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (got $actual, expected $expected)"
  fi
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t jit195)"
trap 'rm -rf "$WORK"' EXIT

# =============================================================================
# SECTION A (#195): the Modules-builder append is now checked, engine-independent.
# =============================================================================
# The defect this section drives does not need a real locale divergence to exist: #195's
# second half is that `awk ... >> "$tsv"` never checked ITS OWN exit status at all, so an
# awk that dies for ANY reason -- not just this repo's byte abort -- wrote a partial file
# and the run still reported success. A fake `awk` that fails ON PURPOSE, for exactly the
# one call this concerns and no other, proves the check fires independently of which
# engine or byte triggered the failure -- which is the point: detecting a bad byte cannot
# depend on the engine under test, and neither can detecting "awk died".
echo ""
echo "=== A: an awk that dies while building the Modules index is now FATAL, not silent (#195) ==="

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
REALAWK=$(command -v awk)
# `file=` is the unique marker: it is only ever passed as `-v file=...` at the ONE call
# site in rebuild-tsv.sh that builds "## Modules" rows (grep verified below, so this shim
# cannot silently stop matching anything and pass by not firing).
cat > "$FAKEBIN/awk" << EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    file=*) exit 2 ;;
  esac
done
exec "$REALAWK" "\$@"
EOF
chmod +x "$FAKEBIN/awk"

SITES=$(grep -c -- '-v file="\$filename"' "$SCRIPT_DIR/scripts/rebuild-tsv.sh")
if [ "${SITES:-0}" -ne 1 ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected exactly one '-v file=\"\$filename\"' call site in rebuild-tsv.sh," \
       "found $SITES -- this shim's marker is no longer unique, fix the marker before trusting section A"
else
  PASS=$((PASS + 1)); echo "  PASS: the shim's marker still names exactly one call site"

  APROJ="$WORK/modfail"
  AMANUAL="$APROJ/.claude/jit-context/vocabulary/00-manual"
  mkdir -p "$AMANUAL"
  printf -- '---\ntitle: t\n---\n\n## Modules\n\nBillingCore does the thing.\n' > "$AMANUAL/mod.md"

  AOUT="$WORK/modfail.out"
  PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$APROJ" bash "$REBUILD" > "$AOUT" 2>&1
  ARC=$?

  assert_status "a Modules-builder awk that dies exits the whole rebuild 2" "$ARC" "2"
  assert_has  "the failure is named FATAL, with the entry file" "$AOUT" "mod.md: awk exited 2"
  assert_has  "and it says the index is not this run" "$AOUT" "the index is not this run"
  assert_lacks "the row the dead awk would have written never landed silently" \
    "$AMANUAL/01-paths.tsv" "BillingCore"

  # Positive control: the SAME tree, with the real awk restored, indexes cleanly and the
  # row IS written -- proving the FATAL above is about the injected failure and not about
  # this fixture being unbuildable for some unrelated reason.
  AOUT2="$WORK/modok.out"
  CLAUDE_PROJECT_DIR="$APROJ" bash "$REBUILD" > "$AOUT2" 2>&1
  ARC2=$?
  assert_status "the same tree with a working awk exits 0" "$ARC2" "0"
  assert_has "and the row IS written this time" "$AMANUAL/01-paths.tsv" "BillingCore"
fi

echo ""
echo "=== A2: the same shim against the UNFIXED code is red -- the check is new, not vacuous ==="
# TDD's own bar: would this test still pass if the code did nothing? Answered by running
# it against the tree BEFORE #195/#196, via git show, in a scratch copy -- never by
# editing the working tree, which every other suite in this run still reads.
ORIG_REBUILD="$WORK/rebuild-tsv.orig.sh"
# NOT `HEAD` -- this test file is committed in the SAME commit as the fix it is meant to
# prove red against, so `HEAD:scripts/rebuild-tsv.sh` is the FIXED file on every run after
# that commit lands, and this section would silently stop proving anything while still
# reporting PASS/FAIL as if it did. NOT `merge-base HEAD origin/main` either (#212): that
# resolves to HEAD once this branch's fix commit IS origin/main's tip -- true the moment it
# merges -- so the "pre-fix" tree it loads is actually the fixed one, and the control passes
# on a branch and silently proves nothing once run on main itself.
#
# "Pre-fix" instead means: walk this file's own history (independent of which branch HEAD
# sits on) for the commit that introduced a string only the fix writes, then take THAT
# commit's parent. This is correct on a branch forked before the fix, on a branch forked
# after it, and on main once the fix has landed there too, because the fix commit is found
# by what it changed rather than by where it sits relative to a moving remote ref.
FIX_MARKER='the index is not this run'
FIX_COMMIT=$(git -C "$SCRIPT_DIR" log -1 --format=%H -S"$FIX_MARKER" -- scripts/rebuild-tsv.sh 2>/dev/null)
PRE_FIX_REF=""
if [ -n "$FIX_COMMIT" ]; then
  PRE_FIX_REF=$(git -C "$SCRIPT_DIR" rev-parse "${FIX_COMMIT}~1" 2>/dev/null)
fi
if [ -n "${PRE_FIX_REF:-}" ] \
   && git -C "$SCRIPT_DIR" show "$PRE_FIX_REF:scripts/rebuild-tsv.sh" > "$ORIG_REBUILD" 2>/dev/null \
   && git -C "$SCRIPT_DIR" show "$PRE_FIX_REF:scripts/common.sh" > "$WORK/common.orig.sh" 2>/dev/null; then
  # rebuild-tsv.sh sources "$(dirname "$0")/common.sh" -- give the scratch copy its own
  # common.sh right beside it so it does not pick up the FIXED one from scripts/.
  cp "$WORK/common.orig.sh" "$WORK/common.sh"
  BPROJ="$WORK/modfail-orig"
  BMANUAL="$BPROJ/.claude/jit-context/vocabulary/00-manual"
  mkdir -p "$BMANUAL"
  printf -- '---\ntitle: t\n---\n\n## Modules\n\nBillingCore does the thing.\n' > "$BMANUAL/mod.md"
  BOUT="$WORK/modfail-orig.out"
  PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$BPROJ" bash "$ORIG_REBUILD" > "$BOUT" 2>&1
  BRC=$?
  if [ "$BRC" -eq 0 ] && ! grep -q "FATAL" "$BOUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: [red, pre-fix] the same dying awk was invisible -- exit 0, no FATAL, no row"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: expected the pre-fix code to exit 0 with no FATAL for this same fixture" \
         "(got rc=$BRC); the red/green comparison above proves nothing if this is not red"
    echo "    --- pre-fix output ---"
    cat "$BOUT"
  fi
else
  NOT_EVALUATED="$NOT_EVALUATED
  - A2: could not resolve a pre-fix ref -- scripts/rebuild-tsv.sh's own history carries no
    commit introducing \"$FIX_MARKER\" (a shallow clone is the ordinary cause: git log -S
    can only see commits the clone actually fetched), or that commit's parent could not be
    resolved, or scripts/rebuild-tsv.sh / scripts/common.sh could not be read from it via
    git show -- the red/pre-fix comparison could not run"
fi

# =============================================================================
# Engines and the divergent locale, both found by DRIVING (#116, #163's methodology).
# =============================================================================
ENGINE_BIN="$WORK/engines"
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2>/dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

# A lone lead byte (0xE9 alone), the same shape #144's fixture uses: invalid whatever
# follows it, so no engine can read it as one valid character by accident.
BADREC=$(printf 'ab\351cd\n')
DIVERGE_ENGINE=""
DIVERGE_LOCALE=""
for eng in $ENGINES; do
  rc_c=0
  printf '%s' "$BADREC" | PATH="$ENGINE_BIN/$eng:$PATH" LC_ALL=C awk '/x/{}1' >/dev/null 2>&1
  rc_c=$?
  [ "$rc_c" -eq 0 ] || continue
  for loc in en_US.UTF-8 C.UTF-8 en_US.utf8; do
    rc_loc=0
    printf '%s' "$BADREC" | PATH="$ENGINE_BIN/$eng:$PATH" LC_ALL="$loc" awk '/x/{}1' >/dev/null 2>&1
    rc_loc=$?
    if [ "$rc_loc" -ne 0 ]; then
      DIVERGE_ENGINE="$eng"; DIVERGE_LOCALE="$loc"
      break 2
    fi
  done
done

if [ -z "$DIVERGE_ENGINE" ]; then
  NOT_EVALUATED="$NOT_EVALUATED
  - sections B-D: no (engine, locale) pair on this machine actually diverges by locale on
    an invalid byte -- driven against $ENGINES under en_US.UTF-8, C.UTF-8 and en_US.utf8,
    none aborted differently than under C. The pinned code is still exercised (LC_ALL=C
    is what every assertion below runs under regardless), but the BEFORE/AFTER contrast
    that proves the pin was load-bearing could not be driven on this machine."
else
  echo ""
  echo "=== divergence found: [$DIVERGE_ENGINE] aborts under LC_ALL=$DIVERGE_LOCALE, not under C ==="
fi

# =============================================================================
# SECTION B (#195): the keywords: extraction no longer aborts, and no longer misreports.
# =============================================================================
# `keywords: cafe-accented, widget` -- 0xE9 for the accented e, Latin-1. Before the pin,
# the SAME regex that finds the `keywords:` line runs against every line INCLUDING this
# one, so under the divergent locale it aborted before ever printing kw_line, and the
# entry was reported "no keywords: in its frontmatter" -- the right loudness, the wrong
# reason, and BOTH real keywords lost silently. After the pin, jit_fold_latin1() folds
# the accented byte to plain ASCII (that fold exists for exactly this), and both folded
# forms index.
if [ -n "$DIVERGE_ENGINE" ]; then
  echo ""
  echo "=== B [$DIVERGE_ENGINE/$DIVERGE_LOCALE]: keywords: with a Latin-1 byte indexes, not 'no keywords:' ==="
  BPROJ="$WORK/kwbytes"
  BMANUAL="$BPROJ/.claude/jit-context/vocabulary/00-manual"
  mkdir -p "$BMANUAL"
  printf -- '---\ntitle: t\nkeywords: caf\351, widget\n---\n\nBody.\n' > "$BMANUAL/kw.md"

  BOUT="$WORK/kwbytes.out"
  PATH="$ENGINE_BIN/$DIVERGE_ENGINE:$PATH" LC_ALL="$DIVERGE_LOCALE" CLAUDE_PROJECT_DIR="$BPROJ" \
    bash "$REBUILD" > "$BOUT" 2>&1

  assert_lacks "the entry is no longer wrongly reported as having no keywords:" \
    "$BOUT" "no keywords: in its frontmatter"
  # 0xE9 alone matches nothing in jit_fold_latin1()'s table (that table is proper UTF-8
  # accented characters, not a raw Latin-1 byte) -- it survives the fold untouched and is
  # then stripped by the ordinary keyword normaliser, same as any other punctuation, so
  # "cafe" is not the expected row here. What this section is actually proving is that
  # nothing ABORTS on the byte and BOTH keywords on the line still reach the index.
  BKWIDX="$BMANUAL/00-index.tsv"
  assert_has "the byte-bearing keyword still indexes, stripped rather than lost" "$BKWIDX" "caf"
  assert_has "and so does its sibling on the same line" "$BKWIDX" "widget"
fi

# =============================================================================
# SECTION C (#196): jit_frontmatter() no longer needs the caller to force LC_ALL=C.
# =============================================================================
# The existing bad-bytes coverage for `match:` can only reach its subject by forcing
# LC_ALL=C on the WHOLE `bash rebuild-tsv.sh` invocation, because jit_frontmatter() did
# not pin it internally -- that is precisely the workaround #196 removes: jit_frontmatter
# now pins its own awk, so the same shape of fixture must survive running under the
# caller's ordinary, divergent locale, unforced.
if [ -n "$DIVERGE_ENGINE" ]; then
  echo ""
  echo "=== C [$DIVERGE_ENGINE/$DIVERGE_LOCALE]: a bad match: byte survives without the caller forcing LC_ALL=C ==="
  CPROJ="$WORK/matchbytes"
  CMANUAL="$CPROJ/.claude/jit-context/paths/00-manual"
  mkdir -p "$CMANUAL"
  printf -- '---\nmatch: (^|/)ca\351/\n---\n\nBody.\n' > "$CMANUAL/badmatch.md"

  COUT="$WORK/matchbytes.out"
  # No LC_ALL=C on this line -- the caller's own locale is the divergent one, on purpose.
  PATH="$ENGINE_BIN/$DIVERGE_ENGINE:$PATH" LC_ALL="$DIVERGE_LOCALE" CLAUDE_PROJECT_DIR="$CPROJ" \
    bash "$REBUILD" > "$COUT" 2>&1

  assert_lacks "the entry is not silently dropped as having no match:" \
    "$COUT" "no match: in its frontmatter"
  CIDX="$CMANUAL/00-index.tsv"
  assert_has "the row is written, byte and all" "$CIDX" "badmatch.md"
  assert_has "and report_bad_bytes() names it downstream, unforced" \
    "$COUT" "is not valid UTF-8 -- the hooks will refuse this row"
fi

# =============================================================================
# SECTION D (#196): check_paths_fragment() -- an anchored pattern with a bad byte is not
# warned about by accident.
# =============================================================================
# Before the pin, one-true-awk's abort under the divergent locale made the `&&` in
# check_paths_fragment() fall through to WARN unconditionally, for any pattern carrying a
# bad byte -- including one that IS anchored and should never warn. That is a correct
# verdict for the wrong reason: it would fire on an anchored pattern exactly as readily
# as on a genuinely bare one, and a linter that cannot tell those apart is not testing
# anchoring at all. Written straight into the index, bypassing rebuild-tsv.sh, because
# the fixture is about the LINT rather than about the writer.
if [ -n "$DIVERGE_ENGINE" ]; then
  echo ""
  echo "=== D [$DIVERGE_ENGINE/$DIVERGE_LOCALE]: an anchored bad-byte pattern is not warned about ==="
  DPROJ="$WORK/anchorbytes"
  DBASE="$DPROJ/.claude/jit-context"
  mkdir -p "$DBASE/tools/00-manual" "$DBASE/paths/00-manual" "$DBASE/vocabulary/00-manual"
  DTOOLIDX="$DBASE/tools/00-manual/00-index.tsv"
  DVOCIDX="$DBASE/vocabulary/00-manual/00-index.tsv"
  : > "$DTOOLIDX"
  : > "$DVOCIDX"
  DPATHIDX="$DBASE/paths/00-manual/00-index.tsv"
  printf '^src/Billing\351/\tanchored.md\n' > "$DPATHIDX"
  echo "anchored body" > "$DBASE/paths/00-manual/anchored.md"

  DOUT="$WORK/anchorbytes.out"
  PATH="$ENGINE_BIN/$DIVERGE_ENGINE:$PATH" LC_ALL="$DIVERGE_LOCALE" \
    bash "$DRYRUN" --base "$DBASE" > "$DOUT" 2>&1

  assert_lacks "an anchored pattern is not warned about, bad byte or not" "$DOUT" "WARN"
  assert_lacks "and gawk's own runtime warning does not leak into the report either" \
    "$DOUT" "Invalid multibyte data"
fi
# =============================================================================
# SECTION E (#162): a vocabulary bad-bytes row now names WHICH of its two indexes.
# =============================================================================
# report_bad_bytes() is called twice for one vocabulary layer -- once for the keyword
# index, once for the module-paths index -- and both calls used to pass the same bare
# `vocabulary/<layer>` label, so a row could not be traced to either file without opening
# both. Neither index can carry an invalid byte through an ORDINARY fixture today (the
# keyword normaliser and the Modules PascalCase filter both strip anything outside
# [A-Za-z0-9] before a row is ever written), so this drives the call sites directly: seed
# both TSVs with a bad byte and a working awk, then make the WRITE step fail so the seed
# survives to the report -- read-only permission bits, gated on a positive control, since
# an account that ignores them (root, some CI images) would make every assertion below
# pass for the wrong reason.
echo ""
echo "=== E: a vocabulary bad-bytes row names its own leaf file, index vs paths (#162) ==="

EPROJ="$WORK/vocablabel"
EMANUAL="$EPROJ/.claude/jit-context/vocabulary/00-manual"
mkdir -p "$EMANUAL"
echo "entry body" > "$EMANUAL/seed.md"

EKWLEAF="00-index.tsv"
EPATHLEAF="01-paths.tsv"
EKWIDX="$EMANUAL/$EKWLEAF"
EPATHIDX="$EMANUAL/$EPATHLEAF"
# 0xE9 alone -- a lead byte with no continuation, invalid whatever follows it.
printf 'wi\351dget\tseed.md\n' > "$EKWIDX"
printf 'src/Wi\351dget/\tseed.md\n' > "$EPATHIDX"
chmod 444 "$EKWIDX" "$EPATHIDX"

EOUT="$WORK/vocablabel.out"
CLAUDE_PROJECT_DIR="$EPROJ" bash "$REBUILD" > "$EOUT" 2>&1

# The positive control: did the read-only bit actually stop the truncate, so our seeded
# bytes are what the reporter is reading? If not (root, or a filesystem that ignores the
# bit), this whole section says NOT_EVALUATED rather than passing on an empty file.
if LC_ALL=C grep -qF 'wi' "$EKWIDX" 2>/dev/null && LC_ALL=C grep -qF 'Wi' "$EPATHIDX" 2>/dev/null; then
  assert_has "the keyword-index row names its own leaf" \
    "$EOUT" "vocabulary/00-manual/$EKWLEAF row"
  assert_has "the paths-index row names its own leaf" \
    "$EOUT" "vocabulary/00-manual/$EPATHLEAF row"
  # grep -c already prints "0" on no match and only its EXIT status is nonzero then, so
  # `|| echo 0` here would append a SECOND "0" on a line of its own and break the -eq
  # test below with two lines instead of one.
  OLDFORM=$(LC_ALL=C grep -c '^rebuild-tsv: vocabulary/00-manual row ' "$EOUT" 2>/dev/null)
  OLDFORM="${OLDFORM:-0}"
  if [ "${OLDFORM:-0}" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: the undifferentiated 'vocabulary/00-manual row' form is gone"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: the old ambiguous label is still printed on its own"
  fi
  # tools/ and paths/ write one index per layer and stay bare on purpose (#153) -- this
  # change must not have widened to them by accident.
  TPROJ="$WORK/toolslabel"
  TMANUAL="$TPROJ/.claude/jit-context/paths/00-manual"
  mkdir -p "$TMANUAL"
  echo "entry body" > "$TMANUAL/seed.md"
  TIDX="$TMANUAL/$EKWLEAF"
  printf '(^|/)wi\351dget/\tseed.md\n' > "$TIDX"
  chmod 444 "$TIDX"
  TOUT="$WORK/toolslabel.out"
  CLAUDE_PROJECT_DIR="$TPROJ" bash "$REBUILD" > "$TOUT" 2>&1
  if LC_ALL=C grep -qF 'wi' "$TIDX" 2>/dev/null; then
    assert_has "paths stays bare -- no leaf suffix invented where only one index exists" \
      "$TOUT" "rebuild-tsv: paths/00-manual row"
    assert_lacks "and it does not gain a fabricated leaf suffix either" \
      "$TOUT" "paths/00-manual/$EKWLEAF row"
  fi
  chmod 644 "$TIDX" 2>/dev/null || true
else
  NOT_EVALUATED="$NOT_EVALUATED
  - section E: chmod 444 did not stop rebuild-tsv.sh from truncating the seeded TSVs on
    this account (root, or a filesystem that ignores the permission bit) -- the seeded
    bad bytes did not survive to the reporter, so nothing here proves which label was
    printed"
fi
chmod 644 "$EKWIDX" "$EPATHIDX" 2>/dev/null || true

echo ""
if [ -n "$NOT_EVALUATED" ]; then
  echo "=== NOT EVALUATED ==="
  echo "$NOT_EVALUATED"
fi
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
