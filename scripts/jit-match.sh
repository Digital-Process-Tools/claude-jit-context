#!/bin/bash
# claude-jit-context -- "which entries does this text call for?", answerable from outside
# a session (#205).
#
# A headless run (`claude -p`) sends exactly one prompt, usually built from paths rather
# than prose, so the vocabulary dimension matches almost nothing on the runs that would
# benefit most from it. The run usually DOES have prose -- the issue or ticket it was
# launched for -- just not in a form UserPromptSubmit ever sees. This is the supported way
# to ask the plugin what that prose calls for, without a caller resolving the version-
# numbered plugin cache path or hand-building a hook payload itself.
#
# Usage:
#   bash scripts/jit-match.sh --base DIR --text "the new component does not autocomplete"
#   printf '%s' "$TICKET_BODY" | bash scripts/jit-match.sh --base DIR
#   bash scripts/jit-match.sh --base DIR --text "..." --format json --summary --limit 3
#
# --base must be a `<project>/.claude/jit-context` path (default: ./.claude/jit-context,
# the tree you are standing in -- same convention as jit-dry-run.sh, and for the same
# reason: JIT_BASE resolves against $CLAUDE_PROJECT_DIR, never the current directory, so
# this has to point AT a project rather than assume it is standing inside one).
#
# --text is the prose to match. Omit it to read stdin instead -- an issue body is often
# long enough that a caller would rather pipe it than quote it.
#
# --format text (default) prints one block per matched entry, human-readable. --format
# json prints one JSON object with `count`, `dropped` and a `matches` array of
# {"file","keywords","mode","text"} -- no jq, no Python: hand-built by the same awk that
# reads the hook's own output. --summary forces the project default to `summary` for this
# call only (an entry pinned `inject: full` still renders full -- the same override
# JIT_CONTEXT_INJECT=summary gets in config.env, reachable per call instead of per project).
# --limit N keeps the first N matched entries and REPORTS what it dropped, by name -- a
# silent top-N reads as "nothing else applied" (#205's own words for why this exists).
#
# --- Why this shells out to pre-prompt-hook.sh instead of reimplementing the match ------
#
# #205 asks explicitly not to reimplement it: this hook's LC_ALL=C pin, its Latin-1 fold
# table (jit_fold_latin1 in common.sh) and its fail-open-loudly behaviour on a malformed
# byte took several rounds to get right (#14, #15, #31, #68, #76), and a second matcher
# reading the same index would drift from the first the next time only one of them is
# fixed. jit-dry-run.sh already established the pattern this follows: its own --prompt
# sample call runs the REAL pre-prompt-hook.sh as a subprocess with CLAUDE_PROJECT_DIR
# pointed at the target project, and reads its actual stdout. This does the same, then
# goes one step further and decodes the JSON it gets back into structured, per-entry
# output -- which jit-dry-run.sh's own report_hook() deliberately does not do, because it
# is a LINT report (what fired, what it cost) and not a content feed.
#
# --- The shown-set is never touched ------------------------------------------------------
#
# #205 asks explicitly: don't touch the shown-set by default, and don't expose
# --session-id. The payload built below carries no "session_id" key. jit_session_key() in
# common.sh returns "" for a payload with none, jit_shown_file() returns "" for an empty
# key, and every shown-set read/write in the hook is a no-op against an empty path (see
# jit_shown_load/jit_shown_mark in common.sh) -- the same shape jit-dry-run.sh's own
# sample calls already rely on.
#
# Exit: 0 every row could be evaluated (a match, or cleanly none) | 1 ran, but the hook
#       also reported something it could not evaluate -- a refused index row, a refused
#       layer, a refused config.env line, or the hook wrote to stderr, which its own
#       contract (paths/00-manual/hooks.md) says it must never do. Matches, if any, are
#       still printed. | 2 could not evaluate at all: a bad argument, --base not a project
#       tree, or no text from either --text or stdin.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

BASE="$PWD/.claude/jit-context"
TEXT=""
TEXT_SET=0
FORMAT="text"
SUMMARY=0
LIMIT=0

usage() {
  sed -n '2,42p' "$0"
  exit "${1:-0}"
}

need_value() {
  echo "jit-match: SKIPPED -- $1 needs a value" >&2
  echo "  run with --help for the accepted flags. Nothing was checked." >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)    [ $# -ge 2 ] || need_value "$1"; BASE="$2"; shift 2 ;;
    --text)    [ $# -ge 2 ] || need_value "$1"; TEXT="$2"; TEXT_SET=1; shift 2 ;;
    --format)  [ $# -ge 2 ] || need_value "$1"; FORMAT="$2"; shift 2 ;;
    --limit)   [ $# -ge 2 ] || need_value "$1"; LIMIT="$2"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "jit-match: SKIPPED -- unknown argument: $1" >&2; usage 2 ;;
  esac
done

BASE="${BASE%/}"

case "$FORMAT" in
  text|json) : ;;
  *)
    echo "jit-match: SKIPPED -- --format must be text or json, got: $FORMAT" >&2
    echo "  Nothing was checked." >&2
    exit 2
    ;;
esac

case "$LIMIT" in
  ''|*[!0-9]*)
    echo "jit-match: SKIPPED -- --limit must be a non-negative integer, got: $LIMIT" >&2
    echo "  Nothing was checked." >&2
    exit 2
    ;;
esac

# jit-match shells out to pre-prompt-hook.sh with CLAUDE_PROJECT_DIR pointed at a project,
# the same constraint jit-dry-run.sh's --prompt sample call carries -- there is no project
# directory to run the hook against otherwise, and guessing one from --base's parent would
# accept a --base that happens to look right and quietly ask the hook a question about the
# wrong tree (#183 is this whole plugin's name for that failure mode).
case "$BASE" in
  */.claude/jit-context) PROJECT="${BASE%/.claude/jit-context}" ;;
  *)
    echo "jit-match: SKIPPED -- --base must be a <project>/.claude/jit-context path, got: $BASE" >&2
    echo "  jit-match runs the real hook against a project directory; there is nothing to point it at." >&2
    exit 2
    ;;
esac

if [ ! -d "$BASE" ]; then
  echo "jit-match: SKIPPED -- no such directory: $BASE" >&2
  echo "  Nothing was checked. This is not a clean result." >&2
  exit 2
fi

if [ "$TEXT_SET" = 0 ]; then
  if [ -t 0 ]; then
    echo "jit-match: SKIPPED -- no text. Pass --text \"...\" or pipe text on stdin." >&2
    echo "  Nothing was checked." >&2
    exit 2
  fi
  # $( ) drops a trailing newline and, per paths/00-manual/tests.md, a NUL byte anywhere
  # in the middle -- acceptable here because the subject is prose, never a fixed-format or
  # binary payload, and the same acceptance jit-dry-run.sh's own --prompt already makes.
  TEXT="$(cat)"
fi

if [ -z "$TEXT" ]; then
  echo "jit-match: SKIPPED -- the text is empty." >&2
  echo "  Nothing was checked." >&2
  exit 2
fi

# --- Build the payload -------------------------------------------------------------------
# No session_id: see the header comment. Escaped per RFC 8259's minimal set -- the same
# five characters jit_json_escape() escapes in every hook, because this is the payload the
# SAME hook decodes with jit_unescape(). Slurp mode (-0777) so an embedded real newline in
# a multi-line ticket body is escaped rather than splitting perl's own record.
json_escape() {
  printf '%s' "$1" | LC_ALL=C perl -0777 -pe '
    s/\\/\\\\/g;
    s/"/\\"/g;
    s/\t/\\t/g;
    s/\r/\\r/g;
    s/\n/\\n/g;
  '
}

PAYLOAD="{\"prompt\":\"$(json_escape "$TEXT")\"}"

HOOK_ENV=(CLAUDE_PROJECT_DIR="$PROJECT")
if [ "$SUMMARY" = 1 ]; then
  HOOK_ENV+=(JIT_CONTEXT_INJECT=summary)
fi

# HOOK_STDERR_CHECKED is its own flag rather than a sentinel packed into HOOK_STDERR: an
# earlier version used a non-empty placeholder string for "could not check" and the exit
# logic below tested `[ -n "$HOOK_STDERR" ]`, which is true for BOTH a real violation and
# a check that never ran -- a hook that behaved perfectly was reported as having broken
# its own never-write-to-stderr contract, on any platform where mktemp happens to fail.
# Third state, own variable: "found a violation", "checked and clean" and "could not
# check" must not collapse to two.
HOOK_STDERR_CHECKED=0
ERRF="$(mktemp "${TMPDIR:-/tmp}/claude-jit-match-XXXXXXXX" 2>/dev/null)" || ERRF=""
if [ -n "$ERRF" ]; then
  HOOK_OUT="$(printf '%s' "$PAYLOAD" | env "${HOOK_ENV[@]}" bash "$SCRIPT_DIR/pre-prompt-hook.sh" 2>"$ERRF")"
  HOOK_STDERR="$(cat "$ERRF" 2>/dev/null)"
  HOOK_STDERR_CHECKED=1
  rm -f "$ERRF"
else
  HOOK_OUT="$(printf '%s' "$PAYLOAD" | env "${HOOK_ENV[@]}" bash "$SCRIPT_DIR/pre-prompt-hook.sh" 2>/dev/null)"
  HOOK_STDERR=""
fi

# --- Decode the hook's own JSON, and split additionalContext into blocks -----------------
# jit_json_fields()/jit_unescape() are the exact functions the hooks use to read THEIR
# payload -- this reads the hook's own reply the same way rather than inventing a second
# JSON reader. Splitting on "\n---\n" is the exact separator pre-prompt-hook.sh joins
# blocks with; a block whose first line opens "# Vocabulary: " is a matched entry, and
# anything else (a refused-row notice, a refused-layer notice, a refused-config notice) is
# reported as a NOTICE rather than silently folded into the match count.
#
# Everything this awk has to say goes to stdout, prefixed on ONE line: `JIT-MATCH-STATUS`
# carrying 0 or 1, last, so bash can pull it back out and use it for the exit code without
# a second channel to keep in sync with the report above it.
RESULT="$(printf '%s' "$HOOK_OUT" | LC_ALL=C awk \
  -v format="$FORMAT" -v limit="$LIMIT" \
  "$JIT_AWK_JSON"'
function emit_json_str(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  for (jit_c00 = 0; jit_c00 <= 31; jit_c00++) {
    if (jit_c00 == 9 || jit_c00 == 10 || jit_c00 == 13) continue
    jit_c00_ch = sprintf("%c", jit_c00)
    if (length(jit_c00_ch) == 0) continue
    if (index(s, jit_c00_ch) > 0) gsub(jit_c00_ch, sprintf("\\u%04x", jit_c00), s)
  }
  return s
}
# jit_unescape() (common.sh) never decodes \uXXXX -- it was written for a hook reading a
# CLIENT-built prompt field, which this codebase own encoders never emit \u for. But
# pre-prompt-hook.sh IS one of this codebases own encoders: its jit_json_escape() escapes
# the whole 0x00-0x1F range (skipping \t \n \r, which get their own two-letter escape)
# as \u00XX, exactly the range emit_json_str() above re-escapes on the way back out. Left
# alone, jit_unescape() passes an unrecognised \u escape through as six literal
# characters (see its own `else { o = o c nx; ...}` arm) -- syntactically harmless, but the
# original control byte is gone, replaced by visible text that was never in the entry.
# This reverses PRECISELY the range pre-prompt-hook.sh can produce and nothing wider: a
# \uXXXX above 0x1F never comes from this hook, and decoding it here would need a UTF-8
# assembly step no awk here is trusted to do (JIT_AWK_JSON own header comment says so of
# an unrecognised escape generally).
function jit_decode_u00(s,   out, i, n, c, hx, v) {
  # No index()-based early-return guard here: a first version tried `index(s, "\u00") ==
  # 0`, a PLAIN STRING LITERAL with an escape awk itself does not define ("\u" is not one
  # of \n \t \r \\ \" and the rest) -- exactly the trap this repository already documents
  # for a REGEX carrying \s \d \w, just relocated into a string constant instead. Measured
  # on gawk 5.4.1: the guard fired on every call, "no marker found", and the byte was
  # never restored, silently -- while the identical-looking loop below, whose \\u00 lives
  # inside an ERE literal rather than a string literal, compiled and matched correctly on
  # BOTH engines. So there is no guard: the walk below is O(length(s)) either way, and it
  # is the one thing here proven to agree across engines.
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\" && substr(s, i, 6) ~ /^\\u00[0-9a-fA-F][0-9a-fA-F]$/) {
      hx = tolower(substr(s, i + 4, 2))
      v = index("0123456789abcdef", substr(hx, 1, 1)) - 1
      v = v * 16 + index("0123456789abcdef", substr(hx, 2, 1)) - 1
      out = out sprintf("%c", v)
      i += 6
      continue
    }
    out = out c
    i++
  }
  return out
}
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  ctx = ""
  # Stride 2, matching pre-prompt-hook.sh own scan for "prompt": a quoted key is always
  # followed by ONE more field holding the colon (and, for a nested object, the opening
  # brace too) before the next quoted field -- the value, or the next nested key. This
  # response is a fixed, known shape (this script own hook, this script own envelope), so
  # jumping straight to i+2 for the value is exact rather than a guess.
  for (i = 1; i + 2 <= n; i++) {
    if (fs[i] != fe[i]) continue
    if (jit_field(raw, fs[i], fe[i]) != "additionalContext") continue
    ctx = jit_decode_u00(jit_unescape(jit_field(raw, fs[i+2], fe[i+2])))
    break
  }

  nmatch = 0; nnotice = 0
  if (ctx != "") {
    # A block boundary is "\n---\n" ONLY when it is immediately followed by the start
    # of the next top-level block -- "# Vocabulary: " or "# JIT Context: " (the fixed
    # headers jit_refusal_notice()/jit_layers_notice()/jit_config_notice() and the vocab
    # match loop write). A "---" INSIDE a matched entry is common and not a boundary: an
    # entry injected in full mode carries its own frontmatter delimiters verbatim, and
    # splitting blindly on "\n---\n" cut a one-entry match into three pieces the first
    # time this was driven against a real fixture.
    #
    # index()-based scan, not split(FS): one-true-awk 20200816 (macOS) turned a single
    # control-byte FS into "split on every embedded newline too" the moment the string
    # being split carried a real newline anywhere in it -- reproduced in isolation, not
    # reasoned about, and unrelated to whether the FS came from a literal or sprintf(%c).
    # A manual walk over occurrences has no FS for that engine to reinterpret.
    rest = ctx
    nb = 0
    while (1) {
      p1 = index(rest, "\n---\n# Vocabulary: ")
      p2 = index(rest, "\n---\n# JIT Context: ")
      if (p1 == 0 && p2 == 0) { nb++; blocks[nb] = rest; break }
      if (p1 == 0) p = p2
      else if (p2 == 0) p = p1
      else p = (p1 < p2) ? p1 : p2
      nb++
      blocks[nb] = substr(rest, 1, p - 1)
      rest = substr(rest, p + 5)
    }
    for (b = 1; b <= nb; b++) {
      body = blocks[b]
      nl = index(body, "\n")
      header = (nl > 0) ? substr(body, 1, nl - 1) : body
      if (header !~ /^# Vocabulary: /) {
        nnotice++
        notice[nnotice] = body
        continue
      }
      nmatch++
      mfile = header
      sub(/^# Vocabulary: /, "", mfile)
      sub(/ \(matched:.*$/, "", mfile)
      # Bounded on the FIRST ")" after "(matched: ", not on the end of header -- header
      # runs past it (00-manual carries a "\n[vocab-upkeep] ..." tail that is not a real
      # newline, see the comment above jit_json_escape() in pre-prompt-hook.sh for why),
      # and anchoring on $ picked up that whole tail as part of the keyword list.
      mkw = ""
      if (match(header, /\(matched: [^)]*\)/)) {
        mkw = substr(header, RSTART + 10, RLENGTH - 11)
      }
      mtext[nmatch] = body
      mname[nmatch] = mfile
      mkwlist[nmatch] = mkw
      mmode[nmatch] = (index(body, "\n[jit] Summary only") > 0) ? "summary" : "full"
    }
  }

  kept = nmatch
  dropped = 0
  if (limit > 0 && nmatch > limit) { kept = limit; dropped = nmatch - limit }

  if (format == "json") {
    out = "{\"count\":" nmatch ",\"dropped\":" dropped ",\"matches\":["
    for (m = 1; m <= kept; m++) {
      out = out (m > 1 ? "," : "") \
        "{\"file\":\"" emit_json_str(mname[m]) "\"" \
        ",\"keywords\":\"" emit_json_str(mkwlist[m]) "\"" \
        ",\"mode\":\"" mmode[m] "\"" \
        ",\"text\":\"" emit_json_str(mtext[m]) "\"}"
    }
    out = out "],\"dropped_files\":["
    for (m = kept + 1; m <= nmatch; m++) out = out (m > kept + 1 ? "," : "") "\"" emit_json_str(mname[m]) "\""
    out = out "]}"
    print out
  } else {
    out = nmatch " entr" (nmatch == 1 ? "y" : "ies") " matched"
    if (dropped > 0) {
      out = out ", " dropped " dropped by --limit " limit ":"
      for (m = kept + 1; m <= nmatch; m++) out = out " " mname[m]
    }
    print out
    for (m = 1; m <= kept; m++) print "\n---\n" mtext[m]
    if (nnotice > 0) {
      print "\n--- notices (not counted as matches) ---"
      for (nt = 1; nt <= nnotice; nt++) print "\n" notice[nt]
    }
  }
  print "JIT-MATCH-STATUS\t" (nnotice > 0 ? 1 : 0)
}
'
)"

AWK_STATUS="$(printf '%s\n' "$RESULT" | awk -F'\t' '/^JIT-MATCH-STATUS\t/ { s = $2 } END { print s + 0 }')"
printf '%s\n' "$RESULT" | grep -v '^JIT-MATCH-STATUS'"$(printf '\t')"

EXIT=0
if [ "$HOOK_STDERR_CHECKED" = 1 ] && [ -n "$HOOK_STDERR" ]; then
  echo "" >&2
  echo "jit-match: NOTE -- pre-prompt-hook.sh wrote to stderr, which its own contract says" >&2
  echo "  it must never do. What matched above, if anything, is not the whole answer:" >&2
  printf '%s\n' "$HOOK_STDERR" | sed 's/^/  /' >&2
  EXIT=1
elif [ "$HOOK_STDERR_CHECKED" = 0 ]; then
  # Not promoted to exit 1: nothing was FOUND wrong, only left unverified, and jit-doctor.sh
  # already sets the precedent for that distinction -- its own "cannot tell" answers are
  # real, first-class outcomes that do not move an exit code, because a confident claim of
  # a defect that was never actually observed is worse than saying plainly it was not
  # checked. Always printed, on stderr, so this state is never silent either.
  echo "" >&2
  echo "jit-match: NOTE -- no temp file was available to check pre-prompt-hook.sh's stderr." >&2
  echo "  This is not a clean result: whether it kept its never-write-to-stderr contract" >&2
  echo "  was not checked, one way or the other. What matched above is not verified against it." >&2
fi
[ "$AWK_STATUS" = "1" ] && EXIT=1

exit "$EXIT"
