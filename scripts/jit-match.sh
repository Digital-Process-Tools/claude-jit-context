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
# json prints one JSON object with `count`, `dropped`, a `matches` array of
# {"file","keywords","mode","text"}, and an `unverifiable` array of the same shape minus
# `mode` -- no jq, no Python: hand-built by the same awk that reads the hook's own output.
# --summary forces the project default to `summary` for this call only (an entry pinned
# `inject: full` still renders full -- the same override JIT_CONTEXT_INJECT=summary gets
# in config.env, reachable per call instead of per project). --limit N keeps the first N
# VERIFIED matched entries and REPORTS what it dropped, by name -- a silent top-N reads as
# "nothing else applied" (#205's own words for why this exists).
#
# --- Why a match can come back "unverifiable" instead of counted ------------------------
#
# .claude/jit-context/ is attacker-controlled input (paths/00-manual/hooks.md). Until
# #219, the hook's own output joined matched entries with a literal "\n---\n# Vocabulary:
# " text boundary that an entry own author-controlled body could legitimately contain --
# so the splitter could not always tell a genuine join from the same bytes sitting inside
# one entry, and a crafted entry could make this tool print a fabricated match with an
# attacker-chosen file name and keyword list. #219 closed that class at the source: the
# hook now prepends a byte-length manifest (see the comment above the manifest-parsing
# block below) that this tool trusts instead of searching for the separator, so the
# splitting itself can no longer be fooled on the path that manifest covers.
#
# This existence check is what remains, kept on purpose rather than removed now that it
# is not the primary guard: every candidate match is checked against the tree's own
# 00-index.tsv before it is counted -- does the (file, keyword) pair it claims actually
# exist as a row? A real match always does, by construction, so this never turns a
# genuine match into a false refusal -- and a candidate that fails is reported once,
# separately, labelled unverifiable rather than silently dropped or silently trusted.
# It is a structural existence check, not a reimplementation of the matcher: it does not
# fold accents, does not decide that a match fired, and does not close the narrower
# residual where a forged entry names ANOTHER real, already-indexed (file, keyword) pair
# from the same tree -- catching that would need the hook own match count, which the
# manifest does not carry either. Added in response to a maintainer override on PR #216,
# over a reviewer finding (block-splitter fabricates a phantom match) this file first
# filed rather than fixed; #219 is the fix that finding asked for.
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
#       layer, a refused config.env line, the hook wrote to stderr (which its own contract,
#       paths/00-manual/hooks.md, says it must never do), or at least one candidate match
#       could not be verified against the tree's own index and was reported unverifiable
#       instead of counted. Verified matches, if any, are still printed. | 2 could not
#       evaluate at all: a bad argument, --base not a project tree, or no text from either
#       --text or stdin.

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

# --- What the tree's own index actually says fired -- used ONLY to VERIFY a candidate
# match, never to derive one. See the big comment above the verification block in the
# awk program below for why this exists and what it does and does not close.
jit_scan_layers "$BASE/vocabulary" vocabulary
VOCAB_LAYERS="$JIT_LAYERS"

# JIT_SAMPLE_CALL=1 tells common.sh this is a diagnostic probe, not a session, so the
# real hook's own logging (_log_hook -> jit_log_write) is a no-op for this call and
# hooks.log stays a clean record of genuine activity -- see the comment above the check
# in common.sh for why a real session has no route to the same suppression (#217).
HOOK_ENV=(CLAUDE_PROJECT_DIR="$PROJECT" JIT_SAMPLE_CALL=1)
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
  -v vocab_layers="$VOCAB_LAYERS" -v vocab_base="$BASE/vocabulary" \
  "$JIT_AWK_JSON$JIT_AWK_ENTRY$JIT_AWK_BLOCKS"'
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
# jit_unescape_blocks() (common.sh, JIT_AWK_BLOCKS) is what this file calls below to
# decode a block-carrying field instead of jit_unescape() alone -- it moved here (#223)
# alongside jit_split_ctx_blocks() for the same reason as that function: jit-dry-run.sh
# report_hook() needs the identical decode before it can trust a block header, and a
# second copy here is what let the two drift out of step in the first place. It replaced
# the two-pass jit_decode_u00(jit_unescape(...)) idiom in #226, fusing both into one walk
# so an entry own escaped backslash can never be mistaken for a genuine \u00XX escape
# once jit_unescape() has already run on it. See its own comment in common.sh.
# --- The tree own index, loaded once, used only to VERIFY -------------------------------
# This does NOT reimplement the matcher. It does not fold accents, does not apply the
# LC_ALL=C keyword-lookup this whole design deliberately leaves to the real hook, and it
# never DECIDES that a match fired -- it only answers a narrower, purely structural
# question: does a (file, keyword) pair the hook claims fired actually exist as a row in
# this tree own 00-index.tsv? A row that does not exist could not have caused a real
# match, whatever the hook output claims.
#
# Why this exists (#202/#205/#189 review, maintainer override on PR #216): the
# index()-based block splitter above cannot tell a genuine hook-emitted join from the
# same literal bytes appearing inside one entry own author-controlled body -- paths/00-
# manual/hooks.md says plainly that .claude/jit-context/ is attacker-controlled input.
# Proven unsolvable from ctx alone: `matched = matched "\n---\n" vh "\n" vc` in
# pre-prompt-hook.sh produces a BYTE-IDENTICAL join to an entry whose own full-mode body
# (raw file content, no fixed ending) happens to end in the same five-plus-header bytes,
# so no property of the SURROUNDING text can ever distinguish the two cases -- reasoned
# through and confirmed against the real hook source, not assumed.
#
# What this DOES close: the specific reproduction that motivated it -- an entry naming a
# file/keyword pair that does not exist anywhere in the tree own index at all. That is a
# decidable, false-positive-free question: every REAL match necessarily corresponds to a
# real index row, by construction, so this can never flag a genuine match.
#
# What this does NOT close, said once rather than reasoned about twice: a forged entry
# that instead names another file own REAL keyword already indexed elsewhere in the SAME
# tree would pass this check too -- verifying existence is not verifying that THIS TEXT
# caused THAT row to fire, and closing that gap needs the hook own match count, which
# only the protocol change the maintainer accepted as out-of-scope reaches. Said in the
# report, not silently narrowed here.
function jit_index_load(   nl, li, layer, lookup, vl, why, vf) {
  if (jit_idx_loaded) return
  jit_idx_loaded = 1
  nl = split(vocab_layers, jit_idx_layers, " ")
  for (li = 1; li <= nl; li++) {
    layer = jit_idx_layers[li]
    lookup = vocab_base "/" layer "/00-index.tsv"
    while ((getline vl < lookup) > 0) {
      why = jit_bad_bytes(vl, "the index row")
      if (why != "") continue
      split(vl, vf, "\t")
      if (vf[1] == "" || vf[2] == "") continue
      jit_idx[vf[2] "\t" vf[1]] = 1
    }
    close(lookup)
  }
}
# mkw may carry more than one keyword, "|"-joined (jit_inject_text/vmatch join multiple
# keywords that matched the same file that way -- see the vmatch[vfile] build in
# pre-prompt-hook.sh). Verified when AT LEAST ONE of them is a real row for mfile: that is
# the OR a real match would satisfy, since any one of them firing is what puts the file in
# vmatch to begin with.
function jit_index_verified(mfile, mkw,   nk, ki, kws) {
  jit_index_load()
  if (mkw == "") return 0
  nk = split(mkw, kws, "|")
  for (ki = 1; ki <= nk; ki++) {
    if ((mfile "\t" kws[ki]) in jit_idx) return 1
  }
  return 0
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
    ctx = jit_unescape_blocks(jit_field(raw, fs[i+2], fe[i+2]))
    break
  }

  nmatch = 0; nnotice = 0
  if (ctx != "") {
    # The manifest-vs-fallback block split is shared with jit-dry-run.sh report_hook()
    # now (#223) -- jit_split_ctx_blocks() in common.sh (JIT_AWK_BLOCKS), carried over
    # verbatim from here rather than reimplemented, so the two consumers cannot drift the
    # way this one drifted out of step with #219 in the first place. It fills jit_blk_n
    # and jit_blk_body[1..jit_blk_n]; jit_index_verified() below is the second, structural
    # check this file still runs on top of it -- see its own comment for what it does and
    # does not close.
    jit_split_ctx_blocks(ctx)
    # #227: jit_blk_manifest_ok is set (0 or 1) by jit_split_ctx_blocks() above and was
    # read by nobody -- 0 means the manifest failed to verify and the split fell back to
    # the pre-#219/#223 heuristic splitter, which an entry body can forge. This tool must
    # never fail hard, so the degrade is named in the injected context instead of an
    # exception -- the same register the "N rule(s) could not be evaluated" notice
    # already uses (common.sh, jit_refusal_notice()) -- and it still counts as a notice
    # below, which already moves this tool off exit 0 the same way an unverifiable match
    # or a refused row does.
    #
    # Gated on !jit_blk_manifest_ok alone (#230): pre-prompt-hook.sh -- the only hook this
    # script ever shells out to -- always builds a manifest now, so "no manifest was ever
    # attempted" is no longer a state a real call here can reach. See the comment above
    # jit_split_ctx_blocks() in common.sh for why the jit_blk_manifest_seen flag this
    # comment used to gate on is gone rather than merely unread.
    if (!jit_blk_manifest_ok) {
      nnotice++
      notice[nnotice] = "# JIT Context: the block manifest could not be evaluated, so this call fell back to a splitter an entry body can forge"
    }
    nb = jit_blk_n
    for (b = 1; b <= nb; b++) {
      body = jit_blk_body[b]
      nl = index(body, "\n")
      header = (nl > 0) ? substr(body, 1, nl - 1) : body
      if (header !~ /^# Vocabulary: /) {
        nnotice++
        notice[nnotice] = body
        continue
      }
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
        # #233: a 00-manual header now carries " · last edited Nd ago" inside the same
        # parenthetical, after the keyword list -- see jit_entry_age() in common.sh and
        # its call sites in pre-prompt-hook.sh/pre-tool-hook.sh. Strip it back off before
        # jit_index_verified() sees mkw, or an entry whose age is being reported would
        # verify against a keyword string the real index never held and land in the
        # unverifiable bucket for a reason that has nothing to do with verification.
        sub(/ \302\267 last edited [0-9]+d ago$/, "", mkw)
      }
      # jit_index_verified() -- see its own comment above -- is a SECOND, structural check
      # on top of the manifest-verified split above (#219): on the manifest path this is
      # no longer what stands between "the splitter cut here" and "this is reported as a
      # real match" -- the byte-exact block boundary already settles that -- but it is
      # still what this tool has on the fallback path, and it is kept unconditionally
      # rather than only when the manifest is absent, since a real match always passes
      # it anyway. A candidate whose claimed (file, keyword) has no row in the tree own
      # index is not counted, not put in matches[], and not silent either: it goes to its
      # own bucket.
      if (jit_index_verified(mfile, mkw)) {
        nmatch++
        mtext[nmatch] = body
        mname[nmatch] = mfile
        mkwlist[nmatch] = mkw
        mmode[nmatch] = (index(body, "\n[jit] Summary only") > 0) ? "summary" : "full"
      } else {
        nunverified++
        utext[nunverified] = body
        uname[nunverified] = mfile
        ukwlist[nunverified] = mkw
      }
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
    out = out "],\"unverifiable\":["
    for (u = 1; u <= nunverified; u++) {
      out = out (u > 1 ? "," : "") \
        "{\"file\":\"" emit_json_str(uname[u]) "\"" \
        ",\"keywords\":\"" emit_json_str(ukwlist[u]) "\"" \
        ",\"text\":\"" emit_json_str(utext[u]) "\"}"
    }
    out = out "]}"
    print out
  } else {
    out = nmatch " entr" (nmatch == 1 ? "y" : "ies") " matched"
    if (dropped > 0) {
      out = out ", " dropped " dropped by --limit " limit ":"
      for (m = kept + 1; m <= nmatch; m++) out = out " " mname[m]
    }
    if (nunverified > 0) out = out ", " nunverified " unverifiable"
    print out
    for (m = 1; m <= kept; m++) print "\n---\n" mtext[m]
    if (nunverified > 0) {
      print "\n--- unverifiable (claimed file/keyword has no row in this tree own index -- NOT counted as a match) ---"
      for (u = 1; u <= nunverified; u++) print "\n" utext[u]
    }
    if (nnotice > 0) {
      print "\n--- notices (not counted as matches) ---"
      for (nt = 1; nt <= nnotice; nt++) print "\n" notice[nt]
    }
  }
  print "JIT-MATCH-STATUS\t" ((nnotice > 0 || nunverified > 0) ? 1 : 0)
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
