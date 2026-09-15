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
      # #389 self-review: stripped through the SAME NL-anchored needle the
      # existence check above just proved is present, never through the bare
      # "<key><TAB>" text alone -- an unanchored strip can land inside an
      # unrelated, earlier line whose own longer key happens to end with this
      # key's text immediately before a tab, and silently return that line's
      # byte count instead (see scripts/stop-hook.sh's identical fix).
      rest="${JIT_NL}${BYTES_RAW}${JIT_NL}"
      rest="${rest#*"$needle"}"
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
  # #389 self-review, second pass: the first fix narrowed the needle from a
  # bare ":$file(" to "<layer>:<file>(" but two things about it were still
  # wrong, both caught by re-review after the first fix landed.
  #
  # ONE. `tools` log tokens are never "<layer>:<file>(" at all -- every tools
  # site (pre-tool-hook.sh) writes the FIXED literal prefix "tool:" regardless
  # of which layer the rule lives in ("tool:" r_logname "(" r_match ")"), and
  # a `rule:`-prefixed legacy shown-mark (a hook from before #299, possibly
  # still firing earlier in a session that spans an upgrade) never carried a
  # layer to begin with. Requiring layer for every dimension silently zeroed
  # out `tools` correlation entirely. `tools` now searches "tool:<file>("
  # instead, and does not require a layer at all.
  #
  # TWO. Even the narrower "<layer>:<file>(" needle was still an UNANCHORED
  # substring search within one log line, so a real layer name that happens
  # to be a suffix of a DIFFERENT one ("00-manual" inside "sub-00-manual")
  # could still borrow that other entry's token. hooks.log's own field
  # separator is exactly what jit_log_write()'s callers already build
  # log_matches with -- ", " between tokens, and "| " ahead of the first one
  # -- so this now splits the line on that separator and requires the needle
  # to be a PREFIX of one whole token, never a substring landing mid-token.
  # That is a real anchor, the same kind of guarantee bytes_for() above gets
  # from $JIT_NL: a token boundary a crafted or coincidental key can be a
  # substring of, but can never BE without actually starting there.
  local dim="$1" layer="$2" file="$3" needle line rest tok
  [ -f "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ] || {
    printf ''
    return 0
  }
  case "$dim" in
    tools) needle="tool:$file(" ;;
    paths | vocabulary)
      [ -n "$layer" ] || {
        printf ''
        return 0
      }
      needle="$layer:$file("
      ;;
    *)
      printf ''
      return 0
      ;;
  esac
  line="$(LC_ALL=C grep -F -- "$needle" "$LOG_FILE" 2> /dev/null | tail -1)"
  [ -n "$line" ] || {
    printf ''
    return 0
  }
  rest="${line#*"| "}"
  IFS=',' read -r -a _js_toks <<< "$rest"
  for tok in "${_js_toks[@]+"${_js_toks[@]}"}"; do
    tok="${tok# }"
    case "$tok" in
      "$needle"*)
        tok="${tok#"$needle"}"
        case "$tok" in
          *')'*)
            printf '%s' "${tok%%)*}"
            return 0
            ;;
        esac
        ;;
    esac
  done
  printf ''
  return 0
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
    M="$(match_for "$DIM" "$LAYER" "$NAME")"
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
