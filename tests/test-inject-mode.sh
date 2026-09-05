#!/bin/bash
# Tests for what a MATCH injects: the entry body, or its title and author-written
# `description:` (issue #1).
#
# The defect this is about is not accuracy, it is cost. A 14.9 KB entry arriving on the
# word `tag` is the whole case, and it does not depend on the match being wrong -- it
# depends on being wrong being expensive. So the mode is a project setting with a
# per-entry override -- `full` by default, for upgrade safety, and `summary` opt-in --
# and every assertion below is paired: a fixture that must arrive whole beside one that
# must not, in the same tree.
#
# Usage: bash tests/test-inject-mode.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT_HOOK="$SCRIPT_DIR/scripts/pre-prompt-hook.sh"
PATH_HOOK="$SCRIPT_DIR/scripts/pre-path-hook.sh"
TOOL_HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"
PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
# Cleanup on EVERY exit, not only the last line: this suite runs without `set -e`, so an
# interrupted or aborted run would otherwise leave its fixture tree behind.
trap 'rm -rf "$TEST_DIR"' EXIT
BASE="$TEST_DIR/.claude/jit-context"
V="$BASE/vocabulary/00-manual"
P="$BASE/paths/00-manual"
T="$BASE/tools/00-manual"
mkdir -p "$V" "$P" "$T"

# --- Fixtures ----------------------------------------------------------------
# Every body carries a marker string that appears NOWHERE in its frontmatter, so
# "the body arrived" and "the summary arrived" can never be confused for each other.

printf '%s\n' \
  "---" \
  "title: Billing amounts" \
  "description: How invoice totals are computed and why the getter lies." \
  "keywords: billing" \
  "---" \
  "" \
  "BILLING-BODY-MARKER" > "$V/billing.md"

printf '%s\n' \
  "---" \
  "title: Payments" \
  "description: Which provider settles what." \
  "inject: full" \
  "keywords: payments" \
  "---" \
  "" \
  "PAYMENTS-BODY-MARKER" > "$V/payments.md"

# Frontmatter, but no description:. Decided on issue #1 and deliberately NOT
# auto-generated: a generated summary of a wrong entry is a confident wrong summary.
printf '%s\n' \
  "---" \
  "title: Undescribed" \
  "keywords: nodesc" \
  "---" \
  "" \
  "NODESC-BODY-MARKER" > "$V/nodesc.md"

# No frontmatter at all. rebuild-tsv.sh could not have indexed this file -- it carries
# no keywords: either -- so it exists only in a hand-written index, there is nothing to
# summarise, and the body is the entry.
printf '%s\n' "BARE-BODY-MARKER" > "$V/bare.md"

# An inject: value that is neither summary nor full. `gated` is recorded on issue #1 and
# deliberately not built, so it must behave as any other unknown value behaves.
printf '%s\n' \
  "---" \
  "title: Gated hopeful" \
  "description: Wants a mode that does not exist." \
  "inject: gated" \
  "keywords: weird" \
  "---" \
  "" \
  "WEIRD-BODY-MARKER" > "$V/weird.md"

# Pinned to full by its own frontmatter AND carrying no description:. It can never be
# rendered as a summary whatever the project sets, so it is NOT what stands between this
# tree and being able to flip -- and a report that names it sends an author to write a
# line nothing will ever read.
printf '%s\n' \
  "---" \
  "title: Pinned" \
  "inject: full" \
  "keywords: pinned" \
  "---" \
  "" \
  "PINNED-BODY-MARKER" > "$V/pinned.md"

printf '%s\n' \
  "---" \
  "title: Opted in" \
  "description: This entry asked to be summarised." \
  "inject: summary" \
  "keywords: optin" \
  "---" \
  "" \
  "OPTIN-BODY-MARKER" > "$V/optin.md"

LONG_DESC="LONGDESCSTART$(printf 'x%.0s' $(seq 1 2000))LONGDESCEND"
printf '%s\n' \
  "---" \
  "title: Verbose" \
  "description: $LONG_DESC" \
  "keywords: longdesc" \
  "---" \
  "" \
  "LONG-BODY-MARKER" > "$V/longdesc.md"

# The same typo one outcome over: a mistyped inject: AND no description: at all. Under a
# summary default those are two different facts about the same file -- one sends the author
# to fix a word, the other to write a line -- and the log column has to be able to carry
# both at once, or it can only ever report whichever one is checked first.
printf '%s\n' \
  "---" \
  "title: Gated and undescribed" \
  "inject: gated" \
  "keywords: weirdnodesc" \
  "---" \
  "" \
  "WEIRDNODESC-BODY-MARKER" > "$V/weirdnodesc.md"

printf '%s\t%s\n' \
  billing billing.md \
  payments payments.md \
  nodesc nodesc.md \
  bare bare.md \
  weird weird.md \
  weirdnodesc weirdnodesc.md \
  optin optin.md \
  pinned pinned.md \
  longdesc longdesc.md > "$V/00-index.tsv"

printf '%s\n' \
  "---" \
  "title: Command conventions" \
  "description: Every command extends CommandBase." \
  "match: Commands/" \
  "---" \
  "" \
  "COMMANDS-BODY-MARKER" > "$P/commands.md"
printf 'Commands/\tcommands.md\n' > "$P/00-index.tsv"

printf '%s\n' \
  "---" \
  "title: Coverage is slow" \
  "description: Coverage runs take eight minutes locally." \
  "tool: Bash" \
  "match: bin/phpunit" \
  "---" \
  "" \
  "PHPUNIT-BODY-MARKER" > "$T/phpunit.md"

printf '%s\n' \
  "---" \
  "title: Never push to main" \
  "description: Open a merge request instead." \
  "tool: Bash" \
  "match: git push" \
  "mode: block" \
  "---" \
  "" \
  "GITPUSH-BODY-MARKER" > "$T/gitpush.md"

printf '%s\n' \
  "---" \
  "title: Deploys are dry-run first" \
  "description: The deploy script has no undo." \
  "tool: Bash" \
  "match: bin/deploy" \
  "require: --dry-run" \
  "---" \
  "" \
  "DEPLOY-BODY-MARKER" > "$T/deploy.md"

printf '%s\n' \
  "---" \
  "title: Never fetch over an unverified transport" \
  "description: The fetch helper refuses --insecure." \
  "tool: Bash" \
  "match: bin/fetch" \
  "forbid: --insecure" \
  "---" \
  "" \
  "FETCH-BODY-MARKER" > "$T/fetch.md"

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  Bash "bin/phpunit" phpunit.md remind "" "" \
  Bash "git push" gitpush.md block "" "" \
  Bash "bin/deploy" deploy.md remind "--dry-run" "" \
  Bash "bin/fetch" fetch.md remind "" "--insecure" > "$T/00-index.tsv"

# A block rule whose entry file carries no frontmatter and no text (#135). rebuild-tsv.sh
# cannot have produced this pair itself -- a file with no frontmatter has no tool: and no
# match: -- so it is a row written by hand, or one whose file was truncated after it was
# indexed. 00-index.tsv is committed and the markdown is read at fire time, so the two
# drifting apart is a state this tree already knows about.
printf '\n' > "$T/emptyblock.md"
# The same shape one dimension over: a `remind` row whose file has no text. This one must
# stay SILENT. A rule that refuses everything and a rule that refuses nothing both look
# like success from one side.
printf '\n' > "$T/emptyadv.md"

# Whitespace is not text, and the difference is not academic: a body that reads back as
# "\n\n" is not the empty string, so a guard testing for `== ""` lets it through and the
# rule refuses with a reason that renders as nothing at all. Blank lines are what a
# half-written entry and a truncated one both leave behind.
printf '\n\n  \n' > "$T/wsblock.md"
# The same shape on a `require:` row, which refuses through a different branch. Its reason
# is built as "BLOCKED: Missing required: X. " plus the body, so a text-less entry ends
# that sentence on a bare space.
printf '\n\n  \n' > "$T/wsrequire.md"

# Through a variable rather than the literal path, and that is not obfuscation: this
# repo's own tools/ rule refuses a shell redirect naming the generated index, so a payload
# carrying one cannot be typed by an agent editing this file at all.
IDX_TOOLS="$T/00-index.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  Bash "git shove" emptyblock.md block "" "" \
  Bash "git nudge" emptyadv.md remind "" "" \
  Bash "git heave" wsblock.md block "" "" \
  Bash "git haul" wsrequire.md remind "--safe" "" >> "$IDX_TOOLS"

# --- Helpers -----------------------------------------------------------------

set_config() {
  if [ -z "${1:-}" ]; then rm -f "$BASE/config.env"; else printf '%s\n' "$1" > "$BASE/config.env"; fi
}

run_prompt() { printf '%s' "{\"prompt\":\"$1\"}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" 2> /dev/null; }
run_tool() { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2> /dev/null; }
run_path() { printf '%s' "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$1\"}}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2> /dev/null; }

# The two below take (description, CAPTURED OUTPUT, needle), the shape most helpers in this
# tree carry. The `jit-drive:` lines are what puts them under `test-assertion-helpers.sh`'s
# 1 MB payload -- a suite that declares nothing is a hard failure there (#110), and this
# suite arrived from #54 one hour after that landed, which is how `main` went red.
# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  # Bash substring match, not `grep -qF <<<`: a fork per assertion is the dominant cost
  # of this suite under a slow-fork shell (measured: ~6ms/call on macOS's own grep, and
  # a Windows git-bash fork is far more expensive than that) -- #323. `[[ == *lit* ]]`
  # is byte-for-byte equivalent to `grep -qF` here: quoting "$expected" inside the
  # pattern strips its glob meaning, so a needle containing `*`, `?` or `[` still
  # matches literally. `grep -qF` itself matches per LINE, not across the whole
  # blob -- a needle containing a literal newline would OR-match each of its own
  # lines against each line of input, which `[[ == *lit* ]]` does not reproduce.
  # That divergence is never reached here: no needle at any assert_contains /
  # assert_not_contains / assert_blocked call site in this file embeds a newline,
  # so every needle can only ever land inside a single line of $output either way.
  if [[ "$output" == *"$expected"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:300}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if [[ "$output" == *"$unexpected"* ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:300}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

# jit-drive: assert_blocked blocked capture
assert_blocked() {
  local desc="$1" output="$2"
  if [[ "$output" == *'"decision":"block"'* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected a block payload"
    echo "    got: ${output:0:300}"
  fi
}

# Exact equality with `{}`, not "no block appeared": the second is also true of a hook that
# printed nothing at all, and of one that injected an advisory reminder instead. Silence
# here is a specific payload, so it is asserted as one.
# jit-drive: assert_silent not_blocked capture
assert_silent() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected: {}"
    echo "    got: ${output:0:300}"
  fi
}

# =============================================
# SECTION 1: the default is full, and summary is the opt-in
# =============================================
# The default is `full` for upgrade safety and for no other reason. A project that
# installed this before the mode existed has entries that arrive whole and agents that
# depend on it, and nobody opted into a silent downgrade to twenty tokens. Changing what
# an existing tree injects, without that tree asking, is an absence produced by the tool.
echo "=== No config.env: a match injects the whole body, as it always has ==="
set_config ""
OUT=$(run_prompt "what about the billing")
assert_contains "the entry is named" "$OUT" "Vocabulary: billing.md"
assert_contains "the body arrives whole" "$OUT" "BILLING-BODY-MARKER"
assert_not_contains "and nothing tells the agent to go and read it" "$OUT" "Summary only"

echo ""
echo "=== The same entry, project opted in to summary ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "what about the billing")
assert_contains "the entry is still named" "$OUT" "Vocabulary: billing.md"
assert_contains "the author description arrives" "$OUT" "How invoice totals are computed"
assert_contains "the title arrives" "$OUT" "Billing amounts"
assert_not_contains "the body does NOT arrive" "$OUT" "BILLING-BODY-MARKER"
assert_contains "the agent is told where to read it" "$OUT" ".claude/jit-context/vocabulary/00-manual/billing.md"

echo ""
echo "=== An entry can opt in on its own, under the default ==="
set_config ""
OUT=$(run_prompt "the optin one and the billing")
assert_contains "an entry that says inject: summary is summarised" "$OUT" "Summary only"
assert_not_contains "even though the project default is full" "$OUT" "OPTIN-BODY-MARKER"
assert_contains "paired: its neighbour under the default still arrives whole" "$OUT" "BILLING-BODY-MARKER"

# =============================================
# SECTION 2: the per-entry override, both directions
# =============================================
echo ""
echo "=== Project summary, entry says inject: full ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "billing and payments together")
assert_contains "the overriding entry arrives whole" "$OUT" "PAYMENTS-BODY-MARKER"
assert_not_contains "its neighbour in the same match does not" "$OUT" "BILLING-BODY-MARKER"
assert_contains "and the neighbour still has its description" "$OUT" "How invoice totals are computed"

echo ""
echo "=== Project full, entry says nothing: still full ==="
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_prompt "billing and payments together")
assert_contains "both bodies arrive" "$OUT" "BILLING-BODY-MARKER"
assert_contains "both bodies arrive (2)" "$OUT" "PAYMENTS-BODY-MARKER"

# =============================================
# SECTION 3: an entry with no description:
# =============================================
echo ""
echo "=== Frontmatter with no description: named, not injected ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "the nodesc thing and the billing")
assert_contains "the entry is named" "$OUT" "Vocabulary: nodesc.md"
assert_not_contains "its body is NOT injected" "$OUT" "NODESC-BODY-MARKER"
assert_contains "the absence is stated, not hidden" "$OUT" "no description:"
assert_contains "positive control: a described neighbour still says what it holds" \
  "$OUT" "How invoice totals are computed"

echo ""
echo "=== The same entry under full: the body arrives ==="
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_prompt "the nodesc thing")
assert_contains "no description does not suppress a full entry" "$OUT" "NODESC-BODY-MARKER"

# =============================================
# SECTION 4: a file with no frontmatter at all
# =============================================
echo ""
echo "=== No frontmatter: there is nothing to summarise, so the body is the entry ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "a bare entry and the billing")
assert_contains "the frontmatter-less body arrives" "$OUT" "BARE-BODY-MARKER"
assert_not_contains "paired: the entry WITH frontmatter beside it does not" "$OUT" "BILLING-BODY-MARKER"

# =============================================
# SECTION 5: an unknown mode, from either side
# =============================================
echo ""
echo "=== inject: gated in an entry -- unknown, so the project default applies ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "the weird one")
assert_not_contains "the body does not arrive" "$OUT" "WEIRD-BODY-MARKER"
assert_contains "the description does" "$OUT" "Wants a mode that does not exist"
assert_contains "and the unknown value is named, not silently dropped" "$OUT" "is not summary or full"
assert_not_contains "the value itself is never echoed back" "$OUT" "gated"

# The same entry on the path almost every project is on. `full` is the default, so a tree
# that has configured nothing is here -- and jit_inject_text() returned the body BEFORE the
# notice was appended, so an author's typo produced an entry that behaved exactly as though
# the line had never been written (#118). The fallback half of the contract held; the "and
# says so" half did not, everywhere it mattered.
#
# `gated` is NOT asserted absent here, unlike the summary leg above: under full the whole
# body arrives and the body carries the frontmatter, so the value is in the output as the
# author's own text. What must never echo it is the notice, and the notice does not.
echo ""
echo "=== inject: gated under the project default, which is full and is configured by nobody ==="
set_config ""
OUT=$(run_prompt "the weird one")
assert_contains "the body still arrives, so the fallback happened" "$OUT" "WEIRD-BODY-MARKER"
assert_contains "and the unknown value is named under full too" "$OUT" "is not summary or full"

# Both directions, same tree: a good inject: must produce no notice at all. On its own that
# assertion passes against a hook that injected nothing, so the body marker beside it is
# what makes the silence mean something.
echo ""
echo "=== Paired: a recognised inject: value produces no notice ==="
OUT=$(run_prompt "payments please")
assert_contains "positive control: the entry fired and arrived whole" "$OUT" "PAYMENTS-BODY-MARKER"
assert_not_contains "and nothing was said about its inject: value" "$OUT" "is not summary or full"

# And explicitly configured full, not just defaulted into: `full` reaches the same return.
echo ""
echo "=== The same pair with JIT_CONTEXT_INJECT=full spelled out ==="
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_prompt "the weird one and payments")
assert_contains "the mistyped entry is named" "$OUT" "is not summary or full"
assert_contains "paired: its neighbour arrived too" "$OUT" "PAYMENTS-BODY-MARKER"
assert_contains "and the mistyped entry still injected" "$OUT" "WEIRD-BODY-MARKER"

# =============================================
# SECTION 3b: the LOG can tell a typo from a decision (#130)
# =============================================
# The notice above is context, and context ends with the session. hooks.log is the durable
# record and the one a person greps, so the mode column there has to distinguish an entry
# that is deliberately `full` from one that fell back to `full` because its inject: line was
# mistyped. Before #130 both wrote the same six bytes, `[full]`, and the tally an author
# would want -- "which entries in this repo have a typo nobody noticed" -- was being read
# off a column that said the typo did not happen.
#
# Every assertion here is paired against a correctly-written entry in the SAME log line, so
# none of them can pass by the tag disappearing altogether.
JIT_LOG="$BASE/.discovery/logs/hooks.log"

# The log is a file the hook may legitimately decline to write, so its absence has to fail
# LOUDLY rather than leave the assertions below reading an empty string and passing the
# negative ones for free.
read_log() {
  if [ ! -s "$JIT_LOG" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1 -- hooks.log is missing or empty, so nothing below is evidence"
    LOGTEXT=""
    return 1
  fi
  LOGTEXT="$(cat "$JIT_LOG")"
}

echo ""
echo "=== The log distinguishes a mistyped inject: from a deliberate full ==="
set_config "JIT_CONTEXT_INJECT=full"
rm -f "$JIT_LOG"
run_prompt "the weird one and payments" > /dev/null
if read_log "full default"; then
  assert_contains "the mistyped entry is logged as a fallback, not a decision" \
    "$LOGTEXT" "weird.md(weird)[full:badmode]"
  assert_contains "paired: the entry that really asked for full says so plainly" \
    "$LOGTEXT" "payments.md(payments)[full]"
  assert_not_contains "so the two no longer write the same token" \
    "$LOGTEXT" "weird.md(weird)[full]"
fi

# The same blindness one default over, which is the half the issue did not name: a project
# on JIT_CONTEXT_INJECT=summary has a mistyped entry rendering as `[summary]`, which is
# exactly what an entry that asked for summary writes. The badmode fact is orthogonal to
# which of the three outcomes was reached, so it is carried as a suffix on all three rather
# than folded into the `full` one alone.
echo ""
echo "=== The same distinction under a summary default, on all three outcomes ==="
set_config "JIT_CONTEXT_INJECT=summary"
rm -f "$JIT_LOG"
run_prompt "the weird one and weirdnodesc and optin" > /dev/null
if read_log "summary default"; then
  assert_contains "a mistyped entry rendered as a summary says both" \
    "$LOGTEXT" "weird.md(weird)[summary:badmode]"
  assert_contains "and one with nothing to summarise says all three facts" \
    "$LOGTEXT" "weirdnodesc.md(weirdnodesc)[summary:no-description:badmode]"
  assert_contains "paired: an entry that asked for summary is still plain" \
    "$LOGTEXT" "optin.md(optin)[summary]"
  assert_not_contains "and the mistyped one is not confusable with it" \
    "$LOGTEXT" "weird.md(weird)[summary]"
fi

echo ""
echo "=== JIT_CONTEXT_INJECT=gated in config.env -- refused like any other bad line ==="
set_config "JIT_CONTEXT_INJECT=gated"
OUT=$(run_prompt "what about the billing")
assert_contains "the refusal is reported" "$OUT" "were refused"
# The default is `full`, so an unknown value falling back to it is the SAFE direction:
# a project that mistyped its setting keeps what it had rather than losing it.
assert_contains "and the default still applied" "$OUT" "BILLING-BODY-MARKER"
assert_contains "positive control: the entry still fired" "$OUT" "Vocabulary: billing.md"

echo ""
echo "=== JIT_CONTEXT_INJECT=full in config.env -- honoured, and NOT refused ==="
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_prompt "what about the billing")
assert_not_contains "a valid value raises no refusal" "$OUT" "were refused"
assert_contains "and it takes effect" "$OUT" "BILLING-BODY-MARKER"

# =============================================
# SECTION 6: a description cannot become a body
# =============================================
echo ""
echo "=== A very long description is clipped ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "longdesc please")
assert_contains "the start of it arrives" "$OUT" "LONGDESCSTART"
assert_not_contains "the end of it does not" "$OUT" "LONGDESCEND"
assert_contains "paired: a short description arrives whole" \
  "$(run_prompt "what about the billing")" "and why the getter lies."

# =============================================
# SECTION 7: paths and tools carry the same rule
# =============================================
echo ""
echo "=== Paths dimension ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_path "src/Commands/Deploy.php")
assert_contains "the description arrives" "$OUT" "Every command extends CommandBase"
assert_not_contains "the body does not" "$OUT" "COMMANDS-BODY-MARKER"
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_path "src/Commands/Deploy.php")
assert_contains "under full, the body does" "$OUT" "COMMANDS-BODY-MARKER"

echo ""
echo "=== Tools dimension, a remind rule ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_tool "bin/phpunit tests/")
assert_contains "the description arrives" "$OUT" "Coverage runs take eight minutes"
assert_not_contains "the body does not" "$OUT" "PHPUNIT-BODY-MARKER"
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_tool "bin/phpunit tests/")
assert_contains "under full, the body does" "$OUT" "PHPUNIT-BODY-MARKER"

# =============================================
# SECTION 8: a refusal is never a summary
# =============================================
# The call has already been stopped. There is no cheaper path left to buy, and the pull
# step is a soft rule an agent under momentum skips -- so a block reason that says "read
# the file to find out why" is an absence produced by the tool, which is the one failure
# this repository exists to name.
echo ""
echo "=== A block rule injects its whole body even under summary ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_tool "git push origin main")
assert_contains "the block reason is the whole entry" "$OUT" "GITPUSH-BODY-MARKER"
assert_contains "and it is a block" "$OUT" '"decision":"block"'

echo ""
echo "=== A require: block injects its whole body even under summary ==="
OUT=$(run_tool "bin/deploy production")
assert_contains "the block reason is the whole entry" "$OUT" "DEPLOY-BODY-MARKER"
assert_contains "and it names what was missing" "$OUT" "Missing required"

echo ""
echo "=== Paired: the same rule NOT blocking is a summary ==="
OUT=$(run_tool "bin/deploy production --dry-run")
assert_contains "the description arrives" "$OUT" "The deploy script has no undo"
assert_not_contains "the body does not" "$OUT" "DEPLOY-BODY-MARKER"

# A forbid: refusal is the same contract as require:, and it was NOT covered here.
# Both refusal paths read `body` and never `content` -- a rebase that resolved one of
# them to `content` left the other passing, which is the shape this file exists to catch.
echo ""
echo "=== A forbid: block injects its whole body even under summary ==="
OUT=$(run_tool "bin/fetch --insecure https://example.invalid")
assert_contains "the block reason is the whole entry" "$OUT" "FETCH-BODY-MARKER"
assert_contains "and it names what was forbidden" "$OUT" "Forbidden"

echo ""
echo "=== Paired: the same forbid rule NOT blocking is a summary ==="
OUT=$(run_tool "bin/fetch https://example.invalid")
assert_contains "the description arrives" "$OUT" "The fetch helper refuses --insecure"
assert_not_contains "the body does not" "$OUT" "FETCH-BODY-MARKER"

# =============================================
# SECTION 8b: a block rule with nothing to say still refuses (#135)
# =============================================
# The block branch used to sit inside `if (content != "" && blocked == "")`, so a rule
# whose entry file had no deliverable text was never reached and THE CALL WAS PERMITTED --
# exit 0, `{}`, nothing on stderr, indistinguishable from a rule that did not match.
#
# Driven under BOTH modes deliberately, and that pairing is why this was filed high rather
# than as a curiosity: under `summary` jit_inject_text() is never empty, so `content` was
# non-empty and the identical tree DID refuse. A block rule whose enforcement turns on an
# unrelated cost setting is the shape this repository exists to name.
echo ""
echo "=== A block rule whose entry has no text refuses anyway, under summary ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_tool "git shove origin main")
assert_blocked "the call is refused" "$OUT"
assert_contains "and the reason says the text is missing rather than being blank" \
  "$OUT" "was not delivered"

echo ""
echo "=== The same tree under full -- the mode may not decide whether a rule enforces ==="
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_tool "git shove origin main")
assert_blocked "the call is refused here too" "$OUT"
assert_contains "with the same substitute reason" "$OUT" "was not delivered"

# The other direction, same fixture: a NON-blocking row whose file has no text must inject
# nothing and permit. Without the pair below, everything above is also true of a hook that
# refuses on sight.
echo ""
echo "=== Paired: a remind rule with no text stays silent and permits ==="
OUT=$(run_tool "git nudge origin main")
assert_silent "an advisory rule with nothing to say injects nothing" "$OUT"

# ...and the positive control for that silence, which is the only thing that makes it mean
# anything: the same row, the same command, with text in the file. The body is read at fire
# time, so this needs no rebuild. If this leg fails, the silence above proved only that the
# harness was pointed at nothing.
printf 'NUDGE-BODY-MARKER\n' > "$T/emptyadv.md"
OUT=$(run_tool "git nudge origin main")
assert_contains "control: the same row fires once its file has text" "$OUT" "NUDGE-BODY-MARKER"
printf '\n' > "$T/emptyadv.md"

# Whitespace is not text. A guard testing for the empty string alone lets a body of two
# blank lines through, and the rule then refuses with a reason that renders as nothing --
# the same defect one shape over, and the shape a truncated file actually leaves.
echo ""
echo "=== Blank lines are not a reason either ==="
OUT=$(run_tool "git heave origin main")
assert_blocked "a whitespace-only entry still refuses" "$OUT"
assert_contains "and says why the reason is absent, rather than refusing blankly" \
  "$OUT" "was not delivered"

# `require:` refuses through a different branch, and its reason is built as
# "BLOCKED: Missing required: X. " plus the body -- so a text-less entry used to end that
# sentence on a bare space.
echo ""
echo "=== A require: refusal from a text-less entry says why too ==="
OUT=$(run_tool "git haul the thing")
assert_blocked "the requirement is absent, so the call is refused" "$OUT"
assert_contains "and the refusal names the requirement" "$OUT" "Missing required: --safe"
assert_contains "with the substitute where the body would be" "$OUT" "was not delivered"

# The other direction on that row: satisfy the requirement and it must not refuse. A
# whitespace-only body is not the empty string, so the advisory branch still injects a
# header -- and until #170, nothing under it: content != "" was the only guard, and a
# file of blank lines reads back as "\n", which passes that test. #135 drew this exact
# distinction seventy lines up for the refusal substitute and it was never applied here.
# This is the retirement of the "pre-existing behaviour ... not what this change is
# about" scoping a prior lane wrote at #165 -- deliberately, per #170s own framing.
OUT=$(run_tool "git haul the thing --safe")
assert_contains "control: the same row still fires when satisfied" "$OUT" "JIT Context: wsrequire.md"
assert_not_contains "and does not refuse" "$OUT" '"decision":"block"'
assert_contains "and says the entry has no text, rather than a bare header (#170)" \
  "$OUT" "has no text to inject"

# =============================================
# SECTION 9: the pull is observable
# =============================================
# The one admitted loss in this design is that the pull step is soft. It is measurable
# without any new machinery: reading the entry file is a tool call, and the path hook
# logs the path of every tool call it sees.
echo ""
echo "=== A read of an entry file is recorded in hooks.log ==="
set_config ""
LOG="$BASE/.discovery/logs/hooks.log"
rm -f "$LOG"
run_path "$TEST_DIR/.claude/jit-context/vocabulary/00-manual/billing.md" > /dev/null
if [ -f "$LOG" ]; then
  assert_contains "the pull shows up in the log" "$(cat "$LOG")" "vocabulary/00-manual/billing.md"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: no hooks.log was written"
fi

# =============================================
# SECTION 9b: a YAML-quoted value, and the build-time count agreeing with the hook
# =============================================
# `inject: "full"` is ordinary YAML. The hook strips a wrapping quote pair the way
# jit_frontmatter() does; the report in rebuild-tsv.sh has its own parser and did not,
# so it counted the entry as summary while the hook injected the whole body. A budget
# that disagrees with the thing it is budgeting is worse than no budget -- and it is the
# report the CHANGELOG points at as the answer to "nobody measures the drift".
echo ""
echo "=== inject: \"full\" is honoured, and counted ==="
set_config "JIT_CONTEXT_INJECT=summary"
printf '%s\n' \
  "---" \
  "title: Quoted" \
  "description: \"A quoted description.\"" \
  "inject: \"full\"" \
  "keywords: quoted" \
  "---" \
  "" \
  "QUOTED-BODY-MARKER" > "$V/quoted.md"
printf 'quoted\tquoted.md\n' >> "$V/00-index.tsv"

OUT=$(run_prompt "the quoted one")
assert_contains "the hook honours the quoted value" "$OUT" "QUOTED-BODY-MARKER"
REPORT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$SCRIPT_DIR/scripts/rebuild-tsv.sh" 2>&1 > /dev/null)
# Scoped to the "What a match costs" section alone (#232's own advisory-report pattern,
# lifted from test-generic-keywords-232.sh's IDCOL extraction): REPORT is rebuild-tsv.sh's
# WHOLE stderr, and it is not the only section entitled to name a file by path. The
# all-generic fallback (#232) has its own advisory section that correctly names any entry
# whose keywords are ALL classified generic against the bundled wordlist -- and once a
# fuller wordlist replaces the hand-curated stand-in (#251), "billing" is exactly the kind
# of ordinary word that list is meant to catch, so billing.md legitimately appears THERE
# for a reason that has nothing to do with the injection-cost question this pair of
# assertions is about. It is the LAST section rebuild-tsv.sh prints, so this reads to EOF.
COST_SECTION="$(awk '/=== What a match costs/{p=1} p' <<< "$REPORT")"
assert_contains "and rebuild-tsv counts it as arriving whole" "$COST_SECTION" "quoted.md"
# Paired, in the same section: the entry that is genuinely a summary is NOT counted.
assert_not_contains "and does not count a summary entry as whole" "$COST_SECTION" "billing.md"

# rebuild-tsv.sh rewrote every index in the fixture tree from frontmatter, which is not
# what the rest of this suite indexed by hand. Put them back, or every later assertion
# would be measuring the rebuild rather than the hooks. Every fixture, or the next
# section is quietly testing a smaller tree than the one it was written against.
printf '%s\t%s\n' \
  billing billing.md \
  payments payments.md \
  nodesc nodesc.md \
  bare bare.md \
  weird weird.md \
  weirdnodesc weirdnodesc.md \
  optin optin.md \
  pinned pinned.md \
  longdesc longdesc.md \
  quoted quoted.md > "$V/00-index.tsv"

# =============================================
# SECTION 9c: the exit condition is a number, not a slogan
# =============================================
# Default-`full` is a stage rather than a destination, and the risk it carries is issue
# #1s own objection one level up: a setting nobody revisits stays at maximum by inertia.
# What makes it reconsiderable is a measured figure for THIS tree, so the report has to
# name what a match costs, what it would cost summarised, and what stands in the way.
echo ""
echo "=== rebuild-tsv reports what a match costs, and what blocks the flip ==="
set_config ""
REPORT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$SCRIPT_DIR/scripts/rebuild-tsv.sh" 2>&1 > /dev/null)
assert_contains "it says which default is in force" "$REPORT" "JIT_CONTEXT_INJECT=full"
assert_contains "it prices one match, not the corpus" "$REPORT" "cost of ONE match, not a total"
assert_contains "with a summarised figure beside it" "$REPORT" "summarised"
# nodesc.md and bare.md carry no usable description: -- that is the distance between this
# tree and being able to flip, and it has to be named rather than counted in silence.
assert_contains "it names the entries that block the flip" "$REPORT" "carry no description:"
assert_contains "and names one of them" "$REPORT" "nodesc.md"
# Paired, in the same report: an entry that CAN be summarised is not listed as blocking.
assert_not_contains "and does not name one that can be summarised" "$REPORT" "  .claude/jit-context/vocabulary/00-manual/billing.md"
# And the other kind of non-blocker, which is the one that is easy to get wrong: an entry
# PINNED to full can never render as a summary, so its missing description: is not work
# anybody has to do before flipping. Naming it would send an author to write a line that
# nothing will ever read.
# Scoped to the no-description LIST, the way the assertion above it already is. A bare
# `pinned.md` needle is a claim about the whole of stderr, and stderr carries four other
# reports -- bare.md legitimately appears in the "no row in the index" one added by #44,
# since an entry with no frontmatter has no keywords: and therefore no row. An assertion
# about one section must name that section's own line shape.
assert_not_contains "nor an entry pinned to full by its own frontmatter" "$REPORT" "  .claude/jit-context/vocabulary/00-manual/pinned.md"
assert_not_contains "nor one with no frontmatter at all" "$REPORT" "  .claude/jit-context/vocabulary/00-manual/bare.md"
# And the positive half of the same needle shape: nodesc.md IS in that list, indented,
# under the full path. Without it the two above pass against a report that lists nothing.
assert_contains "the blocking entry is listed in that same shape" "$REPORT" "  .claude/jit-context/vocabulary/00-manual/nodesc.md"

# The other side of the same question: a tree with nothing in the way says so, because
# "2 entries block this" and "nothing blocks this" must not read identically.
CLEAN_DIR=$(mktemp -d)
mkdir -p "$CLEAN_DIR/.claude/jit-context/vocabulary/00-manual"
printf '%s\n' "---" "title: Clean" "description: Has one." "keywords: clean" "---" "" "body" \
  > "$CLEAN_DIR/.claude/jit-context/vocabulary/00-manual/clean.md"
CLEAN_REPORT=$(CLAUDE_PROJECT_DIR="$CLEAN_DIR" bash "$SCRIPT_DIR/scripts/rebuild-tsv.sh" 2>&1 > /dev/null)
assert_contains "a tree with nothing in the way says the flip is available" \
  "$CLEAN_REPORT" "can move to summary"
assert_not_contains "and does not also claim something blocks it" \
  "$CLEAN_REPORT" "carry no description:"
rm -rf "$CLEAN_DIR"

# rebuild-tsv.sh rewrote the fixture indexes again.
printf '%s\t%s\n' \
  billing billing.md \
  payments payments.md \
  nodesc nodesc.md \
  bare bare.md \
  weird weird.md \
  weirdnodesc weirdnodesc.md \
  optin optin.md \
  pinned pinned.md \
  longdesc longdesc.md \
  quoted quoted.md > "$V/00-index.tsv"

# =============================================
# SECTION 10: awk engine matrix -- a clipped multibyte description
# =============================================
# The clip is a substr, and substr counts BYTES on one-true-awk and CHARACTERS on gawk.
# A cut that lands inside a multibyte character leaves a lone continuation byte behind.
#
# Driven, not reasoned. With the boundary fixup disabled, awk version 20200816 printed
# NOTHING AT ALL for this prompt and still exited 0 -- the END block aborts on the byte,
# which is issue #14 one function over -- while gawk printed the whole object correctly.
# So the UTF-8 assertion below would have passed on the broken engine, on an empty file,
# for the worst possible reason. The positive control beside it is what caught it, and
# that is why the two are paired rather than the first one standing alone.
#
# Every assertion here runs once per awk on this machine, through a PATH shim.
echo ""
echo "=== A clipped description stays valid UTF-8 on every awk here ==="
# The clip only happens on the summary path, so this section opts in explicitly.

# 1 ASCII byte then 300 two-byte characters, so byte 400 -- the cap -- falls on the
# SECOND byte of a character rather than between two. An even-length prefix would put
# the cut on a boundary and the assertion would pass without testing anything.
MB_DESC="M$(awk 'BEGIN{ for (i = 0; i < 300; i++) printf "é" }')"
printf '%s\n' \
  "---" \
  "title: Multibyte" \
  "description: $MB_DESC" \
  "keywords: multibyte" \
  "---" \
  "" \
  "MB-BODY-MARKER" > "$V/multibyte.md"
printf 'multibyte\tmultibyte.md\n' >> "$V/00-index.tsv"
set_config "JIT_CONTEXT_INJECT=summary"

ENGINE_BIN=$(mktemp -d)
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2> /dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

for eng in $ENGINES; do
  OUTF=$(mktemp)
  printf '%s' '{"prompt":"the multibyte one"}' \
    | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" > "$OUTF" 2> /dev/null
  # Read from the FILE, never a $( ) capture: bash drops bytes a capture cannot carry,
  # so an assertion on a shell variable can pass against output that is already broken.
  if perl -0777 -ne 'my $x = $_; exit(utf8::decode($x) ? 0 : 1)' "$OUTF"; then
    PASS=$((PASS + 1))
    echo "  PASS: [$eng] the clipped description is valid UTF-8"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: [$eng] the clipped description is NOT valid UTF-8"
  fi
  # Paired: the assertion above passes trivially against a hook that injected nothing.
  assert_contains "[$eng] positive control: something was actually injected" \
    "$(cat "$OUTF")" "Multibyte"
  assert_not_contains "[$eng] and it was clipped, not delivered whole" \
    "$(cat "$OUTF")" "MB-BODY-MARKER"
  rm -f "$OUTF"
done
rm -rf "$ENGINE_BIN"

# =============================================
# SECTION 11: summary mode bounds its own header (#146)
# =============================================
# `summary` exists so that a match costs about twenty tokens instead of the whole entry
# (#1). The BODY was given a budget -- 160 bytes of title, 400 of description -- and the
# header beside it was not, so the two index columns the header quotes reopened exactly
# the cost the mode was added to close. Driven at ca89547: a 60,000-byte regex `match:`
# column on a `summary` entry, matching `git push origin main`, produced 60,223 bytes of
# ordinary advisory context, and a 60,000-byte entry-file column produced 60,539.
#
# Four assertions, one tree, and the last two are not decoration:
#
#   1. a long `match:` column on a `summary` row is bounded, and the header still names
#      the rule and the head of the pattern -- a bound that destroyed the handle would
#      trade one absence for another.
#   2. a `full` row is untouched. It never promised a cheap match, and a bound on its
#      header alone is walked around by moving one line down into the body -- which is
#      the argument that got #141 refused, applied to the path where it still holds.
#   3. a REFUSAL still carries its header whole. #141 asked for that bound and was
#      refused on a driven reason; without this leg the decision is one edit from being
#      undone silently.
#   4. the entry-file column is bounded too. Clipping only the pattern moves the same
#      60 KB one column over: an unreadable file name reaches the very same header with
#      a two-line substitute for a body.
#
# The assertions are byte-for-byte over ASCII, so no awk engine can disagree about them
# and they do not go through the PATH shim SECTION 10 builds.
echo ""
echo "=== A long index column cannot escape the summary budget (#146) ==="

LONG_PAT="LONGPATSTART$(printf 'x%.0s' $(seq 1 4000))LONGPATEND"
LONG_FILE="LONGFILESTART$(printf 'x%.0s' $(seq 1 4000))LONGFILEEND.md"

printf '%s\n' \
  "---" \
  "title: Enormous pattern, summarised" \
  "description: A rule whose match column is far larger than the entry it names." \
  "tool: Bash" \
  "inject: summary" \
  "---" \
  "" \
  "LONGSUM-BODY-MARKER" > "$T/longsum.md"

printf '%s\n' \
  "---" \
  "title: Enormous pattern, whole" \
  "description: The same rule, asking for its whole body." \
  "tool: Bash" \
  "inject: full" \
  "---" \
  "" \
  "LONGFULL-BODY-MARKER" > "$T/longfull.md"

printf '%s\n' \
  "---" \
  "title: Enormous pattern, refusing" \
  "description: The same rule again, and this one stops the call." \
  "tool: Bash" \
  "inject: summary" \
  "---" \
  "" \
  "LONGBLOCK-BODY-MARKER" > "$T/longblock.md"

# No frontmatter, and nothing but blank lines. TWO of them, not one: a single newline reads
# back as the empty string, never reaches the header at all, and the one-line version of
# this fixture would prove nothing -- the same distinction #135 drew one guard further up.
#
# A file with no frontmatter is pinned to `full` whatever the project sets, and `full` is
# what exempts a header from the #146 budget, on the reasoning that a full entry delivered
# its body whole and made no promise about what a match costs. This file delivers no body
# at all, so it took the exemption without the reason for it (#165).
printf '\n\n' > "$T/blankfull.md"

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  Bash "~git hurl|$LONG_PAT" longsum.md remind "" "" \
  Bash "~git lob|$LONG_PAT" longfull.md remind "" "" \
  Bash "~git chuck|$LONG_PAT" longblock.md block "" "" \
  Bash "~git fling" "$LONG_FILE" remind "" "" \
  Bash "~git shunt|$LONG_PAT" blankfull.md remind "" "" \
  Bash "~git toss|$LONG_PAT" missingentry.md remind "" "" >> "$IDX_TOOLS"

# The project is pinned to `full` here on purpose, and the word `default` is deliberately
# not used: SECTION 10 left `summary` in config.env, so this is an explicit override and
# the entry alone opts back in. What is being measured is the entrys own mode. The leg
# further down that says DEFAULT means the other thing -- no config.env at all -- and the
# two are not interchangeable, which is exactly what the first version of this section
# got wrong.
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_tool "git hurl at the wall")
assert_contains "the entry is still named" "$OUT" "longsum.md"
assert_contains "the head of the pattern still identifies it" "$OUT" "matched: ~git hurl|LONGPATSTART"
assert_contains "and the header says it was cut" "$OUT" "[clipped]"
assert_not_contains "the rest of the pattern does not arrive" "$OUT" "LONGPATEND"
assert_contains "control: the summary itself still arrives" "$OUT" "far larger than the entry"

echo ""
echo "=== Paired: a full entry has no budget to protect, so its header is untouched ==="
OUT=$(run_tool "git lob a brick")
assert_contains "the whole pattern is echoed back" "$OUT" "LONGPATEND"
assert_contains "control: and the body arrives whole" "$OUT" "LONGFULL-BODY-MARKER"

echo ""
echo "=== Paired: a refusal still carries its header whole, under summary (#141) ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_tool "git chuck it over there")
assert_blocked "the call is refused" "$OUT"
assert_contains "the refusal header keeps the whole pattern" "$OUT" "LONGPATEND"
assert_contains "and the whole body, as a refusal always does" "$OUT" "LONGBLOCK-BODY-MARKER"

echo ""
echo "=== The entry-file column is bounded on the same path, or the bound moves over ==="
OUT=$(run_tool "git fling it away")
assert_not_contains "the file column does not arrive whole" "$OUT" "LONGFILEEND"
assert_contains "control: the row still says its text could not be delivered" \
  "$OUT" "was not delivered"

# ...and the same two rows under the DEFAULT, which is `full` and is what every project
# that configured nothing is on. This is the leg the first version of this section did not
# have, and it was wrong in exactly the way that matters: `full` exempts the header
# because a full entry delivers its body whole at its author-s request -- and a row whose
# entry file cannot be read delivers no body at all, only a two-line substitute, in every
# mode. So the mode is the wrong question here and the header was still 60 KB. Driven
# against the first fix: 60,539 bytes for the file column, 60,547 for the pattern.
echo ""
echo "=== A row with no deliverable text is bounded whatever the mode says ==="
set_config ""
OUT=$(run_tool "git fling it away")
assert_not_contains "the file column is still bounded under the default" "$OUT" "LONGFILEEND"
assert_contains "control: the row still reports itself" "$OUT" "was not delivered"

OUT=$(run_tool "git toss it out")
assert_not_contains "and so is the pattern beside it" "$OUT" "LONGPATEND"
assert_contains "control: that row reports itself too" "$OUT" "was not delivered"
assert_contains "control: and it is still named" "$OUT" "missingentry.md"

# Paired, and this is what keeps the bound above from reading as `full is now clipped`:
# the SAME default, a row whose file reads fine, still echoes its whole pattern.
OUT=$(run_tool "git lob a brick")
assert_contains "a full entry whose body arrived keeps its whole header" "$OUT" "LONGPATEND"

# ...and the shape the exemption was never argued for (#165). The exemption above is
# earned by "this entry delivered its body whole at its authors request". A file with no
# frontmatter is pinned to `full` and delivers whatever text it has -- and when it has
# none, the exemption is taken with nothing under the header to justify it. Driven at
# cdff15a on one-true-awk with no config.env: a 60,000-byte `match:` column on this row
# produced 60,125 bytes of additionalContext, under which the delivered body was a single
# newline.
#
# Not a vulnerability, and that is why the fix is a term in the gate and not a new bound:
# the control drive, same tree, is a short `match:` and 60,000 bytes IN the entry file,
# which costs 60,124. The two channels cost the same and #155s caps give up nothing. What
# was wrong is the gate taking the exemption for a case its own comment said could not
# reach it.
echo ""
echo "=== An entry with no body has nothing to exempt, so its header is bounded (#165) ==="
OUT=$(run_tool "git shunt it sideways")
assert_contains "the entry is still named" "$OUT" "blankfull.md"
assert_contains "and the head of the pattern identifies it" \
  "$OUT" "matched: ~git shunt|LONGPATSTART"
assert_contains "and the header says it was cut" "$OUT" "[clipped]"
assert_not_contains "the rest of the pattern does not arrive" "$OUT" "LONGPATEND"
# The same fixture is #170s: a bare header with nothing under it, because content is
# "\n\n" rather than "". Paired with the wsrequire.md leg in SECTION 8 so the report is
# not tied to one call site of the guard.
assert_contains "and what IS under the header says the entry is empty (#170)" \
  "$OUT" "has no text to inject"

# The control that makes the four above mean anything, and the only one that isolates the
# BODY as the cause: the same row, the same command, the same 60,000-byte pattern, with
# text in the file. The body is read at fire time, so this needs no rebuild. Without it,
# "LONGPATEND did not arrive" is also true of a hook that matched nothing at all.
printf 'SHUNT-BODY-MARKER\n' > "$T/blankfull.md"
OUT=$(run_tool "git shunt it sideways")
assert_contains "control: the same row fires once its file has text" "$OUT" "SHUNT-BODY-MARKER"
assert_contains "control: and its header is whole again" "$OUT" "LONGPATEND"
printf '\n\n' > "$T/blankfull.md"

# The other direction: the row must still be silent on a command it does not match. A
# bound that fired on everything and a bound that fired on nothing both read as green
# from the side above.
OUT=$(run_tool "ls -la")
assert_not_contains "and a command it does not match reaches no header at all" \
  "$OUT" "blankfull.md"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
