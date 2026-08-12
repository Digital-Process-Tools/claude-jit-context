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
# Since #51 that mkdir is gated on `.claude/jit-context/` already existing, so it no longer
# materialises a tree in a project that has none -- but it still creates `.discovery/logs/`
# in every project that HAS one, which is every project this tool is ever pointed at. The
# reason to keep the `source` line out is unchanged; only the size of what it would create
# is smaller. Do not "fix" the missing source.
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

  A pasted link is removed whole before tokenising -- any run of non-space characters
  containing :// -- and counted in the header. https://github.com/acme/thing/pull/54
  is not the words `https`, `github`, `com` and `pull`; none of them was typed. Only
  the scheme does this. A path (src/Billing/Totals.php) and a dotted file name
  (common.sh) are ordinary tokens and still count, because a host name cannot be told
  from a file name by shape -- only by a list of TLDs, and this tool keeps no lists.

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

# LC_ALL=C, for the same reason the three hooks pin it (#68) and one that is specific to
# this tool: the file it reads is one THE HOOKS WROTE, and they truncate the prompt copy at
# 80 bytes. An ordinary CJK or heavily accented prompt therefore leaves a half-finished
# UTF-8 sequence at the end of a log line -- no attacker, no malformed input, just a
# multibyte character straddling the cut. Reading that back aborted this awk with
# `illegal byte sequence` under one-true-awk and made gawk print a multibyte warning, so
# the reporting tool went dark on exactly the corpora the accent fold exists for.
#
# This tool may fail loudly, and it still does -- on a log it cannot read, with a named
# SKIPPED reason and exit 2. Choking on bytes it wrote itself is not that.
#
# The fold table below is the byte-identical copy of the one in common.sh, built out of
# index() and substr() with no decode and carrying both cases, so `C` costs it nothing --
# tests/test-jit-misses.sh drives the accented fixture under both engines.
LC_ALL=C awk -v min="$MIN" -v top="$TOP" -v logfile="$LOG" '
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

}

# A byte-identical copy of jit_fold_latin1() and its table from common.sh, which this
# script deliberately does not source -- see the header. The hooks and rebuild-tsv.sh use
# the common.sh copy, and a letter in one table but not the other is a keyword indexed one
# way and reported another, so tests/test-jit-misses.sh compares the two rather than
# trusting them.
#
# Latin-1 letters fold to their ASCII base BEFORE the strip below. Without this, `cassee`
# came out of `cassée` as the token `cass` and `detaillee` out of `détaillée` as `taill`
# -- the accent is replaced by a space, so one word becomes two fragments nobody typed,
# offered as a candidate entry name. Measured under both awks: the character class is
# ASCII either way.
#
# index()/substr() and not gsub(): gsub() with a multibyte character as its pattern
# decodes the subject, and this script reads an 80-character log excerpt that may end
# mid-character. Split on "[ ]" and not " ": one-true-awk splits a one-character
# separator on newlines too, gawk does not, and this list has to mean the same on both.
function jit_fold_latin1(s,   i, p, out) {
  if (_jit_fold_n == 0)
    _jit_fold_n = split("á a à a â a ä a ã a å a æ ae ç c é e è e ê e ë e í i ì i î i ï i ñ n " \
                        "ó o ò o ô o ö o õ o œ oe ß ss ú u ù u û u ü u ý y ÿ y " \
                        "Á a À a Â a Ä a Ã a Å a Æ ae Ç c É e È e Ê e Ë e Í i Ì i Î i Ï i Ñ n " \
                        "Ó o Ò o Ô o Ö o Õ o Œ oe Ú u Ù u Û u Ü u Ý y", _jit_fold_tr, "[ ]")
  for (i = 1; i + 1 <= _jit_fold_n; i += 2) {
    out = ""
    while ((p = index(s, _jit_fold_tr[i])) > 0) {
      out = out substr(s, 1, p - 1) _jit_fold_tr[i+1]
      s = substr(s, p + length(_jit_fold_tr[i]))
    }
    s = out s
  }
  return s
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

  # A pasted link is a machine address, not prose. Left in, `https://github.com/org/
  # repo/pull/54` becomes the tokens `https`, `github`, `com`, `pull`, `org` and `repo`,
  # and three pastes of the SAME link outrank every word a person actually typed, so the
  # headline advice becomes "write vocabulary/00-manual/com.md". None of those was ever
  # a word in the prompt, which is why this is a tokeniser rule and not a stop-list: a
  # stop-list hides `com` in this corpus and leaves `https` in whatever the next one is.
  #
  # The rule is exactly one thing: a whitespace-delimited run containing `://` is
  # dropped whole. Deliberately NOT "a dot between two alphanumerics" -- `common.sh`,
  # `tests.md` and `rebuild-tsv.sh` are that shape and are all words someone may want an
  # entry for, and `github.com` cannot be told apart from `common.sh` by structure, only
  # by a list of TLDs, which is the stop-list under another name. So a scheme-less host
  # still tokenises; a link, which is what people actually paste, does not. Paths are
  # untouched: `src/Billing/Totals.php` carries no scheme and still yields `billing` and
  # `totals`, and the paths dimension already treats a token like that as meaningful.
  #
  # Split on "[ \t]+" and not " ": a one-character separator splits on newlines under
  # one-true-awk and not under gawk, and this has to mean the same thing on both.
  np = split(msg, part, "[ \t]+")
  stripped = 0
  kept = ""
  for (u = 1; u <= np; u++) {
    if (part[u] == "") continue
    if (index(part[u], "://") > 0) { stripped++; continue }
    kept = (kept == "" ? part[u] : kept " " part[u])
  }
  urls += stripped

  # The hook logs substr(msg, 1, 80), so an 80-character record may end mid-word. That
  # partial token would be its own miss forever -- it can never recur as a real word.
  # If the run that got cut was the link, it left with the cut, and dropping a further
  # token would then discard a whole word nobody truncated.
  truncated = (length(msg) == 80 && index(part[np], "://") == 0)

  norm = tolower(kept)
  # tolower() leaves a multibyte capital alone on one-true-awk, so the table carries both
  # cases and the fold runs after it.
  norm = jit_fold_latin1(norm)
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
  # Said out loud rather than dropped in silence, on the same principle as `set aside`:
  # a prompt that was only a link now contributes no token at all, and a reader owed an
  # explanation for a miss that produced nothing should not have to read the source.
  if (urls > 0) printf ", %d link(s) stripped", urls
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
