#!/bin/bash
# claude-jit-context — Path-based PreToolUse hook
# One awk program: parses JSON, matches file path against TSV patterns, outputs JSON.
# Supports Read/Edit/Write/Glob/Grep (file_path/path) AND Bash (command field).
# The program runs TWICE for a Bash command whose tokens name real files -- once to extract
# the tokens, once over the ones bash confirmed exist. See the candidate section below;
# every other payload still costs exactly one awk process.

case "$0" in */*) SCRIPT_DIR="${0%/*}" ;; *) SCRIPT_DIR="." ;; esac
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
# The project directory, and the sentinel that opens the candidate channel below. The
# directory is read from ENVIRON inside awk rather than passed with -v: a -v value has its
# escape sequences PROCESSED, so a checkout under a directory with a backslash in its name
# would arrive mangled, and a newline in one is a fatal awk error raised before the program
# runs. ENVIRON does neither. bash needs the same value, so it is normalised once here.
JIT_PROJECT="${CLAUDE_PROJECT_DIR:-.}"
while [ "${JIT_PROJECT%/}" != "$JIT_PROJECT" ] && [ "$JIT_PROJECT" != "/" ]; do
  JIT_PROJECT="${JIT_PROJECT%/}"
done
JIT_CAND_BEGIN='--jit-candidates--'

# ONE program, TWO possible passes. See the candidate section in END: the first pass parses
# the payload, and when a Bash command yields path candidates it writes them to the scratch
# channel and prints NOTHING, because whether they are real files is a question awk must not
# ask (a getline probe on a directory is a fatal i/o error on one-true-awk, which is the awk
# macOS ships). bash answers it with builtins and runs the program again over the survivors.
JIT_PATH_PROG=$JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_JSON$JIT_AWK_BLK_BUILD'
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
# --- Path candidates out of an arbitrary Bash command (#85) -------------------
# The path dimension used to see a Bash payload and collect NOTHING unless the command
# matched a supertool invocation. `vim scripts/pre-tool-hook.sh` reached no path rule;
# `Read` of the same file reached every one of them. The tool the agent happened to use
# decided whether the rule existed, and neither the session nor the log said so.
#
# So a token is a candidate now. What makes guessing safe is not this function -- it is
# the EXISTENCE test in the bash half: a token becomes a path only if it names a regular
# file inside the project. Everything here is the confinement that has to hold BEFORE
# anything is stat-ed, because a stat follows what it is given:
#
#   * `..` in ANY position is refused, including a traversal that resolves back inside.
#     There is no realpath here that costs nothing, so the verdict is lexical -- the same
#     trade jit_bad_entry_file() makes for a symbolic link one dimension over.
#   * An ABSOLUTE token must sit under the project directory, and is made relative to it.
#     One outside is dropped, not tested.
#   * A BACKSLASH drops the token. Here it is a shell escape; on Git Bash the Win32 API
#     underneath treats it as a separator, so a dot-dot spelled with backslashes traverses
#     there while reading as an ordinary character in every check above. jit_shown_apply()
#     draws the same line for the same reason.
#   * A NUL drops the token, because the channel that carries candidates back to bash is
#     line-based and `read -r` truncates at one (#78, one channel over).
#
# No verb is inspected and no intent is guessed. `grep foo scripts/common.sh` fires the
# rule about common.sh, and that is correct: the rule is about the file the agent is about
# to read. Over-firing is not the defect; silence is.
#
# The count is capped because the command length is chosen by the payload and each survivor
# costs bash a stat. 64 is far above any honest command line.
function jit_cand_sep(   q) {
  if (jit_sep_re == "") {
    q = sprintf("%c", 39)
    jit_sep_re = "[ \t\n\r;&|()<>\"`," q "=]+"
  }
  return jit_sep_re
}
function jit_cand_ctl(s) {
  if (jit_ctl_re == "") jit_ctl_re = "[" sprintf("%c", 1) "-" sprintf("%c", 31) sprintf("%c", 127) "]"
  return (s ~ jit_ctl_re)
}
function jit_cand_tokens(c, out,   nt, tk, i, t, project, plen, k) {
  jit_utf8_init()
  project = ENVIRON["CLAUDE_PROJECT_DIR"]
  if (project == "") project = "."
  sub(/\/+$/, "", project)
  if (project == "") project = "/"
  k = 0
  nt = split(c, tk, jit_cand_sep())
  for (i = 1; i <= nt; i++) {
    if (k >= 64) break
    t = tk[i]
    if (t == "") continue
    # An option is not a path. Its VALUE still is: `=` is a separator above, so
    # --file=src/x.php arrives here as two tokens and the second one survives.
    if (substr(t, 1, 1) == "-") continue
    if (index(t, "\\") > 0) continue
    # one-true-awk truncates the record at a NUL and never sees one; gawk carries it.
    if (length(jit_nul) == 1 && index(t, jit_nul) > 0) continue
    if (jit_cand_ctl(t)) continue
    if (substr(t, 1, 1) == "/") {
      plen = length(project)
      if (project == "/") t = substr(t, 2)
      else if (substr(t, 1, plen + 1) == project "/") t = substr(t, plen + 2)
      else continue
    } else if (t ~ /^[A-Za-z]:/) continue
    # `./scripts/x.sh` and `scripts/x.sh` are the same file, and a shell prints the first
    # form whenever a completion or a `find .` produced the token. A rule anchored with ^
    # matches only one of them, so the two forms are folded here rather than left to every
    # author to spell twice. Ordered before the .. checks below, so that `./../x` is
    # refused rather than normalised out of view. Loops because gsub does not rescan what
    # it just produced: `a/././b` needs two passes and `a///b` needs two as well.
    while (substr(t, 1, 2) == "./") t = substr(t, 3)
    while (t ~ /\/\.\//) sub(/\/\.\//, "/", t)
    while (t ~ /\/\//) sub(/\/\//, "/", t)
    sub(/\/\.$/, "", t)
    if (t == "" || substr(t, 1, 1) == "/") continue
    if (t == "." || t == "..") continue
    if (t ~ /(^|\/)\.\.(\/|$)/) continue
    k++
    out[k] = t
  }
  return k
}
# The survivors, handed back by the bash half through the environment for the second pass.
# The environment rather than -v for the reason JIT_SYMLINKS uses it: the list is
# newline-separated, and a newline in a -v value is fatal before the program runs.
function jit_cand_load(out,   nc, a, i, k) {
  k = 0
  nc = split(ENVIRON["JIT_PATH_CANDIDATES"], a, "\n")
  for (i = 1; i <= nc; i++) if (a[i] != "") { k++; out[k] = a[i] }
  return k
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
  # The SECOND pass (#85). Its stdin is empty, so everything parsed above came out blank;
  # the paths were extracted from a Bash command in the first pass and bash kept the ones
  # that name a regular file inside the project. The session key rides back with them so
  # that both passes address the same marker file rather than two.
  if (cand_mode == 1) {
    path_count = jit_cand_load(all_paths)
    shown_file = jit_shown_path(state_dir, "path", ENVIRON["JIT_SESSION_KEY"])
    vocab_shown_file = jit_shown_path(state_dir, "vocab", ENVIRON["JIT_SESSION_KEY"])
  } else if (file_path != "") {
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

  # --- A Bash command that named no supertool op: ask bash about its tokens (#85) ---
  # Nothing is printed on this branch. The hook has not decided anything yet: the tokens
  # go down the scratch channel, bash keeps the ones that name a regular file inside the
  # project, and either runs this program again over them or prints {} itself.
  #
  # WHY THE EXISTENCE TEST IS NOT HERE. It is a stat, and awk has none. The nearest thing
  # is `(getline x < t) >= 0`, and a token is very often a DIRECTORY -- `ls -la scripts/`.
  # Measured on awk version 20200816, the awk macOS ships: getline on a directory returns 0
  # and then raises `i/o error occurred on scripts/`, which exits 2 and prints into the
  # stranger session. Failing hard and being loud, from the line meant to add a feature.
  # gawk returns -1 there and is fine, so a local green run would have said nothing about
  # it. common.sh already records the same engine trap for close() on a directory.
  #
  # Without a scratch file there is no channel, and the branch degrades to what this hook
  # did before: no candidates, no injection, exit 0. That is the same degradation an
  # unwritable TMPDIR already costs the log and the dedup.
  if (cand_mode != 1 && path_count == 0 && cmd != "" && log_tmp != "") {
    n_cand = jit_cand_tokens(cmd, cands)
    if (n_cand > 0) {
      printf "%s\n%s\n", cand_begin, jit_session_key(raw, fs, fe, n) > log_tmp
      for (ci = 1; ci <= n_cand; ci++) printf "%s\n", cands[ci] > log_tmp
      close(log_tmp)
      exit
    }
  }

  if (path_count == 0) { print "{}"; exit }

  # --- Load shown set ---
  jit_shown_load(shown_file, shown)

  nblk = 0
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0

  # --- Scan path layers ---
  # Enumerated from disk by jit_scan_layers() in common.sh and handed in as a -v value
  # (#176). The bound comes off the same split() rather than being a second literal beside
  # it: the `li <= 4` this replaces was a separate copy of the same fact, and a fix that
  # changed only the string would have truncated the list silently.
  n_path_layers = split(path_layers, players, " ")
  for (li = 1; li <= n_path_layers; li++) {
    layer = players[li]
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

      # The entry is read BEFORE anything is marked shown. A row whose entry file will not
      # open used to be marked anyway -- nothing injected, nothing refused, and the key
      # recorded as delivered, which is how a NUL-truncated row went missing in silence on
      # one-true-awk (#78). A mark now records an injection that happened.
      #
      # jit_entry_load/jit_inject_text live in common.sh: the title and the
      # author-written description by default, the whole body only when the project or
      # the entry asks for it.
      content = ""
      rpath = paths_base "/" layer "/" rule_file
      if (jit_entry_load(rpath, inject_default, 0, ent)) {
        content = jit_inject_text(ent, ".claude/jit-context/paths/" layer "/" rule_file)
      } else if (ent["why"] != "") {
        why = ent["why"]
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id("paths/" layer, rown) ": " why)
        # The name PASSED the bare-name check above, so it is what an author fixing this
        # needs and jit_log_name() keeps it -- the log is read by a person, not a model.
        log_matches = log_matches sep "refused:" jit_log_name(rule_file, layer, rown, why) "(" why ")"
        sep = ", "
        continue
      }

      if (content != "") {
        shown[rule_file] = 1
        jit_shown_mark(shown_file, rule_file)
        header = "# JIT Context: " rule_file " (matched: " pattern ")"
        log_matches = log_matches sep layer ":" rule_file "(" pattern ")" jit_inject_tag(ent)
        sep = ", "
        nblk++; blk[nblk] = header "\n" content
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

    # Its OWN list, not the path one. Until #176 this loop reused the `layers` array the
    # path scan above built, which was only correct while both were the same constant --
    # enumerated, vocabulary/ and paths/ can legitimately hold different layer directories,
    # and sharing the array would have read this dimension for the other one names.
    n_vocab_layers = split(vocab_layers, vlayers, " ")
    for (li = 1; li <= n_vocab_layers; li++) {
      layer = vlayers[li]
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
        vcontent = ""
        vfpath = vocab_base "/" layer "/" vocab_file
        if (jit_entry_load(vfpath, inject_default, 0, vent)) {
          vcontent = jit_inject_text(vent, ".claude/jit-context/vocabulary/" layer "/" vocab_file)
        } else if (vent["why"] != "") {
          why = vent["why"]
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
          log_matches = log_matches sep "refused:" jit_log_name(vocab_file, layer, vrown, why) "(" why ")"
          sep = ", "
          continue
        }

        if (vcontent != "") {
          vshown[vocab_file] = 1
          jit_shown_mark(vocab_shown_file, vocab_file)
          vheader = "# Vocabulary: " vocab_file " (matched path: " vpattern ")"
          log_matches = log_matches sep layer ":" vocab_file "(" vpattern ")" jit_inject_tag(vent)
          sep = ", "
          nblk++; blk[nblk] = vheader "\n" vcontent
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
    jit_blk_prepend(note)
  }

  # --- A layer directory that could not be read is reported, once per session ---
  # #176: the state that had no channel at all. A layer nobody could load and a layer whose
  # rules never matched produced the same silence, and every other signal -- the rebuild
  # count, the linter, doctor -- reported the layer as healthy.
  layers_refused = ENVIRON["JIT_LAYERS_REFUSED"]
  layers_refused_n = ENVIRON["JIT_LAYERS_REFUSED_N"] + 0
  if (layers_refused_n > 0 && !("jit-refused-layers" in shown)) {
    shown["jit-refused-layers"] = 1
    jit_shown_mark(shown_file, "jit-refused-layers")
    lnote = jit_layers_notice(layers_refused, layers_refused_n)
    jit_blk_prepend(lnote)
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
    jit_blk_prepend(cnote)
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
  #
  # 200, not 80. The one admitted loss in the summary design (issue #1) is that the pull
  # step is soft: the agent is handed a description and decides whether to read the file.
  # Whether it does is measurable with no new machinery, because reading an entry IS a
  # tool call and this is the line that records it -- but at 80 characters an absolute
  # path to `.claude/jit-context/vocabulary/00-manual/<entry>.md` under any real project
  # directory was cut before the part that identifies it, and the measurement read as a
  # pull that never happened.
  fp_short = substr(jit_log_text(fp_short), 1, 200)
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
  # jit_blk_join() (common.sh, JIT_AWK_BLK_BUILD, #230) assembles the "# JIT-CTX-BLOCKS"
  # manifest from nblk/blk[] the same way pre-prompt-hook.sh always has -- this hook
  # never built one before, so a consumer walking additionalContext always fell back to
  # searching it for "\n---\n", a separator an entry body can forge.
  if ((matched = jit_blk_join()) != "") {
    matched = jit_json_escape(matched)
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"%s\"}}", matched
  } else {
    print "{}"
  }
}
'

# Enumerated, never a literal (#176). See jit_scan_layers() in common.sh.
#
# TWO SCANS, TWO LISTS, and that is the change rather than an accident of it: this hook
# used to build one `layers` array and walk it over BOTH paths_base and vocab_base, which
# was only correct while the list was a constant. Enumerated, the two dimensions can hold
# different layer directories -- a scaffold that ships vocabulary/01-oss and no
# paths/01-oss is the ordinary case -- and one array serving both would read each
# dimension for the other one directories.
#
# Scanned HERE and not inside jit_path_awk(), because that function may run twice in one
# invocation and the refusal list accumulates: scanning per call would count every refused
# layer twice and report a number that is not the number of layers.
#
# The vocabulary scan is gated exactly as its loop is. With DYNAMIC_RULES_VOCAB_PATHS off
# this hook never opens that dimension, and a notice about layers it was not going to read
# would be a report of a consequence that does not exist.
jit_scan_layers "$JIT_BASE/paths" paths
JIT_PATH_LAYERS="$JIT_LAYERS"
JIT_VOCAB_LAYERS=""
if [ "$VOCAB_PATHS" = "1" ]; then
  jit_scan_layers "$JIT_BASE/vocabulary" vocabulary
  JIT_VOCAB_LAYERS="$JIT_LAYERS"
fi

# One place the -v list lives, because this program may run twice. cand_mode is the only
# thing that differs: 0 parses the payload on stdin, 1 takes its paths from the environment.
jit_path_awk() {
  LC_ALL=C awk \
    -v path_layers="$JIT_PATH_LAYERS" \
    -v vocab_layers="$JIT_VOCAB_LAYERS" \
    -v paths_base="$JIT_BASE/paths" \
    -v vocab_base="$JIT_BASE/vocabulary" \
    -v vocab_paths="$VOCAB_PATHS" \
    -v state_dir="$JIT_STATE_DIR" \
    -v inject_default="$JIT_INJECT" \
    -v log_tmp="$JIT_TMP" \
    -v cand_mode="$1" \
    -v cand_begin="$JIT_CAND_BEGIN" \
    "$JIT_PATH_PROG"
}

# No `cat |` in front of it: jit_path_awk() is a wrapper around one awk, awk reads stdin
# itself, and the second call site below already invokes this function outside a pipeline.
jit_path_awk 0

# --- The question awk cannot ask: does this token name a file? (#85) ----------
# `[ -f ]` and `[ -L ]` are shell BUILTINS -- this forks nothing, and it is the same trade
# jit_scan_symlinks() makes at the top of common.sh: the tests awk has no syscall for are
# paid in bash, once, with no per-row subprocess.
#
# `-f` or `-d`, never `-e`. A directory is a path a rule can be about -- `grep -r x
# src/Billing/Components` is the case README calls "a test runner pointed at a directory"
# -- so it counts. What -e would ALSO admit is a fifo, a socket and a device node, and
# those are refused: nothing here opens a candidate, but the moment something did, opening
# a fifo for reading blocks until somebody writes, and a clone chooses what is in the tree.
#
# A SYMBOLIC LINK is refused at every component, leaf included, whether or not its target
# is inside the tree. That is the verdict common.sh already gives an entry file, and for
# the same reason: resolving instead would need a realpath this design cannot afford, and a
# structural answer is the same answer on every platform.
#
# What a bad candidate could actually do is worth stating, because it bounds this: the path
# is never opened and never read. It is matched against rule patterns and written to the
# log tail. So the cost of getting containment wrong is a rule firing for a file the
# project does not contain -- and #13 and #27 are why that is still refused rather than
# argued down.
# The accepted token comes back in JIT_CAND_VALUE rather than on stdout: `$( )` is a fork,
# and this runs once per token. A DIRECTORY is normalised to a trailing slash there, which
# is how path rules are written -- `Components/`, `src/Billing/` -- and how the supertool
# glob extractor above has always handed one over. Without it `grep -r x src/Components`
# and `grep -r x src/Components/` are the same directory and only one of them fires.
JIT_CAND_VALUE=""
jit_cand_ok() {
  local tok="$1" rest comp pre=""
  JIT_CAND_VALUE=""
  case "$tok" in
    "" | /*) return 1 ;;
    *\\*) return 1 ;;
    .. | ../* | */../* | */..) return 1 ;;
  esac
  rest="$tok"
  while [ "$rest" != "${rest#*/}" ]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    [ -n "$comp" ] || continue
    pre="$pre$comp"
    if [ -L "$JIT_PROJECT/$pre" ]; then return 1; fi
    pre="$pre/"
  done
  if [ -L "$JIT_PROJECT/$tok" ]; then return 1; fi
  if [ -d "$JIT_PROJECT/$tok" ]; then
    case "$tok" in */) JIT_CAND_VALUE="$tok" ;; *) JIT_CAND_VALUE="$tok/" ;; esac
    return 0
  fi
  [ -f "$JIT_PROJECT/$tok" ] || return 1
  JIT_CAND_VALUE="$tok"
  return 0
}

# The first pass printed NOTHING if it wrote this channel, so exactly one of the three
# branches below produces the hook output: the second pass, or the `{}` beside it, or --
# when the channel holds no candidate sentinel -- the first pass, which already printed.
#
# Capped in bytes, like JIT_SYMLINKS and JIT_CONFIG_REFUSED, and for the same reason: the
# list crosses an exec into the second pass, and its length is chosen by the payload.
JIT_CANDIDATES=""
JIT_SESSION_KEY=""
if [ -n "$JIT_TMP" ] && [ -s "$JIT_TMP" ]; then
  IFS= read -r JIT_CAND_HEAD < "$JIT_TMP" || JIT_CAND_HEAD=""
  if [ "$JIT_CAND_HEAD" = "$JIT_CAND_BEGIN" ]; then
    {
      IFS= read -r _JIT_SENTINEL
      IFS= read -r JIT_SESSION_KEY
      while IFS= read -r JIT_TOK; do
        [ "${#JIT_CANDIDATES}" -lt 4096 ] || break
        if jit_cand_ok "$JIT_TOK"; then
          JIT_CANDIDATES="$JIT_CANDIDATES$JIT_CAND_VALUE$JIT_NL"
        fi
      done
    } < "$JIT_TMP"
    # awk built this key out of the payload and constrained it; checked again here because
    # it is about to become part of a file name in the second pass.
    case "$JIT_SESSION_KEY" in *[!A-Za-z0-9_-]*) JIT_SESSION_KEY="" ;; esac
    # Emptied either way. The second pass rewrites this file with its marks and its log
    # line; without one, the block at the bottom would read leftover candidate lines as a
    # marks channel and a log line.
    : > "$JIT_TMP"
    if [ -n "$JIT_CANDIDATES" ]; then
      export JIT_PATH_CANDIDATES="$JIT_CANDIDATES"
      export JIT_SESSION_KEY
      jit_path_awk 1 < /dev/null
    else
      echo "{}"
    fi
  fi
fi

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
  # Two arguments, not one concatenation: _log_hook caps the matches field and leaves the
  # tail alone (#64). The tail is already bounded to 80 bytes inside awk and is what
  # jit-misses.sh reads, so it must survive a line that had to be cut.
  _log_hook "pre-path" "$TOTAL" "$AWK_MATCHES" "<< $AWK_PATH"
fi

# Stated, not inherited. The hook exit status used to be whatever the last command
# happened to leave behind -- which was `rm -f`, and always 0 by accident. With the
# removal moved to the EXIT trap the last command became the log append, and a project
# whose .discovery is read-only exited 1: a hook that FAILED HARD because it could not
# write a log line. tests/test-session-markers.sh section H caught it.
exit 0
