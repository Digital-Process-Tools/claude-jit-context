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

# --- Tool rules: parse frontmatter from .md files ---
# Extracts tool, match, mode, require, forbid from YAML frontmatter
build_tool_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  : > "$tsv"

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    # Parse frontmatter fields
    local tool match mode require forbid
    tool=$(awk '/^---$/{n++; next} n==1 && /^tool:/{sub(/^tool: */, ""); gsub(/"/, ""); print; exit}' "$md")
    match=$(awk '/^---$/{n++; next} n==1 && /^match:/{sub(/^match: */, ""); gsub(/"/, ""); print; exit}' "$md")
    mode=$(awk '/^---$/{n++; next} n==1 && /^mode:/{sub(/^mode: */, ""); gsub(/ /, ""); print; exit}' "$md")
    require=$(awk '/^---$/{n++; next} n==1 && /^require:/{sub(/^require: */, ""); gsub(/"/, ""); print; exit}' "$md")
    forbid=$(awk '/^---$/{n++; next} n==1 && /^forbid:/{sub(/^forbid: */, ""); gsub(/"/, ""); print; exit}' "$md")

    [ -z "$tool" ] || [ -z "$match" ] && continue

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

  : > "$tsv"  # truncate

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    # Extract keywords line from frontmatter (between first --- and second ---)
    local kw_line
    kw_line=$(awk '/^---$/{n++; next} n==1 && /^keywords:/{sub(/^keywords: */, ""); print; exit}' "$md")

    [ -z "$kw_line" ] && continue

    # Split on ", " and write each keyword → filename
    echo "$kw_line" | tr ',' '\n' | while read -r kw; do
      # Normalize IDENTICALLY to the matcher (pre-prompt-hook.sh): lowercase, then
      # map any char outside [a-z0-9 -] to a space, collapse, trim. A keyword authored
      # with dots/slashes ("docs.dp.tools", "security/dast") would otherwise be DEAD —
      # the matcher strips those from the prompt, so a dotted keyword can never match.
      kw=$(echo "$kw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]/ /g; s/  */ /g; s/^ *//; s/ *$//')
      [ -z "$kw" ] && continue
      # Skip overly generic single words — they collide with op flags and path tokens.
      echo "$kw" | grep -Eq "$VOCAB_KEYWORD_BLACKLIST" && continue
      printf '%s\t%s\n' "$kw" "$filename"
    done >> "$tsv"
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
  : > "$tsv"

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
  : > "$tsv"

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue

    local match_line
    match_line=$(awk '/^---$/{n++; next} n==1 && /^match:/{sub(/^match: */, ""); gsub(/"/, ""); print; exit}' "$md")
    [ -z "$match_line" ] && continue

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
