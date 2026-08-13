#!/bin/bash
# Tests for THIS repository's own entries in .claude/jit-context/.
#
# Every other suite builds a synthetic tree and tests the hooks against it. That
# proves the engine works and says nothing about the rules we actually ship to
# ourselves — which is where an unanchored pattern hides, because it fires often
# enough to look alive and nobody checks what else it fired on.
#
# Both directions for every rule: a path it must match, and a near-miss it must not.
#
# Usage: bash tests/test-dogfood-entries.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

# Which rules fired for one sample path, as reported by the dry-run against this repo.
#
# cd into the repo: the dry-run resolves the tree it evaluates from the working
# directory, so running this from tests/ made EVERY sample return nothing — and the
# assert_silent cases all passed on that emptiness. A vacuous pass is the exact defect
# this suite is about, so the guard below fails loudly instead of trusting the silence.
fired_for() {
  (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$DRYRUN" --file "$1" 2>&1) \
    | awk '/pre-path-hook\.sh/ { $1=""; print }'
}

# Proves the harness can see the tree at all. Without it, every assert_silent below
# would pass in an environment where the dry-run silently evaluates nothing.
# Captured first, not piped: `grep -q` exits on the match and the writer on the left of
# the pipe takes SIGPIPE, which under pipefail turns a found string into a non-zero
# status. That is issue #56, and here it would have inverted the guard itself.
harness_probe=$(fired_for "scripts/pre-path-hook.sh")
if ! grep -q "hooks.md" <<<"$harness_probe"; then
  echo "  FAIL: harness cannot evaluate this repo's own tree — every result below would be vacuous"
  exit 1
fi

assert_fires() {
  local desc="$1" path="$2" rule="$3" out
  out=$(fired_for "$path")
  if grep -qF "$rule" <<<"$out"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected $rule to fire for: $path"
    echo "    got: ${out:-<nothing>}"
  fi
}

assert_silent() {
  local desc="$1" path="$2" rule="$3" out
  out=$(fired_for "$path")
  if grep -qF "$rule" <<<"$out"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    $rule must NOT fire for: $path"
    echo "    got: $out"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

echo "=== entries.md fires on an entry, and only on an entry ==="
assert_fires  "our own entry tree"     ".claude/jit-context/paths/00-manual/hooks.md" "entries.md"
assert_fires  "the shipped examples"   "examples/jit-context/tools/00-manual/git.md"  "entries.md"
# The bug this suite was written for. The scratchpad path a Claude Code session hands
# out is derived from the project directory, so for THIS repo it contains the string
# "claude-jit-context" — and a pattern anchored on the bare fragment "jit-context/"
# matched every temporary .md file written during a session. Observed twice in one day.
assert_silent "a session scratchpad path" \
  "/private/tmp/claude-501/-Users-floriandavid-Documents-claude-jit-context/x/scratchpad/note.md" \
  "entries.md"
assert_silent "a doc that is not an entry" "docs/contributing.md" "entries.md"
assert_silent "the README"                 "README.md"            "entries.md"

echo ""
echo "=== hooks.md fires on code that runs in someone else session ==="
assert_fires  "a hook script"          "scripts/pre-path-hook.sh"  "hooks.md"
assert_fires  "the session-start hook" "scripts/session-start-hook.sh" "hooks.md"
# common.sh is sourced by all four hooks, so every sentence in hooks.md applies to it
# verbatim -- and it is where every containment fix in 0.3.0 landed. It carried no rule
# at all until #42.
assert_fires  "the shared library"     "scripts/common.sh"         "hooks.md"
# The three tooling scripts must NOT get this entry. "Every failure path exits 0" is
# actively wrong for rebuild-tsv.sh, and jit-dry-run.sh exits 1 and 2 on purpose. A false
# rule fires more expensively than no rule, because it arrives with the same authority.
assert_silent "the index writer"       "scripts/rebuild-tsv.sh"    "hooks.md"
assert_silent "the linter"             "scripts/jit-dry-run.sh"    "hooks.md"
assert_silent "the miss reporter"      "scripts/jit-misses.sh"     "hooks.md"
assert_silent "a test for a hook"      "tests/test-pre-path-hook.sh" "hooks.md"
# Same defect class as the scratchpad path above: an unanchored pattern matches the
# fragment wherever it appears, so a directory ENDING in "scripts" claims the rule.
assert_silent "a lookalike directory"  "myscripts/common.sh"       "hooks.md"
# jit-init.sh must never inherit "every failure path exits 0" -- it exits 1 to refuse an
# overwrite and 2 when it cannot evaluate the request.
assert_silent "the project seeder"     "scripts/jit-init.sh"       "hooks.md"

echo ""
echo "=== tooling.md fires on the five build, diagnostic and release scripts ==="
assert_fires  "the index writer"       "scripts/rebuild-tsv.sh"    "tooling.md"
# Seeds a project and refuses rather than overwriting, so it is run deliberately by a
# person and fails loudly (#81). It carried no rule at all until this file named it --
# hooks.md's pattern does not reach it either, so it was a script in scripts/ that the
# repo's own knowledge said nothing about.
assert_fires  "the project seeder"     "scripts/jit-init.sh"       "tooling.md"
assert_fires  "the linter"             "scripts/jit-dry-run.sh"    "tooling.md"
assert_fires  "the miss reporter"      "scripts/jit-misses.sh"     "tooling.md"
# Same contract, same reason: it is run at a tag by a person, never in a stranger's
# session, so it fails loudly with exit codes that mean distinct things (#66).
assert_fires  "the changelog assembler" ".github/scripts/assemble_changelog.py" "tooling.md"
assert_silent "a lookalike outside .github"  "scripts/assemble_changelog.py" "tooling.md"
# The inverse of the split above: these run in someone else session and are governed by
# hooks.md, so the tooling contract must not reach them.
assert_silent "a hook script"          "scripts/pre-tool-hook.sh"  "tooling.md"
assert_silent "the shared library"     "scripts/common.sh"         "tooling.md"
assert_silent "a suite about a tool"   "tests/test-jit-dry-run.sh" "tooling.md"
assert_silent "a lookalike directory"  "vendor/subscripts/jit-misses.sh" "tooling.md"
assert_silent "the seeder's own suite"  "tests/test-jit-init.sh"   "tooling.md"
# The template the seeder copies is documentation, not one of the tools.
assert_silent "the seeded template"     "templates/jit-context/vocabulary/00-manual/writing-rules.md" "tooling.md"

echo ""
echo "=== tests.md fires on a suite, and only on a suite ==="
assert_fires  "a hook suite"           "tests/test-pre-path-hook.sh" "tests.md"
assert_fires  "the runner"             "tests/run-all.sh"          "tests.md"
assert_silent "a hook script"          "scripts/pre-path-hook.sh"  "tests.md"
assert_silent "the shared library"     "scripts/common.sh"         "tests.md"
assert_silent "a fixture below tests/" "tests/fixtures/tree/setup.sh" "tests.md"
assert_silent "a lookalike directory"  "contests/entry.sh"         "tests.md"

echo ""
echo "=== release.md fires on the manifest only ==="
assert_fires  "the plugin manifest"    ".claude-plugin/plugin.json" "release.md"
assert_silent "some other json"        ".supertool.json"            "release.md"

echo ""
echo "=== changelog.md fires on the assembled file, and not on the fragments ==="
assert_fires  "the assembled file"     "CHANGELOG.md"               "changelog.md"
assert_fires  "it from a subdirectory" "vendor/thing/CHANGELOG.md"  "changelog.md"
# The directory documents itself, and a rule saying "do not edit this, write a fragment"
# arriving while you write a fragment is the rule firing against its own advice.
assert_silent "the convention page"    "changelog.d/README.md"      "changelog.md"
assert_silent "a fragment"             "changelog.d/70.fixed.md"    "changelog.md"
assert_silent "a lookalike name"       "docs/CHANGELOG.md.tmpl"     "changelog.md"

echo ""
echo "=== the tools dimension: a write to the generated index is refused, a read is not ==="
# The `block` rules -- the only two in this tree, and until #92 there was one and it had
# no assertion anywhere in tests/: it could have stopped working outright and nothing
# would have gone red (#93).
#
# The REAL hook, not jit-dry-run.sh. The thing under test is a refusal, and only the hook
# emits the {"decision":"block"} a session acts on; the dry-run reports which rule fired,
# which is one inference short of the question -- and #92 is precisely a case where a rule
# was present, matched something, and permitted the call anyway.
#
# Every "must not block" case is paired with a "must block" case differing in ONE token --
# `sed -n` against `sed -i`, `00-index.tsv.bak` against `00-index.tsv`. A silence assertion
# on its own passes in a tree the hook cannot even see, which is the vacuous result this
# whole suite exists to refuse.
HOOK="$REPO/scripts/pre-tool-hook.sh"
EDIT_RULE="no-hand-editing-the-index.md"
SHELL_RULE="no-shell-writes-to-the-index.md"
IDX=".claude/jit-context/paths/00-manual/00-index.tsv"

hook_verdict() {
  printf '%s' "$1" | (cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>/dev/null)
}
# No double quote appears in any command below, so none needs JSON-escaping here. A helper
# that pretended to escape would be a helper nobody checked.
bash_payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
file_payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }

assert_blocks() {
  local desc="$1" payload="$2" rule="$3" out
  out=$(hook_verdict "$payload")
  if grep -qF '"decision":"block"' <<<"$out" && grep -qF "$rule" <<<"$out"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected a block naming $rule"
    echo "    got: ${out:0:200}"
  fi
}

assert_allows() {
  local desc="$1" payload="$2" out
  out=$(hook_verdict "$payload")
  if grep -qF '"decision":"block"' <<<"$out"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    this call must NOT be blocked"
    echo "    got: ${out:0:200}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

# Positive control for every assert_allows below. Without it a hook that cannot resolve
# this tree -- wrong CLAUDE_PROJECT_DIR, missing index, a fatal awk error in row 1 --
# reports no block for everything and the silence half of this section passes on emptiness.
tool_probe=$(hook_verdict "$(file_payload Edit "$REPO/$IDX")")
if ! grep -qF '"decision":"block"' <<<"$tool_probe"; then
  echo "  FAIL: the tool hook cannot refuse anything in this repo's own tree"
  echo "    got: ${tool_probe:0:200}"
  echo "    every allow assertion below would be vacuous"
  exit 1
fi

# --- Edit / Write: the subject is a path -------------------------------------
assert_blocks "Edit on the paths index"   "$(file_payload Edit "$REPO/$IDX")"  "$EDIT_RULE"
assert_blocks "Write on the tools index"  "$(file_payload Write ".claude/jit-context/tools/00-manual/00-index.tsv")" "$EDIT_RULE"
assert_blocks "a relative bare index"     "$(file_payload Edit "00-index.tsv")" "$EDIT_RULE"
# The over-fire half of #92: the rule named a filename FRAGMENT where it meant the
# generated index, so a backup of it -- a file nothing generates and nobody may not edit --
# was refused by a rule that has no business reaching it.
assert_allows "a backup of the index"     "$(file_payload Edit "docs/00-index.tsv.bak")"
assert_allows "a differently named tsv"   "$(file_payload Edit "docs/my00-index.tsv")"
assert_allows "the index name in a dir"   "$(file_payload Edit "docs/00-index.tsv/notes.md")"

# --- Bash: the subject is a command string ------------------------------------
# The blindness #92 reports. The guard was anchored on the tool, so every one of these
# rewrote the generated index with the hook running and saying nothing about it.
assert_blocks "sed -i on the index"       "$(bash_payload "sed -i '' s/a/b/ $IDX")" "$SHELL_RULE"
assert_blocks "sed -i with a backup suffix" "$(bash_payload "sed -i.bak s/a/b/ $IDX")"     "$SHELL_RULE"
assert_blocks "perl -pi on the index"     "$(bash_payload "perl -pi -e s/a/b/ $IDX")"      "$SHELL_RULE"
# The long-option spelling of the same flag. `-[a-z]*i` is a SHORT cluster and cannot
# reach it, so the first draft of this rule claimed to cover in-place sed and did not.
assert_blocks "sed --in-place"            "$(bash_payload "sed --in-place s/a/b/ $IDX")"  "$SHELL_RULE"
assert_blocks "a > redirect"              "$(bash_payload "echo x > $IDX")"                "$SHELL_RULE"
assert_blocks "a >> redirect, no space"   "$(bash_payload "printf a >>$IDX")"              "$SHELL_RULE"
assert_blocks "tee at the end of a pipe"  "$(bash_payload "cat foo | tee $IDX")"           "$SHELL_RULE"
assert_blocks "a write after a chain op"  "$(bash_payload "cd /tmp && sed -i '' s/a/b/ $IDX")" "$SHELL_RULE"
assert_blocks "the bare file name"        "$(bash_payload "sed -i '' s/a/b/ 00-index.tsv")"    "$SHELL_RULE"

# The other direction, and the whole reason this rule is a regex over write FORMS rather
# than over the file name: #76 and #79 are what a block anchored on a word costs. Each of
# these names the index and each is a read or a mention.
assert_allows "cat on the index"          "$(bash_payload "cat $IDX")"
assert_allows "grep on the index"         "$(bash_payload "grep foo $IDX")"
# Paired with "sed -i on the index" above: same command word, same path, one flag apart.
assert_allows "sed reading, not writing"  "$(bash_payload "sed -n 1p $IDX")"
assert_allows "merely mentioning it"      "$(bash_payload "echo see $IDX")"
# An arrow is not a redirect. The first draft matched a bare `>`, so narrating a rename
# was refused -- the #76 shape again, one character wide.
assert_allows "an arrow, not a redirect"  "$(bash_payload "echo renamed old.tsv->00-index.tsv")"
# Paired with "sed -i on the index": same write form, one suffix apart.
assert_allows "a write to a .bak"         "$(bash_payload "sed -i '' s/a/b/ docs/00-index.tsv.bak")"
assert_allows "a write to another tsv"    "$(bash_payload "echo x > docs/my00-index.tsv")"
# The sanctioned writer. A guard that refuses the command its own text tells you to run
# would be worse than the hole it closes.
assert_allows "the rebuild script itself" "$(bash_payload "bash scripts/rebuild-tsv.sh")"

echo ""
echo "=== the vocabulary dimension: the one entry that explains this plugin ==="
# The other half of #93. `vocabulary/00-manual/jit-context.md` fires today and had no
# assertion anywhere in tests/: it could have stopped matching outright and every leg would
# still be green. It is the entry that answers "what is pre-tool-hook", which is the first
# question anyone touching this repository asks.
#
# The REAL prompt hook, and output to a file rather than $( ): a captured variable silently
# drops NUL bytes, so an assertion can pass against output it never saw.
PROMPT_HOOK="$REPO/scripts/pre-prompt-hook.sh"
VOCAB_RULE="jit-context.md"
PTMP="$(mktemp -d 2>/dev/null)" || PTMP=""
if [ -z "$PTMP" ] || [ ! -d "$PTMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory here, so this section was not tested."
else
  trap 'rm -rf "$PTMP"' EXIT

  run_prompt() {
    printf '{"prompt":"%s"}' "$1" > "$PTMP/payload.json"
    CLAUDE_PROJECT_DIR="$REPO" bash "$PROMPT_HOOK" < "$PTMP/payload.json" \
      > "$PTMP/prompt-out.txt" 2>/dev/null
  }

  assert_prompt_fires() {
    run_prompt "$2"
    if grep -qF -- "$VOCAB_RULE" "$PTMP/prompt-out.txt"; then
      PASS=$((PASS + 1)); echo "  PASS: $1"
    else
      FAIL=$((FAIL + 1)); echo "  FAIL: $1"
      echo "    expected $VOCAB_RULE for prompt: $2"
    fi
  }

  assert_prompt_silent() {
    run_prompt "$2"
    if grep -qF -- "$VOCAB_RULE" "$PTMP/prompt-out.txt"; then
      FAIL=$((FAIL + 1)); echo "  FAIL: $1"
      echo "    $VOCAB_RULE must NOT fire for prompt: $2"
    else
      PASS=$((PASS + 1)); echo "  PASS: $1"
    fi
  }

  # Positive control, first and loud. Without it every silence below passes in an
  # environment where the prompt hook resolves no tree at all -- which is exactly how the
  # first draft of this suite went green over nothing.
  run_prompt "what does rebuild-tsv actually write"
  if ! grep -qF -- "$VOCAB_RULE" "$PTMP/prompt-out.txt"; then
    echo "  FAIL: the prompt hook fires nothing for this repo's own vocabulary entry --"
    echo "        every silence assertion in this section would be vacuous. Stopping."
    cat "$PTMP/prompt-out.txt"
    exit 1
  fi
  PASS=$((PASS + 1)); echo "  PASS: it fires when someone names rebuild-tsv"

  assert_prompt_fires  "naming a hook"        "what does pre-tool-hook decide"
  assert_prompt_fires  "naming the plugin"    "how does jit-context pick an entry"
  # Ordinary sentences in a session that happens to be in this repository. Each names a
  # word the entry is about without naming anything the entry is keyed on, and an entry
  # that fires on them is a standing tax on every prompt.
  assert_prompt_silent "a git hook"           "add a pre-commit hook to this repo"
  assert_prompt_silent "an unrelated index"   "the index is stale, rebuild it"
  assert_prompt_silent "an unrelated context" "the context window is full"
fi

echo ""
echo "=== every file under scripts/ is governed by some paths/ rule ==="
# The class behind #83 rather than the instance. `hooks.md` matches the hooks and
# `common.sh`; `tooling.md` names its tools by hand, one alternation per script. A file that
# is neither matched nothing, and `scripts/jit-init.sh` shipped exactly like that: the
# repository's own knowledge said nothing about the file its author was editing, and an
# absence produced by the tool is unreadable from an absence in the world. Widening one
# `match` fixed that file; only a red leg fixes the next one.
#
# COVERED MEANS ANY paths/ RULE FIRES, not a rule from a fixed set. "hooks.md or tooling.md"
# would be the stronger assertion and it would freeze today's two-way split into the suite:
# a script under a third contract would be red while being perfectly documented, and the
# leg would then be asserting the shape of the tree rather than its coverage. The question
# asked here is the one the defect was about -- does this repository say anything at all
# when you open this file?
#
# The consequence is why #83's option 2, a catch-all entry matching `scripts/` broadly, was
# NOT built alongside this: such an entry satisfies every assertion below by construction,
# and this leg could never go red again. The test and the catch-all do not compose.
#
# Scope is `scripts/`: what ships inside the plugin and runs in a user's project.
# `.github/scripts/` is CI, and `tooling.md` reaches it today only because
# `assemble_changelog.py` is named there -- requiring a jit-context rule for every future
# workflow helper is a bar nobody has agreed to.

# Positive control for the reading below, and it earned its place on the first run: a
# governed file is one whose dry-run line names a `.md`, NOT one whose line is non-empty.
# jit-dry-run.sh prints the words "no rule fired" for a miss, precisely so a hook that
# matched nothing cannot read as a hook that fired -- so the first draft of this section
# tested for non-empty output and reported a deliberately uncovered script as covered.
# That is the defect this whole suite is about, reproduced inside the fix for it.
uncovered_probe=$(fired_for "docs/nothing-governs-this.txt")
if grep -qE '[^[:space:]]+[.]md' <<<"$uncovered_probe"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: control -- an ungoverned path must name no rule"
  echo "    got: $uncovered_probe"
  echo "    every coverage assertion below is vacuous"
else
  PASS=$((PASS + 1)); echo "  PASS: control -- an ungoverned path names no rule"
fi

# Enumerated from the repository, not listed here: a list in this file is the same
# enumeration the defect is about, one directory further away.
#
# `git ls-files`, not `find`: the question is what SHIPS in scripts/, and find also returns
# a .DS_Store, an editor backup and a merge .orig, each of which would redden this section
# for a reason that has nothing to do with rule coverage. The cost is that a brand-new
# script is invisible here until it is staged, which is before CI sees it either.
script_list=$(cd "$REPO" && git ls-files -- scripts | LC_ALL=C sort)
if ! grep -q '^scripts/common[.]sh$' <<<"$script_list"; then
  echo "  FAIL: could not enumerate scripts/ -- every coverage assertion below would be vacuous"
  exit 1
fi

while IFS= read -r script; do
  [ -n "$script" ] || continue
  fired=$(fired_for "$script")
  if grep -qE '[^[:space:]]+[.]md' <<<"$fired"; then
    PASS=$((PASS + 1)); echo "  PASS: $script is governed by:$fired"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $script matches no rule in .claude/jit-context/paths/"
    echo "    a new script starts uncovered, and an uncovered script reads exactly like one"
    echo "    with nothing to say about it (#83). Widen a match in paths/00-manual/, or write"
    echo "    the entry that states its contract, then rebuild: bash scripts/rebuild-tsv.sh"
  fi
done <<<"$script_list"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
