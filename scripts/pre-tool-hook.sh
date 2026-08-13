#!/bin/bash
# claude-jit-context — PreToolUse hook
# Single awk process: parses JSON, scans tool + vocab TSVs, outputs JSON.
# Bash wrapper only handles timing (2 perl calls) and log writing.

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
# pin changes the verdict of every comparison that leans on tolower() ALONE, and it does
# so on every platform rather than only on Linux.
#
# What makes the pin free is jit_fold_latin1() (#31), never tolower(): the table carries
# both cases explicitly and is applied with index()/substr(), so it decodes nothing and
# asks the locale nothing. A comparison that runs the fold on BOTH of its sides reaches
# the same verdict under C as under UTF-8, on either engine. A comparison that does not is
# a live defect.
#
# This hook has two FAMILIES of such comparison -- one vocabulary lookup and the four
# tool-rule sites below -- and #68 only checked the first. The vocabulary
# lookup folds its subject below and reads an index rebuild-tsv.sh folded with the same
# table -- that half was driven over four spellings of `detail` on both engines under both
# locales, and again as a differential over a mixed ASCII/French/German/Greek/Cyrillic
# corpus against this repository own tree: byte-identical output, UTF-8 vs C on each
# engine and between the engines under C. The TOOL RULES did not fold at all, so
# `forbid: clé-privée` stopped blocking `CLÉ-PRIVÉE` and the deny-list rule allowed the
# call (#76). They fold both sides now; see the block above the row loop.
#
# A letter outside Latin-1 is unaffected either way in the vocabulary pass: the strip maps
# every non-ASCII byte to a space regardless of case, so the two locales cannot disagree
# about it. In the tool pass it is compared byte for byte, which is also locale-blind --
# what it is not is case-insensitive, and it never was on either engine under `C`.
#
# The alternative -- sanitising the bytes before tolower() -- needs a pass that cannot
# itself decode, which is the same trap one layer down.
#
# Scoped to this awk, not exported: rebuild-tsv.sh has its own awk and the opposite
# contract (it may fail loudly), and it sources this hook shared file too.
cat | LC_ALL=C awk \
  -v tools_tsv="$JIT_BASE/tools/00-manual/00-index.tsv" \
  -v tools_dir="$JIT_BASE/tools/00-manual" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v state_dir="$JIT_STATE_DIR" \
  -v home="$HOME" \
  -v project="${CLAUDE_PROJECT_DIR:-.}" \
  -v log_tmp="$JIT_TMP" \
  "$JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_JSON$JIT_AWK_FOLD"'
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
  # The marker path is derived from the same parse: state_dir is empty when the tree cannot
  # hold one, and the key is empty when the payload names no session. Either way this is ""
  # and the shown set lives and dies with this process. See common.sh.
  shown_file = jit_shown_file(state_dir, "vocab", raw, fs, fe, n)
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

  # --- The subjects the tool rules are matched against, folded once (#76) --------------
  # tolower() is not enough on its own and never was. Under the `C` pin from #68 neither
  # engine folds a multibyte capital -- measured on gawk 5.4.1 AND on one-true-awk
  # 20200816, which does fold under a UTF-8 locale, so this was never the gawk-only
  # divergence #68 assumed. A rule written `forbid: clé-privée` stopped matching
  # `CLÉ-PRIVÉE`: the block became a reminder, exit 0, nothing on stderr.
  #
  # jit_fold_latin1() is the answer this codebase already gives to "how do we compare
  # non-ASCII text", and it is the right one here because it is locale-independent BY
  # CONSTRUCTION: it is index()/substr() over a table carrying both cases explicitly, so
  # it decodes nothing and asks the locale nothing. That is also why rebuild-tsv.sh may
  # keep folding without the pin (common.sh:1108) -- the fold is bytes in, bytes out, and
  # the two locales cannot disagree about it. Only tolower() was ever locale-sensitive.
  #
  # Folded HERE, once, rather than per row: the fold is 51 index() scans of the subject,
  # and the loop below would run it per rule otherwise. The terms are folded at their four
  # comparison sites instead, because they are short and because the raw term is what the
  # injected header and the block reason echo back to the author.
  #
  # What the per-row term fold costs, measured on gawk 5.4.1, 20 calls per point,
  # interleaved against 5f3d14e on the same machine: 20 rows 63 -> 65 ms, 100 rows
  # 61 -> 62 ms, 1000 rows 66 -> 83 ms. A tools index is rules a human wrote, and the
  # shapes that exist are the first two; the 1000-row figure is there so the next person
  # reaching for a per-row fold knows where it starts to show. The 1000-entry corpus the
  # README cites is VOCABULARY, and that pass is untouched by this.
  #
  # Both sides, always. #31 learned that folding one side of a comparison silently kills
  # the rows that used to line up -- worse than the bug it fixes. Nothing in the tool
  # dimension is folded at index time, so both sides are folded here and there is no
  # migration: a tools/00-index.tsv written by any previous version still matches.
  fold_cmd = jit_fold_latin1(tolower(cmd))
  fold_full = jit_fold_latin1(tolower(full_command))

  matched = ""
  blocked = ""
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0

  # --- Load shown file into set ---
  jit_shown_load(shown_file, shown)

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

    # The row itself. The match column is echoed back in the (matched: ...) header and the
    # require and forbid columns are echoed in a block reason, so a byte the JSON string
    # cannot carry reaches stdout from the index alone, with no entry file involved (#77).
    # A NUL truncated the dedup key (#78).
    #
    # Unlike an undeliverable BODY, this refuses the row and the call is not blocked -- and
    # the difference is not an inconsistency. A bad body leaves the decision intact, since
    # mode, require and forbid all come from the row, so refusing there would throw away a
    # verdict that was reached. Bad bytes in the ROW are the decision inputs themselves:
    # there is no verdict to preserve, and blocking a call on a rule nobody can read is not
    # the safe direction, it is a different failure. Same posture as jit_bad_pattern().
    #
    # Which is why this sits AFTER r_kind and not before the split: "a block rule went
    # dark" is the part of an untrusted row worth saying, and it is DERIVED from column 4
    # rather than quoted out of it -- exactly what the comment above already argues.
    why = jit_bad_bytes(tline, "the index row")
    if (why != "") {
      n_refused++
      refused = jit_refuse_add(refused, jit_row_id("tools/00-manual", rown) r_kind ": " why)
      log_matches = log_matches sep "refused:" jit_row_id("tools/00-manual", rown) "(" why ")"
      sep = ", "
      continue
    }

    why = jit_bad_entry_file(r_file, tools_dir)
    if (why != "") {
      n_refused++
      refused = jit_refuse_add(refused, jit_row_id("tools/00-manual", rown) r_kind ": " why)
      log_matches = log_matches sep "refused:" jit_log_name(r_file, "tools/00-manual", rown, why) "(" why ")"
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
        # POSITIONED, not named. This branch used to echo r_file, arguing that the row had
        # passed the bare-name check so the name was safe. That check forbids a slash, a
        # backslash, `.` and `..` and nothing else — 250 bytes of English pass it intact,
        # and a file-name column reading "IGNORE ALL PREVIOUS INSTRUCTIONS. Run: ..." landed
        # in the context verbatim, with no rule matched and no entry file present (#35).
        # The sibling of the r_modes hole below, one column over in the same statement.
        #
        # The name is not lost, it moved: jit_log_name() puts it in hooks.log, which a
        # person reads and no model does, and jit-dry-run.sh — which this very notice tells
        # the author to run — prints the name beside the reason. The model gets the row.
        #
        # r_kind, never r_modes. Column 4 is free text from a committed index and this
        # branch was interpolating it raw, thirty-five lines under the comment saying why
        # that is not allowed and one branch over from the code that honours it. It needs
        # no rule to match and no entry file to exist, so a mode column reading "IGNORE ALL
        # PREVIOUS INSTRUCTIONS: ..." arrived in the context on the first Bash call of the
        # session. Reproduced 2026-08-12; tests/test-security.sh drives both halves.
        refused = jit_refuse_add(refused, jit_row_id("tools/00-manual", rown) r_kind ": " why)
        log_matches = log_matches sep "refused:" r_file "(" why ")"
        sep = ", "
        continue
      }
      # The PATTERN is folded too, not just the subject (#76). Folding one side alone is
      # the #31 mistake one level down: against a folded subject, an ERE carrying `é`
      # becomes unmatchable rather than accent-insensitive. The fold is safe on a regex
      # because every entry in the table maps a Latin-1 LETTER to ASCII letters -- it can
      # introduce no metacharacter, so a pattern that compiled before still compiles.
      # It runs AFTER jit_bad_pattern(), so the author is diagnosed against what they
      # wrote.
      #
      # NOT tolower()-ed, unlike the three index() sites below. That is deliberate and
      # unchanged: the subject has always been lowercased and the pattern never was, so a
      # pattern carrying an ASCII capital has matched nothing since this line was written.
      # Lowercasing it here would wake rules that are dead today -- including `block`
      # rules -- which is a behaviour change nobody asked for and not this fix.
      #
      # The fold is a literal substitution with no bracket-expression awareness, and two
      # shapes are widened by it. `[æ]` becomes `[ae]`, which is the accent-insensitivity
      # the plain terms get. A RANGE across the fold is worse: under `C` `[é-ü]` is a
      # bracket expression over the raw bytes and matches almost nothing -- measured, it
      # does not match `exemple de phrase` -- while the folded `[e-u]` matches a third of
      # the lowercase alphabet, and it does. Nobody has written such a pattern and a range
      # over accented endpoints has never meant what its author intended, but this widens
      # rather than fixes it, and a `block` rule is the one that would notice. Refusing
      # non-ASCII inside a bracket expression was the alternative and is worse: it kills
      # `[éè]`, which is legitimate and works.
      if (match(fold_full, jit_fold_latin1(substr(r_match, 2))) == 0) continue
    } else {
      if (index(fold_cmd, jit_fold_latin1(tolower(r_match))) == 0) continue
    }

    # "once" mode. The mark moved BELOW the read (#78): a rule whose body never arrived
    # used to consume its own once-per-session budget, so the next call skipped the row
    # entirely and the rule was silently gone for the session.
    key = ""
    if (index(r_modes, "once") > 0) {
      key = "rule:" r_file
      if (key in shown) continue
    }

    # Read rule .md. A body that cannot be delivered does NOT cancel the decision: mode,
    # require and forbid all come out of the index row, so a block rule whose text is
    # unreadable still blocks and says why in place of the text (#77). Refusing the row
    # outright would turn an unhonourable rule into an allowed call, which is the one
    # direction this dimension may never fail in. The row is named in the notice either
    # way, and the substitute is ASCII, so the reason survives the JSON channel.
    #
    # That sentence was FALSE for one shape of unreadable body until #97, and false in the
    # direction it exists to rule out. A file-name column naming a directory -- or an empty
    # one, which concatenates to the layer directory -- made this getline a fatal i/o error
    # on one-true-awk, so the process carrying a block decision reached three lines below
    # died inside END with no JSON on stdout at all. Not "blocks without its text": no
    # block. jit_read_body() now refuses both shapes before the read, off a set the bash
    # half sweeps, so what this paragraph claims is what the code does on every engine.
    why = jit_read_body(tools_dir "/" r_file)
    content = JIT_BODY
    if (why != "") {
      content = "(the text of this rule was not delivered: " why ")"
      n_refused++
      refused = jit_refuse_add(refused, jit_row_id("tools/00-manual", rown) r_kind ": " why)
      log_matches = log_matches sep "refused:" jit_log_name(r_file, "tools/00-manual", rown, why) "(" why ")"
      sep = ", "
    } else if (key != "") {
      shown[key] = 1
      jit_shown_mark(shown_file, key)
    }

    # Check require
    if (r_require != "") {
      nr = split(r_require, reqs, "|")
      for (ri = 1; ri <= nr; ri++) {
        # Folded on both sides (#76): `require: validé` must be satisfied by `VALIDÉ`.
        # This half fails CLOSED when it breaks -- it refuses a command that met its
        # requirement -- which is the safer direction and still wrong.
        if (index(fold_full, jit_fold_latin1(tolower(reqs[ri]))) == 0) {
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
        # Folded on both sides (#76). This is the half that failed OPEN: `forbid:
        # clé-privée` stopped seeing `CLÉ-PRIVÉE` and the deny-list rule allowed the call.
        if (index(fold_full, jit_fold_latin1(tolower(forbs[fi]))) > 0) {
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
  # 2. Pad, fold Latin-1 accents, strip non-alnum (keep hyphens) for space-bounded kw
  # lookup. This hook reads the SAME vocabulary index as pre-prompt-hook.sh, so it has to
  # normalise a path token exactly as rebuild-tsv.sh normalises the keyword: without the
  # fold, src/Détail/a.php reaches the lookup as `d tail` and a folded row is dead here
  # while it fires from a prompt (#31). The stale variant is the same compatibility path
  # as the prompt hook -- an index built before the fold carries `d tail` as its keyword,
  # and only the unfolded subject can still reach it. Built only when the fold changed
  # something, so an ASCII command pays one comparison.
  low = " " tt " "
  padded = jit_fold_latin1(low)
  stale = (padded != low) ? low : ""
  gsub(/[^a-z0-9 -]/, " ", padded)
  gsub(/  +/, " ", padded)
  if (stale != "") {
    gsub(/[^a-z0-9 -]/, " ", stale)
    gsub(/  +/, " ", stale)
  }

  if (tt != "") {
    split("00-manual 10-auto 20-grouped 30-crosscutting", layers, " ")
    for (li = 1; li <= 4; li++) {
      layer = layers[li]
      lookup = vocab_base "/" layer "/00-index.tsv"

      # Single pass: match keywords, collect files + matched keywords
      delete vmatch
      # The row a matched file was FIRST seen at, so a body this pass cannot deliver is
      # named by position -- the loop below walks files, not rows.
      delete vmrow
      vrown = 0
      while ((getline vl < lookup) > 0) {
        vrown++

        # Same two channels as the rule loop above. See jit_bad_bytes() in common.sh.
        why = jit_bad_bytes(vl, "the index row")
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
          log_matches = log_matches sep "refused:" jit_row_id("vocabulary/" layer, vrown) "(" why ")"
          sep = ", "
          continue
        }

        split(vl, vf, "\t")
        kw = vf[1]; vfile = vf[2]
        why = jit_bad_entry_file(vfile, vocab_base "/" layer)
        if (why != "") {
          # Same concatenation, same refusal. Keyed on the name so one bad row is counted
          # once, not once per keyword that happens to point at it.
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
          # Named once -- see the same guard in pre-prompt-hook.sh. Folding the keyword
          # makes two spellings of it collide, and the header read `(matched: x|x)`.
          if (vfile in vmatch) {
            if (index("|" vmatch[vfile] "|", "|" kw "|") == 0) vmatch[vfile] = vmatch[vfile] "|" kw
          } else { vmatch[vfile] = kw; vmrow[vfile] = vrown }
        }
      }
      close(lookup)

      for (vfile in vmatch) {
        # Read first, mark only what was delivered -- see the same loop in
        # pre-prompt-hook.sh for why the old order marked entries nothing had injected.
        why = jit_read_body(vocab_base "/" layer "/" vfile)
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vmrow[vfile]) ": " why)
          log_matches = log_matches sep "refused:" jit_log_name(vfile, layer, vmrow[vfile], why) "(" why ")"
          sep = ", "
          continue
        }
        vc = JIT_BODY

        if (vc != "") {
          shown[vfile] = 1
          jit_shown_mark(shown_file, vfile)
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
  #
  # It is delivered on the BLOCK path too (#103), appended after the reason rather than
  # prepended, and that reverses what the two comments here used to say. They claimed the
  # suppression kept a block reason "the only thing the model reads". Two things were
  # wrong with it:
  #
  #   The block is STRUCTURAL. `{"decision":"block"}` refuses the call whatever the model
  #   then reads, so text after the reason cannot dilute a decision into failing open. It
  #   is a tidiness preference, and it was buying the sentence four lines up.
  #
  #   And the suppression was not always a deferral. A row refused at LOAD -- an undefined
  #   escape, a bad byte -- is counted on every call whose tool the row names, so a later
  #   call that is not blocked does report it. A row refused at MATCH -- a body
  #   jit_read_body() cannot deliver -- is counted only on a command that row matched, and
  #   when that is the same command a block rule refuses, EVERY call that counts it is
  #   blocked. Driven, not read: the notice never arrived for the rest of the session.
  #
  # The marker is deliberately NOT consumed on the block path. `break` at the block rule
  # ends the row scan, so the list delivered beside a block reason is whatever was reached
  # before the decision and may be short; consuming the marker there would hide the
  # complete list from the next call. The cost is a repeat across consecutive blocked
  # calls, which is the cheaper direction.
  if (n_refused > 0 && !("jit-refused-rules" in shown)) {
    note = jit_refusal_notice(refused, n_refused)
    if (blocked == "") {
      shown["jit-refused-rules"] = 1
      jit_shown_mark(shown_file, "jit-refused-rules")
      matched = (matched == "") ? note : note "\n---\n" matched
    } else {
      block_tail = block_tail "\n---\n" note
    }
  }

  # --- A refused config.env line is reported, once per session ---
  # Parsed in common.sh, reported here, for the same reason as a refused rule: the log is
  # exactly where this would go unnoticed. Delivered on the block path too, for the reason
  # above.
  #
  # This one DOES consume its marker there, and the asymmetry is the truncation and
  # nothing else: config.env is parsed whole in the bash half before awk starts, so the
  # list beside a block reason is the complete list and there is nothing left to arrive
  # later. The rule list is the one a `break` can cut short.
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    jit_shown_mark(shown_file, "jit-refused-config")
    cnote = jit_config_notice(config_refused, config_refused_n)
    if (blocked == "") matched = (matched == "") ? cnote : cnote "\n---\n" matched
    else block_tail = block_tail "\n---\n" cnote
  }
  # --- Write log info to temp file (bash reads it for timing) ---
  sc = 0; for (s in shown) sc++
  # jit_log_text() first, THEN the truncation: both of these are payload text after
  # jit_unescape(), so a JSON newline escape is a real newline by now and the log line
  # would end early with the rest read back as marker lines (#65). See common.sh.
  tt_short = substr(jit_log_text(tt), 1, 120)
  tool_log = jit_log_text(tool_name)
  if (log_matches == "") log_matches = "(none)"
  # Empty means bash could not get a scratch file at all -- see jit_tmp_open() in
  # common.sh. Redirecting to "" is a FATAL awk error raised inside END, which would take
  # the block decision below with it: the #50 shape, out of the line meant to record it.
  if (log_tmp != "") {
    # Marks FIRST, then the sentinel jit_shown_flush() writes, then the log line. One
    # `path<TAB>key` per mark; bash appends them, because bash can test `[ -L ]` and
    # survive a redirect that fails. This is also why a `block` decision can no longer be
    # lost to an unusable marker: nothing between the rule matching and the print below
    # opens a file any more. The ORDER is #65: the log line ends with payload text, so
    # marks written after it could be forged with a newline -- and the rule forged
    # already-shown here was a `block` one. See common.sh.
    jit_shown_flush(log_tmp)
    printf "%s\t%s\t%d\t%s\n", tool_log, log_matches, sc, tt_short > log_tmp
    close(log_tmp)
  }

  # --- Output JSON ---
  if (blocked != "") {
    # block_tail is the refusal notices and NOTHING else: `matched` is deliberately not
    # folded in here. The rules a call happens to match are advisory and belong to the
    # branch below; a rule that could not be evaluated is a report to the author about
    # the tree itself, and it has no other channel (#103).
    blocked = jit_json_escape(blocked block_tail)
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
    IFS=$'\t' read -r AWK_TOOL AWK_MATCHES AWK_SHOWN AWK_TEXT
  } < "$JIT_TMP"
  jit_shown_apply
  # Two arguments, not one concatenation: _log_hook caps the matches field and leaves the
  # tail alone (#64). The tail is already bounded to 80 bytes inside awk and is what
  # jit-misses.sh reads, so it must survive a line that had to be cut.
  _log_hook "pre-tool ($AWK_TOOL)" "$TOTAL" "$AWK_MATCHES" "[shown:$AWK_SHOWN] << $AWK_TEXT"
fi

# Stated, not inherited. The hook exit status used to be whatever the last command
# happened to leave behind -- which was `rm -f`, and always 0 by accident. With the
# removal moved to the EXIT trap the last command became the log append, and a project
# whose .discovery is read-only exited 1: a hook that FAILED HARD because it could not
# write a log line. tests/test-session-markers.sh section H caught it.
exit 0
