#!/bin/bash
# claude-jit-context -- PostToolUse hook: records that a jit-context entry was EDITED.
#
# #244 (part 2 of #233): the Stop hook this feeds (stop-hook.sh) needs an edit signal
# that does not exist anywhere else in this codebase. hooks.log and the `shown` marks
# both record what was INJECTED; nothing records that an entry file was WRITTEN. This
# hook is that signal, and it is deliberately the only new mechanism -- the maintainer's
# own #244 comment makes adding a second one the difference between shipping this and
# closing the issue `wontfix`.
#
# WHY POSTTOOLUSE, KEYED ON Write|Edit. It is the only candidate that OBSERVES an edit
# rather than inferring one. jit_scan_entry_ages() (common.sh) already exists and reads
# filesystem mtimes -- and it inherits #243: on a fresh clone every mtime is checkout
# time, so a signal built on it would report "nothing was updated" on a session where
# everything was, with no way to tell which. That is the trap this hook exists to avoid,
# not a second way to reach the same table.
#
# STORAGE: a marker file beside the `shown` marks this project already keeps --
# `edited-<session>.txt` in the same $JIT_STATE_DIR, same session keying, same
# ageing-out session-start-hook.sh already performs (extended there for this one name).
# Existence only. No path, no content, no count: the Stop hook this feeds only ever asks
# "did anything under this tree get written this session", never which file or how many
# times, and free text out of a payload is a channel this project has already been
# burned by trusting once (#65, one file over) and is not going to open a second one
# for a feature that does not need it.
#
# COST (#244's own constraint): this fires on every Write and Edit in a stranger's
# session, most of which have nothing to do with this project's own tree.
# `hooks/hooks.json` already narrows PostToolUse to the Write and Edit tools via its own
# matcher, and after the one JSON parse below the very first thing this script does is a
# plain `case` prefix comparison against $JIT_BASE -- never a match against the index,
# never a second fork for anything but the marker write itself (and, since #276, the
# canonicalisation fallback below, which is itself gated behind a zero-fork substring
# test before it forks anything).
#
# A hook must never fail hard (hooks.md): every exit below answers `{}`.
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

# One awk pass, the same JSON macros every other hook here already shares
# (JIT_AWK_JSON, jit_json_fields/jit_field/jit_unescape, jit_session_key out of
# common.sh). tool_name is bounded to a plain identifier before it is ever handed back
# to bash -- the same posture jit_session_key() already applies to the session id --
# because free text out of a payload has no business riding a line bash will `read` as
# a trusted token.
#
# THE ORDER OF THE THREE PRINTED LINES MATTERS. tool_name and the session key are both
# bounded, newline-free tokens, each read with one `read -r`; file_path is free text out
# of the payload and, after jit_unescape, may itself carry a literal newline (a JSON
# `\n` escape decodes to a real one). It is printed LAST and read with `cat` over
# whatever remains, for the same reason _log_hook's own tail argument is the last thing
# on its line (common.sh): everything with a shape bash can trust comes first, and the
# one field that cannot be trusted to fit on one line comes after there is nothing left
# for it to misalign.
PT_PARSED="$(cat | LC_ALL=C awk "$JIT_AWK_JSON"'
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  tool = ""; fp = ""
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    k = raw[fs[i]]
    if (k == "tool_name") tool = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "file_path" && fp == "") fp = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "path" && fp == "") fp = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
  }
  if (tool !~ /^[A-Za-z_]+$/ || length(tool) > 32) tool = ""
  key = jit_session_key(raw, fs, fe, n)
  print tool
  print key
  print fp
}
')"

PT_TOOL=""
PT_SESSION=""
PT_FP=""
{
  IFS= read -r PT_TOOL
  IFS= read -r PT_SESSION
  PT_FP="$(cat)"
} <<<"$PT_PARSED"

case "$PT_TOOL" in
  Write|Edit) ;;
  *) echo '{}'; exit 0 ;;
esac

if [ -z "$PT_FP" ] || [ -z "$PT_SESSION" ] || [ -z "$JIT_STATE_DIR" ]; then
  echo '{}'
  exit 0
fi

# A literal ".." anywhere in the value is refused outright: the prefix test below is a
# `case` pattern, which is lexical and never resolves a path, so
# "$JIT_BASE/00-manual/../../../../etc/passwd" would otherwise match the pattern while
# naming a file nowhere near this tree. jit_shown_apply() (common.sh) refuses the same
# byte for the same reason one channel over. A literal backslash is refused too: on Git
# Bash the Win32 file API underneath treats it as a separator, so a dot-dot spelled with
# backslashes traverses there while reading as an ordinary character to this pattern.
case "$PT_FP" in
  *..*|*\\*) echo '{}'; exit 0 ;;
esac

# The cheap prefix test. $JIT_BASE carries no trailing slash on the ordinary path
# (common.sh), so on an ordinary session this already cannot match a sibling directory
# that merely starts with the same characters -- ".claude/jit-contextual/x" is not
# ".claude/jit-context/x". It is also the fast path almost every OTHER session's edit
# takes: no match, no fork, exit -- the cost this hook's header promises to hold to.
case "$PT_FP" in
  "$JIT_BASE"/*) ;;
  *)
    # #276: the literal test above is lexical, not physical, and three ordinary values
    # make it miss a file that IS inside this tree. A trailing slash on
    # CLAUDE_PROJECT_DIR leaves JIT_BASE reading ".../project//.claude/jit-context",
    # and no real file_path carries a doubled slash to match it. A relative
    # CLAUDE_PROJECT_DIR leaves JIT_BASE never starting with "/" at all, so it can
    # never prefix an absolute file_path, for any input. And a symlinked project root
    # (macOS's /tmp -> /private/tmp is the standing example) means JIT_BASE and
    # file_path can each spell the exact same file on disk with different characters --
    # whichever one of the two a given payload happens to canonicalise and the other
    # does not. A missed marker here is not just a missed injection: stop-hook.sh reads
    # its absence as the positive claim "nothing was updated", which is false when the
    # observer never matched in the first place.
    #
    # Resolving that costs a `cd -P` fork, and the header above is explicit that this
    # hook affords at most one fork beyond the marker write, for every edit everywhere,
    # most of which have nothing to do with this project. So the fallback stays behind
    # a substring test that costs nothing: JIT_BASE's tail is always the literal
    # ".claude/jit-context" (common.sh builds no other shape), so a file_path that does
    # not contain that substring anywhere cannot be inside ANY project's jit-context
    # tree, canonical or not, and is rejected right here with zero forks -- exactly the
    # fast path above, just one string test later.
    case "$PT_FP" in
      *"/.claude/jit-context/"*) ;;
      *) echo '{}'; exit 0 ;;
    esac

    # jit_pt_canon_dir(): prints $1's physical location on disk today, resolving
    # symlinks in whatever prefix of it already exists and reattaching whatever is
    # left (which cannot itself contain a symlink, because it does not exist yet) with
    # single slashes. Adapted from jit-init.sh's resolve_dir() -- duplicated rather
    # than shared, because the two scripts do not source a common file for this and
    # adding one is a bigger change than this fix. No `realpath`: jit-init.sh's own
    # comment already established there is none on macOS, and none may be added here
    # either (hooks.md: no new runtime dependency).
    jit_pt_canon_dir() {
      local head="$1" tail="" phys
      while [ ! -d "$head" ]; do
        case "$head" in */*) ;; *) break ;; esac
        tail="${head##*/}${tail:+/}$tail"
        head="${head%/*}"
        [ -n "$head" ] || head="/"
      done
      if [ -d "$head" ]; then
        phys="$(CDPATH='' cd -P "$head" 2>/dev/null && pwd -P)"
        [ -n "$phys" ] && head="$phys"
      fi
      if [ -z "$tail" ]; then
        printf '%s\n' "$head"
      else
        printf '%s/%s\n' "${head%/}" "$tail"
      fi
    }

    JIT_BASE_ABS="$JIT_BASE"
    case "$JIT_BASE_ABS" in
      /*) ;;
      *) JIT_BASE_ABS="$PWD/$JIT_BASE_ABS" ;;
    esac
    JIT_BASE_CANON="$(jit_pt_canon_dir "$JIT_BASE_ABS")"

    PT_FP_ABS="$PT_FP"
    case "$PT_FP_ABS" in
      /*) ;;
      *) PT_FP_ABS="$PWD/$PT_FP_ABS" ;;
    esac
    case "$PT_FP_ABS" in
      */) PT_FP_DIR="${PT_FP_ABS%/}"; PT_FP_BASE="" ;;
      *)  PT_FP_DIR="${PT_FP_ABS%/*}"; PT_FP_BASE="${PT_FP_ABS##*/}" ;;
    esac
    [ -n "$PT_FP_DIR" ] || PT_FP_DIR="/"
    PT_FP_DIR_CANON="$(jit_pt_canon_dir "$PT_FP_DIR")"
    if [ -n "$PT_FP_BASE" ]; then
      PT_FP_CANON="${PT_FP_DIR_CANON%/}/$PT_FP_BASE"
    else
      PT_FP_CANON="$PT_FP_DIR_CANON"
    fi

    case "$PT_FP_CANON" in
      "$JIT_BASE_CANON"/*) ;;
      *) echo '{}'; exit 0 ;;
    esac
    ;;
esac

# `[ -L ]` before the write, the same guard jit_shown_apply() applies to the `shown`
# marks: awk cannot lstat, and although this write never goes through awk, a marker name
# that is actually a symbolic link is exactly as real a trap for a plain bash redirect.
# `2>/dev/null` BEFORE the write, not after -- redirections are applied left to right, so
# with the order reversed the write is the one that can fail while stderr is still the
# session, which is the exact loudness this whole hook exists to avoid (see the matching
# comment on jit_shown_apply() in common.sh).
EDIT_MARK="$JIT_STATE_DIR/edited-$PT_SESSION.txt"
if [ ! -L "$EDIT_MARK" ]; then
  : 2>/dev/null > "$EDIT_MARK"
fi

echo '{}'
