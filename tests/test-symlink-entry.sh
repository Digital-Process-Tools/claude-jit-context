#!/bin/bash
# S3: an entry file that is a SYMBOLIC LINK out of the tree.
#
# PR #11 closed the string form -- an index row of `../../../../outside.txt` is refused
# because the name is not bare. It did not close this form: the name in the index IS bare,
# so it passes that check, and `getline` then follows the link. Reproduced 2026-08-11
# against every read site.
#
# Two shapes, because `[ -L ]` on the entry file only sees the first:
#   S3a  the entry FILE is a symlink to a file outside the project.
#   S3b  the LAYER DIRECTORY is a symlink to a directory outside the project, carrying its
#        own 00-index.tsv -- so the attacker needs nothing inside the tree but the link.
#
# `git clone` recreates both, so cloning a repository is the whole attack.
#
# Every negative is paired with a positive control that a real entry still fires, because
# a fix that broke entry loading outright would satisfy the negative half on its own.
#
# Usage: bash tests/test-symlink-entry.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF "$expected"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF "$unexpected"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CANARY="SECRET-CANARY-DO-NOT-INJECT"
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
printf '%s\n' "$CANARY" > "$OUTSIDE/secret.txt"

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/paths/00-manual" \
           "$p/.claude/jit-context/tools/00-manual" \
           "$p/.claude/jit-context/vocabulary/00-manual"
  printf '%s' "$p"
}

run_hook() {
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$2" bash "$SCRIPTS/$1" 2>&1
}

TOOL_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"sectarget run"}}'
PATH_PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"src/sectarget/a.txt"}}'
PROMPT_PAYLOAD='{"prompt":"tell me about sectarget"}'

echo "=== S3a: the entry FILE is a symlink out of the tree ==="

P="$(new_project s3a-tool)"
D="$P/.claude/jit-context/tools/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/evil.md"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\tevil.md\t\t\t\n' > "$D/00-index.tsv"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' >> "$D/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_not_contains "tool rule: symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "tool rule: the refusal is named in context" "$OUT" "could not be evaluated"
assert_contains "tool rule: positive control -- a real entry still fires" "$OUT" "legit body"

P="$(new_project s3a-path)"
D="$P/.claude/jit-context/paths/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/evil.md"
printf 'legit body\n' > "$D/good.md"
printf 'sectarget\tevil.md\n' > "$D/00-index.tsv"
printf 'sectarget\tgood.md\n' >> "$D/00-index.tsv"
OUT="$(run_hook pre-path-hook.sh "$P" "$PATH_PAYLOAD")"
assert_not_contains "path rule: symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "path rule: the refusal is named in context" "$OUT" "could not be evaluated"
assert_contains "path rule: positive control -- a real entry still fires" "$OUT" "legit body"

P="$(new_project s3a-prompt)"
D="$P/.claude/jit-context/vocabulary/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/evil.md"
printf 'legit body\n' > "$D/good.md"
printf 'sectarget\tevil.md\n' > "$D/00-index.tsv"
printf 'sectarget\tgood.md\n' >> "$D/00-index.tsv"
OUT="$(run_hook pre-prompt-hook.sh "$P" "$PROMPT_PAYLOAD")"
assert_not_contains "prompt vocab: symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "prompt vocab: the refusal is named in context" "$OUT" "could not be evaluated"
assert_contains "prompt vocab: positive control -- a real entry still fires" "$OUT" "legit body"

P="$(new_project s3a-toolvocab)"
D="$P/.claude/jit-context/vocabulary/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/evil.md"
printf 'legit body\n' > "$D/good.md"
printf 'sectarget\tevil.md\n' > "$D/00-index.tsv"
printf 'sectarget\tgood.md\n' >> "$D/00-index.tsv"
: > "$P/.claude/jit-context/tools/00-manual/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$P" '{"tool_name":"Edit","tool_input":{"file_path":"src/sectarget/a.txt"}}')"
assert_not_contains "tool vocab: symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "tool vocab: the refusal is named in context" "$OUT" "could not be evaluated"
assert_contains "tool vocab: positive control -- a real entry still fires" "$OUT" "legit body"

P="$(new_project s3a-pathvocab)"
D="$P/.claude/jit-context/vocabulary/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/evil.md"
printf 'legit body\n' > "$D/good.md"
printf 'sectarget/\tevil.md\n' > "$D/01-paths.tsv"
printf 'sectarget/\tgood.md\n' >> "$D/01-paths.tsv"
: > "$P/.claude/jit-context/paths/00-manual/00-index.tsv"
OUT="$(printf '%s' "$PATH_PAYLOAD" | CLAUDE_PROJECT_DIR="$P" JIT_CONTEXT_VOCAB_PATHS=1 bash "$SCRIPTS/pre-path-hook.sh" 2>&1)"
assert_not_contains "path vocab: symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "path vocab: the refusal is named in context" "$OUT" "could not be evaluated"
assert_contains "path vocab: positive control -- a real entry still fires" "$OUT" "legit body"

echo ""
echo "=== S3b: the LAYER DIRECTORY is a symlink out of the tree ==="

P="$(new_project s3b-tool)"
EVILDIR="$TMP/evildir-tool"
mkdir -p "$EVILDIR"
printf '%s\n' "$CANARY" > "$EVILDIR/entry.md"
printf 'Bash\tsectarget\tentry.md\t\t\t\n' > "$EVILDIR/00-index.tsv"
rm -rf "$P/.claude/jit-context/tools/00-manual"
ln -sfn "$EVILDIR" "$P/.claude/jit-context/tools/00-manual"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_not_contains "tool rule: symlinked layer dir does not leak its contents" "$OUT" "$CANARY"
assert_contains "tool rule: the refused layer is named in context" "$OUT" "could not be evaluated"

P="$(new_project s3b-prompt)"
EVILDIR="$TMP/evildir-vocab"
mkdir -p "$EVILDIR"
printf '%s\n' "$CANARY" > "$EVILDIR/entry.md"
printf 'sectarget\tentry.md\n' > "$EVILDIR/00-index.tsv"
rm -rf "$P/.claude/jit-context/vocabulary/00-manual"
ln -sfn "$EVILDIR" "$P/.claude/jit-context/vocabulary/00-manual"
OUT="$(run_hook pre-prompt-hook.sh "$P" "$PROMPT_PAYLOAD")"
assert_not_contains "prompt vocab: symlinked layer dir does not leak its contents" "$OUT" "$CANARY"
assert_contains "prompt vocab: the refused layer is named in context" "$OUT" "could not be evaluated"

echo ""
echo "=== S3c: an ANCESTOR of the layer is a symlink out of the tree ==="

# The glob sweep starts at .claude/jit-context. Two directories above the layer are still
# inside the repository, and git carries either of them as a link exactly like an entry:
#   S3c-i   .claude/jit-context -> outside
#   S3c-ii  .claude             -> outside
# The second one leaked on the first cut of this fix -- the sweep never lstat'd anything
# above its own base -- so it is driven here rather than reasoned about.

P="$TMP/s3c-jit"
rm -rf "$P"; mkdir -p "$P/.claude"
EVILDIR="$TMP/evil-jitroot/tools/00-manual"
mkdir -p "$EVILDIR"
printf '%s\n' "$CANARY" > "$EVILDIR/entry.md"
printf 'Bash\tsectarget\tentry.md\t\t\t\n' > "$EVILDIR/00-index.tsv"
ln -sfn "$TMP/evil-jitroot" "$P/.claude/jit-context"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_not_contains "linked jit-context root does not leak its contents" "$OUT" "$CANARY"
assert_contains "linked jit-context root is named in context" "$OUT" "could not be evaluated"

P="$TMP/s3c-claude"
rm -rf "$P"; mkdir -p "$P"
EVILDIR="$TMP/evil-claude/jit-context/tools/00-manual"
mkdir -p "$EVILDIR"
printf '%s\n' "$CANARY" > "$EVILDIR/entry.md"
printf 'Bash\tsectarget\tentry.md\t\t\t\n' > "$EVILDIR/00-index.tsv"
ln -sfn "$TMP/evil-claude" "$P/.claude"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_not_contains "linked .claude does not leak its contents" "$OUT" "$CANARY"
assert_contains "linked .claude is named in context" "$OUT" "could not be evaluated"

# The bound on that walk, driven rather than assumed. Only the two directories the clone
# owns are tested; everything above the project belongs to the user. On macOS /tmp is
# itself a symlink, so a sweep that walked to the root would refuse every honest tree
# opened through one -- and this repo would have shipped that.
mkdir -p "$TMP/linked-parent-real/proj/.claude/jit-context/tools/00-manual"
ln -sfn "$TMP/linked-parent-real" "$TMP/linked-parent"
D="$TMP/linked-parent-real/proj/.claude/jit-context/tools/00-manual"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' > "$D/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$TMP/linked-parent/proj" "$TOOL_PAYLOAD")"
assert_contains "a project reached through a linked parent still fires" "$OUT" "legit body"
assert_not_contains "a project reached through a linked parent refuses nothing" "$OUT" "could not be evaluated"

echo ""
echo "=== Negative control: an ordinary tree is untouched ==="

P="$(new_project clean)"
D="$P/.claude/jit-context/tools/00-manual"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' > "$D/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_contains "clean tree: the entry fires" "$OUT" "legit body"
assert_not_contains "clean tree: nothing is refused" "$OUT" "could not be evaluated"

OUT="$(run_hook pre-tool-hook.sh "$P" '{"tool_name":"Bash","tool_input":{"command":"echo unrelated"}}')"
assert_not_contains "clean tree: an unrelated command stays silent" "$OUT" "legit body"

P="$(new_project inside)"
D="$P/.claude/jit-context/tools/00-manual"
printf 'inside body\n' > "$D/real.md"
ln -sf real.md "$D/link.md"
printf 'Bash\tsectarget\tlink.md\t\t\t\n' > "$D/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_not_contains "in-tree symlink: refused too, and its target is not injected" "$OUT" "inside body"
assert_contains "in-tree symlink: the refusal is named" "$OUT" "could not be evaluated"

echo ""
echo "=== jit-dry-run.sh reaches the same verdict ==="

# The refusal notice the hooks inject tells the author to lint the tree with this script.
# If it clears a row the hooks refuse, that advice sends them looking at the wrong thing --
# so the linter is driven against both shapes, not just compiled once by hand.
#
# It also lints the tree named by --base, which is NOT this session's project, so it has to
# sweep that tree itself rather than inherit the one common.sh built.

P="$(new_project dryrun-file)"
D="$P/.claude/jit-context/tools/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/evil.md"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\tevil.md\t\t\t\n' > "$D/00-index.tsv"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' >> "$D/00-index.tsv"
OUT="$(bash "$SCRIPTS/jit-dry-run.sh" --base "$P/.claude/jit-context" --tool Bash --command "sectarget run" 2>&1)"
RC=$?
assert_contains "dry-run: the linked entry is refused and named" "$OUT" "the entry file is a symbolic link"
assert_contains "dry-run: the second line is about the link, not the name" "$OUT" "replace the link with the file"
assert_not_contains "dry-run: the traversal wording is not printed for a link" "$OUT" "so this row leaves the tree"
assert_contains "dry-run: the honest row beside it still lints ok" "$OUT" "good.md"
assert_not_contains "dry-run: the target is never read into the report" "$OUT" "$CANARY"
if [ "$RC" -eq 1 ]; then
  PASS=$((PASS + 1)); echo "  PASS: dry-run exits 1 on a refused row"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: dry-run exited $RC, expected 1"
fi

P="$(new_project dryrun-dir)"
EVILDIR="$TMP/evildir-dryrun"
mkdir -p "$EVILDIR"
printf '%s\n' "$CANARY" > "$EVILDIR/entry.md"
printf 'Bash\tsectarget\tentry.md\t\t\t\n' > "$EVILDIR/00-index.tsv"
rm -rf "$P/.claude/jit-context/tools/00-manual"
ln -sfn "$EVILDIR" "$P/.claude/jit-context/tools/00-manual"
OUT="$(bash "$SCRIPTS/jit-dry-run.sh" --base "$P/.claude/jit-context" --tool Bash --command "sectarget run" 2>&1)"
assert_contains "dry-run: the linked layer directory is refused and named" "$OUT" "its layer directory is a symbolic link"
assert_not_contains "dry-run: the linked layer leaks nothing" "$OUT" "$CANARY"

# Negative control: a clean tree must lint clean, or the linter is refusing everything.
P="$(new_project dryrun-clean)"
D="$P/.claude/jit-context/tools/00-manual"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' > "$D/00-index.tsv"
OUT="$(bash "$SCRIPTS/jit-dry-run.sh" --base "$P/.claude/jit-context" --tool Bash --command "sectarget run" 2>&1)"
RC=$?
assert_not_contains "dry-run: a clean tree refuses nothing" "$OUT" "REFUSED"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: dry-run exits 0 on a clean tree"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: dry-run on a clean tree exited $RC, expected 0"
fi

echo ""
echo "=== Failure paths still exit 0 and say nothing ==="

P="$TMP/no-such-project"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
RC=$?
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: missing tree exits 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: missing tree exited $RC"
fi
assert_not_contains "missing tree injects nothing" "$OUT" "could not be evaluated"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
