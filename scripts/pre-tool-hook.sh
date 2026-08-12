#!/bin/bash
# claude-jit-context — PreToolUse hook
# Single awk process: parses JSON, scans tool + vocab TSVs, outputs JSON.
# Bash wrapper only handles timing (2 perl calls) and log writing.

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"
T_START=$(_ms)

SHOWN_FILE="/tmp/claude-vocab-shown-$PPID.txt"
[ -f "$SHOWN_FILE" ] || : > "$SHOWN_FILE"
LOG_TMP="/tmp/claude-hook-log-$$.tmp"

cat | awk \
  -v tools_tsv="$JIT_BASE/tools/00-manual/00-index.tsv" \
  -v tools_dir="$JIT_BASE/tools/00-manual" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v shown_file="$SHOWN_FILE" \
  -v home="$HOME" \
  -v project="${CLAUDE_PROJECT_DIR:-.}" \
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
# multibyte decode -- the same reason the CamelCase split uses it -- and no byte of a UTF-8
# sequence falls in 0x00-0x1F, so it can never cut a multibyte character in half. The two
# fixes pass over different buffers and neither can undo the other.
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
  # --- Parse JSON (common.sh: jit_json_fields honours an escaped quote, jit_unescape
  # --- decodes the value) and extract key-value pairs ---
  n = jit_json_fields(input, raw, fs, fe)
  for (i = 2; i + 2 <= n; i += 2) {
    # Only a field that is ONE raw piece can be a key this hook wants — every key below is
    # quote-free — and only the matching value is ever materialised or decoded. That is
    # what keeps a Write payload, whose tool_input.content is the whole file body, from
    # being reassembled and walked character by character on every single tool call.
    if (fs[i] != fe[i]) continue
    k = raw[fs[i]]
    if (k == "tool_name") tool_name = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "command") command = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "skill") f_skill = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "file_path") f_file_path = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    else if (k == "pattern") f_pattern = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
  }

  # Fallback chain for tool matching
  full_command = command
  if (full_command == "") full_command = f_skill
  if (full_command == "") full_command = f_file_path
  if (full_command == "") full_command = f_pattern

  # Strip to command words (before ; & | quotes flags). `full_command` can now hold real
  # newlines, and the one strip that had to change is the quote.
  #
  # `.` matches a newline -- measured on awk 20200816 and GNU Awk 5.4.1, both of which
  # reduce "a;b<NL>c;d" to "a". So the ; & | and -- strips already run to the end of the
  # whole string rather than to the end of a line, which is what they always meant, and
  # a multi-line command keeps its later lines only when nothing truncated it earlier.
  #
  # The quote is a cut at its FIRST occurrence, not a gsub, and the difference only shows
  # once a command can span lines. A quoted argument may too -- `git commit -m "line one
  # ... mentions gh pr list"` -- and awk cannot see that the quote opened on line one is
  # still open on line three. Stripping per line would hand that commit message to
  # substring rules as if it were a command, which is the false block issue #7 reports.
  cmd = full_command
  gsub(/[;&|].*/, "", cmd)
  q = index(cmd, "\"")
  if (q > 0) cmd = substr(cmd, 1, q - 1)
  gsub(/ --.*/, "", cmd)

  # What is left can now be newlines and spaces rather than the empty string. Blank is
  # "no command words" either way, and must reach the same verdict.
  probe = cmd
  gsub(/[[:space:]]/, "", probe)
  if (probe == "") cmd = ""

  if (tool_name == "" || cmd == "") { print "{}"; exit }

  matched = ""
  blocked = ""
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0

  # --- Load shown file into set ---
  while ((getline sline < shown_file) > 0) shown[sline] = 1
  close(shown_file)

  # --- Tool rules matching ---
  rown = 0
  while ((getline tline < tools_tsv) > 0) {
    rown++
    split(tline, tf, "\t")
    r_tool = tf[1]; r_match = tf[2]; r_file = tf[3]
    r_modes = tf[4]; r_require = tf[5]; r_forbid = tf[6]

    # Containment first: r_file is concatenated onto tools_dir below, and a row of
    # ../../../x made this hook read that file and inject it. jit_bad_entry_file lives in
    # common.sh with the reproduction.
    # The mode is DERIVED, never echoed: like the file name, column 4 is attacker text.
    # "this was a block rule and it did not run" is worth saying; the raw column is not.
    r_kind = (index(r_modes, "block") > 0) ? " (a block rule)" : ""
    why = jit_bad_entry_file(r_file, tools_dir)
    if (why != "") {
      n_refused++
      refused = refused (refused == "" ? "- " : "\n- ") jit_row_id("tools/00-manual", rown) r_kind ": " why
      log_matches = log_matches sep "refused:" r_file "(" why ")"
      sep = ", "
      continue
    }

    # tool may name several tools, pipe-separated: `tool: Edit|Write|Read`.
    # Exact-match each alternative — never substring, or `Read` would match `ReadFile`.
    tool_hit = 0
    nt = split(r_tool, talts, "|")
    for (ti = 1; ti <= nt; ti++) if (talts[ti] == tool_name) tool_hit = 1
    if (!tool_hit) continue
    if (substr(r_match, 1, 1) == "~") {
      # Regex rules match the WHOLE command, not the truncated first segment:
      # `cmd` is stripped at the first ; & | so `cd X && git push` was only ever
      # tested as `cd X`, and every rule after a chain operator silently never
      # fired. A rule that reads as enforced and is not is worse than no rule.
      #
      # Guard first. An undefined escape compiles to the bare letter and matches
      # nothing while awk exits 0, and a malformed pattern is a fatal error that
      # kills this whole program — taking every later rule, the vocabulary pass and
      # the log line with it. Both look exactly like "no rule matched". Refuse the
      # ROW, never the file: refusing the file turns one dead rule into all of them.
      why = jit_bad_pattern(substr(r_match, 2))
      if (why != "") {
        n_refused++
        # Named, not positioned — see the same decision in pre-path-hook.sh: this row
        # already passed the bare-name check, so the name is safe to echo and is the thing
        # an author needs. tests/test-rule-guard.sh asserts this half by file name.
        refused = refused (refused == "" ? "- " : "\n- ") r_file " (" r_modes "): " why
        log_matches = log_matches sep "refused:" r_file "(" why ")"
        sep = ", "
        continue
      }
      if (match(tolower(full_command), substr(r_match, 2)) == 0) continue
    } else {
      if (index(tolower(cmd), tolower(r_match)) == 0) continue
    }

    # "once" mode
    if (index(r_modes, "once") > 0) {
      key = "rule:" r_file
      if (key in shown) continue
      shown[key] = 1
      print key >> shown_file
    }

    # Read rule .md
    content = ""
    rpath = tools_dir "/" r_file
    while ((getline rl < rpath) > 0) content = content (content == "" ? "" : "\n") rl
    close(rpath)

    # Check require
    if (r_require != "") {
      nr = split(r_require, reqs, "|")
      for (ri = 1; ri <= nr; ri++) {
        if (index(tolower(full_command), tolower(reqs[ri])) == 0) {
          blocked = "BLOCKED: Missing required: " reqs[ri] ". " content
          log_matches = log_matches sep "tool:" r_file "(BLOCKED:" reqs[ri] ")"
          sep = ", "; break
        }
      }
      if (blocked != "") break
    }

    # Check forbid
    if (r_forbid != "" && blocked == "") {
      nfb = split(r_forbid, forbs, "|")
      for (fi = 1; fi <= nfb; fi++) {
        if (index(tolower(full_command), tolower(forbs[fi])) > 0) {
          blocked = "BLOCKED: Forbidden: " forbs[fi] ". " content
          log_matches = log_matches sep "tool:" r_file "(BLOCKED:" forbs[fi] ")"
          sep = ", "; break
        }
      }
      if (blocked != "") break
    }

    if (content != "" && blocked == "") {
      header = "# JIT Context: " r_file " (matched: " r_match ")"
      log_matches = log_matches sep "tool:" r_file "(" r_match ")"
      sep = ", "

      if (index(r_modes, "block") > 0) { blocked = header "\n" content; break }

      if (matched != "") matched = matched "\n---\n" header "\n" content
      else matched = header "\n" content
    }
  }
  close(tools_tsv)

  # --- Vocabulary matching ---
  # Bind vocab to WHERE the tool acts (target path), not WHAT the payload says.
  # Matching command verbs / descriptions / patterns fired unrelated module
  # entries on incidental words ("feedback" in a comment, "checkout" in a git
  # verb). Path-only: an Edit/Read file_path, plus path-like tokens (those
  # containing "/") lifted out of a Bash/supertool command so
  # `./supertool edit:..src/Billing/..` still binds to Billing. No path -> no vocab
  # here; the prompt hook still injects on what the user is actually discussing.
  cmd_paths = ""
  # Split on any run of whitespace, not a single space: a decoded command has real
  # newlines in it now, and splitting on " " alone would glue the last token of one line
  # to the first of the next and hide both from the path test.
  np = split(command, ptoks, /[[:space:]]+/)
  for (pi = 1; pi <= np; pi++) {
    if (index(ptoks[pi], "/") > 0) cmd_paths = cmd_paths " " ptoks[pi]
  }
  tt = f_file_path " " cmd_paths
  gsub(home "/", "", tt)
  gsub(project "/", "", tt)

  # Word-boundary match prep:
  # 1. Split CamelCase: "SiProjectModule" -> "Si Project Module"
  # The case test is index() and not /[A-Z]/. Matching a regex against a SINGLE character
  # is a multibyte decode, and one character of a UTF-8 string is one BYTE to one-true-awk:
  # a lone continuation byte raised "towc: multibyte conversion failure", which aborts the
  # END block. The hook then printed nothing at all and still exited 0, so a command naming
  # a path like src/Détail/a.php silently skipped every vocabulary entry (issue #14). gawk
  # decodes the whole string and never hit it, which is why Linux CI stayed green and macOS
  # and Git Bash did not.
  #
  # index() is a plain byte search with no decode, and it cannot change the verdict: every
  # byte of a multibyte UTF-8 sequence is >= 0x80, so none of them is ever an ASCII letter
  # or digit either way. The empty guards keep the substitution exact rather than merely
  # equivalent: index(s, "") returns 1, so an unguarded p == "" splits on a leading capital
  # where /[a-z0-9]/ did not. Measured: the two agree byte for byte anyway, because the
  # whitespace collapse below absorbs the extra separator. Kept because the next person to
  # reach for index() on a single character should not have to re-derive that.
  cc = ""
  for (i = 1; i <= length(tt); i++) {
    c = substr(tt, i, 1)
    p = (i > 1) ? substr(tt, i-1, 1) : ""
    if (c != "" && p != "" && index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) > 0 && index("abcdefghijklmnopqrstuvwxyz0123456789", p) > 0) cc = cc " " c
    else cc = cc c
  }
  tt = tolower(cc)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", tt)
  # 2. Pad + strip non-alnum (keep hyphens) for space-bounded kw lookup
  padded = " " tt " "
  gsub(/[^a-z0-9 -]/, " ", padded)
  gsub(/  +/, " ", padded)

  if (tt != "") {
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
        why = jit_bad_entry_file(vfile, vocab_base "/" layer)
        if (why != "") {
          # Same concatenation, same refusal. Keyed on the name so one bad row is counted
          # once, not once per keyword that happens to point at it.
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
  }

  # --- A refused row is reported, once per session ---
  # The log alone was not enough: that is exactly where two dead block rules sat
  # unnoticed, showing "(none) [shown:0]" on the very command they were written for.
  # This is the only channel that reaches someone who can fix it. It costs nothing
  # while every pattern is honourable, and stops the moment the rule is corrected.
  # Suppressed when the call is being blocked, and only marked shown once delivered.
  if (n_refused > 0 && blocked == "" && !("jit-refused-rules" in shown)) {
    shown["jit-refused-rules"] = 1
    print "jit-refused-rules" >> shown_file
    note = jit_refusal_notice(refused, n_refused)
    matched = (matched == "") ? note : note "\n---\n" matched
  }

  # --- A refused config.env line is reported, once per session ---
  # Parsed in common.sh, reported here, for the same reason as a refused rule: the log is
  # exactly where this would go unnoticed. Suppressed when the call is being blocked, so
  # a block reason stays the only thing the model reads.
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && blocked == "" && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    print "jit-refused-config" >> shown_file
    cnote = jit_config_notice(config_refused, config_refused_n)
    matched = (matched == "") ? cnote : cnote "\n---\n" matched
  }
  close(shown_file)

  # --- Write log info to temp file (bash reads it for timing) ---
  sc = 0; for (s in shown) sc++
  tt_short = substr(tt, 1, 120)
  if (log_matches == "") log_matches = "(none)"
  printf "%s\t%s\t%d\t%s\n", tool_name, log_matches, sc, tt_short > log_tmp
  close(log_tmp)

  # --- Output JSON ---
  if (blocked != "") {
    blocked = jit_json_escape(blocked)
    printf "{\"decision\":\"block\",\"reason\":\"%s\"}", blocked
  } else if (matched != "") {
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
  IFS=$'\t' read -r AWK_TOOL AWK_MATCHES AWK_SHOWN AWK_TEXT < "$LOG_TMP"
  _log_hook "pre-tool ($AWK_TOOL)" "$TOTAL" "$AWK_MATCHES [shown:$AWK_SHOWN] << $AWK_TEXT"
  rm -f "$LOG_TMP"
fi
