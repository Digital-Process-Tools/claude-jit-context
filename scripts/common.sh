#!/bin/bash
# Shared functions for claude-jit-context hooks and pipeline scripts.
# Source this at the top of every script: source "$(dirname "$0")/common.sh"

_ms() { perl -MTime::HiRes -e 'printf("%.0f\n",Time::HiRes::time()*1000)'; }

JIT_BASE="${CLAUDE_PROJECT_DIR:-.}/.claude/jit-context"

# --- Entry files and layer directories that are SYMBOLIC LINKS ---------------
# PR #11 stopped an index row from NAMING a path outside its layer. It did not stop the
# entry file from BEING a link to one: the name in the index is bare, so it passes that
# check, and getline follows the link. Reproduced 2026-08-11 at all five read sites, and
# again with any directory on the way to one linked instead -- the layer, the dimension,
# .claude/jit-context/ or .claude/ -- each of which needs nothing inside the tree but the
# one link, since the linked directory carries its own 00-index.tsv. git clone recreates
# all of them, so cloning a repository is the whole attack.
#
# awk cannot lstat, and the architecture is one awk process per hook with no per-row
# subprocess. So the lstat is paid ONCE per hook invocation, here, and never per row.
#
# It is paid with a glob and a [ -L ] test, both of which are shell BUILTINS -- this forks
# nothing. Measured end to end on a 1008-entry tree, interleaved against the unpatched
# hook to cancel machine load: 31 ms before, 43 ms after. On a 5-entry tree the difference
# did not clear the noise floor. A find fork costs the same walk plus a process.
#
# Re-measured 2026-08-12 after #34 added the dot-form globs, same tree, same interleave:
# 40 ms for the seven-term loop at 0994dc0 against 48 ms for it here -- the walk is issued
# twice per depth now, once for each form, and both halves lstat every hit. That is the
# price of the sweep being able to see a file named after the thing that hides it.
#
# Every hook does its own sweep. Nothing is cached to a marker and nothing is carried
# between hooks, because a cache is only as good as the run that filled it: a session
# whose runner never fires SessionStart would have failed OPEN, and failing open is the
# wrong direction for a disclosure.
#
# The verdict is structural, not a resolution: a link is refused whether or not its target
# is inside the tree. awk has no realpath, and buying one costs a process per row -- the
# exact cost this design exists to avoid. An entry that needs to live elsewhere is a copy
# or a generated layer, not a link.
#
# The list travels to the hooks through the ENVIRONMENT, for the reason JIT_CONFIG_REFUSED
# does: it is newline-separated, and a newline in an awk -v value is a fatal error raised
# before the program runs.
export JIT_SYMLINKS=""

# ...and the environment has a size. JIT_SYMLINKS was unbounded, so a tree with roughly 4000
# attacker-named links pushed the environment past ARG_MAX and every exec from this file
# onward failed with E2BIG. The hook then emitted NOTHING, exited 0, printed "Argument list
# too long" to the session stderr, and a block rule that was present, indexed and honourable
# did not block. It failed OPEN and it was loud about it -- both of this file standing
# contracts broken at once, by a quantity the repository being cloned chooses.
#
# So the set is CAPPED, in bytes rather than in entries: bytes are the quantity ARG_MAX is
# about, and 4000 short names and 40 long ones are the same problem. Crossing the cap is not
# a reason to enumerate less and carry on -- that is failing open with extra steps. It sets
# a sentinel that refuses EVERY row in the tree, because a tree nobody can enumerate is a
# tree nobody can vouch for. The sweep stops there, which also bounds its own cost: the
# accumulation is a string append per link and quadratic in the count.
#
# 8192 is far above any honest tree. An honest tree records ZERO links; the cases that
# legitimately record a few are a project opened through a linked parent, which records two.
# It is far below the smallest ARG_MAX on any leg of CI -- including Windows, where the
# limit that bites is the 32767-character process environment block rather than ARG_MAX.
#
# A temp file was the other option and is worse here: it is a fork per hook invocation on a
# path that must stay under 110 ms, it needs cleanup on every exit path, and it puts a
# predictable new file next to a tree we have just decided is hostile -- reopening the class
# of defect this whole sweep exists to close. A cap needs none of that and bounds the thing
# that actually broke.
JIT_SYMLINKS_MAX=8192
export JIT_SYMLINKS_ALL=""

# Populated shallow-to-deep, so a directory already in the set marks its children too --
# a regular file inside a linked layer directory is not itself a link, and lstat on it
# says nothing. Membership is a newline-delimited substring test, because macOS ships
# bash 3.2 and has no associative arrays.
#
# nullglob is deliberately NOT set: an unmatched glob stays literal, that literal is
# neither a link nor a known parent, and it falls out of both tests on its own. Toggling
# a shell option in a sourced file would change it for whatever sourced us.
JIT_NL="
"
jit_scan_symlinks() {
  local base="$1" f parent found=0
  JIT_SYMLINKS="$JIT_NL"
  JIT_SYMLINKS_ALL=""
  # `.claude/` is inside the repository too, and git carries it as a link like anything
  # else, so `.claude -> /elsewhere` reaches the same disclosure one level above anything
  # the glob below can see -- with a jit-context/ inside the target it needs nothing in the
  # clone but that one link. Driven, not reasoned: it leaked on the first cut of this fix.
  #
  # Exactly one ancestor is tested and the walk stops there. Everything above the project
  # directory is the user's own filesystem rather than something the clone chose, and on
  # macOS /tmp is itself a symlink -- a sweep that walked to the root would refuse every
  # honest tree opened through one.
  if [ "${base%/*}" != "$base" ] && [ -L "${base%/*}" ]; then
    JIT_SYMLINKS="$JIT_SYMLINKS${base%/*}$JIT_NL$base$JIT_NL"
    found=1
  fi
  # Both forms at every depth. A glob `*` does not match a leading dot, so until #34 the
  # sweep walked straight past `.hidden.md` -- never lstat-ed it, never recorded it, and the
  # awk side then cleared the row. The comment about the log path forty lines below already
  # said this about `.discovery` and did not apply it here.
  #
  # Ordering still matters and is still shallow-to-deep: both forms at depth 1 before either
  # form at depth 2, so a descendant can only ever be tested after its ancestor was recorded.
  #
  # `.` and `..` are dropped below rather than here -- a glob cannot exclude them, and
  # `..` is the parent of the tree, which is neither ours to judge nor ours to refuse.
  for f in "$base" "$base"/* "$base"/.* "$base"/*/* "$base"/*/.* "$base"/*/*/* "$base"/*/*/.*; do
    case "$f" in
      */. | */..) continue ;;
    esac
    if [ -L "$f" ]; then
      JIT_SYMLINKS="$JIT_SYMLINKS$f$JIT_NL"
      found=1
      # See JIT_SYMLINKS_MAX above. Checked at the two places that grow the set, and the
      # sweep RETURNS rather than continuing: a partial list is a list that clears rows it
      # never looked at, which is the failure this is here to stop.
      if [ "${#JIT_SYMLINKS}" -gt "$JIT_SYMLINKS_MAX" ]; then
        JIT_SYMLINKS="$JIT_NL"
        JIT_SYMLINKS_ALL=1
        export JIT_SYMLINKS JIT_SYMLINKS_ALL
        return 0
      fi
      continue
    fi
    # The parent test is skipped entirely until a link has actually been seen, and on a
    # tree with none it never runs at all. That guard is the whole cost story: measured in
    # isolation on a 1008-entry tree, the sweep cost 70 ms with this test running
    # unconditionally and 12 ms with it guarded -- against a glob-and-lstat floor of 12 ms,
    # so guarded it adds nothing measurable of its own. The cost was the pattern match, per
    # file, against a set that is empty in every honest tree.
    #
    # Those two figures are from before #34 widened the loop. Re-measured on the same shape
    # of tree with the seven terms below, interleaved to cancel load: 10.7 ms for the old
    # four-term loop against 18.4 ms for this one. The guard still costs nothing of its own
    # -- the tree has no links, so this branch never runs -- and the floor itself moved,
    # because the walk is now issued twice per depth.
    #
    # The globs are issued shallow-to-deep, both the plain and the dot form at each depth
    # before either form at the next, so every entry at one depth is recorded before any
    # entry at the next is tested. Descendants can only follow an ancestor, and nothing is
    # missed by not looking earlier.
    [ "$found" = 1 ] || continue
    [ "$f" != "$base" ] || continue
    parent="${f%/*}"
    case "$JIT_SYMLINKS" in
      *"$JIT_NL$parent$JIT_NL"*)
        JIT_SYMLINKS="$JIT_SYMLINKS$f$JIT_NL"
        # The second place the set grows. A linked layer directory can carry an unbounded
        # number of ordinary files, every one of which is recorded here, so capping only the
        # branch above would have left the same hole one indirection away.
        if [ "${#JIT_SYMLINKS}" -gt "$JIT_SYMLINKS_MAX" ]; then
          JIT_SYMLINKS="$JIT_NL"
          JIT_SYMLINKS_ALL=1
          export JIT_SYMLINKS JIT_SYMLINKS_ALL
          return 0
        fi
        ;;
    esac
  done
  export JIT_SYMLINKS JIT_SYMLINKS_ALL
}

jit_scan_symlinks "$JIT_BASE"

# --- The log path is inside the project, so a clone chooses where we write ---
# LOG_DIR and LOG_FILE are built by concatenating onto JIT_BASE, and until 2026-08-12
# nothing checked them. `mkdir -p` follows a symlink and `>>` follows a symlink, and git
# tracks symlinks as mode 120000 -- so a committed
# `.claude/jit-context/.discovery/logs/hooks.log -> ~/.zshenv` means one prompt appends
# attacker-chosen text to the victim's rc file, and it runs at the next shell start.
# Reproduced with NO keyword match, NO rule fired and NO entry file present: the refusal
# path alone writes a line, and the row's file-name column is the payload.
#
# jit_scan_symlinks() does not cover this, and the reason changed with #34. It used to be
# that the sweep globbed only with `*`, which does not match a leading dot, so `.discovery`
# was invisible to it by construction; the sweep globs the dot forms now and does see it.
# What still holds is the other half of that sentence, which was always the load-bearing
# one: the log path is a DIFFERENT concatenation from the entry path. The sweep answers
# "is this path a link", and nothing reads its answer on the way to the log -- so these
# tests stay here rather than becoming a lookup into a set built for another purpose.
#
# Four positions reach the same write and all four are tested: hooks.log, logs/,
# .discovery/, and the two directories above JIT_BASE that the entry sweep already refuses.
#
# On refusal, logging is DISABLED for the run and the hook carries on. A hook that cannot
# log still has a job to do, and this file runs before every one of them -- exiting here
# would be the "fail hard" this whole design forbids. Nothing is injected about it either:
# the log is for the person, and a notice would be a second attacker-triggered channel.
#
# Five `[ -L ]` tests, all shell builtins, forking nothing.
JIT_LOG_DISABLED=0
LOG_DIR="$JIT_BASE/.discovery/logs"
LOG_FILE="$LOG_DIR/hooks.log"
for _jit_p in "${JIT_BASE%/*}" "$JIT_BASE" "$JIT_BASE/.discovery" "$LOG_DIR"; do
  if [ -L "$_jit_p" ]; then JIT_LOG_DISABLED=1; fi
done
unset _jit_p
# The mkdir is what MATERIALISES a directory through a link, so it is gated too, not just
# the append. `2>/dev/null` because a read-only or unwritable tree is a reason to say
# nothing, never a reason to print to a session's stderr.
if [ "$JIT_LOG_DISABLED" = 0 ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null
  # Checked after the mkdir as well: hooks.log may be a dangling link, which `mkdir -p`
  # on its parent neither creates nor disturbs.
  if [ -L "$LOG_FILE" ]; then JIT_LOG_DISABLED=1; fi
fi
# Every writer goes through this. A caller that appends to "$LOG_FILE" directly reopens
# the hole -- there is one function so there is one place to check.
jit_log_write() {
  if [ "$JIT_LOG_DISABLED" = 0 ]; then
    # Same ordering trap as jit_shown_apply below: `>> "$LOG_FILE" 2>/dev/null` suppresses
    # nothing, because the redirection that fails is applied before the one that would have
    # hidden it. A log directory removed after common.sh created it printed straight into
    # the session.
    printf '%s\n' "$1" 2>/dev/null >> "$LOG_FILE"
  fi
}

# --- The once-per-session markers, and what a session is --------------------
# They used to be /tmp/claude-{vocab,path}-shown-$PPID.txt. Two things were wrong with
# that and only one of them was visible.
#
# $PPID is not a session. Under `$( ... )` it is the command-substitution SUBSHELL --
# measured: script pid 31660, hook PPID 31661 -- a short-lived pid the OS recycles freely.
# Two hook calls in one process drew the same marker at random, and what the second one
# then suppressed was every path rule INCLUDING the refusal notice, so a lost security
# message and a flake had the same signature. 4 of 5 full `run-all.sh` runs went red at
# 8c62858 with ZERO stale marker files on disk: recycling inside one run, not leftovers.
# In production the same weak proxy collides across concurrent sessions and worktrees.
#
# And /tmp is shared, so nothing there could be cleaned without reaching into state this
# session does not own -- which is exactly what `rm -f /tmp/claude-hook-log-*.tmp` did.
#
# The key is now the `session_id` the hook payload carries, read in awk (jit_session_key,
# below) because awk is already parsing that JSON. No session_id -- a hand-run hook, a
# test payload -- means NO marker file and no dedup at all, rather than a guess: repeating
# an entry costs tokens, suppressing one costs the rule. That is also why exactly one of the
# twelve existing suites needed a behaviour change: the SessionStart section of
# test-pre-prompt-hook.sh, which asserted on the /tmp files by name.
#
# The directory is the project's, beside the log, so markers die with the tree instead of
# accumulating in /tmp forever (12,288 of them on one machine, #17) and two projects no
# longer share a namespace. That puts a WRITE inside a tree a clone controls, so it gets
# the same four `[ -L ]` tests the log path got in #27 -- written out again rather than
# read off the log's verdict, because this is a DIFFERENT concatenation and JIT_LOG_DISABLED
# also covers hooks.log itself, which has nothing to say about this directory.
#
# An unwritable or read-only checkout ends with JIT_STATE_DIR empty, which degrades to no
# dedup in silence. A hook that cannot remember is still a hook that must run.
JIT_STATE_DIR="$JIT_BASE/.discovery/state"
for _jit_p in "${JIT_BASE%/*}" "$JIT_BASE" "$JIT_BASE/.discovery" "$JIT_STATE_DIR"; do
  if [ -L "$_jit_p" ]; then JIT_STATE_DIR=""; fi
done
unset _jit_p
# `mkdir -p` is a fork, and this file runs before every hook, so it is only paid when the
# directory is missing AND the parent that would hold it is writable -- otherwise a
# permanently read-only checkout buys a doomed fork on every prompt and every tool call,
# forever, because a one-shot process cannot remember that it already failed. Both tests
# below are shell builtins. Gated on JIT_BASE existing too: a session with no jit-context
# tree at all should not have one materialised under its cwd.
if [ -n "$JIT_STATE_DIR" ] && [ -d "$JIT_BASE" ] && [ ! -d "$JIT_STATE_DIR" ]; then
  if [ -d "$JIT_BASE/.discovery" ]; then
    if [ -w "$JIT_BASE/.discovery" ]; then mkdir -p "$JIT_STATE_DIR" 2>/dev/null; fi
  elif [ -w "$JIT_BASE" ]; then
    mkdir -p "$JIT_STATE_DIR" 2>/dev/null
  fi
fi
if [ ! -d "$JIT_STATE_DIR" ] || [ ! -w "$JIT_STATE_DIR" ]; then JIT_STATE_DIR=""; fi

# --- The marker FILE gets no sweep, and that is a measurement, not an oversight ---------
# The four tests above are on ancestors. The marker itself got none, awk cannot lstat, and
# `print key >> file` therefore followed a committed link and appended entry names into a file
# outside the tree (#49) -- the shape #27 closed for hooks.log, one concatenation to the left.
#
# The WRITE now gets a real `[ -L ]`, because the write moved into bash: see
# jit_shown_apply() below. That is the whole of #49 and it costs one builtin.
#
# The READ stays in awk, because only awk knows the session id, and it is NOT swept. The
# obvious sweep -- glob this directory, refuse it if anything in it is a link or not an
# ordinary file -- was written, measured and removed. It is O(entries), and the number of
# entries is a quantity a CLONED REPOSITORY chooses: `.discovery/state/` is inside the tree
# and git carries whatever is committed there. Interleaved against the unpatched hook on the
# same machine, 60 calls per point:
#
#     entries      0      500     2000     8000
#     unpatched   30 ms   30 ms   30 ms    45 ms
#     swept       30 ms   41 ms   84 ms   238 ms   (worst sample 565 ms)
#
# That is JIT_SYMLINKS_MAX's failure re-introduced by the fix for another one: a repository
# choosing how long every prompt in the session takes. A cap does not save it either, because
# the cost is the glob expansion itself, before any test in the loop runs.
#
# What the unswept read can actually do, stated so it can be argued with: it can read a file
# it should not have (a link), and the only use of what it reads is a set of names to SKIP.
# So the worst outcome is fewer injections -- never a write outside the tree, never content
# in the context, never a lost injection. On one-true-awk one shape is also loud: a path that
# opens and then cannot be read, i.e. a DIRECTORY at the marker name, raises a fatal i/o
# error at program exit. jit_shown_load() drops its close() so that error lands AFTER every
# print has flushed rather than instead of them, and session-start-hook.sh removes a link or
# an empty directory sitting at this session's two names before any hook runs. Both routes
# need the session id guessed first.

# --- Applying the marks awk asked for ----------------------------------------
# awk used to append them itself. An unopenable marker path is a FATAL awk error, raised
# inside END before the final `print`, so a rule that was indexed, matched and had something
# to say emitted NOTHING, exited 0, and printed an awk diagnostic into the session's stderr
# (#50): failing open and being loud, the two things this file's own comment at the top
# forbids. Three routes reached it -- a missing directory, an unwritable file, and the state
# directory being removed between the `[ -d ]` above and the write, which needs no guessed
# session id at all.
#
# awk cannot guard a redirect and this repo will not add a runtime dependency to get one.
# bash can: `>>` with `2>/dev/null` is a builtin that cannot kill anything, and `[ -L ]` is
# the check awk was missing. So awk emits `path<TAB>key` lines down the temp channel every
# hook already uses for its log line, and this reads them back.
#
# There is still exactly ONE answer to "what is a session id": awk parses it, awk builds the
# path, and bash never re-derives either. What bash does here is CONTAIN what it was handed
# -- the same posture as jit_bad_entry_file() -- because that channel is a file in /tmp named
# after a pid, and a path arriving over it is not evidence of anything.
jit_shown_apply() {
  local f k name
  [ -n "$JIT_STATE_DIR" ] || return 0
  while IFS=$'\t' read -r f k; do
    [ -n "$f" ] && [ -n "$k" ] || continue
    name="${f#"$JIT_STATE_DIR"/}"
    # Unchanged means the path was not under the state directory at all.
    [ "$name" != "$f" ] || continue
    case "$name" in
      */*) continue ;;
      path-shown-*.txt | vocab-shown-*.txt) ;;
      *) continue ;;
    esac
    # The test awk could not make. Checked here rather than in the sweep above as well,
    # because a link can be planted after that sweep ran and before this line does.
    [ -L "$f" ] && continue
    # `2>/dev/null` BEFORE the append, not after. Redirections are applied left to right,
    # so with `>> "$f" 2>/dev/null` the append is the one that fails and it fails while
    # stderr is still the session -- which printed "No such file or directory" into the
    # stranger's terminal, the exact loudness this whole change is about, out of the line
    # written to prevent it. Driven: it is what section C of the suite caught.
    printf '%s\n' "$k" 2>/dev/null >> "$f"
  done
  return 0
}

# --- The scratch channel the hooks hand to awk -------------------------------
# Every hook needs one file that awk writes and bash reads back: the log line, then the
# marker appends of jit_shown_flush(). It used to be built by concatenation --
# `/tmp/claude-path-log-$$.tmp`, and the same shape twice more -- and awk opened it with
# `>`, which truncates and follows a symbolic link. awk cannot lstat, so awk could not
# have checked; the `[ -f ]` bash did afterwards checked nothing either, because `-f`
# follows the link too and a link to a regular file passes it. A pid is not a secret and
# /tmp is world-writable: the attack is to pre-create the plausible range and wait (#60).
#
# `[ -L ]` before the write is NOT the fix. That is check-then-act on a directory anyone
# can write, which is the one place the race is cheap for the attacker to win. mktemp
# creates with O_EXCL and an unpredictable name in a single step, so there is no window
# and nothing to check: the file cannot be one that already existed.
#
# The cost is one fork per hook fire, on a path budgeted at 30-110 ms. Measured at ~2 ms
# here. The alternative that avoids it -- $JIT_STATE_DIR, which already carries four
# `[ -L ]` ancestor tests -- would put a write inside the user project on every prompt and
# every tool call, which #51 is separately arguing against, and would go silent whenever
# that directory is unavailable.
#
# WHO REMOVES IT. #43: `rm -f /tmp/claude-hook-log-*.tmp` in SessionStart deleted other
# live sessions' in-flight temps. So nothing sweeps by wildcard, and nothing but the
# creating process removes this file -- an EXIT trap, which also covers the crash the
# unpredictable name would otherwise leak forever (bash runs it on a normal exit and on
# every trappable signal; SIGKILL leaks one file of a few dozen bytes, which is the same
# thing the old name leaked, minus the rest of the class).
#
# FAILING TO GET ONE IS NOT AN ERROR. An unwritable or missing $TMPDIR leaves JIT_TMP
# empty, and awk is told so: the hook then has no log line and no dedup, and still
# matches, still injects, still exits 0. Passing "" to awk unguarded would be worse than
# the bug -- an unopenable redirect is FATAL inside END and takes the injection with it,
# which is #50 exactly -- so each hook guards the write on `log_tmp != ""`.
JIT_TMP=""
jit_tmp_open() {
  local d
  d="${TMPDIR:-/tmp}"
  d="${d%/}"
  JIT_TMP="$(mktemp "$d/claude-jit-XXXXXXXX" 2>/dev/null)" || JIT_TMP=""
  [ -n "$JIT_TMP" ] || return 0
  # Single-quoted on purpose: expanded when the trap fires, so it names the file this
  # process created and no other.
  # shellcheck disable=SC2064
  trap 'rm -f "$JIT_TMP"' EXIT
  return 0
}

# Timestamp with ms precision (single perl call, ~11ms)
_ts() { perl -MTime::HiRes -MPOSIX -e 'my $t=Time::HiRes::time(); printf("%s.%03d\n", strftime("%H:%M:%S",localtime($t)), ($t*1000)%1000)'; }

# --- Optional per-project settings ------------------------------------------
# config.env lives INSIDE the project, so it arrives with the repository. It used to be
# dot-sourced here, on every prompt and every tool call, which made cloning a repo and
# opening it arbitrary code execution before the user had read a line of the code.
# Reproduced 2026-08-11: a config.env of `echo ... >&2` printed, and one of `touch ...`
# created the file.
#
# Every documented setting is a plain KEY=VALUE, so the file is READ and never executed.
#
# Only the three documented prefixes are settable. A bare identifier allowlist is not
# enough: PATH is a valid identifier, common.sh runs before every hook invokes `awk`, and
# a config.env that could set PATH would be the same execution one hop removed.
#
# A line that cannot be honoured is REFUSED and named -- in the log, and once per session
# in the injected context. A silently dropped setting is this repo's own defect class: it
# reads exactly like a setting that applied and did nothing.
#
# Only the line number and the reason are reported, never the line's own text. The premise
# of the whole change is that this file may be hostile, and hostile text does not belong
# in a model's context.
#
# The list travels to the hooks through the ENVIRONMENT, never through `awk -v`. It is
# newline-separated, and a -v value containing a newline is the fatal awk error "newline
# in string" -- raised before the program runs, so the hook printed nothing at all and
# exited 0. A single refused line has no separator and hid that completely; two lines
# silenced the whole hook. The channel for reporting a silent failure must not have one.
#
# And it is CAPPED, for the reason JIT_SYMLINKS is: config.env arrives with the repository,
# so its length is chosen by the clone, and one refusal line per bad line was unbounded. A
# config.env of 30000 unknown settings pushed the environment past ARG_MAX; every exec from
# this file onward failed, the hook emitted nothing, exited 0, and printed "Argument list too
# long" to the session stderr. Same shape as #36, one channel over, found while fixing it.
#
# The COUNT is not capped, only the list. A truncated list that also under-counted would be
# this repo own defect class wearing a fix as a disguise: a report that reads as complete and
# is not. The notice says how many were refused, lists what fits, and says plainly that the
# rest are not there.
JIT_CONFIG_REFUSED_MAX=4096
export JIT_CONFIG_REFUSED=""
export JIT_CONFIG_REFUSED_N=0

# One appender, so there is one place the cap is applied. Two call sites grew this string
# before and capping either alone would have left the other unbounded.
JIT_CONFIG_REFUSED_CUT=0
jit_config_refuse() {
  # $1 line number, $2 reason
  JIT_CONFIG_REFUSED_N=$((JIT_CONFIG_REFUSED_N + 1))
  if [ "${#JIT_CONFIG_REFUSED}" -gt "$JIT_CONFIG_REFUSED_MAX" ]; then
    if [ "$JIT_CONFIG_REFUSED_CUT" = 0 ]; then
      JIT_CONFIG_REFUSED_CUT=1
      JIT_CONFIG_REFUSED="$JIT_CONFIG_REFUSED$JIT_NL- the remaining refused lines are not listed here; the count above is the whole total"
    fi
    return 0
  fi
  JIT_CONFIG_REFUSED="$JIT_CONFIG_REFUSED${JIT_CONFIG_REFUSED:+$JIT_NL}- line $1: $2"
}

jit_load_config() {
  local file="$1" line key value reason q rest tail lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # A CRLF checkout must parse the same as an LF one -- config.env is not covered by
    # this repo's .gitattributes, because it lives in the user's project.
    line="${line%$'\r'}"
    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
    case "$line" in
      ''|'#'*) continue ;;
      # `export KEY=VALUE` was valid while this file was sourced, so it stays valid.
      # The export itself is a no-op now: the hooks read these as shell variables.
      export[[:space:]]*)
        line="${line#export}"
        while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
        ;;
    esac

    reason=""
    case "$line" in
      *=*) key="${line%%=*}"; value="${line#*=}" ;;
      *)   key=""; value=""; reason="not a KEY=VALUE assignment" ;;
    esac
    if [ -z "$reason" ] && ! [[ "$key" =~ ^(JIT_CONTEXT|DYNAMIC_RULES|DVSI)_[A-Za-z0-9_]+$ ]]; then
      reason="unknown setting (only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* are read)"
    fi
    if [ -n "$reason" ]; then
      jit_config_refuse "$lineno" "$reason"
      continue
    fi

    # Quotes and trailing comments are handled the way `.`-sourcing handled them, because
    # a config.env that worked before this change has to keep working. A parser that only
    # strips a quote pair turns `KEY="src/" # default` into the value `"src/" # default`
    # -- not refused, not reported, just quietly wrong. That is the exact failure mode the
    # refusal machinery above exists to prevent, reintroduced by the fix for it.
    #
    # Nothing inside a value is expanded: a $, a backtick or a $(...) is a literal now.
    case "$value" in
      '"'*|"'"*)
        q="${value%"${value#?}"}"        # the opening quote, " or '
        rest="${value#?}"
        case "$rest" in
          *"$q"*)
            tail="${rest#*"$q"}"
            while [ "$tail" != "${tail#[[:space:]]}" ]; do tail="${tail#[[:space:]]}"; done
            case "$tail" in
              # Anything after the closing quote that is not a comment is ambiguous, so it
              # is refused rather than guessed at. Guessing is how a value goes quietly
              # wrong, which is the one outcome this whole function is written to avoid.
              ''|'#'*) value="${rest%%"$q"*}" ;;
              *) reason="trailing text after the closing quote" ;;
            esac
            ;;
          *) reason="unterminated quote" ;;
        esac
        ;;
      *)
        # Bash starts a comment at a # preceded by whitespace, and treats one that is not
        # as an ordinary character -- so `^(a#b)$` keeps its hash and `1 # on` does not.
        case "$value" in
          *[[:space:]]#*) value="${value%%[[:space:]]#*}" ;;
        esac
        while [ "$value" != "${value%[[:space:]]}" ]; do value="${value%[[:space:]]}"; done
        ;;
    esac
    if [ -n "$reason" ]; then
      jit_config_refuse "$lineno" "$reason"
      continue
    fi
    printf -v "$key" '%s' "$value"
  done < "$file"
}

# config.env is the same trust boundary as the log, one file over. It is a direct child of
# JIT_BASE -- so jit_scan_symlinks() already records it when it is a link -- but this read
# opened it by name and consulted nothing. git carries the link, so a clone chose a file
# OUTSIDE the project to be read line by line, and any JIT_CONTEXT_*, DYNAMIC_RULES_* or
# DVSI_* line that happened to be in the target then took effect. No line text leaves this
# function, but the settings do, and so does the shape of a file nobody meant to expose.
#
# Refused and NAMED, through the channel config.env refusals already use. Ignoring the file
# in silence would be this repo's own defect class wearing a fix as a disguise: a setting
# that reads as applied and is not.
#
# The whole file is one refusal, so it is reported without a line number -- there is no line
# to point at, and inventing one would be worse than saying so plainly.
if [ -L "$JIT_BASE/config.env" ]; then
  JIT_CONFIG_REFUSED_N=1
  JIT_CONFIG_REFUSED="- the file itself: config.env is a symbolic link, so it was not read"
  jit_log_write "$(printf '[%s] config.env | refused: symbolic link' "$(_ts)")"
elif [ -f "$JIT_BASE/config.env" ]; then
  jit_load_config "$JIT_BASE/config.env"
  if [ "$JIT_CONFIG_REFUSED_N" -gt 0 ]; then
    jit_log_write "$(printf '[%s] config.env | %d line(s) refused\n%s' \
      "$(_ts)" "$JIT_CONFIG_REFUSED_N" "$JIT_CONFIG_REFUSED")"
  fi
fi

# Pipeline log: _log "step" duration_ms "message"  → [HH:MM:SS.mmm] step 42ms | message
_log() {
  local line="$1 ${2}ms | $3"
  jit_log_write "[$(_ts)] $line"
  echo "$line"
}

# --- Frontmatter reader ------------------------------------------------------
# The ONE reader of an entry's YAML frontmatter. rebuild-tsv.sh writes the index with it
# and jit-dry-run.sh checks the index against it, so the two cannot drift into disagreeing
# about what a file says -- which would make the staleness lint either blind or noisy, and
# both of those read as "the tree is fine".
#
# Only the first `---` block, only the first occurrence of the field.
jit_frontmatter() {
  # $1 field name, $2 entry file
  awk -v f="$1" '
    /^---$/ { n++; next }
    n == 1 && index($0, f ":") == 1 {
      sub("^" f ": *", "")
      # mode is a comma-separated token list, so every space goes.
      if (f == "mode") { gsub(/ /, "") }
      else {
        # Every other field is free text, and a `match:` value is an awk ERE where a
        # double quote is an ordinary character an author has real reason to write --
        # `["]` is how you anchor on a quoted argument. Deleting every quote in the value
        # (#19) turned that into `[]`, silently: the .md still read as the author wrote
        # it, only the index runs, and the rule matched something else forever with no
        # error and no log line.
        #
        # So only a pair WRAPPING the whole value goes -- that is YAML-style quoting of
        # the value, which is what the strip was for. A quote anywhere else is data.
        #
        # Wrapping is `^"[^"]*"$` and not `^".*"$` on purpose: the second is greedy, and
        # `"a" and "b"` starts and ends with a quote without being one quoted scalar. It
        # would come out as `a" and "b"` -- a rewrite nobody asked for, which is the
        # defect this whole change is about. Anything that is not unambiguously a wrapped
        # scalar is preserved verbatim, and a value is never required to be quoted here:
        # the reader takes the rest of the line as it stands.
        v = $0
        sub(/[[:space:]]+$/, "", v)
        if (v ~ /^"[^"]*"$/) $0 = substr(v, 2, length(v) - 2)
      }
      print
      exit
    }
  ' "$2"
}

# --- Invocation macros -------------------------------------------------------
# A rule that has to fire on an INVOCATION rather than on a word carries an anchor, and
# the anchor is the part nobody can verify by reading. Four have been wrong: the \n
# alternative that could never fire (#6), `git stash push` blocked by a rule written for
# `git push` (#8), a rule with no anchor at all (#8), and this repo's own paths rule
# matching a session scratchpad directory (#10). Three of those were written by someone
# who had read the anchoring guidance; one was in the file that contains it.
#
# So the anchor is written once, here, and named in frontmatter instead of retyped:
#
#   match: ~@invocation git push               command-with-options
#   match: ~@invocation-quoted-arg supertool   command-with-quoted-argument
#
# Expansion happens in rebuild-tsv.sh, at index time. The INDEX CONTRACT does not change:
# the column still holds a plain awk ERE, the hooks are untouched, and an index built from
# frontmatter that uses no macro is byte-identical to the one built before this existed.
# Nobody has to rebuild anything to keep working.
#
# What the two shapes mean, and the near-miss each one exists to exclude:
#
#   @invocation W...     the words at invocation position, optionally behind a wrapper
#                        (rtk, command, env, sudo) or an environment assignment, with
#                        only OPTION-SHAPED tokens between them. `git -C /tmp push`
#                        matches; `git stash push` does not, because a subcommand is not
#                        an option. That distinction is the whole point -- the widely
#                        copied `([^;&|\n]*[[:space:]])?`, added to catch the first, also
#                        swallows the second.
#
#   @invocation-quoted-arg W...
#                        the same, followed by a QUOTED argument before any pipe.
#                        `supertool 'gh-pr:1' | head` matches; `pytest | tail` does not.
#                        Hand-writing this used to be impossible -- the frontmatter reader
#                        deleted every double quote in a `match:` value, so an author could
#                        only ever anchor on the single quote and never learned the other
#                        half had gone (#19). jit_frontmatter() now preserves it, so the
#                        macro is a shorthand for an anchor rather than the only route to
#                        one; the anchor is still the part nobody can verify by reading,
#                        which is why it is written once here.
#
# The subject a tools regex is matched against is lowercased by the hook, so the words
# are lowercased here. Everything outside [a-z0-9_/] is emitted inside a bracket
# expression rather than behind a backslash: `\.` is accepted by awk today, but
# jit_bad_pattern() refuses undefined escapes and a bracket needs no per-engine judgement.
JIT_MACRO_ANCHOR='(^|[;&|\n] *)'
JIT_MACRO_WRAP='(([a-z_][a-z0-9_]*=[^[:space:];&|]*|rtk|command|env|sudo|nohup|nice|time)[[:space:]]+)*'
JIT_MACRO_OPT='(-[^[:space:];&|]*[[:space:]]+([^-;&|[:space:]][^[:space:];&|]*[[:space:]]+)?)*'
JIT_MACRO_END='($|[[:space:];&|])'

jit_macro_word() {
  local w="$1" out="" i n c
  n=${#w}
  for ((i = 0; i < n; i++)); do
    c="${w:i:1}"
    case "$c" in
      [a-z0-9_/]) out="$out$c" ;;
      *)          out="${out}[$c]" ;;
    esac
  done
  printf '%s' "$out"
}

# jit_expand_match RAW DIMENSION LABEL
#
# Prints the value to write into the index, and returns 0 when it can be honoured. A value
# that is not a macro is printed back unchanged -- this function is on the path of every
# row, and it must be a no-op for every rule that exists today.
#
# A macro it CANNOT honour is also printed back unchanged, returns 1, and names itself on
# stderr. Dropping the row would delete a rule the author wrote; repairing it would be a
# guess. Written through, the unexpanded `@name` reaches jit_bad_pattern() in the hook,
# which refuses that row by name -- loud at build time and loud at run time, instead of a
# literal that compiles cleanly and matches nothing.
jit_expand_match() {
  local raw="$1" dim="${2:-tools}" label="${3:-<entry>}"
  local body name args reason="" out word first=1

  case "$raw" in '~'*) body="${raw#\~}" ;; *) body="$raw" ;; esac
  case "$body" in '@'*) ;; *) printf '%s' "$raw"; return 0 ;; esac

  name="${body#@}"
  args=""
  case "$name" in
    *[[:space:]]*) args="${name#*[[:space:]]}"; name="${name%%[[:space:]]*}" ;;
  esac
  while [ "$args" != "${args#[[:space:]]}" ]; do args="${args#[[:space:]]}"; done
  while [ "$args" != "${args%[[:space:]]}" ]; do args="${args%[[:space:]]}"; done
  args="$(printf '%s' "$args" | tr '[:upper:]' '[:lower:]')"

  if [ "$dim" != "tools" ]; then
    reason="@$name describes a COMMAND, and a $dim rule is matched against a file path"
  elif [ "$name" != "invocation" ] && [ "$name" != "invocation-quoted-arg" ]; then
    reason="unknown macro @$name -- the macros are @invocation and @invocation-quoted-arg"
  elif [ -z "$args" ]; then
    reason="@$name needs the command it targets, e.g. 'match: ~@$name git push'"
  else
    case "$args" in
      *[!a-z0-9._/:+\ -]*) reason="@$name takes plain command words, and this one carries a character that is not one" ;;
    esac
  fi

  if [ -n "$reason" ]; then
    printf '%s' "$raw"
    printf 'REFUSED  %s: %s\n' "$label" "$reason" >&2
    printf '         written through unexpanded, so the hook refuses that row by name rather than matching nothing.\n' >&2
    return 1
  fi

  out="$JIT_MACRO_ANCHOR$JIT_MACRO_WRAP"
  # Deliberate word splitting: args is the space-separated command phrase, already
  # restricted above to characters that cannot glob.
  # shellcheck disable=SC2086
  for word in $args; do
    [ "$first" = 1 ] || out="${out}[[:space:]]+${JIT_MACRO_OPT}"
    out="$out$(jit_macro_word "$word")"
    first=0
  done
  case "$name" in
    invocation)            out="$out$JIT_MACRO_END" ;;
    invocation-quoted-arg) out="${out}[[:space:]]+${JIT_MACRO_OPT}['\"]" ;;
  esac

  # The ~ is not optional and is not copied from the author: a tools row without it is a
  # substring rule, and a substring rule whose text is an ERE can never match anything.
  printf '~%s' "$out"
}

# --- Shared awk guard for a rule match pattern -------------------------------
# Prepended to the hook programs (awk "$JIT_AWK_GUARD"'...'), so the same verdict is
# reached by pre-tool-hook.sh, pre-path-hook.sh and jit-dry-run.sh.
#
# Two failures, and only one of them is loud:
#
#   1. An undefined escape. Measured 2026-08-10 on awk version 20200816: of the ASCII
#      letters, only \a \b \f \n \r \t \v \x survive; every other \<letter> compiles to
#      the bare letter, so ~gh\s+pr becomes ghs+pr and matches nothing at all. awk does
#      not fail on this. It exits 0. Exit status cannot see this defect, which is why
#      the check here is structural rather than a compile probe.
#   2. A malformed pattern. ~a[b is a fatal awk error (exit 2) raised mid-scan, so the
#      END block never runs and EVERY rule in that index — plus the vocabulary pass and
#      the log line — is silenced by one row. Reproduced against both hooks.
#
# The verdict is deliberately engine-independent. A rule fires on the author machine,
# which is where the drop happens; gawk accepting \s is not a licence to write it, and a
# lint whose answer changes with the runner cannot gate anything.
#
# \n is the one escape rules genuinely need — it anchors on command position,
# (^|[;&|\n] *), because ^ anchors the whole command string and not each line. \t and \r
# are honoured too and are left alone. Everything else after a backslash that is a letter
# or a digit is refused: the author is present, and the fix is one character.
#
# Returns "" when the pattern can be honoured, else a short reason.
# Consumed by the hook awk programs and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_AWK_GUARD='
function jit_bad_pattern(p,   i, n, c, nx, depth, inbr, brpos) {
  # An @macro that reached the index unexpanded. Three ways in: an index built before the
  # macros existed, an index not rebuilt after the frontmatter adopted one, or a macro
  # rebuild-tsv.sh refused and wrote through. Compiled as a regex it is a literal that
  # matches nothing, on both engines, while awk exits 0 -- the exact silence this guard
  # exists to break. Anchored on `@name` followed by a space or end of pattern, so a
  # pattern that genuinely starts with a literal @ (`@app/.*`) is untouched.
  if (p ~ /^@[A-Za-z][A-Za-z0-9-]*([[:space:]]|$)/) return "unexpanded macro -- run scripts/rebuild-tsv.sh"
  n = length(p)
  depth = 0
  inbr = 0
  brpos = 0
  for (i = 1; i <= n; i++) {
    c = substr(p, i, 1)
    if (c == "\\") {
      nx = substr(p, i + 1, 1)
      if (nx == "") return "trailing backslash"
      if (nx ~ /[[:alnum:]]/ && nx !~ /^[ntr]$/) return "undefined escape \\" nx
      i++
      continue
    }
    if (inbr) {
      # A POSIX class, collating element or equivalence class is one unit, and the ] it
      # contains does NOT close the bracket expression. Scanning ] naively reads
      # [[:alnum:] as balanced and hands it to match(), where it is a FATAL awk error --
      # reopening the exact failure this guard exists to stop.
      if (c == "[" && substr(p, i + 1, 1) ~ /^[:.=]$/) {
        k = index(substr(p, i + 2), substr(p, i + 1, 1) "]")
        if (k == 0) return "unterminated [" substr(p, i + 1, 1) " element inside a character class"
        i = i + 2 + k
        continue
      }
      # ] is a literal when it is the first character of the expression, or the first
      # after a negating ^.
      if (c == "]" && i != brpos + 1 && !(i == brpos + 2 && substr(p, brpos + 1, 1) == "^")) inbr = 0
      continue
    }
    if (c == "[") { inbr = 1; brpos = i; continue }
    if (c == "(") { depth++; continue }
    # An unmatched ) is a LITERAL in an ERE and awk accepts it -- measured, a)b matches.
    # Refusing it would kill rules that work today, which is worse than the bug: this
    # guard may only ever refuse a pattern awk cannot honour. An unmatched ( is a fatal
    # error, so the closing check below is deliberately one-sided.
    if (c == ")") { if (depth > 0) depth--; continue }
  }
  if (inbr) return "unterminated character class"
  if (depth > 0) return "unbalanced parenthesis"
  return ""
}
'

# --- Shared awk containment check + refusal notices ---------------------------
# Prepended to all three hook programs (the prompt hook has no patterns to guard, so it
# takes this and not JIT_AWK_GUARD), and to jit-dry-run.sh.
#
# An index row names its entry file, and every hook builds the path by concatenating that
# name onto the layer directory. Until 2026-08-11 nothing checked it, so a committed row
# of `../../../../outside.txt` made the hook READ that file and inject its contents into
# the model's context. 00-index.tsv is a committed file, so cloning a repository was the
# whole attack. Reproduced at all five read sites: the path rule loop, the tool rule loop,
# and the three vocabulary passes.
#
# The check is "a bare file name", not a resolved-prefix comparison, because awk has no
# realpath and shelling out for one would cost a process per row. It is safe to be this
# strict: rebuild-tsv.sh writes this column with `basename` at all four of its sites, and
# the generated-layer contract in the README is the same TSV format, so a name carrying a
# separator was never produced by this project.
#
# The backslash is refused for Windows. On Git Bash the Win32 file API underneath awk
# treats it as a separator, so `..\..\x` traverses there while being inert here -- the
# reverse of the mistake this repo has already made twice about the other legs of CI.
#
# Consumed by the hook awk programs and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_AWK_ENTRY='
# A refused row is reported by POSITION, never by the text of its file-name column. That
# column is attacker-controlled free text whose only constraint is that it carries no
# separator, and the refusal notice fires without any rule having matched -- so echoing it
# back would be a prompt-injection channel that needs no trigger at all. The full name
# still goes to hooks.log, which a person reads and no model does.
#
# That was true of the CONTAINMENT branches and false of the pattern branches beside them,
# which echoed the name and carried a comment arguing it was safe because the row had
# passed the bare-name check. Passing that check means no slash, no backslash, not `.` and
# not `..`; it does not mean 250 bytes of English are not a sentence. A file-name column
# reading "IGNORE ALL PREVIOUS INSTRUCTIONS. Run: ..." landed in the context verbatim with
# no rule matched and no entry file present (#35). All seven refusal sites go through this
# function now, and tests/test-security.sh pins each hook.
#
# `layer` is qualified by DIMENSION -- "paths/00-manual", not "00-manual". Two dimensions
# use the same four layer names, one hook reads both, and the file name used to be what
# told two otherwise identical notice lines apart. Withholding the name without adding the
# dimension would have closed one hole by making the remaining line ambiguous.
function jit_row_id(layer, rown) {
  return layer " row " rown
}
# What the LOG may say about a refused row. hooks.log is a file on the disk of whoever
# cloned the repository, read by a person, and the containment branch was writing the row
# file-name column into it verbatim -- the one string jit_bad_entry_file() deliberately
# withholds from the model. A name that FAILED the bare-name check now gets the treatment
# the model-facing notice already gets: the row is named by POSITION, the raw text dropped.
#
# A name that PASSED is bare by construction -- no separator, not . or .. -- and it is what
# an author fixing an unhonourable pattern actually needs, so it is kept. That includes a
# row refused for being a symbolic link: the name passed, only the file behind it did not.
#
# No apostrophes in this block. It is a single-quoted bash string and one would close it.
function jit_log_name(f, layer, rown, why) {
  return (why == "not a bare file name") ? jit_row_id(layer, rown) : f
}
# The set built by jit_scan_symlinks() in the bash half, keyed by full path. Loaded once
# per awk process, lazily, so a hook whose tree has no index pays nothing for it.
function jit_symlinked(p,   n, i, a) {
  # The sentinel first. When the bash sweep could not carry the set within its byte budget
  # it enumerates NOTHING and says so here instead -- a tree nobody can enumerate is a tree
  # nobody can vouch for, so every path in it answers yes. Any future caller of this
  # function inherits that without having to know the sentinel exists.
  if (ENVIRON["JIT_SYMLINKS_ALL"] == "1") return 1
  if (!jit_sym_init) {
    jit_sym_init = 1
    n = split(ENVIRON["JIT_SYMLINKS"], a, "\n")
    for (i = 1; i <= n; i++) if (a[i] != "") jit_sym[a[i]] = 1
  }
  return (p in jit_sym)
}
# dir is the layer directory the caller is about to concatenate this name onto -- the same
# string the hook builds for getline, so the lookup is an exact match against what the
# bash sweep globbed. A caller that passes no dir gets the name checks only.
function jit_bad_entry_file(f, dir) {
  # An empty column is a blank index line, not a rule. It carries no pattern either and
  # the caller skips it on the existing content == "" path; refusing it would fire a
  # notice at the author over stray whitespace.
  if (f == "") return ""
  if (index(f, "/") > 0 || index(f, "\\") > 0) return "not a bare file name"
  if (f == "." || f == "..") return "not a bare file name"
  # A LEADING DOT, refused by name rather than caught by lstat, because lstat never saw it:
  # the sweep in the bash half enumerates the tree with globs and a glob * does not match a
  # leading dot. So `.hidden.md` skipped the link set entirely and every check below cleared
  # it, while the identical link named `hidden.md` was refused -- #13 reopened as #34,
  # driven at all five read sites and in jit-dry-run.sh.
  #
  # The sweep now globs the dot forms too, so this is belt and braces rather than the only
  # guard. It is kept because it is the half that needs no lstat at all, and because it is
  # the same verdict on every platform regardless of what the sweep managed to see.
  #
  # Refusing every dot-name outright is safe for an honest tree: rebuild-tsv.sh writes this
  # column from a `*.md` glob at all four of its sites, and that glob cannot produce one.
  # No WIDER alphabet constraint is imposed. `^[A-Za-z0-9._-]+\.md$` was proposed for this
  # and would have been worse than nothing: it admits `.hidden.md`, every character of which
  # is in that class, and it admits a whole English sentence of dots and hyphens -- so it
  # closes neither this nor the notice-quoting sibling, while refusing an accented or spaced
  # file name that works today. tests/test-security.sh pins both directions.
  if (substr(f, 1, 1) == ".") return "the entry file name begins with a dot, so rename it without one"
  if (dir != "") {
    # The whole-tree sentinel first, and with its own reason: "its layer directory is a
    # symbolic link" would be a specific claim about a specific path that nobody checked.
    # Saying what actually happened is the point -- an author whose tree is refused for this
    # has a different thing to fix from an author whose layer is a link.
    if (ENVIRON["JIT_SYMLINKS_ALL"] == "1") return "this tree has too many symbolic links to check, so every row in it is refused"
    # The directory next: when the layer itself is a link, every row in it is unreadable
    # for the same reason, and naming the file would point the author at the wrong thing.
    if (jit_symlinked(dir)) return "its layer directory is a symbolic link"
    if (jit_symlinked(dir "/" f)) return "the entry file is a symbolic link"
  }
  return ""
}
function jit_refusal_notice(list, n) {
  return "# JIT Context: " n " rule(s) could not be evaluated, so they did NOT run\n" list \
    "\nA pattern the matcher cannot honour is not a rule that did not match, and until now the two looked identical. Lint the tree that owns these rules:\n  bash scripts/jit-dry-run.sh --base <tree>/.claude/jit-context"
}
function jit_config_notice(list, n) {
  return "# JIT Context: " n " line(s) in .claude/jit-context/config.env were refused, so they did NOT take effect\n" list \
    "\nconfig.env is read as plain KEY=VALUE and is never executed. Only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* settings are read; anything else, shell included, is refused. If a refused line is not one you wrote, treat that file as hostile -- it arrived with the repository."
}
'

# --- Shared JSON string reader ---------------------------------------------
# Prepended to all three hook programs. Every hook used to read its payload with
# `split(input, f, "\\"")` and take the raw field, which is wrong twice:
#
#   1. It ends a value at the first ESCAPED quote. `gh pr list --search \\"a b\\" --limit 20`
#      arrived as `gh pr list --search ` -- so a `require: --limit` blocked a command that
#      carried --limit, and only when the flag sat after the quote. The require check is a
#      plain index(); it was the subject that had been cut, not the test.
#   2. It never decodes anything. A multi-line Bash command arrives with its newlines as
#      the two characters \\ and n, so a rule anchored `~(^|[;&|\\n] *)` -- where the escape
#      is a real newline to awk -- could not fire on it, ever. Nothing errored, nothing
#      warned; the rule read as enforced and was not.
#
# jit_json_fields() keeps the old quote-split parity (field[even] = key, field[even+2] =
# value) but reports each field as a RANGE of raw pieces, rejoining nothing: a quote whose
# preceding piece ends in an odd number of backslashes was escaped, so it is content and
# the field continues past it.
#
# Ranges rather than strings, because a Write payload carries the whole file body in
# tool_input.content and every literal quote in that body arrives escaped. Concatenating a
# field back together costs a copy of the whole value per escaped quote — measured at
# 359 ms for a 200 KB payload with 8000 of them, against 30 ms before and 44 ms now.
# jit_field()
# materialises a field only when a caller asks for one, and a caller only ever asks for
# the four short values it matches on.
#
# Parity is read off the single piece before the quote, never the joined field: a join
# always inserts a literal quote, so a run of backslashes can never carry across one.
#
# An escape awk cannot represent is left exactly as written rather than swallowed: eating
# the backslash of an unknown escape would turn `\\d` into `d` and hand the matcher a
# subject its author never typed. \\uXXXX is in that set deliberately -- decoding it needs
# UTF-8 assembly no awk here can be trusted to do.
# shellcheck disable=SC2034
JIT_AWK_JSON='
function jit_trailing_backslashes(s,   c, n) {
  n = length(s); c = 0
  while (c < n && substr(s, n - c, 1) == "\\") c++
  return c
}
function jit_json_fields(s, raw, fs, fe,   n, i, k) {
  n = split(s, raw, "\"")
  k = 1
  fs[1] = 1
  for (i = 1; i < n; i++) {
    # An odd number of trailing backslashes means the quote that follows was escaped, so
    # it is content and not a delimiter: the field runs on. The backslash stays put and
    # jit_unescape() collapses the pair when the field is finally materialised.
    if (jit_trailing_backslashes(raw[i]) % 2 == 1) continue
    fe[k] = i
    k++
    fs[k] = i + 1
  }
  fe[k] = n
  return k
}
# --- Session identity, for the once-per-session markers ---------------------
# Read here rather than in bash because the payload is already being parsed: a second awk
# process per hook to fetch one field would cost more than every check in this file.
#
# The value becomes a FILE NAME concatenated onto a directory, and it arrives in JSON that
# a stranger runner writes -- so it is a bare-name check of the same family as
# jit_bad_entry_file(): anything outside [A-Za-z0-9_-] is not a session id, it is a path
# fragment, and a field spanning an escaped quote is not one either. Refused means NO
# marker, never a sanitised guess at what was meant.
#
# The first session_id in the payload wins. The scan is flat, so a nested tool_input value
# could carry the string too -- first-wins keeps the field the runner itself wrote, which
# Claude Code puts at the top level, ahead of anything a command line spells.
function jit_session_key(raw, fs, fe, n,   i, k) {
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "session_id") continue
    if (fs[i+2] != fe[i+2]) return ""
    k = raw[fs[i+2]]
    if (k == "" || length(k) > 64) return ""
    if (k ~ /[^A-Za-z0-9_-]/) return ""
    return k
  }
  return ""
}
# "" means this run keeps its shown set in memory only: it still dedups within the one
# invocation, and forgets at exit. Every read and write of the set goes through the
# functions below, so the empty case is handled in one place rather than at nine.
function jit_shown_file(dir, kind, raw, fs, fe, n,   k) {
  if (dir == "") return ""
  k = jit_session_key(raw, fs, fe, n)
  if (k == "") return ""
  return dir "/" kind "-shown-" k ".txt"
}
# No close(). getline itself is safe -- an unopenable path returns -1 and a path that opens
# but cannot be read returns 0 -- but one-true-awk raises a FATAL i/o error from close() on,
# say, a directory, and raises it again at program exit if the close is dropped. Dropping it
# is still worth doing: the diagnostic then arrives after every print has been flushed rather
# than instead of them. The state-directory sweep in bash is what stops it arriving at all;
# this is the second layer, and neither one costs a fork.
#
# Nothing re-reads a marker inside one invocation, so no handle needs freeing: the process is
# about to exit.
function jit_shown_load(file, set,   line) {
  if (file == "") return
  while ((getline line < file) > 0) set[line] = 1
}
# Accumulated, never written. `print key >> file` is fatal when the path will not open, and
# it is fatal inside END -- taking the injection, the block decision and the log line with
# it, and printing an awk diagnostic into a stranger session (#50). It also followed a
# symbolic link, because awk cannot lstat (#49). Both belong to bash now: jit_shown_flush()
# hands these lines to the hook temp channel and jit_shown_apply() in the shell does the
# append, behind a `[ -L ]` and a `2>/dev/null` that awk has no way to write.
function jit_shown_mark(file, key) {
  if (file == "") return
  JIT_MARKS = JIT_MARKS file "\t" key "\n"
}
# Called once, straight after the hook writes its log line to the same file, so the marks are
# lines 2..N of a channel bash was already opening. A second temp file would be a second
# create and unlink on a path budgeted at 30-110 ms.
function jit_shown_flush(out) {
  if (JIT_MARKS != "") printf "%s", JIT_MARKS > out
}
function jit_field(raw, a, b,   o, i) {
  if (a == "" || b == "" || a > b) return ""
  if (a == b) return raw[a]
  o = raw[a]
  for (i = a + 1; i <= b; i++) o = o "\"" raw[i]
  return o
}
function jit_unescape(s,   n, i, c, nx, o) {
  if (index(s, "\\") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\\" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") o = o "\n"
    else if (nx == "t") o = o "\t"
    else if (nx == "r") o = o "\r"
    else if (nx == "b") o = o "\b"
    else if (nx == "f") o = o "\f"
    else if (nx == "\"") o = o "\""
    else if (nx == "/") o = o "/"
    else if (nx == "\\") o = o "\\"
    else { o = o c nx; i++; continue }
    i++
  }
  return o
}
'

# Hook log with timing + matches: _log_hook "pre-tool (Bash)" 42 "tool:git-push.md(git push)"
_log_hook() {
  local hook="$1"
  local ms="$2"
  local matches="${3:-(none)}"
  jit_log_write "[$(_ts)] $hook ${ms}ms | $matches"
}
