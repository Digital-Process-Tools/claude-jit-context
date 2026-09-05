#!/bin/bash
# claude-jit-context — PreToolUse hook
# Single awk process: parses JSON, scans tool + vocab TSVs, outputs JSON.
# Bash wrapper only handles timing (2 perl calls) and log writing.

case "$0" in */*) SCRIPT_DIR="${0%/*}" ;; *) SCRIPT_DIR="." ;; esac
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
# Enumerated, never a literal (#176). See jit_scan_layers() in common.sh.
#
# The tools dimension was the WORST of the three and was not in the issue title: it had no
# layer loop at all. `tools_tsv` and `tools_dir` were pinned to tools/00-manual, so
# `10-auto`, `20-grouped` and `30-crosscutting` were dead here even though docs/layers.md says
# a rule in any of them is indexed and fires -- and this is the only dimension that can
# REFUSE a call, so a `mode: block` rule in one of those layers failed OPEN and said
# nothing. That is the shape claude-oss filed #176 against.
jit_scan_layers "$JIT_BASE/tools" tools
JIT_TOOL_LAYERS="$JIT_LAYERS"
jit_scan_layers "$JIT_BASE/vocabulary" vocabulary
# #233: see the same call and comment in pre-prompt-hook.sh -- read once here too, since
# this hook carries its own copy of the vocabulary match loop and its own footer.
jit_scan_entry_ages "$JIT_BASE/vocabulary"
JIT_VOCAB_LAYERS="$JIT_LAYERS"

# #203: computed once, in bash, before the row loop below ever opens a tools index --
# see jit_missing_requires() in common.sh for why this cannot be an awk-side check.
# Space-padded on both ends so the row loop can test membership with a plain index()
# call, the same shape jit_layers_notice()'s caller already uses for a bash-built list.
JIT_MISSING_REQUIRES="$(jit_missing_requires "$JIT_BASE/tools" "$JIT_TOOL_LAYERS")"

# `awk` reads stdin itself; the `cat` in front of it was one fork per invocation, on the
# hottest path this plugin has, buying nothing.
LC_ALL=C awk \
  -v tool_layers="$JIT_TOOL_LAYERS" \
  -v vocab_layers="$JIT_VOCAB_LAYERS" \
  -v tools_base="$JIT_BASE/tools" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v state_dir="$JIT_STATE_DIR" \
  -v inject_default="$JIT_INJECT" \
  -v home="$HOME" \
  -v project="${CLAUDE_PROJECT_DIR:-.}" \
  -v log_tmp="$JIT_TMP" \
  -v missing_bins="$JIT_MISSING_REQUIRES" \
  "$JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_JSON$JIT_AWK_FOLD$JIT_AWK_BLK_BUILD$JIT_AWK_ENVELOPE"'
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
# gsub(home "/", ...) and gsub(project "/", ...) below build their pattern by string
# CONCATENATION, and gsub takes that result as an ERE -- awk does not know the caller
# meant a literal prefix. home/project are -v values from the environment, not
# constants this repository controls: $HOME is normally metacharacter-free, but
# CLAUDE_PROJECT_DIR is a Claude-Code-specific variable, unset under every other host,
# and its fallback here is the single byte ".". As a regex, "." matches ANY character,
# so gsub("." "/", "", tt) deletes one arbitrary byte plus the "/" that follows it --
# at EVERY slash in tt, not just a leading project prefix (issue #361). That is a
# vocabulary-matching bug, not just a log one: tt feeds both the padded/stale lookup
# below and the log tail written at the bottom of this hook, so a path token loses a
# byte at every "/" and a real keyword can silently stop matching (reproduced: src/
# pipeline/config.yml becomes srpipelinconfig.yml, and "pipeline" no longer matches).
#
# Fixed by escaping regex metacharacters in the literal string before it reaches gsub,
# character by character rather than gsub-on-gsub, so escaping this awk functions own
# output is never itself a place a metacharacter could leak back in.
function jit_re_lit(s,    i, c, out, special) {
  special = "\\.^$*+?()[]{}|"
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    out = out (index(special, c) > 0 ? "\\" c : c)
  }
  return out
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
    # #182. An Agent dispatch carries description, prompt and subagent_type and none of
    # the four above, so `cmd` came out empty and this hook printed {} and exited 59
    # lines before the layer loop. A `tool: Agent` rule -- including a `mode: block` one
    # -- was written, validated, indexed, counted by every diagnostic, and inert.
    #
    # subagent_type ONLY, and the other two are a deliberate no. `prompt` and
    # `description` are author-written prose, and two things go wrong with prose as a
    # subject. It is matched by `forbid`/`require`/substring rules that were written
    # about COMMANDS, so a prompt saying "do not run git push here" trips a deny-list
    # rule about `git push`. And `cmd` is cut at the first ; & | or double quote (see
    # the strip below), so a prose subject is compared as an arbitrary prefix of itself
    # -- the #7 false-block shape, rebuilt.
    #
    # The cost is real too, though it is the weaker half of the argument. Measured on a
    # two-rule tools index, 40 calls per point, interleaved, one-true-awk 20200816 on
    # darwin 24.3.0, read out of the hook OWN timing in hooks.log rather than wall clock
    # around the process: a 7-byte subject 91 ms median, a 4.4 KB one 97 ms, a 44 KB one
    # 207 ms. A prompt is routinely in the second band and can reach the third.
    # subagent_type is a bounded identifier and is always in the first.
    else if (k == "subagent_type") f_subagent = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
  }

  # Fallback chain for tool matching
  full_command = command
  if (full_command == "") full_command = f_skill
  if (full_command == "") full_command = f_file_path
  if (full_command == "") full_command = f_pattern
  if (full_command == "") full_command = f_subagent

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

  # No tool name at all is a payload this hook has nothing to say about, and there is
  # no rule it could be measured against. Unchanged, and still the only silent exit.
  if (tool_name == "") { print "{}"; exit }

  # THE THIRD STATE, #182. `cmd == ""` used to leave here the same way, and that is the
  # whole defect: "no rule matched" and "no rule could be reached" printed the same {}.
  #
  # The subject is built from a fixed set of tool_input KEYS and `tool:` accepts any tool
  # NAME, and nothing joined those two facts. `tool: Agent` was the measured case;
  # `tool: TodoWrite`, `tool: WebFetch`, `tool: ExitPlanMode` and every `tool: mcp__*`
  # rule are the same shape. The set is open -- an MCP server defines its own input
  # schema -- so it is not enumerable here, in rebuild-tsv.sh, or in any list that could
  # be committed. See jit_no_subject_notice() in common.sh for why an index-time refusal
  # was rejected.
  #
  # So the scan below RUNS, on evidence rather than on a list: a real dispatch arrived,
  # nothing in it could be made into a subject, and if any rule in the tree names this
  # tool the author is told. `no_subject` turns the row loop into a census -- no pattern
  # is compiled, no entry body is read, no call is ever blocked on this path -- and if
  # no rule names the tool the output is {} exactly as before, which is the case for
  # every TodoWrite in a tree whose rules are about Bash.
  #
  # `full_command`, NOT `cmd`, and the difference is the whole accuracy of the notice.
  # `cmd` is the command WORDS -- `full_command` cut at the first ; & | or double quote
  # -- so it is empty for two completely different reasons: no tool_input key yielded
  # anything at all, or a key yielded something the cut then took. The notice makes a
  # factual claim about which one it is, and gating it on `cmd` made it fire on
  # `{"command":"\""}` and on `{"command":"; cat x"}`, telling the author that every
  # Bash rule in their tree was unreachable on a call that carried a command the whole
  # time. Reproduced against the first cut of this fix; tests/test-agent-subject.sh
  # section H drives both shapes.
  #
  # A subject that was built and then cut to nothing is #186, and it USED to leave here
  # too -- `if (cmd == "" && !no_subject) { print "{}"; exit }`. That line is gone, and
  # what it was is worth stating because it did not look like a behaviour change:
  #
  # it was a SHORT-CIRCUIT ON THE WRONG VARIABLE. `cmd` is the command WORDS, and it is
  # the subject of exactly ONE consumer below -- the substring arm of the tool matcher.
  # Three others read something else and were skipped by a test about a variable that is
  # none of their business:
  #
  #   - the REGEX arm matches `fold_full`, deliberately (see the comment above it): a
  #     rule is tested against the whole command so that `cd x && git push` is reachable
  #     at all. `full_command` is non-empty on every call this exit caught, so those
  #     rules would have matched and never ran -- and this dimension is the only one that
  #     can REFUSE a call, so a `mode: block` regex rule failed OPEN on any command whose
  #     first byte is `;`, `&`, `|` or `"`. Read as enforced, never run, which is the one
  #     failure this repository is named after.
  #   - the VOCABULARY pass lifts path tokens out of `command`, never `cmd`, so
  #     `; cat src/Billing/x.php` said nothing while `true; cat src/Billing/x.php` bound
  #     Billing the whole time.
  #   - the per-row refusal notices need no subject at all.
  #
  # The substring arm needs no exit of its own: `index("", term)` is 0 for a non-empty
  # term, and rebuild-tsv.sh refuses a row with an empty `match:` (it is one of the three
  # `jit_unindexed` reasons), so there is no row whose term could be "". A substring rule
  # therefore still does not see past the cut -- `git push` does not fire on
  # `; git push`, exactly as it does not fire on `true; git push`. THE CUT ITSELF IS NOT
  # THE BUG and is deliberately unchanged: it is what stops a substring rule about
  # `git push` firing on `echo "git push"`, which is issue #7, and narrowing it to keep
  # the first command word would fix this case by reopening that one.
  #
  # This state does NOT get a notice of its own, and that is a decision rather than an
  # omission. After this change no row is unreached: every row is read, the regex ones
  # are evaluated and can fire, and a substring row that does not match is an ORDINARY
  # non-match -- the same one `true; git push` has always produced silently. A notice
  # here would fire on that entire class and would say "unreachable" about rules that
  # are working as #7 intends.
  #
  # What is left below is the #182 census gate, unchanged and still on the whole subject.
  no_subject = (full_command == "")

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
  # keep folding without the pin (`jit_fold_latin1()` in common.sh) -- the fold is bytes
  # in, bytes out, and the two locales cannot disagree about it. Only tolower() was ever
  # locale-sensitive.
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

  nblk = 0
  blocked = ""
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0
  # #182: the rows that name this tool and could not be reached, and their count. Kept
  # apart from `refused` because they are a different verdict about a different thing --
  # `refused` is a row the matcher read and could not honour, this is a row the matcher
  # could honour and had nothing to measure it against. Merging them would put one
  # sentence on two states, which is the defect this hook exists to avoid.
  unreached = ""
  n_unreached = 0

  # --- Load shown file into set ---
  jit_shown_load(shown_file, shown)

  # --- Tool rules matching ---
  # THE LAYER LOOP #176 ADDED. This dimension had none: tools_tsv and tools_dir arrived
  # pinned to tools/00-manual and nothing else in the tree was ever opened, so a rule in
  # `01-oss` or in any of the three generated layer names docs/layers.md documents was indexed
  # by the rebuild and read by no matcher. The list is enumerated from disk by
  # jit_scan_layers() in common.sh; the bound comes off the same split() rather than being
  # a second literal beside it.
  #
  # Everything the scan accumulates -- matched, blocked, log_matches, refused, held --
  # lives OUTSIDE this loop and is not reset per layer. Only `rown` is, because it is a
  # position within one index and jit_row_id() names the layer beside it.
  #
  # The body is indented one level for this loop and is otherwise unchanged; `git diff -w`
  # is the reviewable form.
  n_tool_layers = split(tool_layers, tlayers, " ")
  for (tli = 1; tli <= n_tool_layers; tli++) {
    tool_layer = tlayers[tli]
    # Every report inside the loop names the layer it read, where it used to name the one
    # layer that could be read.
    tool_label = "tools/" tool_layer
    tools_tsv = tools_base "/" tool_layer "/00-index.tsv"
    tools_dir = tools_base "/" tool_layer
    rown = 0
    while ((getline tline < tools_tsv) > 0) {
      rown++

      split(tline, tf, "\t")
      r_tool = tf[1]; r_match = tf[2]; r_file = tf[3]
      r_modes = tf[4]; r_require = tf[5]; r_forbid = tf[6]; r_requires = tf[7]

      # Containment first: r_file is concatenated onto tools_dir below, and a row of
      # ../../../x made this hook read that file and inject it. jit_bad_entry_file lives in
      # common.sh with the reproduction.
      # The mode is DERIVED, never echoed: like the file name, column 4 is attacker text.
      # "this was a block rule and it did not run" is worth saying; the raw column is not.
      r_kind = (index(r_modes, "block") > 0) ? " (a block rule)" : ""

      # Can this row refuse a call at all? Read off the INDEX columns and nothing else, so
      # it is settled before the entry file is named, let alone opened. Three later decisions
      # turn on it: whether `once` may suppress the row (#139), whether an unreadable file
      # name still costs the call (#140), and whether the body is worth reading at all.
      #
      # would_refuse is that same test with NOTHING taken off it yet -- what this row asks
      # for before #203 is asked whether it can actually have it. missing_bins is built in
      # BASH, once, before this awk process starts (see jit_missing_requires() in common.sh
      # for why): a space-padded list of every requires: value this tools tree names that
      # did not resolve on PATH at fire time. requires_missing is a property of the ROW,
      # not of the call -- it does not depend on r_match, so it is settled here beside
      # would_refuse rather than re-derived at each of the three refusal sites below.
      #
      # A rule with no requires: column reads "" here, index(missing_bins, " " "" " ") is
      # always > 0 on a non-empty missing_bins (the empty string is a substring of
      # anything), so the r_requires != "" guard is load-bearing and not decoration: an
      # ORDINARY block rule -- nothing already written asks for a requires: column at all
      # -- must keep blocking whether or not this tree happens to carry OTHER rows naming
      # an absent binary. #203s own scope note -- "not a request to stop blocking where
      # supertool IS installed" -- generalised to every rule that never asked to be
      # conditional in the first place.
      requires_missing = (r_requires != "" && index(missing_bins, " " r_requires " ") > 0)
      would_refuse = (index(r_modes, "block") > 0 || r_require != "" || r_forbid != "")
      can_refuse = would_refuse && !requires_missing

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
        refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " why)
        log_matches = log_matches sep "refused:" jit_row_id(tool_label, rown) "(" why ")"
        sep = ", "
        continue
      }

      file_why = jit_bad_entry_file(r_file, tools_dir)
      if (file_why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " file_why)
        log_matches = log_matches sep "refused:" jit_log_name(r_file, tool_label, rown, file_why) "(" file_why ")"
        sep = ", "
        # NOT an unconditional `continue` any more (#140). This branch fires when the file
        # column cannot be turned into a path -- a separator in it, a leading dot, an entry
        # or a layer that is a symbolic link. The column it distrusts is the one that names
        # the BODY, and #77 already settled what that costs: mode, require and forbid come
        # off the row, so a body nobody can deliver leaves the decision intact. A row saying
        # `block` was becoming advisory because its file name was malformed, and the call
        # went through with a notice in place of a refusal.
        #
        # The other two refusal sites in this loop are deliberately NOT like this, and the
        # difference is which column went dark. jit_bad_bytes() above distrusts the whole
        # row, decision inputs included; jit_bad_pattern() below distrusts the match column,
        # so whether the rule even applies is unknown. Here every decision input is intact
        # and only the pointer to the text is not.
        #
        # This grants no new reach to a hostile index: a row that wanted to refuse a call
        # could always do it by naming a legitimate file. The containment guard exists to
        # stop the hook READING outside its layer, and nothing below reads this file.
        #
        # An advisory row still leaves here, so a bad name costs it the notice and nothing
        # more -- unchanged, and the half a widening would have got wrong.
        if (!can_refuse) continue
      }

      # What the log line and the block header may call this row now that it can reach them.
      # jit_log_name() is the rule the refusal notice already applies: a name that failed the
      # bare-name check is 250 bytes of attacker text and is replaced by the position, while
      # a name that passed is what an author fixing a symlinked entry actually needs. The
      # header is MODEL-facing, so it takes the position for every refusal reason, not just
      # that one -- the same posture as the notice above (#35).
      r_logname = (file_why != "") ? jit_log_name(r_file, tool_label, rown, file_why) : r_file
      r_header_name = (file_why != "") ? jit_row_id(tool_label, rown) : r_file

      # tool may name several tools, pipe-separated: `tool: Edit|Write|Read`.
      # Exact-match each alternative — never substring, or `Read` would match `ReadFile`.
      tool_hit = 0
      nt = split(r_tool, talts, "|")
      for (ti = 1; ti <= nt; ti++) if (talts[ti] == tool_name) tool_hit = 1
      if (!tool_hit) continue

      # #182: this row names the tool, and the dispatch gave us nothing to match it
      # against. Count it and move on. Deliberately AFTER the tool test, so a tree full
      # of Bash rules pays one split() per row on a TodoWrite and reports nothing --
      # and deliberately after the two refusal checks above, because "this row has bad
      # bytes" is a truer thing to say about it than "it was unreachable".
      #
      # `continue`, always: nothing below this point may run on this path. The pattern
      # is never compiled (an unreachable rule must not also report a bad ERE, which
      # would be a second verdict about a row nobody could have run), no `once` marker
      # is spent, no entry body is read, and no decision is reached -- so `blocked`
      # stays empty and the census can never refuse a call.
      if (no_subject) {
        n_unreached++
        unreached = jit_unreached_add(unreached, jit_row_id(tool_label, rown) r_kind)
        log_matches = log_matches sep "nosubject:" jit_row_id(tool_label, rown)
        sep = ", "
        continue
      }

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
          refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " why)
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
      hushed = 0
      if (index(r_modes, "once") > 0) {
        key = "rule:" r_file
        # `held` as well as `shown`: an advisory rule delivered earlier in THIS scan is not in
        # `shown` yet -- its mark waits on the block decision below (#112) -- and without this
        # a second row naming the same file would inject it twice in one call.
        if ((key in shown) || (key in held)) {
          # `hushed`, not `continue`, for a row that can refuse (#139). `once` was leaving
          # this loop before the row reached its decision, so `mode: once, block` refused
          # the first matching call of a session and permitted every one after it -- no
          # notice, and a log line indistinguishable from a rule that had nothing to say.
          #
          # An injection is knowledge the agent now has, so repeating it is waste and that
          # is what `once` is for. A refusal is not knowledge, it is a decision, and a
          # decision that expires was never enforced. So `once` keeps its exact meaning for
          # the advisory half -- the body is injected at most once per session -- and buys
          # no silence at all on the refusal half.
          #
          # This is the same reasoning the #135 substitute path already applied one branch
          # down, where it empties `key` so a refusal carrying none of its text cannot spend
          # the budget. That closed the case where the body was missing; this closes the
          # case where the body was fine and the budget was already gone.
          #
          # The cost is one entry read per call for a `once` row that can refuse, which is
          # a read it was already paying on the call that refused.
          if (!can_refuse) continue
          hushed = 1
        }
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
      # block. jit_entry_why() now refuses both shapes before the read, off a set the bash
      # half sweeps, so what this paragraph claims is what the code does on every engine.
      # It is the funnel BOTH entry readers call -- jit_read_body() and jit_entry_load() --
      # which is why the summary-mode reader below is safe where a plain getline was not.
      #
      # jit_entry_load/jit_inject_text live in common.sh: what a match contributes is the
      # title and the author-written description by default, and the whole body only when
      # the project or the entry asks for it.
      #
      # A rule that can REFUSE the call reads its body whatever the mode says, and the
      # three refusal messages below use that body and never the summary. The call has
      # already been stopped, so there is no cheaper outcome left to buy -- and the pull
      # step summary mode relies on is a SOFT rule an agent under momentum skips. A block
      # reason that says "read the file to find out why" is an absence produced by the
      # tool, which is the one failure this repository exists to name. The cost trade that
      # justifies a summary needs a next turn to spend it in; a refusal has none.
      #
      # keepbody is read off the INDEX columns, before the file is opened, so a rule that
      # cannot block never pays for a body it will not use.
      keepbody = can_refuse
      content = ""
      body = ""
      why = ""
      if (file_why != "") {
        # The row survived the containment guard because it can refuse (#140), and this is
        # the only place that changes: the file is never named and never opened, so the
        # decision below is reached with the reason in place of the text.
        #
        # `content` stays EMPTY, unlike the two substitute paths below. Those stand in for a
        # file the hook did try to read; this file column is not a file name at all, the
        # notice above has already reported the row by position, and filling `content` would
        # inject that same sentence a second time as advisory context.
        body = "(the text of this rule was not delivered: " file_why ")"
        key = ""
      } else {
        rpath = tools_dir "/" r_file
        if (jit_entry_load(rpath, inject_default, keepbody, ent)) {
          body = ent["body"]
          content = jit_inject_text(ent, ".claude/jit-context/" tool_label "/" r_file)
        }
        why = ent["why"]
      }
      if (why != "") {
        # BOTH, not one of the two. The substitute goes into content so that a `mode: block`
        # rule still reaches the block below -- content == "" is the no-op path, and #77 is
        # that an unhonourable rule must never become an allowed call -- and into body so
        # that the require and forbid refusals say the same thing rather than nothing.
        body = "(the text of this rule was not delivered: " why ")"
        content = body
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " why)
        log_matches = log_matches sep "refused:" jit_log_name(r_file, tool_label, rown, why) "(" why ")"
        sep = ", "
        # A substitute is not the rule text, so it consumes no once-per-session budget. That
        # was already true -- the branch below is what marked, and this one skipped it -- and
        # emptying `key` here is how it stays true now that the mark has moved down to the
        # three places the text is actually delivered.
        key = ""
      }

      # A rule that can REFUSE must reach its decision on the strength of its INDEX ROW, and
      # never on whether its file had text in it (#135). `why` above covers a file that could
      # not be read; this covers one that read fine and said nothing -- a file with no
      # frontmatter and no text, or one truncated after it was indexed. rebuild-tsv.sh cannot
      # have produced that pair itself, since a file with no frontmatter carries no tool: and
      # no match:, so the row is hand-written or the file drifted out from under a committed
      # index. Either way the index says `block` and the markdown has nothing to say.
      #
      # Without this the three refusals below read an empty `body`: the block branch was
      # guarded on `content != ""` and was never reached at all -- exit 0, {}, THE CALL
      # PERMITTED, indistinguishable from a rule that did not match -- while require and
      # forbid refused with a reason ending in a bare space.
      #
      # `body` only, deliberately NOT `content`. content == "" is what keeps an advisory rule
      # with nothing to say silent, and filling it here would start injecting this sentence
      # at authors whose entry never refuses anything -- a behaviour change nobody asked for.
      #
      # The same wording as the `why` substitute, because from the side that reads it this is
      # the same fact: the text of this rule did not arrive. And `key` is emptied for the
      # reason recorded above -- a substitute is not the rule text, so it may not spend a
      # once-per-session budget. That matters most here: a `once,block` row that marked
      # itself shown on a refusal carrying none of its text would be skipped on the next
      # call, and the second `git push` of the session would go through.
      # WHITESPACE, not just the empty string. A file of two blank lines reads back as "\n",
      # which is not "" and would slip a guard testing for that alone -- and the refusal then
      # carries a reason that renders as nothing at all, which is this defect one shape over
      # and the shape a half-written or truncated entry actually leaves behind. `[[:space:]]`
      # rather than `\s`: this is an awk ERE, and one-true-awk drops the class spelling.
      if (keepbody && body ~ /^[[:space:]]*$/) {
        body = "(the text of this rule was not delivered: the entry file has no text)"
        key = ""
      }

      # A row that WOULD refuse but may not, because the binary its requires: column
      # names is not on PATH, says so out loud (#203) -- "a check that cannot be
      # satisfied must say so and degrade" is the sentence #203 itself settles on, and a
      # degrade nobody is told about is this repositorys own defect class with the sign
      # flipped: a rule that reads as enforced in the tree and is not, on this machine.
      #
      # would_refuse, not can_refuse: can_refuse is already false on this path -- it is
      # would_refuse && !requires_missing, computed where r_modes was first read -- so
      # testing it here would never fire. requires_missing alone is not enough either: a
      # `remind` row may carry requires: for reasons of its own that have nothing to do
      # with refusing, and #203 is about a check that stops ENFORCING, not about naming a
      # dependency on an ordinary advisory row that was never going to block anything.
      if (requires_missing && would_refuse) {
        degrade_note = "[jit] This rule would normally refuse this call, but `" r_requires "` was not found on PATH, so it has degraded to advisory instead of blocking. Install `" r_requires "` to restore enforcement."
        content = (content == "") ? degrade_note : degrade_note "\n" content
      }

      # Check require. Gated on !requires_missing (#203): a require: refusal whose whole
      # point is a binary that is not on PATH is a remedy the reader cannot perform, and
      # this row degraded to advisory back where can_refuse was computed -- this branch
      # must agree with that, or a `mode: remind, require: --safe, requires: absentbin`
      # row would still refuse here despite can_refuse already having said it may not.
      if (r_require != "" && !requires_missing) {
        nr = split(r_require, reqs, "|")
        for (ri = 1; ri <= nr; ri++) {
          # Folded on both sides (#76): `require: validé` must be satisfied by `VALIDÉ`.
          # This half fails CLOSED when it breaks -- it refuses a command that met its
          # requirement -- which is the safer direction and still wrong.
          if (index(fold_full, jit_fold_latin1(tolower(reqs[ri]))) == 0) {
            blocked = "BLOCKED: Missing required: " reqs[ri] ". " body
            log_matches = log_matches sep "tool:" r_logname "(BLOCKED:" reqs[ri] ")"
            sep = ", "
            # NOTHING is marked here (#139). This branch used to mark, on the reasoning that
            # the body had been delivered as the refusal reason -- true, and the wrong unit to
            # count. `once` bounds how often an entry is INJECTED as context; spending that
            # budget on a refusal is what made the next matching call skip the row entirely
            # and go through. A refusal is a decision, not knowledge the agent now carries.
            break
          }
        }
        if (blocked != "") break
      }

      # Check forbid. Gated on !requires_missing, same reasoning as require above (#203).
      if (r_forbid != "" && blocked == "" && !requires_missing) {
        nfb = split(r_forbid, forbs, "|")
        for (fi = 1; fi <= nfb; fi++) {
          # Folded on both sides (#76). This is the half that failed OPEN: `forbid:
          # clé-privée` stopped seeing `CLÉ-PRIVÉE` and the deny-list rule allowed the call.
          if (index(fold_full, jit_fold_latin1(tolower(forbs[fi]))) > 0) {
            blocked = "BLOCKED: Forbidden: " forbs[fi] ". " body
            log_matches = log_matches sep "tool:" r_logname "(BLOCKED:" forbs[fi] ")"
            sep = ", "
            # Marks nothing, same as the require refusal above (#139).
            break
          }
        }
        if (blocked != "") break
      }

      header = "# JIT Context: " r_header_name " (matched: " r_match ")"

      # OUTSIDE the content guard below, and that is the whole of #135. `mode: block` comes
      # off the index row, so whether this rule refuses is settled before the file is opened;
      # `content` is about what there is to SAY. Sitting inside that guard turned an entry
      # with no deliverable text into an allowed call -- the one direction this dimension may
      # never fail in, and it read exactly like a rule that did not match. require and forbid
      # were already outside it, for the same reason.
      #
      # `body` can no longer be blank here: it is the entry text, the substitute for a body
      # that could not be read, or the substitute for a file with nothing but whitespace in it.
      #
      # Gated on !requires_missing (#203), same as require and forbid above: a `mode:
      # block` row naming a `requires:` binary that is not on PATH cannot enforce its own
      # remedy, so it falls through to the advisory branch below, which is where the
      # degrade is actually said out loud -- see degrade_note.
      if (index(r_modes, "block") > 0 && !requires_missing && blocked == "") {
        log_matches = log_matches sep "tool:" r_logname "(" r_match ")[full:block]"
        sep = ", "
        # Marks nothing (#139). This was the line that disarmed `mode: once, block`: the
        # first matching call of a session refused and marked, and every call after it left
        # the loop at the `once` check before reaching this branch at all.
        # body, not content: a block is a refusal, and a refusal is never a summary.
        blocked = header "\n" body
        break
      }

      # `hushed` is where a `once` budget that has already been spent lands now (#139): the
      # row still reached its decision above, and this is the half -- and the only half --
      # that the budget was ever about.
      if (content != "" && blocked == "" && !hushed) {
        # ADVISORY, and therefore provisional. A row further down this index may still block,
        # and the block path below throws `matched` away -- so neither the once-marker nor the
        # log token may be written yet. Both are held and committed after the loop, when the
        # decision is known (#112).
        log_adv = log_adv asep "tool:" r_logname "(" r_match ")" jit_inject_tag(ent)
        asep = ", "
        if (key != "") { held[key] = 1; hold_n++ }

        # The SECOND header, and the reason there are two (#146). `header` above is the
        # refusal header and is deliberately unbounded: #141 asked for a bound there and was
        # refused, because the block reason carries the whole entry body anyway, so bounding
        # the header alone is a defence walked around by moving one line down the same entry.
        # Nothing about that has changed and the block branch above still uses `header`.
        #
        # On THIS path the same reasoning does not hold, and that asymmetry was the defect.
        # Under `summary` the body is on a budget -- 160 bytes of title and 400 of
        # description, spent in jit_inject_text() -- and the header sat outside it, quoting
        # two index columns whole. Driven: a 60,000-byte regex `match:` column on a summary
        # entry produced 60,223 bytes of ordinary advisory context, and a 60,000-byte
        # entry-file column produced 60,539 with no entry file involved at all. `summary`
        # exists so a match costs about twenty tokens instead of the whole entry (#1), and a
        # single frontmatter-free index column reopened exactly the cost it was added to
        # close -- silently, on an ordinary non-refusing match.
        #
        # So the bound is placed on the BODY BUDGET rather than on `header` itself, and the
        # test is "was the entry text actually delivered here", which is three conditions and
        # not one. A `full` entry that delivered its body made no promise about what a match
        # costs and its body is unbounded at the authors own request, so a bound on its
        # header is #141s walk-around one more time. Every other case has a bounded body
        # sitting under this header, and `why != ""` is the second of them: a row whose entry
        # file could not be read delivers no body at all, only the two-line substitute built
        # above, IN EVERY MODE. Gating on the mode alone left that shape unbounded under the
        # project default -- which is `full`, and is what every project that configured
        # nothing is on. Driven after the mode-only fix and before this one: 60,539 bytes for
        # the file column and 60,547 for the pattern, with no config.env present.
        #
        # The THIRD condition is the case the sentence above once claimed could not exist
        # (#165). A file with no frontmatter is pinned to `full` whatever the project sets,
        # so an entry containing nothing but blank lines arrived here with mode `full`, no
        # `why`, and a body of a single newline -- and took the exemption with nothing under
        # the header to justify it. Driven at cdff15a on one-true-awk with no config.env:
        # 60,125 bytes of additionalContext for a 60,000-byte `match:` column on such a row.
        #
        # That was never a hole in the cap and this condition is not what closes one. Control
        # drive, same tree: a short `match:` and the same 60,000 bytes IN the entry file cost
        # 60,124, because the same pin delivers them. Both channels need write access to the
        # tree and both cost the same, so #146s budget gave up nothing either way. What was
        # wrong is that the exemption is EARNED by delivering a body and this branch granted
        # it on the mode alone -- the `why` error one paragraph up, one shape further in, and
        # a premise the next person to touch this gate would have reasoned from.
        #
        # `[[:space:]]`, not `== ""`. `content` is already non-empty by the guard this block
        # sits inside, and a file of two blank lines reads back as one newline -- which is the
        # distinction #135 drew for the refusal substitute seventy lines up, and the shape a
        # truncated or half-written entry actually leaves behind.
        #
        # And `content`, which under `full` is the WHOLE FILE -- frontmatter included, since
        # nothing strips it in that mode. So an entry whose frontmatter is all it has still
        # takes the exemption, and that is correct rather than a second hole: its author can
        # put 60,000 bytes one line below the closing `---` and have them delivered. Driven:
        # 60,164 bytes through that header against 60,166 through that body, on one tree.
        # The test here is not "is this entry worth much", it is "is there a body channel
        # open beside the header" -- and for every file this branch reaches, there is.
        #
        # BOTH columns, not just the pattern. They are different kinds of text -- one is
        # written by the rule author, the other names a file -- and the second one is exactly
        # how that substitute path is reached, so clipping the pattern alone moves the 60 KB
        # one column over.
        #
        # The two caps differ for that same reason. 160 is the title cap, because in this
        # header the pattern does the title job -- name the rule well enough to find it. 255
        # is NAME_MAX on every platform this runs on, so it never bites a column that names
        # a file which could exist, and always bounds one that cannot. jit_clip() marks the
        # cut in what is injected rather than truncating quietly, so the reader can tell a
        # clipped pattern from a short one.
        #
        # ent[] is safe to read here: the only branch that leaves it stale is file_why != "",
        # which keeps `content` empty and therefore never reaches this line.
        #
        # `body`, not `content` (#170). jit_inject_text() no longer returns a whitespace-
        # only full body as-is -- it substitutes a report line, "the entry file has no
        # text to inject", so that an advisory rule with nothing to say no longer prints a
        # bare header with nothing under it. That substitute is NOT whitespace, so testing
        # `content` here would now read a report-only row as a row whose body was
        # genuinely delivered and hand it the unbounded header #165 built this exemption
        # to withhold. `body` is the raw entry text this row actually holds, read two
        # branches up, and is exactly what #165s comment already reasons about.
        if (ent["mode"] == "full" && why == "" && body !~ /^[[:space:]]*$/) adv_header = header
        else adv_header = "# JIT Context: " jit_clip(r_header_name, 255) " (matched: " jit_clip(r_match, 160) ")"

        # nblk/blk[] (common.sh, JIT_AWK_BLK_BUILD, #230) replace the old
        # matched = matched "\n---\n" X string-concat: this is still speculative, exactly
        # as the concat was -- a `break` above discards the whole scan on a block decision,
        # and nblk/blk[] are discarded right along with it, never read past that point.
        nblk++; blk[nblk] = adv_header "\n" content
      }
    }
    close(tools_tsv)
    # A block ends the WHOLE scan, not just this layer index. The `break`s inside the row
    # loop end one index; without this the next layer would be scanned after a decision
    # was already made, and the entries it matched would be held and then discarded --
    # which is the burn #112 named, one loop out.
    if (blocked != "") break
  }

  # The decision is known now. Either the advisory rules were delivered -- commit their
  # marks and their log tokens -- or a later row blocked and they were not, in which case
  # they are named as withheld and nothing about them is marked. A mark records an
  # injection that happened (#78); this is that rule applied to the one branch that
  # discards its own output.
  if (hold_n > 0 && blocked == "") {
    for (hk in held) { shown[hk] = 1; jit_shown_mark(shown_file, hk) }
  }
  if (log_adv != "") {
    if (blocked == "") { log_matches = log_matches sep log_adv; sep = ", " }
    else { withheld_log = log_adv; wsep = ", " }
  }

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
  gsub(jit_re_lit(home) "/", "", tt)
  gsub(jit_re_lit(project) "/", "", tt)

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

  # `!no_subject` is dead by construction and is here so that it stays dead (#182).
  # `no_subject` means NO tool_input key yielded anything, so `command` and `f_file_path`
  # are both empty, so `tt` is empty and this pass is skipped anyway -- one comparison to
  # make that an invariant rather than a coincidence.
  #
  # A Bash command cut to nothing that still names a path -- `; cat src/Billing/x.php` --
  # DOES reach here now (#186), and it is not the shape this guard is about. `tt` comes
  # from `command`, the whole command, and never from `cmd`, so this pass never cared
  # about the cut; it was the early exit above that skipped it, and that exit is gone.
  # `true; cat src/Billing/x.php` has always bound Billing here, and the leading-operator
  # spelling now does the same thing rather than a different one.
  if (tt != "" && !no_subject) {
    # Enumerated, and its OWN list rather than the tools one: the two dimensions can hold
    # different layer directories (#176). The bound comes off the same split().
    n_vocab_layers = split(vocab_layers, layers, " ")
    for (li = 1; li <= n_vocab_layers; li++) {
      layer = layers[li]
      lookup = vocab_base "/" layer "/00-index.tsv"

      # Single pass: match keywords, collect files + matched keywords
      delete vmatch
      # The row a matched file was FIRST seen at, so a body this pass cannot deliver is
      # named by position -- the loop below walks files, not rows.
      delete vmrow
      # #232: same tracking as pre-prompt-hook.sh -- see the comment there.
      delete vspecific
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
        kw = vf[1]; vfile = vf[2]; kwverdict = vf[3]
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
          # #232: same tracking as pre-prompt-hook.sh -- see the comment there.
          if (kwverdict != "generic") vspecific[vfile] = 1
        }
      }
      close(lookup)

      for (vfile in vmatch) {
        # #232: same downgrade as pre-prompt-hook.sh -- see the comment there.
        generic_only = !(vfile in vspecific)
        # Read first, mark only what was delivered -- see the same loop in
        # pre-prompt-hook.sh for why the old order marked entries nothing had injected.
        vc = ""
        vpath = vocab_base "/" layer "/" vfile
        if (jit_entry_load(vpath, inject_default, 0, vent)) {
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
          # The pass RUNS on the block path -- the loads above are what turn a vocabulary row
          # that cannot be evaluated into a refusal notice, and beside a persistently blocked
          # command that notice has no other call to arrive on (#103). What it must not do is
          # DELIVER: `matched` is discarded below, so an entry marked here would be spent for
          # the whole session, in this dimension and in pre-prompt-hook.sh, having reached
          # nobody. It stays unmarked and is named as withheld in the log instead (#112).
          if (blocked != "") {
            # Same token as a delivered one, tag included, so the two lists read alike and
            # `withheld[` is the only thing that distinguishes them.
            withheld_log = withheld_log wsep layer ":" vfile "(" vmatch[vfile] ")" jit_inject_tag(vent)
            wsep = ", "
            continue
          }
          if (!generic_only) {
            shown[vfile] = 1
            jit_shown_mark(shown_file, vfile)
          }
          # #233: same lookup and same "" fallback as pre-prompt-hook.sh -- see the
          # comment there.
          vage = (layer ~ /00-manual/) ? jit_entry_age(layer "/" vfile) : ""
          vh = "# Vocabulary: " vfile " (matched: " vmatch[vfile] (vage != "" ? " · last edited " vage "d ago" : "") ")"
          if (layer ~ /00-manual/) vh = vh "\\n[vocab-upkeep] Learned something new here, or found this entry wrong? Edit it now — hand-written entries live in 00-manual/."
          log_matches = log_matches sep layer ":" vfile "(" vmatch[vfile] ")" jit_inject_tag(vent) (generic_only ? ":generic-only" : "")
          sep = ", "
          nblk++; blk[nblk] = vh "\n" vc
        }
      }
    }
  }

  # --- A rule that could not be reached at all is reported, once per session (#182) ---
  # The sibling of the block below and of the layer notice under it, one state further
  # out: that one reports a rule the matcher read and could not honour, this one reports
  # a rule the matcher would have honoured and had nothing to measure against.
  #
  # ONCE PER SESSION, on a constant key, and the key is constant on purpose. `tool_name`
  # is payload text and putting it in a marker key would put payload text in a file this
  # hook reads back (#65). The cost is stated rather than hidden: a session whose tree
  # has unreachable rules for two different tools reports the first one it meets and
  # then goes quiet, so the author fixes one class, and the notice returns next session
  # for the next. That is the same trade every notice here already makes.
  #
  # The marker is consumed here and there is no block path to worry about: the census
  # `continue`s before any decision is reached, so `blocked` cannot be set on a call
  # that produced this list. The branch is written anyway, and is dead by construction
  # rather than by luck -- if a later edit ever lets a decision through, the notice
  # travels with the refusal instead of vanishing.
  if (n_unreached > 0 && !("jit-no-subject" in shown)) {
    shown["jit-no-subject"] = 1
    jit_shown_mark(shown_file, "jit-no-subject")
    unote = jit_no_subject_notice(unreached, n_unreached)
    if (blocked == "") jit_blk_prepend(unote)
    else block_tail = block_tail "\n---\n" unote
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
      jit_blk_prepend(note)
    } else {
      block_tail = block_tail "\n---\n" note
    }
  }

  # --- A layer directory that could not be read is reported, once per session ---
  # #176: the state that had no channel at all, and in THIS hook the one that matters most
  # -- an unread tools layer holding a `mode: block` rule fails open, and every other
  # signal (the rebuild count, the linter, doctor) reported the layer as healthy.
  #
  # Delivered on the block path too, and it consumes its marker there, for the reason the
  # config notice does: the list is built whole in the bash half before awk starts, so
  # nothing about it can arrive later. It is the RULE list that a `break` can cut short.
  layers_refused = ENVIRON["JIT_LAYERS_REFUSED"]
  layers_refused_n = ENVIRON["JIT_LAYERS_REFUSED_N"] + 0
  if (layers_refused_n > 0 && !("jit-refused-layers" in shown)) {
    shown["jit-refused-layers"] = 1
    jit_shown_mark(shown_file, "jit-refused-layers")
    lnote = jit_layers_notice(layers_refused, layers_refused_n)
    if (blocked == "") jit_blk_prepend(lnote)
    else block_tail = block_tail "\n---\n" lnote
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
    if (blocked == "") jit_blk_prepend(cnote)
    else block_tail = block_tail "\n---\n" cnote
  }
  # --- Write log info to temp file (bash reads it for timing) ---
  sc = 0; for (s in shown) sc++
  # jit_log_text() first, THEN the truncation: both of these are payload text after
  # jit_unescape(), so a JSON newline escape is a real newline by now and the log line
  # would end early with the rest read back as marker lines (#65). See common.sh.
  tt_short = substr(jit_log_text(tt), 1, 120)
  tool_log = jit_log_text(tool_name)
  # Named, and named as NOT delivered. This half is what let the defect survive two audits:
  # the blocked call logged `00-manual:billing.md(billing) [shown:1]`, which is exactly what
  # a correct delivery looks like, so the one surface that could have shown the burn agreed
  # with it. `withheld[...]` is only ever written on a call that discarded something, and
  # the entries inside it are the ones the next call still gets (#112).
  if (withheld_log != "") { log_matches = log_matches sep "withheld[" withheld_log "]"; sep = ", " }
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
    #
    # #112 re-argued that line and left it where it is. What was wrong was not the choice
    # of branch: it was that the discarded entries were MARKED on the way here, so an
    # advisory entry with another channel had it taken away -- for this dimension and for
    # pre-prompt-hook.sh, which reads the same marker file. "It has no other channel" is
    # the whole test for what belongs in block_tail, and it only holds if the things that
    # do have one still get to use it.
    blocked = jit_json_escape(blocked block_tail)
    printf "%s", jit_envelope_block(blocked)
  } else if ((matched = jit_blk_join()) != "") {
    # jit_blk_join() (common.sh, JIT_AWK_BLK_BUILD, #230) assembles the "# JIT-CTX-BLOCKS"
    # manifest from nblk/blk[] the same way pre-prompt-hook.sh always has -- this hook
    # never built one before, so a consumer walking additionalContext always fell back to
    # searching it for "\n---\n", a separator an entry body can forge.
    matched = jit_json_escape(matched)
    printf "%s", jit_envelope_inject("PreToolUse", matched)
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
