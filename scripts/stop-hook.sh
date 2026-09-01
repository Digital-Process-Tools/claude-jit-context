#!/bin/bash
# claude-jit-context -- Stop hook: reads back the session's own injected-vs-edited record.
#
# #244 (part 2 of #233): #233 asked for this and it was carried out of that PR because
# the signal it needs did not exist. post-tool-hook.sh (also #244) is that signal now --
# an `edited-<session>.txt` marker beside the `shown` marks this project already keeps.
# This hook is the one reader of both marker sets, run once at session end, which is why
# the per-tool-call cost budget that shapes post-tool-hook.sh does not apply here.
#
# THREE STATES, and #244's own body is explicit the third must never render as the
# first:
#
#   * entries fired this session and NONE were edited -- the numbered list #233 asked
#     for, naming every fired entry.
#   * entries fired and SOME were edited -- silence. The healthy case, the same posture
#     SessionStart's own "ok, nothing recurs" already takes (session-start-hook.sh):
#     a hook must never fail hard, and here that includes not nagging about a session
#     that is behaving exactly as intended.
#   * COULD NOT TELL whether anything was edited -- the state directory degraded to
#     empty (common.sh: an unwritable checkout, a linked ancestor), so neither the fired
#     count nor the edit marker can be trusted. This says so rather than falling through
#     to the silent, healthy-looking branch above.
#
# A fourth kind of silence is not one of the three: nothing fired this session at all,
# so there is nothing to compare and nothing worth saying either way.
#
# THE TRAP THIS HOOK DOES NOT REACH FOR: jit_scan_entry_ages() (common.sh) reads
# filesystem mtimes and inherits #243 -- a fresh clone reports every file as "0d old"
# regardless of real history. It is used below ONLY to annotate an entry this hook has
# ALREADY determined, from the real edit marker, was not touched this session -- never
# to decide the fired-vs-edited question itself. Reusing it for that boolean is the
# exact defect #244's own issue body names as the reason this shipped separately from
# #233's other two parts.
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"

# A person can run this by hand with no stdin at all, the same case session-start-hook.sh
# guards against and for the same reason: without the tty guard, awk would sit waiting
# on a payload that will never arrive.
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

# A project that has never heard of this plugin gets nothing -- the same "inert without
# a tree" contract every other hook here holds (tests/test-inert-without-tree.sh).
if [ ! -d "$JIT_BASE" ]; then
  echo '{}'
  exit 0
fi

# The tree exists, but common.sh could not give this process a state directory to read
# back -- an unwritable checkout, or a symbolic link sitting on the way to one. Neither
# the `shown` marks nor an edit marker can have been written this session in that case,
# so there is no fired count and no edit signal to compare: this is state three, and it
# must say so rather than fall through to the silent branches below.
if [ -z "$JIT_STATE_DIR" ] || [ -z "$SESSION_ID" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"jit-context: could not tell whether any entry fired or was edited this session (no session state to read back)"}}\n'
  exit 0
fi

VOCAB_FILE="$JIT_STATE_DIR/vocab-shown-$SESSION_ID.txt"
PATH_FILE="$JIT_STATE_DIR/path-shown-$SESSION_ID.txt"
EDIT_MARK="$JIT_STATE_DIR/edited-$SESSION_ID.txt"

# The `shown` marks carry a handful of sentinel keys beside real entry names --
# `jit-refused-*`, `jit-no-subject` -- written by the same jit_shown_mark() call sites
# a real fired entry uses, so they cannot be told apart by which function wrote them.
# Excluded here the same way jit_shown_apply() already validates a mark line: only a
# bare name survives, everything else (a slash, a backslash, one of the known
# sentinels) is dropped rather than reported as an entry nobody wrote.
JIT_FIRED=""
JIT_FIRED_N=0
for _jit_mf in "$VOCAB_FILE" "$PATH_FILE"; do
  [ -f "$_jit_mf" ] && [ ! -L "$_jit_mf" ] || continue
  while IFS= read -r _jit_name || [ -n "$_jit_name" ]; do
    case "$_jit_name" in
      ''|*/*|*\\*) continue ;;
      jit-refused-*|jit-no-subject) continue ;;
    esac
    case "$JIT_NL$JIT_FIRED$JIT_NL" in
      *"$JIT_NL$_jit_name$JIT_NL"*) continue ;;
    esac
    JIT_FIRED="$JIT_FIRED${JIT_FIRED:+$JIT_NL}$_jit_name"
    JIT_FIRED_N=$((JIT_FIRED_N + 1))
  done < "$_jit_mf"
done
unset _jit_mf _jit_name

# Nothing fired this session at all -- there is no injected-vs-edited comparison to
# make, which is not the same claim as "nothing was edited" and gets no message either
# way.
if [ "$JIT_FIRED_N" -eq 0 ]; then
  echo '{}'
  exit 0
fi

# The one real signal: post-tool-hook.sh (#244) drops this, and only this, when a
# Write or Edit landed under $JIT_BASE this session. Its presence answers the whole
# question; nothing here re-derives it from a timestamp.
if [ -f "$EDIT_MARK" ] && [ ! -L "$EDIT_MARK" ]; then
  echo '{}'
  exit 0
fi

# Ages are read for DISPLAY ONLY, on entries this hook has already decided (from the
# real marker above) were not edited. Only 00-manual is asked, for the same reason
# jit_scan_entry_ages() itself gives: it is the only layer with an author to point at.
# A dimension that does not exist here scans to nothing and costs nothing extra; this
# runs once per session, not once per tool call, so the per-dimension cost budget that
# shapes post-tool-hook.sh does not apply.
JIT_AGES_ALL=""
for _jit_dim in vocabulary tools paths; do
  jit_scan_layers "$JIT_BASE/$_jit_dim" "$_jit_dim"
  jit_scan_entry_ages "$JIT_BASE/$_jit_dim"
  [ -n "$JIT_ENTRY_AGES" ] || continue
  JIT_AGES_ALL="$JIT_AGES_ALL${JIT_AGES_ALL:+$JIT_NL}$JIT_ENTRY_AGES"
done
unset _jit_dim

# "<layer>/<file>\t<days>" is jit_scan_entry_ages()'s own table format (common.sh); the
# key this hook has is a bare file name with no layer, so only the 00-manual row is
# ever looked up. "" is a real answer, not a defect (common.sh's own jit_entry_age()
# comment): an entry outside 00-manual, one this platform could not stat, or one from
# a layer whose whole mtime spread looked like a checkout rather than real history.
jit_age_for() {
  local name="$1" needle
  needle="${JIT_NL}00-manual/$name$(printf '\t')"
  case "$JIT_NL$JIT_AGES_ALL$JIT_NL" in
    *"$needle"*)
      local rest="${JIT_AGES_ALL#*00-manual/"$name"$(printf '\t')}"
      rest="${rest%%$JIT_NL*}"
      printf '%s' "$rest"
      ;;
    *) printf '' ;;
  esac
}

# The numbered list #233 asked for. jit_report_name() (common.sh) is the same guard
# every other maintainer-facing report in this tree applies before printing a name out
# of a committed file -- a bare name that fails it becomes "<withheld: ...>" rather than
# free text riding into a session's own transcript.
JIT_LIST=""
JIT_I=0
while IFS= read -r _jit_name; do
  [ -n "$_jit_name" ] || continue
  JIT_I=$((JIT_I + 1))
  # A hard cap for the same reason JIT_LAYERS_MAX exists: the fired count is chosen by
  # what matched this session, not by this hook, and a report that keeps growing
  # unbounded is the resource #64 already measured and capped once in this codebase.
  if [ "$JIT_I" -gt 200 ]; then
    JIT_LIST="$JIT_LIST\\n  ... and $((JIT_FIRED_N - 200)) more, not listed here"
    break
  fi
  _jit_age="$(jit_age_for "$_jit_name")"
  _jit_shown="$(jit_report_name "$_jit_name")"
  if [ -n "$_jit_age" ]; then
    JIT_LIST="$JIT_LIST\\n  $JIT_I. $_jit_shown (last edited ${_jit_age}d ago)"
  else
    JIT_LIST="$JIT_LIST\\n  $JIT_I. $_jit_shown"
  fi
done <<EOF_FIRED
$JIT_FIRED
EOF_FIRED
unset _jit_name _jit_age _jit_shown

printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"%s entries injected this session, none updated. Fired:%s"}}\n' "$JIT_FIRED_N" "$JIT_LIST"
