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
# WHAT IT COSTS. Under `C`, tolower() stops case-folding non-ASCII -- on BOTH engines.
# The sentence this comment carried until #76, that one-true-awk tolower() never folded a
# multibyte capital, is wrong: awk 20200816 folds `CLÉ` to `clé` under a UTF-8 locale
# exactly as gawk 5.4.1 does, and neither folds it under `C`. Measured 2026-08-12. So the
# pin changes the verdict of every comparison that leans on tolower() ALONE.
#
# What makes the pin free is jit_fold_latin1() (#31), never tolower(): the table carries
# both cases explicitly and is applied with index()/substr(), so it decodes nothing and
# asks the locale nothing. A comparison that runs the fold on BOTH of its sides reaches
# the same verdict under C as under UTF-8, on either engine.
#
# This hook has exactly one such comparison, the vocabulary lookup, and it does fold: the
# subject below and the keyword rebuild-tsv.sh wrote, with the same table. Driven over
# four spellings of `detail` on both engines under both locales, all sixteen match; and
# again as a differential over a mixed ASCII/French/German/Greek/Cyrillic corpus against
# this repository own tree, byte-identical UTF-8 vs C on each engine and between the two
# engines under C. That check was real and it did NOT cover pre-tool-hook.sh, whose tool
# rules folded nowhere and failed open for it (#76) -- so read this paragraph as a claim
# about this file only.
#
# A letter outside Latin-1 is unaffected either way: the strip maps every non-ASCII byte
# to a space regardless of case, so the two locales cannot disagree about it.
#
# The alternative -- sanitising the bytes before tolower() -- needs a pass that cannot
# itself decode, which is the same trap one layer down.
#
# Scoped to this awk, not exported: rebuild-tsv.sh has its own awk and the opposite
# contract (it may fail loudly), and it sources this hook shared file too.
# Enumerated, never a literal (#176). See jit_scan_layers() in common.sh: a layer name
# outside the four this used to hardcode was indexed by the rebuild and read by nothing.
jit_scan_layers "$JIT_BASE/vocabulary" vocabulary
# #233: reads the on-disk age of every 00-manual vocabulary entry, once, before awk
# ever runs -- see jit_scan_entry_ages() in common.sh for why this is a bash-side scan
# and not a per-row stat.
jit_scan_entry_ages "$JIT_BASE/vocabulary"

cat | LC_ALL=C awk \
  -v vocab_layers="$JIT_LAYERS" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v state_dir="$JIT_STATE_DIR" \
  -v inject_default="$JIT_INJECT" \
  -v log_tmp="$JIT_TMP" \
  "$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_JSON$JIT_AWK_FOLD$JIT_AWK_BLK_BUILD"'
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
# --- Blocks are tracked, not glued (#219) ------------------------------------------
#
# Until now, every matched entry and every refusal notice was appended straight into one
# growing string, joined by the literal text "\n---\n". That text is prose, and the thing
# it separates is arbitrary author-controlled markdown -- .claude/jit-context/ is
# attacker-controlled input, not configuration (paths/00-manual/hooks.md). An entry whose
# own FULL-MODE body happens to end in the same bytes -- "\n---\n# Vocabulary: " -- joins
# with the next block in a way byte-identical to a genuine boundary, so no property of the
# surrounding text can ever tell the two cases apart. Proven, not merely suspected:
# reproduced on scripts/jit-match.sh before it grew a narrower, non-load-bearing mitigation
# of its own (jit_index_verified() there, kept deliberately).
#
# The fix is not a cleverer separator -- nothing is structurally excluded from a body: an
# entry is only refused for invalid UTF-8 or (in the INDEX ROW, not the body) a NUL byte,
# see jit_bad_utf8()/jit_bad_bytes() in common.sh, so literally any printable byte sequence
# can appear in author text, including whatever boundary text this hook might choose next.
# What a consumer CAN verify instead is a LENGTH it did not have to search for: each block
# below is pushed onto an array as it is built, so its own exact byte count is known at the
# moment of construction rather than re-derived later by scanning the assembled text for a
# separator an entry body can forge. The final assembly prepends one manifest line naming
# how many blocks there are and each one byte length, in order -- "# JIT-CTX-BLOCKS <n>
# <len1> <len2> ...\n" -- built entirely from length(), never from anything an entry
# authored, so nothing a clone ships can forge it. A consumer that trusts the manifest
# walks the rest of the string by BYTE COUNT, never by searching for "\n---\n" inside it,
# which is what makes the class impossible rather than merely detected: a body that quotes
# "\n---\n# Vocabulary: fake.md" verbatim is just bytes at that point, because the parser
# already knows exactly where the block it is inside of ends.
#
# The human-readable shape is unchanged on purpose: the manifest is one machine-readable
# line, and everything after it is the exact same "\n---\n"-joined prose a session already
# saw, so a real user reading their own context sees nothing new but one line at the top.
#
# jit_blk_prepend() is the ONE ordering rule this hook has always had: a refused-row,
# refused-layer or refused-config notice is added in FRONT of whatever already matched --
# three call sites below, previously three copies of the same string-prepend. Written once
# here instead, over the block array, so recording a length cannot be forgotten at a fourth
# call site later. length(list) > 4096 is bytes, not characters, because this whole awk runs
# under LC_ALL=C (see the T_START comment at the top of this file for why the pin is
# scoped here) -- the same axis jit_refuse_add()/jit_unreached_add() already use for their
# own 4096-byte caps.
#
# jit_blk_prepend() and its sibling jit_blk_join() now live in common.sh (JIT_AWK_BLK_BUILD,
# #230), so pre-tool-hook.sh and pre-path-hook.sh -- which never had a manifest producer at
# all until #230 -- share this file own copy instead of hand-rolling a third one.
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

  # nblk/blk[] are the ordered block list jit_blk_prepend() and the vocab loop below
  # populate; the final matched string is assembled from them once, at the very end (#219).
  nblk = 0
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0

  # --- Scan vocab layers ---
  # The list is enumerated from disk by jit_scan_layers() in common.sh and arrives here as
  # a -v value; the bound comes off the same split() rather than being a second literal
  # beside it, which is how a fix for #176 that changed only the string would have
  # truncated the list silently.
  n_layers = split(vocab_layers, layers, " ")
  for (li = 1; li <= n_layers; li++) {
    layer = layers[li]
    lookup = vocab_base "/" layer "/00-index.tsv"

    # Single pass: match keywords, collect files + matched keywords
    delete vmatch
    # The row a matched file was FIRST seen at, so a body this loop cannot deliver is
    # named by position like every other refusal -- the loop below walks files, not rows.
    delete vmrow
    # #232: whether AT LEAST ONE keyword that matched this file was specific (the 3rd
    # TSV column is anything but "generic", including missing -- the documented
    # degrade-to-specific case). A file with no key here matched on generic keywords
    # only, and is downgraded to summary and left unmarked below.
    delete vspecific
    vrown = 0
    while ((getline vl < lookup) > 0) {
      vrown++

      # The index row is a channel into additionalContext too -- the keyword column is
      # echoed in the (matched: ...) header (#77) -- and a NUL in the file column silently
      # truncated the dedup key (#78). Checked before the split, so no column of an
      # unusable row is read at all. See jit_bad_bytes() in common.sh.
      why = jit_bad_bytes(vl, "the index row")
      if (why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
        log_matches = log_matches sep "refused:" jit_row_id("vocabulary/" layer, vrown) "(" why ")"
        sep = ", "
        continue
      }

      split(vl, vf, "\t")
      kw = vf[1]; vfile = vf[2]; kwverdict = vf[3]
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
        } else { vmatch[vfile] = kw; vmrow[vfile] = vrown }
        # #232: ANY specific keyword hitting this file is enough to keep it full-mode.
        # A missing or empty 3rd column degrades to specific -- the documented fallback
        # for an index built before this landed.
        if (kwverdict != "generic") vspecific[vfile] = 1
      }
    }
    close(lookup)

    for (vfile in vmatch) {
      # #232: a file reached ONLY through generic keywords this turn. Downgraded to
      # title+description below and left OUT of `shown`, so the full body still arrives
      # the moment a specific keyword hits later in the session -- the entry one shot
      # is never spent on an ordinary-word match.
      generic_only = !(vfile in vspecific)
      # The entry is read BEFORE anything is marked shown. A row whose entry file will not
      # open was marked delivered anyway, which is exactly what a NUL-truncated row looks
      # like to one-true-awk (#78), and an entry the JSON channel cannot carry is refused
      # rather than voiding every other entry in the same call (#77).
      #
      # jit_entry_load/jit_inject_text live in common.sh. What arrives here is the
      # entry title and its author-written description by default, and the whole body
      # only when the project or the entry asks for it -- see JIT_AWK_INJECT for why
      # the choice belongs to the project owner and not to the entry author. The refusal
      # reason comes back in vent["why"], and it carries the same guards the single body
      # reader has always applied.
      vc = ""
      vpath = vocab_base "/" layer "/" vfile
      if (jit_entry_load(vpath, inject_default, 0, vent)) {
        # Overridden AFTER load, never passed in: jit_entry_load own default/pin
        # logic (project setting, an entry inject: line, a frontmatter-less file
        # pinned to full) is exactly what a generic-only match must NOT honour --
        # #232 asks for summary regardless of what the entry or the project would
        # otherwise choose, precisely because nothing here changed how the entry
        # itself is configured.
        if (generic_only) vent["mode"] = "summary"
        vc = jit_inject_text(vent, ".claude/jit-context/vocabulary/" layer "/" vfile)
      } else if (vent["why"] != "") {
        why = vent["why"]
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vmrow[vfile]) ": " why)
        log_matches = log_matches sep "refused:" jit_log_name(vfile, layer, vmrow[vfile], why) "(" why ")"
        sep = ", "
        continue
      }

      if (vc != "") {
        if (!generic_only) {
          shown[vfile] = 1
          jit_shown_mark(shown_file, vfile)
        }
        # #233: age is looked up by "layer/vfile", the same key jit_scan_entry_ages()
        # (common.sh) wrote it under. "" means no age was measured for this file --
        # outside 00-manual, or a platform this could not run perl on -- and the header
        # then reads exactly as it did before #233, never claiming a false "0d ago".
        vage = (layer ~ /00-manual/) ? jit_entry_age(layer "/" vfile) : ""
        vh = "# Vocabulary: " vfile " (matched: " vmatch[vfile] (vage != "" ? " · last edited " vage "d ago" : "") ")"
        if (layer ~ /00-manual/) vh = vh "\\n[vocab-upkeep] Learned something new here, or found this entry wrong? Edit it now — hand-written entries live in 00-manual/."
        log_matches = log_matches sep layer ":" vfile "(" vmatch[vfile] ")" jit_inject_tag(vent) (generic_only ? ":generic-only" : "")
        sep = ", "
        nblk++; blk[nblk] = vh "\n" vc
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
    jit_blk_prepend(note)
  }

  # --- A layer directory that could not be read is reported, once per session ---
  # #176: this is the state that had no channel at all. A layer nobody could load and a
  # layer whose rules never matched produced the same silence, and every other signal --
  # the rebuild count, the linter, doctor -- said the layer was healthy.
  layers_refused = ENVIRON["JIT_LAYERS_REFUSED"]
  layers_refused_n = ENVIRON["JIT_LAYERS_REFUSED_N"] + 0
  if (layers_refused_n > 0 && !("jit-refused-layers" in shown)) {
    shown["jit-refused-layers"] = 1
    jit_shown_mark(shown_file, "jit-refused-layers")
    lnote = jit_layers_notice(layers_refused, layers_refused_n)
    jit_blk_prepend(lnote)
  }

  # --- A refused config.env line is reported, once per session ---
  # Shares the shown-file with the tool hook, so this lands once across both.
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    jit_shown_mark(shown_file, "jit-refused-config")
    cnote = jit_config_notice(config_refused, config_refused_n)
    jit_blk_prepend(cnote)
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

  # --- Assemble the manifest and join the blocks (#219, #230) ---
  # nblk/blk[] are populated above: once per real vocabulary match, and once more per
  # refused-row/layer/config notice, in final display order. jit_blk_join() (common.sh,
  # JIT_AWK_BLK_BUILD) builds the manifest from length(blk[i]) alone -- never from
  # anything an entry authored -- and returns "" when nblk is 0, which the guard below
  # already reads as "nothing to inject."
  matched = jit_blk_join()

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
  # Two arguments, not one concatenation: _log_hook caps the matches field and leaves the
  # tail alone (#64). The tail is already bounded to 80 bytes inside awk and is what
  # jit-misses.sh reads -- it anchors on `(none) [shown:` and then on ` << ` -- so it must
  # survive a line that had to be cut.
  _log_hook "pre-prompt" "$TOTAL" "$AWK_MATCHES" "[shown:$AWK_SHOWN] << $AWK_MSG"
fi

# Stated, not inherited. The hook exit status used to be whatever the last command
# happened to leave behind -- which was `rm -f`, and always 0 by accident. With the
# removal moved to the EXIT trap the last command became the log append, and a project
# whose .discovery is read-only exited 1: a hook that FAILED HARD because it could not
# write a log line. tests/test-session-markers.sh section H caught it.
exit 0
