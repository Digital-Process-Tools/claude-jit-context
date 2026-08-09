#!/bin/bash
# claude-jit-context — Vocabulary-based UserPromptSubmit hook
# Single awk process: parses JSON, matches keywords against TSV indexes, outputs JSON.

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"
T_START=$(_ms)

SHOWN_FILE="/tmp/claude-vocab-shown-$PPID.txt"
[ -f "$SHOWN_FILE" ] || : > "$SHOWN_FILE"
LOG_TMP="/tmp/claude-prompt-log-$$.tmp"

cat | awk \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v shown_file="$SHOWN_FILE" \
  -v log_tmp="$LOG_TMP" \
'
{ input = input $0 }
END {
  # --- Parse JSON: extract prompt ---
  n = split(input, f, "\"")
  for (i = 2; i <= n; i += 2) {
    if (f[i] == "prompt") { message = f[i+2]; break }
  }

  if (message == "") { print "{}"; exit }

  # Lowercase + strip accents (basic ASCII transliteration)
  msg = tolower(message)

  # Word-boundary match prep:
  # 1. Split CamelCase: "SiProjectModule" -> "Si Project Module"
  cc = ""
  for (i = 1; i <= length(message); i++) {
    c = substr(message, i, 1)
    p = (i > 1) ? substr(message, i-1, 1) : ""
    if (c ~ /[A-Z]/ && p ~ /[a-z0-9]/) cc = cc " " c
    else cc = cc c
  }
  # 2. Pad, lowercase, strip non-alnum (keep hyphens) so kw lookup is space-bounded
  padded = " " tolower(cc) " "
  gsub(/[^a-z0-9 -]/, " ", padded)
  gsub(/  +/, " ", padded)

  # --- Load shown set ---
  while ((getline sline < shown_file) > 0) shown[sline] = 1
  close(shown_file)

  matched = ""
  log_matches = ""
  sep = ""

  # --- Scan vocab layers ---
  split("00-manual 10-auto 20-grouped 30-crosscutting", layers, " ")
  for (li = 1; li <= 4; li++) {
    layer = layers[li]
    lookup = vocab_base "/" layer "/00-index.tsv"

    # Single pass: match keywords, collect files + matched keywords
    delete vmatch
    while ((getline vl < lookup) > 0) {
      split(vl, vf, "\t")
      kw = vf[1]; vfile = vf[2]
      if (!(vfile in shown) && index(padded, " " kw " ") > 0) {
        if (vfile in vmatch) vmatch[vfile] = vmatch[vfile] "|" kw
        else vmatch[vfile] = kw
      }
    }
    close(lookup)

    for (vfile in vmatch) {
      shown[vfile] = 1
      print vfile >> shown_file

      vc = ""
      vpath = vocab_base "/" layer "/" vfile
      while ((getline vcl < vpath) > 0) vc = vc (vc == "" ? "" : "\n") vcl
      close(vpath)

      if (vc != "") {
        vh = "# Vocabulary: " vfile " (matched: " vmatch[vfile] ")"
        if (layer ~ /00-manual/) vh = vh "\\n[vocab-upkeep] Learned something new here, or found this entry wrong? Edit it now — hand-written entries live in 00-manual/."
        log_matches = log_matches sep layer ":" vfile "(" vmatch[vfile] ")"
        sep = ", "
        if (matched != "") matched = matched "\n---\n" vh "\n" vc
        else matched = vh "\n" vc
      }
    }
  }
  close(shown_file)

  # --- Log info ---
  sc = 0; for (s in shown) sc++
  msg_short = substr(msg, 1, 80)
  if (log_matches == "") log_matches = "(none)"
  printf "%s\t%d\t%s\n", log_matches, sc, msg_short > log_tmp
  close(log_tmp)

  # --- Output JSON ---
  if (matched != "") {
    gsub(/\\/, "\\\\", matched); gsub(/"/, "\\\"", matched)
    gsub(/\t/, "\\t", matched); gsub(/\n/, "\\n", matched)
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"%s\"}}", matched
  } else {
    print "{}"
  }
}
'

# --- Timing + log ---
T_END=$(_ms)
TOTAL=$((T_END - T_START))

if [ -f "$LOG_TMP" ]; then
  IFS=$'\t' read -r AWK_MATCHES AWK_SHOWN AWK_MSG < "$LOG_TMP"
  _log_hook "pre-prompt" "$TOTAL" "$AWK_MATCHES [shown:$AWK_SHOWN] << $AWK_MSG"
  rm -f "$LOG_TMP"
fi
