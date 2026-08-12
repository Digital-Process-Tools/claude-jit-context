#!/bin/bash
# claude-jit-context -- report the vocabulary this project keeps not having.
#
# pre-prompt-hook.sh already logs every prompt with the entries it matched, or the literal
# `(none)`. A `(none)` that repeats on the same words is a measured record of what the team
# keeps not knowing -- demand, not guesswork, and it costs nothing to collect because it is
# already collected.
#
# This script READS and PRINTS. It writes no file, creates no entry, fires no hook and makes
# no network call. That is why it does NOT source common.sh: common.sh mkdir -p's the log
# directory at load, and a reporting tool that creates the thing it reports is a tool whose
# own output cannot be trusted.
#
# Three outcomes, never two. An empty report that means "no repeated misses" and "the log
# was not readable" identically is this repository own defect class, shipped inside the
# tool that reports it:
#
#   findings   -- a ranked list, exit 0
#   ok         -- the log was read, nothing recurs, exit 0
#   SKIPPED    -- named reason, exit 2
#
# Usage: bash scripts/jit-misses.sh [--log PATH] [--min N] [--top N]

LOG=""
MIN=2
TOP=20

usage() {
  cat <<'EOF'
jit-misses.sh -- the vocabulary this project keeps not having

  bash scripts/jit-misses.sh [--log PATH] [--min N] [--top N]

  --log PATH   hook log to read. Default: $CLAUDE_PROJECT_DIR/.claude/jit-context/
               .discovery/logs/hooks.log (CLAUDE_PROJECT_DIR defaults to .)
  --min N      report a token shared by at least N misses. Default 2.
  --top N      print at most N tokens. Default 20.
  --help       this text.

What counts as the same miss

  Two prompts are the SAME MISS when they share a content word -- a token of three or
  more characters that is not a stopword -- after the same lowercase-and-strip
  normalisation the prompt hook applies to a prompt before it looks a keyword up.

  So "xsd validation" and "validate the xsd" are one miss, on "xsd". "validation" and
  "validate" are NOT, because nothing here stems: no similarity metric, no threshold to
  tune, and no way for two prompts to merge on a resemblance you cannot see. Every miss
  that produced a row is printed under it, so you can always read why they grouped and
  disagree with the grouping.

  Set aside before grouping, and counted in the header rather than dropped in silence:
  a prompt that begins with / (a slash command is an instruction to the harness, not a
  question about the codebase) and one that begins with < (a harness-generated block).

  Only pre-prompt records are read. The tool and path dimensions produce far more
  (none) rows than the prompt hook does -- on the machine this was designed against,
  1,217 of 1,242 -- and none of them is a vocabulary gap.

Outcomes

  findings, exit 0   a ranked list
  ok, exit 0         the log was read and nothing recurs
  SKIPPED, exit 2    the log could not be evaluated -- the reason is named

  It reads and prints. It writes nothing and creates no entry: it tells you what to
  write, and an entry still has an author.
EOF
}

# A flag whose value is missing needs the same loud refusal as an unknown flag. The first
# draft left `shift 2` to fail on its own, which exits 2 having printed NOTHING -- three
# outcomes collapsed back into two, in the script written to keep them apart.
need_value() {
  echo "jit-misses: SKIPPED -- $1 needs a value"
  echo "  run with --help for the accepted flags"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --log)  [ $# -ge 2 ] || need_value "$1"; LOG="$2"; shift 2 ;;
    --min)  [ $# -ge 2 ] || need_value "$1"; MIN="$2"; shift 2 ;;
    --top)  [ $# -ge 2 ] || need_value "$1"; TOP="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      # An unknown flag is refused rather than ignored. A silently dropped --min reads as
      # a threshold that applied, which is the failure this whole script is written about.
      echo "jit-misses: SKIPPED -- unknown argument: $1"
      echo "  run with --help for the accepted flags"
      exit 2
      ;;
  esac
done

case "$MIN" in ""|*[!0-9]*) echo "jit-misses: SKIPPED -- --min takes a whole number"; exit 2 ;; esac
case "$TOP" in ""|*[!0-9]*) echo "jit-misses: SKIPPED -- --top takes a whole number"; exit 2 ;; esac
[ "$MIN" -ge 1 ] || MIN=1
[ "$TOP" -ge 1 ] || TOP=1

if [ -z "$LOG" ]; then
  LOG="${CLAUDE_PROJECT_DIR:-.}/.claude/jit-context/.discovery/logs/hooks.log"
fi

skip() {
  echo "jit-misses: SKIPPED -- $1"
  echo "  log: $LOG"
  exit 2
}

[ -e "$LOG" ] || skip "no such file -- the hooks have never run here, or the log lives elsewhere (--log PATH)"
[ -f "$LOG" ] || skip "not a regular file"
[ -r "$LOG" ] || skip "not readable"
[ -s "$LOG" ] || skip "the file is empty -- the hooks have logged nothing yet"

awk -v min="$MIN" -v top="$TOP" -v logfile="$LOG" '
BEGIN {
  # Filler that two prompts can share without sharing a subject. Deliberately short and
  # visible: it is the only part of the grouping rule that is a matter of taste, and a
  # word missing from here costs a noisy row, never a silent one.
  split("the and for are you your our their his her its not but with without that this " \
        "these those what when where which who whom whose how why can could shall should " \
        "would will does did done have has had was were been being from into onto out off " \
        "over under about after before again more most less least some any all every each " \
        "other another same such than then there here just only also still yet now new old " \
        "make made makes get gets got use used uses using need needs want wants know knows " \
        "think thinks say says tell tells look looks see sees show shows give gives take " \
        "please thanks thank hey hello yes yeah nope sure okay let lets like " \
        "something anything nothing everything someone anyone thing things stuff " \
        "run runs ran add adds added fix fixes fixed check checks checked " \
        "one two three four five six seven eight nine ten", sw, " ")
  for (i in sw) stop[sw[i]] = 1

  # Latin-1 letters fold to their ASCII base BEFORE the strip below. Without this,
  # `cassee` came out of `cassée` as the token `cass` and `detaillee` out of `détaillée`
  # as `taill` -- the accent is replaced by a space, so one word becomes two fragments
  # nobody typed, offered as a candidate entry name. Measured under both awks, so it is
  # not an engine quirk: the character class is ASCII either way.
  #
  # Split on "[ ]" and not " ": one-true-awk splits a one-character separator on newlines
  # too, gawk does not, and this list has to mean the same thing on both.
  ntr = split("á a à a â a ä a ã a å a æ ae ç c é e è e ê e ë e í i ì i î i ï i ñ n " \
              "ó o ò o ô o ö o õ o œ oe ß ss ú u ù u û u ü u ý y ÿ y " \
              "Á a À a Â a Ä a Ã a Å a Æ ae Ç c É e È e Ê e Ë e Í i Ì i Î i Ï i Ñ n " \
              "Ó o Ò o Ô o Ö o Õ o Œ oe Ú u Ù u Û u Ü u Ý y", tr, "[ ]")
}

{
  lines++

  # A hook record, from any hook. Anchored: an unanchored test would fire on a record whose
  # MESSAGE quotes a log line, and the point of this pass is to tell a log we can read from
  # one we cannot.
  #
  # The tool name in the parentheses is whatever the payload called the tool, unsanitised
  # -- pre-tool-hook.sh logs `pre-tool ($AWK_TOOL)` straight from tool_name, and an MCP tool
  # is `mcp__server__thing`. Matching only [A-Za-z]+ there made a log full of MCP calls
  # report "no line has the hook log format" instead of "no pre-prompt records": the right
  # verdict for the wrong reason, from the script whose whole job is telling those apart.
  if ($0 !~ /^\[[^]]*\] [a-z][a-z-]*( \([^)]*\))? [0-9]+ms \| /) next
  shaped++

  if (match($0, /^\[[^]]*\] pre-prompt [0-9]+ms \| /) == 0) next
  prompts++
  rest = substr($0, RLENGTH + 1)

  if (index(rest, "(none) [shown:") != 1) next
  misses++

  p = index(rest, " << ")
  if (p == 0) { headless++; next }
  msg = substr(rest, p + 4)
  if (msg == "") { headless++; next }

  # A slash command is an instruction to the harness and a <...> block is harness-generated
  # text. Neither is someone asking about the codebase. Counted, never silently dropped.
  first = substr(msg, 1, 1)
  if (first == "/" || first == "<") { aside++; next }
  considered++

  # The hook logs substr(msg, 1, 80), so an 80-character record may end mid-word. That
  # partial token would be its own miss forever -- it can never recur as a real word.
  truncated = (length(msg) == 80)

  norm = tolower(msg)
  # tolower() leaves a multibyte capital alone on one-true-awk, so the table carries both
  # cases and runs after it. gsub takes its pattern as a string here; every entry is a
  # plain letter, so there is no regex metacharacter to escape.
  for (i = 1; i + 1 <= ntr; i += 2) if (index(norm, tr[i]) > 0) gsub(tr[i], tr[i+1], norm)
  gsub(/[^a-z0-9 -]/, " ", norm)
  gsub(/  +/, " ", norm)
  sub(/^ /, "", norm); sub(/ $/, "", norm)

  n = split(norm, tok, " ")
  if (truncated && n > 1) n--

  delete seen
  for (i = 1; i <= n; i++) {
    t = tok[i]
    gsub(/^-+/, "", t); gsub(/-+$/, "", t)
    if (length(t) < 3) continue
    if (t ~ /^[0-9-]+$/) continue
    if (t in stop) continue
    if (t in seen) continue
    seen[t] = 1
    cnt[t]++
    if (exn[t] < 5) { exn[t]++; ex[t, exn[t]] = msg }
  }
}

END {
  if (lines == 0) {
    print "jit-misses: SKIPPED -- the file is empty"
    print "  log: " logfile
    exit 2
  }
  if (shaped == 0) {
    print "jit-misses: SKIPPED -- no line in this file has the hook log format"
    print "  log: " logfile
    print "  expected records like: [23:48:14.393] pre-prompt 9ms | (none) [shown:1] << ..."
    print "  " lines " line(s) read, 0 recognised. Either this is not the log this script"
    print "  reads, or the format changed and this script did not."
    exit 2
  }
  if (prompts == 0) {
    print "jit-misses: SKIPPED -- " shaped " hook record(s), none of them from pre-prompt"
    print "  log: " logfile
    print "  The tool and path hooks log misses too, and none of those is a vocabulary gap."
    print "  A prompt miss can only come from a pre-prompt record, and this log has none."
    exit 2
  }

  printf "jit-misses: %s\n", logfile
  printf "  %d line(s), %d prompt record(s), %d with no vocabulary match", lines, prompts, misses
  if (aside > 0) printf ", %d set aside (slash command or harness block)", aside
  if (headless > 0) printf ", %d with no message", headless
  printf "\n"

  # Rank: count desc, then token asc, so two runs over the same log print the same order.
  nk = 0
  for (t in cnt) if (cnt[t] >= min) { nk++; keys[nk] = t }
  for (i = 2; i <= nk; i++) {
    k = keys[i]; j = i - 1
    while (j >= 1 && (cnt[keys[j]] < cnt[k] || (cnt[keys[j]] == cnt[k] && keys[j] > k))) {
      keys[j+1] = keys[j]; j--
    }
    keys[j+1] = k
  }

  if (nk == 0) {
    printf "  ok -- no token is shared by %d or more of them; nothing here is a repeated gap\n", min
    if (considered == 0 && misses > 0)
      print "  (every miss was a slash command or a harness block, so none was grouped)"
    exit 0
  }

  printf "\n  recurring misses -- prompts sharing a content word, most-missed first:\n\n"
  shown = 0
  for (i = 1; i <= nk && shown < top; i++) {
    t = keys[i]
    printf "  %dx  %s\n", cnt[t], t
    for (j = 1; j <= exn[t]; j++) printf "        %s\n", ex[t, j]
    if (cnt[t] > exn[t]) printf "        ... and %d more\n", cnt[t] - exn[t]
    print ""
    shown++
  }
  if (nk > shown) printf "  ... and %d more token(s) below the cut (--top %d)\n", nk - shown, top
  print "  Each block is one candidate vocabulary entry, written by a person:"
  print "  .claude/jit-context/vocabulary/00-manual/<name>.md, then bash scripts/rebuild-tsv.sh"
  exit 0
}
' "$LOG"
