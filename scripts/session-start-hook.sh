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

echo '{}'
