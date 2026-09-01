#!/bin/bash
# claude-jit-context — SessionStart hook
# Clears this session "once" markers so entries fire fresh, and ages out the ones no
# session will come back for. Patterns: vocab (pre-prompt, pre-tool), path (pre-path).
#
# What this used to be, and why none of it worked:
#
#   rm -f /tmp/claude-vocab-shown-$PPID.txt
#   rm -f /tmp/claude-path-shown-$PPID.txt
#   rm -f /tmp/claude-hook-log-*.tmp
#
# The first two named the wrong file. $PPID here is whatever exec-ed this script, which is
# not the pid the pre-prompt hook will see later in the same session -- so the markers a
# session actually used were never the ones cleared, and 12,288 of them accumulated on one
# machine (#17). The third deleted the in-flight log temp of every OTHER concurrent session
# of the same user, which owns none of them: a lost log line, silently, and the log is
# where a dead rule is supposed to become visible.
#
# Now: the markers are keyed on session_id and live in the project (see common.sh), so this
# clears exactly the two files this session will use and nothing else. The wildcard is gone
# with the /tmp path it swept; a hook removes its own log temp on the way out.
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

# The payload carries session_id, and it is read with the SAME parser and the same bare-name
# check the hooks use -- jit_json_fields + jit_session_key out of common.sh. A second,
# simpler regex here would be a second answer to "what is a session id", and the two would
# drift. Guarded on a tty because a SessionStart hook always has stdin and a person running
# this by hand does not -- awk would sit there waiting.
#
# LC_ALL=C, for the same reason the other three hooks set it (#68) and one this hook lacked
# until #177: the same parser in a different locale is not the same parser, so without the
# pin the sentence above was a claim the code did not carry out.
#
# Measured at 98386f1 on a payload whose session_id carries a lone 0xE9 -- 3 engines x 2
# locales, the value jit_session_key() returned:
#
#   one-true-awk C, gawk C, mawk C, mawk en_US.UTF-8   ""  refused, which is correct
#   one-true-awk en_US.UTF-8                           ""  plus a `towc: multibyte
#                                                          conversion failure` diagnostic
#                                                          that 2>/dev/null already ate
#   gawk en_US.UTF-8                                   the id ACCEPTED, 0xE9 and all
#
# gawk in a multibyte locale does not match a lone 0xE9 against `[^A-Za-z0-9_-]`, so the
# bare-name check silently stopped being a bare-name check and an id the three matching
# hooks REFUSE was accepted here -- on gawk, which is `awk` on most Linux boxes and on
# ubuntu-latest. What that cost is bounded and worth stating rather than implying: `/` and
# `\` are single-byte and still match, so no name ever left the state directory. It cost
# AGREEMENT. The matching hooks refused the id and kept no marker; this hook built two
# marker names out of it and cleared files under names nothing had written -- and on macOS
# it could not even do that, because APFS refuses a file name that is not valid UTF-8.
#
# tests/test-session-markers.sh section J drives all three engines through a shimmed `rm`
# and fails on gawk without this pin.
#
# THE `$( )` HERE DROPS NUL BYTES, and that was measured rather than reasoned about (#177):
# it cannot cost anything, because no NUL ever reaches the capture. Driven on the same 3x2
# matrix with a NUL inside the session_id value -- one-true-awk truncates the record at the
# NUL and returns the prefix, gawk carries it through and `k ~ /[^A-Za-z0-9_-]/` matches it,
# mawk refuses it too. Every path either refuses the key or has already lost the NUL before
# `print`, in both locales. There is nothing to fix here; it is written down so the next
# reader does not have to re-measure it to find that out.
SESSION_ID=""
if [ ! -t 0 ]; then
  SESSION_ID="$(LC_ALL=C awk "$JIT_AWK_JSON"'
    { input = input $0 }
    END {
      n = jit_json_fields(input, raw, fs, fe)
      k = jit_session_key(raw, fs, fe, n)
      if (k != "") print k
    }
  ' 2>/dev/null)"
fi

if [ -n "$JIT_STATE_DIR" ]; then
  # SESSION_ID passed the same [A-Za-z0-9_-] check the hooks apply, so it is a name and not
  # a path. Two exact files, no glob: a session that resumes or is /cleared keeps its id,
  # and every other session in this project is none of our business.
  if [ -n "$SESSION_ID" ]; then
    rm -f "$JIT_STATE_DIR/vocab-shown-$SESSION_ID.txt" \
          "$JIT_STATE_DIR/path-shown-$SESSION_ID.txt" 2>/dev/null
    # A directory at one of those two names is what makes one-true-awk raise a fatal i/o
    # error on the marker READ, which the hooks cannot test for and cannot afford to sweep
    # for (see common.sh). It is O(1) here, once per session, before any hook runs. `rmdir`
    # and not `rm -rf`: this clears what got in the way, it does not delete a tree because a
    # name matched. git cannot commit an empty directory, so a directory that survives this
    # was made locally -- and is left alone rather than removed by a hook.
    rmdir "$JIT_STATE_DIR/vocab-shown-$SESSION_ID.txt" \
          "$JIT_STATE_DIR/path-shown-$SESSION_ID.txt" 2>/dev/null
  fi
  # Markers die with the tree, which bounds the leak but does not bound a long-lived
  # checkout: one pair per session, forever. So they age out here -- in a directory this
  # plugin created, matching only names this plugin writes, skipping links, and only past a
  # week, which no live session marker reaches. perl is already a dependency; `find` would
  # be a new one and its -delete is not POSIX.
  perl -e '
    my $d = shift or exit 0;
    opendir(my $h, $d) or exit 0;
    while (defined(my $e = readdir $h)) {
      next unless $e =~ /\A(?:vocab|path)-shown-[A-Za-z0-9_-]{1,64}\.txt\z/;
      my $f = "$d/$e";
      next if -l $f;
      next unless -f $f;
      unlink $f if -M $f > 7;
    }
    closedir $h;
  ' "$JIT_STATE_DIR" 2>/dev/null
fi

# #233 part 3: jit-misses.sh already reads every prompt this project has logged and
# ranks the words that keep matching nothing -- demand, measured, and collected for
# free by pre-prompt-hook.sh on every call. It just never ran on its own; a human had to
# think to invoke it. SessionStart is the one moment nothing else is competing for
# attention, which is the same argument #233 makes for the footer age above and for a
# Stop-hook summary this issue leaves to a later change.
#
# jit-misses.sh may exit 2 (SKIPPED, a reason named on stderr -- no log yet, an
# unreadable one, or one with nothing this tool recognises) or 0 with either "findings"
# or "ok". Before #247 this hook threw the exit-2 reason away with 2>/dev/null and
# branched on the exit code alone, so a log that could not be evaluated rendered as {} --
# byte-identical to "ok, nothing recurs". Silence and "nothing to say" are not the same
# (hooks.md), so now: a genuine "ok" (the log was read, nothing recurs) still stays
# quiet, and anything else that kept jit-misses.sh from reading it says so in one
# sentence, on the same surface the findings already use. A hook must never fail hard
# (see hooks.md) -- this is still exit 0 either way, just a sentence instead of nothing.
# #248: jit-misses.sh read the WHOLE unrotated log here, unbounded, on every session --
# the manual tool's own cost assumption, silently inherited by the one caller that never
# chooses the moment. --tail bounds this call to the log's most recent lines; a person
# running jit-misses.sh by hand still gets the full history, because that invocation is
# not this one. The window is named explicitly in what gets injected below, so a report
# built over the last JIT_MISSES_TAIL lines never reads as a report over the log's whole
# life -- the same three-outcomes discipline #247 already holds this hook to, one axis
# over: not just whether the log could be read, but how much of it was.
JIT_MISSES_TOP=5
JIT_MISSES_TAIL=5000
MISSES_OUT="$(bash "$SCRIPT_DIR/jit-misses.sh" --top "$JIT_MISSES_TOP" --tail "$JIT_MISSES_TAIL" 2>&1)"
MISSES_RC=$?
JIT_RECUR=""
JIT_SKIP_REASON=""
if [ "$MISSES_RC" = 0 ]; then
  # Reads jit-misses.sh recurring-miss lines back out of its human-readable report --
  # "  Nx  token" -- rather than reparsing hooks.log a second time with a second answer
  # to what counts as a repeated miss. LC_ALL=C for the same reason every other awk pass
  # in this repository is pinned to it (#68): the token already comes out of
  # jit-misses.sh restricted to [a-z0-9-], so nothing here needs to decode anything.
  #
  # index()/substr() throughout, never split() on a variable-width field: the token
  # itself may contain a literal letter x (nextjs, xterm), so splitting the line on "x"
  # would cut the wrong one. The FIRST "x" in "Nx  token" is always the count/token
  # separator, because jit-misses.sh only ever prints digits before it.
  JIT_RECUR="$(printf '%s\n' "$MISSES_OUT" | LC_ALL=C awk -v top="$JIT_MISSES_TOP" '
    {
      line = $0
      if (substr(line, 1, 2) != "  ") next
      rest = substr(line, 3)
      xi = index(rest, "x")
      if (xi == 0) next
      n = substr(rest, 1, xi - 1)
      if (n !~ /^[0-9]+$/) next
      tail = substr(rest, xi + 1)
      if (substr(tail, 1, 2) != "  ") next
      tok = substr(tail, 3)
      if (tok == "") next
      out = out (out == "" ? "" : ", ") "\\\"" tok "\\\" x" n
      c++
      if (c >= top) exit
    }
    END { if (out != "") print out }
  ')"
else
  # jit-misses.sh names its own reason on the first line of what it wrote --
  # "jit-misses: SKIPPED -- <reason>" -- and that is now MISSES_OUT because the capture
  # above merged stderr into it (2>&1). Anything that reaches this branch without that
  # exact shape is a failure jit-misses.sh itself never got to report -- this shell could
  # not even exec it, say -- and gets a reason of its own rather than silence.
  JIT_SKIP_REASON="$(printf '%s\n' "$MISSES_OUT" | LC_ALL=C awk '
    NR == 1 {
      prefix = "jit-misses: SKIPPED -- "
      if (index($0, prefix) == 1) print substr($0, length(prefix) + 1)
      exit
    }
  ')"
  if [ -z "$JIT_SKIP_REASON" ]; then
    JIT_SKIP_REASON="jit-misses.sh exited $MISSES_RC"
  fi
  # Two of jit-misses.sh own SKIPPED reasons mean "there is no data yet", not "something
  # is wrong": a project with no hooks.log at all, and one whose log exists but has
  # nothing written to it. Both are the ordinary shape of a fresh project or its first
  # few sessions, both were silent before #233 ever existed, and test-session-markers.sh
  # already pins that silence for the no-such-file case across every engine this repo
  # tests. Surfacing THOSE as "could not be evaluated" would turn the normal state of a
  # brand new project into a standing warning on every session until enough history
  # accumulates -- which is the opposite of what #247 is for. Every OTHER reason --
  # unreadable, not a regular file, a log that is not this tool's log at all, one with
  # records but none from pre-prompt -- means jit-misses.sh tried and could not, and that
  # is the case #247 is about: it says so instead of reading as "nothing recurs".
  case "$JIT_SKIP_REASON" in
    "no such file"*|"the file is empty"*) JIT_SKIP_REASON="" ;;
  esac
  if [ -n "$JIT_SKIP_REASON" ]; then
    # The reason is prose jit-misses.sh chose, not a token restricted to [a-z0-9-] like
    # JIT_RECUR's, so it is escaped for the JSON string it lands inside -- a literal
    # backslash or double quote would otherwise break the surrounding object, and a hook
    # must never fail hard on a string it did not choose the shape of.
    JIT_SKIP_REASON="$(printf '%s' "$JIT_SKIP_REASON" | LC_ALL=C awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print }')"
  fi
fi

# #248: jit-misses.sh names the log's own size, and past its watch threshold says so in
# a line of its own -- "  the log has reached N bytes, at or past the M byte watch
# threshold ...". That line only exists when jit-misses.sh got far enough to read the
# log at all, so this parse is safe to run unconditionally over MISSES_OUT: on a
# SKIPPED run (JIT_SKIP_REASON branch above) or an ordinary small log, the prefix below
# simply never matches and JIT_SIZE_NOTE stays empty. Read from MISSES_OUT rather than
# threaded through a new jit-misses.sh flag, for the same reason JIT_RECUR is: one
# report, read back rather than re-derived.
JIT_SIZE_NOTE="$(printf '%s\n' "$MISSES_OUT" | LC_ALL=C awk '
  {
    prefix = "  the log has reached "
    if (index($0, prefix) == 1) { print substr($0, length(prefix) + 1); exit }
  }
')"
if [ -n "$JIT_SIZE_NOTE" ]; then
  # Prose jit-misses.sh chose, so it is escaped the same way JIT_SKIP_REASON is above --
  # a literal backslash or double quote would otherwise break the JSON string it lands
  # inside, and a hook must never fail hard on a string it did not choose the shape of.
  JIT_SIZE_NOTE="$(printf '%s' "$JIT_SIZE_NOTE" | LC_ALL=C awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print }')"
fi

# raw counts, unfiltered for ordinary English words: #246. entries.md tells an author
# the opposite of what a bare "recurring misses: X" reads as recommending -- "repo",
# "context" and "index" are ordinary words that also happen to be project nouns in a
# project about vocabulary indexing, and jit-misses.sh has no way to tell those apart
# from a genuine gap (see #232, open on that same discrimination problem). Saying so
# plainly here does not solve which of these are worth an entry; it stops the sentence
# from reading as a recommendation on its own.
#
# #248: every branch below that has something to say also says WHICH WINDOW it covers
# -- "last JIT_MISSES_TAIL line(s) of the log" -- so a finding built over a bounded read
# never reads as a finding over the log's whole history, and a size-watch note appends
# to whichever branch fired rather than replacing it, because "these words recur" and
# "the log is getting big" are two different facts and neither should swallow the
# other. The size note can also be the ONLY thing worth saying -- a log past threshold
# with no recurring words and a readable log -- so it gets a branch of its own too.
if [ -n "$JIT_RECUR" ]; then
  JIT_EXTRA=""
  [ -n "$JIT_SIZE_NOTE" ] && JIT_EXTRA=" -- also, $JIT_SIZE_NOTE"
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"recurring misses (last %s line(s) of the log, raw counts, not filtered for ordinary words -- judge before adding a vocabulary entry): %s%s"}}\n' "$JIT_MISSES_TAIL" "$JIT_RECUR" "$JIT_EXTRA"
elif [ -n "$JIT_SKIP_REASON" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"recurring misses: could not be evaluated (%s)"}}\n' "$JIT_SKIP_REASON"
elif [ -n "$JIT_SIZE_NOTE" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$JIT_SIZE_NOTE"
else
  echo '{}'
fi
