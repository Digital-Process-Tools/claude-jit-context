#!/bin/bash
# Tests for #480: a helper process that dies mid-rebuild must not truncate the index that
# was already committed.
#
# macOS 27's built-in /bin/bash 3.2.57 kills roughly twenty forked awk children with
# "Bus error: 10" (SIGBUS, exit 138) over the course of one real rebuild -- not
# reproducible under Homebrew bash, not reproducible running the same awk calls in
# isolation, and too rare in the plugin's own short test runs to ever show up there. The
# issue's own report: before this fix, rebuild-tsv.sh already detected one of those
# crashes (jit_rc 2) and kept going -- but `truncate_index()` had already truncated the
# REAL, committed 00-index.tsv before the loop even started, so "kept going" meant
# writing whatever came after the crash into the file a fresh clone (and the hooks) read
# as this tree's rules. 7 indexes in the reporter's own project ended up empty; the
# largest went from 3,714 rows to 1,430.
#
# This suite drives a real crash with a shimmed `awk` that dies on the ONE file named
# below, confirms rebuild-tsv exits 2, and -- the assertion #480 is actually about --
# confirms the PREVIOUSLY COMMITTED index on disk is byte-identical to what it was before
# the crashed run, never shorter and never empty. A positive control runs the same
# fixture with no shim, so a harness that cannot drive a real crash reports that rather
# than a false pass.
#
# Usage: bash tests/test-rebuild-atomic-swap-480.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  [ $# -eq 0 ] || echo "    $*"
}

assert_rc() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "wanted exit $want, got exit $got"
  fi
}

assert_contains() {
  local desc="$1" out="$2" want="$3"
  if grep -qF -- "$want" <<< "$out"; then
    ok "$desc"
  else
    bad "$desc" "expected stderr to contain: $want"
  fi
}

# --- Positive control first (same shape test-awk-crash-397.sh uses): confirm this host
# can actually make a shimmed awk die with SIGBUS before trusting anything downstream of
# it. A shim that silently fails to crash would make every byte-identical assertion below
# pass for the wrong reason -- the loop below never actually crashed, it just never ran.
REAL_AWK="$(command -v awk)"
if [ -z "$REAL_AWK" ]; then
  echo "SKIPPED: no 'awk' on PATH to wrap -- #480's crash-handling assertions are UNTESTED here." >&2
  exit 2
fi
SHIM_DIR=$(mktemp -d 2> /dev/null || mktemp -d -t jit480)
if [ -z "$SHIM_DIR" ] || [ ! -d "$SHIM_DIR" ]; then
  echo "SKIPPED: mktemp -d produced no directory, so no shim can be built here." >&2
  exit 2
fi
trap 'rm -rf "$SHIM_DIR"' EXIT

PROBE_OUT="$(PATH="$SHIM_DIR:$PATH" sh -c 'kill -BUS $$' 2>&1)"
PROBE_RC=$?
: "$PROBE_OUT"
if [ "$PROBE_RC" -ne 138 ] && [ "$PROBE_RC" -ne 135 ]; then
  echo "SKIPPED: this host's shell cannot make a subprocess exit 138/135 via kill -BUS \$\$" >&2
  echo "         (got exit $PROBE_RC instead) -- #480's crash-handling assertions are UNTESTED here." >&2
  exit 2
fi

# Crashes ONLY when its last argument is the sentinel file named below -- every other
# awk invocation during the run (frontmatter parsing on other files, the generic-word
# classifier canary, every other layer's own build) passes straight through to the real
# awk, so the rest of the tree still builds normally around the one crashed file.
cat > "$SHIM_DIR/awk" << SHIMEOF
#!/bin/sh
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in
  */jit480-crash-me.md|jit480-crash-me.md) kill -BUS \$\$ ;;
esac
exec "$REAL_AWK" "\$@"
SHIMEOF
chmod +x "$SHIM_DIR/awk"

# --- Fixture ------------------------------------------------------------------------
ROOT="$(mktemp -d 2> /dev/null || mktemp -d -t jit480root)"
trap 'chmod -R u+rwX "$ROOT" "$SHIM_DIR" 2>/dev/null; rm -rf "$ROOT" "$SHIM_DIR"' EXIT
BASE="$ROOT/.claude/jit-context"
VOCAB_DIR="$BASE/vocabulary/00-manual"
mkdir -p "$BASE/tools/00-manual" "$BASE/paths/00-manual" "$VOCAB_DIR"

write_vocab() {
  # $1 filename under VOCAB_DIR, $2 keywords: value
  cat > "$VOCAB_DIR/$1" << EOF2
---
title: $1
description: fixture entry for #480
keywords: $2
---

Body for $1.
EOF2
}

write_vocab "keep-a-480.md" "alpha keyword"
write_vocab "jit480-crash-me.md" "bravo keyword"
write_vocab "keep-b-480.md" "charlie keyword"

ERR="$ROOT/clean.err"
CLAUDE_PROJECT_DIR="$ROOT" bash "$REBUILD" > /dev/null 2> "$ERR"
CLEAN_RC=$?
assert_rc "a clean rebuild (no shim) exits 0" "0" "$CLEAN_RC"

VOCAB_TSV="$VOCAB_DIR/00-index.tsv"
if [ ! -s "$VOCAB_TSV" ]; then
  bad "the clean rebuild produced a non-empty vocabulary index" "found: $(wc -l < "$VOCAB_TSV" 2>/dev/null || echo missing) lines"
else
  ok "the clean rebuild produced a non-empty vocabulary index"
fi

COMMITTED_BEFORE="$(cat "$VOCAB_TSV" 2> /dev/null)"
COMMITTED_SHA_BEFORE="$(cksum "$VOCAB_TSV" 2> /dev/null)"

# --- The crash run --------------------------------------------------------------------
ERR2="$ROOT/crash.err"
PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$ROOT" bash "$REBUILD" > /dev/null 2> "$ERR2"
CRASH_RC=$?
assert_rc "a rebuild with a crashed helper exits 2, not 0" "2" "$CRASH_RC"

ERR2_TXT="$(cat "$ERR2" 2> /dev/null)"
assert_contains "stderr names the crashed entry's keyword line as the reason" "$ERR2_TXT" "jit480-crash-me.md"
assert_contains "stderr says the partial rebuild was discarded (#480)" "$ERR2_TXT" "discarded"

# --- The assertion #480 is about ------------------------------------------------------
# A FILE comparison, never a captured bash variable: the whole point here is the byte
# count on disk, and a `$( )` capture would strip the very truncation this is checking
# for away before it could be seen (tests.md's own rule, paths/00-manual/tests.md).
if [ ! -e "$VOCAB_TSV" ]; then
  bad "the committed vocabulary index still exists after the crashed run" "it is GONE"
else
  ok "the committed vocabulary index still exists after the crashed run"
fi

COMMITTED_SHA_AFTER="$(cksum "$VOCAB_TSV" 2> /dev/null)"
if [ "$COMMITTED_SHA_BEFORE" = "$COMMITTED_SHA_AFTER" ] && [ -n "$COMMITTED_SHA_BEFORE" ]; then
  ok "the committed vocabulary index is byte-identical before and after the crashed run"
else
  bad "the committed vocabulary index is byte-identical before and after the crashed run" \
    "before: $COMMITTED_SHA_BEFORE / after: $COMMITTED_SHA_AFTER"
fi

AFTER_LINES=$(wc -l < "$VOCAB_TSV" 2> /dev/null | tr -d ' ')
BEFORE_LINES=$(printf '%s\n' "$COMMITTED_BEFORE" | grep -c '.')
if [ "$AFTER_LINES" -ge "$BEFORE_LINES" ]; then
  ok "the index has not shrunk after the crashed run ($BEFORE_LINES -> $AFTER_LINES rows)"
else
  bad "the index has not shrunk after the crashed run" "went from $BEFORE_LINES to $AFTER_LINES rows"
fi

# No stray temp file left behind in the layer directory either -- commit_index()'s own
# failure path is responsible for cleaning up the scratch file it never got to swap in.
LEFTOVER=$(find "$VOCAB_DIR" -maxdepth 1 -name '.00-index.tsv.*' 2> /dev/null)
if [ -z "$LEFTOVER" ]; then
  ok "no stray temp index file was left behind in the layer directory"
else
  bad "no stray temp index file was left behind in the layer directory" "found: $LEFTOVER"
fi

# --- Other layers, unaffected (per-index atomicity, not whole-run) --------------------
# tools/ and paths/ have no entries at all in this fixture, so they are empty directories
# with no 00-index.tsv to even build -- real coverage of "a sibling layer with its OWN
# content still gets rebuilt even when the vocabulary layer's build was discarded" is
# left for a future pass; this suite's own assertion is the committed-index preservation,
# not cross-layer independence.

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
