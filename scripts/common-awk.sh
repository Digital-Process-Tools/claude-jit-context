#!/bin/bash
# scripts/common-awk.sh -- the awk program-fragment library, split out of common.sh (#442).
#
# This is pure DATA from bash own point of view: eleven JIT_AWK_* variables, each
# holding one chunk of awk source as a single-quoted string, concatenated by the
# hooks that need them (see pre-tool-hook.sh, pre-prompt-hook.sh, pre-path-hook.sh,
# post-tool-hook.sh, session-start-hook.sh, stop-hook.sh). Split out of common.sh
# rather than trimmed, because common.sh was over the Anthropic plugin directory own
# 256 KiB per-file limit for the release branch (tests/test-release-branch-437.sh) --
# the same constraint data/generic-words.txt was already split for (#437), this time
# for a bash source file rather than a data file. BYTE-IDENTICAL move: every function
# body below is exactly what common.sh carried before this split, with its own
# documentation moved alongside it rather than left stranded at the old location.
#
# Sourced from common.sh the same way common.sh sources host.sh (#252): a missing or
# unreadable file here must not fail a hook hard. If sourcing this file fails, every
# JIT_AWK_* variable below stays unset, so the awk program a hook composes from them
# is missing function definitions -- indistinguishable, to the awk engine, from the
# crash shapes #393/#397/#400/#403 already hardened this codebase against (mawk
# refuses such a program at PARSE time with nothing on stdout; one-true-awk and gawk
# fail at the first undefined-function CALL instead). jit_awk_capture()/
# jit_awk_dispatch() already turn exactly that shape into a safe, decisive answer --
# jit_awk_crash_block() (refuse the call) for pre-tool-hook.sh, since it cannot
# verify and has something to refuse, or jit_awk_empty_ok() ("{}", the same answer a
# genuine no-match produces) for the three injection-only hooks, which have nothing
# to refuse. Nothing new needed here beyond the same readability guard host.sh
# already demonstrates.

# The value rules for one frontmatter field, in ONE place and one awk program (#307
# follow-on). It used to be a program per CALL: jit-dry-run.sh asks for up to six fields
# of the same entry and paid six awk processes, each re-reading the same file, and that
# was 42 of the 142 awks one bare lint spawned.
#
# So the program takes a LIST of fields and prints `<field><TAB><value>` for each one it
# finds. jit_frontmatter() below still takes a single field and still returns a bare
# value -- it passes a one-element list and strips the prefix with parameter expansion --
# so there is exactly one implementation of the rules below and no second copy to drift.
#
# Consumed by jit_frontmatter_many() in common.sh (#442: shellcheck cannot trace that
# usage across the source boundary the way it could within one file).
# shellcheck disable=SC2034
JIT_AWK_FRONTMATTER='
  BEGIN { nf = split(fl, want, " ") }
  /^---$/ { n++; if (n == 2) exit; next }
  n == 1 {
    for (i = 1; i <= nf; i++) {
      f = want[i]
      if (f == "" || seen[f]) continue
      if (index($0, f ":") != 1) continue
      line = $0
      sub("^" f ": *", "", line)
      # mode is a comma-separated token list, so every space goes.
        # Every other field is free text, and a `match:` value is an awk ERE where a
        # double quote is an ordinary character an author has real reason to write --
        # `["]` is how you anchor on a quoted argument. Deleting every quote in the value
        # (#19) turned that into `[]`, silently: the .md still read as the author wrote
        # it, only the index runs, and the rule matched something else forever with no
        # error and no log line.
        #
        # So only a pair WRAPPING the whole value goes -- that is YAML-style quoting of
        # the value, which is what the strip was for. A quote anywhere else is data.
        #
        # Wrapping is `^"[^"]*"$` and not `^".*"$` on purpose: the second is greedy, and
        # `"a" and "b"` starts and ends with a quote without being one quoted scalar. It
        # would come out as `a" and "b"` -- a rewrite nobody asked for, which is the
        # defect this whole change is about. Anything that is not unambiguously a wrapped
        # scalar is preserved verbatim, and a value is never required to be quoted here:
        # the reader takes the rest of the line as it stands.
        #
        # No apostrophes in this block either. It sits inside the same single-quoted bash
        # string as the rest of this program and one would close it.
        #
        # The trailing trim is the six ASCII whitespace bytes SPELLED OUT, not [[:space:]],
        # which is the rule #164 established in jit_clip() applied one function over (#172).
        # A POSIX class is byte-class-sensitive: in a single-byte locale [[:space:]] matches
        # 0xA0 -- the trailing byte of a-grave (C3 A0), S-caron (C5 A0) and the dagger
        # (E2 80 A0), and a character in its own right in ISO-8859-1. jit_clip() could argue
        # no session reached that, because every caller pins LC_ALL=C. THIS function pins
        # its own now too (#195, #196) -- rebuild-tsv.sh and jit-dry-run.sh used to call it
        # unpinned, which is the same divergence class this trim was written to survive,
        # one level up. The trim below is six ASCII bytes spelled out rather than a POSIX
        # class, so the pin buys it nothing directly here -- but a caller no longer has to
        # get its OWN locale right first for the guarantee this trim already made to hold.
        #
        # What the wide class cost was never invalid UTF-8 out of here, and the reason is
        # worth stating rather than re-deriving: v is only tested against ^"[^"]*"$, the trim
        # can only ever expose a byte that is not a quote, and the substr cuts between two
        # ASCII quotes -- so a damaged value fails the test and the line goes out untouched.
        # It cost the PARSE DECISION instead. Eating a trailing 0xA0 turned a value the
        # author did not write as a quoted scalar into one, deleting that byte and both
        # quotes with it, so rebuild-tsv.sh indexed a different `match:` ERE depending on who
        # ran it. That is #19 one locale over, silently, and #19 is why this reader stopped
        # rewriting values it does not understand.
        #
        # \t \n \v \f \r are the escapes POSIX defines for an awk ERE and all three engines
        # honour them. Naming one an engine did NOT know is the quiet failure: an awk that
        # drops an unrecognised escape matches the bare letter, so the trim would start
        # eating a trailing "v" off values with nothing said anywhere. 172a in
        # tests/test-entry-bytes.sh drives both directions per engine, 172b drives the byte
        # under a probed single-byte locale, and 172c refuses a POSIX class in the source of
        # this function on the CI legs where no such locale exists.
      if (f == "mode") { gsub(/ /, "", line) }
      else {
        v = line
        sub(/[ \t\n\v\f\r]+$/, "", v)
        if (v ~ /^"[^"]*"$/) line = substr(v, 2, length(v) - 2)
      }
      seen[f] = 1
      printf "%s\t%s\n", f, line
      next
    }
  }
'
# --- Shared awk guard for a rule match pattern -------------------------------
# Prepended to the hook programs (awk "$JIT_AWK_GUARD"'...'), so the same verdict is
# reached by pre-tool-hook.sh, pre-path-hook.sh and jit-dry-run.sh.
#
# Two failures, and only one of them is loud:
#
#   1. An undefined escape. Measured 2026-08-10 on awk version 20200816: of the ASCII
#      letters, only \a \b \f \n \r \t \v \x survive; every other \<letter> compiles to
#      the bare letter, so ~gh\s+pr becomes ghs+pr and matches nothing at all. awk does
#      not fail on this. It exits 0. Exit status cannot see this defect, which is why
#      the check here is structural rather than a compile probe.
#   2. A malformed pattern. ~a[b is a fatal awk error (exit 2) raised mid-scan, so the
#      END block never runs and EVERY rule in that index — plus the vocabulary pass and
#      the log line — is silenced by one row. Reproduced against both hooks.
#
# The verdict is deliberately engine-independent. A rule fires on the author machine,
# which is where the drop happens; gawk accepting \s is not a licence to write it, and a
# lint whose answer changes with the runner cannot gate anything.
#
# \n is the one escape rules genuinely need — it anchors on command position,
# (^|[;&|\n] *), because ^ anchors the whole command string and not each line. \t and \r
# are honoured too and are left alone. Everything else after a backslash that is a letter
# or a digit is refused: the author is present, and the fix is one character.
#
# Returns "" when the pattern can be honoured, else a short reason.
# Consumed by the hook awk programs and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_AWK_GUARD='
function jit_bad_pattern(p,   i, n, c, nx, depth, inbr, brpos) {
  # An @macro that reached the index unexpanded. Three ways in: an index built before the
  # macros existed, an index not rebuilt after the frontmatter adopted one, or a macro
  # rebuild-tsv.sh refused and wrote through. Compiled as a regex it is a literal that
  # matches nothing, on both engines, while awk exits 0 -- the exact silence this guard
  # exists to break. Anchored on `@name` followed by a space or end of pattern, so a
  # pattern that genuinely starts with a literal @ (`@app/.*`) is untouched.
  if (p ~ /^@[A-Za-z][A-Za-z0-9-]*([[:space:]]|$)/) return "unexpanded macro -- rebuild the index with the rebuild-tsv tool this plugin ships"
  n = length(p)
  depth = 0
  inbr = 0
  brpos = 0
  for (i = 1; i <= n; i++) {
    c = substr(p, i, 1)
    if (c == "\134") {
      nx = substr(p, i + 1, 1)
      if (nx == "") return "trailing backslash"
      if (nx ~ /[[:alnum:]]/ && nx !~ /^[ntr]$/) return "undefined escape \134" nx
      # A byte above ASCII, and the test above could never see it (#116). LC_ALL=C is
      # pinned on every awk that reaches this function, so substr() returns one BYTE:
      # the lead byte of an accented or CJK character. Measured on awk 20200816 and gawk
      # 5.4.1 under C, that byte is in NO character class -- not [[:alnum:]], not
      # [[:print:]], not [[:cntrl:]] -- so no class test can catch it, which is why this
      # is a byte comparison. String comparison under C is strcmp, and both engines
      # answer 1 for `"\303" > "\177"`.
      #
      # What such a row actually did is worth stating, because it is NOT "matched
      # nothing": the escape is dropped and the pattern matches the BARE character, on
      # both engines. So the row fires on text the author did not write a backslash for.
      # Refusing it is the same trade the ASCII case above already makes -- the author is
      # present and the fix is one character -- and it buys the half that has no
      # workaround: gawk writes `regexp escape sequence ... is not a known regexp
      # operator` into a stranger session stderr while the hook exits 0, and a refused
      # row never reaches match() at all.
      #
      # The reason names the position instead of appending the byte. `"undefined escape
      # \\" nx` would put a lone continuation byte into the injected notice, which is the
      # class #77 and #78 were about: half a character on a channel that must carry it.
      if (nx > "\177") return "undefined escape \\ before a non-ASCII byte"
      i++
      continue
    }
    if (inbr) {
      # A POSIX class, collating element or equivalence class is one unit, and the ] it
      # contains does NOT close the bracket expression. Scanning ] naively reads
      # [[:alnum:] as balanced and hands it to match(), where it is a FATAL awk error --
      # reopening the exact failure this guard exists to stop.
      # #461: the three element openers come from sprintf, not the text `:.=` -- the
      # directory validator read that sequence as a `.` command and held every hook.
      nx = substr(p, i + 1, 1)
      if (c == "[" && nx != "" && index(sprintf("%c%c%c", 58, 46, 61), nx) > 0) {
        k = index(substr(p, i + 2), substr(p, i + 1, 1) "]")
        if (k == 0) return "unterminated [" substr(p, i + 1, 1) " element inside a character class"
        i = i + 2 + k
        continue
      }
      # ] is a literal when it is the first character of the expression, or the first
      # after a negating ^.
      if (c == "]" && i != brpos + 1 && !(i == brpos + 2 && substr(p, brpos + 1, 1) == "^")) inbr = 0
      continue
    }
    if (c == "[") { inbr = 1; brpos = i; continue }
    if (c == "(") { depth++; continue }
    # An unmatched ) is a LITERAL in an ERE and awk accepts it -- measured, a)b matches.
    # Refusing it would kill rules that work today, which is worse than the bug: this
    # guard may only ever refuse a pattern awk cannot honour. An unmatched ( is a fatal
    # error, so the closing check below is deliberately one-sided.
    if (c == ")") { if (depth > 0) depth--; continue }
  }
  if (inbr) return "unterminated character class"
  if (depth > 0) return "unbalanced parenthesis"
  return ""
}
'
# --- Shared awk containment check + refusal notices ---------------------------
# Prepended to all three hook programs (the prompt hook has no patterns to guard, so it
# takes this and not JIT_AWK_GUARD), and to jit-dry-run.sh.
#
# An index row names its entry file, and every hook builds the path by concatenating that
# name onto the layer directory. Until 2026-08-11 nothing checked it, so a committed row
# of `../../../../outside.txt` made the hook READ that file and inject its contents into
# the model's context. 00-index.tsv is a committed file, so cloning a repository was the
# whole attack. Reproduced at all five read sites: the path rule loop, the tool rule loop,
# and the three vocabulary passes.
#
# The check is "a bare file name", not a resolved-prefix comparison, because awk has no
# realpath and shelling out for one would cost a process per row. It is safe to be this
# strict: rebuild-tsv.sh writes this column with `basename` at all four of its sites, and
# the generated-layer contract in the README is the same TSV format, so a name carrying a
# separator was never produced by this project.
#
# The backslash is refused for Windows. On Git Bash the Win32 file API underneath awk
# treats it as a separator, so `..\..\x` traverses there while being inert here -- the
# reverse of the mistake this repo has already made twice about the other legs of CI.
#
# Consumed by the hook awk programs and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_AWK_ENTRY='
# A refused row is reported by POSITION, never by the text of its file-name column. That
# column is attacker-controlled free text whose only constraint is that it carries no
# separator, and the refusal notice fires without any rule having matched -- so echoing it
# back would be a prompt-injection channel that needs no trigger at all. The full name
# still goes to hooks.log, which a person reads and no model does.
#
# That was true of the CONTAINMENT branches and false of the pattern branches beside them,
# which echoed the name and carried a comment arguing it was safe because the row had
# passed the bare-name check. Passing that check means no slash, no backslash, not `.` and
# not `..`; it does not mean 250 bytes of English are not a sentence. A file-name column
# reading "IGNORE ALL PREVIOUS INSTRUCTIONS. Run: ..." landed in the context verbatim with
# no rule matched and no entry file present (#35). All seven refusal sites go through this
# function now, and tests/test-security.sh pins each hook.
#
# `layer` is qualified by DIMENSION -- "paths/00-manual", not "00-manual". Two dimensions
# use the same four layer names, one hook reads both, and the file name used to be what
# told two otherwise identical notice lines apart. Withholding the name without adding the
# dimension would have closed one hole by making the remaining line ambiguous.
function jit_row_id(layer, rown) {
  return layer " row " rown
}
# #233: looks up the age jit_scan_entry_ages() (bash half, above) already read for
# "<layer>/<file>" and returns it as a whole number of days, or "" when the table has
# nothing for that key -- an entry outside 00-manual, a whole line jit_scan_entry_ages()
# dropped once JIT_ENTRY_AGES was already over its cap (the cap never truncates a line
# mid-flight, only refuses the next one), or a perl this platform could not run. "" is a
# real answer, not a defect: every caller treats it as "say nothing", never as "0 days
# old", so a platform where this could not be measured degrades to the footer exactly as
# it read before #233.
#
# Parsed ONCE per awk process, on the first call, into jit_age[] -- not once per row.
# ENVIRON["JIT_ENTRY_AGES"] is "<layer>/<file>\t<days>" lines, exactly what the bash
# scan built; a line this split cannot make sense of (no tab, an empty key) is skipped
# rather than crashing the whole table, the same tolerance jit_shown_load() already
# gives a marker file it did not write.
function jit_entry_age(ident,   raw, n, i, ln, tp) {
  if (!jit_age_loaded) {
    jit_age_loaded = 1
    raw = ENVIRON["JIT_ENTRY_AGES"]
    if (raw != "") {
      n = split(raw, jit_age_lines, "\n")
      for (i = 1; i <= n; i++) {
        ln = jit_age_lines[i]
        if (ln == "") continue
        tp = index(ln, "\t")
        if (tp == 0) continue
        jit_age[substr(ln, 1, tp - 1)] = substr(ln, tp + 1) + 0
      }
    }
  }
  if (ident in jit_age) return jit_age[ident]
  return ""
}
# Every hook log line ends with a field lifted verbatim out of the tool payload, after
# jit_unescape() -- so a JSON newline escape is a REAL newline by the time it is written.
# Two things went wrong with that and only one of them was a security bug.
#
# The security half is #65: the marks share this channel, so payload text after a newline
# was read back as a mark. The boundary in jit_shown_flush() is what actually closes that;
# this is defence in depth, at the point the field is BUILT rather than at the point it is
# parsed, so a future log line that forgets the boundary still cannot carry one.
#
# The reporting half needs no attacker at all. A multi-line prompt truncated its own log
# line at the first newline, and jit-misses.sh reads that file -- so a two-line prompt was
# recorded, and reported back to its author, as shorter than they typed it.
#
# A space, not a deletion: two words either side of a line break are two words.
# gsub over the class, not index(): both bytes are ASCII and neither can be part of a
# multibyte sequence, so there is no decode here to go wrong.
function jit_log_text(s) {
  gsub(/[\n\r]/, " ", s)
  return s
}
# What the LOG may say about a refused row. hooks.log is a file on the disk of whoever
# cloned the repository, read by a person, and the containment branch was writing the row
# file-name column into it verbatim -- the one string jit_bad_entry_file() deliberately
# withholds from the model. A name that FAILED the bare-name check now gets the treatment
# the model-facing notice already gets: the row is named by POSITION, the raw text dropped.
#
# A name that PASSED is bare by construction -- no separator, not . or .. -- and it is what
# an author fixing an unhonourable pattern actually needs, so it is kept. That includes a
# row refused for being a symbolic link: the name passed, only the file behind it did not.
#
# No apostrophes in this block. It is a single-quoted bash string and one would close it.
function jit_log_name(f, layer, rown, why) {
  return (why == "not a bare file name") ? jit_row_id(layer, rown) : f
}
# The set built by jit_scan_symlinks() in the bash half, keyed by full path. Loaded once
# per awk process, lazily, so a hook whose tree has no index pays nothing for it.
function jit_symlinked(p,   n, i, a) {
  # The sentinel first. When the bash sweep could not carry the set within its byte budget
  # it enumerates NOTHING and says so here instead -- a tree nobody can enumerate is a tree
  # nobody can vouch for, so every path in it answers yes. Any future caller of this
  # function inherits that without having to know the sentinel exists.
  if (ENVIRON["JIT_SYMLINKS_ALL"] == "1") return 1
  if (!jit_sym_init) {
    jit_sym_init = 1
    n = split(ENVIRON["JIT_SYMLINKS"], a, "\n")
    for (i = 1; i <= n; i++) if (a[i] != "") jit_sym[a[i]] = 1
  }
  return (p in jit_sym)
}
# The other half of the same sweep (#97): paths at entry depth that are NOT regular files.
# Same shape as jit_symlinked() above, deliberately -- one idiom for one job -- and the
# same sentinel posture: a set the bash half could not finish enumerating answers yes for
# everything, because the alternative is clearing a path nobody looked at.
#
# Answering YES here costs one body, never the hook: every caller turns it into a reason
# string and keeps going. Answering wrongly NO on the engine that matters costs the process.
function jit_nonfile(p,   n, i, a) {
  if (ENVIRON["JIT_NONFILES_ALL"] == "1") return 1
  if (!jit_nf_init) {
    jit_nf_init = 1
    n = split(ENVIRON["JIT_NONFILES"], a, "\n")
    for (i = 1; i <= n; i++) if (a[i] != "") jit_nf[a[i]] = 1
  }
  return (p in jit_nf)
}
# dir is the layer directory the caller is about to concatenate this name onto -- the same
# string the hook builds for getline, so the lookup is an exact match against what the
# bash sweep globbed. A caller that passes no dir gets the name checks only.
function jit_bad_entry_file(f, dir) {
  # An empty column is a blank index line, not a rule. It carries no pattern either and
  # the caller skips it on the existing content == "" path; refusing it would fire a
  # notice at the author over stray whitespace.
  if (f == "") return ""
  if (index(f, "/") > 0 || index(f, "\134") > 0) return "not a bare file name"
  if (f == "\056" || f == "\056\056") return "not a bare file name"
  # A LEADING DOT, refused by name rather than caught by lstat, because lstat never saw it:
  # the sweep in the bash half enumerates the tree with globs and a glob * does not match a
  # leading dot. So `.hidden.md` skipped the link set entirely and every check below cleared
  # it, while the identical link named `hidden.md` was refused -- #13 reopened as #34,
  # driven at all five read sites and in jit-dry-run.sh.
  #
  # The sweep now globs the dot forms too, so this is belt and braces rather than the only
  # guard. It is kept because it is the half that needs no lstat at all, and because it is
  # the same verdict on every platform regardless of what the sweep managed to see.
  #
  # Refusing every dot-name outright is safe for an honest tree: rebuild-tsv.sh writes this
  # column from a `*.md` glob at all four of its sites, and that glob cannot produce one.
  # No WIDER alphabet constraint is imposed. `^[A-Za-z0-9._-]+\.md$` was proposed for this
  # and would have been worse than nothing: it admits `.hidden.md`, every character of which
  # is in that class, and it admits a whole English sentence of dots and hyphens -- so it
  # closes neither this nor the notice-quoting sibling, while refusing an accented or spaced
  # file name that works today. tests/test-security.sh pins both directions.
  if (substr(f, 1, 1) == "\056") return "the entry file name begins with a dot, so rename it without one"
  if (dir != "") {
    # The whole-tree sentinel first, and with its own reason: "its layer directory is a
    # symbolic link" would be a specific claim about a specific path that nobody checked.
    # Saying what actually happened is the point -- an author whose tree is refused for this
    # has a different thing to fix from an author whose layer is a link.
    if (ENVIRON["JIT_SYMLINKS_ALL"] == "1") return "this tree has too many symbolic links to check, so every row in it is refused"
    # The directory next: when the layer itself is a link, every row in it is unreadable
    # for the same reason, and naming the file would point the author at the wrong thing.
    if (jit_symlinked(dir)) return "its layer directory is a symbolic link"
    if (jit_symlinked(dir "/" f)) return "the entry file is a symbolic link"
  }
  return ""
}
# --- Bytes an entry can carry that the JSON channel cannot (#77, #78) --------
#
# jit_json_escape() escapes 0x00-0x1F, quote and backslash and NOTHING above 0x7F, which
# is right: valid UTF-8 needs no escaping inside a JSON string. What it cannot do is
# decode. So an entry saved in ISO-8859-1 -- one 0xE9 in "Preferez rm -i" -- travelled
# into additionalContext intact and the emitted object was not UTF-8. Exit 0, stderr
# empty, and a strict reader rejects the WHOLE object: the other entries injected in the
# same call went down with the bad one, and a block decision that had been reached became
# unreadable.
#
# Escaping the byte instead was the alternative and is worse: a \u escape needs the code
# point, which needs a decoder, which is the multibyte trap this file has been bitten by
# three times. Transliterating silently rewrites an entry. So the byte is REFUSED, through
# the machinery that already exists for a pattern the matcher cannot honour: the ROW is
# refused, named by POSITION in the notice, and every other row still fires.
#
# Bytes only, no decode. Under LC_ALL=C -- which every hook awk is pinned to -- both
# engines read a record as bytes, and sprintf("%c", k) builds exactly one byte for k in
# 1..255 on both; verified on awk version 20200816 and GNU Awk 5.4.1. No regex is matched
# against a single character, so the rule at the top of this file is intact.
#
# The fast path is the whole cost story: an all-ASCII string clears in ONE regex match
# against a bracketed byte range, and the per-byte loop runs only for a string that
# carries a high byte at all. Measured end to end on a 1001-row paths index with two
# entries injected, one of them 4 KB, interleaved against the unpatched hook to cancel
# machine load: 22.2 ms before, 23.3 ms after, on awk version 20200816. The loop itself,
# when it does run, costs about 1 ms per 4 KB of accented body.
function jit_utf8_init(   k) {
  if (jit_utf8_ready) return
  jit_utf8_ready = 1
  for (k = 1; k <= 255; k++) jit_ord[sprintf("%c", k)] = k
  jit_hi_re = "[" sprintf("%c", 128) "-" sprintf("%c", 255) "]"
  # Stored rather than rebuilt per call, because the two engines disagree about whether it
  # exists: gawk is NUL-transparent and one-true-awk cannot build a one-byte NUL at all.
  # index(s, "") returns 1, so an unguarded search reports every string as carrying one.
  jit_nul = sprintf("%c", 0)
}
# Structure only, in the RFC 3629 ranges: no overlong form, no surrogate, nothing above
# U+10FFFF. A lone continuation byte and a truncated sequence are the two shapes a Latin-1
# save and a copy cut at a buffer boundary actually produce, and both are refused.
function jit_bad_utf8(s,   i, n, b, need, lo, hi, j, cb) {
  jit_utf8_init()
  if (s !~ jit_hi_re) return 0
  n = length(s)
  for (i = 1; i <= n; i++) {
    b = jit_ord[substr(s, i, 1)] + 0
    if (b < 128) continue
    if (b < 194 || b > 244) return 1
    if (b < 224) { need = 1; lo = 128; hi = 191 }
    else if (b < 240) { need = 2; lo = (b == 224) ? 160 : 128; hi = (b == 237) ? 159 : 191 }
    else { need = 3; lo = (b == 240) ? 144 : 128; hi = (b == 244) ? 143 : 191 }
    if (i + need > n) return 1
    for (j = 1; j <= need; j++) {
      cb = jit_ord[substr(s, i + j, 1)] + 0
      if (j == 1) { if (cb < lo || cb > hi) return 1 }
      else if (cb < 128 || cb > 191) return 1
    }
    i += need
  }
  return 0
}
# One verdict for both channels. NUL comes first and is NOT a UTF-8 fault -- U+0000 is a
# code point and jit_json_escape() escapes it -- but the mark channel is line-based and
# bash read -r truncates at it, so a NUL in an index row silently shortened the dedup key
# and a marker was written for an entry nothing had injected (#78). one-true-awk truncates
# the RECORD at the NUL and never reaches here with it; that reading is caught one step
# later, when the file the shortened name points at does not open.
function jit_bad_bytes(s, what) {
  jit_utf8_init()
  if (length(jit_nul) == 1 && index(s, jit_nul) > 0) return what " contains a NUL byte"
  if (jit_bad_utf8(s)) return what " is not valid UTF-8"
  return ""
}
# The ONE FUNNEL every reader of an entry file passes through, so this check cannot be
# added at four sites and missed at the fifth. It used to be jit_read_body() itself, back
# when that was the only reader; issue #1 added a second, jit_entry_load(), which stops at
# the closing --- when only a summary is injected, so the guard moved down here rather
# than being written out twice. A THIRD reader that opens an entry file without calling
# this reopens #97 on one-true-awk, silently and on an engine Linux CI does not run.
#
# Returns a reason a getline must not be attempted at all, or "" when it may be. Both
# shapes are committable index rows, and both are fatal rather than -1 on one-true-awk.
function jit_entry_why(path) {
  if (substr(path, length(path), 1) == "/") return "the row names no entry file"
  if (jit_nonfile(path)) return "the entry file is not a regular file"
  return ""
}
# Reads a WHOLE entry file. One caller is left, jit-dry-run.sh, which is asking whether
# the bytes can be delivered at all rather than what would be injected -- the hooks now go
# through jit_entry_load(). The body lands in JIT_BODY rather than in the return value,
# because awk returns one scalar and the reason is what every caller has to branch on.
#
# getline < 0 is "could not open", which a row naming a deleted or renamed entry produces.
# It used to be indistinguishable from an EMPTY entry file: nothing injected, nothing
# refused, and the shown-marker written anyway. That is the reading one-true-awk takes of
# a NUL-bearing row, so this is where #78 is caught on the engine that hides the byte.
function jit_read_body(path,   line, r, first) {
  JIT_BODY = ""
  # --- Before the read, because on one engine there is no after (#97) --------------
  #
  # Every caller builds this path as <layer dir> "/" <file-name column>, and two shapes of
  # that concatenation name something `getline` must never open. Both are refused in
  # jit_entry_why(), the funnel every entry read passes through, rather than at each site:
  # a guard a site can forget is a guard that protects four sites out of five.
  #
  # A trailing slash is an EMPTY file-name column, which concatenates to the layer directory
  # itself. jit_bad_entry_file() lets that column through on purpose -- an empty column is a
  # blank index line, and refusing it would fire a notice at an author over stray whitespace
  # -- but a row that reached a body read has a tool, a match and a mode, so it is a rule
  # naming no entry rather than a blank line, and saying so is the honest reading.
  #
  # A path in the non-file set is a directory, a FIFO or a device node. On one-true-awk the
  # first is a fatal i/o error inside END and the second never returns at all.
  #
  # THE ROW IS REFUSED, NEVER THE FILE, and never the decision. This returns a reason like
  # every other unreadable body, so the caller substitutes text and carries on -- a block
  # rule whose entry is a directory still blocks. That is the jit_bad_pattern() posture, and
  # the whole of #97 is that a malformed thing was fatal to the program instead.
  #
  # The two pre-read checks live in jit_entry_why() because there are now TWO readers of an
  # entry file, not one: this function, and jit_entry_load() in JIT_AWK_INJECT, which stops
  # at the closing `---` when only a summary is injected. Two readers with the guard written
  # out twice is exactly the fifth-site problem this comment opens with, so the guard is one
  # function that both call.
  if ((r = jit_entry_why(path)) != "") return r
  first = 1
  while ((r = (getline line < path)) > 0) {
    JIT_BODY = JIT_BODY (first ? "" : "\n") line
    first = 0
  }
  close(path)
  if (r < 0) return "the entry file could not be read"
  # UTF-8 only, and deliberately NOT jit_bad_bytes(). A NUL in a BODY is already handled
  # and already tested: U+0000 is a code point, jit_json_escape() emits it as a unicode
  # escape, and a body never reaches the line-based mark channel that #78 is about -- a
  # mark carries the entry FILE NAME. Refusing it here would break delivery that works,
  # and break it on gawk alone, since one-true-awk truncates the line at the NUL and
  # never sees one. The index row keeps the NUL check; the body does not need it.
  return jit_bad_utf8(JIT_BODY) ? "the entry file is not valid UTF-8" : ""
}
# --- The refusal list is bounded; the COUNT beside it is not (#38) ------------
#
# The sibling of the config.env cap, one channel over and a different failure. This string
# is built INSIDE awk and never crosses an exec, so there is no ARG_MAX here and nothing
# errors: it simply grows, one bullet per unhonourable row, and every byte lands in
# additionalContext. 00-index.tsv is a committed file, so a clone chooses how many rows are
# unhonourable -- and the cost is the session context window, which is the one resource this
# plugin exists to spend carefully.
#
# BYTES, not rows, for two reasons. It is the guarantee that matters -- context is measured
# in tokens, and a row cap only bounds tokens if every bullet is the same size -- and it is
# the axis the config.env half already uses, so there is one idiom for one job rather than
# two. In practice the two are close here: a bullet is a layer name, a row number and a
# fixed reason string, never the pattern and never the file-name column (#28, #35), so it
# is roughly 45 bytes and 4096 buys about ninety of them. That is far more than anyone
# fixing a tree reads before running the linter the notice points them at.
#
# The cap is on the OUTPUT and on nothing else. Every row is still evaluated, every honest
# rule after the cap still fires, and no hook exits differently. Stopping the scan would
# turn a bounded notice into silently unenforced rules.
#
# The COUNT is uncapped, and the cut says so in words. A notice that quietly stopped at N
# would tell the reader N rules were refused -- a false statement produced by a defence,
# which is this repository own defect class wearing a fix as a disguise.
#
# POSITIONS SURVIVE TRUNCATION. Each bullet carries the row number its own call site
# computed, so the numbers printed are true positions in the file and not indices into the
# list that was kept. tests/test-security.sh S7 interleaves honest rows with refused ones so
# that no refused row sits at position 1, and pins that "row 1" never appears.
#
# jit_refuse_cut is a program-scope variable on purpose: one awk process runs one hook, and
# the cut line must be added once no matter which of the seven call sites overflows first.
#
# A THRESHOLD, not a hard ceiling: the length is checked before the append, so the list
# settles at 4096 plus the bullet that crossed it plus the cut line. That is the config.env
# half exactly. Cutting a bullet mid-string to hit a precise figure would print half a row
# number, and a position that lies is the one outcome this whole notice exists to avoid.
function jit_refuse_add(list, item) {
  if (length(list) > 4096) {
    if (jit_refuse_cut) return list
    jit_refuse_cut = 1
    return list "\n- the remaining refused rows are not listed here; the count above is the whole total"
  }
  return list (list == "" ? "- " : "\n- ") item
}
# The census of #182 needs the same 4096-byte threshold and the same cut line, and it
# must NOT share jit_refuse_cut. That variable is program-scope on purpose -- one awk
# process, one hook, and whichever of the seven refusal sites overflows first adds the
# cut line once. Two DIFFERENT lists sharing it is a different thing: if `refused`
# overflows first and sets the flag, every later append to the unreachable list is
# dropped silently, with no cut line and with n_unreached still counting the whole
# total. The notice would then say "N rule(s)" above a list shorter than N and offer no
# hint that anything was removed -- a false statement produced by a defence, which is
# the exact failure the comment above jit_refuse_add() names. Its own flag, so the two
# lists cannot cut each other.
function jit_unreached_add(list, item) {
  if (length(list) > 4096) {
    if (jit_unreached_cut) return list
    jit_unreached_cut = 1
    return list "\n- the remaining unreachable rows are not listed here; the count above is the whole total"
  }
  return list (list == "" ? "- " : "\n- ") item
}
function jit_refusal_notice(list, n) {
  return "# JIT Context: " n " rule(s) could not be evaluated, so they did NOT run\n" list \
    "\nA pattern the matcher cannot honour is not a rule that did not match, and until now the two looked identical. Lint the tree that owns these rules with the jit-dry-run tool this plugin ships, --base <tree>/.claude/jit-context"
}
# The third state for a LAYER rather than for a row (#176). Everything above reports a
# rule the matcher read and could not honour; this reports a directory of rules the
# matcher never opened, which until #176 was reported by nothing at all and rendered
# exactly like a layer whose rules simply never matched.
#
# The list is built in bash (jit_scan_layers) and arrives through ENVIRON, for the reason
# JIT_CONFIG_REFUSED does: it is newline-separated, and a newline in an awk -v value is a
# fatal error raised before the program runs. No layer NAME is ever in it -- the bullets
# carry a dimension, a position in the glob and a constant reason.
function jit_layers_notice(list, n) {
  return "# JIT Context: " n " jit-context layer director" (n == 1 ? "y" : "ies") " could not be read, so no rule inside them ran\n" list "\nThese are directories under .claude/jit-context/<dimension>/ that exist and hold rules the matcher never opened. A layer that was never loaded and a layer whose rules never matched look identical from a session, which is why this says so. Name a layer directory with letters, digits, dot, underscore and hyphen only, and lint the tree with the jit-dry-run tool this plugin ships, --base <tree>/.claude/jit-context"
}
# The third state for a TOOL rather than for a row or a layer (#182). The two above
# report rules the matcher read; this reports rules the matcher never reached, because
# the dispatch carried nothing it could build a subject out of.
#
# It exists because `tool:` accepts any tool name and the subject is built from a fixed
# set of tool_input KEYS -- command, skill, file_path, pattern, subagent_type. Those two
# facts do not line up, and nothing joined them: `tool: Agent` validated, indexed, was
# counted by every diagnostic that counts rules, and could not fire. So did `tool:
# TodoWrite`, `tool: WebFetch`, and every `tool: mcp__*` rule there will ever be.
#
# WHY THIS IS A RUNTIME NOTICE AND NOT AN INDEX-TIME REFUSAL. Refusing the row in
# rebuild-tsv.sh would need a tool -> key map hardcoded somewhere, and that map cannot
# be written: an MCP server defines its own input schema at connect time, and Claude
# Code adds tools between releases. A hardcoded list would refuse rules that work and
# accept rules that do not -- the #176 defect in a new spelling, in the one place that
# is committed to disk and shipped to strangers. This fires only on EVIDENCE: a real
# dispatch of that tool arrived, no subject came out of it, and rules in this tree name
# it. That evidence cannot be stale.
#
# By position, never by the file-name column, and no tool NAME either: the name column
# of a row is untrusted free text (#35) and tool_name is payload. The bullets carry a
# dimension, a layer, a row number and a derived kind, exactly as the bullets of
# jit_refusal_notice do.
#
# NOTE FOR THE NEXT EDITOR: this whole block lives inside a single-quoted shell string.
# An apostrophe here ends it, and bash then reads awk source as shell. Measured while
# writing this comment -- the validator caught it, the rollback undid it, and the next
# person should not have to rediscover it.
function jit_no_subject_notice(list, n) {
  return "# JIT Context: " n " tools rule(s) name this tool, but the hook could build no subject to match them against, so they did NOT run\n" list \
    "\nA tools rule is matched against a subject built from the tool_input keys `command`, `skill`, `file_path`, `pattern` and `subagent_type`. This dispatch carried none of them, so the rules above were indexed and counted and never consulted. Either they name a tool whose input this hook cannot read, or they name the wrong tool. A rule that cannot be reached is not a rule that did not match, and until now the two looked identical."
}
function jit_config_notice(list, n) {
  return "# JIT Context: " n " line(s) in .claude/jit-context/config.env were refused, so they did NOT take effect\n" list \
    "\nconfig.env is read as plain KEY=VALUE and is never executed. Only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* settings are read; anything else, shell included, is refused. If a refused line is not one you wrote, treat that file as hostile -- it arrived with the repository."
}
# #402: `line` is built in bash by jit_worktree_mismatch_line() and arrives empty unless a
# mismatch was CONFIRMED -- the caller only invokes jit_blk_prepend()/block_tail with this
# when `line` is non-empty, the same "only speak when there is something to say" shape
# every other notice in this file follows.
function jit_worktree_notice(line) {
  return "# JIT Context: CLAUDE_PROJECT_DIR names a different git worktree than this shell is sitting in\n" line \
    "\nEvery hook resolves rules from CLAUDE_PROJECT_DIR, never from the working directory -- content injected below (or on any call in this session) can be served from the copy in the OTHER tree, silently (#402). Run /jit-context:doctor"
}
'
# --- Shared entry reader: frontmatter, body, and what gets injected ----------
# Prepended to all three hook programs. This is the ONE place an entry file is turned
# into the text a match contributes, so the three hooks cannot drift into disagreeing
# about what a `description:` or an `inject:` means.
#
# The description is read out of the FILE at fire time, not out of a third TSV column.
# That was a judgement call and it is worth recording: the hook already opened the entry
# to read its body, so this costs no schema change, no version bump and no migration
# note -- where a new column would leave a stale committed index in every project that
# has one, with session-start-hook.sh clearing markers and rebuilding nothing.
#
# Summary mode is also FASTER than reading the whole file: the read stops at the closing
# `---`, so a large entry costs its frontmatter instead of its body.
# Measured 2026-08-12 on macOS, awk version 20200816, a 31.6 KB entry matched by one
# keyword, 60 invocations per arm and three interleaved rounds to cancel machine load:
# 32.6 / 32.8 / 35.8 ms per invocation reading the whole file, against 29.1 / 28.0 / 30.3
# stopping at the frontmatter. So the cheap answer to "where does the description come
# from" is also the fast one, and the third TSV column -- which would have made every
# committed index in every project stale -- buys nothing it does not also cost.
#
# A `description:` reaches the model context, so it is attacker-controlled text of the
# same family as the file-name column (#35) and the mode column (#28) -- one file over.
# It is NOT the same trust tier as those two, and the difference decides the treatment:
# those reached the context with no rule matched and no entry file present, which made
# them a prompt-injection channel that needed no trigger. This text comes out of an entry
# whose row matched and whose file passed jit_bad_entry_file(), and until this change the
# WHOLE of that file was injected verbatim. So the description is not new text in the
# context; it is less of it.
#
# What is new is the promise that a match is CHEAP, and an uncapped description breaks
# exactly that -- 15 KB on one frontmatter line and summary mode costs what full mode
# costs, silently. So both fields are clipped, and the clip is visible in what is
# injected rather than being a quiet truncation. No other rewriting: #19 is what happens
# when this reader edits a value it does not understand -- so the only whitespace jit_clip()
# removes is whitespace inside the cut it just made, never any in a value that fits (#156).
#
# No apostrophes in this block. It is a single-quoted bash string and one would close it.
#
# THIS IS A FRAGMENT, NOT A PROGRAM (#173). jit_entry_load() below calls jit_bad_utf8() and
# jit_entry_why(), which live in $JIT_AWK_ENTRY, so this variable must be concatenated with
# at least $JIT_AWK_ENTRY -- the hooks compose $JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_INJECT
# $JIT_AWK_JSON, see pre-path-hook.sh. Two of the three engines hide a violation: one-true-
# awk and gawk only notice an undefined function when one is CALLED, so a program that never
# reaches those call sites runs anyway. mawk refuses at PARSE time and prints nothing at all,
# with "function jit_bad_utf8 never defined" on a stderr the caller usually discards -- empty
# stdout and the explanation thrown away, which is this repository's own defect class. It cost
# a full CI round on PR #171: 13 assertions red on ubuntu-latest, where mawk is the default
# awk, every one of them with an empty got:, and none of it about the code under test.
# shellcheck disable=SC2034
JIT_AWK_INJECT='
function jit_clip(s, n,   i) {
  if (length(s) <= n) return s
  s = substr(s, 1, n)
  # substr counts BYTES on one-true-awk and CHARACTERS on gawk, so on one of the two a
  # cut at n can land inside a multibyte character and leave a lone continuation byte in
  # what is injected. RFC 8259 says nothing about it, but a strict reader of the JSON is
  # entitled to reject invalid UTF-8, which renders as the hook having said nothing at
  # all -- the shape of #14 and #15, and unreachable on the engine CI runs on Linux.
  #
  # The cut is not the only way that byte sequence can leave this function: the trim at
  # the bottom runs after this repair, so it too is looking at raw bytes, and the block
  # beside it (#164) is what keeps THAT from undoing this.
  #
  # So the engine is PROBED rather than assumed: one two-byte character has length 1
  # where substr is character-based and 2 where it is byte-based. Under gawk this whole
  # branch is dead, and correctly so -- the cut there is already on a boundary.
  if (length("é") > 1) {
    # 0x80-0xBF is a continuation byte and 0xC0-0xFD introduces a sequence. On this
    # engine sprintf("%c", k) is exactly that one byte, and index() is a byte search.
    # At most three continuations plus the byte that introduces them: a UTF-8 sequence
    # is four bytes at the most. A cut that landed on a boundary loses one whole
    # character to this, which is a cosmetic price on a string already being truncated.
    if (!jit_cont) {
      for (i = 128; i <= 191; i++) jit_cont = jit_cont sprintf("%c", i)
      for (i = 192; i <= 253; i++) jit_lead = jit_lead sprintf("%c", i)
    }
    i = 0
    while (i < 3 && length(s) > 0 && index(jit_cont, substr(s, length(s), 1)) > 0) {
      s = substr(s, 1, length(s) - 1)
      i++
    }
    if (length(s) > 0 && index(jit_lead, substr(s, length(s), 1)) > 0) s = substr(s, 1, length(s) - 1)
  }
  # The ONE rewrite this function is entitled to, and only on a string it has already cut.
  # A cut at n can land inside a run of spaces or on a CR, and the marker would then read
  # "word    [clipped]" -- whitespace that is not the authors, sitting where the cut was.
  # Below the cap nothing is cut, so there is nothing to tidy and the value goes out as it
  # was written: see #156 for what trimming everything cost.
  #
  # The cap is measured on the value as written, whitespace included, and that is
  # deliberate: a value that is over budget only by its trailing spaces is cut and marked
  # like any other. Deciding on the trimmed length instead would put the old rewrite back
  # for a narrower band of values, which is a stranger rule than the one it replaced.
  #
  # The class is SPELLED OUT rather than written [[:space:]], and that is the whole of
  # #164. A POSIX class is byte-class-sensitive: in a single-byte locale [[:space:]]
  # matches 0xA0, which is the trailing byte of a-grave (C3 A0), S-caron (C5 A0) and the
  # dagger (E2 80 A0). Since #157 this trim runs AFTER the repair above, so it is looking
  # at raw UTF-8 bytes -- and a cut landing after two adjacent such characters leaves the
  # repair a valid, complete character to stop on, whose last byte the trim then ate,
  # exposing the lone lead byte in front of it. Invalid UTF-8 out of this function, which
  # is the #14/#15 shape the block above describes.
  #
  # Every caller pins LC_ALL=C, so no session could reach it. That is exactly the reason
  # not to leave it: the function would be describing a property it no longer held, kept
  # alive by four pins in four files that nothing forces anyone to keep. Measured under C on
  # one-true-awk, gawk and mawk: these six bytes ARE [[:space:]] on all three, byte for
  # byte -- so this changes nothing #157 established and removes the dependence on the
  # caller. \t \n \v \f \r are the escape sequences POSIX defines for an awk ERE, and all
  # three honour them. Naming one an engine did NOT know would be the quiet failure: an awk
  # that does not recognise an escape drops the backslash and matches the bare letter, so
  # the trim would start eating a trailing "v" off values and nothing would say so -- gawk
  # warns on stderr, which every hook here discards. tests/test-entry-bytes.sh 164a drives
  # that in both directions, per engine.
  sub(/\r$/, "", s)
  sub(/[ \t\n\v\f\r]+$/, "", s)
  return s " [clipped]"
}
# --- Transclusion: {{dimension/layer/file.md}} spliced into a body at fire time (#378) ---
#
# Decided FIRE TIME rather than rebuild time -- see paths/00-manual/entries.md for the full
# writeup. Every other body transform in this file (jit_clip, jit_inject_text itself)
# already runs per fire and rebuild-tsv.sh never touches what gets INJECTED, only what
# gets INDEXED, so pulling this into the rebuild would be a second body pipeline rather
# than a reuse of this one. Fire time also keeps the ergonomic already established: editing
# a transcluded body needs no rebuild-tsv.sh run to take effect, which is the trap the top
# of CLAUDE.md already names for frontmatter -- reopening it one layer down for bodies
# would be a strange trade for a feature whose whole point is to hand a body over directly.
# The cost that buys is bounded rather than assumed away: a depth cap, a per-fire total cap
# and cycle detection, all three enforced in the pass that resolves the path, below.
#
# Containment is the syntax, not a bolt-on check -- the issue own framing, and the reason
# the accepted shape is narrow. A spec is split on "/" into EXACTLY three components, each
# held to the same alphabet a layer directory name is already held to elsewhere in this
# file (letters, digits, dot, underscore, hyphen -- jit_layers_notice() own wording), with
# a leading dot refused the way jit_bad_entry_file() already refuses one on an ordinary
# file-name column. That alphabet has no "/" and cannot spell ".." as a whole component
# without also failing the explicit equality check below, so there is no character
# sequence that climbs out of the tree and nothing left for a symlink check to add on top
# of. jit_bad_entry_file()/jit_entry_why() still run anyway: a transclusion target is
# refused by EXACTLY the rule an ordinary index row is refused by, not a second rule that
# could quietly drift from it.
# BEGIN, not a bare top-level assignment: an awk statement outside any block is a
# PATTERN with the implicit default action `{ print }` -- so `X = 3` at top level does
# not just set X, it adds a rule that prints the WHOLE input record, once per line, for
# every hook invocation from here on. Two bare assignments read as two such rules, which
# is exactly what made every fire double-print its own raw JSON payload before stdout
# ever reached the real END block (caught by tests/test-inject-mode.sh and friends,
# never by tests/test-transclusion-378.sh itself, since that suite only ever asserts
# what IS in the output rather than what else came before it).
BEGIN {
  JIT_TRANSCLUDE_DEPTH_MAX = 3
  JIT_TRANSCLUDE_TOTAL_MAX = 12
}
function jit_transclude_component_ok(s) {
  if (s == "" || s == "\056" || s == "\056\056") return 0
  if (substr(s, 1, 1) == "\056") return 0
  if (s ~ /[^A-Za-z0-9._-]/) return 0
  return 1
}
# Resolves "dimension/layer/file.md" to an absolute path under JIT_BASE, or sets
# jit_transclude_why and returns "". JIT_BASE arrives through ENVIRON -- exported by
# common.sh at the top of every hook -- and never through -v: a -v value has its escapes
# PROCESSED, and a checkout path can carry a backslash, or a newline that would be a fatal
# awk error raised before the program runs (the same reason JIT_BASE reaches this file
# that way already, at the top of this file where it is exported).
function jit_transclude_resolve(spec,   n, parts, dim, layer, file, dir, path, why) {
  jit_transclude_why = ""
  n = split(spec, parts, "/")
  if (n != 3) { jit_transclude_why = "not a dimension/layer/file.md path"; return "" }
  dim = parts[1]; layer = parts[2]; file = parts[3]
  if (!jit_transclude_component_ok(dim) || !jit_transclude_component_ok(layer) || !jit_transclude_component_ok(file) || file !~ /\.md$/) {
    jit_transclude_why = "not a dimension/layer/file.md path"
    return ""
  }
  dir = ENVIRON["JIT_BASE"] "/" dim "/" layer
  why = jit_bad_entry_file(file, dir)
  if (why == "") {
    path = dir "/" file
    why = jit_entry_why(path)
  }
  if (why != "") { jit_transclude_why = why; return "" }
  return path
}
# The transcluded file own --- frontmatter block, stripped before its body is spliced in
# (#378 judgment call 4). jit_entry_load() below leaves frontmatter INSIDE e["body"] on
# purpose for an ordinary full-mode fire -- that is pre-existing behaviour this fix does
# not touch -- but a transcluded file was never the row that matched, so its keywords:
# line means nothing to the reader it lands in front of.
function jit_transclude_strip_frontmatter(body,   lines, n, i, out, closed, first, ln) {
  n = split(body, lines, "\n")
  if (n == 0) return body
  # A CR-stripped COPY for the fence comparison only, never for what is kept -- the same
  # split jit_entry_load() already makes for the identical "---" test, so a target saved
  # with CRLF line endings (plausible on Windows before a checkout normalises it) is
  # still recognised as opening and closing frontmatter, and the CR itself is trimmed
  # from the comparison, never silently eaten out of a body line this function keeps.
  ln = lines[1]; sub(/\r$/, "", ln)
  if (ln != "---") return body
  closed = 0
  for (i = 2; i <= n; i++) {
    ln = lines[i]; sub(/\r$/, "", ln)
    if (ln == "---") { closed = 1; i++; break }
  }
  if (!closed) return body
  out = ""; first = 1
  for (; i <= n; i++) { out = out (first ? "" : "\n") lines[i]; first = 0 }
  return out
}
# The recursive expander. depth counts transclusions already nested at this point (0 for
# a fired entry own body); jit_transclude_total and jit_transclude_stack are reset ONCE,
# by jit_inject_text() before the first call, and shared across the whole recursion for
# one fire -- that is what makes the total a per-fire cap rather than a per-file one.
function jit_expand_transclusions(body, depth,   out, i, n, lines, first) {
  n = split(body, lines, "\n")
  out = ""; first = 1
  for (i = 1; i <= n; i++) {
    out = out (first ? "" : "\n") jit_transclude_expand_line(lines[i], depth)
    first = 0
  }
  return out
}
# One line at a time, so a fenced code block can be recognised and left alone regardless
# of what it quotes. Markdown fences are line-oriented, and every entry that quotes
# GitHub Actions YAML today (vendored-oss.md, about .github/workflows/oss-changelog.yml)
# does so inside one -- a "${{ github.sha }}" sitting on its own line inside a fence must
# never be read as this syntax, whether or not the "$" guard below would also have caught
# it. jit_infence is a whole-process flag on purpose: a fence opened on one call to this
# function must still read as open on the next, since the caller feeds it one body line
# at a time -- reset once per top-level fire, in jit_inject_text(), the same place the
# other two shared counters are reset.
function jit_transclude_expand_line(line, depth,   trimmed, out, i, n, start, endp, spec, path, tent, expanded, saved_infence) {
  trimmed = line
  sub(/^[[:space:]]+/, "", trimmed)
  if (trimmed ~ /^```/) { jit_infence = !jit_infence; return line }
  if (jit_infence) return line
  if (index(line, "{{") == 0) return line
  out = ""
  n = length(line)
  i = 1
  while (i <= n) {
    start = index(substr(line, i), "{{")
    if (start == 0) { out = out substr(line, i); break }
    start = i + start - 1
    out = out substr(line, i, start - i)
    # A "{{" immediately preceded by "$" is GitHub Actions syntax and is left completely
    # alone, brace and all -- the guard the issue itself suggests.
    if (start > 1 && substr(line, start - 1, 1) == "$") {
      out = out "{{"
      i = start + 2
      continue
    }
    endp = index(substr(line, start + 2), "}}")
    if (endp == 0) { out = out substr(line, start); break }
    endp = start + 2 + endp - 1
    spec = substr(line, start + 2, endp - (start + 2))
    gsub(/^[[:space:]]+/, "", spec)
    gsub(/[[:space:]]+$/, "", spec)
    i = endp + 2
    if (jit_transclude_total >= JIT_TRANSCLUDE_TOTAL_MAX) {
      out = out "{{" spec "}} [jit] transclusion refused: this fire already spliced in " JIT_TRANSCLUDE_TOTAL_MAX " file(s), so this one was left as a pointer"
      continue
    }
    if (depth >= JIT_TRANSCLUDE_DEPTH_MAX) {
      out = out "{{" spec "}} [jit] transclusion refused: nested " JIT_TRANSCLUDE_DEPTH_MAX " deep already, so this one was left as a pointer"
      continue
    }
    path = jit_transclude_resolve(spec)
    if (path == "") {
      out = out "{{" spec "}} [jit] transclusion refused: " jit_transclude_why
      continue
    }
    if (index(jit_transclude_stack, "\n" path "\n") > 0) {
      out = out "{{" spec "}} [jit] transclusion refused: this would include itself (a cycle)"
      continue
    }
    if (!jit_entry_load(path, "full", 1, tent)) {
      out = out "{{" spec "}} [jit] transclusion refused: " (tent["why"] != "" ? tent["why"] : "the entry file is empty")
      continue
    }
    jit_transclude_total++
    jit_transclude_stack = jit_transclude_stack path "\n"
    # jit_infence tracks fence-open/closed state ACROSS the whole recursive walk, and an
    # included file is its own self-contained document: an odd number of fence markers
    # left open inside IT must never bleed into the lines of whoever included it (review
    # finding, #378). Saved and forced closed before recursing in, restored to the
    # caller own state after -- never just reset to 0, because a transclusion that
    # itself sits INSIDE a fence in the parent (already inert, per the guard above) must
    # not come back open once this nested call returns.
    saved_infence = jit_infence
    jit_infence = 0
    expanded = jit_expand_transclusions(jit_transclude_strip_frontmatter(tent["body"]), depth + 1)
    jit_infence = saved_infence
    jit_transclude_stack = substr(jit_transclude_stack, 1, length(jit_transclude_stack) - length(path) - 1)
    out = out expanded
  }
  return out
}
# Fills e with title, desc, mode, body and two flags, and returns 1 when the file had
# anything in it at all. An unreadable or empty entry returns 0 and the caller stays
# silent, which is what it did before this existed.
#
# keepbody forces the body to be read whatever the mode says. Exactly one caller passes
# it: a tools rule that can REFUSE the call. See pre-tool-hook.sh for why.
function jit_entry_load(path, def, keepbody, e,   line, ln, nfm, want, ident, val, nread, r) {
  e["body"] = ""; e["title"] = ""; e["desc"] = ""
  e["mode"] = def; e["fm"] = 0; e["badmode"] = 0; e["read"] = 0; e["injseen"] = 0
  # PIN: the mode was decided by the ENTRY rather than inherited from the project
  # default. A caller that wants to know what would change if the project flipped needs
  # this and cannot derive it from mode alone -- when the default and the override agree,
  # the two are indistinguishable. Both reports got that wrong: an entry pinned to `full`
  # can never render as a summary, so listing it as "write a description: and you can
  # flip" sends an author to write a line nothing will ever read.
  e["pin"] = 0
  # e["why"] is the SECOND half of the return value: 0 with a reason is a row that could
  # not be honoured and must be refused out loud, 0 with no reason is an empty file and
  # has always been silence. Callers branch on it, so it is reset on every call -- ent is
  # reused across rows and a stale reason would refuse the next honest one.
  #
  # The guards are the ones jit_read_body() applies, reached through the single function
  # that holds them (#78, #97): a file-name column that is empty or names a directory is a
  # fatal i/o error inside END on one-true-awk, and the process carrying a block decision
  # then dies with no JSON on stdout. That is true of this getline exactly as it was of
  # that one, and this reader exists because summary mode stops at the closing ---.
  e["why"] = jit_entry_why(path)
  if (e["why"] != "") return 0
  nfm = 0; want = 1; nread = 0
  while ((r = (getline line < path)) > 0) {
    nread++
    e["read"] = 1
    if (want) e["body"] = e["body"] (nread == 1 ? "" : "\n") line
    ln = line
    sub(/\r$/, "", ln)
    if (ln == "---") {
      # Frontmatter opens on the FIRST line and nowhere else. jit_frontmatter() in the
      # bash half counts every `---` instead, which is fine for a file the rebuild
      # indexed but would let a markdown horizontal rule halfway down a body open a
      # block here -- and the entry would then read as having frontmatter, no
      # description, and nothing to inject. Being stricter here can only err towards
      # injecting the body, which is the direction that loses tokens rather than
      # knowledge.
      if (nfm == 0) {
        if (nread != 1) continue
        nfm = 1; e["fm"] = 1; continue
      }
      if (nfm == 1) {
        nfm = 2
        # Nothing past here is needed when only the summary is injected. This is the
        # read that a third TSV column was supposed to save.
        if (!keepbody && e["mode"] != "full") { e["body"] = ""; want = 0; break }
        continue
      }
      continue
    }
    if (nfm != 1) continue
    if (index(ln, ":") == 0) continue
    ident = substr(ln, 1, index(ln, ":") - 1)
    if (ident ~ /[^A-Za-z0-9_-]/) continue
    val = substr(ln, index(ln, ":") + 1)
    sub(/^[[:space:]]+/, "", val)
    sub(/[[:space:]]+$/, "", val)
    # The same wrapped-scalar rule jit_frontmatter() applies, and for the reason recorded
    # there: only a quote pair wrapping the WHOLE value is YAML quoting. A quote anywhere
    # else is data, and deleting it is #19.
    if (val ~ /^"[^"]*"$/) val = substr(val, 2, length(val) - 2)
    if (ident == "title") { if (e["title"] == "") e["title"] = val }
    else if (ident == "description") { if (e["desc"] == "") e["desc"] = val }
    else if (ident == "inject" && !e["injseen"]) {
      e["injseen"] = 1
      gsub(/[[:space:]]/, "", val)
      val = tolower(val)
      if (val == "summary" || val == "full") { e["mode"] = val; e["pin"] = 1 }
      else if (val != "") e["badmode"] = 1
    }
  }
  close(path)
  # getline < 0 is "could not open", which a row naming a deleted or renamed entry
  # produces, and it is indistinguishable from an EMPTY file unless it is asked. r is
  # whatever the LAST getline returned, so a summary-mode break leaves it > 0 and this is
  # only reached for a file that was read to the end -- which is the only place the answer
  # could have changed anyway.
  if (r < 0) { e["why"] = "the entry file could not be read"; return 0 }
  # Only what will actually be injected is checked, which in full mode is the whole body
  # and is therefore what jit_read_body() checked before this reader existed. Invalid
  # UTF-8 in a part of the file summary mode never reads cannot reach the JSON channel,
  # and refusing a row over bytes nothing emits would be a rule silently unenforced.
  if (jit_bad_utf8(e["body"] e["title"] e["desc"])) {
    e["why"] = "the entry file is not valid UTF-8"
    return 0
  }
  # A file with NO frontmatter has no description to inject and no inject: to honour --
  # and it also has no keywords:, no match: and no tool:, so rebuild-tsv.sh could not
  # have produced its index row. It reached the index by hand, there is nothing to
  # summarise, and its body is the entry. That is not a loophole an author can live in:
  # deleting the frontmatter to keep the whole body also unindexes the entry on the next
  # rebuild.
  if (!e["fm"]) { e["mode"] = "full"; e["pin"] = 1 }
  return e["read"]
}
# The VALUE is never echoed back. It is free text from a file that arrived with the
# repository, and naming the field is enough for the author who wrote it.
function jit_badmode_note(e) {
  if (!e["badmode"]) return ""
  return "\n[jit] The inject: value in this entry is not summary or full, so the project default applied."
}
# That notice is appended in BOTH modes, and the early return below used to skip it (#118).
# The contract published on issue #1 is that an unrecognised value "falls back to the
# project default and says so in what that entry injects". The fallback half held
# everywhere and the saying-so half held only under `summary` -- so on the path almost
# every tree is on, `full` being the default and nobody having configured anything, a typo
# by the author produced an entry that behaved exactly as if the line were never written.
# That is the defect shape this repository exists to name, inside the feature meant to give
# an author control: a value somebody typed, silently ignored, indistinguishable from a
# correct configuration.
#
# Said on every fire rather than once per session, and that is a considered dose rather
# than the cheap option. The notice rides the injection of the entry itself, which is
# already deduped per session in the paths and vocabulary dimensions and by `once` in
# tools -- so it can never be noisier than the entry it is attached to, and under `full` it
# is 94 bytes against a whole body. A separate once-per-session channel would need
# session state inside a function that has none, and would go quiet for exactly the
# sessions that resume or compact, where the agent reading the injection is not the one
# that read the notice. The refusal channels in the hooks report once per session because a
# refused row is a standing fact about the index; this is a property of the text of one
# entry, and it stops the moment somebody fixes the line.
#
# A refusal still never carries it: pre-tool-hook.sh builds a block reason from the body
# and not from this, and an entry that can refuse reads its body whatever the mode says, so
# a bad inject: changes nothing there to report.
function jit_inject_text(e, rel, selfpath,   out, tbody) {
  if (e["mode"] == "full") {
    # A file with NO frontmatter is pinned to full (see jit_entry_load() above), and
    # body is then the WHOLE FILE. A file of nothing but blank lines reads back as "\n"
    # or "\n\n", which is not "" -- so the guard the caller applies on the RETURN of this
    # function (content != "") passed it through, and an advisory rule with nothing to
    # say injected a header with nothing under it (#170). The comment beside that guard
    # already states its intent -- content == "" is what keeps an advisory rule with
    # nothing to say silent -- and this is that same intent, widened from the empty
    # string to whitespace, the same distinction #135 drew for the refusal substitute.
    #
    # REPORTED here, not silenced: going silent would make this indistinguishable from a
    # row that never matched at all, which is the defect class this whole project exists
    # to name (#170s own argument). It would also undo #165 one call site up, whose
    # header-bound test still expects a header for exactly this fixture -- silencing the
    # body would silence the header too, since the callers guard is on this return
    # value. Reporting keeps #165s decision intact and only fixes what #170 is about:
    # what is UNDER the header.
    #
    # Frontmatter, when present, is never whitespace-only (a title: or description:
    # line is not blank), so this can only fire for the no-frontmatter case #165 already
    # names -- an entry WITH frontmatter and a blank body still returns that body, however
    # short, because its author wrote something under the closing --- on purpose.
    # NON-empty whitespace, not empty. A truly empty file (one blank line, which reads
    # back as the empty string -- see jit_entry_load() above) already returns "" through
    # the line below, and the callers own guard (content != "") already keeps THAT case
    # silent, which is tested and deliberate (SECTION 8 of test-inject-mode.sh, "an
    # advisory rule with nothing to say injects nothing"). Matching the empty string here
    # too would report on a file that already behaved correctly, and is not what #170 is
    # about.
    if (e["body"] != "" && e["body"] ~ /^[[:space:]]*$/) return "[jit] The entry file has no text to inject." jit_badmode_note(e)
    # {{dimension/layer/file.md}} transclusion (#378), expanded here rather than at
    # rebuild time -- see the block above jit_transclude_resolve() for why. Skipped with
    # one cheap index() when the body carries no "{{" at all, which is every entry that
    # does not use this syntax -- the common case stays exactly as fast as it was.
    jit_transclude_total = 0
    jit_transclude_stack = (selfpath != "" ? "\n" selfpath "\n" : "\n")
    jit_infence = 0
    tbody = (index(e["body"], "{{") > 0) ? jit_expand_transclusions(e["body"], 0) : e["body"]
    return tbody jit_badmode_note(e)
  }
  out = ""
  if (e["title"] != "") out = jit_clip(e["title"], 160)
  if (e["desc"] != "") out = out (out == "" ? "" : "\n") jit_clip(e["desc"], 400)
  # Decided on issue #1 and worth restating where it is implemented: nothing is
  # auto-derived here. A generated summary of a wrong entry is a confident wrong summary,
  # and it removes the one moment where the author would have noticed. The absence is
  # said out loud instead -- a silently downgraded entry is an absence produced by the
  # tool, which is the failure this whole repository exists to name.
  else out = out (out == "" ? "" : "\n") "[jit] There is no description: in this entry, so a match can only name it. Add one and the next match will say what it holds."
  out = out jit_badmode_note(e)
  return out "\n[jit] Summary only -- read " rel " for the entry."
}
# For the log, which a person reads. `full` and `summary` and `summary with nothing to
# say` are three different outcomes and the middle one is the only cheap one.
#
# There is a FOURTH fact, and it is not one of those three: whether the mode was chosen or
# fallen back into (#130). A mistyped `inject:` leaves e["mode"] at the project default and
# only sets e["badmode"], so the entry rendered as `full` under the default nobody
# configures, and the log wrote `[full]` -- the same six bytes a correctly-written
# `inject: full` writes. jit_badmode_note() tells the MODEL, once, in context that ends with
# the session; hooks.log is the durable record and what jit-misses.sh reads, and it was
# reporting that the typo had not happened. An absence produced by the tool, in the log kept
# to find them.
#
# A SUFFIX on all three outcomes, not a fourth tag. The two facts are orthogonal -- which
# mode was rendered, and whether that mode was asked for -- and a project on
# JIT_CONTEXT_INJECT=summary is blind in exactly the same way with `[summary]`, which is the
# half #130 did not name. `[badmode]` alone would have thrown away the outcome; `:badmode`
# keeps it and reads the way `[summary:no-description]` already does, which is the precedent
# for a colon-qualified tag in this very function.
#
# The cost is that a reader grepping the literal `[full]` no longer sees these rows -- which
# is the point, since that reader is counting deliberate `full` entries and these are not
# any. A `[full` prefix catches both, and `badmode` is the tally that could not be taken
# before.
#
# The block path in pre-tool-hook.sh writes `[full:block]` and deliberately does NOT pass
# through here: a refusal reads the body whatever the mode says, so a bad `inject:` changes
# nothing it could report -- the same reasoning recorded above jit_inject_text().
function jit_inject_tag(e,   t) {
  if (e["mode"] == "full") t = "[full"
  else if (e["desc"] == "") t = "[summary:no-description"
  else t = "[summary"
  return t (e["badmode"] ? ":badmode" : "") "]"
}
'
# --- Shared Latin-1 accent fold ----------------------------------------------
# Prepended to any awk program that normalises text for vocabulary lookup, so the index
# writer and both matchers arrive at the same spelling.
#
# The strip that follows a fold maps every byte outside [a-z0-9 -] to a space, so without
# this an accent does not merely fail to match: it cuts the word in two. `détail` became
# the two tokens `d` and `tail` -- on the prompt side AND in the index, which is why an
# accented keyword matched an accented prompt by accident and an ASCII one never (#31).
# So the fold has to run on BOTH sides. rebuild-tsv.sh folds the keyword; pre-prompt-hook.sh
# and pre-tool-hook.sh fold their subject. Folding one side alone silently kills the rows
# that used to line up, which is a worse bug than the one it fixes.
#
# Latin-1 Supplement plus the two ligatures, and deliberately no further: folding beyond
# that is a much larger claim about languages nobody here has measured.
#
# The substitution is index() and substr(), not gsub(). Measured 2026-08-12 on awk version
# 20200816: gsub() with a multibyte character as its pattern decodes the SUBJECT, so a
# truncated sequence anywhere in the string raised `towc: multibyte conversion failure` --
# the #14 abort, in the function added to fix #14's other half. index()/substr() do not
# decode, and on a record carrying a lone 0xC3 the splice returns a non-match and keeps
# going. Verified byte-identical to the gsub form on well-formed French, German and
# Spanish input under both awk 20200816 and gawk 5.4.1.
#
# The table carries both cases and is applied AFTER tolower(), because one-true-awk's
# tolower() leaves a multibyte capital alone and gawk's does not.
#
# Split on "[ ]" and not " ": one-true-awk splits a one-character separator on newlines
# too, gawk does not, and this list has to mean the same thing on both.
#
# jit-misses.sh carries a byte-identical copy of the table, because it deliberately does
# not source this file (see its header). tests/test-jit-misses.sh asserts the two agree.
# shellcheck disable=SC2034
JIT_AWK_FOLD='
function jit_fold_latin1(s,   i, p, out) {
  if (_jit_fold_n == 0)
    _jit_fold_n = split("á a à a â a ä a ã a å a æ ae ç c é e è e ê e ë e í i ì i î i ï i ñ n " \
                        "ó o ò o ô o ö o õ o œ oe ß ss ú u ù u û u ü u ý y ÿ y " \
                        "Á a À a Â a Ä a Ã a Å a Æ ae Ç c É e È e Ê e Ë e Í i Ì i Î i Ï i Ñ n " \
                        "Ó o Ò o Ô o Ö o Õ o Œ oe Ú u Ù u Û u Ü u Ý y", _jit_fold_tr, "[ ]")
  for (i = 1; i + 1 <= _jit_fold_n; i += 2) {
    out = ""
    while ((p = index(s, _jit_fold_tr[i])) > 0) {
      out = out substr(s, 1, p - 1) _jit_fold_tr[i+1]
      s = substr(s, p + length(_jit_fold_tr[i]))
    }
    s = out s
  }
  return s
}
'
# shellcheck disable=SC2034
JIT_AWK_HEREDOC='
# --- Shared heredoc-body stripper (#432) -------------------------------------
# A `~` regex rule (and the plain `require:`/`forbid:` substring rules beside it in
# pre-tool-hook.sh) is tested against the WHOLE command text, `fold_full`, which is
# built from the raw, undecoded-of-heredocs `full_command`. A heredoc body is a
# PAYLOAD piped to whatever the operator line names, not a command -- a word inside it
# that a rule targets is data mentioning the word, not the command running it, and
# refusing on it is the same false-positive shape as issue #7 (a quoted argument
# mentioning a blocked verb), one syntax form over.
#
# jit_strip_heredoc_body() removes every heredoc BODY line -- and its own closing
# delimiter line -- from a command string, in place, while leaving the operator line
# itself untouched so a rule can still target whatever runs on that line. It is a
# state machine over newline-split lines, not a real shell parser: it tracks at most
# one open heredoc at a time and closes it on the first line that equals the
# delimiter (tab-stripped first when the operator was `<<-`).
#
# Guarded against a here-string (`<<<word` or a quoted `<<<word`), which is NOT a
# heredoc and opens no body: `<<<` differs from `<<DELIM` only by one more `<`, and a
# naive `<<` scan reads the third `<` as part of the operator, extracts the quoted
# word as a delimiter, and then finds no line that ever equals it -- silently
# swallowing every line for the rest of the command as if it were heredoc body. The
# guard prepends a single sentinel character to the line before matching and requires
# a NON-`<` character immediately before the `<<`, which a third `<` can never be, so
# `<<<` never opens.
#
# LOOKAHEAD, not a single-pass state machine (self-review finding, #432): the first cut
# of this function set in_heredoc the moment it saw a <<WORD-shaped operator and cleared
# it only on a later line equal to WORD -- so a false positive (the shape appearing
# inside an ordinary quoted string that is not a heredoc at all, e.g. echo "info:
# <<NOTICE follows") or a genuinely malformed/truncated command with no closing line
# left in_heredoc set for the REST OF THE STRING, silently dropping every command word
# after it from fold_full -- a forbid:/~/block rule blinded to a real rm -rf or git push
# --force sitting right after the false trigger, which is a worse failure than the one
# #432 reports: nothing was blocked and nothing said so. The same shape hid a
# CRLF-authored heredoc own real closing line from itself, since neither side of the
# comparison stripped a trailing CR.
#
# So this now looks AHEAD before committing to strip anything: an operator is only
# treated as opening a real heredoc when a later line, scanned forward from here,
# genuinely equals its delimiter (CR-trimmed on both sides, tab-stripped first for
# <<-). No such line anywhere in the rest of the command means no heredoc was ever
# opened by this text -- so nothing is stripped, and the operator line own text
# (<<NOTICE included) stays visible to whatever rule was going to see it anyway. A
# false positive on the operator regex can now only leave MORE of the command visible
# than a hand parser would, never less, which is the direction #432 already established
# is safe.
#
# NOT stripped when the operator line names a known interpreter (self-review finding):
# bash <<EOF / sh <<EOF / ssh host <<EOF / python3 <<EOF and the like pipe their
# heredoc BODY to something that executes it as code -- it is the command, not a
# payload, and the premise the rest of this function rests on ("a heredoc body is data,
# not a command") does not hold for this one class. Stripping it anyway would let
# bash <<EOF containing rm -rf / slip past a forbid: rm -rf row that correctly blocked a
# bare rm -rf /, which is a NEW bypass this fix must not introduce. jit_heredoc_
# targets_interpreter() is a denylist, the same posture the no-shell-writes-to-the-
# index.md rule already states out loud for this codebase: it does not try to be a
# general oracle for "does this command execute its stdin", it names the common,
# concretely-reported cases and leaves everything else alone -- a wrapper script this
# list has never heard of still gets its heredoc body stripped, exactly as before this
# paragraph, which is #432 own residual rather than a regression this fix introduces.
#
# The quote characters the delimiter may be wrapped in -- plus the backslash a
# backslash-DELIM operator uses to suppress expansion, the same job a quoted delimiter
# does -- are built from their codes (39, 34, 92) rather than typed literally, because
# this whole function lives inside a bash SINGLE-quoted string and a bare apostrophe
# here would close it early -- see jit_shown_flush() a little further down for the same
# rule stated about this file.
# #442: self-review found the lookahead above crosses two further false positives,
# both leaving stripping too aggressive in the UNSAFE direction (the invariant this
# function obeys: an imperfect stripper may only ever leave MORE text visible to a
# rule than a real shell parser would, never less):
#
#   1. A line that is entirely a shell comment can never open a real heredoc -- the
#      whole line, <<WORD included, is text the shell never executes -- yet the
#      operator regex has no comment awareness and matches one anyway (# <<EOF,
#      #442 second repro). Self-review while fixing #442 found the same gap for a
#      TRAILING comment on an otherwise real command line (true # <<EOF): the
#      shell never executes anything from an unquoted # to end of line either,
#      heredoc operator included. Both shapes are caught by the same scan, below,
#      rather than two separate checks -- a comment line is just the case where
#      the unquoted # is the very first character.
#
#   2. The operator scan has no quote tracking either, so echo "<<EOF" (#442 first
#      repro) reads as a real opener even though the <<EOF text sits inside an
#      ordinary double-quoted argument the shell never treats as a redirection at
#      all.
#
# jit_heredoc_opener_is_suppressed() answers both at once: scanning the characters
# BEFORE the matched << on this same line, it returns true the moment it finds
# either an UNQUOTED # (comment reached before the operator) or ends the scan with
# an odd (open) single- or double-quote state. A small state machine, not a
# parser, tracking at most one open quote kind at a time and mirroring real shell
# escaping: backslash escapes the next character outside quotes and inside double
# quotes, and does nothing special inside single quotes. Its only effect on the
# outcome is to turn a match into a non-match, i.e. to suppress stripping -- a
# wrong verdict in either direction can only leave this function at least as
# conservative as if the check were absent, never less.
#
# state0 is NOT always 0: reviewer finding on #442 -- a single-quoted argument can
# legitimately span several physical lines (an assignment opening a single quote on
# one line, closed only two lines later), and the quote it opens is still open on
# every line in between, including a line whose own <<WORD shape would otherwise
# read as a real operator. jit_heredoc_quote_states() below computes, once per call
# to jit_strip_heredoc_body(), the quote state carried INTO each line from every
# line before it, and that is what state0 is here -- this function itself still
# only looks at the one line it is handed.
function jit_heredoc_opener_is_suppressed(prefix, state0,    i, c, state, n, q1, q2, bs) {
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  bs = sprintf("%c", 92)
  state = state0
  n = length(prefix)
  for (i = 1; i <= n; i++) {
    c = substr(prefix, i, 1)
    if (state == 0) {
      if (c == q1) state = 1
      else if (c == q2) state = 2
      else if (c == "#") return 1
      else if (c == bs) i++
    } else if (state == 1) {
      if (c == q1) state = 0
    } else if (state == 2) {
      if (c == bs) i++
      else if (c == q2) state = 0
    }
  }
  return (state != 0)
}
# The exit state of ONE whole line, given the state it was entered with -- the building
# block jit_heredoc_quote_states() below calls once per line to chain them. A `#` only
# starts a comment (break, nothing after it on this line can change the state) when state
# is already 0 at the point it is reached; inside an open quote a `#` is literal text, the
# same posture jit_heredoc_opener_is_suppressed() above already takes.
function jit_heredoc_line_exit_state(line, state0,    i, c, len, q1, q2, bs, state) {
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  bs = sprintf("%c", 92)
  state = state0
  len = length(line)
  for (i = 1; i <= len; i++) {
    c = substr(line, i, 1)
    if (state == 0) {
      if (c == q1) state = 1
      else if (c == q2) state = 2
      else if (c == "#") break
      else if (c == bs) i++
    } else if (state == 1) {
      if (c == q1) state = 0
    } else if (state == 2) {
      if (c == bs) i++
      else if (c == q2) state = 0
    }
  }
  return state
}
# Fills in[i] (1-indexed) with the quote state the whole text carries INTO line i, by
# replaying every line before it through jit_heredoc_line_exit_state() in order. A plain
# forward pass, computed once per jit_strip_heredoc_body() call rather than per operator
# match, since it depends only on the lines before the one being tested, never on where
# a later match happens to land.
function jit_heredoc_quote_states(lines, n, qin,    i, state) {
  state = 0
  for (i = 1; i <= n; i++) {
    qin[i] = state
    state = jit_heredoc_line_exit_state(lines[i], state)
  }
}
# unconditional (default 0) exists ONLY for the require: check, whose own fail-open
# direction runs opposite to the direction forbid:/~/block need. MORE visible body
# text is the safe default for a deny-style rule (forbid:/~/block): it can only make
# such a rule MORE likely to correctly refuse, never less. require: is an
# allow-only-if-present rule, so the same extra visibility makes it MORE likely to
# be satisfied by inert payload text sitting in a heredoc body that was never a real
# argument at all -- the same fail-open shape, just reached through the opposite
# bias. Passing unconditional=1 strips a recognized heredoc body regardless of
# jit_heredoc_opener_is_known_sink(), so body text can never satisfy a require:
# column no matter what command it sits under; it does NOT skip the suppression
# checks above, since those answer a different question (is this text a real
# heredoc operator at all) that both callers need answered the same way.
# #447: jit_heredoc_opener_is_known_sink() used to be handed the WHOLE line, so a
# real sink elsewhere on the SAME line (a decoy cat/tee/gh command followed by ; or
# & and then bash <<EOF) made the allowlist match even though the heredoc actually
# belongs to a DIFFERENT, non-sink command on that same line -- including a sink
# decoy combined with the round-1 fake-arithmetic-opener shape, since binding the
# operator to its own clause makes the fake opener own clause the one with no sink
# in it either way. Binds the sink check to just the clause the operator sits in,
# bounded by the nearest ";" or "&" on either side (a lone "&" covers "&&" too, since
# each "&" character is itself a boundary). jit_heredoc_opener_has_danger_token()
# runs on that same clause now too -- more precise than the whole line, never less
# conservative, since a pipe or substitution in an UNRELATED earlier clause has
# nothing to do with this heredoc own command.
#
# Self-review finding: a bare scan for ";"/"&" is quote-UNAWARE, so a quoted ";" or
# "&" inside the heredoc operator own command (python3 -c "x=1; tee y" <<EOF) could
# forge a fake clause boundary and truncate the clause down to a substring (" tee y"
# <<EOF") that happens to satisfy the sink allowlist on its own -- reopening the exact
# bypass class this fix exists to close, just through a quoted separator instead of a
# bare one. state0 is the quote state carried INTO this physical line from every line
# before it (jit_heredoc_quote_states() own quote_in[i], the same value the opener
# suppression check already uses for a different question), since a quote can span
# more than one line; a ";"/"&" only ends a clause when the state AT that character,
# replaying the SAME escaping rules jit_heredoc_line_exit_state() already uses, is 0.
function jit_heredoc_clause_at(line, col, state0,    i, c, start, endp, len, state, instate, q1, q2, bs) {
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  bs = sprintf("%c", 92)
  len = length(line)
  state = state0
  for (i = 1; i <= len; i++) {
    instate[i] = state
    c = substr(line, i, 1)
    if (state == 0) {
      if (c == q1) state = 1
      else if (c == q2) state = 2
      else if (c == bs) { i++; instate[i] = -1 }
    } else if (state == 1) {
      if (c == q1) state = 0
    } else if (state == 2) {
      if (c == bs) { i++; instate[i] = -1 }
      else if (c == q2) state = 0
    }
  }
  start = 1
  for (i = col - 1; i >= 1; i--) {
    c = substr(line, i, 1)
    if ((c == ";" || c == "&") && instate[i] == 0) { start = i + 1; break }
  }
  endp = len
  for (i = col; i <= len; i++) {
    c = substr(line, i, 1)
    if ((c == ";" || c == "&") && instate[i] == 0) { endp = i - 1; break }
  }
  if (endp < start) return ""
  return substr(line, start, endp - start + 1)
}
# #447: the OLD closing-delimiter extraction kept only ONE optional quote or
# backslash character on each side of the bare identifier, so a delimiter bash
# itself builds by concatenating several quoted/escaped/bare pieces was read wrong
# -- a quote-then-bare-letters suffix, a bare dash-digit suffix, and a backslash
# mid-word all closed at the WRONG line for this stripper, either leaving a real
# sink own data visible (false block) or never finding a close at all. Replays
# bash own word-formation rule one character at a time: a bare run of ordinary
# characters, a single-quoted run, a double-quoted run (where a backslash-escaped
# double-quote, backslash, dollar or backtick collapses to the literal character),
# or a single backslash-escaped character outside quotes, concatenated with no
# gap, stopping at the first blank or shell word-ending character. start is the
# column of the first character of the word (i.e. right after the operator, its
# optional "-", and any blanks) -- not the operator itself.
function jit_heredoc_scan_word(line, start,    i, n, c, nc, state, word, bs, q1, q2, stopchars) {
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  bs = sprintf("%c", 92)
  stopchars = " \t" bs q1 q2 ";&|<>()"
  n = length(line)
  i = start
  state = 0
  word = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (state == 0) {
      if (c == q1) { state = 1; i++; continue }
      if (c == q2) { state = 2; i++; continue }
      if (c == bs) {
        if (i == n) break
        word = word substr(line, i + 1, 1)
        i += 2
        continue
      }
      if (index(stopchars, c) > 0) break
      word = word c
      i++
      continue
    }
    if (state == 1) {
      if (c == q1) { state = 0; i++; continue }
      word = word c
      i++
      continue
    }
    # state == 2: double-quoted -- only an escaped double-quote, backslash, dollar
    # or backtick collapses (bash own double-quote escape set); any other
    # backslash stays literal.
    if (c == q2) { state = 0; i++; continue }
    if (c == bs && i < n) {
      nc = substr(line, i + 1, 1)
      if (nc == q2 || nc == bs || nc == "$" || nc == "`") { word = word nc; i += 2; continue }
    }
    word = word c
    i++
  }
  return word
}
function jit_strip_heredoc_body(s, unconditional,    n, lines, i, j, out, strip_tabs, delim, line, rest, probed, word, prefix, close_i, quote_in, lt2, op_col, after_pos) {
  # #461: the heredoc operator is built from its character code, never typed. Once the
  # release build inlines this file into a hook, the directory validator reads a typed
  # double `<` here as a shell here-document it cannot close, and blocks the plugin.
  lt2 = sprintf("%c%c", 60, 60)
  n = split(s, lines, "\n")
  jit_heredoc_quote_states(lines, n, quote_in)
  out = ""
  i = 1
  while (i <= n) {
    line = lines[i]
    probed = " " line
    close_i = 0
    # Detection only -- deliberately loose, just "a non-< char followed by <<" -- the
    # ACCURATE word is computed below by jit_heredoc_scan_word(), never by trusting
    # how much of the operator this match happens to consume (#447).
    if (match(probed, "[^<]" lt2)) {
      prefix = substr(probed, 1, RSTART)
      if (!jit_heredoc_opener_is_suppressed(prefix, quote_in[i])) {
        op_col = RSTART
        after_pos = op_col + length(lt2)
        strip_tabs = (substr(line, after_pos, 1) == "-")
        if (strip_tabs) after_pos++
        while (substr(line, after_pos, 1) == " " || substr(line, after_pos, 1) == "\t") after_pos++
        word = jit_heredoc_scan_word(line, after_pos)
        if (word != "" && (unconditional || jit_heredoc_opener_is_known_sink(jit_heredoc_clause_at(line, op_col, quote_in[i])))) {
          delim = word
          for (j = i + 1; j <= n; j++) {
            rest = lines[j]
            sub(/\r$/, "", rest)
            if (strip_tabs) sub(/^\t+/, "", rest)
            if (rest == delim) { close_i = j; break }
          }
        }
      }
    }
    out = (out == "") ? line : out "\n" line
    if (close_i > 0) {
      # A genuine heredoc: everything from the line after the operator through its own
      # closing delimiter line is BODY (or the delimiter line itself), neither of which
      # is a command -- skip straight past it. The operator line above already went into
      # out.
      i = close_i + 1
    } else {
      i++
    }
  }
  return out
}
# ROUND 3 (coordinator review): this used to be jit_heredoc_targets_interpreter(), a
# DENYLIST of commands that execute their heredoc body as code (bash, sh, ssh, python3,
# source, eval, a dot-source special case for #442 repro 3, ...), not stripped for
# those so a forbid:/require:/~ rule could still see the body. That denylist is itself
# unbounded, and was the wrong side of this check to bound: it fails OPEN on anything
# it has never heard of, and two review rounds on this very issue each found one more
# way through it by construction, with no code change in between -- $SHELL <<EOF (the
# interactive shell named by an environment variable), perl5.30 <<EOF (a versioned
# perl binary), node18 <<EOF (a versioned node binary), awk -f - <<EOF (which can run
# arbitrary code via system()), "$0" <<EOF (the script re-invoking itself). Every one
# of those pipes its heredoc body to something that EXECUTES it, and every one was
# silently stripped and hidden from a block rule by the code this comment used to
# describe, purely because its literal spelling never matched a name on the list.
#
# Inverted instead of patched further: jit_heredoc_opener_is_known_sink() is an
# ALLOWLIST of commands whose stdin is DATA by construction -- cat/tee writing to a
# file, the supertool this repository ships its own writes through, git commit -F -,
# gh ... --body-file -/-F - -- and a heredoc body is stripped ONLY when the operator
# line matches one of them. Everything else, every interpreter old or new or
# never-yet-invented included, keeps its body visible by default. This is the
# direction the invariant this whole file obeys actually requires: the unbounded side
# of "strip or do not strip" has to default to "do not", because an allowlist that is
# too SHORT only means more commands keep their heredoc body visible -- safe, if
# noisier for issue #432 own motivating payload-is-not-a-command case -- while a
# denylist that is too SHORT means more commands silently LOSE theirs, which is the
# whole subject of issue #442. A command not on this list is not claimed to be safe
# to execute; it is simply not claimed to be a payload sink either, and the function
# answers only the question it is actually asked.
# Coordinator finding on round 3 itself: naming a command as a payload sink is not
# enough -- a sink on the operator line can still hand the SAME body to something
# that executes it, by piping the sink own stdout into an interpreter, or by command/
# process substitution reading the heredoc back as a command: cat <<EOF | bash, cat
# <<EOF 2>/dev/null | bash (the pipe is still there, a redirect earlier on the line
# does not change that), tee f <<EOF | sh, cat <<EOF >(bash) (>( is a PROCESS
# SUBSTITUTION, not the plain file redirect the cat rule above is written for -- it
# matches the bare > check in that rule too, which is exactly the hole), eval
# "$(cat <<EOF" / bash -c "$(cat <<EOF" (command substitution feeding the body text
# itself to a shell that runs it). None of a plain file write, tee, supertool, git
# commit -F - or gh --body-file - ever legitimately carries a |, a $(, a backtick, a
# >( or a <( on the SAME CLAUSE as the heredoc operator (#447: the argument this
# function receives is that clause, jit_heredoc_clause_at()s own return value, not
# necessarily the whole physical line any more), so their presence overrides the
# allowlist unconditionally rather than being named in each sink pattern one at a
# time -- the same posture as the comment/quote suppression above: a check that can
# only ever turn a match into a non-match, never the reverse.
function jit_heredoc_opener_has_danger_token(line) {
  if (index(line, "|") > 0) return 1
  if (index(line, "$(") > 0) return 1
  if (index(line, "`") > 0) return 1
  if (index(line, ">(") > 0) return 1
  if (index(line, "<(") > 0) return 1
  return 0
}
function jit_heredoc_opener_is_known_sink(line) {
  if (jit_heredoc_opener_has_danger_token(line)) return 0
  # cat writing to a file: the write target may be spelled before OR after the
  # heredoc operator in the same clause (cat > out <<EOF and cat <<EOF > out are
  # both ordinary bash), so this checks the whole clause (#447: the caller now hands
  # this the operator own clause, not necessarily the whole physical line) for a >
  # rather than just the text before the operator.
  if (line ~ /(^|[;&|])[ \t]*cat([ \t]|$)/ && line ~ />/) return 1
  # tee always takes its target as a plain argument, never a redirect.
  if (line ~ /(^|[;&|])[ \t]*tee[ \t]+[^ \t;&|\n]/) return 1
  if (line ~ /(^|[;&|])[ \t]*(\.\/)?supertool([ \t]|$)/) return 1
  if (line ~ /(^|[;&|])[ \t]*git[ \t]+commit([ \t]|$)/ && line ~ /(^|[ \t])(-F|--file)[ \t]*-([ \t]|$)/) return 1
  if (line ~ /(^|[;&|])[ \t]*gh([ \t]|$)/ && line ~ /(^|[ \t])(--body-file|-F)[ \t]*-([ \t]|$)/) return 1
  return 0
}
'
# shellcheck disable=SC2034
JIT_AWK_JSON='
function jit_trailing_backslashes(s,   c, n) {
  n = length(s); c = 0
  while (c < n && substr(s, n - c, 1) == "\134") c++
  return c
}
function jit_json_fields(s, raw, fs, fe,   n, i, k) {
  n = split(s, raw, "\042")
  k = 1
  fs[1] = 1
  for (i = 1; i < n; i++) {
    # An odd number of trailing backslashes means the quote that follows was escaped, so
    # it is content and not a delimiter: the field runs on. The backslash stays put and
    # jit_unescape() collapses the pair when the field is finally materialised.
    if (jit_trailing_backslashes(raw[i]) % 2 == 1) continue
    fe[k] = i
    k++
    fs[k] = i + 1
  }
  fe[k] = n
  return k
}
# jit_hook_fields() walks the same logical fields jit_json_fields() produced, but
# structurally rather than positionally (#426). The old dispatch loops in
# pre-tool-hook.sh/pre-path-hook.sh/post-tool-hook.sh treated EVERY single-piece quoted
# field at an even logical index as a candidate key and read whatever quoted field
# followed two positions later as its value -- no check that the field actually sat at
# key position, no check of which object it was inside. A tool_input STRING VALUE equal
# to tool_name, command, file_path, pattern, skill or subagent_type could therefore
# repoint the field it named, last-wins, at whatever quoted string happened to follow --
# including tool_use_id, defeating every mode: block/require/forbid rule.
#
# Two structural checks close that. A string is a key only when the raw piece right
# after its closing quote begins, after optional whitespace, with a colon --
# jit_stop_hook_active() below already relies on exactly this check for
# stop_hook_active. And brace depth is tracked over the STRUCTURAL (odd-logical-index)
# fields, which are always ONE physical raw piece -- only quoted content can span an
# escaped quote, so only even indices ever do -- never over quoted content itself. TOP
# is populated from keys read at depth 1, the top level of the whole payload; TI is
# populated from keys read directly inside the top-level tool_input object and nowhere
# deeper. A tool_input value that merely spells a wanted key name is read at the wrong
# depth, is not followed by a colon, or both -- it is never assigned to TOP or TI.
#
# top_wanted/ti_wanted are caller-built membership arrays (name -> 1); only names
# present there are ever looked up. First occurrence wins for every field, the same
# shape jit_session_key() below already uses, and for the same reason given there: the
# runner-written value should never lose to a string an untrusted tool_input carries
# later in the payload.
function jit_hook_fields(raw, fs, fe, n, top_wanted, ti_wanted, TOP, TI,   depth, ti_depth, pending_ident, pending_key_depth, i, c, ch, txt, val, nxt, is_ident) {
  depth = 0
  ti_depth = -1
  pending_ident = ""
  pending_key_depth = -1
  for (i = 1; i <= n; i++) {
    if (i % 2 == 1) {
      txt = raw[fs[i]]
      for (c = 1; c <= length(txt); c++) {
        ch = substr(txt, c, 1)
        if (ch == "{") {
          depth++
          # #426 self-review finding: pending_ident alone names WHICH key precedes this
          # brace, not WHERE that key itself sat. Without pending_key_depth == 1 here,
          # any earlier key spelled "tool_input" at ANY depth -- nested three objects
          # deep, say -- would lock ti_depth onto ITS value object, and first-wins would
          # then silently discard the real top-level tool_input for every name the
          # impostor also claims. Only a "tool_input" key read while depth was still 1
          # (before this open brace bumps it) is the genuine top-level one.
          if (pending_ident == "tool_input" && pending_key_depth == 1 && ti_depth == -1) ti_depth = depth
        } else if (ch == "}") {
          if (depth == ti_depth) ti_depth = -1
          depth--
        }
      }
      continue
    }
    # A field spanning several raw pieces -- an escaped quote inside it -- is never a
    # bare key name this loop wants and can never BE the pending key either -- the same
    # single-piece guard every dispatch loop in this file already used.
    if (fs[i] != fe[i]) { pending_ident = ""; pending_key_depth = -1; continue }
    val = raw[fs[i]]
    is_ident = 0
    if (i + 1 <= n) {
      nxt = raw[fs[i+1]]
      if (nxt ~ /^[[:space:]]*:/) is_ident = 1
    }
    if (!is_ident) { pending_ident = ""; pending_key_depth = -1; continue }
    pending_ident = val
    pending_key_depth = depth
    # The VALUE field i+2 may itself span several raw pieces -- a command carrying an
    # escaped quote, or a Write payload own file body -- and jit_field() already
    # reassembles a RANGE, so it is read over the full [fs[i+2], fe[i+2]] range rather
    # than requiring it be single-piece too. Only the KEY (field i, checked above) has
    # to be one bare piece; a spoofed key candidate that itself spans an escaped quote
    # was already rejected by that same guard before reaching this point.
    if (i + 2 > n) continue
    if (depth == 1) {
      if ((val in top_wanted) && !(val in TOP)) TOP[val] = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    } else if (depth == ti_depth) {
      if ((val in ti_wanted) && !(val in TI)) TI[val] = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    }
  }
}
# --- Session identity, for the once-per-session markers ---------------------
# Read here rather than in bash because the payload is already being parsed: a second awk
# process per hook to fetch one field would cost more than every check in this file.
#
# The value becomes a FILE NAME concatenated onto a directory, and it arrives in JSON that
# a stranger runner writes -- so it is a bare-name check of the same family as
# jit_bad_entry_file(): anything outside [A-Za-z0-9_-] is not a session id, it is a path
# fragment, and a field spanning an escaped quote is not one either. Refused means NO
# marker, never a sanitised guess at what was meant.
#
# The first session_id in the payload wins. The scan is flat, so a nested tool_input value
# could carry the string too -- first-wins keeps the field the runner itself wrote, which
# Claude Code puts at the top level, ahead of anything a command line spells.
function jit_session_key(raw, fs, fe, n,   i, k) {
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "session_id") continue
    if (fs[i+2] != fe[i+2]) return ""
    k = raw[fs[i+2]]
    if (k == "" || length(k) > 64) return ""
    if (k ~ /[^A-Za-z0-9_-]/) return ""
    return k
  }
  return ""
}
# --- Agent identity, for once-mode per-agent dedup (#394) -------------------
# `once` used to mean once per session_id -- and a spawned agent inherits the parent
# session_id (measured: same session_id on a main lane and on every Explore/developer
# spawn it launches). One shown set for the whole session meant the first agent to trip
# a once rule spent it for every agent behind it, silently -- exactly the failure this
# plugin exists to name, reproduced in its own dedup.
#
# transcript_path is the field that actually varies per reader: a main session own hook
# payload names its own session-uuid.jsonl, and a spawned agent payload names its OWN
# transcript under subagents/agent-hexid.jsonl -- verified against real transcripts on
# disk, both shapes, not assumed from documentation. For the main session the basename
# IS the session_id, so once keeps its exact old behaviour there; only a spawn own
# marker file moves.
#
# Same bare-name discipline as jit_session_key() above, because this value becomes a
# marker FILE NAME too: anything outside [A-Za-z0-9_-], over 64 bytes, or spanning an
# escaped quote is refused -- NO marker, never a sanitised guess. A `.jsonl` suffix is
# stripped first (both shapes carry it); a `/` or `\` separator is stripped down to the
# basename first (a Windows transcript path uses `\`, a POSIX one never contains one in
# a real path), so directory content ahead of the basename plays no part in the check.
function jit_agent_key(raw, fs, fe, n,   i, v, base) {
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "transcript_path") continue
    if (fs[i+2] != fe[i+2]) return ""
    v = raw[fs[i+2]]
    if (v == "") return ""
    base = v
    gsub(/.*[\/\\]/, "", base)
    sub(/\.jsonl$/, "", base)
    if (base == "" || length(base) > 64) return ""
    if (base ~ /[^A-Za-z0-9_-]/) return ""
    return base
  }
  return ""
}
# --- Stop/SubagentStop re-entry guard (#279) ---------------------------------
# The harness re-invokes a Stop hook whose own output (additionalContext) blocked the
# turn from ending, and marks that re-entry with "stop_hook_active":true in the same
# payload -- a JSON boolean, never wrapped in quotes, so it cannot be read by
# jit_session_key() quoted-value logic above. A hook that never checks this field
# cannot tell its own re-entry from a first stop and re-emits the same
# additionalContext every time, which is exactly what re-triggers it: nine straight
# re-entries in one live session before the harness overrode the block (#279).
#
# The key field itself is still quoted ("stop_hook_active"), so it lands as its own
# entry in raw/fs/fe exactly as "session_id" does. The BOOLEAN that follows it is not
# quoted, so it never gets a field of its own -- it sits in the raw segment
# immediately after the key closing quote, still carrying the leading ":" and
# whatever trails it up to the next quote character (a comma, a closing brace, or the
# next key opening quote). Matched as a prefix on that segment rather than parsed as
# its own field, which is why this reads fe[i]+1 directly instead of looking for a
# paired value field the way jit_session_key() does.
#
# NO fe[i]+1-vs-n bound check here, and that omission is deliberate, not an
# oversight: n is jit_json_fields() own LOGICAL field count (its own k), but fe[]
# stores PHYSICAL raw[] positions, and the two only coincide when nothing earlier in
# the payload merged raw segments across an escaped quote. Any earlier field that
# does (an escaped quote inside cwd, transcript_path, or any string ahead of this
# key) leaves physical positions running past the logical count, so a bound check
# against n refuses a raw[] index that is genuinely still in range and reads a
# real true value as false -- the exact re-entry bug this function exists to close,
# reintroduced by the guard meant to protect it. Referencing raw[fe[i]+1] past the
# end of the array is not unsafe in awk: an unset numeric index reads back as the
# empty string, which the regex below simply fails to match.
function jit_stop_hook_active(raw, fs, fe, n,   i) {
  for (i = 2; i <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "stop_hook_active") continue
    return (raw[fe[i] + 1] ~ /^[[:space:]]*:[[:space:]]*true/) ? 1 : 0
  }
  return 0
}
# "" means this run keeps its shown set in memory only: it still dedups within the one
# invocation, and forgets at exit. Every read and write of the set goes through the
# functions below, so the empty case is handled in one place rather than at nine.
function jit_shown_file(dir, kind, raw, fs, fe, n,   k) {
  return jit_shown_path(dir, kind, jit_session_key(raw, fs, fe, n))
}
# The per-agent sibling (#394): same shape, keyed on jit_agent_key() instead. Used ONLY
# by pre-tool-hook.sh, for once-mode dedup -- the vocab/bytes shown_file above stays
# session-keyed and is still written to on every delivery, so the Stop hook own byte
# accounting (#389, which reads back "vocab-shown-$SESSION_ID.txt" and nothing else) is
# untouched. This is a SECOND marker a once row is also written into, not a
# replacement for the first.
#
# #398: jit_agent_key() returns empty for a payload with no usable transcript_path -- a
# hand-run hook, or a host that does not supply the field. #394 left that case with no
# key and therefore no marker at all, so a once row degraded to firing on every call
# and its session-wide mark (jit_shown_mark below) grew by one line per call for the
# life of the session, unbounded. That is worse than v0.9.0, which deduped those same
# calls on session_id.
#
# So this falls back to jit_session_key() here, and only here: when the reader cannot
# be told apart from its session, dedup on the session instead of not at all. This
# restores exactly v0.9.0 behaviour for that host -- session-keyed, single mark, fires
# once -- and is a regression against the per-agent isolation #394 built only in the
# narrow intersection of a host missing transcript_path, a multi-agent run, and an
# author who opted a rule into once -- measured at #394 own filing to have zero real
# adopters. Weighed against that: the alternative shipped by #394 was unconditional, on
# every such host, whether or not it ever spawns an agent. A host that DOES supply
# transcript_path -- every real Claude Code CLI and Agent SDK invocation, per the hooks
# reference, which documents transcript_path as one of the fields every hook receives
# -- never reaches this branch at all, so the per-agent isolation #394 built is
# untouched on the path that is actually exercised in practice.
function jit_agent_shown_file(dir, kind, raw, fs, fe, n,   k) {
  k = jit_agent_key(raw, fs, fe, n)
  if (k == "") k = jit_session_key(raw, fs, fe, n)
  return jit_shown_path(dir, kind, k)
}
# The name, built from a key the caller already has. Split out because pre-path-hook.sh
# runs a SECOND awk pass for its Bash path candidates -- the payload is parsed once, in
# the first pass, and the second one is handed the key rather than the JSON. One format
# string, so the two passes cannot drift into writing two different marker files for one
# session, which would cost the dedup silently.
function jit_shown_path(dir, kind, k) {
  if (dir == "" || k == "") return ""
  return dir "/" kind "-shown-" k ".txt"
}
# No close(). getline itself is safe -- an unopenable path returns -1 and a path that opens
# but cannot be read returns 0 -- but one-true-awk raises a FATAL i/o error from close() on,
# say, a directory, and raises it again at program exit if the close is dropped. Dropping it
# is still worth doing: the diagnostic then arrives after every print has been flushed rather
# than instead of them. The state-directory sweep in bash is what stops it arriving at all;
# this is the second layer, and neither one costs a fork.
#
# Nothing re-reads a marker inside one invocation, so no handle needs freeing: the process is
# about to exit.
#
# #394: that "nothing re-reads" was a real invariant, not just an unused capability -- a
# SECOND call on the SAME path returns 0 immediately rather than reopening it, because
# one-true-awk keeps the getline file handle positioned at EOF from the first read and
# this function never closes it (the paragraph above is why). Driven: loading a file
# into a second array right after loading it into a first came back empty, silently, no
# awk error at all. A caller that needs the same lines in two arrays copies the first
# result rather than calling this twice -- see pre-tool-hook.sh, where shown_file and
# agent_shown_file are the identical path for a main (non-spawned) session.
function jit_shown_load(file, set,   line) {
  if (file == "") return
  while ((getline line < file) > 0) set[line] = 1
}
# Accumulated, never written. `print key >> file` is fatal when the path will not open, and
# it is fatal inside END -- taking the injection, the block decision and the log line with
# it, and printing an awk diagnostic into a stranger session (#50). It also followed a
# symbolic link, because awk cannot lstat (#49). Both belong to bash now: jit_shown_flush()
# hands these lines to the hook temp channel and jit_shown_apply() in the shell does the
# append, behind a `[ -L ]` and a `2>/dev/null` that awk has no way to write.
function jit_shown_mark(file, ident) {
  if (file == "") return
  JIT_MARKS = JIT_MARKS file "\t" ident "\n"
}
function jit_loc_key(dim, layer, file) {
  return "loc:" dim ":" layer ":" file
}
# Called once, BEFORE the hook writes its log line to the same file. The order is the whole
# of the #65 fix and it is not cosmetic: the log line ends with a payload-derived field, so
# anything written after it can be forged with a newline. Marks first, then a sentinel line,
# then the log line -- payload bytes can only ever land downstream of the boundary. bash
# stops at the first sentinel, so a payload that spells one out achieves nothing.
#
# The sentinel is written even when there is nothing to mark: its ABSENCE is what tells
# jit_marks_read() the channel is malformed, so it has to be unconditional. In awk, `>`
# truncates on the first write to a name and appends thereafter, so this may run first.
#
# A second temp file would be a second create and unlink on a path budgeted at 30-110 ms.
#
# No apostrophes in this block. It is a single-quoted bash string and one would close it.
function jit_shown_flush(out) {
  printf "%s%s\n", JIT_MARKS, ENVIRON["JIT_MARK_END"] > out
}
function jit_field(raw, a, b,   o, i) {
  if (a == "" || b == "" || a > b) return ""
  if (a == b) return raw[a]
  o = raw[a]
  for (i = a + 1; i <= b; i++) o = o "\042" raw[i]
  return o
}
function jit_unescape(s,   n, i, c, nx, o) {
  if (index(s, "\134") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\134" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") o = o "\n"
    else if (nx == "t") o = o "\t"
    else if (nx == "r") o = o "\r"
    else if (nx == "b") o = o "\b"
    else if (nx == "f") o = o "\f"
    else if (nx == "\042") o = o "\042"
    else if (nx == "/") o = o "/"
    else if (nx == "\134") o = o "\134"
    else { o = o c nx; i++; continue }
    i++
  }
  return o
}
'
# --- Building the byte-length manifest, shared by all three hooks (#219, #230) ----------
#
# #219 gave pre-prompt-hook.sh a way to join its own blocks so a consumer can walk them by
# byte count instead of searching the joined text for "\n---\n" -- a separator an entry
# body can forge, since .claude/jit-context/ is attacker-controlled input. #230 is that
# pre-tool-hook.sh and pre-path-hook.sh never grew the same producer: they still join with
# the bare "\n---\n" pre-prompt-hook.sh itself joined with before #219, so the forgery
# class #219 closed for the prompt dimension stayed open for the tool and path dimensions,
# via the same fallback splitter in jit_split_ctx_blocks() below.
#
# This is that producer, factored out so a third hand-rolled copy in pre-tool-hook.sh and
# pre-path-hook.sh cannot drift the way a second copy already drifted once -- report_hook()
# carried the pre-#219 grep, unfixed, through #223. All three hooks now build their block
# list the same way pre-prompt-hook.sh always did: append a real match with `nblk++; blk[nblk]
# = text`, prepend a refusal/layer/config notice with jit_blk_prepend(), and assemble the
# final additionalContext with jit_blk_join() once the whole scan is done. jit_blk_join()
# returns "" when nblk is 0, which every caller already reads as "print {} instead."
#
# nblk/blk[] are plain awk globals, uninitialised (0/empty) at the start of every END
# block by awk's own rules -- no explicit reset needed before the first `nblk++`.
#
# Consumed by the hook awk programs (pre-prompt-hook.sh, pre-tool-hook.sh,
# pre-path-hook.sh), which shellcheck cannot see -- same reason every other JIT_AWK_*
# variable above carries this directive.
# shellcheck disable=SC2034
JIT_AWK_BLK_BUILD='
function jit_blk_prepend(text,   i) {
  for (i = nblk; i >= 1; i--) blk[i + 1] = blk[i]
  blk[1] = text
  nblk++
}
function jit_blk_join(   bi, out, manifest) {
  if (nblk == 0) return ""
  manifest = "# JIT-CTX-BLOCKS " nblk
  out = ""
  for (bi = 1; bi <= nblk; bi++) {
    manifest = manifest " " length(blk[bi])
    out = (out == "") ? blk[bi] : out "\n---\n" blk[bi]
  }
  return manifest "\n" out
}
'
# --- Splitting additionalContext into blocks without trusting its own separator (#219,
#     #223) -------------------------------------------------------------------------------
#
# Two callers walk a hook decoded additionalContext looking for the blocks it joined:
# jit-match.sh (pre-prompt-hook.sh only, so it only ever sees "# Vocabulary: " headers) and
# jit-dry-run.sh report_hook() (all three hooks, so it sees "# JIT Context: " too). Both
# used to search the text for "\n---\n" -- the literal bytes pre-prompt-hook.sh and
# pre-tool-hook.sh/pre-path-hook.sh join blocks with -- and .claude/jit-context/ is
# attacker-controlled input (paths/00-manual/hooks.md): an entry whose own body quotes that
# same five-plus-header-byte sequence verbatim is indistinguishable, by any property of the
# surrounding text, from a genuine join. #219 closed this for jit-match.sh alone by having
# it trust a manifest line the hook now prepends -- "# JIT-CTX-BLOCKS <n> <len1> <len2> ...",
# built entirely from length() over each block own bytes and therefore not forgeable from an
# entry body -- and walk the rest of the string by BYTE COUNT instead of searching it. #223
# is jit-dry-run.sh report_hook() carrying the pre-#219 grep, unfixed, so a tricky.md whose
# body quoted a forged block header was reported as a real match at exit 0.
#
# This is that same walk, moved here so a THIRD copy cannot drift the way the second one did.
# Fills jit_blk_n and jit_blk_body[1..jit_blk_n]; sets jit_blk_manifest_ok to 1 when the
# manifest verified (every block accounted for, no negative or overrunning length, no
# trailing bytes after the last one) and 0 when it fell back to the heuristic splitter below
# -- absent manifest, malformed header, or a length that does not add up. None of that should
# happen from either hook, which are the only backends either caller ever shells out to, but
# degrading to the pre-#219 splitter on a malformed manifest is the correct failure mode
# rather than misreading one (see jit-match.sh own header comment for the fuller argument).
#
# The fallback recognises EITHER "# Vocabulary: " or "# JIT Context: " as a block-opening
# header -- jit-match.sh only ever sees the first, report_hook() sees both -- so one function
# serves both callers rather than the vocabulary-only shape the original carried.
#
# jit_decode_u00() used to live here as a SECOND pass over the string, run after
# jit_unescape() had already turned every escaped backslash back into a literal one --
# and that ordering is #226. Once the escaping is gone, an entry body carrying the
# literal six-byte ASCII text (ordinary prose about JSON escaping -- the
# encoder escapes the body's own backslash to two backslash characters on the wire, and
# jit_unescape() collapses that pair straight back to one, landing on the same six bytes
# a genuine encoder-emitted ESC escape lands on) is byte-identical to that genuine
# escape at this point: jit_unescape() never touches u-escapes at all, so a real escape
# survives its own pass unchanged. Nothing left in the string can tell the two apart,
# because the fact that distinguished them -- whether the leading backslash was itself
# escaped -- is exactly what the first pass discarded. jit_decode_u00() then collapsed
# the prose's six bytes down to one exactly as it would a genuine escape, shrinking the
# block by five bytes and desyncing it from the hook's own byte-length manifest
# (computed on the PRE-escape bytes, which still count all six) -- falling back to the
# pre-#219/#223 heuristic splitter an entry body can forge. Reproduced against the
# shipped tricky.md fixture from tests/test-block-framing.sh plus one added line of
# ordinary prose containing that six-byte sequence, on all three awk engines this
# repository tests against.
#
# jit_unescape_blocks() below is jit_unescape() and jit_decode_u00() fused into ONE
# left-to-right walk, the shape jit_unescape() already used for its two-letter escapes.
# It cannot make this mistake: when it sees an escaped backslash, it consumes BOTH
# bytes as a single literal backslash and moves on, so the letters that follow are
# scanned as plain, unescaped prose one byte at a time and never presented to the
# u00-escape branch as a fresh candidate to decode. A genuine u00-escape -- never
# preceded by an escaping backslash of its own, because the encoder never emits one
# before it -- is still the very next thing this walk sees when it reaches a bare
# backslash followed by "u00", and decodes exactly as jit_decode_u00() did. Moved here
# (from jit-match.sh, where the un-fused pair was the only caller until #223) for the
# reason the comment above jit_split_ctx_blocks() already gives: report_hook() needs
# the identical reversal before it can trust a block header, and a second copy is what
# let the ordering drift in the first place.
#
# jit_unescape() (above, in JIT_AWK_JSON) is UNCHANGED and still the right function for
# every other field this codebase decodes (prompt, command, file_path, ...): those are
# CLIENT-built fields this codebase's own encoders never emit u-escapes for, so folding
# that branch into the shared function would risk decoding one a client legitimately
# sent as literal text. Only additionalContext and reason -- built by THIS codebase's
# own jit_json_escape() -- get the fused decode, through this function instead.
# shellcheck disable=SC2034
JIT_AWK_BLOCKS='
function jit_unescape_blocks(s,   n, i, c, nx, hx, v, o) {
  if (index(s, "\134") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\134" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") { o = o "\n"; i++; continue }
    if (nx == "t") { o = o "\t"; i++; continue }
    if (nx == "r") { o = o "\r"; i++; continue }
    if (nx == "b") { o = o "\b"; i++; continue }
    if (nx == "f") { o = o "\f"; i++; continue }
    if (nx == "\042") { o = o "\042"; i++; continue }
    if (nx == "/") { o = o "/"; i++; continue }
    if (nx == "\134") { o = o "\134"; i++; continue }
    # v <= 31 is not a style choice, it is the whole fix for a defect an auditor found
    # in the predecessor of this function during #223 review. The encoder
    # (jit_json_escape() in each hook) only ever WRITES this shape for k in 0..31
    # excluding 9/10/13, which get two-letter escapes instead -- so codepoints 32 and
    # above can never be a genuine escape this codebase produced, and are left as text.
    if (nx == "u" && substr(s, i, 6) ~ /^\\u00[0-9a-fA-F][0-9a-fA-F]$/) {
      hx = tolower(substr(s, i + 4, 2))
      v = index("0123456789abcdef", substr(hx, 1, 1)) - 1
      v = v * 16 + index("0123456789abcdef", substr(hx, 2, 1)) - 1
      if (v <= 31) { o = o sprintf("%c", v); i += 5; continue }
    }
    o = o c nx; i++; continue
  }
  return o
}
function jit_split_ctx_blocks(ctx,   nl_pos, header, body_rest, hn, hf, declared_n, pos, bi, blen, rest, p1, p2, p) {
  jit_blk_n = 0
  jit_blk_manifest_ok = 0
  # jit_blk_manifest_seen (the flag this comment used to describe) is gone as of #230:
  # it existed only because pre-tool-hook.sh and pre-path-hook.sh never built a manifest
  # at all, so a consumer gating its exit code on jit_blk_manifest_ok alone would have
  # reported every genuine tool/path match as "could not evaluate" (#227). Now that all
  # three hooks build one whenever they have anything to inject (#230), that state is
  # unreachable from a real hook: additionalContext is only ever non-empty when a block
  # was appended, and appending a block is exactly what prepends this manifest. Both
  # consumers (jit-match.sh, jit-dry-run.sh report_hook()) gate on jit_blk_manifest_ok
  # alone now.
  delete jit_blk_body
  if (substr(ctx, 1, 17) == "# JIT-CTX-BLOCKS ") {
    nl_pos = index(ctx, "\n")
    if (nl_pos > 0) {
      header = substr(ctx, 1, nl_pos - 1)
      body_rest = substr(ctx, nl_pos + 1)
      hn = split(header, hf, " ")
      declared_n = hf[3] + 0
      if (hn == 3 + declared_n && declared_n >= 0 && hf[1] == "#" && hf[2] == "JIT-CTX-BLOCKS") {
        jit_blk_manifest_ok = 1
        pos = 1
        for (bi = 1; bi <= declared_n; bi++) {
          blen = hf[3 + bi] + 0
          if (blen < 0 || pos + blen - 1 > length(body_rest)) { jit_blk_manifest_ok = 0; break }
          jit_blk_body[bi] = substr(body_rest, pos, blen)
          pos += blen
          if (bi < declared_n) {
            if (substr(body_rest, pos, 5) != "\n---\n") { jit_blk_manifest_ok = 0; break }
            pos += 5
          }
        }
        if (jit_blk_manifest_ok && pos - 1 != length(body_rest)) jit_blk_manifest_ok = 0
        if (jit_blk_manifest_ok) jit_blk_n = declared_n
      }
    }
  }
  if (!jit_blk_manifest_ok) {
    rest = ctx
    jit_blk_n = 0
    while (1) {
      p1 = index(rest, "\n---\n# Vocabulary: ")
      p2 = index(rest, "\n---\n# JIT Context: ")
      if (p1 == 0 && p2 == 0) { jit_blk_n++; jit_blk_body[jit_blk_n] = rest; break }
      if (p1 == 0) p = p2
      else if (p2 == 0) p = p1
      else p = (p1 < p2) ? p1 : p2
      jit_blk_n++
      jit_blk_body[jit_blk_n] = substr(rest, 1, p - 1)
      rest = substr(rest, p + 5)
    }
  }
}
'
# --- The output envelope, built in one place (#252) --------------------------------
#
# Today three hooks each hand-roll one of three JSON shapes with a `printf` inside
# their own `END` block: pre-tool-hook.sh's block/inject/empty at its own printf
# sites, pre-prompt-hook.sh's and pre-path-hook.sh's inject/empty. Every one of those
# calls jit_json_escape() (defined per-hook, not shared -- a separate cleanup this
# issue does not attempt) on its own text FIRST and only THEN builds the wrapper
# around it, so these functions take an ALREADY-ESCAPED string and wrap it -- they do
# not escape, and calling one on unescaped text produces invalid JSON exactly the way
# calling printf on it today would.
#
# Adopted (#362) at pre-tool-hook.sh's own block/inject sites, and at
# pre-prompt-hook.sh's and pre-path-hook.sh's inject sites -- all four call
# jit_envelope_inject()/jit_envelope_block() rather than hand-rolling the printf, and
# each one was pinned before the swap by a test asserting on the CURRENT bytes, so the
# swap is provably like-for-like rather than merely believed to be. The bare `print
# "{}"` sites in those same three files were left alone: "{}" carries nothing this
# builder can get wrong, so rewriting it would be motion without a defect to fix.
#
# session-start-hook.sh (3 sites) and stop-hook.sh (5 sites) are plain bash, not awk,
# and this string cannot be called from a bash printf directly. Deliberately NOT given
# a bash-side equivalent here: none of those eight sites ever emits a `decision` --
# jit_envelope_block() is the one function above with a security consequence when
# skipped, and it has no bash-side counterpart to skip, because Stop and SessionStart
# never block. A parallel bash implementation of the SAME wire shape would be a second
# answer to the question this comment block already warns drifts from the first one
# invisibly -- the reason jit_row_id()/jit_log_name() live in exactly one place lower
# in this file. Left as eight hand-rolled `printf`s, named here rather than silently.
#
# Every function below builds the Claude Code shape -- the only OBSERVED row in
# the scripts/host.sh registry. A future second host with its own OBSERVED envelope
# contract gets its own functions here, dispatched on $JIT_HOST/JIT_HOST_REFUSAL_STATE
# (both exported above, from scripts/host.sh) -- never a guess folded into these three
# threaded through an untested branch. jit_envelope_block() in particular must never
# be called for a host whose refusal_envelope is not literally "claude-decision-block";
# see jit_host_refusal_state() in scripts/host.sh for why "refusal-not-established" and
# "unsupported" are both a NO here, and different from each other.
# shellcheck disable=SC2034
JIT_AWK_ENVELOPE='
function jit_envelope_inject(event, text_escaped) {
  if (text_escaped == "") return "{}"
  return "{\042hookSpecificOutput\042:{\042hookEventName\042:\042" event "\042,\042additionalContext\042:\042" text_escaped "\042}}"
}
function jit_envelope_block(reason_escaped) {
  return "{\042decision\042:\042block\042,\042reason\042:\042" reason_escaped "\042}"
}
function jit_envelope_empty() {
  return "{}"
}
'
# #367 excluded this macro from pre-tool-hook.sh because that hook sat right at Linux's
# per-argument exec() cap (#369). #371 then moved that hook's composed program off argv
# entirely (a mktemp'd file, read via `awk -f`), so a file on disk has no such limit --
# the reason for the exclusion is gone, and #391 folds this macro into pre-tool-hook.sh
# too, adding jit_envelope_block_sysmsg() below for its one shape the other two hooks
# never needed: a REFUSAL that also carries a systemMessage line naming which rule
# refused (#368 measured that Claude Code delivers systemMessage on a refused
# PreToolUse call too, as its own event ahead of the tool_result error).
# shellcheck disable=SC2034
JIT_AWK_ENVELOPE_SYSMSG='
function jit_fmt_bytes(n) {
  if (n < 1000) return n "b"
  return sprintf("%.1fk", n / 1000)
}
function jit_envelope_inject_sysmsg(event, text_escaped, sysmsg_escaped) {
  if (text_escaped == "" && sysmsg_escaped == "") return "{}"
  if (text_escaped == "") return "{\042systemMessage\042:\042" sysmsg_escaped "\042}"
  if (sysmsg_escaped == "") return jit_envelope_inject(event, text_escaped)
  return "{\042hookSpecificOutput\042:{\042hookEventName\042:\042" event "\042,\042additionalContext\042:\042" text_escaped "\042},\042systemMessage\042:\042" sysmsg_escaped "\042}"
}
function jit_envelope_block_sysmsg(reason_escaped, sysmsg_escaped) {
  if (sysmsg_escaped == "") return jit_envelope_block(reason_escaped)
  return "{\042decision\042:\042block\042,\042reason\042:\042" reason_escaped "\042,\042systemMessage\042:\042" sysmsg_escaped "\042}"
}
'
