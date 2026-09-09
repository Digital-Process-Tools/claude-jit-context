#!/bin/bash
# #379: rebuild-tsv.sh spent 68% of a 1m50s, 195-entry rebuild in process spawn rather
# than work, and the per-layer timings in the issue point at the keyword loop inside
# build_vocab_tsv() -- roughly constant cost per KEYWORD (12-15ms) across layers of very
# different sizes, which is what a per-keyword fork looks like from outside.
#
# Same technique as tests/test-fork-count.sh: a PATH shim in front of the real binaries,
# counting how many times rebuild-tsv.sh actually forks each one over a synthetic
# vocabulary layer. What is asserted is a bound that scales with the number of FILES,
# never with the number of KEYWORDS -- 5 entries carrying 10 keywords each (50 keywords
# total) is the fixture, so any assertion of the shape "at most a small constant times
# the file count" is already falsified by the old per-keyword loop, which forked
# multiple times per keyword regardless of file count.
#
# Usage: bash tests/test-rebuild-fork-count-379.sh
#
# jit-drive: none -- every helper here runs rebuild-tsv.sh through a PATH shim and
# counts forks by name; none takes hook/script output as an assert_*-shaped argument

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jit-rebuild-fork.XXXXXXXX" 2> /dev/null)" || {
  echo "  SKIPPED: could not create a work directory -- nothing was measured"
  exit 2
}
trap 'rm -rf "$WORK"' EXIT

# --- Fixture: 5 vocabulary entries, 10 keywords each (50 keywords, well short of the
# 6999 in the issue, but the assertion is a bound tied to FILE count, so 5 files is
# enough to distinguish "forks per keyword" from "forks per file").
PROJ="$WORK/proj"
mkdir -p "$PROJ/.claude/jit-context/vocabulary/00-manual"
for i in 1 2 3 4 5; do
  cat > "$PROJ/.claude/jit-context/vocabulary/00-manual/entry$i.md" << MD
---
title: Fixture entry $i
description: A synthetic entry for the #379 fork-count regression.
keywords: alpha$i, bravo$i, charlie$i, delta$i, echo$i, foxtrot$i, golf$i, hotel$i, india$i, juliet$i
---

Body of fixture entry $i.
MD
done

# --- Shim: one exec wrapper per command, ahead of PATH, appending its own name to a
# tally file. Measures what the script actually forked, not what the source appears to
# call.
SHIM="$WORK/shim"
COUNT="$WORK/count"
mkdir -p "$SHIM"
: > "$COUNT"

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

spawns_of() {
  local n
  n=$(grep -c -x -F "$1" "$COUNT" 2> /dev/null)
  printf '%s' "${n:-0}"
}

: > "$COUNT"
(cd "$PROJ" && PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$PROJ" \
  bash "$REPO/scripts/rebuild-tsv.sh" > "$WORK/rebuild.out" 2>&1)
rc=$?

echo "=== control: the shim saw the rebuild fork at all, and it wrote an index ==="
if [ "$(spawns_of awk)" -ge 1 ]; then
  pass "the shim counted the rebuild's own awk"
else
  fail "the shim counted the rebuild's own awk" \
    "counted: $(wc -l < "$COUNT" | tr -d '[:space:]') spawn(s), none of them awk" \
    "shimmed:$SHIMMED" "exit=$rc" "$(cat "$WORK/rebuild.out")"
  echo ""
  echo "========================"
  echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
  echo "========================"
  exit 1
fi
IDX="$PROJ/.claude/jit-context/vocabulary/00-manual/00-index.tsv"
if [ -s "$IDX" ] && [ "$(wc -l < "$IDX" | tr -d '[:space:]')" -eq 50 ]; then
  pass "control: the index was written with all 50 keyword rows"
else
  fail "control: the index was written with all 50 keyword rows" \
    "$([ -f "$IDX" ] && wc -l < "$IDX" || echo 'no index file')" "exit=$rc"
fi

echo ""
echo "=== the keyword classify loop forks per FILE, not per KEYWORD ==="
# 5 files, 50 keywords. The old loop forked sed once, tr+sed once (2), and grep once
# (blacklist) per KEYWORD -- at least 4 * 50 = 200 forks from grep/sed/tr alone, on top
# of whatever the rest of the script needs. A per-FILE (or per-layer) design costs a
# small, file-count-scaled number of forks: generously, at most 4 per file for this
# step plus a handful for the rest of the pipeline (frontmatter extraction, the Latin-1
# fold, the batched generic-word classify). 40 is comfortably above any per-file
# accounting and comfortably below the old per-keyword total (200+).
for t in grep sed tr; do
  n=$(spawns_of "$t")
  if [ "$n" -le 40 ]; then
    pass "rebuild-tsv.sh forks $t at most 40 times over 5 files/50 keywords (counted $n)"
  else
    fail "rebuild-tsv.sh forks $t at most 40 times over 5 files/50 keywords" \
      "counted $n -- scales with keyword count, not file count" "exit=$rc"
  fi
done

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
