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
#   * entries fired this session and NONE were edited -- one line, framed as
#     informational and non-actionable (#292); the numbered, per-entry detail #233
#     originally asked for is unchanged, it just moved to hooks.log. #291/#295 split
#     this state in two, further down: a flat "N entries injected... none updated" when
#     every one of them is backed by a real 00-manual file (the reader authored all of
#     them), or "N entries injected... M of them yours and not updated" when only SOME
#     are -- the entries outside 00-manual have no author this reader can point at, so
#     the flat count used to overstate what was theirs to fix.
#   * entries fired and SOME were edited -- silence. The healthy case, the same posture
#     SessionStart's own "ok, nothing recurs" already takes (session-start-hook.sh):
#     a hook must never fail hard, and here that includes not nagging about a session
#     that is behaving exactly as intended.
#   * COULD NOT TELL whether anything was edited -- the state directory degraded to
#     empty (common.sh: an unwritable checkout, a linked ancestor), so neither the fired
#     count nor the edit marker can be trusted. This says so rather than falling through
#     to the silent, healthy-looking branch above. #291/#295 add a SECOND could-not-tell
#     shape further down: the state directory is fine, but a 00-manual directory itself
#     could not be read, so this hook cannot tell whether a fired entry is the reader's.
#
# A fourth kind of silence is not one of the three: nothing fired this session at all,
# so there is nothing to compare and nothing worth saying either way. #291/#295 add a
# FIFTH kind, further down: entries fired, but every one of them resolves to a layer
# outside 00-manual -- there is nobody for this message to ask, which is the same
# "nothing to compare" shape as the fourth kind, just discovered later in the scan.
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
STOP_HOOK_ACTIVE="false"
if [ ! -t 0 ]; then
  _jit_parsed="$(LC_ALL=C awk "$JIT_AWK_JSON"'
    { input = input $0 }
    END {
      n = jit_json_fields(input, raw, fs, fe)
      print jit_session_key(raw, fs, fe, n)
      print (jit_stop_hook_active(raw, fs, fe, n) ? "true" : "false")
    }
  ' 2>/dev/null)"
  _jit_awk_rc=$?
  if [ "$_jit_awk_rc" -eq 0 ]; then
    SESSION_ID="$(printf '%s\n' "$_jit_parsed" | sed -n 1p)"
    STOP_HOOK_ACTIVE="$(printf '%s\n' "$_jit_parsed" | sed -n 2p)"
    case "$STOP_HOOK_ACTIVE" in
      true|false) ;;
      *) STOP_HOOK_ACTIVE="unknown" ;;
    esac
  else
    # #284: the awk parse itself could not run at all (no usable awk on PATH, a
    # broken interpreter). SESSION_ID and STOP_HOOK_ACTIVE both stay unset in that
    # case, and an unset STOP_HOOK_ACTIVE reads identically to a parsed "false" --
    # which falls through to the JIT_STATE_DIR/SESSION_ID check below, and THAT
    # branch answers with additionalContext, exactly the output that blocks a turn
    # from ending and reopens #279's re-entry loop, in the one state where this hook
    # is least able to notice it is looping. "unknown" is a third value, distinct
    # from both true and false, that takes the SAME silent early return true does --
    # never re-derived from the empty string.
    STOP_HOOK_ACTIVE="unknown"
  fi
  unset _jit_parsed _jit_awk_rc
fi

# #279: the harness re-invokes Stop when THIS hook's own additionalContext blocked the
# previous turn from ending, and marks that re-entry with stop_hook_active=true in the
# very same payload shape this hook already parses above. Printing the same report
# again on the re-entry is exactly what re-triggers it -- nine straight re-entries in
# one live session before the harness gave up and overrode the block. The inert shape
# below is the same one the missing-JIT_BASE branch further down already uses; this
# check runs before that one so a re-entry costs nothing further, regardless of
# whether the tree or state directory can even be resolved.
#
# "unknown" (#284) takes the identical branch: when this hook cannot tell whether the
# harness is re-entering, staying silent is the safe direction -- a Stop hook that
# says nothing costs a missing report; one that speaks costs a turn that will not end.
if [ "$STOP_HOOK_ACTIVE" = "true" ] || [ "$STOP_HOOK_ACTIVE" = "unknown" ]; then
  echo '{}'
  exit 0
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
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"jit-context (about .claude/jit-context/*.md entry files, not addressed to you -- informational only, no action needed): could not tell whether any entry fired or was edited this session (no session state to read back)"}}\n'
  exit 0
fi

VOCAB_FILE="$JIT_STATE_DIR/vocab-shown-$SESSION_ID.txt"
PATH_FILE="$JIT_STATE_DIR/path-shown-$SESSION_ID.txt"
EDIT_MARK="$JIT_STATE_DIR/edited-$SESSION_ID.txt"
# #285: post-tool-hook.sh drops THIS marker, and only this one, on the branch where
# its own symlink guard refused to write EDIT_MARK -- an edit really happened, but its
# evidence was declined. Read below, after the "nothing fired" check and before the
# EDIT_MARK check, so it renders as its own distinguishable fourth state rather than
# folding into either "none updated" (case B: nothing was edited at all) or the
# JIT_STATE_DIR-unknown branch above (case D: this whole state directory could not be
# trusted). A reader who sees this text knows specifically that an edit was attempted
# and its own record of it was refused.
EDIT_DECLINED_MARK="$JIT_STATE_DIR/edited-declined-$SESSION_ID.txt"

# The `shown` marks carry a handful of sentinel keys beside real entry names --
# `jit-refused-*`, `jit-no-subject` -- written by the same jit_shown_mark() call sites
# a real fired entry uses, so they cannot be told apart by which function wrote them.
# Excluded here the same way jit_shown_apply() already validates a mark line: only a
# bare name survives, everything else (a slash, a backslash, one of the known
# sentinels) is dropped rather than reported as an entry nobody wrote.
#
# THE DEDUP SCAN IS BOUNDED, the same shape JIT_LAYERS_MAX and JIT_ENTRY_AGES_MAX
# already give a table an untrusted-in-size tree can grow (common.sh): the `case`
# below re-scans the WHOLE accumulator on every line, so an unbounded accumulator is
# quadratic in the number of distinct names two marker files can hold. In the ordinary
# case each hook already dedups before it ever marks an entry (it loads its own
# `shown` set from this same file before matching), so this cap is never reached by a
# real session; it exists so a two-file union this hook did not write itself cannot
# choose how long Stop takes to answer.
JIT_FIRED_MAX=500
JIT_FIRED=""
JIT_FIRED_N=0
JIT_FIRED_OVERFLOW=0
for _jit_mf in "$VOCAB_FILE" "$PATH_FILE"; do
  [ -f "$_jit_mf" ] && [ ! -L "$_jit_mf" ] || continue
  while IFS= read -r _jit_name || [ -n "$_jit_name" ]; do
    case "$_jit_name" in
      ''|*/*|*\\*) continue ;;
      jit-refused-*|jit-no-subject) continue ;;
    esac
    if [ "$JIT_FIRED_N" -ge "$JIT_FIRED_MAX" ]; then
      # Past the cap, a name is counted but not deduped or stored -- the accumulator
      # stays at its capped size instead of growing, which is the whole point, and the
      # displayed count below may over-count a genuine repeat as a result. That is the
      # same trade-off the codebase already makes elsewhere: bounded cost, not exact
      # accounting, past a size no real session reaches.
      JIT_FIRED_OVERFLOW=$((JIT_FIRED_OVERFLOW + 1))
      continue
    fi
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

# #285: an edit was attempted but post-tool-hook.sh's own symlink guard refused to
# record it. Distinct from both the silent B (nothing edited) and D (state dir
# unknown, checked above): this says so explicitly rather than falling through to the
# "none updated" list below, which would misreport a refused write as a clean session.
if [ -f "$EDIT_DECLINED_MARK" ] && [ ! -L "$EDIT_DECLINED_MARK" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"jit-context (about .claude/jit-context/*.md entry files, not addressed to you -- informational only, no action needed): an edit under this tree may have happened this session but could not be confirmed (marker write was declined)"}}\n'
  exit 0
fi

# #291/#295: the report below is aimed at whoever authors .claude/jit-context/00-manual
# -- the only layer with a human owner, the same reason jit_scan_entry_ages() below
# only ever asks about that layer. An entry that fired from any OTHER layer (plugin-
# shipped, generated) has no file this reader can curate, so counting it toward "none
# updated" asks for maintenance nobody can perform -- #291 documented a completed
# subagent waking three times to answer that line as though it were a task, and #295
# measured a real project where EVERY fired entry lived outside 00-manual, so the nag
# fired on nearly every session with nothing to act on.
#
# This is the SAME "nothing to compare" rule the "nothing fired at all" branch above
# already takes: when no fired name is backed by a real 00-manual file, this exits
# exactly like that branch -- no message, no hooks.log write, because there is nothing
# to log either. Membership is a plain file-existence check, not jit_scan_entry_ages()'s
# own age table further down: that table is deliberately silent whenever a whole
# 00-manual layer's mtimes look like a checkout (#243), and reusing it here would fold
# "not yours" and "yours, but this run could not tell its age" into the same false
# answer.
#
# oss:auditor self-review on this change (finding, live-reproduced): a 00-manual
# directory that EXISTS but cannot be opened (permissions, not absence) makes the glob
# below return nothing -- silently, with no way to tell that apart from a 00-manual
# layer that genuinely holds nothing manual. JIT_MANUAL_SCAN_DEGRADED below names that
# case so the branch further down can render it as its own "could not tell" state
# (test section S) rather than let it undercount into the silent Q/R case, the same
# "third state renders as the first" shape #244's own header already refuses for the state
# directory (case D). A dimension whose 00-manual directory simply does not EXIST is
# not degraded -- that is the ordinary, common case this hook must not warn about.
JIT_MANUAL_SCAN_DEGRADED=0
JIT_MANUAL_NAMES=""
for _jit_dim in vocabulary tools paths; do
  _jit_manual_dir="$JIT_BASE/$_jit_dim/00-manual"
  [ -d "$_jit_manual_dir" ] || continue
  if [ ! -r "$_jit_manual_dir" ] || [ ! -x "$_jit_manual_dir" ]; then
    JIT_MANUAL_SCAN_DEGRADED=1
    continue
  fi
  for _jit_mf in "$_jit_manual_dir"/*; do
    [ -f "$_jit_mf" ] && [ ! -L "$_jit_mf" ] || continue
    JIT_MANUAL_NAMES="$JIT_MANUAL_NAMES${JIT_MANUAL_NAMES:+$JIT_NL}${_jit_mf##*/}"
  done
done
unset _jit_dim _jit_manual_dir _jit_mf

JIT_MANUAL_FIRED_N=0
while IFS= read -r _jit_mname; do
  [ -n "$_jit_mname" ] || continue
  case "$JIT_NL$JIT_MANUAL_NAMES$JIT_NL" in
    *"$JIT_NL$_jit_mname$JIT_NL"*) JIT_MANUAL_FIRED_N=$((JIT_MANUAL_FIRED_N + 1)) ;;
  esac
done <<EOF_MANUAL_CHECK
$JIT_FIRED
EOF_MANUAL_CHECK
unset _jit_mname

# JIT_FIRED_OVERFLOW names entered past the JIT_FIRED_MAX cap above and were never
# individually checked here -- their 00-manual membership is genuinely unknown, not
# "not yours", so their presence forces the split-reporting branch below rather than
# the silent one: reporting an uncertain split is the safe direction, the same
# principle #284's "unknown takes the safe branch" already applies to STOP_HOOK_ACTIVE.
if [ "$JIT_MANUAL_FIRED_N" -eq 0 ] && [ "$JIT_FIRED_OVERFLOW" -eq 0 ]; then
  # oss:auditor self-review finding: a degraded 00-manual read (above) means "zero
  # confirmed manual entries" here could equally mean "genuinely zero" or "could not
  # look" -- distinct from the ordinary silent case, this says so rather than folding
  # into it, the same posture case D already takes for the state directory itself.
  if [ "$JIT_MANUAL_SCAN_DEGRADED" = 1 ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"jit-context (about .claude/jit-context/*.md entry files, not addressed to you -- informational only, no action needed): could not tell whether any fired entry is yours (a 00-manual directory could not be read)"}}\n'
    exit 0
  fi
  echo '{}'
  exit 0
fi

# Ages are read for the MAINTENANCE LOG ONLY (#292), on entries this hook has already
# decided (from the real marker above) were not edited. Only 00-manual is asked, for
# the same reason jit_scan_entry_ages() itself gives: it is the only layer with an
# author to point at. A dimension that does not exist here scans to nothing and costs
# nothing extra; this runs once per session, not once per tool call, so the
# per-dimension cost budget that shapes post-tool-hook.sh does not apply.
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

# #292: the model-facing line built below carries only bare names, one line, no
# per-entry breakdown -- the maintainer decided this reads as an instruction
# otherwise. The numbered, age-annotated detail #233 originally asked for still
# exists, and is NEVER bounded by the 200-name cap below -- only jit_report_name()'s
# own guard applies to it; it moves to hooks.log via jit_log_write() (common.sh: "a
# file on the disk of whoever runs the hook that a person reads and no model does"),
# never dropped and never truncated a second time on top of it. Self-review on this
# change (#292) caught a first draft that applied the SAME 200-entry break to both
# lists at once -- that dropped the 200th fired entry's name from the model line
# while still logging it (an off-by-one in the "N more" count), and separately
# silently truncated hooks.log too, contradicting the model line's own "see
# hooks.log" pointer. Two lists, two caps, decoupled below; tests/test-stop-hook.sh
# section O drives both at 205 fired entries.
JIT_NAMES=""
JIT_LOG_LIST=""
JIT_I=0
while IFS= read -r _jit_name; do
  [ -n "$_jit_name" ] || continue
  JIT_I=$((JIT_I + 1))
  _jit_age="$(jit_age_for "$_jit_name")"
  _jit_shown="$(jit_report_name "$_jit_name")"
  # "; " rather than a literal "\n": hooks.log is one physical line per record
  # (jit-misses.sh parses it that way -- paths/00-manual/hooks.md), so an escaped
  # newline embedded in the text here would be misleading bytes on disk, not an
  # actual line break for whoever reads the file.
  if [ -n "$_jit_age" ]; then
    JIT_LOG_LIST="$JIT_LOG_LIST${JIT_LOG_LIST:+; }$JIT_I. $_jit_shown (last edited ${_jit_age}d ago)"
  else
    JIT_LOG_LIST="$JIT_LOG_LIST${JIT_LOG_LIST:+; }$JIT_I. $_jit_shown"
  fi
  # A hard cap for the same reason JIT_LAYERS_MAX exists: the fired count is chosen by
  # what matched this session, not by this hook, and a report that keeps growing
  # unbounded is the resource #64 already measured and capped once in this codebase --
  # here bounding only the model-facing NAME list; a name past this count is still
  # logged above, just not repeated into the session's own transcript.
  if [ "$JIT_I" -le 200 ]; then
    JIT_NAMES="$JIT_NAMES${JIT_NAMES:+, }$_jit_shown"
  fi
done <<EOF_FIRED
$JIT_FIRED
EOF_FIRED
unset _jit_name _jit_age _jit_shown

if [ "$JIT_FIRED_N" -gt 200 ]; then
  JIT_NAMES="$JIT_NAMES, and $((JIT_FIRED_N - 200)) more (not named here, see hooks.log)"
fi

# JIT_FIRED_OVERFLOW is 0 in the ordinary case (see the cap comment above) -- named
# explicitly only when the collection pass above actually hit it, so the count in the
# ordinary sentence stays exact rather than always carrying a caveat nobody needs.
JIT_TOTAL=$((JIT_FIRED_N + JIT_FIRED_OVERFLOW))
if [ "$JIT_FIRED_OVERFLOW" -gt 0 ]; then
  JIT_NAMES="$JIT_NAMES, plus $JIT_FIRED_OVERFLOW more past this hook's own $JIT_FIRED_MAX-entry cap, not deduplicated or listed"
  JIT_LOG_LIST="$JIT_LOG_LIST; plus $JIT_FIRED_OVERFLOW more past this hook's own $JIT_FIRED_MAX-entry cap, not deduplicated or listed"
fi

# hooks.log keeps the full, unbounded (past the 200 cap above) numbered, age-annotated
# detail the model-facing line below no longer carries -- the maintainer curating
# .claude/jit-context/ reads that file; the model reads only the one line handed to
# additionalContext.
#
# #291/#295: "mixed" here means either a genuine non-00-manual entry among the fired
# set, or the JIT_FIRED_OVERFLOW uncertainty named above -- either way the reader did
# not author every fired entry, so the flat "none updated" sentence overstates what is
# theirs to fix. JIT_MANUAL_FIRED_N against JIT_FIRED_N (not JIT_TOTAL, which folds in
# the overflow count) is deliberate: an overflow-only session with every checked name
# manual-owned still counts as mixed, because the un-checked overflow names are
# unknown, not confirmed non-manual.
#
# Explore self-review finding: when overflow names exist, JIT_MANUAL_FIRED_N is a
# FLOOR, not an exact count -- some of the unchecked overflow names could be manual
# too, and the flat "M of them yours" phrasing read as an exact claim it did not have
# the evidence for. "at least " only appears when that floor is genuinely inexact.
JIT_YOURS_QUALIFIER=""
if [ "$JIT_FIRED_OVERFLOW" -gt 0 ]; then
  JIT_YOURS_QUALIFIER="at least "
fi
if [ "$JIT_MANUAL_FIRED_N" -lt "$JIT_FIRED_N" ] || [ "$JIT_FIRED_OVERFLOW" -gt 0 ]; then
  jit_log_write "$(printf '[%s] stop: %s entries fired this session, %s%s of them yours and not updated. %s' "$(_ts)" "$JIT_TOTAL" "$JIT_YOURS_QUALIFIER" "$JIT_MANUAL_FIRED_N" "$JIT_LOG_LIST")"
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"jit-context (about .claude/jit-context/*.md entry files, not addressed to you -- informational only, no action needed): %s entries injected this session, %s%s of them yours and not updated -- fired: %s"}}\n' "$JIT_TOTAL" "$JIT_YOURS_QUALIFIER" "$JIT_MANUAL_FIRED_N" "$JIT_NAMES"
else
  jit_log_write "$(printf '[%s] stop: %s entries fired this session, none updated. %s' "$(_ts)" "$JIT_TOTAL" "$JIT_LOG_LIST")"
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"jit-context (about .claude/jit-context/*.md entry files, not addressed to you -- informational only, no action needed): %s entries injected this session, none updated -- fired: %s"}}\n' "$JIT_TOTAL" "$JIT_NAMES"
fi
