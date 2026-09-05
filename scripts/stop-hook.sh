#!/bin/bash
# claude-jit-context -- Stop hook: reads back the session's own injected-vs-edited record.
#
# #244 (part 2 of #233): #233 asked for this and it was carried out of that PR because
# the signal it needs did not exist. post-tool-hook.sh (also #244) is that signal now --
# an `edited-<session>.txt` marker beside the `shown` marks this project already keeps.
# This hook is the one reader of both marker sets, run once at session end, which is why
# the per-tool-call cost budget that shapes post-tool-hook.sh does not apply here.
#
# #367: what this hook says to a HUMAN moved to `systemMessage`, gated by
# JIT_CONTEXT_STATUS (common.sh, JIT_STATUS) rather than the old JIT_CONTEXT_STOP_REPORT
# -- two different knobs for two different audiences, and this file only ever wrote for
# one of them even before this change (#291/#295: a human curating .claude/jit-context/,
# never the model). JIT_STOP_REPORT is still parsed and validated in common.sh for
# backward config compatibility; nothing in this file reads it any more, because the
# additionalContext line it used to gate no longer exists to gate.
#
# THREE STATES, and #244's own body is explicit the third must never render as the
# first:
#
#   * entries fired this session and NONE were edited -- one line, framed as
#     informational and non-actionable (#292), now the entry COUNT only. #291/#295's
#     "M of them yours" split moved OFF this line with #367: dropping it is what
#     removed this hook's dependency on #299 for the human-facing message (a session
#     with every fired entry outside 00-manual is no longer a nag with nobody to act on
#     it -- it is a neutral fact, so it is said plainly rather than suppressed).
#     hooks.log keeps the fuller split (see #299 below) for whoever curates the tree.
#   * entries fired and SOME were edited -- silence. The healthy case, the same posture
#     SessionStart's own "ok, nothing recurs" already takes (session-start-hook.sh):
#     a hook must never fail hard, and here that includes not nagging about a session
#     that is behaving exactly as intended.
#   * COULD NOT TELL whether anything was edited -- the state directory degraded to
#     empty (common.sh: an unwritable checkout, a linked ancestor), so neither the fired
#     count nor the edit marker can be trusted. This says so rather than falling through
#     to the silent, healthy-looking branch above. #291/#295 add a SECOND could-not-tell
#     shape further down: a 00-manual directory exists but cannot be opened, so this hook
#     cannot tell whether ANY fired entry belongs to the reader -- a systemic readability
#     question, decided once per dimension, independent of which entries actually fired.
#
# A fourth kind of silence is not one of the three: nothing fired this session at all,
# so there is nothing to compare and nothing worth saying either way.
#
# #299: the marker files behind all three dimensions now carry a `loc:<dim>:<layer>:
# <file>` key rather than a bare file name (common.sh: jit_loc_key()), so a fired entry
# says which dimension AND which layer it fired from -- fixing the ownership question
# this hook asks for both shapes #299 measured live: a plugin-owned entry in one
# dimension misreported as the reader's own because an UNRELATED 00-manual file of the
# same basename existed in a different dimension, and `rector.md`, the same collision
# one dimension over, between two LAYERS of vocabulary alone. THREE states again, and
# the second is new: a `loc:`-keyed mark is a known fact (its layer says yours or not);
# a BARE mark -- written by a hook from an earlier version of this plugin, still
# possible inside one session that started before an upgrade landed mid-session -- is
# UNKNOWN, and must render as unknown rather than guessed either way. hooks.log's
# per-session detail line carries this exact three-way split; #299's own tests assert
# all three appear in one message.
#
# THE TRAP THIS HOOK DOES NOT REACH FOR: jit_scan_entry_ages() (common.sh) reads
# filesystem mtimes and inherits #243 -- a fresh clone reports every file as "0d old"
# regardless of real history. It is used below ONLY to annotate an entry this hook has
# ALREADY determined, from the real edit marker, was not touched this session -- never
# to decide the fired-vs-edited question itself. Reusing it for that boolean is the
# exact defect #244's own issue body names as the reason this shipped separately from
# #233's other two parts.
case "$0" in */*) SCRIPT_DIR="${0%/*}" ;; *) SCRIPT_DIR="." ;; esac
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
  ' 2> /dev/null)"
  _jit_awk_rc=$?
  if [ "$_jit_awk_rc" -eq 0 ]; then
    # Two `read`s, not two `sed -n Np` forks over a string this shell is already
    # holding. The here-string supplies the trailing newline both reads need, and a
    # second line that is missing leaves STOP_HOOK_ACTIVE empty -- which the case below
    # already renders as "unknown", exactly as an empty `sed -n 2p` did.
    {
      IFS= read -r SESSION_ID
      IFS= read -r STOP_HOOK_ACTIVE
    } <<< "$_jit_parsed"
    case "$STOP_HOOK_ACTIVE" in
      true | false) ;;
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
#
# #367: systemMessage is NOT known to carry this same re-entry risk -- Claude Code's
# own docs describe additionalContext, never systemMessage, as the field that can hold
# a turn open, and #367/#368's own probes never observed a re-entry from a
# systemMessage-only response. Kept anyway: nothing in this file has measured the
# NEGATIVE (systemMessage definitely cannot re-trigger Stop), and a Stop hook that goes
# quiet on a re-entry it cannot tell apart from a first stop costs a missing status
# line, never a stuck turn -- the same asymmetry #284 already decided on.
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
  if [ "$JIT_STATUS" != "off" ]; then
    printf '{"systemMessage":"JIT : cannot tell what fired (no session state)"}\n'
  else
    echo '{}'
  fi
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
# Excluded here the same way jit_shown_apply() already validates a mark line.
#
# THE DEDUP SCAN IS BOUNDED, the same shape JIT_LAYERS_MAX and JIT_ENTRY_AGES_MAX
# already give a table an untrusted-in-size tree can grow (common.sh): the `case`
# below re-scans the WHOLE accumulator on every line, so an unbounded accumulator is
# quadratic in the number of distinct KEYS two marker files can hold. In the ordinary
# case each hook already dedups before it ever marks an entry (it loads its own
# `shown` set from this same file before matching), so this cap is never reached by a
# real session; it exists so a two-file union this hook did not write itself cannot
# choose how long Stop takes to answer.
#
# #299: deduped by the RAW mark -- the full "loc:dim:layer:file" key for a mark written
# under the new format, or the bare name itself for one written by an older hook this
# session. That is a WIDER identity than the bare file name alone: two marks that share
# a basename but differ in dimension or layer are no longer collapsed into one fired
# entry, which is the same collision #299 measured as `rector.md` (vocabulary/00-manual
# against vocabulary/10-auto) reaching THIS accumulator too, not only the once-per-call
# dedup inside each writer hook. Verified with a fixture (tests/test-marker-loc-299.sh)
# rather than assumed: the issue itself asks this to be checked, not silently patched.
JIT_FIRED_MAX=500
JIT_FIRED_KEYS=""
JIT_FIRED_N=0
JIT_FIRED_OVERFLOW=0
# Parallel arrays, one slot per accepted (deduped) fired mark, same index as each other.
# Arrays rather than a fourth NL-joined string: this loop already builds one per entry
# (name, dimension, layer, classification), and a fifth "is this the Nth line" lookup
# over NL-joined strings in lockstep is more failure-prone than an index a shell array
# already gives for free. Bounded by the same JIT_FIRED_MAX as the dedup key string.
JIT_FIRED_NAME=()
JIT_FIRED_DIM=()
JIT_FIRED_LAYER=()
JIT_FIRED_CLASS=() # Y (00-manual, known), N (another layer, known), U (bare, unknown)
for _jit_mf in "$VOCAB_FILE" "$PATH_FILE"; do
  [ -f "$_jit_mf" ] && [ ! -L "$_jit_mf" ] || continue
  while IFS= read -r _jit_line || [ -n "$_jit_line" ]; do
    case "$_jit_line" in
      '') continue ;;
      jit-refused-* | jit-no-subject) continue ;;
    esac
    _jit_dim=""
    _jit_layer=""
    _jit_class="U"
    case "$_jit_line" in
      loc:*)
        _jit_rest="${_jit_line#loc:}"
        _jit_dim="${_jit_rest%%:*}"
        _jit_rest="${_jit_rest#*:}"
        # A malformed loc: line (no second colon -- a hand-edited marker, an older test
        # fixture) falls through the case below to its own `*) continue` arm: treated
        # as though the line were never there, rather than trusted as evidence of
        # anything, the same posture jit_shown_apply() already takes in common.sh
        # toward a mark line it cannot make sense of.
        case "$_jit_rest" in
          *:*)
            _jit_layer="${_jit_rest%%:*}"
            _jit_name="${_jit_rest#*:}"
            case "$_jit_name" in
              '' | */* | *\\*) continue ;;
            esac
            _jit_class="N"
            [ "$_jit_layer" = "00-manual" ] && _jit_class="Y"
            ;;
          *) continue ;;
        esac
        ;;
      */* | *\\*) continue ;;
      *)
        _jit_name="$_jit_line"
        _jit_class="U"
        ;;
    esac
    if [ "$JIT_FIRED_N" -ge "$JIT_FIRED_MAX" ]; then
      JIT_FIRED_OVERFLOW=$((JIT_FIRED_OVERFLOW + 1))
      continue
    fi
    case "$JIT_NL$JIT_FIRED_KEYS$JIT_NL" in
      *"$JIT_NL$_jit_line$JIT_NL"*) continue ;;
    esac
    JIT_FIRED_KEYS="$JIT_FIRED_KEYS${JIT_FIRED_KEYS:+$JIT_NL}$_jit_line"
    JIT_FIRED_NAME[$JIT_FIRED_N]="$_jit_name"
    JIT_FIRED_DIM[$JIT_FIRED_N]="$_jit_dim"
    JIT_FIRED_LAYER[$JIT_FIRED_N]="$_jit_layer"
    JIT_FIRED_CLASS[$JIT_FIRED_N]="$_jit_class"
    JIT_FIRED_N=$((JIT_FIRED_N + 1))
  done < "$_jit_mf"
done
unset _jit_mf _jit_line _jit_dim _jit_layer _jit_class _jit_rest _jit_name

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
  if [ "$JIT_STATUS" != "off" ]; then
    printf '{"systemMessage":"JIT : an edit here may not have been recorded (marker write declined)"}\n'
  else
    echo '{}'
  fi
  exit 0
fi

# #291/#295/#299: a 00-manual directory that EXISTS but cannot be OPENED (permissions,
# not absence) is a systemic readability question, answered once per dimension and
# independent of which entries actually fired -- unlike #299's per-entry Y/N/U
# classification above, which needs no directory read at all, because a `loc:` key
# already says which layer an entry fired from. A dimension whose 00-manual directory
# simply does not exist is the ordinary case and is not degraded.
JIT_MANUAL_SCAN_DEGRADED=0
for _jit_dim in vocabulary tools paths; do
  _jit_manual_dir="$JIT_BASE/$_jit_dim/00-manual"
  [ -d "$_jit_manual_dir" ] || continue
  if [ ! -r "$_jit_manual_dir" ] || [ ! -x "$_jit_manual_dir" ]; then
    JIT_MANUAL_SCAN_DEGRADED=1
  fi
done
unset _jit_dim _jit_manual_dir

if [ "$JIT_MANUAL_SCAN_DEGRADED" = 1 ]; then
  if [ "$JIT_STATUS" != "off" ]; then
    printf '{"systemMessage":"JIT : cannot tell if any fired entry is yours (00-manual unreadable)"}\n'
  else
    echo '{}'
  fi
  exit 0
fi

# Ages are read for the MAINTENANCE LOG ONLY (#292), on entries this hook has already
# decided (from the real edit marker above) were not edited. Only 00-manual is asked,
# for the same reason jit_scan_entry_ages() itself gives: it is the only layer with an
# author to point at. A dimension that does not exist here scans to nothing and costs
# nothing extra; this runs once per session, not once per tool call, so the
# per-dimension cost budget that shapes post-tool-hook.sh does not apply.
#
# #299: prefixed with the DIMENSION at concatenation time (jit_scan_entry_ages() itself
# is unchanged and untouched -- its own table still carries "<layer>/<file>", the same
# shape every other caller already relies on) so jit_age_for() below can be scoped by
# dimension too. Before this, "install.md" existing as 00-manual in both `paths` and
# `vocabulary` made JIT_AGES_ALL ambiguous about which one a lookup meant -- the same
# cross-consumer ambiguity #299's own issue names as pre-existing for this exact
# function, now closed by the same loc: information rather than left as a separate
# open question.
JIT_AGES_ALL=""
for _jit_dim in vocabulary tools paths; do
  jit_scan_layers "$JIT_BASE/$_jit_dim" "$_jit_dim"
  jit_scan_entry_ages "$JIT_BASE/$_jit_dim"
  [ -n "$JIT_ENTRY_AGES" ] || continue
  _jit_dim_ages=""
  while IFS= read -r _jit_age_line; do
    [ -n "$_jit_age_line" ] || continue
    _jit_dim_ages="$_jit_dim_ages${_jit_dim_ages:+$JIT_NL}$_jit_dim/$_jit_age_line"
  done << EOF_DIM_AGES
$JIT_ENTRY_AGES
EOF_DIM_AGES
  [ -n "$_jit_dim_ages" ] || continue
  JIT_AGES_ALL="$JIT_AGES_ALL${JIT_AGES_ALL:+$JIT_NL}$_jit_dim_ages"
done
unset _jit_dim _jit_dim_ages _jit_age_line

# "<dim>/<layer>/<file>\t<days>" now (see above). Looked up by dimension AND name, so a
# lookup can never answer about the wrong dimension's identically-named file. "" is a
# real answer, not a defect (common.sh's own jit_entry_age() comment): an entry outside
# 00-manual, one this platform could not stat, one from a layer whose whole mtime
# spread looked like a checkout, or one this hook could not even attribute to a
# dimension (the unknown/bare-mark case -- dim is "" there, and the needle below can
# never match, which is correct: an age claim needs a dimension to be about).
jit_age_for() {
  local dim="$1" name="$2" needle
  [ -n "$dim" ] || {
    printf ''
    return 0
  }
  needle="${JIT_NL}$dim/00-manual/$name$(printf '\t')"
  case "$JIT_NL$JIT_AGES_ALL$JIT_NL" in
    *"$needle"*)
      local rest="${JIT_AGES_ALL#*"$dim"/00-manual/"$name"$(printf '\t')}"
      rest="${rest%%$JIT_NL*}"
      printf '%s' "$rest"
      ;;
    *) printf '' ;;
  esac
}

# #292: the model-facing line built below carries only the entry COUNT -- #367 dropped
# the per-name list and the ownership split from the human-facing line entirely (there
# is no wrong number left to show once the split moved to hooks.log alone). The
# numbered, age-annotated, per-name detail #233 originally asked for still exists in
# hooks.log, unbounded except by jit_report_name()'s own guard, and now carries the
# Y/N/U split #299 asks for.
JIT_NAMES=""
JIT_LOG_LIST=""
JIT_YOURS_N=0
JIT_NOT_YOURS_N=0
JIT_UNKNOWN_N=0
JIT_I=0
while [ "$JIT_I" -lt "$JIT_FIRED_N" ]; do
  _jit_name="${JIT_FIRED_NAME[$JIT_I]}"
  _jit_dim="${JIT_FIRED_DIM[$JIT_I]}"
  _jit_layer="${JIT_FIRED_LAYER[$JIT_I]}"
  _jit_class="${JIT_FIRED_CLASS[$JIT_I]}"
  case "$_jit_class" in
    Y) JIT_YOURS_N=$((JIT_YOURS_N + 1)) ;;
    N) JIT_NOT_YOURS_N=$((JIT_NOT_YOURS_N + 1)) ;;
    *) JIT_UNKNOWN_N=$((JIT_UNKNOWN_N + 1)) ;;
  esac
  _jit_age="$(jit_age_for "$_jit_dim" "$_jit_name")"
  _jit_shown="$(jit_report_name "$_jit_name")"
  case "$_jit_dim" in
    tools) _jit_shown="$_jit_shown (tools)" ;;
    paths) _jit_shown="$_jit_shown (paths)" ;;
  esac
  case "$_jit_class" in
    U) _jit_shown="$_jit_shown [unknown: marker from an older hook this session]" ;;
    N) _jit_shown="$_jit_shown [$_jit_layer]" ;;
  esac
  JIT_I=$((JIT_I + 1))
  # "; " rather than a literal "\n": hooks.log is one physical line per record
  # (jit-misses.sh parses it that way -- paths/00-manual/hooks.md).
  if [ -n "$_jit_age" ]; then
    JIT_LOG_LIST="$JIT_LOG_LIST${JIT_LOG_LIST:+; }$JIT_I. $_jit_shown (last edited ${_jit_age}d ago)"
  else
    JIT_LOG_LIST="$JIT_LOG_LIST${JIT_LOG_LIST:+; }$JIT_I. $_jit_shown"
  fi
  if [ "$JIT_I" -le 200 ]; then
    JIT_NAMES="$JIT_NAMES${JIT_NAMES:+, }$_jit_shown"
  fi
done
unset _jit_name _jit_dim _jit_layer _jit_class _jit_age _jit_shown

if [ "$JIT_FIRED_N" -gt 200 ]; then
  JIT_NAMES="$JIT_NAMES, and $((JIT_FIRED_N - 200)) more (not named here, see hooks.log)"
fi

# JIT_FIRED_OVERFLOW names entered past the JIT_FIRED_MAX cap above and were never
# individually classified -- unknown, not "not yours", the same reasoning #284 already
# applies to STOP_HOOK_ACTIVE: an uncertain split is reported as uncertain rather than
# folded into a confident count on either side.
JIT_TOTAL=$((JIT_FIRED_N + JIT_FIRED_OVERFLOW))
if [ "$JIT_FIRED_OVERFLOW" -gt 0 ]; then
  JIT_UNKNOWN_N=$((JIT_UNKNOWN_N + JIT_FIRED_OVERFLOW))
  JIT_NAMES="$JIT_NAMES, plus $JIT_FIRED_OVERFLOW more past this hook's own $JIT_FIRED_MAX-entry cap, not deduplicated or listed"
  JIT_LOG_LIST="$JIT_LOG_LIST; plus $JIT_FIRED_OVERFLOW more past this hook's own $JIT_FIRED_MAX-entry cap, not deduplicated or listed"
fi

# hooks.log keeps the full, unbounded (past the 200 cap above) numbered, age-annotated
# detail -- written unconditionally, on every branch, regardless of JIT_STATUS. #299:
# the three counts below are the fixture this issue asks for -- a session with both a
# `loc:`-keyed mark and a bare one asserts all three appear in the SAME message.
jit_log_write "$(printf '[%s] stop: %s entries fired this session, %s yours, %s not yours, %s unknown, not updated. %s' \
  "$(_ts)" "$JIT_TOTAL" "$JIT_YOURS_N" "$JIT_NOT_YOURS_N" "$JIT_UNKNOWN_N" "$JIT_LOG_LIST")"

# #367: the human-facing line is the total alone -- JIT_CONTEXT_STATUS=fired and
# =summary render it identically here, because "fired" already said one line per entry
# AS IT FIRED, in the hook that fired it; Stop only ever adds the running total.
if [ "$JIT_STATUS" != "off" ]; then
  printf '{"systemMessage":"JIT : %s %s this session"}\n' "$JIT_TOTAL" "$([ "$JIT_TOTAL" = 1 ] && echo entry || echo entries)"
else
  echo '{}'
fi
