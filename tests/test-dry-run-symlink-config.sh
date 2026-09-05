#!/bin/bash
# #159: jit-dry-run.sh prints two REFUSED rows when the tree config.env is a symbolic
# link (scripts/jit-dry-run.sh, the "config.env, for the tree named by --base" block).
# Both columns of that print are literals, so #154's static coverage enumeration already
# passes them -- what nothing drives is the BRANCH: that the rows appear when config.env
# IS a symlink, and that they do NOT appear when it is an ordinary file.
#
# Fabricating "no symlinks" the way test-symlink-required.sh does is overkill here: this
# suite does not construct an attack, it drives one [ -L ] branch in one script. It gates
# the same way test-symlink-entry.sh does -- a probe that proves a write through the link
# survives, not just [ -L ] -- and exits 2, honestly, when the platform cannot build one.
#
# Usage: bash tests/test-dry-run-symlink-config.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRYRUN="$SCRIPT_DIR/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Can this platform make a symbolic link at all, and does it behave like one? --------
CAN_SYMLINK=no
probe_symlinks() {
  local t="$TMP/.symlink-probe.target" l="$TMP/.symlink-probe.link"
  printf 'probe\n' > "$t" || return 1
  ln -sf "$t" "$l" 2> /dev/null
  [ -L "$l" ] || return 1
  printf 'late\n' >> "$t" || return 1
  grep -q 'late' "$l" || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
echo "symlink support: $CAN_SYMLINK (verified through the link)"
echo ""

BASE="$TMP/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual"
IDXNAME="00-index"
IDXNAME="$IDXNAME.tsv"
IDX="$BASE/tools/00-manual/$IDXNAME"
printf 'Bash\tirrelevant\tgood.md\t\t\t\n' > "$IDX"
printf 'good body\n' > "$BASE/tools/00-manual/good.md"

echo "=== Positive control: an ordinary config.env is read, never refused ==="
printf 'JIT_CONTEXT_VOCAB_PATHS=1\n' > "$BASE/config.env"
OUT="$(CLAUDE_PROJECT_DIR="$TMP" bash "$DRYRUN" --base "$BASE" 2>&1)"
assert_not_contains "an ordinary file is not refused as a symlink" "$OUT" "is a symbolic link"
assert_contains "an ordinary file is still reported as read" "$OUT" "config.env"
rm -f "$BASE/config.env"

if [ "$CAN_SYMLINK" != yes ]; then
  echo ""
  echo "SKIPPED: this platform did not create a symbolic link (or a write through it did"
  echo "         not survive), so the negative half -- config.env AS a symlink -- could"
  echo "         not be constructed. Only the positive control above ran."
  echo ""
  echo "$PASS passed, $FAIL failed, the symlink-refusal branch SKIPPED"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 2
fi

echo ""
echo "=== The negative: a symlinked config.env is refused, whole-file, and not read ==="
OUTSIDE="$TMP/outside-config.env"
printf 'JIT_CONTEXT_VOCAB_PATHS=1\n' > "$OUTSIDE"
ln -sf "$OUTSIDE" "$BASE/config.env"
OUT="$(CLAUDE_PROJECT_DIR="$TMP" bash "$DRYRUN" --base "$BASE" 2>&1)"
assert_contains "the symlinked config.env is named" "$OUT" "config.env"
assert_contains "it is refused as a symbolic link" "$OUT" "is a symbolic link, so it is not read at all"
assert_contains "the row points at the same refusal the hooks make" "$OUT" "the hooks refuse it too"
rm -f "$BASE/config.env"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
