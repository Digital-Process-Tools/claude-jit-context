#!/bin/bash
# Tests for examples/jit-context/ -- the entries this repository ships to OTHER people.
#
# Every other suite either builds a synthetic tree (which proves the engine) or reads this
# repository's own .claude/jit-context/ (which proves the rules we wrote for ourselves).
# The four shipped samples were covered by neither: there is no 00-index.tsv under
# examples/ -- correctly, they are files to copy -- so nothing ever built them and nothing
# ever fired them, and `examples/` appeared in tests/ only as a literal path string inside
# one match assertion (#93). A sample that stops matching is worse than a rule that stops
# matching: it is the shape people copy for rules of their own (#94).
#
# So this suite does what a user does. It copies examples/jit-context/ into a scratch
# project, runs rebuild-tsv.sh there, and drives the REAL hooks against it.
#
# Why the hooks and not jit-dry-run.sh alone. The dry-run reports which rule fired, which
# is one inference short of the question this suite asks: #92 was a rule that was present,
# matched, and permitted the call anyway, and #98 was the linter disagreeing with the hook
# about whether a tree had been read at all. Only pre-tool-hook.sh emits the
# {"decision":"block"} a session acts on. The dry-run is still run, once, as a lint gate --
# with an ABSOLUTE --base, because a relative one makes it print SKIPPED for every sample
# and exit 0, which is the vacuous green this repository is about.
#
# Both directions for everything: the call it targets fires, the near-miss is silent, and
# every silence sits beside a positive control on the same code path.
#
# Usage: bash tests/test-shipped-examples.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD="$REPO/scripts/rebuild-tsv.sh"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
TOOL_HOOK="$REPO/scripts/pre-tool-hook.sh"
PATH_HOOK="$REPO/scripts/pre-path-hook.sh"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -eq 0 ] || echo "    $*"; return 0; }

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no scratch project can be built here."
  echo "           Nothing in this file was tested."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

PROJ="$TMP/project"
BASE="$PROJ/.claude/jit-context"
mkdir -p "$PROJ/.claude"

# The copy a user performs, verbatim and with no rearranging. If the shipped tree is not
# in the shape the hooks read, that is the finding -- so it is copied as-is and the layer
# directories are asserted below rather than manufactured here.
if ! cp -R "$REPO/examples/jit-context" "$BASE"; then
  echo "  FAIL: could not copy examples/jit-context into a scratch project"
  exit 1
fi

CLAUDE_PROJECT_DIR="$PROJ" bash "$REBUILD" > "$TMP/rebuild.txt" 2>&1
REBUILD_RC=$?

echo "=== the shipped tree is in the shape the hooks read ==="
# This is the harness probe and an assertion at once. rebuild-tsv.sh walks
# <dimension>/*/ for LAYER directories, and the hooks read <dimension>/00-manual/. A tree
# whose entries sit one level above that indexes nothing at all: `cp -R` it into a project
# and every rule is inert, in silence, which is this repository's own defect class shipped
# as its own documentation. Every assertion below would be vacuous, so this exits.
if [ "$REBUILD_RC" -ne 0 ]; then
  echo "  FAIL: rebuild-tsv.sh exited $REBUILD_RC over the shipped examples"
  cat "$TMP/rebuild.txt"
  exit 1
fi
for dim in paths tools vocabulary; do
  if [ -s "$BASE/$dim/00-manual/00-index.tsv" ]; then
    ok "$dim/00-manual/00-index.tsv was built and is not empty"
  else
    bad "$dim/00-manual/00-index.tsv was built and is not empty" \
        "the shipped $dim/ entries index to nothing -- copied into a project they are inert," \
        "and every assertion below would be vacuous. Stopping."
    ls -R "$BASE" 2>/dev/null
    exit 1
  fi
done

echo ""
echo "=== the shipped tree lints clean ==="
# ABSOLUTE --base. A relative one resolves against the dry-run's own working directory,
# prints SKIPPED for every sample and still exits 0.
bash "$DRYRUN" --base "$BASE" > "$TMP/lint.txt" 2>&1
LINT_RC=$?
if [ "$LINT_RC" -eq 0 ]; then
  ok "jit-dry-run.sh exits 0 over examples/ (nothing refused, nothing stale)"
else
  bad "jit-dry-run.sh exits 0 over examples/ (nothing refused, nothing stale)" "exit=$LINT_RC"
  cat "$TMP/lint.txt"
fi
if grep -q "SKIPPED" "$TMP/lint.txt"; then
  bad "the linter read the whole tree" "a SKIPPED row means an unknown number of rules went unchecked (#98)"
  grep "SKIPPED" "$TMP/lint.txt"
else
  ok "the linter read the whole tree (no SKIPPED row)"
fi

# --- Drivers ------------------------------------------------------------------
# Output goes to a file and the assertions read the file: $( ) silently drops NUL bytes,
# so a captured variable can pass an assertion against output it never saw. Nothing is
# piped into grep -q either -- the writer takes SIGPIPE on a match and pipefail turns a
# hit into a non-zero status (#56).
OUT="$TMP/hook-out.txt"

drive_tool() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" > "$TMP/payload.json"
  CLAUDE_PROJECT_DIR="$PROJ" bash "$TOOL_HOOK" < "$TMP/payload.json" > "$OUT" 2>/dev/null
}

drive_path() {
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1" > "$TMP/payload.json"
  CLAUDE_PROJECT_DIR="$PROJ" bash "$PATH_HOOK" < "$TMP/payload.json" > "$OUT" 2>/dev/null
}

# The same call with the module-path channel switched on. That channel is opt-in
# (JIT_CONTEXT_VOCAB_PATHS, default 0 in pre-path-hook.sh), which is the reason nothing in
# tests/ had ever reached it -- a driver that does not set the variable exercises the
# default and reports the feature silent, correctly and uselessly.
drive_path_vocab() {
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1" > "$TMP/payload.json"
  CLAUDE_PROJECT_DIR="$PROJ" JIT_CONTEXT_VOCAB_PATHS=1 \
    bash "$PATH_HOOK" < "$TMP/payload.json" > "$OUT" 2>/dev/null
}

drive_prompt() {
  printf '{"prompt":"%s"}' "$1" > "$TMP/payload.json"
  CLAUDE_PROJECT_DIR="$PROJ" bash "$PROMPT_HOOK" < "$TMP/payload.json" > "$OUT" 2>/dev/null
}

excerpt() { tr -d '\n' < "$OUT" | cut -c1-220; }

# The four below take (description, needle) and read the file the hook wrote, rather than
# the (description, CAPTURED OUTPUT, needle) most helpers in this tree carry -- because
# `$( )` silently drops NUL bytes (#78). The `jit-drive:` lines say exactly that, and
# tests/test-assertion-helpers.sh drives them on that declared shape. They were renamed
# to `expect_` when that harness still bound on the NAME and handed anything called
# `assert_blocked` its 1 MB payload as a needle; the name no longer decides anything
# (#110), and the declaration does.
#
# `--` before every needle. Half the strings this suite asserts on are command flags, and
# `grep -qF "--no-coverage"` is grep parsing its own argument list: it exits 2 with a usage
# message on stderr, which reads as "not found" and turns a block assertion red for a
# reason that has nothing to do with the hook.
# jit-drive: expect_out_has contains file:OUT
# jit-drive: expect_out_lacks not_contains file:OUT
# jit-drive: expect_blocked blocked file:OUT
# jit-drive: expect_not_blocked not_blocked file:OUT
expect_out_has() {
  # $1 desc, $2 needle
  if grep -qF -- "$2" "$OUT"; then ok "$1"; else
    bad "$1" "expected the hook output to name: $2" "got: $(excerpt)"
  fi
}

expect_out_lacks() {
  if grep -qF -- "$2" "$OUT"; then
    bad "$1" "$2 must NOT appear" "got: $(excerpt)"
  else ok "$1"; fi
}

expect_blocked() {
  # $1 desc, $2 needle that must appear in the block reason
  if grep -qF -- '"decision":"block"' "$OUT" && grep -qF -- "$2" "$OUT"; then ok "$1"; else
    bad "$1" "expected a block naming: $2" "got: $(excerpt)"
  fi
}

expect_not_blocked() {
  if grep -qF -- '"decision":"block"' "$OUT"; then
    bad "$1" "this call must NOT be blocked" "got: $(excerpt)"
  else ok "$1"; fi
}

# --- Positive controls, before any silence assertion --------------------------
# Each one proves the hook it guards can see this tree at all. Without them a hook that
# resolves nothing reports silence for everything, and every "must not fire" below passes
# on that emptiness -- which is precisely the vacuous result #93 is about.
echo ""
echo "=== the three hooks can all see the copied tree ==="
drive_tool "git push origin main"
if ! grep -qF "git-push.example.md" "$OUT"; then
  echo "  FAIL: the tool hook fires nothing for 'git push origin main' in the copied tree."
  echo "        Every tool assertion below would be vacuous. Stopping."
  cat "$OUT"; exit 1
fi
ok "the tool hook fires the shipped tools example"

drive_path "$PROJ/src/Billing/Total.php"
if ! grep -qF "php-coding.example.md" "$OUT"; then
  echo "  FAIL: the path hook fires nothing for a .php file in the copied tree."
  echo "        Every path assertion below would be vacuous. Stopping."
  cat "$OUT"; exit 1
fi
ok "the path hook fires the shipped paths example"

drive_prompt "how are invoice totals computed"
if ! grep -qF "billing.example.md" "$OUT"; then
  echo "  FAIL: the prompt hook fires nothing for the vocabulary example's own subject."
  echo "        Every vocabulary assertion below would be vacuous. Stopping."
  cat "$OUT"; exit 1
fi
ok "the prompt hook fires the shipped vocabulary example"

# --- tools: the anchor (#94) --------------------------------------------------
echo ""
echo "=== git-push.example.md fires on the invocation, not on the words ==="
RULE_PUSH="git-push.example.md"
drive_tool "git push origin main";    expect_out_has   "the command it targets"       "$RULE_PUSH"
drive_tool "cd /tmp && git push";     expect_out_has   "after a chain operator"       "$RULE_PUSH"
drive_tool "git -C /tmp push";        expect_out_has   "with an option between"       "$RULE_PUSH"
# The three near-misses. `git push` as a bare substring fired on the first two, and this is
# the headline tools example -- the shape people copy for their own block rules.
drive_tool "git pushd /tmp";          expect_out_lacks "a longer command word"        "$RULE_PUSH"
drive_tool "echo git push";           expect_out_lacks "the words inside an argument" "$RULE_PUSH"
drive_tool "git stash push";          expect_out_lacks "a different subcommand"       "$RULE_PUSH"

# --- tools: require, reachable (#94) ------------------------------------------
echo ""
echo "=== phpunit.example.md requires the flag, on a command someone would type ==="
drive_tool "bin/phpunit tests/Unit"
expect_blocked     "a local run without the flag is refused"       "--no-coverage"
drive_tool "bin/phpunit --no-coverage tests/Unit"
expect_not_blocked "the same run with the flag is allowed"
# Paired with the block above: same command, one flag apart, and the reason is the entry
# body rather than a bare refusal.
expect_out_has     "and the reminder still arrives"                "phpunit.example.md"
# The two spellings almost everyone actually types. An anchor that anchors on a command
# WORD misses both, and an entry that silently stops covering the command it is named
# after is the same silence as a rule that was never indexed.
drive_tool "./bin/phpunit --no-coverage tests/Unit"
expect_out_has     "a relative path spelling still matches"        "phpunit.example.md"
drive_tool "vendor/bin/phpunit --no-coverage tests/Unit"
expect_out_has     "and a vendored one"                            "phpunit.example.md"
drive_tool "cd api && bin/phpunit tests/Unit"
expect_blocked     "after a chain operator, still refused"         "--no-coverage"
# The other direction, and the one that was live until this change: `match: bin/phpunit`
# was a bare substring, so every command merely NAMING the file inherited the require and
# came back BLOCKED. Refusing `cat` on a log file is the #76 shape, in the entry this
# repository holds up as its example of require.
drive_tool "echo bin/phpunit is our test runner"
expect_not_blocked "narrating the command is not running it"
drive_tool "cat bin/phpunit-report.txt"
expect_not_blocked "reading a file whose name starts with it is not either"
drive_tool "cat notes/bin/phpunit.log"
expect_not_blocked "nor is a log named after it"

# --- tools: forbid, reachable (#94) -------------------------------------------
echo ""
echo "=== the forbid example refuses a command someone would type ==="
# require is evaluated before forbid and short-circuits it, so a forbid sharing an entry
# with a require on the same flag family can only ever speak on a self-contradictory
# command (#94). The mechanism is demonstrated where it is reachable instead.
drive_tool "git commit --no-verify -m fix"
expect_blocked     "the forbidden flag is refused"                 "--no-verify"
drive_tool "git commit -m fix"
expect_not_blocked "the same commit without it is allowed"
drive_tool "echo git commit --no-verify"
expect_not_blocked "and the words inside an argument are not a commit"

# --- paths --------------------------------------------------------------------
echo ""
echo "=== php-coding.example.md fires on a PHP file, and only on one ==="
RULE_PHP="php-coding.example.md"
drive_path "$PROJ/src/Billing/Total.php"; expect_out_has   "a php file"         "$RULE_PHP"
drive_path "$PROJ/notes.phpx";            expect_out_lacks "a lookalike suffix" "$RULE_PHP"
drive_path "$PROJ/README.md";             expect_out_lacks "a markdown file"    "$RULE_PHP"

# --- the module-path channel ---------------------------------------------------
echo ""
echo "=== the ## Modules channel maps a vocabulary entry onto a path ==="
# 01-paths.tsv, written by build_vocab_path_tsv() and read by pre-path-hook.sh. This
# repository's own tree has a 0-byte 01-paths.tsv, so #93 reported the channel as
# untestable here and asked for it to be named as a skip. It is testable: the shipped
# billing example carries a `## Modules` section, so copying examples/ into a scratch
# project is exactly the fixture that was missing. Nothing here is skipped.
if grep -q "billing.example.md" "$BASE/vocabulary/00-manual/01-paths.tsv" 2>/dev/null; then
  ok "the Modules section produced a row in 01-paths.tsv"
else
  bad "the Modules section produced a row in 01-paths.tsv" \
      "got: $(cat "$BASE/vocabulary/00-manual/01-paths.tsv" 2>&1)"
fi
RULE_BILL="billing.example.md"
drive_path_vocab "$PROJ/src/Billing/Total.php"
expect_out_has   "touching a file in the module injects the entry" "$RULE_BILL"
drive_path_vocab "$PROJ/src/Shipping/Label.php"
expect_out_lacks "a file in another module does not"               "$RULE_BILL"
# Positive control for the silence directly above: the same call fires the paths rule, so
# the miss is about the module and not about the hook seeing nothing.
expect_out_has   "control -- that same file still fires the php rule" "$RULE_PHP"
# And the gate itself, in the other direction. Without this the section above is a test of
# one env var rather than of the channel: a hook that injected the module entry
# unconditionally would satisfy every assertion above and would have changed the default
# behaviour of every installed copy.
drive_path "$PROJ/src/Billing/Total.php"
expect_out_lacks "the channel stays off by default"                "$RULE_BILL"
expect_out_has   "control -- the default run still fires the php rule" "$RULE_PHP"

# --- vocabulary keywords (#94) -------------------------------------------------
echo ""
echo "=== billing.example.md keys on product nouns, not on ordinary English ==="
drive_prompt "how are invoice totals computed";      expect_out_has   "its own subject"     "$RULE_BILL"
drive_prompt "what vat rate applies here";           expect_out_has   "a product noun"      "$RULE_BILL"
drive_prompt "why is amount_vat_out silently discarded"
expect_out_has   "the getter the entry is actually about"                 "$RULE_BILL"
# The tax this entry used to levy. `total` and `amount` are ordinary English, and the
# vocabulary dimension loads the whole file on a match -- so an unrelated sentence in an
# unrelated session paid for it. writing-rules.md, the entry jit-init.sh seeds into every
# new project from templates/, warns new users about exactly this -- and the sample they
# were told to copy from did it anyway.
drive_prompt "give me the total number of tests";    expect_out_lacks "an unrelated total"  "$RULE_BILL"
drive_prompt "what amount of memory does this need"; expect_out_lacks "an unrelated amount" "$RULE_BILL"
drive_prompt "deploy the app";                       expect_out_lacks "an unrelated prompt" "$RULE_BILL"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
