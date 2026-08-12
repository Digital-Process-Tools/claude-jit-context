#!/bin/bash
# claude-jit-context — Vocabulary-based UserPromptSubmit hook
# Single awk process: parses JSON, matches keywords against TSV indexes, outputs JSON.

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"
T_START=$(_ms)

# Created with O_EXCL under an unpredictable name, removed by an EXIT trap in this
# process, and empty when this platform could not give us one. See common.sh (#60).
jit_tmp_open

# LC_ALL=C on this awk and nowhere else (#68). A malformed UTF-8 byte in the payload --
# a paste out of a Latin-1 file, a multibyte sequence cut at a copy boundary, a filename
# echoed from a differently-encoded checkout -- made one-true-awk abort the END block with
# `illegal byte sequence`: nothing on stdout, not even `{}`, the diagnostic written into
# the session, exit 0. Failing open AND being loud, which is what the top of common.sh
# forbids in one sentence. gawk did not abort but printed a multibyte warning to the same
# place. Under `C` both engines read the record as bytes and neither has anything to
# decode, so neither can fail to.
#
# WHAT IT COSTS, checked rather than assumed. Under `C`, tolower() stops case-folding
# non-ASCII. The Latin-1 fold table added in #31 already carries BOTH cases explicitly --
# it had to, because one-true-awk tolower() never folded a multibyte capital -- so under
# `C` gawk simply takes the branch one-true-awk always took. Driven over four spellings of
# `detail` on both engines under both locales: all sixteen match. Driven again as a
# differential over a mixed ASCII/French/German/Greek/Cyrillic corpus against this
# repository own tree: the injected output is byte-identical UTF-8 vs C on each engine,
# and byte-identical between the two engines under C.
#
# A letter outside Latin-1 is unaffected either way: the strip maps every non-ASCII byte
# to a space regardless of case, so the two locales cannot disagree about it.
#
# The alternative -- sanitising the bytes before tolower() -- needs a pass that cannot
# itself decode, which is the same trap one layer down.
#
# Scoped to this awk, not exported: rebuild-tsv.sh has its own awk and the opposite
# contract (it may fail loudly), and it sources this hook shared file too.
cat | LC_ALL=C awk \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v state_dir="$JIT_STATE_DIR" \
  -v log_tmp="$JIT_TMP" \
  "$JIT_AWK_ENTRY$JIT_AWK_JSON$JIT_AWK_FOLD"'
# RFC 8259 forbids a raw U+0000-U+001F inside a JSON string, and a strict parser is
# entitled to reject the whole object -- which renders as this hook having had nothing to
# say. Only backslash, quote, tab and newline were escaped; CR was the one that shipped,
# because an entry authored on Windows has CRLF line endings and this repo .gitattributes
# covers OUR files, not a user (issue #15).
#
# Backslash goes first, or every escape introduced after it is doubled.
#
# The tail loop is guarded by index() rather than a regex: index() is a byte search with no
# multibyte decode -- the same reason the CamelCase split above uses it -- and no byte of a
# UTF-8 sequence falls in 0x00-0x1F, so it can never cut a multibyte character in half. The
# two fixes pass over different buffers and neither can undo the other.
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
  # --- Parse JSON: extract prompt ---
  # jit_json_fields/jit_unescape live in common.sh. A bare quote split cut the prompt at
  # the first escaped quote a user typed, and left every \n as the two characters \ and n
  # — which glued the word after a line break to an "n" and hid it from keyword lookup.
  n = jit_json_fields(input, raw, fs, fe)
  # The marker path is derived from the same parse: state_dir is empty when the tree cannot
  # hold one, and the key is empty when the payload names no session. Either way this is ""
  # and the shown set lives and dies with this process. See common.sh.
  shown_file = jit_shown_file(state_dir, "vocab", raw, fs, fe, n)
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] == "prompt") { message = jit_unescape(jit_field(raw, fs[i+2], fe[i+2])); break }
  }

  if (message == "") { print "{}"; exit }

  # The log copy, and only the log copy. Lowercased so a miss report groups on the word
  # rather than on its capitalisation; NOT folded, because the log is a record of what the
  # user typed and jit-misses.sh folds it for itself when it reads this line. The matching
  # subject is built further down and is folded there.
  msg = tolower(message)

  # Word-boundary match prep:
  # 1. Split CamelCase: "SiProjectModule" -> "Si Project Module"
  # The case test is index() and not /[A-Z]/. Matching a regex against a SINGLE character
  # is a multibyte decode, and one character of a UTF-8 string is one BYTE to one-true-awk:
  # a lone continuation byte raised "towc: multibyte conversion failure", which aborts the
  # END block. The hook then printed nothing at all and still exited 0, so every vocabulary
  # entry was silently skipped for any prompt carrying an accent -- "détail de la
  # facturation" matched nothing while "comment marche la facturation" matched (issue #14).
  # gawk decodes the whole string and never hit it, which is why Linux CI stayed green and
  # macOS and Git Bash did not.
  #
  # index() is a plain byte search with no decode, and it cannot change the verdict: every
  # byte of a multibyte UTF-8 sequence is >= 0x80, so none of them is ever an ASCII letter
  # or digit either way. The empty guards keep the substitution exact rather than merely
  # equivalent: index(s, "") returns 1, so an unguarded p == "" splits on a leading capital
  # where /[a-z0-9]/ did not. Measured: the two agree byte for byte anyway, because the
  # whitespace collapse below absorbs the extra separator. Kept because the next person to
  # reach for index() on a single character should not have to re-derive that.
  cc = ""
  for (i = 1; i <= length(message); i++) {
    c = substr(message, i, 1)
    p = (i > 1) ? substr(message, i-1, 1) : ""
    if (c != "" && p != "" && index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) > 0 && index("abcdefghijklmnopqrstuvwxyz0123456789", p) > 0) cc = cc " " c
    else cc = cc c
  }
  # 2. Pad, lowercase, fold Latin-1 accents, strip non-alnum (keep hyphens) so kw lookup
  # is space-bounded. The fold is jit_fold_latin1() in common.sh and it runs before the
  # strip on purpose: the strip maps the accent to a space, so `détail` reached the lookup
  # as the two fragments `d` and `tail` and could never match the keyword `detail` (#31).
  # rebuild-tsv.sh folds the keyword with the same table, or the two sides normalise to
  # different spellings and the row is dead with nothing to show for it.
  low = " " tolower(cc) " "
  padded = jit_fold_latin1(low)
  # An index built BEFORE the fold carries the mangled spelling -- the keyword `détail` as
  # the row `d tail` -- and that row did match an accented prompt, by accident. Folding the
  # prompt alone would take it out on upgrade, silently, for anyone who has not rebuilt.
  # So the unfolded subject stays as a second lookup. It is built only when the fold
  # changed something, which for an ASCII prompt is never: that case pays one comparison.
  # A prompt that DOES carry an accent pays a second index() on every row, for the whole
  # session and not just until the index is rebuilt -- the guard reads the prompt, which
  # is the only side this process can see. Measured over a 1002-row index on awk 20200816:
  # 34 ms for the ASCII prompt, 37 ms for the accented one. The second scan is a byte
  # search over a prompt-sized string, not over the index.
  stale = (padded != low) ? low : ""
  gsub(/[^a-z0-9 -]/, " ", padded)
  gsub(/  +/, " ", padded)
  if (stale != "") {
    gsub(/[^a-z0-9 -]/, " ", stale)
    gsub(/  +/, " ", stale)
  }

  # --- Load shown set ---
  jit_shown_load(shown_file, shown)

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
      why = jit_bad_entry_file(vfile, vocab_base "/" layer)
      if (why != "") {
        if (!((layer "/" vfile) in vrefused)) {
          vrefused[layer "/" vfile] = 1
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
          log_matches = log_matches sep "refused:" jit_log_name(vfile, layer, vrown, why) "(" why ")"
          sep = ", "
        }
        continue
      }
      if (!(vfile in shown) && (index(padded, " " kw " ") > 0 || (stale != "" && index(stale, " " kw " ") > 0))) {
        # Named once. Folding the keyword makes two spellings of it collide -- an author
        # who writes `keywords: détail, detail` now gets two identical rows out of
        # rebuild-tsv.sh, and the header read `(matched: detail|detail)`. That list is a
        # receipt injected into the context window, so it must not double-count.
        # index() on the delimited string, not an array: awk has no `in` for a substring.
        if (vfile in vmatch) {
          if (index("|" vmatch[vfile] "|", "|" kw "|") == 0) vmatch[vfile] = vmatch[vfile] "|" kw
        } else vmatch[vfile] = kw
      }
    }
    close(lookup)

    for (vfile in vmatch) {
      shown[vfile] = 1
      jit_shown_mark(shown_file, vfile)

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
    jit_shown_mark(shown_file, "jit-refused-vocab")
    note = jit_refusal_notice(refused, n_refused)
    matched = (matched == "") ? note : note "\n---\n" matched
  }

  # --- A refused config.env line is reported, once per session ---
  # Shares the shown-file with the tool hook, so this lands once across both.
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    jit_shown_mark(shown_file, "jit-refused-config")
    cnote = jit_config_notice(config_refused, config_refused_n)
    matched = (matched == "") ? cnote : cnote "\n---\n" matched
  }
  # --- Log info ---
  sc = 0; for (s in shown) sc++
  # jit_log_text() first, THEN the truncation. A multi-line prompt used to truncate its own
  # log line at the first newline, so jit-misses.sh reported a shorter prompt than the user
  # typed -- and the rest of it was read back as marker lines (#65). See common.sh.
  msg_short = substr(jit_log_text(msg), 1, 80)
  if (log_matches == "") log_matches = "(none)"
  # Empty means bash could not get a scratch file at all -- see jit_tmp_open() in
  # common.sh. Redirecting to "" is a FATAL awk error raised inside END, which would take
  # the injection below with it: the #50 shape, out of the line meant to record it.
  if (log_tmp != "") {
    # Marks FIRST, then the sentinel jit_shown_flush() writes, then the log line. The log
    # line ends with payload text, so anything after it can be forged with a newline (#65).
    # One `path<TAB>key` per mark; bash appends them, because bash can test `[ -L ]` and
    # survive a redirect that fails. See common.sh.
    jit_shown_flush(log_tmp)
    printf "%s\t%d\t%s\n", log_matches, sc, msg_short > log_tmp
    close(log_tmp)
  }

  # --- Output JSON ---
  if (matched != "") {
    matched = jit_json_escape(matched)
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"%s\"}}", matched
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
    IFS=$'\t' read -r AWK_MATCHES AWK_SHOWN AWK_MSG
  } < "$JIT_TMP"
  jit_shown_apply
  _log_hook "pre-prompt" "$TOTAL" "$AWK_MATCHES [shown:$AWK_SHOWN] << $AWK_MSG"
fi

# Stated, not inherited. The hook exit status used to be whatever the last command
# happened to leave behind -- which was `rm -f`, and always 0 by accident. With the
# removal moved to the EXIT trap the last command became the log append, and a project
# whose .discovery is read-only exited 1: a hook that FAILED HARD because it could not
# write a log line. tests/test-session-markers.sh section H caught it.
exit 0
