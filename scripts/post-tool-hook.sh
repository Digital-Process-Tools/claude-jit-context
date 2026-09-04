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
# WHY POSTTOOLUSE, KEYED ON Write|Edit|Bash. It is the only candidate that OBSERVES an
# edit rather than inferring one. jit_scan_entry_ages() (common.sh) already exists and
# reads filesystem mtimes -- and it inherits #243: on a fresh clone every mtime is
# checkout time, so a signal built on it would report "nothing was updated" on a
# session where everything was, with no way to tell which. That is the trap this hook
# exists to avoid, not a second way to reach the same table. Bash joined the matcher
# for #301: a tree that routes every edit through Bash (a `mode: block` tools rule on
# Edit/Write/MultiEdit/NotebookEdit is the documented case) produced a real edit under
# $JIT_BASE this hook could never observe under Write|Edit alone. The Bash branch
# below is a heuristic over the command text, not a second event-observation
# mechanism -- see its own comment for why, and for the false-negative bias it
# deliberately takes.
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
# COST (#244's own constraint, widened by #301): this fires on every Write, Edit and
# Bash call in a stranger's session -- Bash alone is a much higher-volume tool than
# Write/Edit ever were, most calls having nothing to do with this project's own tree.
# `hooks/hooks.json` narrows PostToolUse to those three tools via its own matcher, and
# after the one JSON parse below the very first thing this script does, on every path,
# is a zero-fork substring test against the free-text subject (file_path for Write/Edit,
# command for Bash) -- never a match against the index, never a fork at all -- for a
# call whose edit has nothing to do with this project's tree. The Bash branch (below)
# never reaches canonicalisation at all -- it has no file_path to canonicalise -- so it
# adds no further fork past its own second, still-zero-fork write-form test.
#
# For Write/Edit, #286 changed what happens once the substring test passes:
# canonicalisation (the forking part) is no longer a rare fallback gated behind a
# second, lexical, $JIT_BASE-prefix
# test -- it now runs on every file_path that reaches this point, including the
# ordinary in-tree edit this hook exists to observe. That is a deliberate trade: the
# substring test is still the one thing that keeps every OTHER session's edit at zero
# forks, and the edits that do reach canonicalisation are, by construction, either a
# real edit to this project's own tree or an attempt to look like one.
#
# A hook must never fail hard (hooks.md): every exit below answers `{}`.
case "$0" in */*) SCRIPT_DIR="${0%/*}" ;; *) SCRIPT_DIR="." ;; esac
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
# `awk` reads stdin itself; the `cat` in front of it was one fork per invocation buying
# nothing. The `$(cat)` further down is a different question and stays -- see there.
PT_PARSED="$(LC_ALL=C awk "$JIT_AWK_JSON"'
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  tool = ""; fp = ""; cmd = ""
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    k = raw[fs[i]]
    if (k == "tool_name") tool = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "file_path" && fp == "") fp = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "path" && fp == "") fp = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "command" && cmd == "") cmd = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
  }
  if (tool !~ /^[A-Za-z_]+$/ || length(tool) > 32) tool = ""
  # A Bash payload carries no file_path at all -- its free-text subject is `command`.
  # Folded into the same third printed line as file_path/path rather than adding a
  # fourth: exactly one of the two is ever populated, because tool_name (checked in
  # bash below) already decides which shape the payload is.
  if (fp == "") fp = cmd
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

# #301: `hooks/hooks.json`'s PostToolUse matcher used to be Write|Edit only, so a tree
# that routes every edit through Bash instead -- a `mode: block` tools rule refusing
# Edit/Write/MultiEdit/NotebookEdit, or any wrapper/formatter that shells out -- had a
# real write under $JIT_BASE this hook never observed. No marker was ever written on
# such a tree, and stop-hook.sh read that permanent absence as the positive claim
# "none updated" -- unsilenceable by doing the right thing, because the one signal it
# trusts could never fire. Bash now reaches this hook (matcher widened above); its
# own branch, below, decides whether a command LOOKS like a write into the tree,
# because unlike Write/Edit it carries no `file_path` this hook can canonicalise.
case "$PT_TOOL" in
  Write|Edit|Bash) ;;
  *) echo '{}'; exit 0 ;;
esac

if [ -z "$PT_FP" ] || [ -z "$PT_SESSION" ] || [ -z "$JIT_STATE_DIR" ]; then
  echo '{}'
  exit 0
fi

if [ "$PT_TOOL" = "Bash" ]; then
  # PT_FP holds the raw command text here, not a path -- #301's own gap is that a
  # Bash payload gives this hook no `file_path` to canonicalise the way Write/Edit's
  # does below, and no honest general answer exists for "does this shell command
  # write that file" from the text alone (the same limit
  # tools/00-manual/no-shell-writes-to-the-index.md already documents for the
  # sibling problem one file over: a shell reaches the same bytes through a
  # variable, a heredoc, a script it invokes, or a language runtime). So this stays
  # a heuristic, not a parse, and it is deliberately biased toward a false NEGATIVE
  # over a false positive: with the model-facing report now opt-in and off by
  # default (#300), the cost of missing a real Bash-routed edit is a nag that stays
  # silent when it could have cleared -- annoying, not wrong -- while the cost of a
  # false positive would be marking "edited" on a session that only READ the tree,
  # silently hiding a genuine "none updated" the reader should have seen. Two gates,
  # both required:
  #
  #   1. the command mentions this project's jit-context tree at all (the same
  #      zero-fork substring literal the Write/Edit path uses below, so a command
  #      naming nothing under any tree costs nothing extra); and
  #   2. it also carries one of the write forms actually typed against a file: a
  #      `>`/`>>` redirect, `tee`, an in-place `sed`/`perl`, or this project's own
  #      mandated write path -- `supertool 'edit:@-'`/`'paste:@-'`/`'git-commit:@-'`
  #      (agents/developer.md and this repo's own CLAUDE.md both require every
  #      write to route through one of those three ops).
  #
  # A command that only reads or greps the tree -- `cat`, `grep`, `ls`, an argument
  # that merely NAMES a jit-context path -- passes gate 1 and fails gate 2, so it
  # marks nothing, the same as a Write/Edit call outside the tree does below.
  #
  # oss:auditor self-review on #301 (reasoned, not observed): this literal is
  # forward-slash only, the same as the Write/Edit path's own substring test below.
  # A Bash command built around a backslash-separated path (a native Windows tool
  # invoked from inside Git Bash, say) would miss this gate and mark nothing --
  # already the accepted direction for this heuristic (see the false-negative-bias
  # note above), not a new failure mode, and the Windows CI leg's own shell is Git
  # Bash, which itself emits forward-slash paths -- so the gap is narrow in
  # practice and untested here rather than measured as reachable.
  case "$PT_FP" in
    *"/.claude/jit-context/"*) ;;
    *) echo '{}'; exit 0 ;;
  esac
  # Explore self-review on #301 (live-reproduced, both fixed here):
  #
  #   1. An unanchored `*'sed'*'-i'*` substring test cannot tell a real `-i` FLAG
  #      from those same two letters appearing inside an argument for an unrelated
  #      reason -- `sed 's/x/y/' -- ./-improved.md` never writes anything (no -i,
  #      no redirect), but its last path component starts with "-i" and used to
  #      mark regardless.
  #   2. An unanchored `*"supertool"*"'edit:"*` substring test cannot tell the
  #      words "supertool 'edit:" actually being INVOKED from those same bytes
  #      merely appearing inside an unrelated argument -- `echo "reminder: never
  #      run supertool 'edit:@-' carelessly"` writes nothing and used to mark too.
  #
  # Both are still substring tests, not a parse -- the "no honest general answer"
  # limit tools/00-manual/no-shell-writes-to-the-index.md documents for the sibling
  # problem still applies -- but each is now anchored on a command-word BOUNDARY
  # (start of string, or after `;`, `&`, `|`), the same anchoring idiom that rule's
  # own regex already uses for the identical reason. That closes both live
  # reproductions above without claiming a level of precision this heuristic was
  # never going to have; a case still exists where `-i` is a flag to a DIFFERENT
  # program on the same command line and gets swept in by the trailing `.*` -- the
  # same over-approximation the sibling rule accepts for the same class of input.
  #
  # `grep -E`, not another `case`, because a command-word boundary needs
  # alternation across an anchor a POSIX glob cannot express; this branch only
  # reaches here after gate 1 above has already limited it to commands that
  # mention this tree, so the one extra fork is bounded to that narrow subset, not
  # paid by every Bash call in the session.
  if LC_ALL=C printf '%s' "$PT_FP" | grep -Eq \
    '(^|[;&|])[[:space:]]*(sed|perl)([[:space:]][^;&|]*)?[[:space:]](-[a-z]*i|--in-place)[^;&|]*|(^|[;&|])[[:space:]]*tee([[:space:]]|$)|(^|[;&|])[[:space:]]*supertool[[:space:]]+.(edit|paste|git-commit):'
  then
    :
  elif printf '%s' "$PT_FP" | grep -qF '>'; then
    :
  else
    echo '{}'
    exit 0
  fi
  EDIT_MARK="$JIT_STATE_DIR/edited-$PT_SESSION.txt"
  if [ ! -L "$EDIT_MARK" ]; then
    : 2>/dev/null > "$EDIT_MARK"
  else
    EDIT_DECLINED_MARK="$JIT_STATE_DIR/edited-declined-$PT_SESSION.txt"
    if [ ! -L "$EDIT_DECLINED_MARK" ]; then
      : 2>/dev/null > "$EDIT_DECLINED_MARK"
    fi
  fi
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

# #286: canonicalisation used to run ONLY on the branch below, reached when the cheap
# lexical prefix test says "outside the tree" -- because #276 already knew that test is
# lexical, not physical, and can miss a file that IS inside the tree (see the three
# routes named below). What #276 did not cover: a path that is lexically INSIDE
# $JIT_BASE but physically outside it -- a symlink planted inside
# ".claude/jit-context/" itself, pointing elsewhere -- takes the OTHER branch, the one
# that was trusted on the lexical test alone, and never reached the canonical check at
# all. That is a false-positive marker for an edit that did not actually land in the
# tree, the opposite direction from #276's false negative, same misreport shape.
#
# Restructured to one call site rather than two: the lexical prefix test above is
# replaced by the cheap substring test alone as the ONLY zero-fork gate (JIT_BASE's
# tail is always the literal ".claude/jit-context" -- common.sh builds no other shape --
# so a file_path that does not contain that substring anywhere cannot be inside ANY
# project's jit-context tree, canonical or not, and is rejected here with zero forks,
# still the fast path for almost every OTHER session's edit, which is what this hook's
# header promises to hold the cost to). Anything that passes the substring test now
# ALWAYS reaches the canonical check below, whether or not it also happened to pass the
# old lexical prefix test -- so the physically-outside-but-lexically-inside case can no
# longer skip it.
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
else
  # #285: the guard above tripped -- a symlink sits at the marker's own name -- so the
  # write above never happened, and stop-hook.sh reading that absence would read it as
  # the positive claim "nothing was edited", which is false: an edit DID land, only its
  # evidence was refused. This branch already knows it is declining, which is the only
  # place this trace is allowed to cost anything (the ordinary A/B paths above never
  # reach here). Same `[ -L ]`-before-write guard, same left-to-right redirection
  # ordering, for the same reason: this new marker name is exactly as real a symlink
  # target as EDIT_MARK itself.
  EDIT_DECLINED_MARK="$JIT_STATE_DIR/edited-declined-$PT_SESSION.txt"
  if [ ! -L "$EDIT_DECLINED_MARK" ]; then
    : 2>/dev/null > "$EDIT_DECLINED_MARK"
  fi
fi

echo '{}'
