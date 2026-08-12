#!/bin/bash
# Tests for scripts/jit-misses.sh -- report the vocabulary this project keeps not having.
#
# The script reads the hook log and prints nothing else: it writes no file, fires no hook
# and makes no network call. What it can get wrong is the thing this repo keeps finding in
# its own product -- an empty report that means "no repeated misses" and "the log was not
# readable" identically. So every fixture below pins WHICH of the three outcomes is due:
# findings, `ok`, or `SKIPPED` with the reason named and exit 2.
#
# Usage: bash tests/test-jit-misses.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MISSES="$SCRIPT_DIR/scripts/jit-misses.sh"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

# A token row is `  2x  token`. Substring matching cannot express its absence -- the
# example prompts printed under a row contain the fragments themselves, so `taill` is in
# the output either way. The claim is about the ROW, so match the whole line.
assert_no_token_row() {
  local desc="$1" output="$2" token="$3"
  if printf '%s\n' "$output" | grep -qE "^ +[0-9]+x  $token\$"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should have no row for token: $token"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_token_row() {
  local desc="$1" output="$2" token="$3"
  if printf '%s\n' "$output" | grep -qE "^ +[0-9]+x  $token\$"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected a row for token: $token"
    echo "    got: $(echo "$output" | cut -c1-400)"
  fi
}

assert_status() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $actual, expected $expected)"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A missing script makes every "must not appear" assertion below pass on the error
# message, which is the vacuous green this suite exists to refuse.
if [ ! -f "$MISSES" ]; then
  echo "  FAIL: harness guard -- $MISSES does not exist, every assertion below is vacuous"
  exit 1
fi

# --- Fixture A: a log with everything in it ----------------------------------
# One matched prompt, two misses sharing `xsd`, two slash commands, one harness block,
# one miss with no recurring word, and two NON-prompt misses whose words must never be
# counted -- the tool and path dimensions dominate this log by volume (976 of 1242
# `(none)` rows on the maintainer's machine) and none of them is a vocabulary gap.
A="$TMP/a.log"
cat > "$A" <<'LOG'
[10:00:00.001] pre-prompt 9ms | 00-manual:jit-context.md(rebuild-tsv) [shown:1] << how does rebuild-tsv build the index
[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << how do i do xsd validation here
[10:00:02.001] pre-prompt 9ms | (none) [shown:1] << validate the xsd please
[10:00:03.001] pre-prompt 9ms | (none) [shown:0] << /opensource-manager
[10:00:04.001] pre-prompt 12ms | (none) [shown:0] << /opensource-manager
[10:00:05.001] pre-prompt 9ms | (none) [shown:1] << <task-notification>
[10:00:06.001] pre-prompt 9ms | (none) [shown:1] << the billing export is broken
[10:00:07.001] pre-tool (Bash) 29ms | (none) [shown:2] << wsdl generate --all
[10:00:08.001] pre-path 13ms | (none) << src/Wsdl/Thing.php
LOG

# Harness guard. Every "must not appear" assertion below is decoration if the fixture
# never reached the script, and an empty file would satisfy all of them at once.
if [ ! -s "$A" ]; then
  echo "  FAIL: harness guard -- fixture A is empty, every silence assertion below is vacuous"
  exit 1
fi

echo ""
echo "=== a log with repeated misses reports them, highest first ==="
OUT=$(bash "$MISSES" --log "$A" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 -- the log was readable" "$ST" "0"
assert_contains "counts what it actually read" "$OUT" "7 prompt record(s)"
assert_contains "counts the misses among them" "$OUT" "6 with no vocabulary match"
assert_contains "reports the recurring token" "$OUT" "xsd"
assert_contains "with its count" "$OUT" "2x"
assert_contains "and shows one prompt that produced it" "$OUT" "how do i do xsd validation here"
assert_contains "and the other, so the grouping is visible" "$OUT" "validate the xsd please"

echo ""
echo "=== and stays silent about everything that is not a repeated vocabulary miss ==="
assert_not_contains "a slash command is not a question about the codebase" "$OUT" "opensource"
assert_not_contains "a harness block is not a prompt someone typed" "$OUT" "task-notification"
assert_not_contains "a token seen once is not recurring" "$OUT" "billing"
assert_not_contains "a stopword shared by two misses is not a shared subject" "$OUT" "the billing export"
assert_not_contains "a pre-tool miss is not a vocabulary miss" "$OUT" "wsdl"
assert_not_contains "a pre-path miss is not one either" "$OUT" "Thing.php"

echo ""
echo "=== --min 1 proves the silences above are the rule, not an unread fixture ==="
OUT1=$(bash "$MISSES" --log "$A" --min 1 2>&1) && ST=0 || ST=$?
assert_status "exit 0" "$ST" "0"
assert_contains "the single-occurrence token IS in the fixture" "$OUT1" "billing"
assert_contains "and so is xsd" "$OUT1" "xsd"
assert_not_contains "but a stopword is dropped at any threshold" "$OUT1" "1x  the"
assert_not_contains "and a slash command is set aside at any threshold" "$OUT1" "opensource"

echo ""
echo "=== a log that cannot be read is SKIPPED, never an empty report ==="
OUT=$(bash "$MISSES" --log "$TMP/does-not-exist.log" 2>&1) && ST=0 || ST=$?
assert_status "exit 2 -- could not evaluate" "$ST" "2"
assert_contains "says SKIPPED" "$OUT" "SKIPPED"
assert_contains "and names the file it looked for" "$OUT" "does-not-exist.log"

EMPTY="$TMP/empty.log"
: > "$EMPTY"
OUT=$(bash "$MISSES" --log "$EMPTY" 2>&1) && ST=0 || ST=$?
assert_status "an empty log is exit 2" "$ST" "2"
assert_contains "and says so" "$OUT" "SKIPPED"
assert_contains "naming emptiness as the reason" "$OUT" "empty"

FOREIGN="$TMP/foreign.log"
cat > "$FOREIGN" <<'LOG'
2026-08-12 04:00:00 INFO  something entirely else happened
2026-08-12 04:00:01 WARN  and again
LOG
OUT=$(bash "$MISSES" --log "$FOREIGN" 2>&1) && ST=0 || ST=$?
assert_status "a log in another format is exit 2" "$ST" "2"
assert_contains "and says SKIPPED" "$OUT" "SKIPPED"
assert_contains "naming the format as the reason" "$OUT" "format"

# The one that matters most: a log FULL of hook records, none of them from the prompt
# hook. Volume looks like evidence and is not -- this must not read as "prompts, no
# misses", which is exactly what a row count would say.
NOPROMPT="$TMP/noprompt.log"
cat > "$NOPROMPT" <<'LOG'
[10:00:07.001] pre-tool (Bash) 29ms | (none) [shown:2] << wsdl generate --all
[10:00:08.001] pre-path 13ms | (none) << src/Wsdl/Thing.php
[10:00:09.001] pre-tool (Read) 11ms | (none) [shown:2] << src/Other.php
LOG
OUT=$(bash "$MISSES" --log "$NOPROMPT" 2>&1) && ST=0 || ST=$?
assert_status "hook records but no prompt records is exit 2" "$ST" "2"
assert_contains "says SKIPPED" "$OUT" "SKIPPED"
assert_contains "naming the prompt hook as what never logged" "$OUT" "pre-prompt"
assert_not_contains "and never claims there was nothing to find" "$OUT" "ok --"

echo ""
echo "=== a log with prompt records and nothing recurring is ok, not SKIPPED ==="
CLEAN="$TMP/clean.log"
cat > "$CLEAN" <<'LOG'
[10:00:00.001] pre-prompt 9ms | 00-manual:jit-context.md(rebuild-tsv) [shown:1] << how does rebuild-tsv build the index
[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << who owns the deployment calendar
LOG
OUT=$(bash "$MISSES" --log "$CLEAN" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 -- read fine, found nothing" "$ST" "0"
assert_contains "says ok" "$OUT" "ok --"
assert_not_contains "and is not confused with a skip" "$OUT" "SKIPPED"
assert_contains "while still reporting what it read" "$OUT" "2 prompt record(s)"

echo ""
echo "=== an unknown flag is refused, not silently ignored ==="
OUT=$(bash "$MISSES" --log "$A" --nonsense 2>&1) && ST=0 || ST=$?
assert_status "exit 2" "$ST" "2"
assert_contains "names the flag" "$OUT" "--nonsense"

# A flag with no value used to let `shift 2` fail on its own: exit 2 with NOTHING
# printed, which is the two-outcome collapse this whole script exists to prevent,
# in the argument parser of the script that prevents it.
for f in --log --min --top; do
  OUT=$(bash "$MISSES" "$f" 2>&1) && ST=0 || ST=$?
  assert_status "$f with no value is exit 2" "$ST" "2"
  assert_contains "$f with no value still says SKIPPED" "$OUT" "SKIPPED"
  assert_contains "$f with no value names the flag" "$OUT" "$f"
done

echo ""
echo "=== a record from a tool nobody hardcoded is still a recognised record ==="
# pre-tool-hook.sh logs `pre-tool ($tool_name)` straight from the payload, and an MCP
# tool is mcp__server__thing. A log made only of those is "no prompt records", NOT
# "unrecognised format" -- the right verdict for the wrong reason is still wrong.
MCP="$TMP/mcp.log"
cat > "$MCP" <<'LOG'
[10:00:07.001] pre-tool (mcp__claude-in-chrome__navigate) 29ms | (none) [shown:2] << go to page
[10:00:08.001] pre-tool (mcp__claude-in-chrome__navigate) 31ms | (none) [shown:2] << go to page again
LOG
OUT=$(bash "$MISSES" --log "$MCP" 2>&1) && ST=0 || ST=$?
assert_status "exit 2" "$ST" "2"
assert_contains "names the prompt hook as what is missing" "$OUT" "none of them from pre-prompt"
assert_not_contains "and does not blame the format" "$OUT" "hook log format"

echo ""
echo "=== --help carries the grouping rule, because it is a judgement call ==="
OUT=$(bash "$MISSES" --help 2>&1) && ST=0 || ST=$?
assert_status "exit 0" "$ST" "0"
assert_contains "states what counts as the same miss" "$OUT" "same miss"

echo ""
echo "=== the script writes nothing ==="
WDIR="$TMP/wdir"
mkdir -p "$WDIR"
# No --log here on purpose: this is the only assertion that exercises the DEFAULT path,
# which the script derives itself rather than taking from common.sh (common.sh mkdir -p's
# the log directory at load, and a reporting tool must not create what it reports on).
OUT=$(cd "$WDIR" && CLAUDE_PROJECT_DIR="$WDIR" bash "$MISSES" 2>&1) && ST=0 || ST=$?
assert_status "no log under CLAUDE_PROJECT_DIR is exit 2" "$ST" "2"
assert_contains "and it names the path it derived" "$OUT" ".claude/jit-context/.discovery/logs/hooks.log"
AFTER=$(find "$WDIR" | sort)
assert_not_contains "reading created no .claude tree" "$AFTER" ".claude"
COUNT=$(printf '%s\n' "$AFTER" | grep -c . || true)
assert_status "the working dir still holds exactly one entry (itself)" "$COUNT" "1"

# =============================================
# SECTION: awk engine matrix
# =============================================
# The report is one awk pass, and the two awks on a CI machine do not agree about
# multibyte input or about split(). A green run under one is not evidence about the
# other -- issue #14 was green under gawk and aborted under one-true-awk.
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

# An accented prompt is the fixture that broke the prompt hook itself under one-true-awk.
ACCENT="$TMP/accent.log"
cat > "$ACCENT" <<'LOG'
[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << comment marche la facturation détaillée
[10:00:02.001] pre-prompt 9ms | (none) [shown:1] << la facturation est cassée
[10:00:03.001] pre-prompt 9ms | (none) [shown:1] << /some-command
LOG

for eng in $ENGINES; do
  echo ""
  echo "=== engine: $eng ==="
  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$MISSES" --log "$A" 2>&1) && ST=0 || ST=$?
  assert_status "[$eng] findings, exit 0" "$ST" "0"
  assert_contains "[$eng] groups on the shared token" "$OUT" "xsd"
  assert_not_contains "[$eng] and not on a slash command" "$OUT" "opensource"

  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$MISSES" --log "$ACCENT" 2>&1) && ST=0 || ST=$?
  assert_status "[$eng] an accented log still reports, exit 0" "$ST" "0"
  assert_contains "[$eng] and finds the recurring word" "$OUT" "facturation"

  # An accented word must fold to one ASCII token, not be split in half by the strip.
  # `cassée` came out as `cass` and `détaillée` as `taill` -- fragments nobody typed,
  # printed as candidate entry names, identically under both engines.
  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$MISSES" --log "$ACCENT" --min 1 2>&1) && ST=0 || ST=$?
  assert_token_row "[$eng] an accented word folds whole" "$OUT" "cassee"
  assert_token_row "[$eng] and so does a doubly accented one" "$OUT" "detaillee"
  assert_no_token_row "[$eng] no fragment before the accent" "$OUT" "cass"
  assert_no_token_row "[$eng] no fragment after it either" "$OUT" "taill"

  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$MISSES" --log "$NOPROMPT" 2>&1) && ST=0 || ST=$?
  assert_status "[$eng] no prompt records is still exit 2" "$ST" "2"
  assert_contains "[$eng] SKIPPED" "$OUT" "SKIPPED"
done
rm -rf "$ENGINE_BIN"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
