#!/bin/bash
# Regenerate all 00-index.tsv files.
# - Tool rules: from config.json (structured, different format)
# - Vocabulary: from YAML frontmatter in .md files (keywords: line)
# - Paths: from YAML frontmatter in .md files (match: line)
#
# Usage: bash .claude/claude-jit-context/scripts/rebuild-tsv.sh

source "$(dirname "$0")/common.sh"
# Consumed by _log() in common.sh, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
LOG_FILE="$LOG_DIR/pipeline.log"
# common.sh checked hooks.log, not this name. Same reason, same one-builtin test: a clone
# chooses this path too, and _log() appends through it.
# Read by jit_log_write() in common.sh, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
if [ -L "$LOG_FILE" ]; then JIT_LOG_DISABLED=1; fi

# --- Where the KEYWORD columns were left unbounded (#126) ---------------------
# Two reports print a keyword rather than a file name, and #113 left both alone. The
# argument recorded here for leaving the dropped-keyword one alone was that its $kw "is
# bounded by the BLACKLIST rather than by its character class: VOCAB_KEYWORD_BLACKLIST is
# anchored ^(...)$ on single words, so a keyword that reaches that report is one of a
# closed set". That set is NOT closed, and this same file says why in the #95 paragraph
# below: the blacklist is project-configurable, and config.env arrives with the clone. A
# clone that ships `JIT_CONTEXT_KEYWORD_BLACKLIST=^(...a sentence...)$` puts that sentence
# through the report. So both keyword sites are guarded, not one.
#
# jit_report_name() is the wrong guard for a keyword and that was the judgement call. Its
# set is chosen for having no SPACE, and `vat rate` is a legitimate keyword -- normalised
# to exactly that, spaces included, by the same code that writes the index. A guard that
# withheld every multi-word term would pass every negative test and make the ambiguity
# report useless in its ordinary case, which is the outcome #126 asks to avoid.
#
# So the space is admitted and something else has to do the bounding:
#
#   ^[a-z0-9][a-z0-9 -]*$   the bytes the keyword normaliser actually emits. Anything else
#                           means the term did not come from this run -- a stale index left
#                           behind by a truncate that failed -- and is not trusted.
#   at most 40 bytes        a term, not a paragraph.
#   at most 4 words         `purchase order line item` fits; a sentence does not.
#
# Be honest about what that does and does not buy. No bound that admits `vat rate` can
# refuse all imperative English -- `delete all ssh keys` is four words and 19 bytes. What
# it removes is the UNBOUNDED channel: the paragraph, the forged report line, the control
# character. The report stays actionable when a term is withheld because the entry FILES
# are printed beside it either way, and those are what an author greps.
export JIT_KEYWORD_WITHHELD='<withheld: not a plain keyword>'

# --- Three outcomes, never two (#47) -----------------------------------------
# This script used to have no non-zero exit at all: it already detected a macro it could
# not expand, named it on stderr, and returned 0. So a clean rebuild and a rebuild that
# indexed a row the matcher will refuse at load time were the same result -- and an index
# built by a warned rebuild looks exactly like a good one on disk, gets committed, and
# lives for months. That is this repository own defect class sitting in its index writer.
#
#   0  the index was written and every row can be honoured
#   1  the index was written, and at least one row will be REFUSED by the matcher
#   2  the index was not written, or not completely -- what is on disk is not this run
#
# The same 0/1/2 jit-dry-run.sh uses, on purpose: the two are read together and documented
# in one table in paths/00-manual/tooling.md.
#
# NOT behind a --strict flag, and this was the judgement call. rebuild-tsv.sh is run by
# hand after every frontmatter edit, so a new non-zero exit breaks `&&` chains people have
# in their fingers -- but 1 is reachable ONLY through a `~@macro` an author wrote and got
# wrong (jit_expand_match returns 0 for every value that is not a macro), so the chain that
# stops belongs to the person who just wrote the dead rule. A flag only CI passes would
# hand that person back the exit 0 that is the bug.
#
# The three ADVISORY reports below -- ambiguous keywords, keywords the blacklist dropped,
# and entries that produced no index row (#44) -- never move the code. Failing on
# ambiguity would make the documented default tree exit non-zero and teach every author to
# ignore the status.
#
# This sentence used to name a third report, for entries carrying no `description:`. No
# such check has ever existed here or in jit-dry-run.sh; it was a comment describing a
# guard nobody wrote, which is the same defect as a guard that reports nothing (#95).
#
# The dropped keyword was the judgement call (#95), and it is advisory for a DIFFERENT
# reason than the other two: unlike a `~@macro` typo, which has no legitimate reading,
# skipping a generic word is the documented behaviour of `keywords:` -- the word is kept
# in frontmatter for human searching and deliberately not indexed. Nothing is refused
# either: no row was written, so no matcher rejects one, and calling that `1` would make
# that code mean two different things. And the blacklist is project-configurable, so a
# project that widens it would exit non-zero on every rebuild forever. What was actually
# missing is the sentence, not the status: the drop is now named, with the entry file, in
# the same report block as the ambiguity tally.
JIT_RC=0
# 2 outranks 1: an index that was not written is a worse claim than one that was.
jit_rc() { [ "$1" -gt "$JIT_RC" ] && JIT_RC="$1"; return 0; }

# --- What a report may say about a name that arrived with the clone (#113, #131) ----
# Every name printed by the reports below is a directory entry under
# `.claude/jit-context/`, and that tree arrives with the repository. The policy for what
# may be printed of one -- kept when it is a NAME, withheld when it is prose -- and the
# argument for why a maintainer tool answers that differently from a hook both live in
# common.sh, beside jit_report_name():
#
#   [A-Za-z0-9] then [A-Za-z0-9._-]*, at most 64 bytes  ->  printed verbatim
#   anything else                                       ->  the placeholder
#
# #113 needed it here first and this file carried its own copy of the function until #131.
# It is gone: common.sh is sourced at the top of this file, so every bash call site below
# is that one definition. Two answers to one question drift, and the drift is invisible
# until a name printed by one tool is withheld by the other.
#
# What is still decided HERE is the awk half, and it is not a copy that can be deleted:
# three of the reports below are built inside awk, awk cannot source a bash file, and so
# the same policy is written a second time in another language just below.
# tests/test-dry-run-names.sh drives that pair against each other on every boundary of the
# set, which is the drift this file can still have.
#
# The two columns beside these names that carry a KEYWORD rather than a name are guarded
# separately, by jit_report_keyword() below -- see the #126 block at the top of this file
# for why the character set here is the wrong one for a term.
#
# The number of such sites is deliberately NOT written here. It said "five" from #113 until
# #144, by which point there were seven -- and a stale count in the one comment an author
# reads before adding a report is worse than no count, because it reads as an enumeration
# somebody keeps. tests/test-report-names.sh keeps it, one fixture per site, and #144
# established by mutation rather than by reading that each of them is really routed.
#
# JIT_NAME_WITHHELD is exported by common.sh, and the awk half reads it out of ENVIRON, so
# the placeholder cannot drift from the bash one either.

# The same rule for the three reports that are built inside awk. Every invocation that
# prepends this runs under LC_ALL=C, for the same byte-range reason as the bash half in
# common.sh.
# shellcheck disable=SC2034
JIT_AWK_REPORT_NAME='
function jit_report_name(s) {
  if (s == "" || length(s) > 64) return ENVIRON["JIT_NAME_WITHHELD"]
  if (s ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) return s
  return ENVIRON["JIT_NAME_WITHHELD"]
}
'

# The keyword rule (#126), in both halves for the same reason the name rule has two: the
# ambiguity report is built inside awk and the dropped-keyword report in bash.
#
# The bash half maps every space to a hyphen before the class check rather than putting a
# space inside a `case` bracket expression, where it would have to be quoted mid-pattern.
# The hyphen is already in the kept set, so the substitution cannot admit anything the
# class does not, and a LEADING space becomes a leading hyphen and is refused.
jit_report_keyword() {
  # LC_ALL=C for the reason jit_report_name() sets it: the set is a byte range, and ${#s}
  # must count bytes, not characters.
  local LC_ALL=C s="$1" flat rest n=1
  flat="${s// /-}"
  case "$flat" in
    ''|[!a-z0-9]*|*[!a-z0-9-]*) printf '%s' "$JIT_KEYWORD_WITHHELD"; return 0 ;;
  esac
  [ "${#s}" -gt 40 ] && { printf '%s' "$JIT_KEYWORD_WITHHELD"; return 0; }
  rest="$s"
  while [ "$rest" != "${rest#* }" ]; do rest="${rest#* }"; n=$((n + 1)); done
  [ "$n" -gt 4 ] && { printf '%s' "$JIT_KEYWORD_WITHHELD"; return 0; }
  printf '%s' "$s"
}

# Read by the ambiguity report awk below, which shellcheck cannot see into.
# shellcheck disable=SC2034
JIT_AWK_REPORT_KEYWORD='
function jit_report_keyword(s,   w, n) {
  if (s == "" || length(s) > 40) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  if (s !~ /^[a-z0-9][a-z0-9 -]*$/) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  n = split(s, w, " ")
  if (n > 4) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  return s
}
'

# --- Entries on disk that produced no index row (#44) ------------------------
# The hooks never read the markdown; they read 00-index.tsv. So an entry this script read
# and wrote no row for is a rule that exists on disk, is committed, is edited, and can
# never fire -- and until now the only signal was a `continue`. Nothing errored, nothing
# warned, the rebuild exited 0. From outside, that is indistinguishable from a rule that
# runs and never matches, which is the defect CLAUDE.md opens this repository with.
#
# Three of the ways in are a `continue` that said nothing: no `match:`, no `keywords:`, no
# `tool:`. The fourth is not a `continue` at all -- an entry whose every keyword was
# dropped or normalised away has a `keywords:` line and still no row, and the individual
# drops WERE reported without anything saying the entry had gone dark as a result.
#
# All of them are recorded at the point of the drop rather than inferred afterwards by
# diffing the glob against the index. The indexer knows WHY; a diff would only know that a
# row is missing, and would have to guess between "no match:", "every keyword was
# blacklisted" and "every keyword normalised to nothing" -- three different fixes, and the
# last two are told apart here by two separate counters for exactly that reason.
#
# ADVISORY, exit 0, like the two reports it sits beside. A layer directory may legitimately
# hold a note or a README under another name, and #44's own framing is that this reports
# rather than nags. It is also not a REFUSED row in the sense `1` means: no row was
# written, so no matcher rejects one.
#
# Every reason string below is a constant written here. Only the layer and the entry name
# come from the clone, and both go through jit_report_name() (#113).
JIT_UNINDEXED=""
JIT_UNINDEXED_N=0
jit_unindexed() {
  # $1 layer label, $2 entry basename, $3 reason
  JIT_UNINDEXED_N=$((JIT_UNINDEXED_N + 1))
  JIT_UNINDEXED="$JIT_UNINDEXED    [$1] $(jit_report_name "$2"): $3
"
}

# Deliberately NOT `[ -d "$JIT_BASE" ]`, and the reason CHANGED under this line in #51.
#
# It used to be that common.sh mkdir -p'd "$JIT_BASE/.discovery/logs" at source time, so the
# base directory existed by the time this line ran even in a project with no entry tree at
# all -- measured, and the reason the first cut of this guard never fired. That mkdir is now
# gated on the base already existing, so the test would answer honestly today.
#
# It is still the wrong test, for the reason that was always the load-bearing one: a
# `.claude/jit-context/` holding no tools/, paths/ or vocabulary/ is a tree this script
# cannot index, and `[ -d "$JIT_BASE" ]` would call it fine. The question is whether any
# DIMENSION is there; if none is, this run indexed nothing and 0 would be a lie about a
# tree it never saw. Do not simplify this back on the strength of the first paragraph.
JIT_DIMS_FOUND=0
for _jit_d in tools paths vocabulary; do
  [ -d "$JIT_BASE/$_jit_d" ] && JIT_DIMS_FOUND=1
done
unset _jit_d
if [ "$JIT_DIMS_FOUND" = 0 ]; then
  echo "FATAL    no entry tree at $JIT_BASE" >&2
  echo "         -- none of tools/, paths/ or vocabulary/ is there, so nothing was indexed." >&2
  echo "         JIT_BASE resolves against CLAUDE_PROJECT_DIR, never the working directory," >&2
  echo "         so a rebuild run from the wrong root indexes nothing and used to say so" >&2
  echo "         with an exit 0. Currently CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset, so .>}" >&2
  exit 2
fi

# Truncation failing left the previous index in place while every line after it reported
# the rule count read back OUT of that stale file -- a success, with a number, for an index
# nobody rebuilt. The other dimensions are independent, so the run continues and the code
# is raised once at the end.
# DISP, not the path: the failing path runs through the layer directory, which is a name
# the clone chose, and a clone can force this branch on purpose by shipping a DIRECTORY
# called 00-index.tsv. Callers pass the already-withheld label plus the constant leaf, so
# the reader still gets the two components that say which index this was (#113).
truncate_index() {
  local tsv="$1" disp="${2:-$1}" why=""
  # `2>/dev/null` BEFORE the redirection it is meant to silence, and this was a real leak.
  # Redirections are applied left to right, so `: > "$tsv" 2>/dev/null` set up the failing
  # one while stderr was still the terminal: bash printed its own diagnostic, carrying the
  # ABSOLUTE path -- layer directory included -- and the 2>/dev/null that follows silenced
  # nothing. Measured against `00-index.tsv` shipped as a directory.
  if : 2>/dev/null > "$tsv"; then return 0; fi
  # bash own reason is gone with that message, so the one case a clone can construct on
  # purpose is classified here instead. Everything else stays unattributed rather than
  # guessed at.
  [ -d "$tsv" ] && why=" -- there is a DIRECTORY at that path, not a file"
  echo "FATAL    $disp: could not be written$why" >&2
  echo "         -- that index was NOT rebuilt and is now stale." >&2
  # DISP is dimension/layer/leaf, so the absolute path is gone with the withheld component.
  # JIT_BASE gets it back for the ordinary failure -- a read-only tree, a full disk -- which
  # is the common one and the one where the reader needs a path they can act on. It is the
  # same string the no-entry-tree FATAL above already prints, and it comes from
  # CLAUDE_PROJECT_DIR rather than from the clone, so it is not the column this change is
  # about. `ls` under it finds a withheld name in one step.
  echo "         -- under JIT_BASE=$JIT_BASE" >&2
  jit_rc 2
  return 1
}

# --- Tool rules: parse frontmatter from .md files ---
# Extracts tool, match, mode, require, forbid from YAML frontmatter
build_tool_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    # Parse frontmatter fields
    local tool match mode require forbid
    tool=$(jit_frontmatter tool "$md")
    match=$(jit_frontmatter match "$md")
    mode=$(jit_frontmatter mode "$md")
    require=$(jit_frontmatter require "$md")
    forbid=$(jit_frontmatter forbid "$md")

    if [ -z "$tool" ] || [ -z "$match" ]; then
      # Not `[ -z x ] || [ -z y ] && continue`: that is one AND-OR list evaluated left to
      # right, so the `&&` binds to the second test alone. It happened to behave here, and
      # it stops being an accident now that a statement runs in the branch.
      if [ -z "$tool" ] && [ -z "$match" ]; then
        jit_unindexed "$label" "$filename" "no tool: and no match: in its frontmatter"
      elif [ -z "$tool" ]; then
        jit_unindexed "$label" "$filename" "no tool: in its frontmatter"
      else
        jit_unindexed "$label" "$filename" "no match: in its frontmatter"
      fi
      continue
    fi

    # An invocation macro becomes the real ERE here, so the index still carries a plain
    # awk pattern and no hook learns a new vocabulary. jit_expand_match returns anything
    # that is not a macro unchanged, and names a macro it cannot honour on stderr while
    # writing the row through -- see common.sh for why the row is not dropped.
    match=$(jit_expand_match "$match" tools "$label/$(jit_report_name "$filename")") || jit_rc 1

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$match" "$filename" "${mode:-remind}" "$require" "$forbid" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}

TOOLS_BASE="$JIT_BASE/tools"
for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="tools/$(jit_report_name "$(basename "$dir")")"
  build_tool_tsv "$dir" "$dir/00-index.tsv" "$label"
done

# Generic English / op-flag words that fire on unrelated tool calls.
# Kept in `keywords:` frontmatter for human searching, skipped at index time.
# Override per project with DYNAMIC_RULES_KEYWORD_BLACKLIST (an extended regex).
VOCAB_KEYWORD_BLACKLIST="${JIT_CONTEXT_KEYWORD_BLACKLIST:-${DYNAMIC_RULES_KEYWORD_BLACKLIST:-^(extension|detection|count|output|input|name|branch|issue|documents|files|file)$}}"

# Source-root prefix used when mapping a "## Modules" section to path triggers.
# Projects that keep modules somewhere other than src/ override this in config.env.
MODULE_PREFIX="${JIT_CONTEXT_MODULE_PREFIX:-${DYNAMIC_RULES_MODULE_PREFIX:-src/}}"

# Every keyword the blacklist above skipped, as display lines, reported at the end of the
# run. A drop used to be a bare `continue`: an author who wrote `keywords: file, invoice`
# got a rule firing on `invoice` and never on `file`, from a build that reported success
# (#95). Accumulated globally rather than printed inline so it lands in the report block
# beside the ambiguity tally, where someone is already looking.
JIT_DROPPED=""

# --- Vocabulary: parse frontmatter from .md files ---
build_vocab_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  if [ ! -d "$dir" ]; then
    return
  fi

  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    # Extract keywords line from frontmatter (between first --- and second ---)
    local kw_line
    kw_line=$(awk '/^---$/{n++; next} n==1 && /^keywords:/{sub(/^keywords: */, ""); print; exit}' "$md")

    if [ -z "$kw_line" ]; then
      jit_unindexed "$label" "$filename" "no keywords: in its frontmatter"
      continue
    fi

    # Fold Latin-1 accents to ASCII BEFORE the per-keyword strip below, which maps every
    # remaining non-[a-z0-9 -] byte to a space: `keywords: détail` would otherwise index as
    # the row `d tail`, reachable only from a prompt carrying the same accent and never
    # from `detail`. Both hooks fold their subject with the same table (#31). Once per
    # file rather than once per keyword -- the fold is per character and leaves the commas
    # this line is about to be split on alone.
    kw_line=$(printf '%s\n' "$kw_line" | awk "$JIT_AWK_FOLD"'{ print jit_fold_latin1($0) }')

    # Split on ", " and write each keyword → filename.
    #
    # A here-string, never `... | while`: the body appends to JIT_DROPPED, and a pipeline's
    # last stage is a subshell whose variables die at the closing `done`. A dropped keyword
    # would then be discarded by the very code written to stop discarding it silently.
    # Three counters, not one. "No row from a keywords: line" has two causes and they are
    # two different fixes: a term the blacklist matched sends the author to
    # JIT_CONTEXT_KEYWORD_BLACKLIST, a term that normalised to nothing sends them to the
    # frontmatter. Reporting one reason for both would name a pattern that never saw the
    # word -- a confident wrong answer, which is worse here than no report at all.
    local kw_split kw_written=0 kw_black=0 kw_empty=0
    kw_split=$(printf '%s\n' "$kw_line" | tr ',' '\n')
    while IFS= read -r kw; do
      # Normalize IDENTICALLY to the matcher (pre-prompt-hook.sh): lowercase, then
      # map any char outside [a-z0-9 -] to a space, collapse, trim. A keyword authored
      # with dots/slashes ("docs.dp.tools", "security/dast") would otherwise be DEAD —
      # the matcher strips those from the prompt, so a dotted keyword can never match.
      kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]/ /g; s/  */ /g; s/^ *//; s/ *$//')
      if [ -z "$kw" ]; then kw_empty=$((kw_empty + 1)); continue; fi
      # Skip overly generic single words — they collide with op flags and path tokens.
      # Skipped, and now SAID: the row is not written, so the entry never fires on this
      # word, and the only place that can be reported is here (#95).
      if printf '%s\n' "$kw" | grep -Eq "$VOCAB_KEYWORD_BLACKLIST"; then
        JIT_DROPPED="$JIT_DROPPED    [$label] $(jit_report_name "$filename"): \"$(jit_report_keyword "$kw")\"
"
        kw_black=$((kw_black + 1))
        continue
      fi
      printf '%s\t%s\n' "$kw" "$filename"
      kw_written=$((kw_written + 1))
    done <<< "$kw_split" >> "$tsv"
    # An entry whose every keyword was blacklisted has a `keywords:` line and no row: the
    # drops above are each reported, but nothing said the ENTRY went dark as a result, and
    # one dropped word out of three is a very different thing from all three.
    # A here-string and not a pipe, so this counter survives the loop -- the same reason
    # JIT_DROPPED is appended to there.
    if [ "$kw_written" -eq 0 ]; then
      if [ "$kw_black" -gt 0 ] && [ "$kw_empty" -gt 0 ]; then
        jit_unindexed "$label" "$filename" \
          "every keywords: term was dropped by the blacklist or normalised to nothing"
      elif [ "$kw_black" -gt 0 ]; then
        jit_unindexed "$label" "$filename" \
          "every keywords: term was dropped by the blacklist, so no row was written"
      else
        jit_unindexed "$label" "$filename" \
          "every keywords: term normalised to nothing -- the normaliser maps every byte outside [a-z0-9 -] to a space"
      fi
    fi
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT keywords"
}

VOCAB_BASE="$JIT_BASE/vocabulary"
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="vocabulary/$(jit_report_name "$(basename "$dir")")"
  build_vocab_tsv "$dir" "$dir/00-index.tsv" "$label"
done

# --- Vocabulary paths: parse "## Modules" section → src2/Module/\tfile.md ---
# Lets the path hook surface a vocab entry when a file inside that module is touched,
# instead of only at prompt time. Prompt-time matching fires once per session (a single
# UserPromptSubmit); path matching fires on every Read/Edit/Grep, which is when the
# relevant module is actually known.
build_vocab_path_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    # Body of the "## Modules" section: everything until the next heading or EOF.
    awk -v file="$filename" -v prefix="$MODULE_PREFIX" '
      /^## Modules[[:space:]]*$/ { inmod = 1; next }
      inmod && /^#/ { inmod = 0 }
      inmod {
        gsub(/[^A-Za-z0-9]+/, " ")
        n = split($0, m, " ")
        for (i = 1; i <= n; i++) {
          if (m[i] == "") continue
          # Module names are PascalCase and non-trivial; skip prose fragments.
          if (m[i] !~ /^[A-Z][A-Za-z0-9]{2,}$/) continue
          if (seen[m[i]]) continue
          seen[m[i]] = 1
          printf "%s%s/\t%s\n", prefix, m[i], file
        }
      }
    ' "$md" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT path mappings"
}

for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="vocabulary/$(jit_report_name "$(basename "$dir")")/paths"
  build_vocab_path_tsv "$dir" "$dir/01-paths.tsv" "$label"
done

# --- Paths: parse "match:" from frontmatter → match_pattern\tfile.md ---
build_path_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    local match_line
    match_line=$(jit_frontmatter match "$md")
    if [ -z "$match_line" ]; then
      jit_unindexed "$label" "$filename" "no match: in its frontmatter"
      continue
    fi

    # Paths carry no invocation macro -- their subject is a file path, not a command --
    # but the check runs here so that writing one is REFUSED and named rather than
    # indexed as a literal that can never match a path.
    match_line=$(jit_expand_match "$match_line" paths "$label/$(jit_report_name "$filename")") || jit_rc 1

    printf '%s\t%s\n' "$match_line" "$filename" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}

PATHS_BASE="$JIT_BASE/paths"
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="paths/$(jit_report_name "$(basename "$dir")")"
  build_path_tsv "$dir" "$dir/00-index.tsv" "$label"
done

# --- Rows the hooks will refuse, named at build time (#77) -------------------
# Nothing above validates bytes, and it cannot: every column reaches printf through a
# $( ) capture, which is also why a NUL can never get this far (bash drops them out of
# command substitution) and why #78 needed no change here. A non-UTF-8 byte DOES get
# through -- under LC_ALL=C the awk in jit_frontmatter() has nothing to decode and copies
# it out verbatim, which was measured, and under a UTF-8 locale that awk aborts loudly
# and the entry is dropped instead. Neither reading tells the author what happened.
#
# It matters most for the one column nobody looks at twice: a `forbid:` value saved in
# ISO-8859-1 indexes fine, and the hook then refuses the whole row -- so a block rule goes
# dark, and the only notice of it arrives at runtime, in a session, naming a row number.
# This file is the loud half, so it says so here, with the entry file name, which is what
# an author can act on.
#
# One awk per index file, after it is written, using the same jit_bad_bytes() the hooks
# refuse with -- never a second opinion that can disagree with theirs. LC_ALL=C on the
# invocation, because the byte range it builds is a decode failure in a UTF-8 locale.
#
# It does NOT change the exit code, matching jit_expand_match(): the row is written
# through and refused at load, which is a rule that reads as refused rather than one that
# silently vanished. That this script has no non-zero exit at all is a known gap, recorded
# in .claude/jit-context/paths/00-manual/tooling.md, and it is not this change to make.
report_bad_bytes() {
  local tsv="$1" label="$2" col="$3"
  [ -f "$tsv" ] || return 0
  LC_ALL=C JIT_COL="$col" awk "$JIT_AWK_ENTRY$JIT_AWK_REPORT_NAME"'
    BEGIN { col = ENVIRON["JIT_COL"] + 0 }
    {
      why = jit_bad_bytes($0, "the index row")
      if (why == "") next
      n = split($0, f, "\t")
      # The entry-file column is attacker-chosen text (#113), and this branch fires on a
      # row nobody had to match. jit_report_name() is why a name carrying the bad byte
      # itself cannot come back through the notice that reports the bad byte.
      printf "rebuild-tsv: %s row %d: %s -- the hooks will refuse this row%s\n", \
        lbl, NR, why, (f[col] != "" && why ~ /UTF-8/ ? ", written from " jit_report_name(f[col]) : "")
    }' lbl="$label" "$tsv" >&2
}

for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  report_bad_bytes "${dir%/}/00-index.tsv" "tools/$(jit_report_name "$(basename "${dir%/}")")" 3
done
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  report_bad_bytes "${dir%/}/00-index.tsv" "paths/$(jit_report_name "$(basename "${dir%/}")")" 2
done
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  _jit_vlabel="vocabulary/$(jit_report_name "$(basename "${dir%/}")")"
  report_bad_bytes "${dir%/}/00-index.tsv" "$_jit_vlabel" 2
  report_bad_bytes "${dir%/}/01-paths.tsv" "$_jit_vlabel" 2
done
unset _jit_vlabel

# --- Ambiguity report: kw appearing in >5 files (vocab only) ---
THRESHOLD=5
echo "" >&2
echo "=== Ambiguous vocabulary keywords (>$THRESHOLD files) ===" >&2
echo "Each match loads ALL listed files into context. Prune \`keywords:\` frontmatter where the term isn't central." >&2
echo "" >&2
HAS_AMBIG=0
for tsv in "$VOCAB_BASE"/*/00-index.tsv; do
  [ -f "$tsv" ] || continue
  # Dimension included, like every other layer label this script prints (#150). This
  # report is vocabulary-only, so the dimension carries no information the section header
  # does not -- but a reader greps `[vocabulary/00-manual]` out of one report and expects
  # it in the next, and a rule with one exception is a rule nobody keeps.
  layer="vocabulary/$(jit_report_name "$(basename "$(dirname "$tsv")")")"
  # LC_ALL=C so jit_report_name() decides on BYTES, the same as the bash half. The file
  # names here are the index column rebuild-tsv.sh just wrote from a basename, so they
  # carry whatever the clone chose to call its entries (#113). A withheld one cannot be
  # confused with the comma this list is joined on -- the comma is outside the kept set.
  # The keyword in column 1 is repository-chosen text too, and #113 stopped at the file
  # names (#126). It is guarded on the way OUT rather than in the aggregation, so entries
  # sharing one long keyword are still counted as one keyword rather than collapsing into
  # a single withheld bucket with somebody else's tally.
  out=$(LC_ALL=C awk -F'\t' -v layer="$layer" -v th="$THRESHOLD" "$JIT_AWK_REPORT_NAME$JIT_AWK_REPORT_KEYWORD"'
    {c[$1]++; f=jit_report_name($2); files[$1]=(files[$1]==""?f:files[$1]","f)}
    END{for(k in c) if(c[k]>th) printf "%4d\t[%s] \"%s\"\n\t  files: %s\n", c[k], layer, jit_report_keyword(k), files[k]}
  ' "$tsv" | sort -rn)
  if [ -n "$out" ]; then
    echo "$out" >&2
    HAS_AMBIG=1
  fi
done
[ "$HAS_AMBIG" = "0" ] && echo "(none — all keywords appear in ≤$THRESHOLD files)" >&2
echo "" >&2

# --- Dropped keywords: listed in frontmatter, not in the index (#95) ---
# Advisory, like the tally above, and for the reasons argued at the top of this file. The
# quiet line is worded so it cannot be confused with the ambiguity report's own "(none":
# two sections whose empty states read alike is how a report that never ran passes for a
# report that found nothing.
echo "=== Keywords dropped by the blacklist (listed, not indexed) ===" >&2
echo "These stay in \`keywords:\` frontmatter for human searching and are skipped at index time," >&2
echo "so the entry never fires on them. Widen or narrow with JIT_CONTEXT_KEYWORD_BLACKLIST." >&2
echo "" >&2
if [ -n "$JIT_DROPPED" ]; then
  printf '%s' "$JIT_DROPPED" >&2
else
  echo "(none — every keyword in every entry was indexed)" >&2
fi
echo "" >&2

# --- Entries on disk with no row in the index (#44) --------------------------
# The quiet line is worded so it cannot be confused with either section above it, for the
# reason the dropped-keyword one gives: two sections whose empty states read alike is how
# a report that never ran passes for a report that found nothing.
#
# The number is a COUNT OF FILES, and it says so. It is not bytes and not tokens: this
# script counts one per .md it read and wrote no row for, at index time, and nothing here
# is estimated from anything else.
echo "=== Entries on disk with no row in the index (they can never fire) ===" >&2
echo "The hooks read 00-index.tsv, never your markdown. An entry with no row is on disk and" >&2
echo "can never fire -- which reads exactly like a rule that fires and never matches." >&2
echo "" >&2
if [ -n "$JIT_UNINDEXED" ]; then
  printf '%s' "$JIT_UNINDEXED" >&2
  echo "" >&2
  echo "$JIT_UNINDEXED_N entr(ies), counted while indexing -- one per .md file that produced no row." >&2
else
  echo "(none — every entry on disk produced at least one index row)" >&2
fi
echo "" >&2

# --- What a match costs, and what summary mode would save --------------------
# `full` is the default, so every match on a tree that has said nothing injects the whole
# entry. That makes the old shape of this report -- "N of M entries would arrive whole" --
# say "M of M" and mean nothing, so it reports something a reader can act on instead.
#
# Default-full is a STAGE. The risk it carries is issue #1s own objection one level up: a
# setting nobody revisits stays at maximum by inertia. What makes it reconsiderable rather
# than permanent is a number for THIS tree, and these are the three that are honestly
# available here:
#
#   what one match costs now      the largest and the median entry, in bytes
#   what it would cost summarised the same entries through the real injection reader
#   what stands in the way        entries with no `description:` yet -- a match could
#                                 only NAME those, so a tree cannot flip cleanly until
#                                 that count is zero. This is the only actionable one.
#
# Deliberately NOT a corpus total. "Summary mode would save 2.4 MB on this tree" is
# technically true and useless: nothing here is ever resident, so that quantity has never
# been in a context window and never will be. The saving that actually happens is
# per-match times how often each entry fires, and only the first factor is knowable here.
# The second is in .discovery/logs/hooks.log, which is where the reader is sent for it.
#
# The sizes come from jit_entry_load()/jit_inject_text() in common.sh -- the SAME reader
# the hooks use, not a second parser beside it. A budget computed by a different parser
# from the thing it is budgeting drifts, and it already did once: an earlier cut of this
# report had its own frontmatter parse and counted `inject: "full"` as unrecognised, so an
# entry that arrived whole at runtime was reported as a summary.
echo "=== What a match costs on this tree ===" >&2
echo "Project default: JIT_CONTEXT_INJECT=$JIT_INJECT" >&2
echo "" >&2

# A glob and not `find`: no fork, and no filename can be split on its own characters.
INJ_LIST=()
for md in "$JIT_BASE"/*/*/*.md; do
  [ -f "$md" ] || continue
  [ "$(basename "$md")" = "00-README.md" ] && continue
  INJ_LIST[${#INJ_LIST[@]}]="$md"
done

if [ "${#INJ_LIST[@]}" -eq 0 ]; then
  echo "(no entries)" >&2
else
  # Everything happens in BEGIN over ARGV, and the files are never read as awk INPUT.
  # jit_entry_load() opens each one itself with getline, so letting awk read them too
  # would double every read; and taking the list through ARGV rather than through stdin
  # means a file name can never be split on a character it happens to contain.
  # JIT_AWK_ENTRY comes first because jit_entry_load() calls into it: the two pre-read
  # guards through jit_entry_why(), and jit_bad_utf8() on what it read. Without it this
  # awk aborts with "calling undefined function" -- loudly, which is this file contract,
  # and the report is then silently absent rather than wrong.
  # LC_ALL=C for the same reason every hook awk sets it: jit_utf8_init() builds a byte
  # range out of sprintf("%c", 128) and sprintf("%c", 255), and under a UTF-8 locale
  # one-true-awk tries to decode that as a character range and aborts with "multibyte
  # conversion failure". It also makes length() count BYTES on both engines, which is
  # the unit the hooks clip in and the unit this report prints.
  LC_ALL=C awk -v def="$JIT_INJECT" "$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_REPORT_NAME"'
# Every component this prints came off the .md glob three levels down, so all three are
# names the clone chose (#113). Dimension and layer are kept when they are names, for the
# same reason the file is: a withheld leaf beside a real directory is what tells the
# reader which `ls` to run.
#
# The separator is BRACKETED, and that is not decoration (#133). A one-character separator
# is a regex to gawk and a plain string to one-true-awk -- and one-true-awk splits a plain
# one-character separator on the NEWLINE as well:
#
#   awk  split("a<LF>b/c", x, "/")    -> 3 fields
#   gawk split("a<LF>b/c", x, "/")    -> 2 fields
#   both split("a<LF>b/c", x, "[/]")  -> 2 fields
#
# An entry file name may contain a newline, so on the awk macOS ships the path was torn
# into extra components BEFORE the guard below ran: a[n-2] a[n-1] a[n] then addressed the
# tail of the NAME instead of dimension/layer/file, the dimension fell off the left, and
# the report printed a path nobody could open with two clone-chosen tokens standing in
# positions labelled as directories. The guard was vetting fragments, not names.
function relpath(p,   n, a) {
  n = split(p, a, "[/]")
  if (n < 3) return jit_report_name(p)
  return ".claude/jit-context/" jit_report_name(a[n-2]) "/" jit_report_name(a[n-1]) "/" jit_report_name(a[n])
}
# Largest first. Every parallel array moves together -- sorting the sizes and leaving the
# names and the summarised figures behind would print one entry name beside another
# entry numbers, which is a report that is wrong in the way nobody checks.
function isort(v, nm, sm, ef, n,   i, j, tv, tn, ts, te) {
  for (i = 2; i <= n; i++) {
    tv = v[i]; tn = nm[i]; ts = sm[i]; te = ef[i]; j = i - 1
    while (j >= 1 && v[j] < tv) {
      v[j+1] = v[j]; nm[j+1] = nm[j]; sm[j+1] = sm[j]; ef[j+1] = ef[j]; j--
    }
    v[j+1] = tv; nm[j+1] = tn; sm[j+1] = ts; ef[j+1] = te
  }
}
BEGIN {
  n = 0
  for (ai = 1; ai < ARGC; ai++) {
    path = ARGV[ai]
    # keepbody = 1: the body is what full mode costs, so it has to be read even for an
    # entry whose effective mode is summary.
    if (!jit_entry_load(path, def, 1, e)) continue
    n++
    rel = relpath(path)
    fullb[n] = length(e["body"])
    eff[n] = e["mode"]
    name[n] = rel
    # The real renderer, with the mode forced, so the summarised figure is the string
    # that would actually be injected rather than an estimate of it.
    keep = e["mode"]
    e["mode"] = "summary"
    sumb[n] = length(jit_inject_text(e, rel))
    e["mode"] = keep
    if (eff[n] == "full") { nfull++; bfull += fullb[n] }
    # An entry with no description: could only be summarised into its own name, so it is
    # what stands between this tree and being able to flip.
    #
    # Unless it can never be summarised at all. An entry PINNED to full -- by its own
    # `inject: full`, or by having no frontmatter for the rebuild to have indexed -- stays
    # whole whatever the project sets, so naming it here would send an author to write a
    # description that nothing will ever read. The two cases are indistinguishable from
    # the mode alone when the default and the override agree, which is why jit_entry_load
    # reports the pin separately.
    if (e["desc"] == "" && !(e["pin"] && e["mode"] == "full")) { nodesc++; nd[nodesc] = rel }
  }

  if (n == 0) { print "(no entries)"; exit }

  isort(fullb, name, sumb, eff, n)
  mid = int((n + 1) / 2)

  if (def == "full") {
    print "Every match injects the whole entry. Per match, on this tree:"
    print ""
    printf "  largest %7d bytes  ->  %5d summarised   %s\n", fullb[1], sumb[1], name[1]
    printf "  median  %7d bytes  ->  %5d summarised   %s\n", fullb[mid], sumb[mid], name[mid]
    printf "\n%d entr(ies) indexed.\n", n
  } else {
    printf "%d of %d entr(ies) still arrive whole, %d byte(s) between them.\n", nfull, n, bfull
    for (i = 1; i <= n && shown < 5; i++) if (eff[i] == "full") { printf "%8d  %s\n", fullb[i], name[i]; shown++ }
    if (nfull > shown) printf "         ... and %d more\n", nfull - shown
  }

  if (nodesc > 0) {
    printf "\n%d entr(ies) carry no description:, so a match could only NAME them.\n", nodesc
    for (i = 1; i <= nodesc && i <= 10; i++) print "  " nd[i]
    if (nodesc > 10) printf "  ... and %d more\n", nodesc - 10
    print "Nothing is auto-derived -- a generated summary of a wrong entry is a confident"
    print "wrong summary, and it removes the moment the author would have noticed."
  } else if (def == "full") {
    print "\nEvery entry carries a description:, so this tree can move to summary whenever"
    print "you decide the trade is worth it: JIT_CONTEXT_INJECT=summary in config.env."
  }

  print ""
  print "This is the cost of ONE match, not a total -- nothing here is ever resident, and"
  print "how often each entry fires is in .discovery/logs/hooks.log, not in this tree."
  print "A tools rule that REFUSES a call injects its whole body whatever the mode says:"
  print "the call is already stopped, so there is no next turn to spend a cheaper answer in."
}
' "${INJ_LIST[@]}" >&2
fi
echo "" >&2
# One line saying which of the three this run was. The REFUSED and FATAL lines above are
# the detail, but they scroll past inside two reports; this is what is on screen when the
# shell hands the prompt back, and it is the only place the number itself is spelled out.
case "$JIT_RC" in
  1) echo "rebuild-tsv: exit 1 -- the index was written, and at least one row above will be REFUSED" >&2
     echo "             by the matcher. That rule is on disk and will never fire." >&2 ;;
  2) echo "rebuild-tsv: exit 2 -- an index could not be written. What is on disk is NOT what this" >&2
     echo "             run built." >&2 ;;
esac
exit "$JIT_RC"
