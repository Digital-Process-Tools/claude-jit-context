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

printf '%s\t%s\n' \
  billing  billing.md \
  payments payments.md \
  nodesc   nodesc.md \
  bare     bare.md \
  weird    weird.md \
  optin    optin.md \
  pinned   pinned.md \
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
  Bash "bin/phpunit" phpunit.md remind ""          "" \
  Bash "git push"    gitpush.md  block  ""          "" \
  Bash "bin/deploy"  deploy.md   remind "--dry-run" "" \
  Bash "bin/fetch"   fetch.md    remind ""          "--insecure" > "$T/00-index.tsv"

# --- Helpers -----------------------------------------------------------------

set_config() {
  if [ -z "${1:-}" ]; then rm -f "$BASE/config.env"; else printf '%s\n' "$1" > "$BASE/config.env"; fi
}

run_prompt() { printf '%s' "{\"prompt\":\"$1\"}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" 2>/dev/null; }
run_tool()   { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2>/dev/null; }
run_path()   { printf '%s' "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$1\"}}" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2>/dev/null; }

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:300}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:300}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
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
assert_contains     "the entry is named"       "$OUT" "Vocabulary: billing.md"
assert_contains     "the body arrives whole"   "$OUT" "BILLING-BODY-MARKER"
assert_not_contains "and nothing tells the agent to go and read it" "$OUT" "Summary only"

echo ""
echo "=== The same entry, project opted in to summary ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "what about the billing")
assert_contains     "the entry is still named"        "$OUT" "Vocabulary: billing.md"
assert_contains     "the author description arrives"  "$OUT" "How invoice totals are computed"
assert_contains     "the title arrives"               "$OUT" "Billing amounts"
assert_not_contains "the body does NOT arrive"        "$OUT" "BILLING-BODY-MARKER"
assert_contains     "the agent is told where to read it" "$OUT" ".claude/jit-context/vocabulary/00-manual/billing.md"

echo ""
echo "=== An entry can opt in on its own, under the default ==="
set_config ""
OUT=$(run_prompt "the optin one and the billing")
assert_contains     "an entry that says inject: summary is summarised" "$OUT" "Summary only"
assert_not_contains "even though the project default is full"          "$OUT" "OPTIN-BODY-MARKER"
assert_contains     "paired: its neighbour under the default still arrives whole" "$OUT" "BILLING-BODY-MARKER"

# =============================================
# SECTION 2: the per-entry override, both directions
# =============================================
echo ""
echo "=== Project summary, entry says inject: full ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "billing and payments together")
assert_contains     "the overriding entry arrives whole" "$OUT" "PAYMENTS-BODY-MARKER"
assert_not_contains "its neighbour in the same match does not" "$OUT" "BILLING-BODY-MARKER"
assert_contains     "and the neighbour still has its description" "$OUT" "How invoice totals are computed"

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
assert_contains     "the entry is named"                  "$OUT" "Vocabulary: nodesc.md"
assert_not_contains "its body is NOT injected"            "$OUT" "NODESC-BODY-MARKER"
assert_contains     "the absence is stated, not hidden"   "$OUT" "no description:"
assert_contains     "positive control: a described neighbour still says what it holds" \
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
assert_contains     "the frontmatter-less body arrives" "$OUT" "BARE-BODY-MARKER"
assert_not_contains "paired: the entry WITH frontmatter beside it does not" "$OUT" "BILLING-BODY-MARKER"

# =============================================
# SECTION 5: an unknown mode, from either side
# =============================================
echo ""
echo "=== inject: gated in an entry -- unknown, so the project default applies ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "the weird one")
assert_not_contains "the body does not arrive"     "$OUT" "WEIRD-BODY-MARKER"
assert_contains     "the description does"         "$OUT" "Wants a mode that does not exist"
assert_contains     "and the unknown value is named, not silently dropped" "$OUT" "is not summary or full"
assert_not_contains "the value itself is never echoed back" "$OUT" "gated"

echo ""
echo "=== JIT_CONTEXT_INJECT=gated in config.env -- refused like any other bad line ==="
set_config "JIT_CONTEXT_INJECT=gated"
OUT=$(run_prompt "what about the billing")
assert_contains     "the refusal is reported"   "$OUT" "were refused"
# The default is `full`, so an unknown value falling back to it is the SAFE direction:
# a project that mistyped its setting keeps what it had rather than losing it.
assert_contains     "and the default still applied" "$OUT" "BILLING-BODY-MARKER"
assert_contains     "positive control: the entry still fired" "$OUT" "Vocabulary: billing.md"

echo ""
echo "=== JIT_CONTEXT_INJECT=full in config.env -- honoured, and NOT refused ==="
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_prompt "what about the billing")
assert_not_contains "a valid value raises no refusal" "$OUT" "were refused"
assert_contains     "and it takes effect"             "$OUT" "BILLING-BODY-MARKER"

# =============================================
# SECTION 6: a description cannot become a body
# =============================================
echo ""
echo "=== A very long description is clipped ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_prompt "longdesc please")
assert_contains     "the start of it arrives" "$OUT" "LONGDESCSTART"
assert_not_contains "the end of it does not"  "$OUT" "LONGDESCEND"
assert_contains     "paired: a short description arrives whole" \
                    "$(run_prompt "what about the billing")" "and why the getter lies."

# =============================================
# SECTION 7: paths and tools carry the same rule
# =============================================
echo ""
echo "=== Paths dimension ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_path "src/Commands/Deploy.php")
assert_contains     "the description arrives" "$OUT" "Every command extends CommandBase"
assert_not_contains "the body does not"       "$OUT" "COMMANDS-BODY-MARKER"
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_path "src/Commands/Deploy.php")
assert_contains "under full, the body does"   "$OUT" "COMMANDS-BODY-MARKER"

echo ""
echo "=== Tools dimension, a remind rule ==="
set_config "JIT_CONTEXT_INJECT=summary"
OUT=$(run_tool "bin/phpunit tests/")
assert_contains     "the description arrives" "$OUT" "Coverage runs take eight minutes"
assert_not_contains "the body does not"       "$OUT" "PHPUNIT-BODY-MARKER"
set_config "JIT_CONTEXT_INJECT=full"
OUT=$(run_tool "bin/phpunit tests/")
assert_contains "under full, the body does"   "$OUT" "PHPUNIT-BODY-MARKER"

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
assert_contains "and it is a block"                   "$OUT" '"decision":"block"'

echo ""
echo "=== A require: block injects its whole body even under summary ==="
OUT=$(run_tool "bin/deploy production")
assert_contains "the block reason is the whole entry" "$OUT" "DEPLOY-BODY-MARKER"
assert_contains "and it names what was missing"       "$OUT" "Missing required"

echo ""
echo "=== Paired: the same rule NOT blocking is a summary ==="
OUT=$(run_tool "bin/deploy production --dry-run")
assert_contains     "the description arrives" "$OUT" "The deploy script has no undo"
assert_not_contains "the body does not"       "$OUT" "DEPLOY-BODY-MARKER"

# A forbid: refusal is the same contract as require:, and it was NOT covered here.
# Both refusal paths read `body` and never `content` -- a rebase that resolved one of
# them to `content` left the other passing, which is the shape this file exists to catch.
echo ""
echo "=== A forbid: block injects its whole body even under summary ==="
OUT=$(run_tool "bin/fetch --insecure https://example.invalid")
assert_contains "the block reason is the whole entry" "$OUT" "FETCH-BODY-MARKER"
assert_contains "and it names what was forbidden"     "$OUT" "Forbidden"

echo ""
echo "=== Paired: the same forbid rule NOT blocking is a summary ==="
OUT=$(run_tool "bin/fetch https://example.invalid")
assert_contains     "the description arrives" "$OUT" "The fetch helper refuses --insecure"
assert_not_contains "the body does not"       "$OUT" "FETCH-BODY-MARKER"

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
run_path "$TEST_DIR/.claude/jit-context/vocabulary/00-manual/billing.md" >/dev/null
if [ -f "$LOG" ]; then
  assert_contains "the pull shows up in the log" "$(cat "$LOG")" "vocabulary/00-manual/billing.md"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: no hooks.log was written"
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
REPORT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$SCRIPT_DIR/scripts/rebuild-tsv.sh" 2>&1 >/dev/null)
assert_contains "and rebuild-tsv counts it as arriving whole" "$REPORT" "quoted.md"
# Paired, in the same report: the entry that is genuinely a summary is NOT counted.
assert_not_contains "and does not count a summary entry as whole" "$REPORT" "billing.md"

# rebuild-tsv.sh rewrote every index in the fixture tree from frontmatter, which is not
# what the rest of this suite indexed by hand. Put them back, or every later assertion
# would be measuring the rebuild rather than the hooks. Every fixture, or the next
# section is quietly testing a smaller tree than the one it was written against.
printf '%s\t%s\n' \
  billing  billing.md \
  payments payments.md \
  nodesc   nodesc.md \
  bare     bare.md \
  weird    weird.md \
  optin    optin.md \
  pinned   pinned.md \
  longdesc longdesc.md \
  quoted   quoted.md > "$V/00-index.tsv"

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
REPORT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$SCRIPT_DIR/scripts/rebuild-tsv.sh" 2>&1 >/dev/null)
assert_contains "it says which default is in force"   "$REPORT" "JIT_CONTEXT_INJECT=full"
assert_contains "it prices one match, not the corpus" "$REPORT" "cost of ONE match, not a total"
assert_contains "with a summarised figure beside it"  "$REPORT" "summarised"
# nodesc.md and bare.md carry no usable description: -- that is the distance between this
# tree and being able to flip, and it has to be named rather than counted in silence.
assert_contains "it names the entries that block the flip" "$REPORT" "carry no description:"
assert_contains "and names one of them"                    "$REPORT" "nodesc.md"
# Paired, in the same report: an entry that CAN be summarised is not listed as blocking.
assert_not_contains "and does not name one that can be summarised" "$REPORT" "  .claude/jit-context/vocabulary/00-manual/billing.md"
# And the other kind of non-blocker, which is the one that is easy to get wrong: an entry
# PINNED to full can never render as a summary, so its missing description: is not work
# anybody has to do before flipping. Naming it would send an author to write a line that
# nothing will ever read.
assert_not_contains "nor an entry pinned to full by its own frontmatter" "$REPORT" "pinned.md"
assert_not_contains "nor one with no frontmatter at all"                "$REPORT" "bare.md"

# The other side of the same question: a tree with nothing in the way says so, because
# "2 entries block this" and "nothing blocks this" must not read identically.
CLEAN_DIR=$(mktemp -d)
mkdir -p "$CLEAN_DIR/.claude/jit-context/vocabulary/00-manual"
printf '%s\n' "---" "title: Clean" "description: Has one." "keywords: clean" "---" "" "body" \
  > "$CLEAN_DIR/.claude/jit-context/vocabulary/00-manual/clean.md"
CLEAN_REPORT=$(CLAUDE_PROJECT_DIR="$CLEAN_DIR" bash "$SCRIPT_DIR/scripts/rebuild-tsv.sh" 2>&1 >/dev/null)
assert_contains     "a tree with nothing in the way says the flip is available" \
                    "$CLEAN_REPORT" "can move to summary"
assert_not_contains "and does not also claim something blocks it" \
                    "$CLEAN_REPORT" "carry no description:"
rm -rf "$CLEAN_DIR"

# rebuild-tsv.sh rewrote the fixture indexes again.
printf '%s\t%s\n' \
  billing  billing.md \
  payments payments.md \
  nodesc   nodesc.md \
  bare     bare.md \
  weird    weird.md \
  optin    optin.md \
  pinned   pinned.md \
  longdesc longdesc.md \
  quoted   quoted.md > "$V/00-index.tsv"

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
  cand_path=$(command -v "$cand" 2>/dev/null) || continue
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
    | PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" > "$OUTF" 2>/dev/null
  # Read from the FILE, never a $( ) capture: bash drops bytes a capture cannot carry,
  # so an assertion on a shell variable can pass against output that is already broken.
  if perl -0777 -ne 'my $x = $_; exit(utf8::decode($x) ? 0 : 1)' "$OUTF"; then
    PASS=$((PASS + 1)); echo "  PASS: [$eng] the clipped description is valid UTF-8"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: [$eng] the clipped description is NOT valid UTF-8"
  fi
  # Paired: the assertion above passes trivially against a hook that injected nothing.
  assert_contains "[$eng] positive control: something was actually injected" \
                  "$(cat "$OUTF")" "Multibyte"
  assert_not_contains "[$eng] and it was clipped, not delivered whole" \
                  "$(cat "$OUTF")" "MB-BODY-MARKER"
  rm -f "$OUTF"
done
rm -rf "$ENGINE_BIN"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
