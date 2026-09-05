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

# jit-drive: assert_contains contains capture
# jit-drive: assert_not_contains not_contains capture
# jit-drive: assert_token_row token_row capture
# jit-drive: assert_no_token_row no_token_row capture
assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF -- "$unexpected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: $(echo "$output" | cut -c1-400)"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

# A token row is `  2x  token`. Substring matching cannot express its absence -- the
# example prompts printed under a row contain the fragments themselves, so `taill` is in
# the output either way. The claim is about the ROW, so match the whole line.
assert_no_token_row() {
  local desc="$1" output="$2" token="$3"
  if grep -qE "^ +[0-9]+x  $token\$" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should have no row for token: $token"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

assert_token_row() {
  local desc="$1" output="$2" token="$3"
  if grep -qE "^ +[0-9]+x  $token\$" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected a row for token: $token"
    echo "    got: $(echo "$output" | cut -c1-400)"
  fi
}

assert_status() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (exit $actual, expected $expected)"
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
cat > "$A" << 'LOG'
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
cat > "$FOREIGN" << 'LOG'
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
cat > "$NOPROMPT" << 'LOG'
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
cat > "$CLEAN" << 'LOG'
[10:00:00.001] pre-prompt 9ms | 00-manual:jit-context.md(rebuild-tsv) [shown:1] << how does rebuild-tsv build the index
[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << who owns the deployment calendar
LOG
OUT=$(bash "$MISSES" --log "$CLEAN" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 -- read fine, found nothing" "$ST" "0"
assert_contains "says ok" "$OUT" "ok --"
assert_not_contains "and is not confused with a skip" "$OUT" "SKIPPED"
assert_contains "while still reporting what it read" "$OUT" "2 prompt record(s)"

# =============================================
# SECTION: a pasted link is not three vocabulary gaps (#69)
# =============================================
# `https://github.com/org/repo/pull/54` tokenised into `https`, `github`, `com`, `pull`
# and the org and repo names, and three pastes of the same link put all six ABOVE the
# words people had actually typed. None of them was ever a word in the prompt.
#
# The rule is `://` and nothing else, so the two shapes that look like it must survive:
# a path (`src/Billing/Totals.php`) and a dotted filename (`common.sh`). A rule that ate
# either would be a worse bug than the one it fixes.
URLS="$TMP/urls.log"
cat > "$URLS" << 'LOG'
[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << the changelog at https://github.com/digital-process-tools/claude-jit-context/pull/54
[10:00:02.001] pre-prompt 9ms | (none) [shown:1] << changelog, see https://github.com/digital-process-tools/claude-jit-context/pull/55
[10:00:03.001] pre-prompt 9ms | (none) [shown:1] << the totals in src/Billing/Totals.php are wrong
[10:00:04.001] pre-prompt 9ms | (none) [shown:1] << recompute src/Billing/Totals.php totals
[10:00:05.001] pre-prompt 9ms | (none) [shown:1] << where is the fold table in common.sh
[10:00:06.001] pre-prompt 9ms | (none) [shown:1] << common.sh sets every path
LOG

if [ ! -s "$URLS" ]; then
  echo "  FAIL: harness guard -- the URL fixture is empty, every silence assertion below is vacuous"
  exit 1
fi

echo ""
echo "=== a pasted URL contributes no tokens, and the words around it still do ==="
OUT=$(bash "$MISSES" --log "$URLS" 2>&1) && ST=0 || ST=$?
assert_status "exit 0 -- findings" "$ST" "0"
assert_contains "read the whole fixture" "$OUT" "6 prompt record(s)"
# Positive control FIRST: an "absent" assertion passes when the tokeniser returns
# nothing at all, so pin what must still be reported before pinning what must not.
assert_token_row "the word typed beside the link is still a miss" "$OUT" "changelog"
assert_token_row "a path is not a URL -- the directory survives" "$OUT" "billing"
assert_token_row "and so does the file name" "$OUT" "totals"
assert_token_row "a dotted file name is not a host name" "$OUT" "common"
assert_no_token_row "the scheme was never a word someone typed" "$OUT" "https"
assert_no_token_row "nor was the TLD" "$OUT" "com"
assert_no_token_row "nor the host" "$OUT" "github"
assert_no_token_row "nor a path segment of the URL" "$OUT" "pull"
assert_no_token_row "nor the org in it" "$OUT" "digital-process-tools"
assert_no_token_row "nor the repo in it" "$OUT" "claude-jit-context"
assert_contains "and it says how many links it dropped" "$OUT" "2 link(s) stripped"

# The header says `link(s)`, so it must count LINKS. Counting records instead is a number
# that reads as a link count and halves on the prompt that pastes two.
MULTI="$TMP/multilink.log"
cat > "$MULTI" << 'LOG'
[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << compare https://acme.example.com/one with https://acme.example.com/two
[10:00:02.001] pre-prompt 9ms | (none) [shown:1] << compare https://acme.example.com/three with https://acme.example.com/four
LOG
OUT=$(bash "$MISSES" --log "$MULTI" --min 1 2>&1) && ST=0 || ST=$?
assert_status "two links in each of two prompts, exit 0" "$ST" "0"
assert_contains "counts links, not records" "$OUT" "4 link(s) stripped"
assert_token_row "and the word around them still counts once each" "$OUT" "compare"

# --- the 80-character cut, and whether it landed inside the link -------------
# The hook logs substr(msg, 1, 80), so a record can end mid-word, and the last token is
# dropped because a fragment can never recur as a real word. If the cut landed inside a
# LINK, that fragment leaves with the link, and dropping a further token then discards a
# whole word nobody truncated. Both messages are built and measured here rather than
# pasted: "exactly 80" is the entire claim, and an off-by-one typed into a heredoc would
# make every assertion below about an untruncated record.
TRUNC_URL="reconcile the omega ledger zebra https://acme.example.com/api/v2/ledger/entries/2026"
TRUNC_URL="${TRUNC_URL:0:80}"
# No word is shared with the record above: `zebra` must owe its row to the truncated-link
# record alone, or the assertion passes on the other record and proves nothing.
TRUNC_WORD_FULL="settlement batch quarterly closingstatementreconciliationprocedureaddendumextension"
TRUNC_WORD="${TRUNC_WORD_FULL:0:80}"
TRUNC_FRAG="${TRUNC_WORD##* }"

if [ "${#TRUNC_URL}" -ne 80 ] || [ "${#TRUNC_WORD}" -ne 80 ] \
  || [ "${TRUNC_URL#*://}" = "$TRUNC_URL" ] \
  || [ "$TRUNC_FRAG" = "${TRUNC_WORD_FULL##* }" ] || [ "${#TRUNC_FRAG}" -lt 3 ]; then
  echo "  FAIL: harness guard -- the truncation fixtures are not the shape they claim"
  echo "    url record: ${#TRUNC_URL} chars, word record: ${#TRUNC_WORD} chars, fragment: $TRUNC_FRAG"
  exit 1
fi

TRUNCLOG="$TMP/trunc.log"
{
  printf '[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << %s\n' "$TRUNC_URL"
  printf '[10:00:02.001] pre-prompt 9ms | (none) [shown:1] << %s\n' "$TRUNC_WORD"
} > "$TRUNCLOG"

echo ""
echo "=== a cut that landed inside the link does not also cost the word before it ==="
OUT=$(bash "$MISSES" --log "$TRUNCLOG" --min 1 2>&1) && ST=0 || ST=$?
assert_status "exit 0" "$ST" "0"
assert_contains "read both records" "$OUT" "2 prompt record(s)"
assert_token_row "the last real word before the link survives the cut" "$OUT" "zebra"
# The other direction, and the control that the truncation rule is still live at all:
# when the cut lands in ordinary text the fragment must still go.
assert_token_row "a record cut mid-word still yields its earlier words" "$OUT" "quarterly"
assert_no_token_row "and never the fragment the cut made" "$OUT" "$TRUNC_FRAG"

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
cat > "$MCP" << 'LOG'
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
# the log directory at load -- since #51 only where `.claude/jit-context/` already exists,
# which is every tree this tool is pointed at -- and a reporting tool must not create what
# it reports on). The `reading created no .claude tree` assertion below is about THIS
# script and holds either way: it never sourced common.sh, so it never created anything.
OUT=$(cd "$WDIR" && CLAUDE_PROJECT_DIR="$WDIR" bash "$MISSES" 2>&1) && ST=0 || ST=$?
assert_status "no log under CLAUDE_PROJECT_DIR is exit 2" "$ST" "2"
assert_contains "and it names the path it derived" "$OUT" ".claude/jit-context/.discovery/logs/hooks.log"
AFTER=$(find "$WDIR" | sort)
assert_not_contains "reading created no .claude tree" "$AFTER" ".claude"
COUNT=$(printf '%s\n' "$AFTER" | grep -c . || true)
assert_status "the working dir still holds exactly one entry (itself)" "$COUNT" "1"

# =============================================
# SECTION: the fold table is duplicated, so assert it has not drifted
# =============================================
# jit-misses.sh deliberately does not source common.sh (its header says why, and says what
# #51 changed about it: common.sh mkdir -p's the log directory at load, now only where the
# tree already exists, and a reporting tool must not create the thing it reports). So the
# Latin-1 fold table exists twice. Drift is not a cosmetic problem: the
# index writer folds a keyword with common.sh's copy, and a letter present in one table
# and missing from the other is a keyword that indexes one way and is reported another.
# Compared as a character sequence, because the two copies are indented differently.
fold_table() {
  # Anchored on the first table entry, written as the two UTF-8 bytes of `á`: perl reads
  # this file as bytes, and an unanchored .*? starts at the FIRST split() in the file --
  # the stop-word list -- and reports that as the fold table.
  perl -0777 -ne 'if (/split\(("\xc3\xa1 .*?),\s*(?:tr|_jit_fold_tr),\s*"\[ \]"\)/s) {
      $t = $1; $t =~ s/\\\n\s*//g; $t =~ s/"//g; $t =~ s/\s+/ /g; $t =~ s/^ | $//g;
      print $t;
    }' "$1"
}
T_MISSES=$(fold_table "$MISSES")
T_COMMON=$(fold_table "$SCRIPT_DIR/scripts/common.sh")
# Positive control. Without it a regex that stops matching either file reports the two
# empty strings as equal -- a green that means the assertion no longer reads anything.
if [ -z "$T_MISSES" ] || [ -z "$T_COMMON" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: could not read a fold table out of both files -- the assertion is vacuous"
  echo "    jit-misses.sh: ${#T_MISSES} chars, common.sh: ${#T_COMMON} chars"
elif [ "$T_MISSES" = "$T_COMMON" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: the two copies of the fold table agree"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: the two copies of the fold table have drifted"
  echo "    jit-misses.sh: $T_MISSES"
  echo "    common.sh:     $T_COMMON"
fi

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
  cand_path=$(command -v "$cand" 2> /dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

# The caller locale for the byte-split assertion below. `C` is where that bug does not
# reproduce, so a suite that inherited `C` would assert nothing; this picks a UTF-8 locale
# when the machine has one and says which it got. See tests/test-pre-prompt-hook.sh.
pick_utf8_locale() {
  local c
  for c in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if [ "$(LC_ALL="$c" locale charmap 2> /dev/null)" = "UTF-8" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  printf '%s' "${LC_ALL:-${LANG:-C}}"
}
UTF8_LOCALE="$(pick_utf8_locale)"
# Whether what came back is ACTUALLY a UTF-8 locale. On a runner with no `locale` command
# or no UTF-8 locale installed -- Git Bash is the case in mind -- the fallback is the
# caller own, which is normally `C`, and `C` is precisely where the bug does not reproduce.
# The assertions below would then still pass, and pass for the wrong reason: they could not
# tell the fix from its absence. Said out loud rather than gone quietly green, on the
# pattern section A of tests/test-hook-tmpfile.sh already uses for symbolic links.
UTF8_LOCALE_REAL=no
if [ "$(LC_ALL="$UTF8_LOCALE" locale charmap 2> /dev/null)" = "UTF-8" ]; then UTF8_LOCALE_REAL=yes; fi
if [ "$UTF8_LOCALE_REAL" != yes ]; then
  echo "  SKIP-NOTE: no UTF-8 locale on this machine ($UTF8_LOCALE). The malformed-byte"
  echo "             assertions below run under a byte locale, where the defect does not"
  echo "             reproduce -- they still assert the guarantee, they just cannot fail"
  echo "             for it here."
  if [ "${JIT_TESTS_REQUIRE_UTF8_LOCALE:-}" = 1 ]; then
    FAIL=$((FAIL + 1))
    echo ""
    echo "  FAIL: A UTF-8 LOCALE WAS REQUIRED AND NOT OBTAINED."
    echo "        JIT_TESTS_REQUIRE_UTF8_LOCALE=1 says this environment was configured to"
    echo "        have one, so the note above is a broken configuration and not a platform"
    echo "        without the capability. Failed rather than noted because run-all.sh"
    echo "        renders a note green. Nothing here is a defect in the hooks."
  fi
fi
echo "caller locale for the byte-split assertion: $UTF8_LOCALE"

# An accented prompt is the fixture that broke the prompt hook itself under one-true-awk.
ACCENT="$TMP/accent.log"
cat > "$ACCENT" << 'LOG'
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

  # The URL strip splits the message on whitespace, and split() is the one function the
  # two awks have already disagreed about in this file. Drive it on both.
  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$MISSES" --log "$URLS" 2>&1) && ST=0 || ST=$?
  assert_status "[$eng] a log full of links still reports, exit 0" "$ST" "0"
  assert_token_row "[$eng] the word beside the link survives" "$OUT" "changelog"
  assert_token_row "[$eng] and the path is not eaten" "$OUT" "billing"
  assert_no_token_row "[$eng] and the scheme is gone" "$OUT" "https"

  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" bash "$MISSES" --log "$NOPROMPT" 2>&1) && ST=0 || ST=$?
  assert_status "[$eng] no prompt records is still exit 2" "$ST" "2"
  assert_contains "[$eng] SKIPPED" "$OUT" "SKIPPED"

  # A log line this tool did not write is one thing; a log line the HOOK wrote is another.
  # pre-prompt-hook.sh truncates the prompt copy at 80 BYTES, so an ordinary CJK or heavily
  # accented prompt puts a half-finished UTF-8 sequence at the end of the line -- no
  # attacker, no malformed input, just a multibyte character straddling the cut. Reading
  # that back aborted this tool with `illegal byte sequence` under one-true-awk and made
  # gawk warn, which is #68 one hop downstream: the reader has to be as byte-oriented as
  # the writer. The fixture is the exact byte sequence the hook produces -- 26 copies of
  # U+65E5 is 78 bytes, so the 80-byte cut lands two bytes into the 27th.
  SPLITLOG="$TMP/split-utf8.log"
  {
    printf '[10:00:01.001] pre-prompt 9ms | (none) [shown:1] << '
    perl -e 'print "\346\227\245" x 26; print "\346\227"'
    printf ' zorkmiss\n'
    printf '[10:00:02.001] pre-prompt 9ms | (none) [shown:1] << zorkmiss again\n'
  } > "$SPLITLOG"
  OUT=$(PATH="$ENGINE_BIN/$eng:$PATH" LC_ALL="$UTF8_LOCALE" bash "$MISSES" --log "$SPLITLOG" --min 2 2>&1) && ST=0 || ST=$?
  assert_status "[$eng] a byte-split UTF-8 log line still reports, exit 0" "$ST" "0"
  # The positive control, in the same call: "no error appeared" is also true of a tool that
  # aborted before reading anything, which is exactly the failure being pinned.
  assert_token_row "[$eng] and the ASCII token beside the split sequence is still counted" "$OUT" "zorkmiss"
  assert_not_contains "[$eng] and nothing about a byte sequence is printed" "$OUT" "illegal byte sequence"
  assert_not_contains "[$eng] nor a multibyte warning" "$OUT" "multibyte"
done
rm -rf "$ENGINE_BIN"

# --- #125: a refusal is not a finding, and stdout is the report -------------------------
# paths/00-manual/tooling.md states the contract these five tools live under: a tool that
# cannot do its job says so on STDERR, with a non-zero status. This one had the status
# right and the stream wrong.
#
# It matters for exactly one reason, and it is this repository defect shape in miniature:
# stdout IS the report. `bash scripts/jit-misses.sh > misses.txt` captured
# "jit-misses: SKIPPED -- not readable" into the findings file, where it reads as a
# finding -- the tool reporting an absence it produced itself.
#
# Driven in both directions and from FILES, never $( ): the refusal reaches stderr AND is
# absent from the redirected report, and an ordinary run report still lands on stdout.
# Reading stdout and stderr out of one `2>&1` capture, which is what every assertion above
# this line does, cannot tell the two streams apart at all.

# jit-drive: assert_file_has contains path-arg
# jit-drive: assert_file_lacks not_contains path-arg
assert_file_has() {
  local desc="$1" path="$2" needle="$3"
  if grep -qF -- "$needle" "$path"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $needle"
    echo "    in file: $path"
  fi
}

assert_file_lacks() {
  local desc="$1" path="$2" needle="$3"
  if grep -qF -- "$needle" "$path"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $needle"
    echo "    in file: $path"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

echo ""
echo "=== refusals go to stderr, the report keeps stdout (#125) ==="

R_OUT="$TMP/refusal.out"
R_ERR="$TMP/refusal.err"

# A file with lines but no record this tool recognises: the refusal built inside the awk
# END block, which is a different set of print statements from the bash half above it.
NORECORDS="$TMP/no-records.log"
printf 'this file has lines but none of them is a hook record\n' > "$NORECORDS"

# The awk END block carries three refusals, not one, and they are three separate sets of
# print statements. This is the second reachable one: well-formed hook records, none of
# them from pre-prompt. (The third, `lines == 0`, cannot be reached through the CLI --
# `[ -s "$LOG" ]` refuses an empty file in bash first -- so driving it here would assert
# nothing.)
NOPROMPTS="$TMP/no-prompt-records.log"
printf '[10:00:01.001] pre-tool (Bash) 9ms | (none) [shown:0] << git status\n' > "$NOPROMPTS"

# One case per refusal SHAPE in the script, because they are independent sets of writes
# and a fix applied to four of them looks identical to a fix applied to all six.
#   --min with no value        need_value()
#   --zzz                      the unknown-argument arm
#   --min x                    the whole-number guard
#   --log /nonexistent         skip()
#   --log <no records>         the awk END block, shaped == 0
#   --log <no pre-prompt>      the awk END block, prompts == 0
for c in "--min:" "--zzz:" "--min:x" "--log:/nonexistent/hooks.log" "--log:$NORECORDS" \
  "--log:$NOPROMPTS"; do
  cflag="${c%%:*}"
  cval="${c#*:}"
  if [ -n "$cval" ]; then set -- "$cflag" "$cval"; else set -- "$cflag"; fi
  bash "$MISSES" "$@" > "$R_OUT" 2> "$R_ERR" && ST=0 || ST=$?
  assert_status "[$cflag ${cval:-<none>}] a refusal still exits 2" "$ST" "2"
  assert_file_has "[$cflag ${cval:-<none>}] the refusal reaches stderr" "$R_ERR" "SKIPPED"
  assert_file_lacks "[$cflag ${cval:-<none>}] and never the redirected report" "$R_OUT" "SKIPPED"
  # Not just the SKIPPED word: the reason and the log path travel on their own lines, and
  # a fix that redirected the first line only would pass the two assertions above.
  assert_file_lacks "[$cflag ${cval:-<none>}] the whole refusal, not its first line" "$R_OUT" "jit-misses:"
done

# The other direction, and it is the half that fails if a fix redirected EVERYTHING: an
# ordinary run still writes its findings to stdout and says nothing on stderr.
OK_OUT="$TMP/ok.out"
OK_ERR="$TMP/ok.err"
bash "$MISSES" --log "$A" > "$OK_OUT" 2> "$OK_ERR" && ST=0 || ST=$?
assert_status "an ordinary run still exits 0" "$ST" "0"
assert_file_has "and its report is on stdout" "$OK_OUT" "jit-misses:"
assert_file_has "with the finding still in it" "$OK_OUT" "xsd"
if [ -s "$OK_ERR" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: an ordinary run writes nothing to stderr"
  echo "    stderr held: $(head -c 200 "$OK_ERR")"
else
  PASS=$((PASS + 1))
  echo "  PASS: an ordinary run writes nothing to stderr"
fi

# --help is not a refusal. It is what the reader ASKED for, so it keeps stdout -- a fix
# that moved every non-finding to stderr would break `jit-misses.sh --help | less`.
H_OUT="$TMP/help.out"
H_ERR="$TMP/help.err"
bash "$MISSES" --help > "$H_OUT" 2> "$H_ERR" && ST=0 || ST=$?
assert_status "--help still exits 0" "$ST" "0"
assert_file_has "--help is a report the reader asked for, so it keeps stdout" "$H_OUT" "the vocabulary this project keeps not having"
if [ -s "$H_ERR" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: --help writes nothing to stderr"
else
  PASS=$((PASS + 1))
  echo "  PASS: --help writes nothing to stderr"
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
