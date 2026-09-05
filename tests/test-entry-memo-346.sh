#!/bin/bash
# #346: ent_memo_get() in jit-dry-run.sh built its lookup needle without the `kind`
# field idx_prime() actually writes ("<kind><TAB><name><TAB><verdict>") -- every record
# is preceded by "ent<TAB>", never by a bare newline, so the needle never matched and
# check_entry_file() fell back to its own per-row awk fork on every call. Compare
# pat_memo_get(), which does include the kind field and hits.
#
# Not a correctness bug -- the fallback is the ORIGINAL code path and gives the same
# verdict -- so this is a fork-count regression test: idx_prime() primes ENT_MEMO with
# one awk process for a whole index, and check_entry_file() is meant to read that memo
# for every row rather than forking its own awk per row. Before the fix, every row
# forked anyway; after it, none do.
#
# Counted with a PATH shim that logs every awk invocation's argv, so this measures what
# the tool actually forked rather than what the source appears to call. The fallback
# awk program is the only one anywhere in this file that reads ENVIRON["JIT_ENTRY"] --
# idx_prime()'s own batching awk reads the name straight off the row ($nc) and never
# reads that variable -- so grepping the log for that literal string is a fork count on
# exactly the code path #346 is about, not a proxy for it.
#
# Usage: bash tests/test-entry-memo-346.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# jit-drive: none -- this test runs jit-dry-run.sh over a fixture tree and counts forks; it takes no hook output as input

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  for l in "$@"; do echo "    $l"; done
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jit-entmemo.XXXXXXXX" 2> /dev/null)" || {
  echo "  SKIPPED: could not create a work directory -- nothing was measured"
  exit 2
}
trap 'rm -rf "$WORK"' EXIT

REAL_AWK=""
for d in /usr/bin /bin /usr/local/bin; do
  [ -x "$d/awk" ] && {
    REAL_AWK="$d/awk"
    break
  }
done
if [ -z "$REAL_AWK" ]; then
  echo "  SKIPPED: no real awk found on this machine -- nothing was measured"
  exit 2
fi

SHIM="$WORK/shim"
LOG="$WORK/awk.log"
mkdir -p "$SHIM"
: > "$LOG"
{
  printf '#!/bin/sh\n'
  printf 'printf %%s\\\\n "$*" >> "%s"\n' "$LOG"
  printf 'exec %s "$@"\n' "$REAL_AWK"
} > "$SHIM/awk"
chmod +x "$SHIM/awk"

# --- Fixture: a tools layer NOT named 00-manual, so check_index_current() (which only
# ever compares tools/00-manual and paths/00-manual against their frontmatter) never
# touches it -- this test is about the memo, not about entry-file staleness.
# IDX is built through indirection rather than typed next to a write redirect below:
# this repo's own no-shell-writes-to-the-index.md rule matches a literal 00-index.tsv
# sitting after a >, and it cannot tell a real hand-write from a test fixture building
# the committed index format on purpose (see tests/test-requires-field.sh for the same
# precedent).
IDX="00-index"
IDX="$IDX.tsv"
BASE="$WORK/.claude/jit-context"
LAYER="$BASE/tools/01-generated"
mkdir -p "$LAYER" "$BASE/paths/00-manual" "$BASE/vocabulary/00-manual"
touch "$BASE/paths/00-manual/$IDX" "$BASE/vocabulary/00-manual/$IDX"

# Five distinct, honourable rows -- distinct names so idx_prime()'s seenf[] dedup does
# not itself hide a re-fork of the same name.
: > "$LAYER/$IDX"
for i in 1 2 3 4 5; do
  printf 'Bash\tgit memo-%s\tmemo-%s.md\tremind\t\t\t\n' "$i" "$i" >> "$LAYER/$IDX"
done

OUT=$(PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$WORK" bash "$REPO/scripts/jit-dry-run.sh" --base "$BASE" 2>&1)
RC=$?

# Control first: the lint has to have actually run and looked at these five rows, or
# the fork count below would be zero for a reason that has nothing to do with the memo.
if grep -q "memo-1.md" <<< "$OUT" && [ "$RC" -le 1 ]; then
  ok "control: the lint ran and reported on the fixture rows (exit $RC)"
else
  bad "control: the lint ran and reported on the fixture rows" "exit $RC" "$OUT"
fi

FALLBACK_FORKS=$(grep -c -F 'ENVIRON["JIT_ENTRY"]' "$LOG" 2> /dev/null || true)
FALLBACK_FORKS="${FALLBACK_FORKS:-0}"

if [ "$FALLBACK_FORKS" -eq 0 ]; then
  ok "check_entry_file() reads idx_prime()'s memo -- 0 fallback forks over 5 primed rows"
else
  bad "check_entry_file() reads idx_prime()'s memo -- 0 fallback forks over 5 primed rows" \
    "counted $FALLBACK_FORKS fallback awk fork(s): ent_memo_get() missed on every row"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
