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
# The two ADVISORY reports below -- ambiguous keywords, and keywords the blacklist
# dropped -- never move the code. Failing on ambiguity would make the documented default
# tree exit non-zero and teach every author to ignore the status.
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
truncate_index() {
  if : > "$1" 2>/dev/null; then return 0; fi
  echo "FATAL    $1: could not be written -- that index was NOT rebuilt and is now stale." >&2
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
  truncate_index "$tsv" || return

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

    [ -z "$tool" ] || [ -z "$match" ] && continue

    # An invocation macro becomes the real ERE here, so the index still carries a plain
    # awk pattern and no hook learns a new vocabulary. jit_expand_match returns anything
    # that is not a macro unchanged, and names a macro it cannot honour on stderr while
    # writing the row through -- see common.sh for why the row is not dropped.
    match=$(jit_expand_match "$match" tools "$label/$filename") || jit_rc 1

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$match" "$filename" "${mode:-remind}" "$require" "$forbid" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}

TOOLS_BASE="$JIT_BASE/tools"
for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="tools/$(basename "$dir")"
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

  truncate_index "$tsv" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    # Extract keywords line from frontmatter (between first --- and second ---)
    local kw_line
    kw_line=$(awk '/^---$/{n++; next} n==1 && /^keywords:/{sub(/^keywords: */, ""); print; exit}' "$md")

    [ -z "$kw_line" ] && continue

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
    local kw_split
    kw_split=$(printf '%s\n' "$kw_line" | tr ',' '\n')
    while IFS= read -r kw; do
      # Normalize IDENTICALLY to the matcher (pre-prompt-hook.sh): lowercase, then
      # map any char outside [a-z0-9 -] to a space, collapse, trim. A keyword authored
      # with dots/slashes ("docs.dp.tools", "security/dast") would otherwise be DEAD —
      # the matcher strips those from the prompt, so a dotted keyword can never match.
      kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]/ /g; s/  */ /g; s/^ *//; s/ *$//')
      [ -z "$kw" ] && continue
      # Skip overly generic single words — they collide with op flags and path tokens.
      # Skipped, and now SAID: the row is not written, so the entry never fires on this
      # word, and the only place that can be reported is here (#95).
      if printf '%s\n' "$kw" | grep -Eq "$VOCAB_KEYWORD_BLACKLIST"; then
        JIT_DROPPED="$JIT_DROPPED    [$label] $filename: \"$kw\"
"
        continue
      fi
      printf '%s\t%s\n' "$kw" "$filename"
    done <<< "$kw_split" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT keywords"
}

VOCAB_BASE="$JIT_BASE/vocabulary"
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label=$(basename "$dir")
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
  truncate_index "$tsv" || return

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
  label="$(basename "$dir")/paths"
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
  truncate_index "$tsv" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    local match_line
    match_line=$(jit_frontmatter match "$md")
    [ -z "$match_line" ] && continue

    # Paths carry no invocation macro -- their subject is a file path, not a command --
    # but the check runs here so that writing one is REFUSED and named rather than
    # indexed as a literal that can never match a path.
    match_line=$(jit_expand_match "$match_line" paths "$label/$filename") || jit_rc 1

    printf '%s\t%s\n' "$match_line" "$filename" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}

PATHS_BASE="$JIT_BASE/paths"
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="paths/$(basename "$dir")"
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
  LC_ALL=C JIT_COL="$col" awk "$JIT_AWK_ENTRY"'
    BEGIN { col = ENVIRON["JIT_COL"] + 0 }
    {
      why = jit_bad_bytes($0, "the index row")
      if (why == "") next
      n = split($0, f, "\t")
      printf "rebuild-tsv: %s row %d: %s -- the hooks will refuse this row%s\n", \
        lbl, NR, why, (f[col] != "" && why ~ /UTF-8/ ? ", written from " f[col] : "")
    }' lbl="$label" "$tsv" >&2
}

for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  report_bad_bytes "${dir%/}/00-index.tsv" "tools/$(basename "${dir%/}")" 3
done
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  report_bad_bytes "${dir%/}/00-index.tsv" "paths/$(basename "${dir%/}")" 2
done
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  report_bad_bytes "${dir%/}/00-index.tsv" "vocabulary/$(basename "${dir%/}")" 2
  report_bad_bytes "${dir%/}/01-paths.tsv" "vocabulary/$(basename "${dir%/}")" 2
done

# --- Ambiguity report: kw appearing in >5 files (vocab only) ---
THRESHOLD=5
echo "" >&2
echo "=== Ambiguous vocabulary keywords (>$THRESHOLD files) ===" >&2
echo "Each match loads ALL listed files into context. Prune \`keywords:\` frontmatter where the term isn't central." >&2
echo "" >&2
HAS_AMBIG=0
for tsv in "$VOCAB_BASE"/*/00-index.tsv; do
  [ -f "$tsv" ] || continue
  layer=$(basename "$(dirname "$tsv")")
  out=$(awk -F'\t' -v layer="$layer" -v th="$THRESHOLD" '
    {c[$1]++; files[$1]=(files[$1]==""?$2:files[$1]","$2)}
    END{for(k in c) if(c[k]>th) printf "%4d\t[%s] %s\n\t  files: %s\n", c[k], layer, k, files[k]}
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
