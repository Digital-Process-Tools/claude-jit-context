#!/bin/bash
# claude-jit-context -- what fired this session, on what word, and what it cost (#389).
#
# The Stop line (scripts/stop-hook.sh) carries a total and, when every fired entry's
# byte record agrees, a size -- and nothing else. This is where the detail #367
# deliberately pulled off that line goes back to: which entries, which dimension and
# layer, the word or pattern that matched, the bytes each one cost, and what keeps
# missing (scripts/jit-misses.sh).
#
# A DELIBERATE, HAND-RUN diagnostic, not a hook -- paths/00-manual/tooling.md's
# contract, not hooks.md's: fail loudly, exit codes carry meaning, never silently
# guess. See that entry before changing this file.
#
# THE SESSION IT REPORTS IS A HEURISTIC, not a fact, and this prints that up front on
# every run rather than once in a comment nobody sees at the point it matters. A slash
# command's own bash body has no access to the JSON payload's session_id -- that field
# only ever reaches a hook, over stdin, never a command run by a person. So this picks
# the SESSION SUFFIX of the most recently modified marker file under
# JIT_BASE/.discovery/state/ (vocab-shown-<k>.txt, path-shown-<k>.txt or
# bytes-shown-<k>.txt) and reports on that suffix's whole trio. On a project with one
# active session this is exactly right; on a shared checkout with several concurrent
# sessions it can report the wrong one, and this says so rather than pretending
# certainty it does not have.
#
# Exit: 0 a report was produced (which may say "nothing fired yet") | 1 the tree
#       exists but no session state could be found at all | 2 could not evaluate --
#       no JIT_BASE, no state directory, or the marker files could not be read.
#
# Usage: bash scripts/jit-stats.sh [--base DIR] [--misses-top N]

case "$0" in */*) SCRIPT_DIR="${0%/*}" ;; *) SCRIPT_DIR="." ;; esac
MISSES_TOP=20
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || {
        echo "jit-stats.sh: --base needs a value" >&2
        exit 2
      }
      JIT_BASE_OVERRIDE="$2"
      shift 2
      ;;
    --misses-top)
      [ $# -ge 2 ] || {
        echo "jit-stats.sh: --misses-top needs a value" >&2
        exit 2
      }
      MISSES_TOP="$2"
      shift 2
      ;;
    *)
      echo "jit-stats.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
[ -n "${JIT_BASE_OVERRIDE:-}" ] && JIT_BASE="$JIT_BASE_OVERRIDE"

if [ ! -d "$JIT_BASE" ]; then
  echo "jit-stats.sh: no jit-context tree at $JIT_BASE" >&2
  exit 2
fi

STATE_DIR="$JIT_BASE/.discovery/state"
LOG_FILE="$JIT_BASE/.discovery/logs/hooks.log"

if [ ! -d "$STATE_DIR" ]; then
  echo "JIT stats: no session state at all -- nothing has fired yet, or the state directory could not be created (see jit-doctor.sh)"
  exit 1
fi

# The newest of the three marker kinds, by mtime, names the session this reports on.
# `ls -t` rather than `find -newer`: every candidate is a plain file this hook already
# sits beside, so no traversal is needed, and `ls -t`'s own tie-break (name order) is
# stable rather than filesystem-timestamp-resolution-dependent.
NEWEST=""
for _js_f in "$STATE_DIR"/vocab-shown-*.txt "$STATE_DIR"/path-shown-*.txt "$STATE_DIR"/bytes-shown-*.txt; do
  [ -f "$_js_f" ] && [ ! -L "$_js_f" ] || continue
  if [ -z "$NEWEST" ] || [ "$_js_f" -nt "$NEWEST" ]; then NEWEST="$_js_f"; fi
done
unset _js_f

if [ -z "$NEWEST" ]; then
  echo "JIT stats: no marker files under $STATE_DIR -- nothing has fired yet this session"
  exit 1
fi

SESSION_KEY="$(basename "$NEWEST")"
SESSION_KEY="${SESSION_KEY#vocab-shown-}"
SESSION_KEY="${SESSION_KEY#path-shown-}"
SESSION_KEY="${SESSION_KEY#bytes-shown-}"
SESSION_KEY="${SESSION_KEY%.txt}"

echo "JIT stats -- session key: $SESSION_KEY (the most recently written marker file; a heuristic, not the true session id -- see this file's own header)"
echo ""

VOCAB_FILE="$STATE_DIR/vocab-shown-$SESSION_KEY.txt"
PATH_FILE="$STATE_DIR/path-shown-$SESSION_KEY.txt"
BYTES_FILE="$STATE_DIR/bytes-shown-$SESSION_KEY.txt"

# One byte lookup, built once: "<key><TAB><n>" lines, NL-joined, same shape
# stop-hook.sh already reads back -- see #389.
BYTES_RAW=""
if [ -f "$BYTES_FILE" ] && [ ! -L "$BYTES_FILE" ]; then
  while IFS= read -r _jb || [ -n "$_jb" ]; do
    [ -n "$_jb" ] || continue
    BYTES_RAW="$BYTES_RAW${BYTES_RAW:+$JIT_NL}$_jb"
  done < "$BYTES_FILE"
  unset _jb
fi

bytes_for() {
  local key="$1" needle rest
  [ -n "$BYTES_RAW" ] || {
    printf ''
    return 0
  }
  needle="$JIT_NL$key$(printf '\t')"
  case "$JIT_NL$BYTES_RAW$JIT_NL" in
    *"$needle"*)
      rest="${BYTES_RAW#*"$key"$(printf '\t')}"
      rest="${rest%%$JIT_NL*}"
      case "$rest" in
        '' | *[!0-9]*) printf '' ;;
        *) printf '%s' "$rest" ;;
      esac
      ;;
    *) printf '' ;;
  esac
}

# The word or pattern that matched is not in the marker files at all -- only
# hooks.log carries it, one physical line per hook invocation, unconditional
# (paths/00-manual/hooks.md). Correlated here by grepping the entry's own basename
# out of the log's "layer:file(pattern)" token; best-effort for the same reason the
# session key above is -- hooks.log carries no session id column either.
match_for() {
  local dim="$1" file="$2" line
  [ -f "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ] || {
    printf ''
    return 0
  }
  case "$dim" in
    paths) line="$(LC_ALL=C grep -F ":$file(" "$LOG_FILE" 2> /dev/null | tail -1)" ;;
    vocabulary) line="$(LC_ALL=C grep -F ":$file(" "$LOG_FILE" 2> /dev/null | tail -1)" ;;
    tools) line="$(LC_ALL=C grep -F ":$file(" "$LOG_FILE" 2> /dev/null | tail -1)" ;;
    *)
      printf ''
      return 0
      ;;
  esac
  [ -n "$line" ] || {
    printf ''
    return 0
  }
  line="${line#*":$file("}"
  case "$line" in
    *')'*) printf '%s' "${line%%)*}" ;;
    *) printf '' ;;
  esac
}

N_SHOWN=0
for MF in "$VOCAB_FILE" "$PATH_FILE"; do
  [ -f "$MF" ] && [ ! -L "$MF" ] || continue
  while IFS= read -r LN || [ -n "$LN" ]; do
    case "$LN" in
      '') continue ;;
      jit-refused-* | jit-no-subject) continue ;;
    esac
    DIM=""
    LAYER=""
    NAME=""
    case "$LN" in
      loc:*)
        REST="${LN#loc:}"
        DIM="${REST%%:*}"
        REST="${REST#*:}"
        case "$REST" in
          *:*)
            LAYER="${REST%%:*}"
            NAME="${REST#*:}"
            ;;
          *) continue ;;
        esac
        ;;
      rule:*)
        DIM="tools"
        NAME="${LN#rule:}"
        ;;
      */* | *\\*) continue ;;
      *) NAME="$LN" ;;
    esac
    N_SHOWN=$((N_SHOWN + 1))
    B="$(bytes_for "$LN")"
    M="$(match_for "$DIM" "$NAME")"
    printf '%s\n' "$(jit_report_name "$NAME")  dim=${DIM:-unknown} layer=${LAYER:-unknown} bytes=${B:-unknown} matched=${M:-unknown}"
  done < "$MF"
done

if [ "$N_SHOWN" -eq 0 ]; then
  echo "(nothing fired for this session key)"
fi

echo ""
echo "--- recurring misses (scripts/jit-misses.sh) ---"
bash "$SCRIPT_DIR/jit-misses.sh" --log "$LOG_FILE" --top "$MISSES_TOP"

exit 0
