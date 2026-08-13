#!/bin/bash
# Tests for scripts/jit-init.sh -- the explicit copy-in that seeds a project (#81).
#
# The gap it closes: a fresh install matches nothing and injects nothing. The hooks
# create only .discovery/, so the first-run experience is "install it and nothing
# happens". jit-init drops one vocabulary entry the user then owns.
#
# The negative half is the important one, and it is exactly the shape that passes on a
# broken harness: the entry must fire on "how do I write a jit entry" and stay SILENT on
# a prompt that merely uses the word "vocabulary" in its ordinary sense. Every silence
# assertion below sits beside a positive control on the same code path, and the harness
# probe exits the suite loudly rather than letting the silences read as passes --
# test-dogfood-entries.sh passed every assert_silent in its first draft because it
# resolved the tree from the working directory and every sample returned nothing.
#
# Usage: bash tests/test-jit-init.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$REPO/scripts/jit-init.sh"
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
ENTRY_REL="vocabulary/00-manual/writing-rules.md"

PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -gt 0 ] && echo "    $*"; return 0; }

# The hook output goes to a file and the assertion reads the file: $( ) silently drops
# NUL bytes, so a captured variable makes an assertion pass against output it never saw.
# Nothing is piped into grep -q either -- the writer takes SIGPIPE on the match and
# pipefail turns a hit into a non-zero status (#56).
run_prompt() {
  # $1 project dir, $2 prompt text
  printf '{"prompt":"%s"}' "$2" > "$TMP/payload.json"
  CLAUDE_PROJECT_DIR="$1" bash "$PROMPT_HOOK" < "$TMP/payload.json" > "$TMP/prompt-out.txt" 2>/dev/null
}

# jit-drive: none -- both helpers run the prompt hook themselves and assert against the file it wrote; neither takes output as an argument
assert_prompt_fires() {
  # $1 desc, $2 project, $3 prompt, $4 needle
  run_prompt "$2" "$3"
  if grep -qF "$4" "$TMP/prompt-out.txt"; then
    ok "$1"
  else
    bad "$1" "expected $4 to be injected for prompt: $3"
  fi
}

assert_prompt_silent() {
  # $1 desc, $2 project, $3 prompt, $4 needle
  run_prompt "$2" "$3"
  if grep -qF "$4" "$TMP/prompt-out.txt"; then
    bad "$1" "$4 must NOT be injected for prompt: $3"
  else
    ok "$1"
  fi
}

echo "=== a bare project gets the three dimensions and one entry ==="

P1="$TMP/p1"
mkdir -p "$P1"
bash "$INIT" --base "$P1/.claude/jit-context" > "$TMP/init1.txt" 2>&1
INIT1_RC=$?

if [ "$INIT1_RC" -eq 0 ]; then
  ok "jit-init exits 0 on a bare project"
else
  bad "jit-init exits 0 on a bare project" "exit=$INIT1_RC"
  cat "$TMP/init1.txt"
fi

for d in vocabulary/00-manual paths/00-manual tools/00-manual; do
  if [ -d "$P1/.claude/jit-context/$d" ]; then
    ok "created $d/"
  else
    bad "created $d/" "missing: $P1/.claude/jit-context/$d"
  fi
done

if [ -f "$P1/.claude/jit-context/$ENTRY_REL" ]; then
  ok "seeded $ENTRY_REL"
else
  bad "seeded $ENTRY_REL" "missing"
fi

# The trap the entry itself is about: an entry that has not been indexed is inert, and
# inert in silence. jit-init must not leave the thing it just wrote in that state.
if [ -s "$P1/.claude/jit-context/vocabulary/00-manual/00-index.tsv" ]; then
  ok "the index was rebuilt, so the seeded entry is not inert"
else
  bad "the index was rebuilt, so the seeded entry is not inert" \
      "00-index.tsv absent or empty -- the entry exists on disk and can never fire"
fi

echo ""
echo "=== the harness can see the tree at all ==="
# Without this every silence below would pass in an environment where the hook resolves
# nothing. It goes FIRST and it exits the suite, rather than counting as one failure
# among many green lines.
run_prompt "$P1" "how do I write a jit entry"
if ! grep -qF "writing-rules.md" "$TMP/prompt-out.txt"; then
  echo "  FAIL: the seeded entry does not fire on its own headline prompt --"
  echo "        every silence assertion below would be vacuous. Stopping."
  echo "        hook output:"
  cat "$TMP/prompt-out.txt"
  exit 1
fi
ok 'the seeded entry fires on "how do I write a jit entry"'

echo ""
echo '=== it answers "how do I make this plugin do something" ==='
assert_prompt_fires "asking for an entry"     "$P1" "how do I add a jit entry for the billing module" "writing-rules.md"
assert_prompt_fires "naming the layer"        "$P1" "what belongs in 00-manual"                       "writing-rules.md"
assert_prompt_fires "naming the index build"  "$P1" "do I need to run rebuild-tsv after this"         "writing-rules.md"
assert_prompt_fires "naming the plugin"       "$P1" "how does jit-context decide what to inject"      "writing-rules.md"

echo ""
echo '=== and never "what does vocabulary mean" ==='
# Each of these is an ordinary sentence somebody types in a project that happens to have
# the plugin installed. An entry that fires on any of them is a tax on every session.
assert_prompt_silent "an ML tokeniser"    "$P1" "the tokeniser vocabulary is 50k tokens, can we shrink it" "writing-rules.md"
assert_prompt_silent "i18n content"       "$P1" "we need a French vocabulary list for the i18n strings"    "writing-rules.md"
assert_prompt_silent "linguistics"        "$P1" "vocabulary and grammar are separate concerns here"        "writing-rules.md"
assert_prompt_silent "an unrelated rule"  "$P1" "add a rule to the eslint config"                          "writing-rules.md"
assert_prompt_silent "unrelated writing"  "$P1" "write an entry in the changelog"                          "writing-rules.md"
assert_prompt_silent "unrelated context"  "$P1" "the context window is full"                               "writing-rules.md"

echo ""
echo "=== jit-dry-run.sh reports the rule it seeded ==="
# A rule that fires and does not appear in the linter's output is the defect this
# repository is named after, arriving through the feature meant to introduce people to it.
(cd "$P1" && bash "$DRYRUN" --base "$P1/.claude/jit-context" --prompt "how do I write a jit entry") \
  > "$TMP/dryrun.txt" 2>&1
DRY_RC=$?
if grep -qF "writing-rules.md" "$TMP/dryrun.txt"; then
  ok "the dry-run names the seeded rule for the sample prompt"
else
  bad "the dry-run names the seeded rule for the sample prompt"
  cat "$TMP/dryrun.txt"
fi
if [ "$DRY_RC" -eq 0 ]; then
  ok "the seeded tree lints clean (exit 0: nothing refused, nothing stale)"
else
  bad "the seeded tree lints clean (exit 0: nothing refused, nothing stale)" "exit=$DRY_RC"
  cat "$TMP/dryrun.txt"
fi
# The tally, not just the sample call. A freshly seeded tree holds exactly one rule and
# it fires; a linter whose summary reads "0 rule(s) indexed" over it has told a new user
# their corpus is empty, which is this repository's own defect class arriving through the
# feature meant to introduce them to it. Vocabulary carries no patterns, so it is counted
# on its own line rather than folded into the compiled-pattern arithmetic.
if grep -qE '^[1-9][0-9]* vocabulary keyword' "$TMP/dryrun.txt"; then
  ok "the tally accounts for the vocabulary rules in the tree"
else
  bad "the tally accounts for the vocabulary rules in the tree" \
      "the summary never counts the one rule that just fired"
  cat "$TMP/dryrun.txt"
fi
# Paired control: the same line must read zero on a tree that genuinely has no keywords,
# so the assertion above is about the count and not about the sentence existing.
P4="$TMP/p4"
mkdir -p "$P4/.claude/jit-context/paths/00-manual"
cat > "$P4/.claude/jit-context/paths/00-manual/only-a-path.md" <<'MD'
---
title: Command conventions
match: (^|/)Commands/
---

Every command extends CommandBase.
MD
CLAUDE_PROJECT_DIR="$P4" bash "$REPO/scripts/rebuild-tsv.sh" > /dev/null 2>&1
(cd "$P4" && bash "$DRYRUN" --base "$P4/.claude/jit-context") > "$TMP/dryrun4.txt" 2>&1
if grep -qE '^[1-9][0-9]* vocabulary keyword' "$TMP/dryrun4.txt"; then
  bad "a tree with no keywords is not credited with any" "$(grep -E 'vocabulary keyword' "$TMP/dryrun4.txt")"
else
  ok "a tree with no keywords is not credited with any"
fi

echo ""
echo "=== a second run refuses rather than overwriting ==="
P2="$TMP/p2"
mkdir -p "$P2"
bash "$INIT" --base "$P2/.claude/jit-context" > /dev/null 2>&1
printf 'EDITED BY THE USER\n' >> "$P2/.claude/jit-context/$ENTRY_REL"
cp "$P2/.claude/jit-context/$ENTRY_REL" "$TMP/before.md"

bash "$INIT" --base "$P2/.claude/jit-context" > "$TMP/init2.txt" 2>&1
INIT2_RC=$?
if [ "$INIT2_RC" -eq 1 ]; then
  ok "a re-run exits 1 (refused), not 0"
else
  bad "a re-run exits 1 (refused), not 0" "exit=$INIT2_RC"
  cat "$TMP/init2.txt"
fi
if cmp -s "$TMP/before.md" "$P2/.claude/jit-context/$ENTRY_REL"; then
  ok "the user's edited copy is byte-identical after the refused re-run"
else
  bad "the user's edited copy is byte-identical after the refused re-run" "it was overwritten"
fi
if grep -qF "writing-rules.md" "$TMP/init2.txt"; then
  ok "the refusal names the file it refused to replace"
else
  bad "the refusal names the file it refused to replace"
  cat "$TMP/init2.txt"
fi

echo ""
echo "=== an existing project keeps its own entries ==="
P3="$TMP/p3"
mkdir -p "$P3/.claude/jit-context/vocabulary/00-manual"
cat > "$P3/.claude/jit-context/vocabulary/00-manual/billing.md" <<'MD'
---
title: Billing amounts
description: How invoice totals are computed.
keywords: billing, invoice, vat
---

Totals are not stored; they are recomputed on every call.
MD
bash "$INIT" --base "$P3/.claude/jit-context" > "$TMP/init3.txt" 2>&1
INIT3_RC=$?
if [ "$INIT3_RC" -eq 0 ]; then
  ok "seeding a project that already has entries exits 0"
else
  bad "seeding a project that already has entries exits 0" "exit=$INIT3_RC"
  cat "$TMP/init3.txt"
fi
assert_prompt_fires "the project own entry still fires"  "$P3" "how are invoice totals computed" "billing.md"
assert_prompt_fires "and the seeded one fires too"       "$P3" "how do I write a jit entry"       "writing-rules.md"
assert_prompt_silent "the seeded one does not shadow it" "$P3" "how are invoice totals computed"  "writing-rules.md"

echo ""
echo "=== a linked component is refused, not followed ==="
# The receipt names a path inside the tree you asked for. If any component on the way to
# it is a symbolic link, the write lands somewhere else and that receipt is false --
# "seeded <project>/..." for a file that is not in the project. Refuse instead.
LINK_PROBE="$TMP/link-probe"
mkdir -p "$LINK_PROBE/target"
if ln -s "$LINK_PROBE/target" "$LINK_PROBE/link" 2>/dev/null && [ -L "$LINK_PROBE/link" ]; then
  for part in .claude .claude/jit-context .claude/jit-context/vocabulary \
              .claude/jit-context/vocabulary/00-manual; do
    OUT="$TMP/outside-$(echo "$part" | tr '/.' '__')"
    PL="$TMP/pl-$(echo "$part" | tr '/.' '__')"
    mkdir -p "$OUT" "$PL/$(dirname "$part")"
    ln -s "$OUT" "$PL/$part"
    bash "$INIT" --base "$PL/.claude/jit-context" > "$TMP/initlink.txt" 2>&1
    LINK_RC=$?
    if [ "$LINK_RC" -eq 2 ]; then
      ok "a linked $part is refused (exit 2)"
    else
      bad "a linked $part is refused (exit 2)" "exit=$LINK_RC"
      cat "$TMP/initlink.txt"
    fi
    # The refusal has to mean nothing was written, not that the write was reported oddly.
    if [ -z "$(find "$OUT" -type f 2>/dev/null)" ]; then
      ok "and nothing was written through it"
    else
      bad "and nothing was written through it" "files landed outside the named tree"
      find "$OUT" -type f
    fi
  done
  # Positive control on the same code path: the identical tree without the link seeds and
  # exits 0, so the refusals above are about the link and not about the fixture.
  PLOK="$TMP/pl-control"
  mkdir -p "$PLOK/.claude/jit-context/vocabulary"
  bash "$INIT" --base "$PLOK/.claude/jit-context" > "$TMP/initlinkok.txt" 2>&1
  CTRL_RC=$?
  if [ "$CTRL_RC" -eq 0 ] && [ -f "$PLOK/.claude/jit-context/$ENTRY_REL" ]; then
    ok "the same tree with no link seeds normally"
  else
    bad "the same tree with no link seeds normally" "exit=$CTRL_RC"
    cat "$TMP/initlinkok.txt"
  fi
else
  echo "  SKIPPED: ln -s did not produce a symbolic link here, so the escape this section"
  echo "           refuses cannot be constructed. Nothing in this section was tested."
  echo "           On Git Bash that needs MSYS=winsymlinks:nativestrict."
fi

echo ""
echo "=== a symbolic link ABOVE .claude is followed, and the receipt says where ==="
# #99. The section above covers .claude and everything under it -- the components the
# hooks themselves refuse to read through, so seeding past one of those would write a
# rule that can never load. NOTHING above .claude was checked, and `..` was never
# folded: `--base .../sym/link/.claude/jit-context` wrote into the link target and
# printed "seeded .../sym/link/..." for a file that was not there. Pointing --base
# anywhere on the disk is this tool's whole job and stays allowed; the receipt naming a
# place the file is not is the defect.
SYMA="$TMP/syma"
mkdir -p "$SYMA/proj/sym" "$SYMA/proj/escape"
if ln -s ../escape "$SYMA/proj/sym/link" 2>/dev/null && [ -L "$SYMA/proj/sym/link" ]; then
  ESCAPE_PHYS="$(cd "$SYMA/proj/escape" && pwd -P)"
  bash "$INIT" --base "$SYMA/proj/sym/link/.claude/jit-context" > "$TMP/initsym.txt" 2>&1
  SYM_RC=$?
  if [ "$SYM_RC" -eq 0 ]; then
    ok "a symlinked ancestor above .claude still seeds (exit 0)"
  else
    bad "a symlinked ancestor above .claude still seeds (exit 0)" "exit=$SYM_RC"
    cat "$TMP/initsym.txt"
  fi
  if [ -f "$ESCAPE_PHYS/.claude/jit-context/$ENTRY_REL" ]; then
    ok "the entry landed in the link target, which is where --base points"
  else
    bad "the entry landed in the link target, which is where --base points" \
        "nothing at $ESCAPE_PHYS/.claude/jit-context/$ENTRY_REL"
  fi
  if grep -qF "seeded  $ESCAPE_PHYS/.claude/jit-context/$ENTRY_REL" "$TMP/initsym.txt"; then
    ok "and the receipt names the resolved location, not the link"
  else
    bad "and the receipt names the resolved location, not the link" \
        "expected: seeded  $ESCAPE_PHYS/.claude/jit-context/$ENTRY_REL"
    cat "$TMP/initsym.txt"
  fi
  # Not just the "seeded" line: the follow-up commands it prints are copy-pasted, and a
  # CLAUDE_PROJECT_DIR through the link is the same lie one level up.
  if grep -qF "/sym/link/" "$TMP/initsym.txt"; then
    bad "no line of the output names the unresolved path" "still printed through the link"
    grep -F "/sym/link/" "$TMP/initsym.txt"
  else
    ok "no line of the output names the unresolved path"
  fi
  assert_prompt_fires "and the entry fires from the resolved project" \
    "$ESCAPE_PHYS" "how do I write a jit entry" "writing-rules.md"
else
  echo "  SKIPPED: ln -s did not produce a symbolic link here, so a symlinked ancestor"
  echo "           cannot be constructed. Nothing in this half was tested."
  echo "           On Git Bash that needs MSYS=winsymlinks:nativestrict."
fi

# The must-seed half, same code path, same run: an ordinary --base with no link above it
# still seeds. If this one ever goes red the refusals and rewrites above prove nothing.
P7="$TMP/p7"
mkdir -p "$P7"
P7_PHYS="$(cd "$P7" && pwd -P)"
bash "$INIT" --base "$P7/.claude/jit-context" > "$TMP/init7.txt" 2>&1
INIT7_RC=$?
if [ "$INIT7_RC" -eq 0 ] && [ -f "$P7/.claude/jit-context/$ENTRY_REL" ]; then
  ok "an ordinary --base still seeds"
else
  bad "an ordinary --base still seeds" "exit=$INIT7_RC"
  cat "$TMP/init7.txt"
fi
if grep -qF "seeded  $P7_PHYS/.claude/jit-context/$ENTRY_REL" "$TMP/init7.txt"; then
  ok "and its receipt is the physical path of that tree"
else
  bad "and its receipt is the physical path of that tree" \
      "expected: seeded  $P7_PHYS/.claude/jit-context/$ENTRY_REL"
  cat "$TMP/init7.txt"
fi

# `..` stays accepted -- this tool writes where you point it -- but what it prints is the
# folded spelling of that place rather than the argument it was handed.
P8="$TMP/p8"
mkdir -p "$P8/inner"
P8_PHYS="$(cd "$P8" && pwd -P)"
bash "$INIT" --base "$P8/inner/../.claude/jit-context" > "$TMP/init8.txt" 2>&1
INIT8_RC=$?
if [ "$INIT8_RC" -eq 0 ] && [ -f "$P8/.claude/jit-context/$ENTRY_REL" ]; then
  ok "a --base carrying .. is honoured, not refused"
else
  bad "a --base carrying .. is honoured, not refused" "exit=$INIT8_RC"
  cat "$TMP/init8.txt"
fi
if grep -qF "seeded  $P8_PHYS/.claude/jit-context/$ENTRY_REL" "$TMP/init8.txt"; then
  ok "and the receipt has no .. left in it"
else
  bad "and the receipt has no .. left in it" \
      "expected: seeded  $P8_PHYS/.claude/jit-context/$ENTRY_REL"
  cat "$TMP/init8.txt"
fi

echo ""
echo "=== a relative --base is resolved, not half-honoured ==="
# The dangerous shape: mkdir/cp are happy with a relative path, but rebuild-tsv.sh
# resolves JIT_BASE from $CLAUDE_PROJECT_DIR, so a project dir derived by stripping a
# suffix that is not there is empty -- the entry lands and the index for it is built
# somewhere else, or nowhere. That is a seeded rule that can never fire, reported as
# success, which is the exact failure this repository exists to describe.
P6="$TMP/p6"
mkdir -p "$P6"
(cd "$P6" && bash "$INIT" --base .claude/jit-context) > "$TMP/init6.txt" 2>&1
INIT6_RC=$?
if [ "$INIT6_RC" -eq 0 ]; then
  ok "a relative --base is accepted"
else
  bad "a relative --base is accepted" "exit=$INIT6_RC"
  cat "$TMP/init6.txt"
fi
if [ -s "$P6/.claude/jit-context/vocabulary/00-manual/00-index.tsv" ]; then
  ok "and its index is built in that same tree, so the entry is not inert"
else
  bad "and its index is built in that same tree, so the entry is not inert" \
      "the entry was seeded and indexed nowhere"
fi
assert_prompt_fires "and the entry fires there" "$P6" "how do I write a jit entry" "writing-rules.md"

echo ""
echo "=== three outcomes, never two ==="
bash "$INIT" --nonsense > "$TMP/init4.txt" 2>&1
INIT4_RC=$?
if [ "$INIT4_RC" -eq 2 ]; then
  ok "an unknown argument is 2 (could not evaluate), not 1"
else
  bad "an unknown argument is 2 (could not evaluate), not 1" "exit=$INIT4_RC"
  cat "$TMP/init4.txt"
fi

# An install missing its template cannot do its job and must say so. Copying scripts/
# alone reproduces exactly that: a tree with the tools and no entry to seed.
mkdir -p "$TMP/fake-install/scripts"
cp "$REPO"/scripts/*.sh "$TMP/fake-install/scripts/"
bash "$TMP/fake-install/scripts/jit-init.sh" --base "$TMP/p5/.claude/jit-context" > "$TMP/init5.txt" 2>&1
INIT5_RC=$?
if [ "$INIT5_RC" -eq 2 ]; then
  ok "a missing template is 2 (could not evaluate), never 0"
else
  bad "a missing template is 2 (could not evaluate), never 0" "exit=$INIT5_RC"
  cat "$TMP/init5.txt"
fi
if [ ! -f "$TMP/p5/.claude/jit-context/$ENTRY_REL" ]; then
  ok "and it seeded nothing"
else
  bad "and it seeded nothing" "an entry appeared without a template"
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
