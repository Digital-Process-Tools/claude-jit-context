#!/bin/bash
# claude-jit-context — Path-based PreToolUse hook
# Single awk process: parses JSON, matches file path against TSV patterns, outputs JSON.
# Supports Read/Edit/Write/Glob/Grep (file_path/path) AND Bash+supertool (command field).

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"
T_START=$(_ms)

# Created with O_EXCL under an unpredictable name, removed by an EXIT trap in this
# process, and empty when this platform could not give us one. See common.sh (#60).
jit_tmp_open

# Vocabulary-by-path is OFF for interactive sessions: every prompt already gets a
# vocabulary pass, so path-triggered entries would only duplicate context. Autonomous
# runs send exactly one prompt for the whole run — tool calls are their only remaining
# injection point, and that single prompt lands before the agent knows which part of the
# codebase it will touch. Opt in with DYNAMIC_RULES_VOCAB_PATHS=1.
# The pre-0.2 name is still honoured so existing runners do not break silently.
VOCAB_PATHS="${JIT_CONTEXT_VOCAB_PATHS:-${DYNAMIC_RULES_VOCAB_PATHS:-${DVSI_AUTONOMOUS_VOCAB_PATHS:-0}}}"

# LC_ALL=C on this awk and nowhere else (#68). A malformed UTF-8 byte in the payload --
# a paste out of a Latin-1 file, a multibyte sequence cut at a copy boundary, a filename
# echoed from a differently-encoded checkout -- made one-true-awk abort the END block with
# `illegal byte sequence`: nothing on stdout, not even `{}`, the diagnostic written into
# the session, exit 0. Failing open AND being loud, which is what the top of common.sh
# forbids in one sentence. gawk did not abort but printed a multibyte warning to the same
# place. Under `C` both engines read the record as bytes and neither has anything to
# decode, so neither can fail to.
#
# WHAT IT COSTS HERE: nothing, and for a narrower reason than the one this comment used to
# give. It claimed the Latin-1 fold table from #31 absorbed the change, on the grounds that
# one-true-awk tolower() never folded a multibyte capital. Both halves were shaky: awk
# 20200816 DOES fold `CLÉ` to `clé` under a UTF-8 locale, exactly as gawk 5.4.1 does
# (measured 2026-08-12), and this hook calls neither tolower() nor the fold table. Its path
# patterns are matched case-sensitively, byte for byte, against the raw path -- so the pin
# cannot change a verdict here in either direction, whatever tolower() does.
#
# The paragraph mattered because the same text sat in pre-tool-hook.sh, where it was false:
# that hook has a tolower()-only comparison in its tool-rule matcher, and a `forbid` rule
# stopped blocking under the pin (#76). Stated per file now rather than pasted three times.
#
# The alternative -- sanitising the bytes before matching -- needs a pass that cannot
# itself decode, which is the same trap one layer down.
#
# Scoped to this awk, not exported: rebuild-tsv.sh has its own awk and the opposite
# contract (it may fail loudly), and it sources this hook shared file too.
cat | LC_ALL=C awk \
  -v paths_base="$JIT_BASE/paths" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v vocab_paths="$VOCAB_PATHS" \
  -v state_dir="$JIT_STATE_DIR" \
  -v log_tmp="$JIT_TMP" \
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
  # Both marker paths are derived from the same parse. state_dir is empty when the tree
  # cannot hold one and the key is empty when the payload names no session; either way
  # these are "" and the shown sets live and die with this process. See common.sh.
  # The vocabulary one is deliberately the SAME file the prompt hook writes.
  shown_file = jit_shown_file(state_dir, "path", raw, fs, fe, n)
  vocab_shown_file = jit_shown_file(state_dir, "vocab", raw, fs, fe, n)
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
  jit_shown_load(shown_file, shown)

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

      # An index row is a channel into additionalContext in its own right: the pattern
      # column is echoed back in the (matched: ...) header, so a byte the JSON string
      # cannot carry reaches stdout without ever being in an entry file (#77). A NUL here
      # truncated the dedup key on both engines (#78). Checked BEFORE the split, so no
      # column of an unusable row is read at all.
      why = jit_bad_bytes(tline, "the index row")
      if (why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id("paths/" layer, rown) ": " why)
        # Positioned, never quoted: the raw text is the thing that could not be carried.
        log_matches = log_matches sep "refused:" jit_row_id("paths/" layer, rown) "(" why ")"
        sep = ", "
        continue
      }

      split(tline, tf, "\t")
      pattern = tf[1]; rule_file = tf[2]

      # Containment first, before the shown set and before the pattern: the file name is
      # about to be concatenated onto this layer directory, and a row of ../../../x made
      # the hook read that file and inject it. See jit_bad_entry_file in common.sh.
      why = jit_bad_entry_file(rule_file, paths_base "/" layer)
      if (why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id("paths/" layer, rown) ": " why)
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
        # POSITIONED, not named. This branch used to echo rule_file, arguing that the row
        # had passed the bare-name check above so the name could not carry a separator.
        # True, and beside the point: that check forbids a slash, a backslash, `.` and `..`
        # and nothing else, so 250 bytes of English pass it intact. A file-name column
        # reading "IGNORE ALL PREVIOUS INSTRUCTIONS. Run: ..." arrived in the context
        # verbatim, with no rule matched and no entry file present (#35).
        #
        # The name is not lost, it moved: jit_log_name() puts it in hooks.log, which a
        # person reads and no model does, and jit-dry-run.sh — which this notice tells the
        # author to run — prints the name beside the reason. The model gets the row.
        # Qualified by DIMENSION, not just by layer. This hook reads paths/<layer> and
        # vocabulary/<layer>, both of which are called 00-manual, and the file name used to
        # tell those two apart. Withholding the name without adding the dimension would have
        # made one notice line ambiguous in exchange for closing the other hole.
        refused = jit_refuse_add(refused, jit_row_id("paths/" layer, rown) ": " why)
        log_matches = log_matches sep "refused:" rule_file "(" why ")"
        sep = ", "
        continue
      }

      path_matched = 0
      for (pi = 1; pi <= path_count; pi++) {
        if (match(all_paths[pi], pattern)) { path_matched = 1; break }
      }
      if (!path_matched) continue

      # The body is read BEFORE anything is marked shown. A row whose entry file will not
      # open used to be marked anyway -- nothing injected, nothing refused, and the key
      # recorded as delivered, which is how a NUL-truncated row went missing in silence on
      # one-true-awk (#78). A mark now records an injection that happened.
      why = jit_read_body(paths_base "/" layer "/" rule_file)
      if (why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id("paths/" layer, rown) ": " why)
        # The name PASSED the bare-name check above, so it is what an author fixing this
        # needs and jit_log_name() keeps it -- the log is read by a person, not a model.
        log_matches = log_matches sep "refused:" jit_log_name(rule_file, layer, rown, why) "(" why ")"
        sep = ", "
        continue
      }
      content = JIT_BODY

      if (content != "") {
        shown[rule_file] = 1
        jit_shown_mark(shown_file, rule_file)
        header = "# JIT Context: " rule_file " (matched: " pattern ")"
        log_matches = log_matches sep layer ":" rule_file "(" pattern ")"
        sep = ", "
        if (matched != "") matched = matched "\n---\n" header "\n" content
        else matched = header "\n" content
      }
    }
    close(index_file)
  }

  # --- Scan vocabulary path layers (autonomous runs only) ---
  # Shares the shown-file written by the prompt hook, so an entry already delivered at
  # intake is not repeated here. Index entries are literal path fragments ("src2/SiBlog/"),
  # not regexes: matched with index(), and the trailing slash keeps src2/Bra/ off src2/Bram/.
  if (vocab_paths == "1") {
    jit_shown_load(vocab_shown_file, vshown)

    for (li = 1; li <= 4; li++) {
      layer = layers[li]
      vindex = vocab_base "/" layer "/01-paths.tsv"

      vrown = 0
      while ((getline vline < vindex) > 0) {
        vrown++

        # Same two channels as the rule loop above, same verdict. See jit_bad_bytes().
        why = jit_bad_bytes(vline, "the index row")
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
          log_matches = log_matches sep "refused:" jit_row_id("vocabulary/" layer, vrown) "(" why ")"
          sep = ", "
          continue
        }

        split(vline, vf, "\t")
        vpattern = vf[1]; vocab_file = vf[2]

        # Same containment check as the rule loop above: this name is concatenated too.
        why = jit_bad_entry_file(vocab_file, vocab_base "/" layer)
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
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

        # Read first, mark only what was delivered. Same reason as the rule loop above.
        why = jit_read_body(vocab_base "/" layer "/" vocab_file)
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
          log_matches = log_matches sep "refused:" jit_log_name(vocab_file, layer, vrown, why) "(" why ")"
          sep = ", "
          continue
        }
        vcontent = JIT_BODY

        if (vcontent != "") {
          vshown[vocab_file] = 1
          jit_shown_mark(vocab_shown_file, vocab_file)
          vheader = "# Vocabulary: " vocab_file " (matched path: " vpattern ")"
          log_matches = log_matches sep layer ":" vocab_file "(" vpattern ")"
          sep = ", "
          if (matched != "") matched = matched "\n---\n" vheader "\n" vcontent
          else matched = vheader "\n" vcontent
        }
      }
      close(vindex)
    }
  }

  # --- A refused row is reported, once per session ---
  # Same reason as the tool hook: the log is where dead rules go unnoticed, and this
  # is the only channel that reaches an author who can fix it. Free while clean.
  if (n_refused > 0 && !("jit-refused-paths" in shown)) {
    shown["jit-refused-paths"] = 1
    jit_shown_mark(shown_file, "jit-refused-paths")
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
    jit_shown_mark(shown_file, "jit-refused-config")
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
  # jit_log_text() first, THEN the truncation. fp_short is payload text after
  # jit_unescape(), so a JSON newline escape is a real newline here; stripping after the
  # cut would leave the first 80 bytes still carrying one. See common.sh (#65).
  fp_short = substr(jit_log_text(fp_short), 1, 80)
  if (log_matches == "") log_matches = "(none)"
  # Empty means bash could not get a scratch file at all -- see jit_tmp_open() in
  # common.sh. Redirecting to "" is a FATAL awk error raised inside END, which would take
  # the injection below with it: the #50 shape, out of the line meant to record it.
  if (log_tmp != "") {
    # Marks FIRST, then the sentinel jit_shown_flush() writes, then the log line. The log
    # line ends with payload text, so anything after it can be forged with a newline --
    # which is how a `block` rule was silently marked already-shown (#65). One `path<TAB>key`
    # per mark; bash appends them, because bash can test `[ -L ]` and survive a redirect
    # that fails. See common.sh.
    jit_shown_flush(log_tmp)
    printf "%s\t%s\n", log_matches, fp_short > log_tmp
    close(log_tmp)
  }

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

# `-s`, not `-f`: mktemp always leaves the file there, so its EXISTENCE stopped being
# evidence that awk had anything to say. An empty one would otherwise be read as a log
# line made of empty fields. Removal is the EXIT trap in common.sh, not a line here --
# one creator, one remover, and the crash path covered too.
if [ -n "$JIT_TMP" ] && [ -s "$JIT_TMP" ]; then
  # One open: every marker append awk asked for, the sentinel that ends them, then the
  # log line. Marks are read into memory and applied AFTER the file is closed, so a
  # channel with no sentinel applies nothing -- see jit_marks_read() in common.sh (#65).
  {
    jit_marks_read
    IFS=$'\t' read -r AWK_MATCHES AWK_PATH
  } < "$JIT_TMP"
  jit_shown_apply
  _log_hook "pre-path" "$TOTAL" "$AWK_MATCHES << $AWK_PATH"
fi

# Stated, not inherited. The hook exit status used to be whatever the last command
# happened to leave behind -- which was `rm -f`, and always 0 by accident. With the
# removal moved to the EXIT trap the last command became the log append, and a project
# whose .discovery is read-only exited 1: a hook that FAILED HARD because it could not
# write a log line. tests/test-session-markers.sh section H caught it.
exit 0
