#!/bin/bash
# #176: the hooks enumerated their layer directories from a hardcoded literal, so a layer
# directory with any other name was written by the author, indexed by rebuild-tsv.sh,
# counted by every report -- and read by nothing. Filed from claude-oss, whose
# /oss:scaffold ships rules into a `01-oss` layer that had never fired anywhere.
#
# Three separate hardcodes, not one:
#
#   paths and vocabulary  split("00-manual 10-auto 20-grouped 30-crosscutting", ...) in
#                         all three hooks, with a `li <= 4` bound written as a SECOND
#                         literal beside it -- so a change that fixes the string and
#                         leaves the 4 truncates the list silently: same defect, new
#                         spelling.
#   tools                 worse: no layer loop at all. pre-tool-hook.sh took
#                         tools_tsv="$JIT_BASE/tools/00-manual/00-index.tsv" directly, so
#                         `10-auto`, `20-grouped` and `30-crosscutting` were dead in the
#                         tools dimension too -- the three layer names docs/layers.md
#                         says are indexed and fire. That dimension is also the only one
#                         that can REFUSE a call, so a `mode: block` rule there failed
#                         open and said nothing.
#
# THE GUARD THIS SUITE NEEDS: nearly every assertion here is "this entry fired", and the
# ones that matter are about a layer that did not. Both halves are driven from the same
# fixture in the same section -- an `00-manual` entry that MUST fire beside the layer
# under test -- so "nothing fired" can never be read as a verdict about layers when it is
# really a verdict about the harness. Section F is the inverse: a refusal that must be
# NAMED, checked beside an honest layer in the same tree that must still fire.
#
# Every index here is built by scripts/rebuild-tsv.sh from real frontmatter rather than
# hand-written, because half the defect is that the rebuild has always indexed every layer
# while the matcher read four names. A hand-written TSV would assert the fix and drop the
# asymmetry that made this invisible for two releases.
#
# Usage: bash tests/test-layer-enumeration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/jit-layers-XXXXXX")" || {
  echo "test-layer-enumeration: SKIPPED -- could not create a temp directory"
  exit 2
}
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
SID_FILE="$TMPROOT/.sid"
printf '0' > "$SID_FILE"

# jit-drive: assert_contains contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

# jit-drive: assert_missing not_contains capture
assert_missing() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should not contain: $unexpected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (exit $rc)"
  fi
}

# An entry in one layer of one dimension. The frontmatter is the real thing, so
# rebuild-tsv.sh writes the row rather than this file writing it.
mk_tool_entry() {
  # $1 base, $2 layer, $3 name, $4 match token
  mkdir -p "$1/tools/$2"
  {
    printf -- '---\n'
    printf 'title: tool rule %s\n' "$3"
    printf 'tool: Bash\n'
    printf 'match: %s\n' "$4"
    printf 'mode: remind\n'
    printf -- '---\n\n'
    printf 'TOOLBODY-%s\n' "$3"
  } > "$1/tools/$2/$3.md"
}

mk_path_entry() {
  # $1 base, $2 layer, $3 name, $4 match ERE
  mkdir -p "$1/paths/$2"
  {
    printf -- '---\n'
    printf 'title: path rule %s\n' "$3"
    printf 'match: %s\n' "$4"
    printf -- '---\n\n'
    printf 'PATHBODY-%s\n' "$3"
  } > "$1/paths/$2/$3.md"
}

mk_vocab_entry() {
  # $1 base, $2 layer, $3 name, $4 keyword, $5 optional module for 01-paths.tsv
  mkdir -p "$1/vocabulary/$2"
  {
    printf -- '---\n'
    printf 'title: vocab %s\n' "$3"
    printf 'keywords: %s\n' "$4"
    printf -- '---\n\n'
    printf 'VOCABBODY-%s\n' "$3"
    if [ -n "${5:-}" ]; then
      printf '\n## Modules\n\n%s\n' "$5"
    fi
  } > "$1/vocabulary/$2/$3.md"
}

rebuild() {
  CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/rebuild-tsv.sh" > /dev/null 2>&1
}

# A fresh session id per call: every dimension dedups on a shown-file, so reusing one id
# makes the SECOND assertion in a section pass or fail for a reason that has nothing to do
# with layers -- an entry is withheld because it was already delivered, and the hook
# answers `{}` exactly as it would for a layer it could not read.
#
# THE COUNTER IS A FILE, and that is not incidental. A shell variable was the first cut of
# this, and it silently did nothing: every call site here reads the hook through `$( )`,
# and the helper therefore runs in a subshell whose increment is discarded. All thirty-odd
# assertions ran under one session id. Section J is what found it -- three engines, the
# first passing and the other two answering `{}` for a defect that was in this file.
# Set beside the trap above, where TMPROOT exists.
next_sid() {
  local n
  n=$(($(cat "$SID_FILE") + 1))
  printf '%s' "$n" > "$SID_FILE"
  printf 'sess%03d' "$n"
}

run_tool() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$2" "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2> /dev/null
}

run_path() {
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"},"session_id":"%s"}' "$2" "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-path-hook.sh" 2> /dev/null
}

run_prompt() {
  printf '{"prompt":"%s","session_id":"%s"}' "$2" "$(next_sid)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-prompt-hook.sh" 2> /dev/null
}

# ---------------------------------------------------------------------------
echo "=== A: paths -- an 01-oss layer beside an 00-manual one ==="

PROJ="$TMPROOT/a"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual manual 'manualfile\.php$'
mk_path_entry "$BASE" 01-oss ossp 'ossfile\.php$'
rebuild "$PROJ"

# The rebuild indexed BOTH. This is the asymmetry: every tool that writes or counts saw
# the layer, and only the matcher did not.
if [ -s "$BASE/paths/01-oss/00-index.tsv" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: A rebuild-tsv.sh indexed the 01-oss layer"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: A rebuild-tsv.sh wrote no 01-oss index -- the fixture is wrong, not the hook"
fi

OUT=$(run_path "$PROJ" "/x/manualfile.php")
RC=$?
assert_rc0 "A the path hook exits 0" "$RC"
assert_contains "A POSITIVE CONTROL: the 00-manual entry fires" "$OUT" "PATHBODY-manual"
OUT=$(run_path "$PROJ" "/x/ossfile.php")
assert_contains "A the 01-oss entry fires too" "$OUT" "PATHBODY-ossp"

# ---------------------------------------------------------------------------
echo ""
echo "=== B: tools -- the dimension that can BLOCK read one layer and no others ==="

PROJ="$TMPROOT/b"
BASE="$PROJ/.claude/jit-context"
mk_tool_entry "$BASE" 00-manual tmanual 'manualtarget'
mk_tool_entry "$BASE" 01-oss toss 'osstarget'
# Not an invented name: docs/layers.md says a `20-grouped` entry is indexed and fires. In the
# tools dimension it never did, because there was no layer loop there at all.
mk_tool_entry "$BASE" 20-grouped tgroup 'grouptarget'
rebuild "$PROJ"

OUT=$(run_tool "$PROJ" "manualtarget now")
RC=$?
assert_rc0 "B the tool hook exits 0" "$RC"
assert_contains "B POSITIVE CONTROL: the 00-manual tool rule fires" "$OUT" "TOOLBODY-tmanual"
OUT=$(run_tool "$PROJ" "osstarget now")
assert_contains "B the 01-oss tool rule fires" "$OUT" "TOOLBODY-toss"
OUT=$(run_tool "$PROJ" "grouptarget now")
assert_contains "B the 20-grouped tool rule fires, as docs/layers.md promises" "$OUT" "TOOLBODY-tgroup"

# A tools layer can refuse a call. A block rule that never loaded fails OPEN, silently,
# which is the worst shape this defect takes and the one claude-oss filed against.
mkdir -p "$BASE/tools/01-oss"
{
  printf -- '---\n'
  printf 'title: blocked target\n'
  printf 'tool: Bash\n'
  printf 'match: blocktarget\n'
  printf 'mode: block\n'
  printf -- '---\n\n'
  printf 'TOOLBODY-block\n'
} > "$BASE/tools/01-oss/tblock.md"
rebuild "$PROJ"
OUT=$(run_tool "$PROJ" "blocktarget now")
assert_contains "B a mode:block rule in 01-oss actually blocks" "$OUT" '"decision":"block"'
assert_contains "B and the denial names the rule" "$OUT" "TOOLBODY-block"

# ---------------------------------------------------------------------------
echo ""
echo "=== C: vocabulary at prompt time ==="

PROJ="$TMPROOT/c"
BASE="$PROJ/.claude/jit-context"
mk_vocab_entry "$BASE" 00-manual vmanual 'manualword'
mk_vocab_entry "$BASE" 01-oss voss 'osssword'
rebuild "$PROJ"

OUT=$(run_prompt "$PROJ" "tell me about manualword please")
RC=$?
assert_rc0 "C the prompt hook exits 0" "$RC"
assert_contains "C POSITIVE CONTROL: the 00-manual vocab entry fires" "$OUT" "VOCABBODY-vmanual"
OUT=$(run_prompt "$PROJ" "tell me about osssword please")
assert_contains "C the 01-oss vocab entry fires" "$OUT" "VOCABBODY-voss"

# ---------------------------------------------------------------------------
echo ""
echo "=== D: vocabulary reached from the tool hook, on a path token ==="

PROJ="$TMPROOT/d"
BASE="$PROJ/.claude/jit-context"
mk_vocab_entry "$BASE" 00-manual dmanual 'dmanualword'
mk_vocab_entry "$BASE" 01-oss doss 'dosssword'
rebuild "$PROJ"

OUT=$(run_tool "$PROJ" "cat src/dmanualword/x.php")
assert_contains "D POSITIVE CONTROL: 00-manual vocab fires from a path token" "$OUT" "VOCABBODY-dmanual"
OUT=$(run_tool "$PROJ" "cat src/dosssword/x.php")
assert_contains "D 01-oss vocab fires from a path token" "$OUT" "VOCABBODY-doss"

# ---------------------------------------------------------------------------
echo ""
echo "=== E: vocabulary path mappings, the second index of the same layer ==="

# pre-path-hook.sh line 424 reused ONE `layers` array across two different dimension
# bases. Once layers are enumerated per dimension those two lists can legitimately
# differ, so this section builds a tree where they DO: `paths/` here has no 01-oss layer
# at all and `vocabulary/` does.
PROJ="$TMPROOT/e"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual epath 'epathfile\.php$'
mk_vocab_entry "$BASE" 00-manual emanual 'emanualword' 'Emanualmod'
mk_vocab_entry "$BASE" 01-oss eoss 'eosssword' 'Eossmod'
rebuild "$PROJ"

if [ -s "$BASE/vocabulary/01-oss/01-paths.tsv" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: E rebuild-tsv.sh wrote the 01-oss path mappings"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: E no 01-oss 01-paths.tsv -- the fixture is wrong, not the hook"
fi

e_run() {
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"},"session_id":"%s"}' "$1" "$(next_sid)" \
    | env DYNAMIC_RULES_VOCAB_PATHS=1 CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPTS/pre-path-hook.sh" 2> /dev/null
}
OUT=$(e_run "src/x/epathfile.php")
assert_contains "E POSITIVE CONTROL: the paths dimension still fires here" "$OUT" "PATHBODY-epath"
OUT=$(e_run "src/Emanualmod/a.php")
assert_contains "E the 00-manual path mapping fires" "$OUT" "VOCABBODY-emanual"
OUT=$(e_run "src/Eossmod/a.php")
assert_contains "E the 01-oss path mapping fires, though paths/ has no such layer" "$OUT" "VOCABBODY-eoss"

# ---------------------------------------------------------------------------
echo ""
echo "=== F: the third state -- a layer the matcher declines to read is NAMED ==="

# The whole point of #176. A rule that never matched and a rule that never loaded rendered
# identically, and every signal available to the reporter said the layer was healthy.
#
# The layer name arrives with the clone, so it is attacker-chosen text of the family
# common.sh cites above jit_report_name() (#35, #113, #124): refused when it is not
# [A-Za-z0-9._-]+, and never echoed into a report.
PROJ="$TMPROOT/f"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual fmanual 'ffile\.php$'
rebuild "$PROJ"
# After the rebuild, so the hand-written index below is what the matcher would find if it
# read this layer at all -- and so the refusal is about the NAME rather than about a
# missing file.
mkdir -p "$BASE/paths/bad name"
printf 'zzz\tnope.md\t\t\t\t\n' > "$BASE/paths/bad name/00-index.tsv"
printf -- '---\ntitle: x\nmatch: zzz\n---\n\nNOPEBODY\n' > "$BASE/paths/bad name/nope.md"

OUT=$(run_path "$PROJ" "/x/ffile.php")
RC=$?
assert_rc0 "F the hook still exits 0 with an unreadable layer present" "$RC"
assert_contains "F POSITIVE CONTROL: the honest layer beside it still fires" "$OUT" "PATHBODY-fmanual"
assert_contains "F the refused layer is reported rather than skipped in silence" "$OUT" "layer directory"
assert_missing "F and its name is never echoed into the report" "$OUT" "bad name"
assert_missing "F nothing from the refused layer is injected" "$OUT" "NOPEBODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== G: ordering is precedence, and the numeric prefixes are what decide it ==="

PROJ="$TMPROOT/g"
BASE="$PROJ/.claude/jit-context"
# One match token, three layers. The injected text must carry them in prefix order.
mk_path_entry "$BASE" 30-crosscutting gcross 'gfile\.php$'
mk_path_entry "$BASE" 01-oss goss 'gfile\.php$'
mk_path_entry "$BASE" 00-manual gmanual 'gfile\.php$'
rebuild "$PROJ"

OUT=$(run_path "$PROJ" "/x/gfile.php")
assert_contains "G all three layers fire (00-manual)" "$OUT" "PATHBODY-gmanual"
assert_contains "G all three layers fire (01-oss)" "$OUT" "PATHBODY-goss"
assert_contains "G all three layers fire (30-crosscutting)" "$OUT" "PATHBODY-gcross"
ORDER=$(grep -o 'PATHBODY-g[a-z]*' <<< "$OUT" | tr '\n' ' ')
if [ "$ORDER" = "PATHBODY-gmanual PATHBODY-goss PATHBODY-gcross " ]; then
  PASS=$((PASS + 1))
  echo "  PASS: G layers are scanned in numeric-prefix order"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: G layer order is not the prefix order"
  echo "    expected: PATHBODY-gmanual PATHBODY-goss PATHBODY-gcross "
  echo "    got: $ORDER"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== H: the count is bounded, and crossing the bound says so ==="

# A layer list whose length the clone chooses is the JIT_SYMLINKS problem one directory
# up. Truncating quietly would be this defect with a fix wearing its name.
#
# #313: each filler layer here costs rebuild-tsv.sh a real pass (two _ms() perl forks, a
# wc, and a report_bad_bytes awk), measured at ~0.05s/layer on this machine and the
# dominant cost of this whole suite on Windows CI. JIT_LAYERS_MAX is 64 and is not
# overridable by env, so crossing it needs more than 64 real layer directories -- but not
# 80 of them. 66 clears the bound with a 3-layer margin (65th, 66th, 67th refused) instead
# of a 17-layer one, for the same assertions below.
PROJ="$TMPROOT/h"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual hmanual 'hfile\.php$'
i=0
while [ "$i" -lt 66 ]; do
  mkdir -p "$(printf '%s/paths/9%02d-filler' "$BASE" "$i")"
  i=$((i + 1))
done
rebuild "$PROJ"

OUT=$(run_path "$PROJ" "/x/hfile.php")
RC=$?
assert_rc0 "H the hook exits 0 over the bound" "$RC"
assert_contains "H POSITIVE CONTROL: 00-manual still fires -- the bound never costs the first layers" "$OUT" "PATHBODY-hmanual"
assert_contains "H and the hook says the layer list was cut" "$OUT" "layer directories"

# ---------------------------------------------------------------------------
echo ""
echo "=== I: the layer set and the report set are the same set ==="

# jit_scan_layers() inlines jit_report_name()s character set rather than calling it, to
# avoid a fork per layer inside a 30-110 ms budget. Two copies of one rule drift, and the
# drift here is invisible in exactly the direction that matters: a name jit_report_name()
# withholds and the scan ACCEPTS is attacker text loaded as a layer; a name it accepts and
# the scan REFUSES is a dead layer nobody can explain. The comment above jit_report_name()
# in common.sh records that this repository keeps rediscovering that lesson -- this is the
# check rather than the citation, and it is the same shape tests/test-dry-run-names.sh
# uses against the copy in rebuild-tsv.sh.
#
# DRIVEN, not compared as source. Each name becomes a real layer directory holding a real
# entry, and the load verdict is read off the hook.
I_NAMES=(
  "00-manual" "01-oss" "a" "a.b" "a_b" "a-b" "Z9"
  "-lead" ".hidden" "_lead" "a b" "a;b" "aa"
)
# Brace expansion rather than `seq`: git-for-windows has shipped without `seq` in the
# bash it provides, and a helper that is missing there would take this whole section out
# on the one platform none of us runs.
# shellcheck disable=SC2086
I_NAMES+=("$(printf 'a%.0s' {1..64})")
I_NAMES+=("$(printf 'a%.0s' {1..65})")

I_DISAGREE=0
I_CHECKED=0
I_LOADED=0
I_REFUSED=0
for nm in "${I_NAMES[@]}"; do
  PROJ="$TMPROOT/i-case"
  rm -rf "$PROJ"
  BASE="$PROJ/.claude/jit-context"
  mkdir -p "$BASE/paths/$nm" 2> /dev/null || continue
  printf -- '---\ntitle: t\nmatch: ifile\\.php$\n---\n\nIBODY\n' > "$BASE/paths/$nm/i.md"
  rebuild "$PROJ"
  OUT=$(run_path "$PROJ" "/x/ifile.php")
  if grep -qF -- "IBODY" <<< "$OUT"; then loaded=yes; else loaded=no; fi
  # A subshell on purpose: sourcing common.sh into this shell would export its refusal
  # accumulators into every hook this suite runs afterwards.
  # shellcheck disable=SC1091
  RN=$(CLAUDE_PROJECT_DIR="$PROJ" bash -c '. "$1/common.sh" >/dev/null 2>&1; jit_report_name "$2"' _ "$SCRIPTS" "$nm")
  if [ "$RN" = "$nm" ]; then reportable=yes; else reportable=no; fi
  I_CHECKED=$((I_CHECKED + 1))
  if [ "$loaded" = yes ]; then I_LOADED=$((I_LOADED + 1)); else I_REFUSED=$((I_REFUSED + 1)); fi
  if [ "$loaded" != "$reportable" ]; then
    I_DISAGREE=$((I_DISAGREE + 1))
    echo "    DISAGREE: a layer name of ${#nm} bytes -- loaded=$loaded reportable=$reportable"
  fi
done

# The positive control for this section is its own count. A loop that built no case at all
# reports zero disagreements, which is the shape of every silent pass this repository has
# had to fix -- so the count is asserted before the verdict is believed.
if [ "$I_CHECKED" -lt 10 ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: I only $I_CHECKED name(s) were driven -- the verdict below is about the harness"
else
  PASS=$((PASS + 1))
  echo "  PASS: I $I_CHECKED layer names were driven through both halves"
fi
# BOTH verdicts must have been observed. "They agree on every one" is satisfied for free
# by a harness where nothing ever loads, and equally by one where nothing is ever refused,
# and those are the two ways this section could pass while testing nothing.
if [ "$I_LOADED" -gt 0 ] && [ "$I_REFUSED" -gt 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: I both verdicts were seen ($I_LOADED loaded, $I_REFUSED refused)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: I only one verdict was ever produced ($I_LOADED loaded, $I_REFUSED refused) -- the agreement below is vacuous"
fi
if [ "$I_DISAGREE" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: I the loader and jit_report_name agree on every one"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: I $I_DISAGREE name(s) load and report differently"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== J: every awk on this machine, because the list is a split() now ==="

# The enumeration is `n = split(list, layers, " ")` where it used to be a literal and a
# hardcoded 4. Two properties of that decide whether a dimension is read correctly, and
# both are engine-facing:
#
#   - an EMPTY list must split to ZERO, not to one empty element. One element would make
#     the loop build an index path with an empty layer name in it -- a doubled slash
#     directly under the dimension root, which is not the tree and reports nothing about
#     it, for a dimension that has no readable layer at all.
#   - a two-element list must split to two, in order.
#
# `split(s, a, " ")` with a single-space separator is awks whitespace-splitting special
# case rather than a literal space, so it is exactly the construct where engines could
# differ. Measured rather than assumed: awk 20200816, gawk 5.4.1 and mawk 1.3.4 all answer
# 0 and 2. CI runs three platforms and does not run the same engine on each, so the whole
# hook is driven per engine here rather than the property being checked in isolation.
ENGINE_BIN=$(mktemp -d "$TMPROOT/engines-XXXXXX")
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2> /dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

if [ -z "$ENGINES" ]; then
  # Never a silent pass: no engine means this section checked nothing.
  FAIL=$((FAIL + 1))
  echo "  FAIL: J no awk was found on PATH, so no engine was driven"
else
  # Two layers that must both fire, and a dimension whose every layer is refused so that
  # the empty-list case is reached on the same run.
  PROJ="$TMPROOT/j"
  BASE="$PROJ/.claude/jit-context"
  mk_path_entry "$BASE" 00-manual jmanual 'jfile\.php$'
  mk_path_entry "$BASE" 01-oss joss 'jfile\.php$'
  rebuild "$PROJ"
  mkdir -p "$BASE/vocabulary/bad name"

  for eng in $ENGINES; do
    OUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/x/jfile.php"},"session_id":"%s"}' "$(next_sid)" \
      | env DYNAMIC_RULES_VOCAB_PATHS=1 PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$PROJ" \
        bash "$SCRIPTS/pre-path-hook.sh" 2> /dev/null)
    RC=$?
    assert_rc0 "J [$eng] the hook exits 0" "$RC"
    assert_contains "J [$eng] both layers of a two-layer list fire (00-manual)" "$OUT" "PATHBODY-jmanual"
    assert_contains "J [$eng] both layers of a two-layer list fire (01-oss)" "$OUT" "PATHBODY-joss"
    assert_contains "J [$eng] a dimension with no readable layer is reported, not scanned" "$OUT" "layer directory"

    # The empty-list half, probed DIRECTLY rather than through the hook. An earlier cut of
    # this section asserted that the string `vocabulary//` was absent from the hook output
    # -- which is true under every implementation, correct or broken, because a getline on
    # a path that does not exist returns -1 and the path is never printed. That assertion
    # would have passed if the code did nothing, which is the thing this suite exists to
    # not do. The property is engine-facing, so it is asked of the engine.
    SPLIT0=$(PATH="$ENGINE_BIN/$eng:$PATH" awk 'BEGIN { printf "%d", split("", a, " ") }' 2> /dev/null)
    if [ "$SPLIT0" = "0" ]; then
      PASS=$((PASS + 1))
      echo "  PASS: J [$eng] an empty layer list splits to zero elements, not one empty name"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: J [$eng] an empty layer list split to '$SPLIT0' elements -- the loop would read an index under the dimension root"
    fi
    # ...and the control for that probe: the same engine must split a real list to two, or
    # a `0` above could be an engine that failed to run at all.
    SPLIT2=$(PATH="$ENGINE_BIN/$eng:$PATH" awk 'BEGIN { n = split("00-manual 01-oss", a, " "); printf "%d:%s:%s", n, a[1], a[2] }' 2> /dev/null)
    if [ "$SPLIT2" = "2:00-manual:01-oss" ]; then
      PASS=$((PASS + 1))
      echo "  PASS: J [$eng] POSITIVE CONTROL: a two-layer list splits to two, in order"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: J [$eng] a two-layer list gave '$SPLIT2' -- the zero above says nothing"
    fi
  done
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== K: the two refusal branches that need a permission bit to reach ==="

# Added after review: sections A-J drove the bad-NAME branch and the count bound, and left
# two of the five refusal branches in jit_scan_layers() with no fixture at all -- a layer
# directory that cannot be opened, and a layer whose index cannot be read. A guard nothing
# reaches is a guard that is nominally on and effectively off, which is the shape of the
# defect this whole change is about, one level in.
#
# chmod is ADVISORY on some filesystems and largely synthetic under git-for-windows, so
# each case probes whether the bit actually took effect and reports SKIPPED when it did
# not. Neither a pass nor a failure: an assertion that cannot be constructed here must not
# render as one that was constructed and held.
k_probe_denied() {
  # Did chmod actually deny us? Root ignores the bits entirely.
  [ "$(id -u 2> /dev/null || echo 1)" != "0" ] || return 1
  ! ls "$1" > /dev/null 2>&1
}

PROJ="$TMPROOT/k1"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual kmanual 'kfile\.php$'
mk_path_entry "$BASE" 01-locked klocked 'kfile\.php$'
rebuild "$PROJ"
chmod 000 "$BASE/paths/01-locked" 2> /dev/null
if ! k_probe_denied "$BASE/paths/01-locked"; then
  chmod 755 "$BASE/paths/01-locked" 2> /dev/null
  echo "  SKIPPED: this filesystem or user ignores the directory permission bits, so the"
  echo "           unopenable-layer branch went undriven -- neither a pass nor a failure"
else
  OUT=$(run_path "$PROJ" "/x/kfile.php")
  RC=$?
  chmod 755 "$BASE/paths/01-locked" 2> /dev/null
  assert_rc0 "K the hook exits 0 with an unopenable layer present" "$RC"
  assert_contains "K POSITIVE CONTROL: the readable layer beside it still fires" "$OUT" "PATHBODY-kmanual"
  assert_contains "K the unopenable layer is named, not skipped" "$OUT" "could not be opened"
  assert_missing "K and nothing from it is injected" "$OUT" "PATHBODY-klocked"
fi

PROJ="$TMPROOT/k2"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual kmanual2 'kfile\.php$'
mk_path_entry "$BASE" 01-noindex knoindex 'kfile\.php$'
rebuild "$PROJ"
chmod 000 "$BASE/paths/01-noindex/00-index.tsv" 2> /dev/null
# `( : < file )` rather than a reader: it opens the file and nothing else, so there is no
# process to close a pipe early. tests/test-inert-without-tree.sh probes the write bit the
# same way, and tests/test-assertion-helpers.sh refuses the `head -c1` spelling by name.
if [ "$(id -u 2> /dev/null || echo 1)" = "0" ] || (: < "$BASE/paths/01-noindex/00-index.tsv") 2> /dev/null; then
  chmod 644 "$BASE/paths/01-noindex/00-index.tsv" 2> /dev/null
  echo "  SKIPPED: this filesystem or user ignores the file permission bits, so the"
  echo "           unreadable-index branch went undriven -- neither a pass nor a failure"
else
  OUT=$(run_path "$PROJ" "/x/kfile.php")
  RC=$?
  chmod 644 "$BASE/paths/01-noindex/00-index.tsv" 2> /dev/null
  assert_rc0 "K the hook exits 0 with an unreadable index present" "$RC"
  assert_contains "K POSITIVE CONTROL: the readable layer beside it still fires" "$OUT" "PATHBODY-kmanual2"
  assert_contains "K the layer whose index cannot be read is named" "$OUT" "an index inside it could not be opened"
  assert_missing "K and nothing from it is injected" "$OUT" "PATHBODY-knoindex"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== L: the refusal LIST is capped in bytes and the COUNT is not ==="

# Also added after review. Section H drives JIT_LAYERS_MAX, the cap on how many layers are
# read, which collapses to a single refusal line however many layers sit past it. The other
# cap -- JIT_LAYERS_REFUSED_MAX, on the bytes of the refusal text -- needs dozens of
# INDIVIDUALLY refused layers to reach, and nothing constructed that.
#
# The property that matters is the asymmetry: the list is truncated and says so, and the
# COUNT is the whole total anyway. A notice that quietly stopped at N would tell the reader
# N layers were refused, which is a false statement produced by a defence.
PROJ="$TMPROOT/l"
BASE="$PROJ/.claude/jit-context"
mk_path_entry "$BASE" 00-manual lmanual 'lfile\.php$'
rebuild "$PROJ"
i=0
while [ "$i" -lt 70 ]; do
  # Every one of these is refused on its NAME, so none of them counts toward the 64-layer
  # bound and each contributes its own bullet.
  mkdir -p "$(printf '%s/paths/bad %02d' "$BASE" "$i")"
  i=$((i + 1))
done

OUT=$(run_path "$PROJ" "/x/lfile.php")
RC=$?
assert_rc0 "L the hook exits 0 with 70 refused layers" "$RC"
assert_contains "L POSITIVE CONTROL: the honest layer still fires" "$OUT" "PATHBODY-lmanual"
assert_contains "L the count is the whole total, not the number that fitted" "$OUT" "70 jit-context layer directories"
assert_contains "L the list says plainly that the rest are not in it" "$OUT" "the remaining refused layer directories are not listed here"
assert_missing "L and no refused directory name is echoed" "$OUT" "bad 42"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
