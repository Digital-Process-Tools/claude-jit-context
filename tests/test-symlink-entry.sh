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
  if grep -qF "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY STDOUT>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF "$unexpected" <<<"$output"; then
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

# A red in this suite is a FINDING. Do not re-run it and take the second answer.
#
# It used to be a coin flip: the once-per-session markers keyed on /tmp/claude-*-shown-$PPID.txt,
# every call here is wrapped in $( ) so the hook inherited the command-substitution subshell
# as its $PPID -- a short-lived, readily recycled pid -- and a recycled one carried a stale
# marker in. What went silent was the REFUSAL NOTICE, the security-relevant output, so the
# positive controls below reddened at random with nothing wrong with them.
#
# Fixed in #43 (67a66e7): the key is the payload's session_id, and a payload without one --
# every payload in this file -- gets no marker and no dedup at all. Nothing here suppresses
# anything any more, so a positive control that goes red went red for a reason.
run_hook() {
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$2" bash "$SCRIPTS/$1" 2>&1
}

TOOL_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"sectarget run"}}'
PATH_PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"src/sectarget/a.txt"}}'
PROMPT_PAYLOAD='{"prompt":"tell me about sectarget"}'

# --- Can this platform make a symbolic link at all? --------------------------
# Every containment case below is CONSTRUCTED with `ln -s`, so a platform that does not
# make symbolic links does not build the attack -- and then the guard correctly stays
# quiet, the canary is correctly injected from an ordinary file, and 28 assertions fail
# while testing nothing at all. Git Bash is that platform: the MSYS runtime copies the
# target instead of linking it unless MSYS=winsymlinks:nativestrict is set and the process
# holds the privilege. Windows CI on 2026-08-12 failed exactly that way.
#
# The probe tests the property the fixtures depend on, not just `[ -L ]`: content written
# to the target AFTER the link exists must be visible THROUGH it. That is the one thing a
# copy can never do, and it is what settled the CI diagnosis -- a layer directory linked
# before its files were written came back EMPTY, while one linked after came back full.
# No symbolic link can behave both ways; a copy taken at `ln` time behaves exactly so.
#
# The runner can DECLARE the capability a requirement: JIT_TESTS_REQUIRE_SYMLINKS=1 says
# this environment was configured to have symbolic links (see .github/workflows/tests.yml,
# which pairs it with MSYS=winsymlinks:nativestrict on the Windows leg). A probe that then
# says "no" is a broken configuration, not a platform without the capability, and the two
# get different verdicts below -- a skip renders green in run-all.sh, and a setting that
# stopped applying and was never noticed is the hole this suite already had once.
REQUIRE_SYMLINKS="${JIT_TESTS_REQUIRE_SYMLINKS:-}"
CAN_SYMLINK=no
probe_symlinks() {
  local d="$TMP/.symlink-probe"
  rm -rf "$d" || return 1
  mkdir -p "$d/target-dir" || return 1
  printf 'probe\n' > "$d/target-file" || return 1
  ln -sf "$d/target-file" "$d/link-file" 2>/dev/null
  ln -sfn "$d/target-dir" "$d/link-dir" 2>/dev/null
  # Written after BOTH links exist. A real link sees it. A copy cannot.
  printf 'late\n' > "$d/target-dir/late.txt" || return 1
  [ -L "$d/link-file" ] || return 1
  [ -L "$d/link-dir" ] || return 1
  [ -f "$d/link-dir/late.txt" ] || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
echo "symlink support: $CAN_SYMLINK (files and directories, verified through the link)"
if [ "$REQUIRE_SYMLINKS" = 1 ]; then
  echo "symbolic links are REQUIRED by this environment (JIT_TESTS_REQUIRE_SYMLINKS=1, MSYS=${MSYS:-<unset>})"
fi
echo ""

echo "=== The harness can build and run a project at all ==="
# This runs on every platform, before any link is needed. If it fails, the SKIPPED verdict
# below means nothing: a suite that cannot construct a PROJECT would report "could not
# construct the attack" for the wrong reason, and that is the same defect one level up.
P="$(new_project harness)"
D="$P/.claude/jit-context/tools/00-manual"
printf 'harness body\n' > "$D/good.md"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' > "$D/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_contains "harness: an ordinary entry fires" "$OUT" "harness body"
OUT="$(run_hook pre-tool-hook.sh "$P" '{"tool_name":"Bash","tool_input":{"command":"echo unrelated"}}')"
assert_not_contains "harness: an unrelated command stays silent" "$OUT" "harness body"

if [ "$CAN_SYMLINK" != yes ]; then
  echo ""
  echo "SKIPPED: this platform did not create a symbolic link, so the containment cases"
  echo "         below could not be constructed. Nothing about containment was tested."
  echo ""
  echo "         'ln -s' produced something that is not a link -- on Git Bash it copies the"
  echo "         target. A copy is not the attack: the hook reads an ordinary file, the"
  echo "         [ -L ] guard is correctly false, and asserting a refusal here would be"
  echo "         asserting it for a threat this platform failed to build."
  echo ""
  echo "         This is NOT a clean result for this suite, and it is not a defect in the"
  echo "         hooks. To make these cases real on Windows, the runner needs"
  echo "         MSYS=winsymlinks:nativestrict and the privilege to create symbolic links"
  echo "         (Developer Mode), plus git config core.symlinks=true for a checkout."
  echo ""
  if [ "$REQUIRE_SYMLINKS" = 1 ]; then
    echo "SYMBOLIC LINKS WERE REQUIRED AND NOT OBTAINED."
    echo ""
    echo "         This environment set JIT_TESTS_REQUIRE_SYMLINKS=1, so it was configured to"
    echo "         have the capability and did not get it. That is a broken configuration,"
    echo "         not a platform that never had symbolic links, and the two must not read the"
    echo "         same in a CI log. On the GitHub Windows image the runner needs"
    echo "         MSYS=winsymlinks:nativestrict exported to the bash step; Developer Mode is"
    echo "         already on in the image, and git config core.symlinks=true covers a"
    echo "         checkout that carries a committed link."
    echo ""
    echo "         Failing rather than skipping: run-all.sh renders a skip green, so a setting"
    echo "         that quietly stopped applying would restore the hole this probe exists to"
    echo "         close. Nothing here is a defect in the hooks."
    echo ""
    echo "$PASS passed, $FAIL failed, every containment case NOT RUN"
    exit 1
  fi
  echo "$PASS passed, $FAIL failed, every containment case SKIPPED"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 2
fi

echo ""
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
echo "=== S3d: config.env is a symlink out of the tree ==="

# The same trust boundary one file over. config.env is a direct child of JIT_BASE, so
# jit_scan_symlinks() already records it -- but jit_load_config() opened it by name and
# never consulted that set. git carries the link, so a clone chooses a file outside the
# project to be READ line by line, and a JIT_CONTEXT_* line that happens to be in the
# target then applies. No line text leaks, but the count and the reasons do.
#
# Refused and NAMED, in the channel config.env refusals already use. Silently ignoring the
# file would be the defect this repo exists to remove, wearing a fix as a disguise.

# Driven on the EFFECT of a setting, not on the wording of a notice. JIT_CONTEXT_VOCAB_PATHS
# is off by default and turns on the 01-paths.tsv vocabulary pass, so "the entry fires" and
# "the entry stays silent" are the two directions of "was that file honoured".
s3d_project() {
  local p; p="$(new_project "$1")"
  local d="$p/.claude/jit-context/vocabulary/00-manual"
  printf 'vocab-by-path body\n' > "$d/good.md"
  printf 'sectarget/\tgood.md\n' > "$d/01-paths.tsv"
  : > "$p/.claude/jit-context/paths/00-manual/00-index.tsv"
  printf '%s' "$p"
}

# Control FIRST, so the negative below is known to be testing something: an ordinary
# config.env carrying that setting does turn the pass on.
P="$(s3d_project s3d-ok)"
printf 'JIT_CONTEXT_VOCAB_PATHS=1\n' > "$P/.claude/jit-context/config.env"
OUT="$(run_hook pre-path-hook.sh "$P" "$PATH_PAYLOAD")"
assert_contains "honest config.env: the setting takes effect" "$OUT" "vocab-by-path body"
assert_not_contains "honest config.env: nothing is refused" "$OUT" "were refused"

P="$(s3d_project s3d)"
printf 'JIT_CONTEXT_VOCAB_PATHS=1\n' > "$TMP/outside/hostile.env"
ln -sf "$TMP/outside/hostile.env" "$P/.claude/jit-context/config.env"
OUT="$(run_hook pre-path-hook.sh "$P" "$PATH_PAYLOAD")"
assert_not_contains "linked config.env: the setting does NOT take effect" "$OUT" "vocab-by-path body"
assert_contains "linked config.env: the refusal is named" "$OUT" "config.env"
assert_contains "linked config.env: and says it is a link" "$OUT" "symbolic link"

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
echo "=== S3e: a DOT-NAMED entry file (#34 -- #13 reopened) ==="

# The sweep enumerates the tree with "$base"/*, "$base"/*/* and "$base"/*/*/*, and a glob
# `*` does not match a leading dot. So `.hidden.md` was never lstat-ed, never entered
# JIT_SYMLINKS, and the awk side cleared it -- while the identical link named `hidden.md`
# was refused. common.sh already stated the dot-glob problem for .discovery six lines
# below the sweep and did not apply it to the sweep.
#
# Every case here is paired with an honest entry in the same index, so a fix that refused
# everything would fail the pairing rather than pass it.

P="$(new_project s3e-tool)"
D="$P/.claude/jit-context/tools/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/.hidden.md"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\t.hidden.md\t\t\t\n' > "$D/00-index.tsv"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' >> "$D/00-index.tsv"
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_not_contains "tool rule: dot-named symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "tool rule: the dot-named row is refused and named" "$OUT" "could not be evaluated"
assert_contains "tool rule: positive control -- a real entry still fires beside it" "$OUT" "legit body"

P="$(new_project s3e-path)"
D="$P/.claude/jit-context/paths/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/.hidden.md"
printf 'legit body\n' > "$D/good.md"
printf 'sectarget\t.hidden.md\n' > "$D/00-index.tsv"
printf 'sectarget\tgood.md\n' >> "$D/00-index.tsv"
OUT="$(run_hook pre-path-hook.sh "$P" "$PATH_PAYLOAD")"
assert_not_contains "path rule: dot-named symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "path rule: the dot-named row is refused and named" "$OUT" "could not be evaluated"
assert_contains "path rule: positive control -- a real entry still fires beside it" "$OUT" "legit body"

P="$(new_project s3e-prompt)"
D="$P/.claude/jit-context/vocabulary/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/.hidden.md"
printf 'legit body\n' > "$D/good.md"
printf 'sectarget\t.hidden.md\n' > "$D/00-index.tsv"
printf 'sectarget\tgood.md\n' >> "$D/00-index.tsv"
OUT="$(run_hook pre-prompt-hook.sh "$P" "$PROMPT_PAYLOAD")"
assert_not_contains "prompt vocab: dot-named symlinked entry does not leak its target" "$OUT" "$CANARY"
assert_contains "prompt vocab: the dot-named row is refused and named" "$OUT" "could not be evaluated"
assert_contains "prompt vocab: positive control -- a real entry still fires beside it" "$OUT" "legit body"

# The sweep itself, not a hook. The name ban above closes the reachable attack; this is the
# other half, and it is about the GLOB rather than the name: a dot-named path anywhere under
# the base must be lstat-ed, so any future read site inherits the verdict instead of needing
# its own. Driven by sourcing common.sh and reading the set it exports.
sweep_of() {
  CLAUDE_PROJECT_DIR="$1" bash -c 'source "$0" >/dev/null 2>&1; printf "%s" "$JIT_SYMLINKS"' \
    "$SCRIPTS/common.sh"
}

P="$(new_project s3e-sweep)"
ln -sfn "$OUTSIDE" "$P/.claude/jit-context/.evil"
ln -sfn "$OUTSIDE" "$P/.claude/jit-context/tools/.evil"
ln -sfn "$OUTSIDE" "$P/.claude/jit-context/tools/00-manual/.evil"
SWEPT="$(sweep_of "$P")"
assert_contains "sweep: a dot-named path one level down is recorded" "$SWEPT" "/jit-context/.evil"
assert_contains "sweep: a dot-named path two levels down is recorded" "$SWEPT" "/tools/.evil"
assert_contains "sweep: a dot-named path three levels down is recorded" "$SWEPT" "/tools/00-manual/.evil"

# Paired positive control: the sweep must still see an ordinary name, or widening the glob
# has replaced the enumeration rather than extended it.
P="$(new_project s3e-sweep-plain)"
ln -sf "$OUTSIDE/secret.txt" "$P/.claude/jit-context/tools/00-manual/plain.md"
SWEPT="$(sweep_of "$P")"
assert_contains "sweep: an ordinary name is still recorded" "$SWEPT" "/tools/00-manual/plain.md"

# And an honest tree still sweeps to nothing, or every row everywhere is about to be refused.
P="$(new_project s3e-sweep-clean)"
printf 'body\n' > "$P/.claude/jit-context/tools/00-manual/good.md"
SWEPT="$(sweep_of "$P")"
assert_not_contains "sweep: an honest tree records no link at all" "$SWEPT" "/tools"

echo ""
echo "=== S3f: a tree with more links than the set can carry (#36) ==="

# JIT_SYMLINKS travels through the environment. It was unbounded, so past ARG_MAX every
# exec from common.sh onward failed: the hook emitted NOTHING, exited 0, printed
# "Argument list too long" to the session stderr, and a block rule that was present,
# indexed and honourable did not block. Both of this repo standing contracts at once --
# never fail hard, never write to a session stderr -- and it failed OPEN, not closed.
#
# Roughly 4000 attacker-named links did it on the audit host. Cheap for a hostile clone,
# unreachable for an honest tree.
#
# Driven in both directions in one fixture: the same tree, the same block rule, with and
# without the links.

P="$(new_project s3f)"
D="$P/.claude/jit-context/tools/00-manual"
printf 'block body here\n' > "$D/good.md"
printf 'Bash\tsectarget\tgood.md\tblock\t\t\n' > "$D/00-index.tsv"
# A vocabulary row too, because the prompt hook reads only that dimension: with no row there
# is nothing to refuse and the prompt hook would correctly say nothing, which is not what
# this case is asking about.
printf 'vocab body here\n' > "$P/.claude/jit-context/vocabulary/00-manual/vocab.md"
printf 'sectarget\tvocab.md\n' > "$P/.claude/jit-context/vocabulary/00-manual/00-index.tsv"

# Direction one: the honest tree. The block rule blocks.
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_contains "s3f control: an honourable block rule blocks before the links exist" "$OUT" '"decision":"block"'

# Now bury it. Names are padded so the byte budget is crossed with a few dozen links rather
# than a few thousand -- the budget is on BYTES, which is the quantity ARG_MAX is about, and
# 4000 short names and 40 long ones are the same problem.
PAD="$(printf 'p%.0s' $(seq 1 190))"
i=0
while [ "$i" -lt 200 ]; do
  i=$((i + 1))
  ln -s /etc/hosts "$D/$PAD$i.md"
done

OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
RC=$?
assert_not_contains "s3f: nothing is written to the session stderr" "$OUT" "Argument list too long"
assert_contains "s3f: the hook still emits JSON rather than nothing at all" "$OUT" "hookEventName"
assert_contains "s3f: and it refuses the tree rather than running unguarded" "$OUT" "too many symbolic links"
assert_not_contains "s3f: a rule in a tree nobody can vouch for does not fire" "$OUT" "block body here"
if [ "$RC" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: s3f: the hook still exits 0"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: s3f: the hook exited $RC, expected 0"
fi

# The other two hooks reach common.sh the same way, so they fail the same way.
OUT="$(run_hook pre-prompt-hook.sh "$P" "$PROMPT_PAYLOAD")"
assert_not_contains "s3f: prompt hook writes nothing to stderr either" "$OUT" "Argument list too long"
assert_contains "s3f: prompt hook reports the refused tree too" "$OUT" "too many symbolic links"
OUT="$(run_hook pre-path-hook.sh "$P" "$PATH_PAYLOAD")"
assert_not_contains "s3f: path hook writes nothing to stderr either" "$OUT" "Argument list too long"

# Direction two, back again: remove the links and the same block rule blocks again. Without
# this the suite would pass with the guard hardwired to refuse every tree it is ever shown.
rm -f "$D/$PAD"*.md
OUT="$(run_hook pre-tool-hook.sh "$P" "$TOOL_PAYLOAD")"
assert_contains "s3f: with the links gone the block rule blocks again" "$OUT" '"decision":"block"'
assert_not_contains "s3f: and nothing is refused any more" "$OUT" "too many symbolic links"

# jit-dry-run.sh sweeps the tree it was pointed at, so it reaches the same wall and must
# reach the same verdict rather than clearing the tree.
i=0
while [ "$i" -lt 200 ]; do
  i=$((i + 1))
  ln -s /etc/hosts "$D/$PAD$i.md"
done
OUT="$(bash "$SCRIPTS/jit-dry-run.sh" --base "$P/.claude/jit-context" --tool Bash --command "sectarget run" 2>&1)"
RC=$?
assert_contains "s3f: the linter refuses the tree too" "$OUT" "too many symbolic links"
assert_not_contains "s3f: and does not print Argument list too long" "$OUT" "Argument list too long"
if [ "$RC" -eq 1 ]; then
  PASS=$((PASS + 1)); echo "  PASS: s3f: the linter exits 1"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: s3f: the linter exited $RC, expected 1"
fi

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

# #34: the linter ran the same blind sweep, so it reported the hostile tree `ok` and exited
# 0 -- the tool the refusal notice sends the reader to said the attack was honourable. Half
# of #34 is exactly this, so it is driven here and not only through the hooks.
P="$(new_project dryrun-dotfile)"
D="$P/.claude/jit-context/tools/00-manual"
ln -sf "$OUTSIDE/secret.txt" "$D/.hidden.md"
printf 'legit body\n' > "$D/good.md"
printf 'Bash\tsectarget\t.hidden.md\t\t\t\n' > "$D/00-index.tsv"
printf 'Bash\tsectarget\tgood.md\t\t\t\n' >> "$D/00-index.tsv"
OUT="$(bash "$SCRIPTS/jit-dry-run.sh" --base "$P/.claude/jit-context" --tool Bash --command "sectarget run" 2>&1)"
RC=$?
assert_contains "dry-run: the dot-named row is REFUSED" "$OUT" "REFUSED"
assert_contains "dry-run: and the reason names the dot" "$OUT" "begins with a dot"
assert_not_contains "dry-run: the dot-named target is never read into the report" "$OUT" "$CANARY"
assert_contains "dry-run: the honest row beside it still lints ok" "$OUT" "good.md"
if [ "$RC" -eq 1 ]; then
  PASS=$((PASS + 1)); echo "  PASS: dry-run exits 1 on the dot-named row"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: dry-run exited $RC on the dot-named row, expected 1"
fi

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
