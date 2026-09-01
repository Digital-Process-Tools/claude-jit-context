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

# jit-drive: none -- every helper here runs a real hook from a path or a payload and captures it itself; none takes hook output as an argument
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
# Same split for the fifth tool: "every failure path exits 0" is actively wrong for a
# diagnostic whose exit code is the answer.
assert_silent "the doctor"             "scripts/jit-doctor.sh"     "hooks.md"

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
# The fifth (#183). It answers "is any of this running at all", exits 1 on a layer whose
# rules can never load, and 2 when it cannot evaluate the tree -- so the tooling contract
# is the one that applies to it, and the hook contract below must not.
assert_fires  "the doctor"             "scripts/jit-doctor.sh"     "tooling.md"
# The changelog assembler used to be here, at `.github/scripts/assemble_changelog.py`,
# under the same contract (#66). It is now `.oss/assemble_changelog.py`, vendored from
# the oss plugin, and `tooling.md`'s exit-code table is the INVERSE of what it does --
# so it must not fire, and `vendored-oss.md` covers it instead.
assert_silent "the vendored assembler" ".oss/assemble_changelog.py" "tooling.md"
assert_fires  "the vendored assembler" ".oss/assemble_changelog.py" "vendored-oss.md"
assert_fires  "the owned workflow"     ".github/workflows/oss-changelog.yml" "vendored-oss.md"
# The scaffold owns files directly under .oss/ and nothing below it, and no other
# workflow: a rule saying "an edit here is lost" must not reach a file it is false of.
assert_silent "a nested path under .oss"  ".oss/vendor/lib/thing.py" "vendored-oss.md"
assert_silent "our own tests workflow" ".github/workflows/tests.yml" "vendored-oss.md"
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

# The rule-specific sibling of assert_allows, for a negative control that BOUNDS one
# named rule rather than asserting silence from the whole tree. A block naming a
# DIFFERENT entry is not a failure of the rule under test -- the hook echoes which
# entry matched as the first line of its `reason` ("# JIT Context: <rule>.md (matched:
# ...)"), so this is expressible without a scratch tree (#239). Anything installed
# alongside this repo's own rules -- today that is .claude/jit-context/tools/01-oss/'s
# catch-all, generated and replaced wholesale by a third-party scaffold -- can refuse
# the same call for its own reason, and that refusal says nothing about whether THIS
# rule's own boundary holds.
assert_not_blocked_by() {
  local desc="$1" payload="$2" forbidden_rule="$3" out
  out=$(hook_verdict "$payload")
  # A hook that produced no output at all -- crashed, or fell over on this specific
  # payload shape -- greps false for "$forbidden_rule" exactly like a genuine allow, so
  # without this guard this helper would report PASS for "the harness said nothing"
  # (oss-audit #239: the earlier tool_probe above proves the hook CAN refuse one payload,
  # never that it answers THESE three). Every real verdict carries one marker or the
  # other: a block always has "decision":"block", and a fall-through (allow or degraded
  # advisory) always carries the hookSpecificOutput wrapper -- so their absence together
  # is the harness failing to evaluate, not a clean answer.
  if ! grep -qF '"decision":"block"' <<<"$out" && ! grep -qF '"hookSpecificOutput"' <<<"$out"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    the hook produced no verdict at all for this payload -- not a clean allow"
    echo "    got: ${out:-<nothing>}"
  elif grep -qF '"decision":"block"' <<<"$out" && grep -qF "$forbidden_rule" <<<"$out"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    $forbidden_rule must NOT block this call"
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
#
# These bound EDIT_RULE specifically, not "must not be blocked at all" (#239).
# .claude/jit-context/tools/01-oss/supertool-required.md -- generated by the `oss` plugin's
# scaffold, replaced wholesale on every install, not ours to edit or narrow -- carries a
# catch-all `tool: Read|Edit|Write|Glob|Grep`, `match: ~.*`, `mode: block` that refuses
# every one of these three calls too, for its own unrelated reason ("go through
# supertool"), whenever `supertool` is missing from $PATH. That is a real, independent
# rule doing its own job; it is not what these three lines exist to bound, and a plain
# assert_allows could not tell the two refusals apart -- so on a machine with no
# `supertool` on PATH, this suite reported 3 failures for a rule that was never at fault.
#
# Positive control, in the same fixture: assert_not_blocked_by must still be ABLE to
# fail, or it is the same vacuous-silence bug in a new coat. The paths index itself is
# always blocked by EDIT_RULE (proven above by tool_probe), so binding forbidden_rule to
# EDIT_RULE for that same call must report a failure. Run in a subshell so the probe's
# own counting does not land in this suite's PASS/FAIL tally.
control_out=$(
  PASS=0 FAIL=0
  assert_not_blocked_by "probe" "$(file_payload Edit "$REPO/$IDX")" "$EDIT_RULE"
)
if grep -q '^  FAIL: probe$' <<<"$control_out"; then
  PASS=$((PASS + 1)); echo "  PASS: control -- assert_not_blocked_by can still fail"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: control -- assert_not_blocked_by can still fail"
  echo "    got: $control_out"
fi

assert_not_blocked_by "a backup of the index"   "$(file_payload Edit "docs/00-index.tsv.bak")"        "$EDIT_RULE"
assert_not_blocked_by "a differently named tsv" "$(file_payload Edit "docs/my00-index.tsv")"          "$EDIT_RULE"
assert_not_blocked_by "the index name in a dir" "$(file_payload Edit "docs/00-index.tsv/notes.md")"   "$EDIT_RULE"

# Second positive control, same shape: a payload the hook cannot answer at all -- no
# "decision", no hookSpecificOutput -- must be reported as a failure ("no verdict"),
# never silently folded into "not blocked, so PASS" (oss-audit #239). Malformed JSON on
# stdin is pre-tool-hook.sh's own documented empty-answer path (`{}`, exit 0): neither
# marker appears, which is exactly the shape this guard exists to catch.
control_out=$(
  PASS=0 FAIL=0
  assert_not_blocked_by "probe" "not valid json at all" "$EDIT_RULE"
)
if grep -q '^  FAIL: probe$' <<<"$control_out" && grep -qF "no verdict at all" <<<"$control_out"; then
  PASS=$((PASS + 1)); echo "  PASS: control -- an unanswerable payload is not read as an allow"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: control -- an unanswerable payload is not read as an allow"
  echo "    got: $control_out"
fi

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

# #215: the payload channel. Every sanctioned write now goes through a supertool
# paste:@-/edit:@- payload, which carries the whole file's CONTENT on the command line --
# so a fixture whose content merely DISCUSSES this rule is refused for writing a totally
# different file, because its content names the index near a redirect character. This is
# not fixed here: the rule body's own argument against anchoring on the file name still
# holds, and a regex over a command string cannot see that a heredoc/TOML string is not a
# real redirect. What changed is that the refusal now names the split-literal workaround,
# so an author pays this once per fixture instead of every time (see the rule body).
IDXNAME_215="00-index"; IDXNAME_215="$IDXNAME_215.tsv"
PAYLOAD_CMD="supertool 'paste:@-' path=docs/other.md content='see > $IDXNAME_215 for details'"
PAYLOAD_OUT="$(hook_verdict "$(bash_payload "$PAYLOAD_CMD")")"
if grep -qF '"decision":"block"' <<<"$PAYLOAD_OUT" && grep -qF "$SHELL_RULE" <<<"$PAYLOAD_OUT"; then
  PASS=$((PASS + 1)); echo "  PASS: a payload writing an unrelated file is still refused (#215, known FP)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: expected this payload to still be refused (the known false positive)"
  echo "    got: ${PAYLOAD_OUT:0:200}"
fi
if grep -qF "Split the literal" <<<"$PAYLOAD_OUT"; then
  PASS=$((PASS + 1)); echo "  PASS: the refusal names the split-literal workaround (#215)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the refusal does not name the split-literal workaround"
  echo "    got: ${PAYLOAD_OUT:0:400}"
fi
# The workaround itself must actually escape the rule -- proof, not just a claim in prose.
# The two halves of the index name are never adjacent in THIS command string, unlike above.
WORKAROUND_CMD="IDXNAME_215=\"00-index\"; IDXNAME_215=\"\$IDXNAME_215.tsv\"; supertool 'paste:@-' path=docs/other.md content=\"see > \$IDXNAME_215 for details\""
assert_allows "the split-literal workaround is not refused" "$(bash_payload "$WORKAROUND_CMD")"

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
# `.github/scripts/` is CI and is deliberately NOT swept -- requiring a jit-context rule
# for every future workflow helper is a bar nobody has agreed to. `tooling.md` used to
# reach one file there, `assemble_changelog.py`; that file is gone, replaced by the
# vendored `.oss/` copy, so the directory is now outside every rule and outside this
# sweep, which is the state it was always meant to be in.

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
