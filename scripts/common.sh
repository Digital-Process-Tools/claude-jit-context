#!/bin/bash
# Shared functions for jit-context hooks and pipeline scripts.
# Source this at the top of every script: source "$(dirname "$0")/common.sh"

# --- Splitting a path, without forking to do it (#307-follow-on) ---------------------
#
# `$(dirname X)` and `$(basename X)` were 121 of the 346 external commands one bare
# jit-dry-run.sh lint spawned over a 17-entry tree -- `$(basename "$(dirname "$tsv")")`
# is two of them, per index file, per dimension, per layer.
#
# These ASSIGN INTO A NAMED VARIABLE rather than printing, and that is the point rather
# than a style choice: a helper that printed would be read as `$(jit_path_dir "$x")`,
# which still forks a subshell to capture the output. Cheaper than fork+exec of
# /usr/bin/dirname, and not free -- and a fork is precisely what is expensive on the leg
# this is about. `printf -v` writes the answer in the caller's own shell.
#
# Naive parameter expansion is not a drop-in for either, and both wrong answers look like
# right ones. `${x%/*}` returns x UNCHANGED when there is no slash, where dirname says
# ".", so a bare filename would become its own directory. `${x%/*}` on "/c.md" is the
# empty string, which is what dirname's "/" means here and is left as-is because every
# caller reattaches a "/" itself. bash 3.2 throughout: no version gate, no fallback.
jit_path_dir() {
  case "$2" in
    */*) printf -v "$1" '%s' "${2%/*}" ;;
    # #461: the same "." written through the format, never as a lone "." argument: the
    # directory validator reads a bare "." in a hook as the hook naming a file called `.`.
    *) printf -v "$1" '.%s' "" ;;
  esac
}

jit_path_base() {
  printf -v "$1" '%s' "${2##*/}"
}

# Epoch milliseconds, without a process where the shell can answer (#307-follow-on).
#
# $EPOCHREALTIME is a bash 5.0 builtin holding "<seconds>.<microseconds>". Git Bash ships
# 5.2 and Linux CI runs 5.x, so on the two legs where a process spawn is the expensive
# thing this costs nothing at all; macOS ships bash 3.2, has no such variable, and keeps
# the perl call below. That is a fallback, not a degrade: both paths answer the same
# number, and tests/test-hook-spawn-count.sh drives each of them.
#
# Three things this parse has to get right, and each is a way to produce a plausible wrong
# number rather than an error:
#   * the separator is locale-dependent. bash writes $EPOCHREALTIME through the locale, so
#     an fr_FR session reads "1000000000,500000" -- matching on [.,] rather than on "."
#     keeps that out of arithmetic, which would otherwise be handed the whole string.
#   * the microseconds field is zero-padded, and bash reads a leading-zero literal as
#     OCTAL. 040000 base 8 is 16384, so without `10#` this answers ...016 instead of
#     ...040 -- wrong by a plausible amount, in silence.
#   * a field shorter or longer than six digits (nothing promises six) is padded and cut
#     to six rather than trusted.
# Anything that does not parse falls through to perl instead of guessing.
_ms() {
  local e="${EPOCHREALTIME:-}" s f
  case "$e" in
    *[.,]*)
      s="${e%%[.,]*}"
      f="${e##*[.,]}000000"
      f="${f:0:6}"
      case "$s$f" in
        '' | *[!0-9]*) ;;
        *)
          printf '%s\n' "$((s * 1000 + 10#$f / 1000))"
          return
          ;;
      esac
      ;;
  esac
  perl -MTime::HiRes -e 'printf("%.0f\n",Time::HiRes::time()*1000)'
}

# #266: the fallback used to be "${CLAUDE_PROJECT_DIR:-.}", which leaves JIT_BASE
# RELATIVE whenever CLAUDE_PROJECT_DIR is unset. post-tool-hook.sh's edit-marker gate
# (#244) compares JIT_BASE against `file_path` out of the tool payload with a plain
# `case` prefix test, and that field always arrives ABSOLUTE in a real payload. A
# relative pattern can never prefix-match an absolute subject, for any input -- so with
# CLAUDE_PROJECT_DIR unset, no edit under the tree was ever recognised as one, and
# stop-hook.sh (#244) then asserted "none updated" as a measured fact about a session
# where the entry genuinely was edited. That is a confident wrong answer, not a
# degrade-to-silence: this codebase's own jit-doctor.sh already treats an unset
# CLAUDE_PROJECT_DIR as a real, anticipated state worth diagnosing (its own `--base`
# resolution message spells out the fallback by name), not one closed off as
# unreachable, so the fix here is to make the fallback correct rather than to declare
# the state impossible.
#
# $PWD is a bash-maintained, always-absolute reflection of the process's own working
# directory -- no subprocess, no `pwd` fork, no dependency on JIT_BASE's target already
# existing (unlike `cd "$JIT_BASE" && pwd`, which needs the directory to be there
# first). Every hook here is launched with cwd at the project root (the same posture
# every test fixture and jit-dry-run.sh already assume when they set
# CLAUDE_PROJECT_DIR explicitly), so falling back to $PWD instead of "." keeps the
# resolved tree identical on disk and makes JIT_BASE absolute either way -- the
# comparison in post-tool-hook.sh now holds regardless of which branch of the fallback
# fired. The bare "." further back (if $PWD itself is somehow empty) preserves the
# old, already-tested degradation rather than reaching for a third fallback nothing
# here exercises.
# #461: an explicit branch, not `${CLAUDE_PROJECT_DIR:-$PWD}`. The directory validator
# reads a default expansion that nests another `$` as "a command assembled at run time".
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JIT_BASE="$CLAUDE_PROJECT_DIR/.claude/jit-context"
else
  # `pwd`, not `$PWD`: the doctor inlines this line, and the directory validator pairs a
  # read of $PWD with any runtime-built string in the same file as a credential leaving
  # the machine. The subshell costs one fork only here, and Claude Code always sets
  # CLAUDE_PROJECT_DIR, so a real session never takes this branch.
  JIT_BASE="$(pwd)/.claude/jit-context"
fi
# Exported (#378): {{dimension/layer/file.md}} transclusion resolves its target through
# ENVIRON["JIT_BASE"] inside the shared awk fragment, the same channel JIT_SYMLINKS below
# already uses and for the same reason -- a -v value has its escapes PROCESSED, so a
# checkout path carrying a backslash would arrive mangled and one carrying a newline is a
# fatal awk error raised before the program runs. Nothing before #378 read this out of
# ENVIRON, so nothing before #378 needed it exported. #424 later moved
# pre-tool-hook.sh's own tools/vocabulary getline paths onto this same ENVIRON read too
# (they used to be built in bash and handed to awk as -v tools_base=/-v vocab_base=,
# hitting the identical escape-processing defect on a backslash-bearing
# CLAUDE_PROJECT_DIR), so this export is no longer read by transclusion alone.
export JIT_BASE

# --- CLAUDE_PROJECT_DIR naming a DIFFERENT worktree than $PWD (#402) ----------------
#
# jit-doctor.sh's own advisory (#412) can only ever be RUN, by hand, after the fact --
# and #412's own reopening comment is explicit that a diagnostic nobody runs mid-session
# does not close this: "What closes this is a confirmed mechanism plus a red test, not a
# diagnostic." This is that mechanism, surfaced on the hot path where it actually bites
# rather than in a side channel.
#
# JIT_BASE above resolves from CLAUDE_PROJECT_DIR ALONE, never from $PWD -- so a session
# whose CLAUDE_PROJECT_DIR still names one git worktree while the shell sits in another
# has every hook read entries from the OTHER tree's copy of the same relative path.
# Confirmed by direct reproduction (tests/test-pre-tool-hook.sh, "#402"): an entry edited
# in the worktree the shell is actually in is not what pre-tool-hook.sh injects, because
# it never opens that copy at all.
#
# Same three-way shape as jit-doctor.sh's check, and deliberately the same wording where
# it overlaps -- a session can already cross-reference the two: an unresolvable side (no
# git, or either $PWD or CLAUDE_PROJECT_DIR not inside a git worktree) says nothing,
# because "could not tell" and "confirmed the same tree" must never render the same way.
# Only a CONFIRMED mismatch produces a line; the hooks' own "never fail hard" contract
# (paths/00-manual/hooks.md) means this can only ever ADD an advisory to what already
# gets injected, never withhold or refuse it.
jit_worktree_mismatch_line() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 0
  command -v git > /dev/null 2>&1 || return 0
  local pwd_top cpd_top
  pwd_top="$(git rev-parse --show-toplevel 2> /dev/null)"
  cpd_top="$(cd "$CLAUDE_PROJECT_DIR" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)"
  [ -n "$pwd_top" ] || return 0
  [ -n "$cpd_top" ] || return 0
  [ "$pwd_top" != "$cpd_top" ] || return 0
  printf '%s' "CLAUDE_PROJECT_DIR ($CLAUDE_PROJECT_DIR -- git worktree $cpd_top) names a DIFFERENT git worktree than the one this shell is sitting in (\$PWD ($PWD) -- git worktree $pwd_top)."
}

# --- Which host is running this hook (#252) ----------------------------------------
# scripts/host.sh is the registry; this just calls it, and guards the call the way
# every other capability in this file guards itself: a missing or unreadable
# host.sh must not take a hook down with it. paths/00-manual/hooks.md's "every
# failure path exits 0 with nothing injected" applies to this block exactly like
# everything else here, so a source failure or a function that is somehow missing
# leaves JIT_HOST at its safe default rather than aborting.
#
# JIT_HOST_REFUSAL_STATE is exported so a hook that later gates a `mode: block` row
# on host support can read it directly rather than re-deriving it -- no hook does
# that yet (see JIT_AWK_ENVELOPE below), but the value is correct and available from
# the first line any hook runs.
JIT_HOST="unknown"
JIT_HOST_REFUSAL_STATE="refusal-not-established"
# #364: the tool-name alias table, unioned across EVERY row regardless of which host
# jit_host_detect() thinks this process is -- see scripts/host.sh's own column-8
# comment for why this one lookup is deliberately not gated behind $JIT_HOST. A
# hook-not-fail-hard default of "" degrades to the identity mapping every caller of
# jit_canonical_tool() already takes for a raw name it has no alias for.
JIT_TOOL_ALIASES=""
# Parameter expansion, not a `dirname` fork: this runs on every invocation of every hook,
# on every platform, for a string operation bash does natively. `${x%/*}` returns x
# UNCHANGED when there is no slash to strip, where dirname answers ".", so the no-slash
# case is spelled out rather than left to coincide.
case "${BASH_SOURCE[0]}" in
  */*) _jit_host_sh="${BASH_SOURCE[0]%/*}/host.sh" ;;
  *) _jit_host_sh="./host.sh" ;;
esac
if [ -r "$_jit_host_sh" ]; then
  # shellcheck disable=SC1090
  source "$_jit_host_sh" 2> /dev/null \
    && JIT_HOST="$(jit_host_detect 2> /dev/null)" \
    && JIT_HOST_REFUSAL_STATE="$(jit_host_refusal_state "$JIT_HOST" 2> /dev/null)"
  [ -n "$JIT_HOST" ] || JIT_HOST="unknown"
  [ -n "$JIT_HOST_REFUSAL_STATE" ] || JIT_HOST_REFUSAL_STATE="refusal-not-established"
  # Deliberately its OWN command substitution, not chained onto the `&&` above: the
  # alias table must still be computed even when jit_host_detect()/jit_host_refusal_state()
  # somehow failed (an empty $JIT_HOST is a real, expected case -- see column 8's own
  # comment in host.sh), so this must not go dark just because an earlier link in that
  # chain did.
  JIT_TOOL_ALIASES="$(jit_all_tool_aliases 2> /dev/null)"
  [ -n "$JIT_TOOL_ALIASES" ] || JIT_TOOL_ALIASES=""
fi
export JIT_HOST JIT_HOST_REFUSAL_STATE JIT_TOOL_ALIASES
unset _jit_host_sh

# --- Entry files and layer directories that are SYMBOLIC LINKS ---------------
# PR #11 stopped an index row from NAMING a path outside its layer. It did not stop the
# entry file from BEING a link to one: the name in the index is bare, so it passes that
# check, and getline follows the link. Reproduced 2026-08-11 at all five read sites, and
# again with any directory on the way to one linked instead -- the layer, the dimension,
# .claude/jit-context/ or .claude/ -- each of which needs nothing inside the tree but the
# one link, since the linked directory carries its own 00-index.tsv. git clone recreates
# all of them, so cloning a repository is the whole attack.
#
# awk cannot lstat, and the architecture is at most a couple of awk processes per hook with
# NO per-row subprocess -- pre-path-hook.sh runs its program a second time for a Bash
# command whose tokens name real files (#85), and that is the only exception. So the lstat
# is paid ONCE per hook invocation, here, in the shell that both passes inherit, and never
# per row.
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

# --- The second thing bash can see and awk cannot: what is not a regular file (#97) ---
#
# Same channel, same walk, a different property. `getline < path` where path is a DIRECTORY
# is a FATAL i/o error on one-true-awk -- the awk macOS ships -- raised wherever the read
# happens, which for these hooks is inside END. The process dies, stdout carries no JSON at
# all, and a `block` decision already reached dies with it: the tool dimension fails OPEN.
# Driven at f63555e on awk version 20200816; GNU Awk 5.4.1 returns -1 from the same read and
# survives, which is why this cannot be tested on one engine.
#
# awk cannot stat, so it cannot answer this before reading -- and it cannot catch it after,
# because the abort is not a return value on the engine that matters. The check has to run
# in bash, which is the same conclusion session-start-hook.sh reached for a directory
# planted at a MARKER name and closed with an rmdir.
#
# It rides the sweep below rather than adding a pass: that walk already globs and lstats
# every path an index row can name, so the extra cost is one `[ -f ]` builtin per file, and
# the common case (a regular file) short-circuits on the first test.
#
# NOT ONLY DIRECTORIES, and the wider net is the point. A FIFO at an entry path does not
# abort the read -- it HANGS it, forever, in a hook that must answer inside 110 ms -- and a
# device node reads as whatever the device says. "is a regular file" is the property the
# reader actually needs, so it is the one that is asked.
#
# 4096 rather than the 8192 above, and the two sets are additive in one environment block:
# an honest tree records ZERO here, so this bounds a quantity that is anomalous at one. The
# smaller figure keeps the pair under 12 KB on Windows, where the limit that bites is the
# 32767-character process environment block.
export JIT_NONFILES=""
export JIT_NONFILES_ALL=""
JIT_NONFILES_MAX=4096

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
# Two sets out of one walk, and the name is narrower than the job: since #97 this also
# records every path at ENTRY DEPTH that is not a regular file. Both answer the same
# question -- what can bash see about this tree that awk cannot -- and both are consumed by
# jit_bad_entry_file()/jit_read_body() through ENVIRON. It stayed one function to share the
# GLOB WALK, which is the expensive half and is issued twice per depth -- not to share a
# stat: the second question needs its own `[ -f ]`, and that syscall is the 10 us per file
# measured below. A second function would have paid for the walk twice to save nothing.
jit_scan_symlinks() {
  local base="$1" f parent rel found=0
  JIT_SYMLINKS="$JIT_NL"
  JIT_SYMLINKS_ALL=""
  JIT_NONFILES="$JIT_NL"
  JIT_NONFILES_ALL=""
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
        # The walk stops here, so the non-file set is incomplete from this point on and a
        # membership test against it would clear a path nobody looked at. Its own sentinel
        # rather than a read of the link one: the two are consumed by different functions,
        # and a caller that had to know about both would be one edit away from checking one.
        JIT_NONFILES="$JIT_NL"
        JIT_NONFILES_ALL=1
        export JIT_SYMLINKS JIT_SYMLINKS_ALL JIT_NONFILES JIT_NONFILES_ALL
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
    # THE STAT FIRST, and the order was measured rather than reasoned. Not a link -- the
    # branch above returned -- so lstat and stat agree, and `[ -f ]` is TRUE for every entry
    # file in an honest tree, which short-circuits the whole block on the only path that
    # runs a thousand times. Putting the cheap-looking string test first was tried and is
    # the slower order by a wide margin -- 173 ms against a 94 ms baseline in the same
    # harness -- because it moves work ONTO that path instead of off it: a `[ -f ]` that
    # answers yes is cheaper than a parameter expansion plus a `case`, and it also skips
    # both. Reasoning about which builtin looks cheaper got this backwards.
    #
    # `[ -e ]` separates a real non-file from a glob that matched nothing -- nullglob is
    # deliberately unset here (see above), so an unmatched term arrives as its own literal.
    #
    # Measured on that layer, interleaved against the merge-base to cancel machine load,
    # with the path hook firing one rule, twice over 36 invocations a side: 73.1 ms before
    # against 84.0 ms after, then 73.0 against 82.6. About 10 us per file, which is the
    # stat, paid once per hook on the largest tree anyone has built. A tree of the size this
    # plugin is usually pointed at pays a fraction of a millisecond.
    if [ ! -f "$f" ] && [ -e "$f" ] && [ "$f" != "$base" ]; then
      # ENTRY DEPTH only. The layer directories themselves are directories in every honest
      # tree, and recording them would put a dozen paths in the set of a tree with nothing
      # wrong with it -- while answering about a path no index row can name, since
      # jit_bad_entry_file() refuses a `/` in the file-name column. What a row CAN name is
      # <base>/<dimension>/<layer>/<name>, the three-segment form below, and it is the
      # deepest this loop globs.
      rel="${f#"$base"/}"
      case "$rel" in
        */*/*)
          JIT_NONFILES="$JIT_NONFILES$f$JIT_NL"
          # Capped for the reason JIT_SYMLINKS is, and with the same posture: a set that
          # did not fit is a set that clears rows nobody looked at, so it sets a sentinel
          # instead. The sweep does not return here -- the link half of this walk is a
          # containment check and still has work to do.
          if [ "${#JIT_NONFILES}" -gt "$JIT_NONFILES_MAX" ]; then
            JIT_NONFILES="$JIT_NL"
            JIT_NONFILES_ALL=1
          fi
          ;;
      esac
    fi
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
          JIT_NONFILES="$JIT_NL"
          JIT_NONFILES_ALL=1
          export JIT_SYMLINKS JIT_SYMLINKS_ALL JIT_NONFILES JIT_NONFILES_ALL
          return 0
        fi
        ;;
    esac
  done
  export JIT_SYMLINKS JIT_SYMLINKS_ALL JIT_NONFILES JIT_NONFILES_ALL
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
# --- A sample call is not a session (#217) -------------------------------------------
#
# scripts/jit-match.sh and scripts/jit-dry-run.sh both shell out to the REAL hook to
# answer "what would fire", rather than reimplementing the matcher -- the same reason
# #205 gives for jit-match.sh, and jit-dry-run.sh set the precedent first. But logging is
# a side effect of the real hook doing its job, and a diagnostic call is not a session:
# reproduced against a fixture project with no .discovery/ directory at all, a hooks.log
# appears after one jit-match.sh or jit-dry-run.sh --prompt/--tool/--path call, built from
# whatever text the caller happened to pass it. That file is the record jit-misses.sh
# reads to report genuine vocabulary gaps, and a diagnostic probe writes exactly the shape
# of record jit-misses.sh counts as a real miss.
#
# JIT_SAMPLE_CALL is the suppression, and its safety rests on WHO can set it. This is a
# plain environment variable the calling SCRIPT exports before it execs the hook
# subprocess -- never a value read out of config.env, the JSON payload, or anything else
# that arrives with a cloned repository. A real Claude Code session invokes the hook
# through its own mechanism, which has no route to set an arbitrary env var for it; only
# jit-match.sh and jit-dry-run.sh, the two callers that ARE sample calls by construction,
# ever set this one. So a real session has no path to the same suppression -- the
# property #217 asks for by name -- and a hook that can be told not to log stays a hook
# whose log proves less only for the caller that is deliberately not a session.
if [ "${JIT_SAMPLE_CALL:-}" = "1" ]; then JIT_LOG_DISABLED=1; fi
# The mkdir is what MATERIALISES a directory through a link, so it is gated too, not just
# the append. `2>/dev/null` because a read-only or unwritable tree is a reason to say
# nothing, never a reason to print to a session's stderr.
#
# AND IT IS GATED ON THE TREE EXISTING, which is #51. `mkdir -p "$LOG_DIR"` creates every
# component on the way -- .claude, .claude/jit-context, .discovery -- so a hook running in
# a project that has never heard of this plugin materialised the whole chain, and one
# `git status` later the user has untracked files in a repository they did not change.
# Only THIS repository's .gitignore covers that path. Reproduced 2026-08-12 in an empty
# directory: `.claude/jit-context/.discovery/logs/hooks.log` and `.discovery/state`.
#
# The state mkdir below already carried `[ -d "$JIT_BASE" ]` and a comment saying a session
# with no tree should not have one materialised under its cwd. That comment was FALSE, and
# this line is why: the log ran first and created the very parent the state gate tested for.
# One of the two gates was doing nothing, and it was not the one anybody would have guessed.
#
# So the plugin is now inert in a project that has not opted in: nothing is created, nothing
# is logged, and the hooks still run, still match nothing, still exit 0. Opting in is making
# the directory -- `scripts/jit-init.sh`, or `mkdir -p .claude/jit-context/vocabulary/00-manual`
# -- and from that moment the log is written exactly as before. What is lost is the log in a
# project with no entries, which could only ever have recorded `(none)` against rules that do
# not exist; what is gained is that installing this plugin globally does not touch every
# repository you open.
#
# Disabling rather than letting the append fail: without a directory every `>>` in the
# session is an open() that fails, once per prompt and once per tool call, and a
# one-shot process cannot remember that it already failed. One builtin test here instead.
if [ ! -d "$JIT_BASE" ]; then JIT_LOG_DISABLED=1; fi
if [ "$JIT_LOG_DISABLED" = 0 ]; then
  # `[ -d ]` first, for the reason the state mkdir has one: mkdir is a fork, this file runs
  # before every hook, and after the first call of the session the directory is always there.
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2> /dev/null
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
    printf '%s\n' "$1" 2> /dev/null >> "$LOG_FILE"
  fi
}

# --- Rotating hooks.log, never deleting it (#406) ----------------------------------
# jit_log_write() opens "$LOG_FILE" BY PATH on every call, O_APPEND, and holds no
# descriptor across calls -- confirmed by reading it just above, not assumed. That is
# what makes a rename here safe under concurrent sessions: a writer holding the old
# inode (renamed out from under it, now hooks.log.1) keeps appending to THAT file
# losslessly, and the next jit_log_write() anywhere reopens whatever now sits at
# "$LOG_FILE" and creates it fresh. A logger holding a long-lived fd would keep
# writing into the rotated generation and lose every subsequent line silently; this
# one does not hold one, so it does not.
#
# Only session-start-hook.sh calls this. Every OTHER hook is on the per-call hot path
# (30-110ms budget), and a stat() on every tool call to check a byte count is not
# something that budget affords -- this hook already runs once per session and
# already computes the size for the watch-threshold warning below, so it is the one
# place a size check is free. Consequence, stated rather than left to be discovered:
# a single very long session can push the log well past JIT_CONTEXT_LOG_MAX_BYTES,
# because nothing checks again until the NEXT session starts.
#
# One generation kept: hooks.log -> hooks.log.1, and a second rotation overwrites
# whatever hooks.log.1 already held. That is a bounded, stated retention of 1, not an
# accidental deletion of "the oldest generation" the contract protects -- a SECOND
# config key for retention count was considered and dropped: one previous file is
# already enough to survive a rotation without losing the recent history
# jit-misses.sh reads (see jit-misses.sh's own handling of the marker line below),
# and a knob whose only two sane values are "1" and "a disk budget you have not
# measured" is not a knob worth asking a person to turn. Raise
# JIT_CONTEXT_LOG_MAX_BYTES instead if more history is wanted; that already bounds
# disk to 2x the threshold either way.
#
# Every failure path here returns silently and leaves the log exactly as it was:
# an unwritable directory, a `mv` that fails (races, permissions, a full disk), a
# hooks.log.1 that is a symlink or a non-regular file. Losing a rotation costs disk
# space growing a little further; refusing to run because rotation failed would cost
# the session, and hooks.md forbids that trade.
jit_log_rotate() {
  # $1: a byte count. jit_load_config() validates what it reads out of config.env, and
  # that is NOT the only way this value arrives -- exporting JIT_CONTEXT_LOG_MAX_BYTES
  # into the environment reaches session-start-hook.sh's presence check without passing
  # through jit_load_config() at all. So this validates the value it actually received
  # rather than trusting a claim about its caller. Two symptoms measured on the
  # unvalidated version, in a stranger's session: `[ "$cur" -ge abc ]` printed
  # "[: abc: integer expected" on stderr, and `-ge -5` was TRUE for every size, so a
  # negative value silently rotated on every single SessionStart -- two rotations and
  # the previous generation is gone. The noisy one was the harmless one.
  local max="$1" cur
  # Refused here rather than clamped, and a leading zero refused with the rest: `[ ]`
  # compares in decimal (`[ 9 -ge 010 ]` is true, unlike `[[ 9 -ge 010 ]]`), so "010" is
  # not misread today -- but it is written by someone who meant one of two different
  # numbers, and this function cannot tell which. Refusing keeps that ambiguity from
  # being resolved by accident here or by a later change from `[ ]` to `[[ ]]`.
  case "$max" in
    "" | *[!0-9]*) return 0 ;;
    0) ;;
    0*) return 0 ;;
  esac
  [ "$JIT_LOG_DISABLED" = 0 ] || return 0
  # "0" is a stated value for "never rotate", not a side effect of the clamp below --
  # it is checked here, explicitly, before anything that could be mistaken for one.
  [ "$max" = 0 ] && return 0
  [ -f "$LOG_FILE" ] || return 0
  # Re-checked here, not just trusted from common.sh load time above: this runs later
  # in the same process, after other code may have run, and a TOCTOU window between
  # "the log was a real file at load" and "the log is a real file right now" is
  # exactly the hazard the load-time checks above exist to close.
  [ -L "$LOG_FILE" ] && return 0
  cur="$(wc -c < "$LOG_FILE" 2> /dev/null | tr -d '[:space:]')"
  case "$cur" in "" | *[!0-9]*) return 0 ;; esac
  [ "$cur" -ge "$max" ] || return 0
  # `-L` is checked FIRST and unconditionally, never gated behind `-e`: `-e` follows the
  # link and is FALSE for a DANGLING symlink (a target that does not exist, or does not
  # resolve on this host), so a version of this check that only asked "-L" inside an
  # "if -e" branch let a dangling hooks.log.1 fall straight through to the mv below,
  # which replaces it just like it would replace an ordinary file. `-L` (lstat, not
  # stat) does not care whether the target exists -- reproduced locally by symlinking
  # hooks.log.1 to a path that does not exist: the old ordering rotated over it every
  # time, silently destroying the symlink instead of refusing.
  if [ -L "$LOG_FILE.1" ]; then
    return 0
  elif [ -e "$LOG_FILE.1" ]; then
    [ -f "$LOG_FILE.1" ] || return 0
  fi
  mv -f -- "$LOG_FILE" "$LOG_FILE.1" 2> /dev/null || return 0
  # #406: jit-misses.sh only ever reads the CURRENT log (never hooks.log.1 -- reading
  # across generations would add real complexity, a second failure surface, to a
  # parsing script whose own comments already spend a lot of care on exactly one
  # pipe-vs-no-pipe exit-status invariant; the marginal benefit is small when only one
  # generation is kept, since the window self-heals by the next rotation's worth of
  # use). So a rotation makes jit-misses.sh's next read find nothing recurring, which
  # reads exactly like "no misses" unless something says otherwise -- this marker line
  # is that something. It is deliberately NOT shaped like a hook record (no "Nms |"),
  # so it is invisible to every OTHER reader of this log; jit-misses.sh alone parses
  # it, to say plainly that its window narrowed rather than silently reporting "ok".
  jit_log_write "$(printf '[%s] hooks.log rotated at %s bytes -- records before this line are in hooks.log.1' "$(_ts)" "$cur")"
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
#
# That sentence was false from the day it was written and is true now (#51). It described
# this gate correctly and the gate did nothing, because the LOG's mkdir above ran first in
# the same file and created $JIT_BASE -- so by the time execution reached here, the
# directory being tested for had just been made by us. The log is gated on the same test
# now. Check the thing, not the citation: this comment is a claim, and the test that holds
# it up is tests/test-inert-without-tree.sh, which drives an empty project through all four
# hooks and asserts `git status` is still clean.
if [ -n "$JIT_STATE_DIR" ] && [ -d "$JIT_BASE" ] && [ ! -d "$JIT_STATE_DIR" ]; then
  if [ -d "$JIT_BASE/.discovery" ]; then
    if [ -w "$JIT_BASE/.discovery" ]; then mkdir -p "$JIT_STATE_DIR" 2> /dev/null; fi
  elif [ -w "$JIT_BASE" ]; then
    mkdir -p "$JIT_STATE_DIR" 2> /dev/null
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
# --- The boundary between the two regions of that channel ---------------------
# Until #65 there was none. Line 1 was the log line and lines 2..N were the marks, and
# every hook's log line ENDS with a field taken verbatim from the tool payload after
# jit_unescape() -- so a JSON newline escape is a real newline by the time it is written,
# and every byte the payload put after it was read back as a mark. A forged
# `path<TAB>key` marks a `block` rule as already-shown and the rule silently does not
# fire: indexed, matched, something to say, and no notice, no stderr, exit 0.
#
# What made it inert against Claude Code was the 80-byte truncation of that log field
# against a 36-character session id -- an incidental constant, not a check. Raising it,
# reordering a log field, or adding a payload-derived one turns it back on, and none of
# those reads as a security change.
#
# THE BOUNDARY CHOSEN, and why it is this one rather than the two alternatives #65 names:
#
#   * The marks are written FIRST, then this sentinel, then the log line. Payload bytes
#     therefore only ever appear AFTER the sentinel, and bash stops reading marks at the
#     first one. A payload that spells the sentinel itself achieves nothing, because that
#     copy is downstream of the real one. This is a STRUCTURAL boundary: it needs no
#     secret, so it cannot be weakened by a shorter session id or a longer log field.
#   * A count written by awk was rejected: with the log line still first, a payload
#     newline puts forged text INSIDE the counted region, so bash honours the count and
#     applies the forgery anyway.
#   * A second temp file was rejected for its second mktemp fork per hook fire on a path
#     budgeted at 30-110 ms. #62 argues for removing this channel altogether one day;
#     nothing here makes that harder -- the sentinel is one line in one function.
#
# WHEN THE BOUNDARY ITSELF IS MALFORMED. jit_marks_read() sets JIT_MARKS_OK only on
# seeing the sentinel, and jit_shown_apply() applies nothing without it. So a truncated
# or absent sentinel costs the DEDUP -- an entry may be injected a second time -- and
# never a rule. That is the direction this repo has always chosen: repeating an entry
# costs tokens, suppressing one costs the rule.
#
# The sentinel carries no TAB, and every mark line has one by construction (`f "\t" k`),
# so awk's own output can never be mistaken for it either.
JIT_MARK_END='--jit-marks-end--'
export JIT_MARK_END

# Reads the marks region off the scratch channel, stopping at the sentinel, and leaves
# the caller's stdin positioned on the log line that follows it. Nothing is applied here:
# the caller reads its log fields from the same open file descriptor, and jit_shown_apply
# runs afterwards with no stdin of its own.
JIT_MARKS_IN=()
JIT_MARKS_OK=0
jit_marks_read() {
  local line
  JIT_MARKS_IN=()
  JIT_MARKS_OK=0
  while IFS= read -r line; do
    if [ "$line" = "$JIT_MARK_END" ]; then
      JIT_MARKS_OK=1
      return 0
    fi
    JIT_MARKS_IN[${#JIT_MARKS_IN[@]}]="$line"
  done
  return 0
}

jit_shown_apply() {
  local f k name entry
  [ -n "$JIT_STATE_DIR" ] || return 0
  # No sentinel, no marks. See above: this costs dedup, never a rule.
  [ "$JIT_MARKS_OK" = 1 ] || return 0
  [ "${#JIT_MARKS_IN[@]}" -gt 0 ] || return 0
  for entry in "${JIT_MARKS_IN[@]}"; do
    f="${entry%%$'\t'*}"
    k="${entry#*$'\t'}"
    [ "$k" != "$entry" ] || continue
    [ -n "$f" ] && [ -n "$k" ] || continue
    name="${f#"$JIT_STATE_DIR"/}"
    # Unchanged means the path was not under the state directory at all.
    [ "$name" != "$f" ] || continue
    case "$name" in
      */*) continue ;;
      # The backslash, for Windows, and it is the same reason jit_bad_entry_file() gives
      # further down this file: on Git Bash the Win32 file API underneath treats it as a
      # separator, so `..\..\x` traverses there while being an ordinary character here.
      # That check did not come along when the write moved out of awk in #59, and the
      # filter admitted a byte this repository's own code says must not pass (#65).
      *\\*) continue ;;
      # #389: the third marker file, one entry per delivered block ("<raw fired
      # key><TAB><byte count>"), keyed by the same jit_shown_path(dir, "bytes", k).
      path-shown-*.txt | vocab-shown-*.txt | bytes-shown-*.txt) ;;
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
    printf '%s\n' "$k" 2> /dev/null >> "$f"
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
  JIT_TMP="$(mktemp "$d/claude-jit-XXXXXXXX" 2> /dev/null)" || JIT_TMP=""
  [ -n "$JIT_TMP" ] || return 0
  # Single-quoted on purpose: expanded when the trap fires, so it names the file this
  # process created and no other.
  # shellcheck disable=SC2064
  trap 'rm -f "$JIT_TMP"' EXIT
  return 0
}

# Local HH:MM:SS.mmm for the log line. Same split as _ms() above: answered by the shell
# where the shell can, by one perl call where it cannot.
#
# This needs TWO things _ms() does not, so it is gated on both rather than on a version
# number: $EPOCHREALTIME for the microseconds, and printf's `%()T` conversion (bash 4.2+)
# to turn epoch seconds into local wall-clock without a `date` fork. The probe below runs
# the conversion and CHECKS ITS OUTPUT rather than reading BASH_VERSINFO -- on a bash that
# does not know `%()T`, printf can succeed and write the format string through verbatim,
# so a status test alone would put "%(%H:%M:%S)T" into the log and call it a timestamp.
# It runs once at source time, not per call, and forks nothing either way.
_jit_printf_time=0
if printf -v _jit_probe '%(%H:%M:%S)T' -1 2> /dev/null; then
  case "$_jit_probe" in
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) _jit_printf_time=1 ;;
  esac
fi
unset _jit_probe

_ts() {
  local e="${EPOCHREALTIME:-}" s f out
  if [ "$_jit_printf_time" = 1 ]; then
    case "$e" in
      *[.,]*)
        s="${e%%[.,]*}"
        f="${e##*[.,]}000000"
        f="${f:0:6}"
        case "$s$f" in
          '' | *[!0-9]*) ;;
          *)
            printf -v out '%(%H:%M:%S)T' "$s"
            printf '%s.%03d\n' "$out" "$((10#$f / 1000))"
            return
            ;;
        esac
        ;;
    esac
  fi
  # #461: no perl here. Without EPOCHREALTIME (bash 3.2, macOS's own) the log line keeps
  # whole seconds and prints .000. The milliseconds were cosmetic -- durations come from
  # _ms, not from this -- and perl in this function made every script that logs a config
  # refusal (jit-doctor.sh among them) carry "perl code" beside its own $PWD read, which
  # the directory validator holds as a credential leaving the machine.
  date '+%H:%M:%S.000'
}

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
  # #388: `[A-Za-z0-9_]` below is a POSIX bracket range inside `[[ =~ ]]`, which glibc
  # matches by the active locale's collation order rather than by byte value. Turkish
  # collation (LC_ALL=tr_TR.UTF-8, and az_AZ) does not place I inside A..Z, so every real
  # setting whose name carries an I after the prefix -- JIT_CONTEXT_INJECT among them --
  # was refused as "unknown setting" under that locale alone. `local` scopes this to the
  # function and restores the caller's locale on return; nothing else in this function
  # reads a value in a way that wants the caller's collation (every value check below is
  # a literal `case` match, never a range).
  local LC_ALL=C
  local file="$1" line key value reason q rest tail lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # A CRLF checkout must parse the same as an LF one -- config.env is not covered by
    # this repo's .gitattributes, because it lives in the user's project.
    line="${line%$'\r'}"
    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
    case "$line" in
      '' | '#'*) continue ;;
      # `export KEY=VALUE` was valid while this file was sourced, so it stays valid.
      # The export itself is a no-op now: the hooks read these as shell variables.
      export[[:space:]]*)
        line="${line#export}"
        while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
        ;;
    esac

    reason=""
    case "$line" in
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        ;;
      *)
        key=""
        value=""
        reason="not a KEY=VALUE assignment"
        ;;
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
      '"'* | "'"*)
        q="${value%"${value#?}"}" # the opening quote, " or '
        rest="${value#?}"
        case "$rest" in
          *"$q"*)
            tail="${rest#*"$q"}"
            while [ "$tail" != "${tail#[[:space:]]}" ]; do tail="${tail#[[:space:]]}"; done
            case "$tail" in
              # Anything after the closing quote that is not a comment is ambiguous, so it
              # is refused rather than guessed at. Guessing is how a value goes quietly
              # wrong, which is the one outcome this whole function is written to avoid.
              '' | '#'*) value="${rest%%"$q"*}" ;;
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
    # A recognised setting whose VALUE is not one this code implements is refused too, and
    # for the same reason the unknown-key branch above exists: a setting that reads as
    # applied and is not is this repository own defect class. JIT_CONTEXT_INJECT decides
    # what every match puts in the model context, so getting it silently wrong is not a
    # cosmetic miss.
    #
    # `gated` is the value this matters most for. It was designed on issue #1 -- a small
    # model asked whether the entry is relevant before the body is spent -- and
    # deliberately NOT built, pending the pull-rate data only the summary path can produce.
    # A project that writes it today is refused and told so, rather than getting a mode
    # nobody implemented, or worse, getting `full` because an unrecognised value fell
    # through to the expensive side.
    if [ "$key" = JIT_CONTEXT_INJECT ]; then
      case "$value" in
        summary | full) ;;
        *)
          jit_config_refuse "$lineno" "not an injection mode (the modes are summary and full)"
          continue
          ;;
      esac
    fi
    # #300: JIT_CONTEXT_STOP_REPORT used to gate stop-hook.sh's model-facing report.
    # #367 moved that report to systemMessage and put it behind JIT_CONTEXT_STATUS
    # below, so this setting now gates NOTHING -- it is still parsed and refused here,
    # unchanged, so a config.env that carries it keeps working rather than being
    # reported as an unknown key. Only 0 and 1 are implemented; anything else must not
    # silently read as either value, the same reason JIT_CONTEXT_INJECT refuses an
    # unimplemented mode above rather than falling through.
    if [ "$key" = JIT_CONTEXT_STOP_REPORT ]; then
      case "$value" in
        0 | 1) ;;
        *)
          jit_config_refuse "$lineno" "not a stop-report toggle (0 or 1)"
          continue
          ;;
      esac
    fi
    # #367: JIT_CONTEXT_STATUS gates the HUMAN-facing status lines -- systemMessage, the
    # field a person actually reads -- a different audience and a different knob from
    # JIT_CONTEXT_STOP_REPORT above, which gates the now-legacy MODEL-facing report.
    # Refused the same way and for the same reason: a setting that reads as applied and
    # silently is not is this repository own defect class, and there is no safe guess
    # between "one line per fire" and "one line per session" to fall back on.
    if [ "$key" = JIT_CONTEXT_STATUS ]; then
      case "$value" in
        fired | summary | off) ;;
        *)
          jit_config_refuse "$lineno" "not a status mode (fired, summary or off)"
          continue
          ;;
      esac
    fi
    # #386: JIT_CONTEXT_MISSES gates the one SessionStart line that names the words a
    # project keeps typing with no entry behind them -- the line itself offers this as
    # the way to make it stop, so it has to exist, and it is narrower than
    # JIT_CONTEXT_STATUS=off on purpose: a person tired of that one line has not asked
    # to lose the Stop summary. Refused on any other value, same reason as above.
    if [ "$key" = JIT_CONTEXT_MISSES ]; then
      case "$value" in
        on | off) ;;
        *)
          jit_config_refuse "$lineno" "not a misses toggle (on or off)"
          continue
          ;;
      esac
    fi
    # #406: JIT_CONTEXT_LOG_MAX_BYTES -- bytes, matching JIT_CONTEXT_COLLISION_BYTES's
    # own convention rather than megabytes, so a person who has already learned one
    # size setting in this file does not have to learn a second unit for the next
    # one. "0" is a stated value meaning "never rotate", checked explicitly by
    # jit_log_rotate() rather than falling out of a clamp -- so it has to survive
    # here rather than being folded into the "malformed" branch below.
    #
    # Refused on anything but "0" or a digit string with no leading zero. The leading
    # zero is refused for ambiguity, not for octal: `[ ]` compares in decimal, so
    # `[ 9 -ge 010 ]` is true and "010" is read as ten today. It is still refused,
    # because someone writing it meant either ten or eight and nothing here can tell
    # which -- and naming the line is cheaper than guessing right. Note `[[ 9 -ge 010 ]]`
    # IS octal, so the reading changes with the test operator; refusing the value means
    # that difference can never quietly become a behaviour change.
    if [ "$key" = JIT_CONTEXT_LOG_MAX_BYTES ]; then
      case "$value" in
        0) ;;
        [1-9]*)
          case "$value" in
            *[!0-9]*)
              jit_config_refuse "$lineno" "not a byte count (0, or digits with no leading zero)"
              continue
              ;;
          esac
          ;;
        *)
          jit_config_refuse "$lineno" "not a byte count (0, or digits with no leading zero)"
          continue
          ;;
      esac
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

# --- What a match injects ----------------------------------------------------
# A match injects the entry BODY, whole. The cost of that is asymmetric and the asymmetry
# is the defect, not the accuracy: a miss costs nothing and a false positive costs the
# whole entry. The case on issue #1 is a 14.9 KB reference arriving on the word `tag` in
# a conversation about YAML metadata -- a match that was word-bounded, correctly
# evaluated, and 15,000 tokens wrong.
#
# `summary` is the answer to that: the entry title plus its author-written
# `description:`, roughly 20 tokens, and the agent decides whether to read the file.
# Being wrong gets cheap instead of the matcher getting cleverer.
#
# It is NOT the default, and the reason is upgrade safety rather than doubt about the
# trade. A project that installed this before the mode existed has entries that arrive
# whole and agents that behave as though they will. Flipping that under them, on an
# upgrade nobody read the notes for, takes away knowledge the project already relies on
# and does it silently -- an absence produced by the tool, read as an absence in the
# world, which is the one failure this repository exists to name. So `full` is what a
# tree gets when it has said nothing, and `summary` is where a project goes once it has
# looked at what a match costs and decided the trade is worth it.
#
# DEFAULT-FULL IS A STAGE, NOT A DESTINATION. The risk it carries is exactly issue #1s
# own objection one level up: a setting nobody revisits stays at maximum by inertia, and
# "we will move to summary later" becomes a sentence nobody ever acts on. The exit is
# meant to be measurable, so rebuild-tsv.sh prints what one match costs on THIS tree --
# largest, median, and what those same entries would cost summarised -- and names the
# entries that carry no `description:` yet, which is the work between a tree and being
# able to flip. When that count is zero and the numbers look worth it, flip it.
#
# WHO CHOOSES is the other half, and it is the part a later reader will get wrong. Issue
# #1 rejects an `inject: full | summary` frontmatter flag, in its own body:
#
#     The value would be self-assessed by whoever writes the entry, and every author
#     believes their own entry is the critical one. Within a month every entry is `full`
#     and the flag has bought nothing.
#
# That objection is about the CHOOSER, and it still stands. The default here is set by
# the PROJECT OWNER in config.env -- the person whose context window fills up -- not by
# the author of an entry. The per-entry `inject:` override is still an author choice, and
# it is deliberate: it overrides a default the project set, and rebuild-tsv.sh counts the
# population at build time, so an author marking everything `full` is marking it against
# a number somebody reads.
#
# If you are about to revert this as "the mode flag we already rejected": check who does
# the choosing first.
JIT_INJECT="${JIT_CONTEXT_INJECT:-full}"
# The config.env path already refused an unknown value by line number. This clamp is for
# every OTHER way the variable can arrive -- an exported environment variable from a
# runner or a test -- where there is no line to name. Refusing to run would be the fail
# hard this file forbids, and honouring an unknown word would be worse than either.
#
# It falls back to `full`, which is the SAFE direction for a fallback: a project whose
# setting could not be honoured keeps what it had rather than quietly losing it.
case "$JIT_INJECT" in
  summary | full) ;;
  *) JIT_INJECT=full ;;
esac

# #300: JIT_CONTEXT_STOP_REPORT gated the whole model-facing report stop-hook.sh used
# to emit; #367 retired that report (it moved to systemMessage, gated by
# JIT_CONTEXT_STATUS below) and nothing reads this variable any more. Kept, parsed and
# clamped exactly as before so an existing config.env keeps loading. Off by default -- the opposite fallback direction from JIT_INJECT above, and
# deliberately so: JIT_INJECT defaults to `full` for upgrade safety (a tree that
# already relies on the whole-body behaviour must not lose it silently), while this
# setting is brand new, so there is no existing behaviour to preserve by defaulting on.
# #291/#295's own conclusion was that the report has no audience until a project asks
# for it -- an installed plugin that says nothing until asked is the correct posture,
# so absent, `0`, and any value this code cannot honour all fall to the same off state.
# The config.env path above already refuses an unimplemented value by line number and
# never lets it reach here; this clamp is for every OTHER way the variable can arrive
# (an exported environment variable from a runner or a test), the same shape JIT_INJECT
# already gives its own clamp just above.
JIT_STOP_REPORT="${JIT_CONTEXT_STOP_REPORT:-0}"
case "$JIT_STOP_REPORT" in
  0 | 1) ;;
  *) JIT_STOP_REPORT=0 ;;
esac

# #367: JIT_CONTEXT_STATUS gates the human-facing systemMessage lines -- default
# summary, the cheapest thing worth having on an upgrade nobody asked for this: one
# line at the end of a session, rather than one per injection on a busy turn (the
# noise budget the issue itself flags as needing design, not assumption). The
# config.env path above already refuses an unimplemented value by line number; this
# clamp covers every other way the variable can arrive, the same shape JIT_INJECT and
# JIT_STOP_REPORT give their own clamp just above.
JIT_STATUS="${JIT_CONTEXT_STATUS:-summary}"
case "$JIT_STATUS" in
  fired | summary | off) ;;
  *) JIT_STATUS=summary ;;
esac

# #386: the SessionStart recurring-words line, on its own switch (see the config.env
# parser above for why it is not folded into JIT_CONTEXT_STATUS). Same clamp shape.
JIT_MISSES="${JIT_CONTEXT_MISSES:-on}"
case "$JIT_MISSES" in
  on | off) ;;
  *) JIT_MISSES=on ;;
esac

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
#
# `LC_ALL=C` on the invocation (#195, #196): this awk matches a regex against every line
# of an entry file, and neither caller pinned the locale before now -- the comment that
# used to claim otherwise, in rebuild-tsv.sh's bad-bytes section, was describing a pin
# that did not exist. Under a UTF-8 locale, one-true-awk aborts the whole program the
# first time that match lands on a record carrying an invalid byte, so a `match:` saved
# in ISO-8859-1 made the entry vanish from the index instead of being written through and
# refused at load. Under `C` the same awk has nothing to decode and copies the byte out
# verbatim on all three engines, which is what lets report_bad_bytes() catch it downstream.
JIT_FM_NL="
"

# --- The awk program-fragment library (#442) ----------------------------------------
# Every JIT_AWK_* variable that used to be defined inline here (JIT_AWK_FRONTMATTER,
# JIT_AWK_GUARD, JIT_AWK_ENTRY, JIT_AWK_INJECT, JIT_AWK_FOLD, JIT_AWK_HEREDOC,
# JIT_AWK_JSON, JIT_AWK_BLK_BUILD, JIT_AWK_BLOCKS, JIT_AWK_ENVELOPE,
# JIT_AWK_ENVELOPE_SYSMSG) -- each one a chunk of awk source as a single-quoted bash
# string, with its own function-level documentation -- now lives in
# scripts/common-awk.sh, split out so common.sh lands under the Anthropic plugin
# directory own 256 KiB per-file limit for the release branch
# (tests/test-release-branch-437.sh), the same constraint data/generic-words.txt was
# already split for (#437). BYTE-IDENTICAL move: nothing below was rewritten.
#
# Sourced the same way common.sh sources scripts/host.sh (#252): a missing or
# unreadable common-awk.sh must not fail a hook hard. If sourcing this fails, every
# JIT_AWK_* variable stays unset, so a hook composing them gets an awk program
# missing function definitions -- indistinguishable, to the awk engine, from the
# crash shapes #393/#397/#400/#403 already hardened this codebase against (mawk
# refuses such a program at PARSE time with nothing on stdout; one-true-awk and gawk
# fail at the first undefined-function CALL instead). jit_awk_capture()/
# jit_awk_dispatch() (below, in this same file) already turn exactly that shape into
# a safe, decisive answer: jit_awk_crash_block() (refuse the call) for
# pre-tool-hook.sh, which cannot verify and has something to refuse, or
# jit_awk_empty_ok() ("{}", the same answer a genuine no-match produces) for the
# three injection-only hooks, which have nothing to refuse. No new fallback logic
# needed here beyond the readability guard host.sh already demonstrates.
case "${BASH_SOURCE[0]}" in
  */*) _jit_common_awk_sh="${BASH_SOURCE[0]%/*}/common-awk.sh" ;;
  *) _jit_common_awk_sh="./common-awk.sh" ;;
esac
if [ -r "$_jit_common_awk_sh" ]; then
  # shellcheck disable=SC1090
  source "$_jit_common_awk_sh" 2> /dev/null
fi
unset _jit_common_awk_sh

# Every requested field of one entry, in one process. VAR receives a memo string, one
# `<field><TAB><value>` record per line; read it with jit_fm_get(), which forks nothing.
jit_frontmatter_many() { # VAR, entry file, field...
  # A positional slice rather than a two-step positional discard. The other spelling makes
  # tests/test-arg-flag-values.sh classify this file as a flag parser whose argument loop
  # it cannot read, and report it as a rotted parser -- it is right to flag that shape in a
  # CLI, and this is a sourced library with no flags at all. The honest fix is to write
  # what is meant rather than to teach the classifier an exception. Its sweep reads the
  # source as text, comments included, so the token itself is not written here either.
  local _v="$1" _file="$2" _fields="${*:3}"
  printf -v "$_v" '%s%s' "$JIT_FM_NL" \
    "$(LC_ALL=C awk -v fl="$_fields" "$JIT_AWK_FRONTMATTER" "$_file")"
}

# Reads one field out of a jit_frontmatter_many() memo. Parameter expansion only -- a fork
# here would be one per field, which is the cost jit_frontmatter_many() just removed.
# A field the entry does not carry is a miss: VAR is left empty and the status is 0 --
# unified with jit_frontmatter()'s own `[ -n "$_out" ] || return 0` on the same case
# (#339: this comment used to claim the two already agreed, while the code below
# returned 1). No caller checks either function's exit status today -- every call site
# in jit-dry-run.sh tests the OUTPUT variable with `[ -n "$var" ]` instead -- so a
# nonzero miss bought nothing and was one `set -e` away from being a landmine.
jit_fm_get() { # VAR, memo, field
  local _key="$JIT_FM_NL$3	" _rest
  case "$2" in
    *"$_key"*)
      _rest="${2#*"$_key"}"
      printf -v "$1" '%s' "${_rest%%"$JIT_FM_NL"*}"
      ;;
    *) printf -v "$1" '%s' "" ;;
  esac
}

jit_frontmatter() {
  # $1 field name, $2 entry file. One field, bare value, unchanged contract -- the shared
  # program above is what applies the rules.
  local _out
  _out="$(LC_ALL=C awk -v fl="$1" "$JIT_AWK_FRONTMATTER" "$2")"
  [ -n "$_out" ] || return 0
  # The trailing newline is part of the contract, not an accident of the old
  # implementation: this used to print through awk's `print`, every caller reads it
  # through $( ) which strips it, and tests/test-entry-bytes.sh asserts on the raw bytes
  # and so sees it. Dropping it broke 54 assertions there and no caller.
  printf '%s\n' "${_out#*	}"
}

# The only mode: values the hooks give meaning to (docs/writing-entries.md;
# pre-tool-hook.sh reads "block" and "once" as substrings of this column, everything
# else defaults to a reminder). Shared between rebuild-tsv.sh, which refuses to index a
# tools row whose ASSEMBLED mode does not match this, and jit-dry-run.sh's
# check_index_current(), which has to agree on the same refusal or it reports a
# correctly-skipped row as merely stale (#347) -- a single copy here is what keeps that
# agreement from drifting the way it did before #347 was filed.
# "remind" is accepted even though the hook never tests for it -- it is the field's own
# documented default spelling and an author may write it explicitly.
# Consumed by rebuild-tsv.sh and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_VALID_MODE_RE='^(remind|block|once)(,(remind|block|once))*$'

# A requires: value is free text out of a committed file, and jit_missing_requires()
# below hands the accumulated list across an exec boundary as a single awk -v argument
# (#427). A bare binary name is the only thing that column means (#203s own comment: a
# single name, never a list), so anything else is refused outright rather than carried
# forward at all -- the same discipline JIT_VALID_MODE_RE already applies to mode:, and
# for the same two reasons: an unbounded or hostile value should be looked at, not
# quietly indexed, and 255 bytes is generous for a real binary name while still bounding
# what one row can contribute to a list that many rows share.
# Shared between rebuild-tsv.sh, which refuses to index a tools row whose requires:
# value does not match this, and jit_missing_requires(), which refuses to carry a
# value that does not match this forward even out of an already-committed index --
# the index-time refusal only protects a FUTURE rebuild by this repository own
# maintainer; a clone reads whatever is already committed.
# Consumed by rebuild-tsv.sh; shellcheck cannot see that from here.
# shellcheck disable=SC2034
JIT_VALID_REQUIRES_RE='^[A-Za-z0-9._+-]{1,255}$'

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
      *) out="${out}[$c]" ;;
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
  case "$body" in '@'*) ;; *)
    printf '%s' "$raw"
    return 0
    ;;
  esac

  name="${body#@}"
  args=""
  case "$name" in
    *[[:space:]]*)
      args="${name#*[[:space:]]}"
      name="${name%%[[:space:]]*}"
      ;;
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
    invocation) out="$out$JIT_MACRO_END" ;;
    invocation-quoted-arg) out="${out}[[:space:]]+${JIT_MACRO_OPT}['\"]" ;;
  esac

  # The ~ is not optional and is not copied from the author: a tools row without it is a
  # substring rule, and a substring rule whose text is an ERE can never match anything.
  printf '~%s' "$out"
}

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

# --- The log LINE is bounded; the information in it is not (#64) --------------
# Hook log with timing + matches:
#   _log_hook "pre-tool (Bash)" 42 "tool:git-push.md(git push)" "[shown:1] << git push"
#
# The matches field is built inside awk by appending one item per matched or refused index
# row, and nothing bounded it. Every row of a 400-row index that matches contributes a
# name, a pattern and punctuation, so the line grew with the index -- measured on this
# branch at 16 KB, 18 KB, 19 KB and 22 KB for the four hooks against a 400-row fixture,
# once per prompt and once per tool call. The index is a committed file, so its length is
# chosen by whoever wrote the repository, which is the same shape as #36 and #38.
#
# WHY THE OBVIOUS FIX IS WRONG, and it is worth reading before changing this. hooks.log is
# not a debug convenience: #28 and #35 removed the index file-name column and the mode
# column from MODEL context precisely because they are unvalidated text from a clone, and
# this file -- on the disk of the person who wrote the tree, read by a person, never by a
# model -- is where they still go. tests/test-security.sh asserts that relationship
# directly, both hooks. Capping the INFORMATION would spend the tree author's only
# debugging channel to save disk, which is not the resource under pressure.
#
# So the LINE is capped and the information is accounted for: what fits is written whole,
# and the exact number of bytes that did not fit is stated. Not an item count -- an item
# may itself contain ", ", so counting separators here would report a number that is
# sometimes wrong, and a report that reads as complete and is not is this repository own
# defect class. jit-dry-run.sh prints the whole tree on demand and the notice says so.
#
# WHY HERE and not at the 33 append sites in awk: this is the single writer, it is the
# only place that sees the assembled line, and a future field added by a future hook is
# bounded by it without anybody remembering to. What awk builds in memory is unchanged --
# the resource #64 measured is the file on disk.
#
# THE TAIL IS A SEPARATE ARGUMENT and is not capped. `[shown:N] << <path or prompt>` is
# already bounded to 80 bytes inside awk, and it is what jit-misses.sh parses; cutting the
# line at a byte count would have taken it off exactly the lines that are hardest to read
# without it. A cut that removed the field the downstream tool reads would be #50's lesson
# reappearing in the tool that reports #50.
#
# LC_ALL=C so `${#s}` and `${s:0:n}` count BYTES. Without it bash counts characters in the
# session locale, and a UTF-8 entry name would make a "2048" cap admit up to four times
# that. `local` restores whatever the caller had on return.
JIT_LOG_MATCHES_MAX=2048
# #461: the `<<` that separates a log line's tail, spelled so that no source line types
# two `<` in a row. Once the release build inlines this into a hook, the directory
# validator reads a typed `<<`, even inside quotes, as a here-document it cannot close.
# shellcheck disable=SC2034  # read by the hooks that source this file
JIT_LOG_ARROW='<''<'
_log_hook() {
  local LC_ALL=C
  local hook="$1"
  local ms="$2"
  local matches="${3:-(none)}"
  local tail="${4:-}"
  local dropped head
  if [ "${#matches}" -gt "$JIT_LOG_MATCHES_MAX" ]; then
    head="${matches:0:$JIT_LOG_MATCHES_MAX}"
    # Back up to the last `, ` inside what was kept, which is USUALLY the item separator and
    # therefore usually leaves whole names in the line rather than half of one.
    #
    # Usually, not always, and the marker below is worded for the difference. `, ` is not a
    # byte an item cannot carry: jit_bad_entry_file() refuses `/`, `\`, `.` and `..` and
    # nothing else, so `a, b.md` is a legal bare entry file name, and a match pattern is
    # free-form. A name like that straddling the cut backs up to its own internal comma and
    # leaves `a, ` reading exactly like a complete item. Driven: 2000 bytes of filler then
    # `AAAA, BBBB-....md` cuts to `..., AAAA, ` and drops 30 bytes.
    #
    # The COUNT is unaffected -- it is taken from what was actually kept, three lines down --
    # so the line still accounts for every byte. What cannot be promised is that the last
    # thing before the marker is whole, and a comment claiming otherwise would be the kind
    # of confident sentence this repository keeps catching itself writing. Making it true
    # would mean a separator no item can contain, which is a change at all 33 append sites
    # inside awk rather than here.
    case "$head" in *", "*) head="${head%, *}, " ;; esac
    # AFTER the back-up, and that ordering is the whole point. Computed against the ceiling
    # instead, the count omits the partial item the back-up just discarded -- so the line
    # would under-report by up to one entry name while reading as exact. That is the defect
    # class this cap exists to avoid, reintroduced by the line meant to avoid it.
    dropped=$((${#matches} - ${#head}))
    matches="${head}[+$dropped bytes not listed here, and the item before this marker may be a fragment; this line is capped at ${JIT_LOG_MATCHES_MAX} bytes -- the jit-dry-run tool prints the whole tree]"
  fi
  jit_log_write "[$(_ts)] $hook ${ms}ms | $matches${tail:+ $tail}"
}

# --- What a MAINTAINER TOOL may say about a name the clone chose (#113, #124) -----------
#
# jit_row_id() above is the hooks' answer to this question: a refused row is named by
# POSITION and its file-name column is never quoted, because that column arrives with the
# repository and the notice fires with no rule having matched.
#
# rebuild-tsv.sh and jit-dry-run.sh cannot take that answer whole. Their reader is the
# author of the tree, the file name is most of the actionable content of every report they
# print, and a maintainer tool that will not tell you WHICH entry is broken has thrown away
# the reason it exists. So they keep the name when the name is a NAME, and withhold it when
# it is prose:
#
#   ^[A-Za-z0-9][A-Za-z0-9._-]*$, at most 64 bytes
#
# The set carries no space, which is what separates a name from a sentence -- no length cap
# does, since `Run rm -rf ~` is twelve bytes. The cap is only there to keep a 4 KB name out
# of a report. The set also excludes the NEWLINE, and that half was never a judgement call:
# a name carrying one forged a whole report line in the voice of the tool, reproduced in
# both tools (#113 in rebuild-tsv.sh, #124 in jit-dry-run.sh).
#
# The cost is real and accepted. An author whose entry is honestly called `my rule.md` sees
# the placeholder, `ls` the layer named beside it, and the odd name is the one that stands
# out. A worse report for a rare legitimate name, in exchange for a report that cannot
# carry a payload at all.
#
# Withholding is a REPORT decision and nothing else. The row is still indexed under the
# real name, the rule still fires, and the linter still lints it -- tests/test-report-names.sh
# and tests/test-dry-run-names.sh both pin that, because a fix that stopped reading the
# entry would satisfy every negative assertion for free.
#
# It lives HERE, and not in the tool that needed it first, for the reason this repo keeps
# rediscovering: two answers to one question drift, and the drift is invisible until a name
# printed by one tool is withheld by the other. Both tools source this file.
#
# The test that pins a second bash definition to this one is tests/test-dry-run-names.sh,
# which extracts any `jit_report_name() {` still living in rebuild-tsv.sh and drives both
# through every boundary of the set. This sentence used to name tests/test-report-names.sh
# instead, which pins what the rebuild REPORTS and has never compared two definitions --
# the same citation-without-a-check that #124 found here in the first place. The extraction
# says so out loud when it finds nothing rather than passing, so it does not go quiet when
# that copy is deleted.
#
# One transliteration is unavoidable and stays whatever happens to the bash copy:
# rebuild-tsv.sh builds three of its reports inside awk, awk cannot source a bash function,
# and JIT_AWK_REPORT_NAME carries the same rule a second time in awk. Nothing compares
# those two, so a change to the character set here has to be made there by hand.
#
# Exported for the awk half in rebuild-tsv.sh, which reads it out of ENVIRON.
export JIT_NAME_WITHHELD='<withheld: not a plain name>'

# --- Which layer directories the matcher reads (#176) ------------------------
# The three hooks used to enumerate their layers from a literal:
#
#   split("00-manual 10-auto 20-grouped 30-crosscutting", layers, " ")
#   for (li = 1; li <= 4; li++)
#
# -- a string in three files with the bound written beside it as a SECOND literal, and in
# the tools dimension not even that: pre-tool-hook.sh read $JIT_BASE/tools/00-manual
# directly and no other layer at all. rebuild-tsv.sh has always globbed `<dimension>/*/`,
# so a layer outside that string was written by its author, indexed by the rebuild, and
# counted by every report this repository prints -- and read by nothing. claude-oss filed
# #176 after shipping five entries into a `01-oss` layer that had never fired anywhere.
#
# So the directories are ENUMERATED, and the ordering falls out for free: the numeric
# prefixes are what the layer scheme is for, and a C-collated glob puts 00-manual before
# 01-oss before 10-auto without anything here having to sort. `local LC_ALL=C` for the
# duration, the same technique and the same reason as jit_report_name() below -- under a
# UTF-8 locale the collation that orders the glob is not the byte order the prefixes were
# designed around.
#
# NO SUBSHELL, for the reason jit_scan_symlinks() has none: this runs twice per hook
# invocation inside a 30-110 ms budget, and a fork per dimension is a cost the whole
# design exists to avoid. Globals out, like that function, rather than a captured stdout.
#
# THE NAME IS ATTACKER-CHOSEN TEXT. A layer directory arrives with the clone exactly as an
# entry file name does, and the comment above jit_report_name() cites the three findings
# where such a name reached a report (#35, #113, #124). Two consequences here:
#
#   - The list is handed to awk through `-v`, space-separated, so a name carrying a space
#     would inject a list entry and a name carrying a newline is the fatal "newline in
#     string" that JIT_CONFIG_REFUSED is routed around the environment to avoid. Refusing
#     the name is what makes the plain separator safe; nothing downstream re-checks it.
#   - A refused layer is never named in the report. It is named BY POSITION in the glob,
#     which is what an author `ls` next.
#
# The accepted set is jit_report_name()s set, character for character, and it has to be:
# a name that cannot be reported must not be silently loaded either, and a name that is
# refused here must be reportable when some other surface prints it. It is inlined rather
# than called because calling costs a fork per layer. tests/test-layer-enumeration.sh
# section I drives the same boundary names through both and fails if they ever disagree.
#
# THE THIRD STATE IS THE POINT. A layer that exists and cannot be read is NAMED -- in what
# the hook injects and in the log -- rather than skipped in silence. That is the whole of
# #176: a rule that never matched and a rule that never loaded rendered identically, and
# every signal available to the reporter said the layer was healthy.
JIT_LAYERS_MAX=64
JIT_LAYERS_REFUSED_MAX=4096
JIT_LAYERS=""
export JIT_LAYERS_REFUSED=""
export JIT_LAYERS_REFUSED_N=0
JIT_LAYERS_REFUSED_CUT=0

# One appender, so there is one place the byte cap is applied -- jit_config_refuse()
# exactly, and for the same reason: the number of layer directories is chosen by the
# repository being cloned, and an unbounded list pushes the environment past ARG_MAX,
# after which every exec fails and the hook emits nothing while exiting 0.
#
# The COUNT is not capped, only the list. A truncated list that also under-counted would
# be a report that reads as complete and is not, which is the defect this notice exists
# to end rather than to re-commit one layer up.
jit_layer_refuse() {
  # $1 dimension label (a constant written by the caller), $2 what could not be done
  JIT_LAYERS_REFUSED_N=$((JIT_LAYERS_REFUSED_N + 1))
  if [ "${#JIT_LAYERS_REFUSED}" -gt "$JIT_LAYERS_REFUSED_MAX" ]; then
    if [ "$JIT_LAYERS_REFUSED_CUT" = 0 ]; then
      JIT_LAYERS_REFUSED_CUT=1
      JIT_LAYERS_REFUSED="$JIT_LAYERS_REFUSED$JIT_NL- the remaining refused layer directories are not listed here; the count above is the whole total"
    fi
    return 0
  fi
  JIT_LAYERS_REFUSED="$JIT_LAYERS_REFUSED${JIT_LAYERS_REFUSED:+$JIT_NL}- $1: $2"
}

# Sets JIT_LAYERS to a space-separated list of the layer directory names under one
# dimension, in scan order. Appends to JIT_LAYERS_REFUSED, which ACCUMULATES across the
# calls in one hook process -- pre-path-hook.sh scans two dimensions, and their lists can
# legitimately differ, but their refusals are one notice.
jit_scan_layers() {
  # $1 dimension base directory, $2 dimension label (a constant written by the caller)
  local base="$1" dim="$2" d name tsv seen=0 kept=0 cut=0
  # See above. `local` restores the caller locale on return.
  local LC_ALL=C
  JIT_LAYERS=""
  # nullglob is deliberately not set, for the reason jit_scan_symlinks() gives: toggling a
  # shell option in a sourced file changes it for whatever sourced us. An unmatched glob
  # stays literal and falls out of the `[ -d ]` on its own.
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    name="${d##*/}"
    seen=$((seen + 1))

    # THE BOUND IS REPORTED, NOT TAKEN QUIETLY. The loop does not break: the glob is
    # already expanded, so counting the rest is free, and a notice that said "64 layers
    # were read" without saying how many were not would be this repositorys own defect
    # class wearing a fix as a disguise.
    if [ "$kept" -ge "$JIT_LAYERS_MAX" ]; then
      if [ "$cut" = 0 ]; then
        cut=1
        jit_layer_refuse "$dim" "the layer directories after the first $JIT_LAYERS_MAX were not read"
      fi
      continue
    fi

    # jit_report_name()s set, inlined. See above for why it is not called.
    case "$name" in
      '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
        jit_layer_refuse "$dim" "layer directory $seen was not read: the directory name is not a plain name"
        continue
        ;;
    esac
    if [ "${#name}" -gt 64 ]; then
      jit_layer_refuse "$dim" "layer directory $seen was not read: the directory name is longer than 64 bytes"
      continue
    fi

    # A directory the process cannot open is the third state in its most literal form.
    # awk would getline -1 on every index inside it and report nothing, which is
    # indistinguishable from a layer that holds no rules.
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then
      jit_layer_refuse "$dim" "layer directory $seen was not read: the directory could not be opened"
      continue
    fi
    # And the indexes themselves. Same verdict for the same reason -- an unreadable
    # 00-index.tsv is a layer whose every rule is inert, reported by nobody. The whole
    # layer is refused rather than the one index: two indexes are built out of a
    # vocabulary layer, and a partial read there is a partial rule set with nothing
    # saying so.
    # NAMED, not globbed, and the reason is a measurement. `for tsv in "$d"/*.tsv` reads
    # the WHOLE layer directory, and a layer directory holds one .md per rule -- so that
    # form costs the size of the rule set to answer a question about two files. Measured
    # on a 300-entry layer, nine interleaved rounds of 400 scans: 1.7-3.9 ms per scan
    # globbing against 0.8-1.3 ms naming the leaves. The machine was noisy enough that
    # only the ratio is worth quoting, and the ratio is about three to one, against a hook
    # budget of 30-110 ms with two of these calls in it.
    #
    # These two are the only index leaves rebuild-tsv.sh writes -- 00-index.tsv in every
    # dimension, 01-paths.tsv in vocabulary -- and a .tsv nothing reads is not this check
    # business. A third index leaf added later has to be added here too, and that is the
    # cost of the named form.
    #
    # `if`, not a bare `&&`: a `&&` whose left side is false leaves the loop body ending
    # on a non-zero status, which is one `set -e` in a future caller away from a hook that
    # stops mid-scan. jit-dry-run.sh report_layer() records the same trap.
    for tsv in "$d/00-index.tsv" "$d/01-paths.tsv"; do
      [ -e "$tsv" ] || continue
      if [ ! -r "$tsv" ]; then
        jit_layer_refuse "$dim" "layer directory $seen was not read: an index inside it could not be opened"
        continue 2
      fi
    done

    JIT_LAYERS="$JIT_LAYERS${JIT_LAYERS:+ }$name"
    kept=$((kept + 1))
  done
}

# #233: the injection footer names an entry's own age -- "last edited 170d ago" -- so a
# rule leaned on for months without a touch reads as the highest-probability stale entry
# in the shelf, at the one moment nothing else is competing for attention. Only
# 00-manual is asked, because that is the only layer the footer already tells an author
# to go fix; a generated layer has no author to send there.
#
# WHY THIS IS A BASH SCAN, NOT AN AWK STAT. Neither one-true-awk, gawk nor mawk carries
# a portable stat() this repo can rely on across the three CI platforms, and the
# `common.sh` lstat comment above jit_scan_layers() already states the rule this follows:
# at most a couple of subprocesses per hook, and NEVER one per row of an index that can
# hold hundreds. So this reads mtimes the same way jit_scan_layers() reads the directory
# itself -- once, in bash, before awk ever runs -- with ONE perl process per 00-manual
# layer directory, not one per matched entry. perl is already a dependency of this
# script (see _ms() at the top of every hook), so this adds no new one.
#
# The result is a table, not a lookup: every file in the directory gets an age, whether
# or not this session's keywords will ever match it. That is deliberately proportionate
# to jit_scan_layers()'s own cost, which already reads the whole directory listing for
# every hook invocation -- a 00-manual layer is hand-authored and stays small by
# construction, unlike 10-auto/20-grouped/30-crosscutting, which this never touches.
#
# JIT_ENTRY_AGES is exported (like JIT_LAYERS_REFUSED) because awk reads it through
# ENVIRON, not through -v: entries live at least one to a line, and a newline inside an
# awk -v value is a fatal error raised before the program runs at all.
JIT_ENTRY_AGES_MAX=8192
export JIT_ENTRY_AGES=""

# Sets JIT_ENTRY_AGES to "<layer>/<file><TAB><days>\n..." for every regular, non-symlink
# file in every scanned layer whose name contains "00-manual", under the base directory
# just scanned by jit_scan_layers() (its vetted, already-validated $JIT_LAYERS is what
# this reads -- never a fresh glob of its own, so a layer name jit_scan_layers() refused
# is never opened here either).
#
# KNOWN LIMITATION, NOT FIXED HERE (#233 review): -M reads the FILESYSTEM mtime, and a
# fresh `git clone` sets every file's mtime to checkout time, not its last commit time.
# So the very sessions this footer is aimed at -- a new contributor's first clone, a CI
# leg, a fresh plugin install -- see "last edited 0d ago" on entries that have not been
# touched in months, which is the opposite of the signal #233 asks for. Fixing this
# properly means reading commit history instead of the filesystem (`git log`), which is
# a materially different mechanism -- slower, requires a `.git` to exist at all, and is
# its own portability question across the three CI platforms -- so it is reported rather
# than silently patched in. A checkout whose mtimes were deliberately preserved (an
# archive extracted with `tar --touch`, a filesystem that keeps birth time) is unaffected
# either way, since this only ever reads the mtime it is given.
jit_scan_entry_ages() {
  # $1 dimension base directory -- the same one just passed to jit_scan_layers()
  local base="$1" layer d out
  local LC_ALL=C
  JIT_ENTRY_AGES=""
  # #243: the window, in seconds, inside which every mtime in a 00-manual layer has to
  # fall for this run to treat the whole layer as a checkout rather than real editing
  # history. A real author touching two files by hand almost never lands them this
  # close together; `git clone`, a plugin install and a CI checkout always do. Bounded
  # to digits only -- an override that is not a plain number falls back to the default
  # rather than being handed to arithmetic below.
  local window="${JIT_CONTEXT_CHECKOUT_WINDOW_S:-${DYNAMIC_RULES_CHECKOUT_WINDOW_S:-5}}"
  case "$window" in '' | *[!0-9]*) window=5 ;; esac
  for layer in $JIT_LAYERS; do
    case "$layer" in
      *00-manual*) ;;
      *) continue ;;
    esac
    d="$base/$layer"
    [ -d "$d" ] || continue
    # A single perl process per 00-manual layer (there is ordinarily exactly one),
    # never per row and never per match. -M is days-since-mtime relative to the
    # process's own start time, floored towards zero: a file newer than "now" (a clock
    # skew, a checkout that rewrote mtimes forward) reads as 0d rather than a negative
    # age nobody asked to see. Symlinked entries are skipped -- jit_bad_entry_file()
    # already refuses them as entries, so an age for one would describe a file this
    # tree never actually injects.
    #
    # A third column, the raw mtime in epoch seconds, rides along here (#243) for the
    # spread check below -- coarser day-floored -M cannot see a checkout's few-second
    # spread at all, since a whole calendar day of real drift and a same-second
    # checkout can both floor to "0d apart".
    out="$(perl -e '
      my $d = shift or exit 0;
      opendir(my $h, $d) or exit 0;
      while (defined(my $e = readdir $h)) {
        next if $e eq "." || $e eq "..";
        # A tab or a newline in the filename would land inside the very bytes this
        # table uses as its own field and record separators, and jit_entry_age() (the
        # awk half) has no way to tell "a filename that happens to contain a tab" from
        # a genuine second row -- it would either fold two files onto the one key that
        # stops at the first tab, or split one row into two. Refused here, before
        # either byte ever reaches the table, rather than tolerated downstream.
        next if $e =~ /[\t\n]/;
        my $f = "$d/$e";
        next if -l $f;
        next unless -f $f;
        my $days = int(-M $f);
        $days = 0 if $days < 0;
        my $mtime = (stat($f))[9];
        print "$e\t$days\t$mtime\n";
      }
      closedir $h;
    ' "$d" 2> /dev/null)"
    [ -n "$out" ] || continue

    # First pass: the mtime spread across every file this run just read, so a checkout
    # signature is recognised BEFORE anything renders an age -- #243's "detect and
    # decline". A layer of one file has no second point to compare and always falls
    # through to rendering its real age, which is a known blind spot the header comment
    # above jit_scan_entry_ages() names rather than an oversight: the heuristic is about
    # the SHAPE of the whole layer, and one file carries no such shape.
    local n=0 emin="" emax=""
    while IFS=$'\t' read -r _e _days epoch; do
      [ -n "$epoch" ] || continue
      n=$((n + 1))
      if [ -z "$emin" ] || [ "$epoch" -lt "$emin" ]; then emin="$epoch"; fi
      if [ -z "$emax" ] || [ "$epoch" -gt "$emax" ]; then emax="$epoch"; fi
    done <<< "$out"

    if [ "$n" -ge 2 ] && [ -n "$emin" ] && [ -n "$emax" ] && [ $((emax - emin)) -le "$window" ]; then
      # Every mtime in this layer sits within $window seconds of the others -- an
      # ordinary `git clone`, a fresh plugin install or a CI checkout produces exactly
      # this shape every time, and a real editing history essentially never does across
      # multiple files. Ages are withheld for the WHOLE layer rather than print a
      # number that would read as "freshly maintained" on exactly the sessions #233
      # wrote the footer for. Logged so this is distinguishable from the case where
      # 00-manual holds no entries at all: that case never reaches this branch (the
      # `[ -n "$out" ] || continue` above already skipped it) and logs nothing, so
      # silence here always means "nothing to scan", never "declined".
      jit_log_write "[$(_ts)] entry-ages declined for $layer: $n files within $((emax - emin))s of each other (looks like a checkout, not real age data)"
      continue
    fi

    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # The epoch column added above was only ever needed for the spread check just
      # run; the age table jit_entry_age() (the awk half) reads never had a third
      # column and must not grow one now, so it is stripped back off here. Safe as a
      # shortest-suffix removal because the filename guard above already refused any
      # name containing a tab, so exactly two tabs exist on this line.
      line="${line%$'\t'*}"
      if [ "${#JIT_ENTRY_AGES}" -gt "$JIT_ENTRY_AGES_MAX" ]; then
        continue
      fi
      JIT_ENTRY_AGES="$JIT_ENTRY_AGES${JIT_ENTRY_AGES:+$JIT_NL}$layer/$line"
    done <<< "$out"
  done
}

jit_report_name() {
  # C collation for the duration. Under a UTF-8 locale bash own [A-Za-z0-9] can admit
  # accented letters and ${#s} counts characters; the whole point of the set is that it is
  # a BYTE range. `local` restores the caller locale on return.
  local LC_ALL=C
  case "$1" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
      printf '%s' "$JIT_NAME_WITHHELD"
      return 0
      ;;
  esac
  [ "${#1}" -gt 64 ] && {
    printf '%s' "$JIT_NAME_WITHHELD"
    return 0
  }
  printf '%s' "$1"
}

# --- What a maintainer tool may say about a KEYWORD (#126) --------------------
# A different question from the one above, and jit_report_name() is the wrong guard for
# it: that set is chosen for having NO SPACE, and `vat rate` is a legitimate keyword --
# normalised to exactly that, spaces included, by the code that writes the index. A guard
# that withheld every multi-word term would pass every negative test and make the reports
# that carry a term useless in their ordinary case.
#
# So the space is admitted and the term is bounded instead: ^[a-z0-9][a-z0-9 -]*$ -- the
# bytes the keyword normaliser actually emits, so anything else means the term did not
# come from this run -- at most 40 bytes and at most 4 words.
#
# Be honest about what that buys: no bound admitting `vat rate` can refuse all imperative
# English, since `delete all ssh keys` is four words and 19 bytes. What it removes is the
# UNBOUNDED channel -- the paragraph, the forged line, the control character. The entry
# FILES print beside every such term either way, so a withheld one is still greppable.
#
# It lived in rebuild-tsv.sh until #183, which is where #126 needed it first. It is here
# now for the reason jit_report_name() moved here in #131: two bash answers to one
# question drift, and the drift is invisible until a term printed by one tool is withheld
# by the other. jit-doctor.sh was the second caller that made that real.
#
# The awk half is NOT a copy that can be deleted and stays in rebuild-tsv.sh beside its
# name twin: three of that script reports are built inside awk, and awk cannot source a
# bash file.
#
# The bash half maps every space to a hyphen before the class check rather than putting a
# space inside a `case` bracket expression, where it would have to be quoted mid-pattern.
# The hyphen is already in the kept set, so the substitution cannot admit anything the
# class does not, and a LEADING space becomes a leading hyphen and is refused.
export JIT_KEYWORD_WITHHELD='<withheld: not a plain keyword>'

jit_report_keyword() {
  # LC_ALL=C for the reason jit_report_name() sets it: the set is a byte range, and ${#s}
  # must count bytes, not characters.
  local LC_ALL=C s="$1" flat rest n=1
  flat="${s// /-}"
  case "$flat" in
    '' | [!a-z0-9]* | *[!a-z0-9-]*)
      printf '%s' "$JIT_KEYWORD_WITHHELD"
      return 0
      ;;
  esac
  [ "${#s}" -gt 40 ] && {
    printf '%s' "$JIT_KEYWORD_WITHHELD"
    return 0
  }
  rest="$s"
  while [ "$rest" != "${rest#* }" ]; do
    rest="${rest#* }"
    n=$((n + 1))
  done
  [ "$n" -gt 4 ] && {
    printf '%s' "$JIT_KEYWORD_WITHHELD"
    return 0
  }
  printf '%s' "$s"
}

# --- requires: presence probe (#203) -------------------------------------------
# A tools rule can carry `requires: <binary>` in its frontmatter, naming a binary its OWN
# remedy depends on -- `mode: block` naming supertool, unconditionally, with no way to say
# "and if supertool is not installed" is the case that was filed. A rule that fires for a
# user with no route to comply is not a guard, it is an outage with an explanation
# attached.
#
# This has to run in BASH, before the awk process starts, and cannot be pushed down into
# the row loop that reads everything else off the index: grep this file for `system(` and
# find nothing, on purpose, everywhere -- every awk program here parses untrusted JSON and
# untrusted index text, and a program that can exec is a program that can be made to exec
# something else. So the answer is computed once, out here, and handed to the row loop as
# one more -v value beside the ones it already reads off an untrusted TSV.
#
# `command -v`, not a hand-rolled PATH walk: a POSIX shell builtin already used elsewhere
# in this tree (jit-dry-run.sh, several test suites), so this introduces no new runtime
# dependency and starts no new external process per lookup.
#
# DEDUPED, not probed once per row. A tree can carry many rules naming the same binary and
# the probe count must not grow with the rule count -- only with the number of DISTINCT
# binaries named. The caller only tests set membership, never position, so a "have we
# already asked this one" guard is enough and needs no sort.
#
# Reads the SAME committed index files the row loop below reads through getline, one bash
# pass ahead of the one awk pass -- both are the tree as committed, so nothing this probe
# sees is a byte the row loop will not also see. A row with fewer than seven columns
# yields an empty 7th field on its own, which is exactly the "no requires: on this row"
# case and needs no extra handling.
#
# `awk -F` with a tab, deliberately, and NOT `read` with IFS set to a literal tab. Driven, not
# reasoned: bash `read` treats tab as an IFS WHITESPACE character regardless of what IFS
# is actually set to, which means it COLLAPSES adjacent delimiters exactly the way
# unquoted word-splitting on the default IFS does -- `a\tb\t\t\tc` read into four
# variables lands `c` in the SECOND one, not the fourth, because the three consecutive
# tabs between `b` and `c` are folded into one separator. This is not a bash-3.2 bug, it
# is documented POSIX `read` behaviour for space, tab and newline specifically, and it is
# invisible on a two- or three-column fixture where every field happens to be non-empty --
# which is exactly why the first version of this function passed its own ad hoc check and
# still misread a 7-column tools row with two empty columns before requires:, taking
# "absentbin" for r_require instead of r_requires and reporting no missing binary at all.
# `awk -F` treats the delimiter literally and never collapses a run of it, which a
# comma-or-pipe-separated field would not have exposed either -- tab is the one delimiter
# this shell cannot be trusted to split on the naive way. `NF >= 7` guards a row with
# fewer than seven columns: awk prints an empty $7 for one of those anyway, but the guard
# says so rather than leaning on that as an accident of how awk handles a field past NF.
# `LC_ALL=C`, the same pin every other awk invocation in this file carries and for the
# same reason (#68, #195): this reads bytes out of a committed index, not characters.
#
# awk, not `cut -f7`: cut would work here too, but it is a tool this tree has never
# needed before, where awk is already the one dependency every hook in scripts/ already
# requires. Reaching for a second external splitter to answer the same question the one
# already on the machine can answer is the wrong new dependency to add.
#
# ONE awk process per file, not one per row: it walks every line of the tsv in a single
# pass and this loop only reads its stdout back, so the process count here does not
# grow with the row count of a layer, only with the number of layers.
#
# `--`, not a bare name, on the presence check: a requires: value is free text out of a
# committed file, and a value starting with a hyphen must not be read as an OPTION to the
# `command` builtin itself.
# #427: this list crosses an exec boundary in pre-tool-hook.sh -- handed to awk as a
# single -v missing_bins=... argument -- and it is the one such list in this file that
# was not byte-capped: JIT_SYMLINKS, JIT_NONFILES, JIT_CONFIG_REFUSED,
# JIT_LAYERS_REFUSED and JIT_ENTRY_AGES all cap themselves for exactly this reason. The
# source is a committed 00-index.tsv, so its size is chosen by whatever tree is cloned,
# not by this machine: a requires: value a few hundred KB long, or a few hundred rows
# each naming a distinct one, pushes the composed awk program past MAX_ARG_STRLEN /
# ARG_MAX, execve fails, and pre-tool-hook.sh refuses -- or on an unwritable TMPDIR,
# silently passes -- every call in the session, not just the row that named the
# oversized value.
JIT_MISSING_REQUIRES_MAX=4096
jit_missing_requires() {
  # $1 tools dimension base directory, $2 space-separated layer names (JIT_TOOL_LAYERS)
  local base="$1" layers="$2" layer tsv bin seen=" " missing=" " cut=0
  local LC_ALL=C
  for layer in $layers; do
    tsv="$base/$layer/00-index.tsv"
    [ -f "$tsv" ] || continue
    while IFS= read -r bin; do
      [ -z "$bin" ] && continue
      # A bare binary name only -- JIT_VALID_REQUIRES_RE, the same discipline
      # rebuild-tsv.sh applies at index time. The committed index may already carry a
      # value that predates that check, or one from a tree this repository never
      # indexed at all, so this is the check that actually protects a clone: refused
      # here means never added to the seen list, never counted toward the cap below,
      # and never handed to command -v as an argument.
      case "$bin" in
        *[!A-Za-z0-9._+-]*) continue ;;
      esac
      [ "${#bin}" -gt 255 ] && continue
      case "$seen" in *" $bin "*) continue ;; esac
      seen="$seen$bin "
      command -v -- "$bin" > /dev/null 2>&1 && continue
      # The COUNT is not capped, only the list -- JIT_CONFIG_REFUSED's own reason: a
      # truncated list that also under-reported would be this repository own defect
      # class wearing a fix as a disguise. A binary dropped by the cap is simply never
      # added to $missing, so the tools row that names it stops being treated as
      # conditionally-bypassable (#203) and goes back to being enforced outright --
      # the fail-closed direction, not fail-open.
      if [ "${#missing}" -gt "$JIT_MISSING_REQUIRES_MAX" ]; then
        if [ "$cut" = 0 ]; then
          cut=1
          # ONE token, no interior space: $missing is membership-tested downstream as
          # " NAME " substrings (pre-tool-hook.sh), so a multi-word note would plant a
          # plain word -- "cap", say -- as a false hit for any row that genuinely names
          # a binary spelled the same. Brackets and colons are outside
          # JIT_VALID_REQUIRES_RE, so no legitimate requires: value can ever equal this
          # token outright either.
          missing="${missing}[JIT-427:list-truncated-at-cap] "
        fi
        continue
      fi
      missing="$missing$bin "
    done < <(LC_ALL=C awk -F "$(printf '\t')" '{ print (NF >= 7) ? $7 : "" }' "$tsv")
  done
  printf '%s' "$missing"
}

# --- The decisive awk crashed: silence is not "no rule matched" (#397) -------------
#
# #393 measured a working awk exiting 139 (SIGSEGV) under concurrent load, 8 times
# across 8 different sections, transient rather than a broken interpreter. #397's own
# comment measured what that does specifically to THIS repository's decisive awk: the
# crash writes nothing to stdout, the wrapper never captured its exit status, and the
# exit 0 after it is unconditional -- so a crashed awk and a mode: block rule with no
# opinion are byte-identical on the wire. The harness reads empty output as permission
# and the call proceeds.
#
# Two answers, not one, because the three hooks that fork the decisive awk are not the
# same shape:
#
#   pre-tool-hook.sh is the refusal path -- the one hook whose whole job is deciding
#   whether the call the harness is about to run is safe. A mode: block rule that
#   could not be checked is the exact defect #397 measured, so this fails CLOSED:
#   refuse the call and say why, rather than let it ride through on a crash no rule was
#   actually checked against.
#
#   pre-prompt-hook.sh and pre-path-hook.sh have no decision field to fail closed WITH
#   -- grep JIT_AWK_ENVELOPE above: only pre-tool-hook.sh's awk program ever calls
#   jit_envelope_block(). A crash there costs a missed injection, never a bypassed
#   refusal, so there is nothing to protect by inventing a block these two hooks have
#   never had. Say so instead, over the systemMessage channel #367/#368 already proved
#   these two deliver on every branch -- honest, and it does not turn one transient
#   crash into every remaining prompt of the session being refused.
#
# NOT the retry question -- #397 is explicit that is a separate issue, with its own
# cost (one wasted fork per call, forever, on a machine already in trouble). This only
# makes the crash speak instead of staying silent; the exit status each call site now
# captures in one place is what a retry loop would wrap around later, not something it
# needs to invent.
# #400 (CI, PR #400 red): a bare "$(LC_ALL=C awk ...)" strips every trailing
# newline the captured output had, and the empty envelope's own `print "{}"` relied
# on one -- so on the two hooks whose decisive awk was rewritten to capture,
# tests/test-inert-without-tree.sh's section B saw four of six hooks' `{}\n{}\n`
# answers glue onto one line and undercounted them. Isolated with `od -c` on each
# hook against main: pre-tool-hook.sh and pre-prompt-hook.sh regressed; the third
# hook that captures, pre-path-hook.sh, was NOT uniformly spared, contrary to what
# looked at first like a clean exemption -- its own `jit_path_awk()` regressed too
# whenever the captured awk itself produces the "{}" (a Read/Edit tool_input with a
# file_path, never routed through the Bash-command two-pass candidates channel);
# only the ONE branch that still calls bash's own `echo "{}"` directly (the
# candidates-written-but-none-resolved case) was ever exempt, by construction
# rather than by hook identity. So the fix is not "add \n back" -- the ORIGINAL
# bytes varied per envelope (`print "{}"` emitted one; `printf "%s", ...block/
# inject(...)` emitted none) and per hook, and the crash envelopes below are new
# text this issue adds, never captured at all.
#
# A FIRST cut of this fix appended a sentinel byte after the captured command inside
# one "$( cmd; printf sentinel )" substitution, to smuggle the trailing bytes and the
# real exit status through the one substitution that strips them. It worked in every
# hand-driven and suite-driven check, and still lost the sentinel about 1 time in 800
# under a tight sequential loop of the REAL pre-prompt-hook.sh awk program against a
# real (unshimmed, non-crashing) awk -- `JIT_DEBUG_CAPTURE` traced the raw captured
# string down to the awk's own 2-byte "{}" with the sentinel and the exit digit both
# entirely absent, which then read as rc="{}": not a number, so `[ "$rc" -eq 0 ]`
# errored, took the else branch, and printed a crash message for a call that never
# crashed at all -- a new false-refusal risk on the exact refusal path this issue
# exists to make trustworthy, worse than the bug it replaced. Root cause not chased
# further (a pipe-buffering race between two commands sharing one command-substitution
# subshell is the leading guess, not a finding) because there is a route around it
# that does not depend on understanding it: write directly to a file rather than
# through any command substitution, and read the exit status of the awk command
# itself, with no subshell between it and $? at all.
#
# `>` a real file is one write() through one already-open descriptor, not a pipe two
# separate commands share -- there is no second statement racing the first for a
# sentinel to lose, and no substitution to strip a trailing byte from what is written.
# `$?` right after `"$@" > file` is `"$@"`'s own exit status directly, no subshell, no
# arithmetic.
#
# #400 (CI, ubuntu leg): the first cut of this read the file back with `cat`, and
# tests/test-fork-count.sh's own "no hook puts a cat in front of something that reads
# stdin itself" section counted that as one added fork per call on the three
# highest-frequency hooks -- a real, counted cost against a budget this repo
# advertises as 30-110ms and guards on every platform, not a false positive: the
# suite's own docstring is broader than its section title (it pins EVERY external
# command a hook forks, not only a redundant `cat | reader`), and post-tool-hook.sh's
# own pinned-at-one exemption is exactly the shape this WOULD have needed if kept.
# `$(<file)` is fork-free too but is command substitution underneath, so it strips
# trailing newlines the same way the original bug this whole issue is about did --
# not viable. `IFS= read -r -d '' out < file` IS: a bash builtin, no fork, and
# verified byte-exact including a trailing newline at 200000 bytes (the same NUL
# caveat `$( )` already carries elsewhere in this codebase applies here too -- never
# reachable, because every byte reaching this file already passed through
# jit_json_escape(), which escapes every control byte 0-31 as \u00XX). `read`'s own
# exit status is not checked: it is 1 whenever the file has no trailing NUL delimiter
# (every real case here), by design, and that is not a distinct signal from success --
# the variable is populated exactly either way, which is confirmed directly rather
# than assumed.
# One helper, four call sites (both pre-tool-hook.sh branches, pre-prompt-hook.sh,
# pre-path-hook.sh's jit_path_awk()) rather than four copies of the file-and-cleanup
# bookkeeping to keep in sync.
jit_awk_capture() {
  # $@ the command to run (LC_ALL=C is applied here, not by the caller, so a
  # caller writes `jit_awk_capture awk ...` rather than `jit_awk_capture LC_ALL=C
  # awk ...` -- the latter would try to run a program literally named "LC_ALL=C").
  # Sets JIT_AWK_CAPTURE_OUT / JIT_AWK_CAPTURE_RC; not local, by design, so the
  # caller reads them back after this returns. On success the caller emits the
  # EXACT bytes with `printf '%s' "$JIT_AWK_CAPTURE_OUT"` -- a builtin, no fork,
  # unlike the `cat "$JIT_AWK_CAPTURE_FILE"` a first cut of this used. The scratch
  # file itself is removed here, immediately after being read back, rather than
  # left for the caller: nothing outside this function needs its path any more
  # once JIT_AWK_CAPTURE_OUT holds its content, and removing it here rather than at
  # each of the four call sites is one fewer thing for a future call site to
  # forget.
  #
  # No writable scratch file (TMPDIR unwritable or absent) is NOT treated as a
  # crash: tests/test-hook-tmpfile.sh section C ("the scratch file lives under
  # $TMPDIR, and losing it is not an error") already pins, for every hook and
  # predating #397, that losing scratch space degrades a hook to running without
  # its log/dedup channel -- never to refusing or staying silent, because every
  # rule still fires. #400 self-review found this function breaking that exact,
  # already-tested contract: TMPDIR being unwritable made its OWN mktemp fail
  # exactly like $JIT_TMP's already does, and reporting that as "could not
  # evaluate" turned an established, benign degrade into a new outage on all
  # three hooks (every entry stopped injecting/blocking whenever TMPDIR alone
  # was the problem, confirmed by that suite's own TMPDIR="$TEST_DIR/no-such-
  # tmpdir" fixture). So this is a THIRD outcome, not folded into either of the
  # other two: JIT_AWK_CAPTURE_RC="uncaptured" and the command runs directly,
  # straight to real stdout, exactly as every hook did before #397 -- the one
  # corner where #397's own crash-detection is unavailable, accepted because it
  # is the SAME already-accepted corner every other scratch-file user in this
  # codebase (jit_tmp_open() included) already degrades through rather than
  # errors on, and asking for scratch space just to verify a decisive awk would
  # be a stricter contract than this codebase has ever held for anything else.
  # A caller checks for this value before treating JIT_AWK_CAPTURE_RC as a
  # number -- see the three-way branches at each of this function's call sites.
  local d f urc
  d="${TMPDIR:-/tmp}"
  d="${d%/}"
  f="$(mktemp "$d/claude-jit-awkout-XXXXXXXX" 2> /dev/null)" || f=""
  if [ -z "$f" ]; then
    # #403: this branch used to run the command and `return 0` without ever reading
    # $? -- a SIGSEGV (exit 139, #393's own measured mechanism) then printed 0 bytes,
    # exactly as an ordinary `mode: block` rule with nothing to say would, and the
    # harness read that silence as permission. $?  IS available here (LC_ALL=C "$@"
    # is a plain foreground command, no subshell in between); it was simply never
    # looked at.
    #
    # The trap: unlike the captured branch below, this one writes straight to REAL
    # stdout -- there is no scratch file to inspect before deciding, and no reliable
    # disk-free way to intercept it either. A single "$( )" was already tried and
    # rejected for this exact codebase (see the #400 commit this function's own
    # header comment describes): it strips a trailing newline a healthy "{}" answer
    # relies on, and a two-statement sentinel variant of it lost the sentinel ~1/800
    # times under real load for a reason never root-caused. Reusing either shape here
    # would risk the same false-crash regression on the one corner (TMPDIR
    # unwritable) this function exists to keep degrading through rather than failing.
    #
    # So a genuine SIGNAL DEATH (rc > 128) is reported by setting JIT_AWK_CAPTURE_RC
    # to the real numeric code rather than "uncaptured", and letting
    # jit_awk_dispatch()'s own existing `rc > 128` branch (unchanged by this fix)
    # call the caller's crash_fn -- the SAME per-hook-family answer (block on
    # pre-tool-hook.sh, systemMessage on the other two) the captured path already
    # gives, without a second five-way branch to keep in sync. Every OTHER exit
    # shape (clean success, or awk's own ordinary non-crash error) still reports
    # "uncaptured" exactly as before: whatever awk already wrote directly to real
    # stdout is trusted as-is, unchanged from pre-#403 behaviour.
    #
    # Does the crash_fn's own extra bytes ever land AFTER awk already wrote a
    # (partial or complete) answer of its own, producing two JSON values on one
    # stdout -- the exact defect class #397's own self-review caught on the captured
    # path? Checked, not assumed: every decisive awk program in this codebase
    # (pre-tool-hook.sh, pre-prompt-hook.sh, pre-path-hook.sh) has exactly ONE
    # terminal stdout print per code path -- `print "{}"; exit` early, or exactly one
    # of the `printf "%s", ...`/`print "{}"` statements in its END block -- and
    # nothing runs after it; grepping each file for `print(f)? "` confirms this
    # directly rather than by memory. Real stdout here is a pipe to the harness, so
    # glibc/BSD libc fully-buffer it: a single print call this small (a rule's
    # `reason` text, typically well under 4KB) never reaches even one write()
    # syscall before the process would already be done, and #393's own 8/8 measured
    # crashes wrote ZERO bytes before dying, consistent with that. It is NOT provably
    # impossible: an unusually large injected body (this codebase elsewhere handles
    # entries up to 200000 bytes) could make ONE printf call issue several internal
    # write()s, and a crash landing between two of them would leave a partial answer
    # on the wire before the crash_fn's own bytes land after it -- REASONED, not
    # observed, exactly the same evidentiary bar this codebase already uses for the
    # NUL-byte caveat above. Accepted for the same reason #400 accepted degrading
    # this corner at all: asking for more than every other scratch-file user in this
    # codebase already gets would be a stricter contract than this function has ever
    # held, and the alternative (a $( )-based capture) is the regression #400 already
    # measured and removed.
    LC_ALL=C "$@"
    urc=$?
    JIT_AWK_CAPTURE_OUT=""
    if [ "$urc" -gt 128 ] 2> /dev/null; then
      # shellcheck disable=SC2034
      JIT_AWK_CAPTURE_RC=$urc
    else
      # shellcheck disable=SC2034
      JIT_AWK_CAPTURE_RC="uncaptured"
    fi
    return 0
  fi
  LC_ALL=C "$@" > "$f"
  # shellcheck disable=SC2034
  JIT_AWK_CAPTURE_RC=$?
  # `read`'s own exit status is not the signal here -- see the comment above this
  # function for why. IFS= so leading/trailing whitespace in the captured bytes
  # (there is none in a well-formed envelope, but this must not depend on that)
  # is never trimmed by the split `read` would otherwise perform.
  # shellcheck disable=SC2034
  IFS= read -r -d '' JIT_AWK_CAPTURE_OUT < "$f"
  rm -f "$f"
}

jit_awk_crash_block() {
  # $1 the decisive awk's exit status (e.g. 139 for SIGSEGV)
  local rc="${1:-?}"
  printf "{\"decision\":\"block\",\"reason\":\"# JIT Context: the rule engine could not evaluate this call -- awk exited %s before it finished. Refusing rather than permitting a call no rule was actually checked against. See issue #397.\"}" "$rc"
}

jit_awk_crash_sysmsg() {
  # $1 the decisive awk's exit status (e.g. 139 for SIGSEGV)
  local rc="${1:-?}"
  printf "{\"systemMessage\":\"JIT Context: the rule engine could not evaluate this turn -- awk exited %s before it finished. No entries were checked, so none were injected. See issue #397.\"}" "$rc"
}

# #400 (CI, macOS leg, test-marker-degradation.sh section B): a SIGSEGV (measured 139 =
# 128+11 on macOS) and awk's OWN ordinary error exit are not the same event, and treating
# every non-zero exit as "nothing was evaluated" broke an established, pre-#397 contract
# (#50) this repository already tests: an unopenable marker path is a FATAL i/o error on
# one-true-awk, but jit_shown_load()'s own comment (this file, above) says why it is
# benign -- the read call that fails NEVER calls close(), so one-true-awk defers the
# diagnostic to interpreter shutdown, AFTER every print in END{} has already run and
# flushed. Measured directly (not assumed): the exact #50 fixture -- a directory at the
# session's marker path -- makes both pre-tool-hook.sh and pre-path-hook.sh exit 2 on
# this machine's awk (one-true-awk, macOS), stderr reading "awk: i/o error occurred on
# <path> ... source line number NNNN", and JIT_AWK_CAPTURE_OUT already holding the real,
# complete, correctly-decided envelope (a genuine "decision":"block" carrying the
# MATCHED RULE's own reason text, not a placeholder) by the time that rc is read back --
# the crash-only branch was discarding a good answer and replacing it with a false "could
# not evaluate" for a call that plainly was. Only OBSERVED on this platform's one-true-awk;
# gawk (Linux, Windows/Git Bash CI legs) is REASONED to behave comparably for the same
# reason -- jit_shown_load()'s own comment already names the engine this was written
# against -- and is exactly the platform claim the audit accompanying this fix marks
# reasoned rather than observed.
#
# So exit status alone is not enough; JIT_AWK_CAPTURE_OUT's own emptiness is the second
# axis, and the two together give three outcomes rather than two:
#   * a SIGNAL DEATH (rc > 128 -- 128+N is POSIX shell convention across bash on Linux,
#     macOS and Git Bash alike, not an awk-specific number, so this test is portable even
#     though the ORDINARY error codes an engine chooses are not) is a genuine crash,
#     #393's own measured mechanism: nothing after it can be trusted, output or not.
#   * an ORDINARY nonzero exit (awk's own chosen status, always well under 128 on both
#     engines this repo has ever measured) with NON-EMPTY captured output is what this
#     scenario actually is: trust it, exactly as jit_shown_load()'s own comment already
#     argues the codebase should.
#   * an ORDINARY nonzero exit with NOTHING captured is still genuinely ambiguous -- a
#     fatal error that hit before the first print ever ran (a bad pattern awk could not
#     even compile, say) reads identically to this deferred-error shape from here, and
#     there is no reasoning function's own way to tell them apart. jit_awk_dispatch()'s
#     two function arguments answer that ambiguity differently per hook family, which is
#     the one difference #397's own split between the refusal and the injection hooks
#     was already about: pre-tool-hook.sh cannot verify, so it still refuses (pass
#     jit_awk_crash_block for BOTH arguments); the injection hooks have nothing to
#     refuse, and #50 already ruled that keeping going -- the same "{}" a genuine
#     no-match produces, not a new alarm -- is the safe direction for an ordinary
#     awk-side hiccup this narrow, as opposed to jit_awk_crash_sysmsg, reserved for the
#     signal-death branch, the class #393/#397 are actually about.
jit_awk_empty_ok() {
  printf '{}\n'
}

# jit_awk_dispatch <crash_fn> <ordinary_empty_fn>
# Reads JIT_AWK_CAPTURE_RC/_OUT, already set by a prior jit_awk_capture() call, and
# prints the right thing to real stdout -- the single place this five-way branch is
# written, rather than once per call site (four, after this fix), each free to drift.
jit_awk_dispatch() {
  local crash_fn="$1" empty_fn="$2"
  if [ "$JIT_AWK_CAPTURE_RC" = "uncaptured" ]; then
    return 0
  fi
  if [ "$JIT_AWK_CAPTURE_RC" -eq 0 ] 2> /dev/null; then
    printf '%s' "$JIT_AWK_CAPTURE_OUT"
  elif [ "$JIT_AWK_CAPTURE_RC" -gt 128 ] 2> /dev/null; then
    _jit_awk_handler "$crash_fn" "$JIT_AWK_CAPTURE_RC"
  elif [ -n "$JIT_AWK_CAPTURE_OUT" ]; then
    printf '%s' "$JIT_AWK_CAPTURE_OUT"
  else
    _jit_awk_handler "$empty_fn" "$JIT_AWK_CAPTURE_RC"
  fi
}
# #461: the handlers are called by name through this explicit table, never as `"$fn" args`.
# The directory validator reads a command whose name is a variable as "a command assembled
# at run time" it cannot follow. A name not listed here returns 127, as calling an unknown
# command did.
_jit_awk_handler() {
  case "$1" in
    jit_path_awk_could_not_evaluate) jit_path_awk_could_not_evaluate "$2" ;;
    jit_path_awk_ordinary_empty) jit_path_awk_ordinary_empty "$2" ;;
    jit_awk_crash_sysmsg) jit_awk_crash_sysmsg "$2" ;;
    jit_awk_empty_ok) jit_awk_empty_ok "$2" ;;
    jit_awk_crash_block) jit_awk_crash_block "$2" ;;
    *) return 127 ;;
  esac
}

# --- The generic-word list: one plain file, or a directory of chunks (#437) --------
# The shipped data/generic-words.txt (1,027,699 bytes, 103,843 lines) was split into
# data/generic-words/chunk-NN.txt, each comfortably under 256 KiB, for the Anthropic
# plugin directory's rule that holds any non-image file of that size or more --
# concatenating the chunks in name order reproduces the original file byte for byte;
# nothing was reordered or deduplicated. rebuild-tsv.sh's own default now names the
# DIRECTORY; a caller-configured JIT_CONTEXT_GENERIC_WORDS / DYNAMIC_RULES_GENERIC_WORDS
# may still name either a single plain file (unchanged) or a directory, read the same
# chunked way.
#
# Prints one member path per line, sorted by name -- callers split this on a newline
# (ENVIRON, never -v: see JIT_SYMLINKS above for why a newline-bearing value travels
# that way). Prints nothing for an empty PATH or one that is neither a file nor a
# directory; the caller's own existence/readability checks still see that absence and
# report it loudly -- this function never swallows it.
jit_generic_words_members() {
  local path="$1" f
  [ -n "$path" ] || return 0
  if [ -f "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [ -d "$path" ]; then
    for f in "$path"/*.txt; do
      [ -f "$f" ] || continue
      printf '%s\n' "$f"
    done | LC_ALL=C sort
  fi
  return 0
}
