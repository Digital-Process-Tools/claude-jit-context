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
  "$JIT_AWK_ENTRY$JIT_AWK_JSON"'
{ input = input $0 }
END {
  # --- Parse JSON: extract prompt ---
  # jit_json_fields/jit_unescape live in common.sh. A bare quote split cut the prompt at
  # the first escaped quote a user typed, and left every \n as the two characters \ and n
  # — which glued the word after a line break to an "n" and hid it from keyword lookup.
  n = jit_json_fields(input, raw, fs, fe)
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] == "prompt") { message = jit_unescape(jit_field(raw, fs[i+2], fe[i+2])); break }
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
  refused = ""
  n_refused = 0

  # --- Scan vocab layers ---
  split("00-manual 10-auto 20-grouped 30-crosscutting", layers, " ")
  for (li = 1; li <= 4; li++) {
    layer = layers[li]
    lookup = vocab_base "/" layer "/00-index.tsv"

    # Single pass: match keywords, collect files + matched keywords
    delete vmatch
    vrown = 0
    while ((getline vl < lookup) > 0) {
      vrown++
      split(vl, vf, "\t")
      kw = vf[1]; vfile = vf[2]
      # vfile is concatenated onto the layer directory below. A row of ../../../x made
      # this hook read that file and inject it into the very first message of a session;
      # jit_bad_entry_file in common.sh carries the reproduction. Counted once per row,
      # not once per keyword pointing at it.
      why = jit_bad_entry_file(vfile)
      if (why != "") {
        if (!((layer "/" vfile) in vrefused)) {
          vrefused[layer "/" vfile] = 1
          n_refused++
          refused = refused (refused == "" ? "- " : "\n- ") jit_row_id(layer, vrown) ": " why
          log_matches = log_matches sep "refused:" vfile "(" why ")"
          sep = ", "
        }
        continue
      }
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

  # --- A refused row is reported, once per session ---
  # The prompt hook had no such channel, because it had no pattern to refuse. A row whose
  # entry file cannot be honoured is the same shape of problem as a pattern that cannot:
  # both read as "no entry matched" and neither is.
  if (n_refused > 0 && !("jit-refused-vocab" in shown)) {
    shown["jit-refused-vocab"] = 1
    print "jit-refused-vocab" >> shown_file
    note = jit_refusal_notice(refused, n_refused)
    matched = (matched == "") ? note : note "\n---\n" matched
  }

  # --- A refused config.env line is reported, once per session ---
  # Shares the shown-file with the tool hook, so this lands once across both.
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    print "jit-refused-config" >> shown_file
    cnote = jit_config_notice(config_refused, config_refused_n)
    matched = (matched == "") ? cnote : cnote "\n---\n" matched
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
