#!/bin/bash
# claude-jit-context — Path-based PreToolUse hook
# Single awk process: parses JSON, matches file path against TSV patterns, outputs JSON.
# Supports Read/Edit/Write/Glob/Grep (file_path/path) AND Bash+supertool (command field).

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"
T_START=$(_ms)

SHOWN_FILE="/tmp/claude-path-shown-$PPID.txt"
[ -f "$SHOWN_FILE" ] || : > "$SHOWN_FILE"
LOG_TMP="/tmp/claude-path-log-$$.tmp"

# Vocabulary-by-path is OFF for interactive sessions: every prompt already gets a
# vocabulary pass, so path-triggered entries would only duplicate context. Autonomous
# runs send exactly one prompt for the whole run — tool calls are their only remaining
# injection point, and that single prompt lands before the agent knows which part of the
# codebase it will touch. Opt in with DYNAMIC_RULES_VOCAB_PATHS=1.
# The pre-0.2 name is still honoured so existing runners do not break silently.
VOCAB_PATHS="${JIT_CONTEXT_VOCAB_PATHS:-${DYNAMIC_RULES_VOCAB_PATHS:-${DVSI_AUTONOMOUS_VOCAB_PATHS:-0}}}"
VOCAB_SHOWN_FILE="/tmp/claude-vocab-shown-$PPID.txt"
[ -f "$VOCAB_SHOWN_FILE" ] || : > "$VOCAB_SHOWN_FILE"

cat | awk \
  -v paths_base="$JIT_BASE/paths" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v vocab_paths="$VOCAB_PATHS" \
  -v vocab_shown_file="$VOCAB_SHOWN_FILE" \
  -v shown_file="$SHOWN_FILE" \
  -v log_tmp="$LOG_TMP" \
  "$JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_JSON"'
# RFC 8259 forbids a raw U+0000-U+001F inside a JSON string, and a strict parser is
# entitled to reject the whole object -- which renders as this hook having had nothing to
# say. Only backslash, quote, tab and newline were escaped; CR was the one that shipped,
# because an entry authored on Windows has CRLF line endings and this repo .gitattributes
# covers OUR files, not a user (issue #15).
#
# Backslash goes first, or every escape introduced after it is doubled.
#
# The tail loop is guarded by index() rather than a regex: index() is a byte search with no
# multibyte decode -- the same reason the CamelCase split in the prompt and tool hooks uses
# it -- and no byte of a UTF-8 sequence falls in 0x00-0x1F, so it can never cut a multibyte
# character in half.
#
# U+0000 IS reachable, on exactly one of the two engines. gawk is NUL-transparent and
# carries an embedded NUL through getline into the buffer; one-true-awk truncates the line
# at it and cannot even build a one-byte NUL with sprintf("%c", 0). So the loop starts at 0
# and skips the code point the engine cannot represent -- without that skip, index(s, "")
# returns 1 and gsub would be handed an empty regex, which matches at every position.
function jit_json_escape(s,   k, c) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  for (k = 0; k <= 31; k++) {
    if (k == 9 || k == 10 || k == 13) continue
    c = sprintf("%c", k)
    if (length(c) == 0) continue
    if (index(s, c) > 0) gsub(c, sprintf("\\u%04x", k), s)
  }
  return s
}
{ input = input $0 }
END {
  # --- Parse JSON: extract file_path, path, or command ---
  # jit_json_fields/jit_unescape live in common.sh. Splitting on a bare quote ended a
  # value at the first ESCAPED one, and nothing decoded \n — so a supertool call sitting
  # on the second line of a multi-line command was invisible here.
  n = jit_json_fields(input, raw, fs, fe)
  cmd = ""
  for (i = 2; i + 2 <= n; i += 2) {
    # A key this hook wants is quote-free, so a field spanning several raw pieces is not
    # one; skipping it is what keeps a Write payload body from ever being reassembled.
    if (fs[i] != fe[i]) continue
    k = raw[fs[i]]
    if (k == "file_path") file_path = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "path" && file_path == "") file_path = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "command") cmd = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
  }

  # --- Collect paths to match against ---
  path_count = 0
  if (file_path != "") {
    path_count = 1; all_paths[1] = file_path
  # \n joins the class for the same reason ; and | are in it: a decoded multi-line
  # command puts the second invocation after a real newline, and without it the call was
  # simply not seen.
  } else if (cmd != "" && cmd ~ /(^|[ \t\n;&|(])(\.\/)?supertool(\.py)?[ \t]/) {
    # Extract paths from supertool single-quoted arguments.
    # The separator is bracketed, so awk compiles it as a REGEX rather than a single
    # character. Measured on awk 20200816 (macOS): with a one-character separator that awk
    # also splits on a newline, so a multi-line command produced one extra field and
    # shifted the odd/even parity this loop walks — every quoted argument was then read
    # from the wrong side of the quote. "[\047]" splits on the quote and nothing else, on
    # every awk.
    n2 = split(cmd, args, "[\047]")
    for (ai = 2; ai <= n2; ai += 2) {
      arg = args[ai]
      # read:PATH, map:PATH, ls:PATH, tail:PATH, head:PATH, wc:PATH
      if (match(arg, /^(read|map|ls|tail|head|wc):/)) {
        sub(/^[^:]+:/, "", arg)
        sub(/:.*/, "", arg)
        if (arg != "") { path_count++; all_paths[path_count] = arg }
      }
      # grep:PATTERN:PATH, around:PATTERN:PATH
      else if (match(arg, /^(grep|around):/)) {
        sub(/^[^:]+:/, "", arg)
        sub(/^[^:]+:/, "", arg)
        sub(/:.*/, "", arg)
        if (arg != "") { path_count++; all_paths[path_count] = arg }
      }
      # glob:PATTERN — extract directory prefix
      else if (match(arg, /^glob:/)) {
        sub(/^glob:/, "", arg)
        sub(/[^\/]*\*.*/, "", arg)
        if (arg != "") { path_count++; all_paths[path_count] = arg }
      }
      # check:PRESET:PATH
      else if (match(arg, /^check:/)) {
        sub(/^check:/, "", arg)
        sub(/^[^:]+:/, "", arg)
        if (arg != "") { path_count++; all_paths[path_count] = arg }
      }
    }
  }

  if (path_count == 0) { print "{}"; exit }

  # --- Load shown set ---
  while ((getline sline < shown_file) > 0) shown[sline] = 1
  close(shown_file)

  matched = ""
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0

  # --- Scan path layers ---
  split("00-manual 10-auto 20-grouped 30-crosscutting", layers, " ")
  for (li = 1; li <= 4; li++) {
    layer = layers[li]
    index_file = paths_base "/" layer "/00-index.tsv"

    rown = 0
    while ((getline tline < index_file) > 0) {
      rown++
      split(tline, tf, "\t")
      pattern = tf[1]; rule_file = tf[2]

      # Containment first, before the shown set and before the pattern: the file name is
      # about to be concatenated onto this layer directory, and a row of ../../../x made
      # the hook read that file and inject it. See jit_bad_entry_file in common.sh.
      why = jit_bad_entry_file(rule_file, paths_base "/" layer)
      if (why != "") {
        n_refused++
        refused = refused (refused == "" ? "- " : "\n- ") jit_row_id(layer, rown) ": " why
        log_matches = log_matches sep "refused:" jit_log_name(rule_file, layer, rown, why) "(" why ")"
        sep = ", "
        continue
      }

      if (rule_file in shown) continue

      # Every path pattern is a regex, so the guard applies to all of them. See
      # common.sh: an undefined escape matches nothing and exits 0, a malformed one
      # is fatal and silences the entire index. Refuse the row, keep the rest.
      why = jit_bad_pattern(pattern)
      if (why != "") {
        n_refused++
        # Named, not positioned: this row PASSED the bare-name check above, so the name
        # cannot carry a separator, and naming it is what an author fixing the pattern
        # actually needs. Only a name that failed that check is untrustworthy enough to
        # withhold. tests/test-rule-guard.sh asserts this half by file name.
        refused = refused (refused == "" ? "- " : "\n- ") layer "/" rule_file ": " why
        log_matches = log_matches sep "refused:" rule_file "(" why ")"
        sep = ", "
        continue
      }

      path_matched = 0
      for (pi = 1; pi <= path_count; pi++) {
        if (match(all_paths[pi], pattern)) { path_matched = 1; break }
      }
      if (!path_matched) continue

      shown[rule_file] = 1
      print rule_file >> shown_file

      content = ""
      rpath = paths_base "/" layer "/" rule_file
      while ((getline rl < rpath) > 0) content = content (content == "" ? "" : "\n") rl
      close(rpath)

      if (content != "") {
        header = "# JIT Context: " rule_file " (matched: " pattern ")"
        log_matches = log_matches sep layer ":" rule_file "(" pattern ")"
        sep = ", "
        if (matched != "") matched = matched "\n---\n" header "\n" content
        else matched = header "\n" content
      }
    }
    close(index_file)
  }
  close(shown_file)

  # --- Scan vocabulary path layers (autonomous runs only) ---
  # Shares the shown-file written by the prompt hook, so an entry already delivered at
  # intake is not repeated here. Index entries are literal path fragments ("src2/SiBlog/"),
  # not regexes: matched with index(), and the trailing slash keeps src2/Bra/ off src2/Bram/.
  if (vocab_paths == "1") {
    while ((getline vsline < vocab_shown_file) > 0) vshown[vsline] = 1
    close(vocab_shown_file)

    for (li = 1; li <= 4; li++) {
      layer = layers[li]
      vindex = vocab_base "/" layer "/01-paths.tsv"

      vrown = 0
      while ((getline vline < vindex) > 0) {
        vrown++
        split(vline, vf, "\t")
        vpattern = vf[1]; vocab_file = vf[2]

        # Same containment check as the rule loop above: this name is concatenated too.
        why = jit_bad_entry_file(vocab_file, vocab_base "/" layer)
        if (why != "") {
          n_refused++
          refused = refused (refused == "" ? "- " : "\n- ") jit_row_id(layer, vrown) ": " why
          log_matches = log_matches sep "refused:" jit_log_name(vocab_file, layer, vrown, why) "(" why ")"
          sep = ", "
          continue
        }

        if (vocab_file in vshown) continue

        vmatched = 0
        for (pi = 1; pi <= path_count; pi++) {
          if (index(all_paths[pi], vpattern) > 0) { vmatched = 1; break }
        }
        if (!vmatched) continue

        vshown[vocab_file] = 1
        print vocab_file >> vocab_shown_file

        vcontent = ""
        vfpath = vocab_base "/" layer "/" vocab_file
        while ((getline vl < vfpath) > 0) vcontent = vcontent (vcontent == "" ? "" : "\n") vl
        close(vfpath)

        if (vcontent != "") {
          vheader = "# Vocabulary: " vocab_file " (matched path: " vpattern ")"
          log_matches = log_matches sep layer ":" vocab_file "(" vpattern ")"
          sep = ", "
          if (matched != "") matched = matched "\n---\n" vheader "\n" vcontent
          else matched = vheader "\n" vcontent
        }
      }
      close(vindex)
    }
    close(vocab_shown_file)
  }

  # --- A refused row is reported, once per session ---
  # Same reason as the tool hook: the log is where dead rules go unnoticed, and this
  # is the only channel that reaches an author who can fix it. Free while clean.
  if (n_refused > 0 && !("jit-refused-paths" in shown)) {
    shown["jit-refused-paths"] = 1
    print "jit-refused-paths" >> shown_file
    note = jit_refusal_notice(refused, n_refused)
    matched = (matched == "") ? note : note "\n---\n" matched
  }

  # --- A refused config.env line is reported, once per session ---
  # Parsed in common.sh, reported here, because this is the only channel that reaches the
  # user. The case that matters is the one where they did NOT write the file: config.env
  # arrives with the repository, and a refused line there is either their own typo or a
  # shell payload someone shipped them. Both are worth saying out loud.
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    print "jit-refused-config" >> shown_file
    cnote = jit_config_notice(config_refused, config_refused_n)
    matched = (matched == "") ? cnote : cnote "\n---\n" matched
  }

  # --- Log info to temp file ---
  fp_short = ""
  for (pi = 1; pi <= path_count; pi++) {
    if (pi > 1) fp_short = fp_short ","
    p = all_paths[pi]
    if (match(p, /src2\//)) p = substr(p, RSTART)
    fp_short = fp_short p
  }
  fp_short = substr(fp_short, 1, 80)
  if (log_matches == "") log_matches = "(none)"
  printf "%s\t%s\n", log_matches, fp_short > log_tmp
  close(log_tmp)

  # --- Output JSON ---
  if (matched != "") {
    matched = jit_json_escape(matched)
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"%s\"}}", matched
  } else {
    print "{}"
  }
}
'

# --- Timing + log ---
T_END=$(_ms)
TOTAL=$((T_END - T_START))

if [ -f "$LOG_TMP" ]; then
  IFS=$'\t' read -r AWK_MATCHES AWK_PATH < "$LOG_TMP"
  _log_hook "pre-path" "$TOTAL" "$AWK_MATCHES << $AWK_PATH"
  rm -f "$LOG_TMP"
fi
