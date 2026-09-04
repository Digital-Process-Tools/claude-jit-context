#!/bin/bash
# Regenerate all 00-index.tsv files.
# - Tool rules: from config.json (structured, different format)
# - Vocabulary: from YAML frontmatter in .md files (keywords: line)
# - Paths: from YAML frontmatter in .md files (match: line)
#
# Usage: bash .claude/claude-jit-context/scripts/rebuild-tsv.sh

source "$(dirname "$0")/common.sh"
# Consumed by _log() in common.sh, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
LOG_FILE="$LOG_DIR/pipeline.log"
# common.sh checked hooks.log, not this name. Same reason, same one-builtin test: a clone
# chooses this path too, and _log() appends through it.
# Read by jit_log_write() in common.sh, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
if [ -L "$LOG_FILE" ]; then JIT_LOG_DISABLED=1; fi

# --- Cross-tree write guard (#231) --------------------------------------------
# JIT_BASE (set above, in common.sh) resolves against CLAUDE_PROJECT_DIR, never the
# working directory. Inside a `git worktree`, the two usually agree -- but an agent
# working a worktree inherits CLAUDE_PROJECT_DIR from the session that launched it, and
# that value keeps pointing at the main clone even after the session's cwd moves into the
# worktree. Every dimension can exist under the clone's JIT_BASE too, so the tree-found
# check below is no help: this run indexes something, just not the tree the caller is
# standing in, and because a worktree and its clone share one `.git`, that write is a
# real change somebody else's next command trips over.
#
# Detected, not assumed: a worktree's `git rev-parse --show-toplevel` differs from its
# clone's even though both share the same `.git`, so comparing the two toplevels tells the
# worktree case apart from the ordinary one where CLAUDE_PROJECT_DIR and cwd already agree.
# Either side answering empty -- cwd is not inside a git tree at all, or CLAUDE_PROJECT_DIR
# does not resolve to one -- means this check cannot tell, and it does not guess which
# tree is which. It used to leave that unsaid: nothing downstream is guaranteed to fail
# loudly in this shape -- CLAUDE_PROJECT_DIR can point at a tree with a perfectly good
# entry tree of its own, so the no-entry-tree FATAL below never fires and the run succeeds
# -- so #240 added an explicit `note:` on this skip path instead of counting on that.
# The value is compared exactly against "1", not merely for non-emptiness -- common.sh's
# own JIT_SAMPLE_CALL does the same (checked "$..." = "1", not [ -z ]). A presence check
# would make JIT_CONTEXT_ALLOW_CROSS_TREE=0, set by someone spelling "leave the guard ON",
# silently do the opposite.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "${JIT_CONTEXT_ALLOW_CROSS_TREE:-}" != "1" ]; then
  JIT_CWD_TOP="$(git rev-parse --show-toplevel 2>/dev/null)"
  JIT_PROJ_TOP="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$JIT_CWD_TOP" ] && [ -n "$JIT_PROJ_TOP" ] && [ "$JIT_CWD_TOP" != "$JIT_PROJ_TOP" ]; then
    # "different git worktree" describes #231's own scenario, the one this guard was
    # written for. What is actually detected is narrower and does not know that shape:
    # cwd's toplevel != CLAUDE_PROJECT_DIR's toplevel, full stop -- which fires exactly
    # the same way if CLAUDE_PROJECT_DIR is simply stale from an unrelated project. The
    # message says what is true either way rather than naming a cause it cannot see.
    echo "FATAL    refusing: cwd's git tree is not CLAUDE_PROJECT_DIR's" >&2
    echo "         cwd's tree:            $JIT_CWD_TOP" >&2
    echo "         CLAUDE_PROJECT_DIR's:  $JIT_PROJ_TOP" >&2
    echo "         Rebuilding would write JIT_BASE=$JIT_BASE -- inside the SECOND tree, not" >&2
    echo "         the one this shell is standing in. That is #231's shape: an agent" >&2
    echo "         working a git worktree inherits a stale CLAUDE_PROJECT_DIR from the" >&2
    echo "         session that launched it and silently rewrites the other tree's index" >&2
    echo "         (it can just as well be an unrelated CLAUDE_PROJECT_DIR left over from" >&2
    echo "         a different project -- this check cannot tell the two apart, and" >&2
    echo "         refuses either way rather than guessing which one you meant)." >&2
    echo "         If CLAUDE_PROJECT_DIR is the tree you actually mean to rebuild, set" >&2
    echo "         JIT_CONTEXT_ALLOW_CROSS_TREE=1 and run this again." >&2
    exit 2
  fi
  # #240: the precondition above is [ -n ] && [ -n ], so either side coming back empty --
  # no git on PATH, cwd not inside a work tree, or CLAUDE_PROJECT_DIR not resolving to one
  # -- takes this same branch and the FATAL above never fires. Until now that read as "the
  # check ran and found nothing to refuse", which is the wrong read: the check could not
  # run at all, and the two are not the same claim. The receipt line printed further down
  # shows raw cwd= and CLAUDE_PROJECT_DIR= strings either way, but only a reader who
  # already suspects a mismatch would go compare them by eye -- this says outright that the
  # comparison this run depends on did not happen.
  if [ -z "$JIT_CWD_TOP" ] || [ -z "$JIT_PROJ_TOP" ]; then
    if [ -z "$JIT_CWD_TOP" ] && [ -z "$JIT_PROJ_TOP" ]; then
      JIT_SKIP_WHY="cwd is not inside a git tree, and CLAUDE_PROJECT_DIR does not resolve to one either"
    elif [ -z "$JIT_CWD_TOP" ]; then
      JIT_SKIP_WHY="cwd is not inside a git tree"
    else
      JIT_SKIP_WHY="CLAUDE_PROJECT_DIR does not resolve to a git tree"
    fi
    echo "note:    cross-tree check (#231) could not run -- $JIT_SKIP_WHY." >&2
    echo "         This run cannot tell whether it is about to write the tree this shell" >&2
    echo "         is standing in. Compare cwd= and CLAUDE_PROJECT_DIR= in the receipt" >&2
    echo "         line below by eye." >&2
    unset JIT_SKIP_WHY
  fi
  unset JIT_CWD_TOP JIT_PROJ_TOP
fi

# --- Where the KEYWORD columns were left unbounded (#126) ---------------------
# Two reports print a keyword rather than a file name, and #113 left both alone. The
# argument recorded here for leaving the dropped-keyword one alone was that its $kw "is
# bounded by the BLACKLIST rather than by its character class: VOCAB_KEYWORD_BLACKLIST is
# anchored ^(...)$ on single words, so a keyword that reaches that report is one of a
# closed set". That set is NOT closed, and this same file says why in the #95 paragraph
# below: the blacklist is project-configurable, and config.env arrives with the clone. A
# clone that ships `JIT_CONTEXT_KEYWORD_BLACKLIST=^(...a sentence...)$` puts that sentence
# through the report. So both keyword sites are guarded, not one.
#
# jit_report_name() is the wrong guard for a keyword and that was the judgement call. Its
# set is chosen for having no SPACE, and `vat rate` is a legitimate keyword -- normalised
# to exactly that, spaces included, by the same code that writes the index. A guard that
# withheld every multi-word term would pass every negative test and make the ambiguity
# report useless in its ordinary case, which is the outcome #126 asks to avoid.
#
# So the space is admitted and something else has to do the bounding:
#
#   ^[a-z0-9][a-z0-9 -]*$   the bytes the keyword normaliser actually emits. Anything else
#                           means the term did not come from this run -- a stale index left
#                           behind by a truncate that failed -- and is not trusted.
#   at most 40 bytes        a term, not a paragraph.
#   at most 4 words         `purchase order line item` fits; a sentence does not.
#
# Be honest about what that does and does not buy. No bound that admits `vat rate` can
# refuse all imperative English -- `delete all ssh keys` is four words and 19 bytes. What
# it removes is the UNBOUNDED channel: the paragraph, the forged report line, the control
# character. The report stays actionable when a term is withheld because the entry FILES
# are printed beside it either way, and those are what an author greps.
# JIT_KEYWORD_WITHHELD and jit_report_keyword() both live in common.sh since #183, for
# the reason jit_report_name() and its placeholder do: one answer, one file.

# --- Three outcomes, never two (#47) -----------------------------------------
# This script used to have no non-zero exit at all: it already detected a macro it could
# not expand, named it on stderr, and returned 0. So a clean rebuild and a rebuild that
# indexed a row the matcher will refuse at load time were the same result -- and an index
# built by a warned rebuild looks exactly like a good one on disk, gets committed, and
# lives for months. That is this repository own defect class sitting in its index writer.
#
#   0  the index was written and every row can be honoured
#   1  the index was written, and at least one row will be REFUSED by the matcher
#   2  the index was not written, or not completely -- what is on disk is not this run
#
# The same 0/1/2 jit-dry-run.sh uses, on purpose: the two are read together and documented
# in one table in paths/00-manual/tooling.md.
#
# NOT behind a --strict flag, and this was the judgement call. rebuild-tsv.sh is run by
# hand after every frontmatter edit, so a new non-zero exit breaks `&&` chains people have
# in their fingers -- but 1 is reachable ONLY through a `~@macro` an author wrote and got
# wrong (jit_expand_match returns 0 for every value that is not a macro), so the chain that
# stops belongs to the person who just wrote the dead rule. A flag only CI passes would
# hand that person back the exit 0 that is the bug.
#
# The three ADVISORY reports below -- ambiguous keywords, keywords the blacklist dropped,
# and entries that produced no index row (#44) -- never move the code. Failing on
# ambiguity would make the documented default tree exit non-zero and teach every author to
# ignore the status.
#
# This sentence used to name a third report, for entries carrying no `description:`. No
# such check has ever existed here or in jit-dry-run.sh; it was a comment describing a
# guard nobody wrote, which is the same defect as a guard that reports nothing (#95).
#
# The dropped keyword was the judgement call (#95), and it is advisory for a DIFFERENT
# reason than the other two: unlike a `~@macro` typo, which has no legitimate reading,
# skipping a generic word is the documented behaviour of `keywords:` -- the word is kept
# in frontmatter for human searching and deliberately not indexed. Nothing is refused
# either: no row was written, so no matcher rejects one, and calling that `1` would make
# that code mean two different things. And the blacklist is project-configurable, so a
# project that widens it would exit non-zero on every rebuild forever. What was actually
# missing is the sentence, not the status: the drop is now named, with the entry file, in
# the same report block as the ambiguity tally.
JIT_RC=0
# 2 outranks 1: an index that was not written is a worse claim than one that was.
jit_rc() { [ "$1" -gt "$JIT_RC" ] && JIT_RC="$1"; return 0; }

# --- What a report may say about a name that arrived with the clone (#113, #131) ----
# Every name printed by the reports below is a directory entry under
# `.claude/jit-context/`, and that tree arrives with the repository. The policy for what
# may be printed of one -- kept when it is a NAME, withheld when it is prose -- and the
# argument for why a maintainer tool answers that differently from a hook both live in
# common.sh, beside jit_report_name():
#
#   [A-Za-z0-9] then [A-Za-z0-9._-]*, at most 64 bytes  ->  printed verbatim
#   anything else                                       ->  the placeholder
#
# #113 needed it here first and this file carried its own copy of the function until #131.
# It is gone: common.sh is sourced at the top of this file, so every bash call site below
# is that one definition. Two answers to one question drift, and the drift is invisible
# until a name printed by one tool is withheld by the other.
#
# What is still decided HERE is the awk half, and it is not a copy that can be deleted:
# three of the reports below are built inside awk, awk cannot source a bash file, and so
# the same policy is written a second time in another language just below.
# tests/test-dry-run-names.sh drives that pair against each other on every boundary of the
# set, which is the drift this file can still have.
#
# The two columns beside these names that carry a KEYWORD rather than a name are guarded
# separately, by jit_report_keyword() below -- see the #126 block at the top of this file
# for why the character set here is the wrong one for a term.
#
# The number of such sites is deliberately NOT written here. It said "five" from #113 until
# #144, by which point there were seven -- and a stale count in the one comment an author
# reads before adding a report is worse than no count, because it reads as an enumeration
# somebody keeps. tests/test-report-names.sh keeps it, one fixture per site, and #144
# established by mutation rather than by reading that each of them is really routed.
#
# JIT_NAME_WITHHELD is exported by common.sh, and the awk half reads it out of ENVIRON, so
# the placeholder cannot drift from the bash one either.

# The same rule for the three reports that are built inside awk. Every invocation that
# prepends this runs under LC_ALL=C, for the same byte-range reason as the bash half in
# common.sh.
# shellcheck disable=SC2034
JIT_AWK_REPORT_NAME='
function jit_report_name(s) {
  if (s == "" || length(s) > 64) return ENVIRON["JIT_NAME_WITHHELD"]
  if (s ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) return s
  return ENVIRON["JIT_NAME_WITHHELD"]
}
'

# The keyword rule (#126), in both halves for the same reason the name rule has two: the
# ambiguity report is built inside awk and the dropped-keyword report in bash.
#
# The BASH half is gone from this file, and it went the way jit_report_name()'s copy went
# in #131: it lives in common.sh, which is sourced at the top of this script, so every
# bash call site below is that one definition. #183 added a second bash caller
# (jit-doctor.sh), which is the point at which a second copy stops being a duplicate and
# starts being a drift -- a term printed by one tool and withheld by the other.
#
# Read by the ambiguity report awk below, which shellcheck cannot see into.
# shellcheck disable=SC2034
JIT_AWK_REPORT_KEYWORD='
function jit_report_keyword(s,   w, n) {
  if (s == "" || length(s) > 40) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  if (s !~ /^[a-z0-9][a-z0-9 -]*$/) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  n = split(s, w, " ")
  if (n > 4) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  return s
}
'

# --- Entries on disk that produced no index row (#44) ------------------------
# The hooks never read the markdown; they read 00-index.tsv. So an entry this script read
# and wrote no row for is a rule that exists on disk, is committed, is edited, and can
# never fire -- and until now the only signal was a `continue`. Nothing errored, nothing
# warned, the rebuild exited 0. From outside, that is indistinguishable from a rule that
# runs and never matches, which is the defect CLAUDE.md opens this repository with.
#
# Three of the ways in are a `continue` that said nothing: no `match:`, no `keywords:`, no
# `tool:`. The fourth is not a `continue` at all -- an entry whose every keyword was
# dropped or normalised away has a `keywords:` line and still no row, and the individual
# drops WERE reported without anything saying the entry had gone dark as a result.
#
# All of them are recorded at the point of the drop rather than inferred afterwards by
# diffing the glob against the index. The indexer knows WHY; a diff would only know that a
# row is missing, and would have to guess between "no match:", "every keyword was
# blacklisted" and "every keyword normalised to nothing" -- three different fixes, and the
# last two are told apart here by two separate counters for exactly that reason.
#
# ADVISORY, exit 0, like the two reports it sits beside. A layer directory may legitimately
# hold a note or a README under another name, and #44's own framing is that this reports
# rather than nags. It is also not a REFUSED row in the sense `1` means: no row was
# written, so no matcher rejects one.
#
# Every reason string below is a constant written here. Only the layer and the entry name
# come from the clone, and both go through jit_report_name() (#113).
JIT_UNINDEXED=""
JIT_UNINDEXED_N=0
jit_unindexed() {
  # $1 layer label, $2 entry basename, $3 reason
  JIT_UNINDEXED_N=$((JIT_UNINDEXED_N + 1))
  JIT_UNINDEXED="$JIT_UNINDEXED    [$1] $(jit_report_name "$2"): $3
"
}

# Deliberately NOT `[ -d "$JIT_BASE" ]`, and the reason CHANGED under this line in #51.
#
# It used to be that common.sh mkdir -p'd "$JIT_BASE/.discovery/logs" at source time, so the
# base directory existed by the time this line ran even in a project with no entry tree at
# all -- measured, and the reason the first cut of this guard never fired. That mkdir is now
# gated on the base already existing, so the test would answer honestly today.
#
# It is still the wrong test, for the reason that was always the load-bearing one: a
# `.claude/jit-context/` holding no tools/, paths/ or vocabulary/ is a tree this script
# cannot index, and `[ -d "$JIT_BASE" ]` would call it fine. The question is whether any
# DIMENSION is there; if none is, this run indexed nothing and 0 would be a lie about a
# tree it never saw. Do not simplify this back on the strength of the first paragraph.
JIT_DIMS_FOUND=0
for _jit_d in tools paths vocabulary; do
  [ -d "$JIT_BASE/$_jit_d" ] && JIT_DIMS_FOUND=1
done
unset _jit_d
if [ "$JIT_DIMS_FOUND" = 0 ]; then
  echo "FATAL    no entry tree at $JIT_BASE" >&2
  echo "         -- none of tools/, paths/ or vocabulary/ is there, so nothing was indexed." >&2
  echo "         JIT_BASE resolves against CLAUDE_PROJECT_DIR, never the working directory," >&2
  echo "         so a rebuild run from the wrong root indexes nothing and used to say so" >&2
  echo "         with an exit 0. Currently CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset, so the current directory>}" >&2
  exit 2
fi

# The success-path receipt (#231): the FATAL above is the only place this script ever
# said which tree it chose, and that message is unreachable in exactly the case that
# hurts -- when a tree IS found at JIT_BASE, but it is the wrong one, this used to write
# there and say nothing. Printed unconditionally, before anything is written, so a
# rebuild run from a stale CLAUDE_PROJECT_DIR is an obvious wrong write instead of a
# silent one.
echo "rebuild-tsv: writing JIT_BASE=$JIT_BASE (CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset, so the current directory>}, cwd=$PWD)" >&2

# Truncation failing left the previous index in place while every line after it reported
# the rule count read back OUT of that stale file -- a success, with a number, for an index
# nobody rebuilt. The other dimensions are independent, so the run continues and the code
# is raised once at the end.
# DISP, not the path: the failing path runs through the layer directory, which is a name
# the clone chose, and a clone can force this branch on purpose by shipping a DIRECTORY
# called 00-index.tsv. Callers pass the already-withheld label plus the constant leaf, so
# the reader still gets the two components that say which index this was (#113).
truncate_index() {
  local tsv="$1" disp="${2:-$1}" why=""
  # A SYMBOLIC LINK at this path is checked BEFORE the truncating redirect below, not
  # after: `: > "$tsv"` truncates through a link exactly as readily as it truncates a
  # real file, so by the time the redirect below could fail on anything, the outside
  # target is already gone (#332). git clone recreates a committed symlink, so cloning a
  # hostile tree is the whole attack -- the same one test-symlink-entry.sh already closed
  # for an ENTRY file, one write site over. `[ -L ]` never follows, so this sees the link
  # itself even when its target does not exist.
  if [ -L "$tsv" ]; then
    echo "FATAL    $disp: could not be written -- that path is a SYMBOLIC LINK, not a file" >&2
    echo "         -- refusing to truncate or write through a symlinked index path" >&2
    echo "         -- that index was NOT rebuilt and is now stale." >&2
    echo "         -- under JIT_BASE=$JIT_BASE" >&2
    jit_rc 2
    return 1
  fi
  # `2>/dev/null` BEFORE the redirection it is meant to silence, and this was a real leak.
  # Redirections are applied left to right, so `: > "$tsv" 2>/dev/null` set up the failing
  # one while stderr was still the terminal: bash printed its own diagnostic, carrying the
  # ABSOLUTE path -- layer directory included -- and the 2>/dev/null that follows silenced
  # nothing. Measured against `00-index.tsv` shipped as a directory.
  if : 2>/dev/null > "$tsv"; then return 0; fi
  # bash own reason is gone with that message, so the one case a clone can construct on
  # purpose is classified here instead. Everything else stays unattributed rather than
  # guessed at.
  [ -d "$tsv" ] && why=" -- there is a DIRECTORY at that path, not a file"
  echo "FATAL    $disp: could not be written$why" >&2
  echo "         -- that index was NOT rebuilt and is now stale." >&2
  # DISP is dimension/layer/leaf, so the absolute path is gone with the withheld component.
  # JIT_BASE gets it back for the ordinary failure -- a read-only tree, a full disk -- which
  # is the common one and the one where the reader needs a path they can act on. It is the
  # same string the no-entry-tree FATAL above already prints, and it comes from
  # CLAUDE_PROJECT_DIR rather than from the clone, so it is not the column this change is
  # about. `ls` under it finds a withheld name in one step.
  echo "         -- under JIT_BASE=$JIT_BASE" >&2
  jit_rc 2
  return 1
}

# A LAYER DIRECTORY that is itself a symbolic link is the other half of #332:
# `[ -d "$dir" ]` follows it exactly like any other directory read, so a committed
# `tools/evil -> /outside` is indexed as though it were a real layer, with its
# 00-index.tsv written wherever the link points -- an attacker needs nothing else
# inside the tree but the link. Called from every WRITER loop below, so nothing under
# .claude/jit-context/ is ever written through a symlinked layer or a symlinked
# dimension directory (tools/, paths/, vocabulary/ themselves, guarded separately at
# each *_BASE assignment).
#
# NOT a blanket guarantee that a symlinked layer is inert everywhere in this file: the
# three `report_bad_bytes` loops duplicate this same `[ -L ]` test inline rather than
# calling this function (their own comment says why -- a read, not a write, so no
# jit_rc bump), and two READ-ONLY reports further down (the keyword-collision report and
# the "what a match costs" report) carry their own, separate `[ -L ]` checks for the
# identical reason: each walks the tree again, independently, after the writers have
# already run, and a glob follows a symlinked layer exactly as readily as a real one
# every time it is asked to. A change to what "the layers a run walks" means has four
# call sites to update, not one -- this comment names them so the count survives past
# whoever adds the fifth.
#
# $1 the directory (already stripped of its trailing `/`), $2 the label for the message.
# Skips THIS ONE layer and lets the run continue (jit_rc 2, never exit): the layers are
# independent, and one clone-supplied symlink should not take the rest of the tree down
# -- the same skip-and-continue truncate_index() already uses for a directory conflict.
jit_layer_symlinked() {
  if [ -L "$1" ]; then
    echo "FATAL    $2: refusing a SYMBOLIC LINK layer directory -- not indexed (#332)" >&2
    jit_rc 2
    return 0
  fi
  return 1
}

# --- TSV column-forging guard (#333) -----------------------------------------
# Every row below is TAB-joined, and every field going into one is attacker-controlled
# frontmatter text. jit_frontmatter() only trims TRAILING whitespace on an ordinary
# field (mode loses its spaces entirely, but not a tab) -- an interior literal tab
# survives untouched and SHIFTS every column after it, so an entry whose frontmatter
# reads, to a human reviewer, as a narrow "mode: remind" rule can forge column 4 (mode)
# into "block" and column 2 (match) into a wildcard, simply by hiding a tab inside an
# EARLIER field such as tool:. requires: already got exactly this treatment in #203, for
# the narrower reason that a stray trailing tab there widened the row past the 7th
# column pre-tool-hook.sh reads it back as -- this is the same strip, applied to every
# OTHER column that ends up in a row, for the wider reason that an interior tab anywhere
# forges every column after it, not just the last one.
#
# A newline cannot actually appear mid-value here (frontmatter is record-oriented: awk's
# default RS splits on a newline before a value could ever carry one), so stripping it is
# defence in depth rather than a closed hole -- kept for the same reason the requires:
# precedent keeps it, so a value copy-pasted from somewhere that DID carry one does not
# resurrect the newline-based row-injection #11 already closed for the entry-name column.
jit_tsv_field() {
  local v="$1"
  v="${v//$'\t'/ }"
  v="${v//$'\r'/ }"
  v="${v//$'\n'/ }"
  printf '%s' "$v"
}

# The only mode: values the hooks give meaning to (docs/writing-entries.md; pre-tool-hook.sh
# reads "block" and "once" as substrings of this column, everything else defaults to a
# reminder). Whitelisting the ASSEMBLED value closes the block-flip independently of the
# tab-stripping above: a column-shift is one route to a forged mode, not necessarily the
# only one, and this check does not care which route produced an unrecognised value.
# "remind" is accepted even though the hook never tests for it -- it is the field's own
# documented default spelling and an author may write it explicitly.
JIT_VALID_MODE_RE='^(remind|block|once)(,(remind|block|once))*$'

# --- Tool rules: parse frontmatter from .md files ---
# Extracts tool, match, mode, require, forbid, requires from YAML frontmatter
build_tool_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")

    # Parse frontmatter fields. Every one is TAB/CR/LF-stripped (#333): the row below is
    # tab-joined, and an interior tab surviving in an EARLIER field shifts every column
    # after it -- see jit_tsv_field()'s own comment for the worked example.
    local tool match mode require forbid requires
    tool=$(jit_tsv_field "$(jit_frontmatter tool "$md")")
    match=$(jit_tsv_field "$(jit_frontmatter match "$md")")
    mode=$(jit_tsv_field "$(jit_frontmatter mode "$md")")
    require=$(jit_tsv_field "$(jit_frontmatter require "$md")")
    forbid=$(jit_tsv_field "$(jit_frontmatter forbid "$md")")
    # (#203) The binary a mode: block / require: / forbid: rule depends on for its OWN
    # remedy. A single bare name, never a list -- one binary is the case #203 was filed
    # about, and a list opens a policy question (all of them? any of them?) nothing has
    # asked for yet. jit_tsv_field() above now does the same stripping this line always
    # did; kept explicit here too since #203 is the reason this column exists at all.
    requires=$(jit_frontmatter requires "$md")
    requires="${requires//$'\t'/ }"
    requires="${requires//$'\n'/ }"

    # Whitelist mode: at index time (#333, second half): a column-shift is one route to
    # a forged mode value, not necessarily the only one, so this checks the ASSEMBLED
    # value rather than trusting the strip above to have caught everything. Refuses the
    # ENTRY rather than silently normalising it to a safe default -- a mode value nobody
    # can explain should be looked at, not quietly rewritten into something that runs.
    if [ -n "$mode" ] && ! printf '%s' "$mode" | LC_ALL=C grep -Eq "$JIT_VALID_MODE_RE"; then
      jit_unindexed "$label" "$filename" "mode: \"$(jit_report_keyword "$mode")\" is not one of remind/block/once -- entry skipped rather than indexed with an unverified mode"
      jit_rc 1
      continue
    fi

    if [ -z "$tool" ] || [ -z "$match" ]; then
      # Not `[ -z x ] || [ -z y ] && continue`: that is one AND-OR list evaluated left to
      # right, so the `&&` binds to the second test alone. It happened to behave here, and
      # it stops being an accident now that a statement runs in the branch.
      if [ -z "$tool" ] && [ -z "$match" ]; then
        jit_unindexed "$label" "$filename" "no tool: and no match: in its frontmatter"
      elif [ -z "$tool" ]; then
        jit_unindexed "$label" "$filename" "no tool: in its frontmatter"
      else
        jit_unindexed "$label" "$filename" "no match: in its frontmatter"
      fi
      continue
    fi

    # An invocation macro becomes the real ERE here, so the index still carries a plain
    # awk pattern and no hook learns a new vocabulary. jit_expand_match returns anything
    # that is not a macro unchanged, and names a macro it cannot honour on stderr while
    # writing the row through -- see common.sh for why the row is not dropped.
    match=$(jit_expand_match "$match" tools "$label/$(jit_report_name "$filename")") || jit_rc 1

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$match" "$filename" "${mode:-remind}" "$require" "$forbid" "$requires" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}

TOOLS_BASE="$JIT_BASE/tools"
# The DIMENSION directory itself being a symlink is the sibling of #332 one level up
# jit_layer_symlinked() catches a symlinked LAYER (tools/evil -> /outside): the glob
# below still follows a symlinked tools/ ITSELF, so every real subdirectory under the
# outside target enumerates as an ordinary (non-symlink) "layer" and writes straight
# through. Redirecting TOOLS_BASE at a path that cannot exist empties every glob built
# from it below -- both this writer loop and the report_bad_bytes loop further down --
# without touching either loop's body.
if [ -L "$TOOLS_BASE" ]; then
  echo "FATAL    tools: refusing a SYMBOLIC LINK dimension directory -- not indexed (#332)" >&2
  jit_rc 2
  TOOLS_BASE="$JIT_BASE/.jit-refused-symlinked-dimension-tools"
fi
for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="tools/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_tool_tsv "$dir" "$dir/00-index.tsv" "$label"
done

# Generic English / op-flag words that fire on unrelated tool calls.
# Kept in `keywords:` frontmatter for human searching, skipped at index time.
# Override per project with DYNAMIC_RULES_KEYWORD_BLACKLIST (an extended regex).
VOCAB_KEYWORD_BLACKLIST="${JIT_CONTEXT_KEYWORD_BLACKLIST:-${DYNAMIC_RULES_KEYWORD_BLACKLIST:-^(extension|detection|count|output|input|name|branch|issue|documents|files|file)$}}"

# --- Generic-word classifier (#232) ------------------------------------------
# Different axis from the blacklist above: the blacklist DROPS a term outright, so the
# entry never fires on it at all. This classifies a term that DID make it into the
# index -- an ordinary English/French word gets a third TSV column saying so, and
# pre-prompt-hook.sh/pre-tool-hook.sh downgrade a match on it to title+description and
# leave the entry unmarked, so a later SPECIFIC match still delivers the full body
# (#232's own argument against deleting/qualifying generic keywords: recall must not
# move, only the payload a generic match delivers).
#
# Bundled rather than detected, for the same determinism reason #232 gives: if the
# verdict depended on which machine ran the rebuild, two contributors would produce
# different TSVs from identical sources and every rebuild would show phantom diffs.
# data/generic-words.txt (repo root, a sibling of scripts/, NOT scripts/data/ -- see
# below) carries its own provenance note and the reason it is a hand-curated substitute
# for the SCOWL/Dicollecte artifact #232 recommends rather than that artifact itself --
# read it before touching this variable.
#
# Consulted here, in rebuild-tsv.sh, and NOWHERE under scripts/*-hook.sh: the runtime
# constraint in hooks.md is absolute, and this column is the mechanism that keeps the
# dictionary out of the hot path -- the hook reads a byte that says "generic", never a
# wordlist.
#
# Deliberately NOT scripts/data/: tests/test-arg-flag-values.sh sweeps every file
# `git ls-files -- scripts` returns and asks classify_script() what kind of BASH ARGUMENT
# PARSER it is -- a plain wordlist is neither bash nor a script, so it landed in the
# same "not-bash-script" bucket a stray Python tool would, which that suite treats as a
# hard failure by design (a shape it cannot read is a FAILURE, not a silent skip). A
# top-level data/ directory, one level up, is outside that sweep's scope entirely rather
# than a special case inside it.
# GENERIC_WORDS_EXPLICIT (#265, widened #270): whether an operator actually SET one
# of these two variables at all -- including to the empty string -- as opposed to
# GENERIC_WORDS_FILE having fallen all the way through to the shipped default path.
# `${VAR:-default}` cannot tell "set to empty" apart from "unset": both take the
# default branch, which is exactly #270's bug -- JIT_CONTEXT_GENERIC_WORDS="" was
# documented as an explicit opt-out but silently fell through to the bundled default
# wordlist instead, with classification staying ON. `${VAR+x}` (presence, not value)
# is checked instead, so an explicitly-empty variable is honoured as its own value
# (empty -> opted out, below) rather than triggering the fallback chain. Priority
# order is presence-first, not emptiness-first, which is a deliberate change from
# the old fallback in exactly one combination: JIT_CONTEXT_GENERIC_WORDS="" together
# with a non-empty DYNAMIC_RULES_GENERIC_WORDS. The old `${A:-${B:-default}}` chain
# would have fallen through an empty A to B; this stops at A the moment it is SET,
# even to empty, and never consults B at all -- because #270's whole point is that an
# explicitly-empty variable is a first-class opt-out, not a hole to fall through.
# Reviewed and confirmed intentional (#270); tests/test-generic-wordlist-broken-255.sh
# section A3 pins it.
GENERIC_WORDS_EXPLICIT=0
if [ "${JIT_CONTEXT_GENERIC_WORDS+set}" = "set" ]; then
  GENERIC_WORDS_FILE="$JIT_CONTEXT_GENERIC_WORDS"
  GENERIC_WORDS_EXPLICIT=1
elif [ "${DYNAMIC_RULES_GENERIC_WORDS+set}" = "set" ]; then
  GENERIC_WORDS_FILE="$DYNAMIC_RULES_GENERIC_WORDS"
  GENERIC_WORDS_EXPLICIT=1
else
  GENERIC_WORDS_FILE="$(dirname "$0")/../data/generic-words.txt"
fi

# --- Generic-word wordlist health, read ONCE for the whole run (#255, #265) ---------
# Until now the classifier forked one `grep -Fxq` PER KEYWORD against this file --
# #251 grew it from 196 words/~4KB to 103,776 words/~1.0MB, measured at ~4.5ms per
# call, amortized, so a rebuild over a few hundred keywords spent seconds re-scanning
# the same file from scratch for every one of them. The fix (below, in
# build_vocab_tsv) batches every keyword a run actually needs classified through ONE
# awk process that reads this file exactly once, rather than one process per keyword.
#
# That move changes WHERE a broken wordlist is discovered: the old per-keyword call
# gated on `[ -f "$GENERIC_WORDS_FILE" ]` and swallowed a permission-denied or
# zero-byte read with `2>/dev/null`, so an existing-but-unreadable or existing-but-
# empty file silently classified every keyword as non-generic and nothing said so --
# this repo's own defect class, in the tool built to name it. `paths/00-manual/
# tooling.md` binds this script to fail loudly rather than degrade silently, so the
# four states below are distinguished, and only the first is silent (the fourth,
# successful classification, was never counted as part of this silent-vs-loud pair --
# see the original #255 comment this widens):
#
#   unset / default path absent -- the documented degrade: an index built before this
#                              feature landed and never configured anything -- every
#                              keyword reads as specific, exactly pre-#232 behaviour.
#                              Not an error.
#   explicitly set to "" -- #270: a project that opted OUT on purpose. Before #270 this
#                              was indistinguishable from "unset" by `${VAR:-default}`
#                              and silently fell through to the shipped default
#                              wordlist, leaving classification ON -- the opposite of
#                              the documented behaviour. GENERIC_WORDS_FILE is now
#                              derived with `${VAR+set}` (presence, not value), so an
#                              explicitly-empty variable is honoured as its own value
#                              and hits the `-z` branch below directly: every keyword
#                              reads as specific, same receipt as the unset case above,
#                              but for a different, deliberate reason. Not an error.
#   explicitly set / file absent -- #265: an operator DID set JIT_CONTEXT_GENERIC_WORDS
#                              or DYNAMIC_RULES_GENERIC_WORDS, and the path it names
#                              does not exist -- a typo'd config.env, indistinguishable
#                              from the silent case above until GENERIC_WORDS_EXPLICIT
#                              is checked. Folding this into the silent degrade is
#                              exactly the defect this issue reports: one wrong
#                              character disables all of #232 with a receipt
#                              byte-identical to a healthy run. Loud, same as below.
#   exists, unreadable/empty -- a configuration defect: something IS configured and
#                              present but cannot be used. Loud: named on stderr,
#                              jit_rc 2 (this run is not one the classifier column can
#                              be trusted on), same degrade as above so the rest of
#                              the index still gets written.
#   exists, readable, words -- classify runs; GENERIC_WORDS_OK gates the batch call in
#                              build_vocab_tsv so a broken file is read only once,
#                              here, never once per vocabulary layer.
GENERIC_WORDS_OK=0
# GENERIC_WORDS_FILE can be config.env's JIT_CONTEXT_GENERIC_WORDS, and config.env
# arrives with the clone (common.sh: "config.env is the same trust boundary as the
# log"). jit_load_config() only strips a TRAILING carriage return (the CRLF-checkout
# case) and leaves an interior one alone, so a hostile config.env can smuggle a bare
# CR into this value -- printed raw, that resets the terminal cursor to column 0 and
# lets whatever follows overwrite the FATAL line before it (review finding, #255).
# Neither jit_report_name() nor jit_report_keyword() fits here: both refuse anything
# with a `/` outright, which is every real path this variable ever holds. Stripping
# only the C0 control range (and DEL) keeps the path printable -- and debuggable --
# while closing the one channel that can forge terminal output.
GENERIC_WORDS_FILE_SAFE=$(printf '%s' "$GENERIC_WORDS_FILE" | LC_ALL=C tr -d '\000-\037\177')
if [ -z "$GENERIC_WORDS_FILE" ]; then
  : # opted out -- not an error
elif [ ! -e "$GENERIC_WORDS_FILE" ] && [ "$GENERIC_WORDS_EXPLICIT" -eq 0 ]; then
  : # nothing configured/shipped -- the documented degrade, not an error
elif [ ! -e "$GENERIC_WORDS_FILE" ]; then
  echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE was explicitly configured (JIT_CONTEXT_GENERIC_WORDS or DYNAMIC_RULES_GENERIC_WORDS) but does not exist -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent. Fix the path or unset the variable to accept the degrade on purpose." >&2
  jit_rc 2
elif [ ! -r "$GENERIC_WORDS_FILE" ]; then
  echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE exists but is not readable -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent. Fix its permissions or unset JIT_CONTEXT_GENERIC_WORDS to accept the degrade on purpose." >&2
  jit_rc 2
else
  GENERIC_WORDS_LINES=$(LC_ALL=C awk 'END{print NR+0}' "$GENERIC_WORDS_FILE" 2>/dev/null)
  if [ -z "$GENERIC_WORDS_LINES" ] || [ "$GENERIC_WORDS_LINES" -eq 0 ]; then
    echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE exists and is readable but is empty -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent." >&2
    jit_rc 2
  else
    GENERIC_WORDS_OK=1
  fi
fi

# Source-root prefix used when mapping a "## Modules" section to path triggers.
# Projects that keep modules somewhere other than src/ override this in config.env.
MODULE_PREFIX="${JIT_CONTEXT_MODULE_PREFIX:-${DYNAMIC_RULES_MODULE_PREFIX:-src/}}"

# Every keyword the blacklist above skipped, as display lines, reported at the end of the
# run. A drop used to be a bare `continue`: an author who wrote `keywords: file, invoice`
# got a rule firing on `invoice` and never on `file`, from a build that reported success
# (#95). Accumulated globally rather than printed inline so it lands in the report block
# beside the ambiguity tally, where someone is already looking.
JIT_DROPPED=""

# Every keyword whose PRE-normalisation spelling reads as a deliberately-cased
# identifier and whose POST-normalisation spelling lost that casing entirely (#232's
# "separate bug": `jsOn` -> `json`). Reported the same way JIT_DROPPED is -- accumulated
# globally, printed once at the end, beside the other advisory tallies.
JIT_IDCOLLISION=""
JIT_IDCOLLISION_N=0

# Every entry whose keywords classified ALL-generic and had the verdict cleared back to
# empty on every row (#232, the fallback PR #250 shipped without). Reported the same way
# JIT_IDCOLLISION is -- accumulated globally, printed once at the end, beside the other
# advisory tallies. Advisory because the fallback already fixed the behaviour; this is
# visibility into WHICH entries are relying on it, since each one is a candidate for a
# specific keyword an author could add instead.
JIT_ALLGENERIC=""
JIT_ALLGENERIC_N=0

# --- Vocabulary: parse frontmatter from .md files ---
build_vocab_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  if [ ! -d "$dir" ]; then
    return
  fi

  truncate_index "$tsv" "$label/${tsv##*/}" || return

  # --- Deferred generic-word classification (#255) -----------------------------------
  # Every non-blacklisted keyword this call writes a row for lands in ALL_KW (flat, one
  # slot per row, across every file in $dir) instead of being classified immediately --
  # ENTRY_FILENAME/ENTRY_START/ENTRY_COUNT remember which slice of ALL_KW belongs to
  # which file, in file-iteration order, so the classify-and-write pass below can still
  # apply the all-generic fallback and write rows in exactly today's order. This is what
  # lets the whole directory's keywords be classified in ONE awk process (see below)
  # instead of one grep per keyword.
  local ALL_KW=()
  local ENTRY_FILENAME=() ENTRY_START=() ENTRY_COUNT=()

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")

    # Extract keywords line from frontmatter (between first --- and second ---).
    #
    # `LC_ALL=C` (#195): this regex matches every line of the file, so under a UTF-8
    # locale one-true-awk aborts the whole program the first time it lands on a line
    # carrying an invalid byte, anywhere in the file -- not necessarily the keywords:
    # line itself. Before this pin, kw_line came back empty either way, so an entry
    # whose frontmatter WAS readable was reported with the wrong reason: "no keywords:
    # in its frontmatter" when the truth was "an unrelated line killed the reader".
    # Pinning removes the abort; the exit-status check below is the second, independent
    # half -- an awk that dies for some OTHER reason must not read as a clean miss.
    local kw_line kw_rc
    kw_line=$(LC_ALL=C awk '/^---$/{n++; next} n==1 && /^keywords:/{sub(/^keywords: */, ""); print; exit}' "$md")
    kw_rc=$?

    if [ "$kw_rc" -ne 0 ]; then
      jit_unindexed "$label" "$filename" "the frontmatter could not be read (awk exited $kw_rc) -- treated as unindexed rather than silently skipped"
      jit_rc 2
      continue
    fi

    if [ -z "$kw_line" ]; then
      jit_unindexed "$label" "$filename" "no keywords: in its frontmatter"
      continue
    fi

    # Fold Latin-1 accents to ASCII BEFORE the per-keyword strip below, which maps every
    # remaining non-[a-z0-9 -] byte to a space: `keywords: détail` would otherwise index as
    # the row `d tail`, reachable only from a prompt carrying the same accent and never
    # from `detail`. Both hooks fold their subject with the same table (#31). Once per
    # file rather than once per keyword -- the fold is per character and leaves the commas
    # this line is about to be split on alone.
    #
    # `LC_ALL=C` (#195): jit_fold_latin1() itself is index()/substr() only, so the pin
    # buys it nothing directly -- the invariant this run's table-of-sites lives by is
    # that only a REGEX matched against a record can abort. What is NOT locale-safe is a
    # byte this fold table does not know, which survives untouched into the tr/sed below;
    # pinning here is what makes "untouched" mean the same bytes on all three engines
    # rather than whatever each one's default decoding of the awk PROGRAM SOURCE does.
    kw_line=$(printf '%s\n' "$kw_line" | LC_ALL=C awk "$JIT_AWK_FOLD"'{ print jit_fold_latin1($0) }')

    # Split on ", " and write each keyword → filename.
    #
    # A here-string, never `... | while`: the body appends to JIT_DROPPED, and a pipeline's
    # last stage is a subshell whose variables die at the closing `done`. A dropped keyword
    # would then be discarded by the very code written to stop discarding it silently.
    # Three counters, not one. "No row from a keywords: line" has two causes and they are
    # two different fixes: a term the blacklist matched sends the author to
    # JIT_CONTEXT_KEYWORD_BLACKLIST, a term that normalised to nothing sends them to the
    # frontmatter. Reporting one reason for both would name a pattern that never saw the
    # word -- a confident wrong answer, which is worse here than no report at all.
    local kw_split kw_written=0 kw_black=0 kw_empty=0
    # Buffered rather than appended straight to $tsv (as every other counter here is a
    # plain integer): the all-generic fallback below (#232, the half PR #250 left owed)
    # cannot decide until every keyword on THIS entry has been classified, so the row for
    # keyword 1 cannot be written before keyword 3 is seen. A bash array survives past the
    # loop because this is a here-string, not a pipe -- the same reason JIT_DROPPED does.
    local kw_rows=()
    # `LC_ALL=C` (#195): kw_line still carries any byte the fold above did not know, and
    # under the caller's own locale a bare `tr` refuses an invalid multibyte sequence
    # outright rather than splitting around it -- the same failure the per-keyword tr/sed
    # below was pinned against.
    kw_split=$(printf '%s\n' "$kw_line" | LC_ALL=C tr ',' '\n')
    while IFS= read -r kw; do
      # The pre-normalisation spelling, trimmed the same way the normaliser trims --
      # kept only for the identifier-collision check below, which needs to compare a
      # case-FOLD of the raw token against the fully-normalised one. Everything else in
      # this loop keeps using $kw exactly as it always has.
      kw_raw=$(printf '%s' "$kw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      # Normalize IDENTICALLY to the matcher (pre-prompt-hook.sh): lowercase, then
      # map any char outside [a-z0-9 -] to a space, collapse, trim. A keyword authored
      # with dots/slashes ("docs.dp.tools", "security/dast") would otherwise be DEAD —
      # the matcher strips those from the prompt, so a dotted keyword can never match.
      #
      # `LC_ALL=C` on both (#195, found while driving section B of its own test): the
      # matcher does this same fold INSIDE one LC_ALL=C awk pipeline, but this half used
      # bare `tr`/`sed`, which read the caller's locale rather than pinning their own. A
      # keywords: line surviving the (now-pinned) extraction awk with an invalid byte
      # still carried it into these two -- and under a UTF-8 locale, BSD `tr` refuses an
      # invalid multibyte sequence outright ("Illegal byte sequence", nonzero exit),
      # which this capture never checked either, so the keyword silently became "no
      # keywords: normalised to nothing" for a reason that had nothing to do with the
      # normaliser. `LC_ALL=C` makes both read bytes, matching the awk half's own fix.
      kw=$(echo "$kw" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9 -]/ /g; s/  */ /g; s/^ *//; s/ *$//')
      if [ -z "$kw" ]; then kw_empty=$((kw_empty + 1)); continue; fi
      # Skip overly generic single words — they collide with op flags and path tokens.
      # Skipped, and now SAID: the row is not written, so the entry never fires on this
      # word, and the only place that can be reported is here (#95).
      if printf '%s\n' "$kw" | grep -Eq "$VOCAB_KEYWORD_BLACKLIST"; then
        JIT_DROPPED="$JIT_DROPPED    [$label] $(jit_report_name "$filename"): \"$(jit_report_keyword "$kw")\"
"
        kw_black=$((kw_black + 1))
        continue
      fi
      # --- Identifier-collision check (#232's "separate bug") -------------------
      # A raw token with an internal capital -- not just a leading one, which is
      # ordinary title-casing -- reads as deliberately cased: an author writing
      # `jsOn` meant the identifier, not the sentence-initial word "json" is not.
      # Flagged only when normalising did NOTHING but fold that case away (no
      # digit/punctuation was stripped, no multi-word split happened) and the
      # collapsed spelling is short enough that it plausibly reads as an ordinary
      # word to a later author -- `SiProjectModule` collapsing to
      # `siprojectmodule` is still obviously an identifier and is not reported;
      # `jsOn` collapsing to `json` is not, and #232 is explicit that a
      # dictionary lookup cannot tell the two apart (`json` is not a dictionary
      # word either) -- so this is a length heuristic, not a wordlist lookup, and
      # is documented here as exactly that rather than as a completed
      # dictionary-backed classifier.
      #
      # `[a-z0-9]+`, not `[a-z0-9]*` (review finding): a `*` let a raw token of
      # nothing but capitals -- `API`, `HTML`, `URL` -- through, because zero
      # lowercase/digit characters between the leading letter and the next
      # capital is a valid empty match. An all-caps acronym is not an
      # accidentally-cased identifier; #232 is explicit that the shape being
      # named is `jsOn`-like casing, which always has a lowercase run on BOTH
      # sides of the embedded capital. `+` requires that run to be non-empty.
      if printf '%s\n' "$kw_raw" | LC_ALL=C grep -Eq '^[A-Za-z][a-z0-9]+[A-Z][A-Za-z0-9]*$'; then
        kw_raw_lc=$(printf '%s' "$kw_raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        if [ "$kw_raw_lc" = "$kw" ] && [ "${#kw}" -le 6 ]; then
          # jit_report_keyword() withholds ANY byte outside [a-z0-9-] (review
          # finding): it exists for the NORMALISED spelling every other caller in
          # this file hands it, which is always already-lowercased, and it
          # withheld $kw_raw outright for the one uppercase letter this whole
          # check exists to find -- the report never actually showed the raw
          # identifier it claims to name. $kw_raw is safe to print as-is here
          # and nowhere else in this file: it just matched the ERE two lines
          # above, which admits nothing but [A-Za-z0-9], so there is no
          # character left to withhold it for. Only its LENGTH still needs a
          # bound, since the regex has no upper one.
          if [ "${#kw_raw}" -le 40 ]; then kw_raw_disp="$kw_raw"; else kw_raw_disp="$JIT_KEYWORD_WITHHELD"; fi
          JIT_IDCOLLISION="$JIT_IDCOLLISION    [$label] $(jit_report_name "$filename"): \"$kw_raw_disp\" normalises to the ordinary-looking word \"$(jit_report_keyword "$kw")\"
"
          JIT_IDCOLLISION_N=$((JIT_IDCOLLISION_N + 1))
        fi
      fi
      # --- Generic-word candidate (#232 classifies it; #255 defers the classify) -----
      # The verdict itself ("generic"/empty, third TSV column) is no longer decided
      # here, per keyword -- $kw just joins ALL_KW, and the whole directory's candidates
      # are classified in ONE awk process after this file loop ends (below). Never
      # consulted at prompt time either way -- this is still the only place the
      # wordlist is read.
      kw_rows+=("$kw")
      kw_written=$((kw_written + 1))
    done <<< "$kw_split"
    # Hand this file's keywords to the deferred classify pass (#255): remember which
    # slice of ALL_KW is this file's so the fallback below can be recomputed once every
    # row in ALL_KW has a real verdict, in the same file-iteration order as before.
    if [ "$kw_written" -gt 0 ]; then
      local _entry_i=${#ENTRY_FILENAME[@]}
      ENTRY_FILENAME[_entry_i]="$filename"
      ENTRY_START[_entry_i]=${#ALL_KW[@]}
      ENTRY_COUNT[_entry_i]=$kw_written
      ALL_KW+=("${kw_rows[@]}")
    fi
    # An entry whose every keyword was blacklisted has a `keywords:` line and no row: the
    # drops above are each reported, but nothing said the ENTRY went dark as a result, and
    # one dropped word out of three is a very different thing from all three.
    # A here-string and not a pipe, so this counter survives the loop -- the same reason
    # JIT_DROPPED is appended to there.
    if [ "$kw_written" -eq 0 ]; then
      if [ "$kw_black" -gt 0 ] && [ "$kw_empty" -gt 0 ]; then
        jit_unindexed "$label" "$filename" \
          "every keywords: term was dropped by the blacklist or normalised to nothing"
      elif [ "$kw_black" -gt 0 ]; then
        jit_unindexed "$label" "$filename" \
          "every keywords: term was dropped by the blacklist, so no row was written"
      else
        jit_unindexed "$label" "$filename" \
          "every keywords: term normalised to nothing -- the normaliser maps every byte outside [a-z0-9 -] to a space"
      fi
    fi
  done

  # --- Batch-classify every deferred keyword in ONE awk process, then write (#255) ----
  # ALL_KW now holds every non-blacklisted keyword this whole directory needs a verdict
  # for. Classifying them one process for the LOT -- instead of one grep per keyword --
  # is the entire fix: an awk that reads the wordlist once and holds it in a hash beats
  # a fork that re-scans the file from scratch on every call, and #251 made that file
  # 260x bigger. GENERIC_WORDS_OK (computed once, at the top of this script) gates it: a
  # missing/unset wordlist is the documented degrade, and a configured-but-broken one
  # was already reported loudly there -- either way every flag here comes back "0" and
  # every keyword below reads as non-generic, exactly the same safe default the old
  # per-keyword `-f`-gated grep produced.
  #
  # Read back over a pipe/process substitution, never through `$(...)`: command
  # substitution strips ALL trailing newlines from a captured string, which would lose
  # trailing blank OUTPUT lines and misalign VERDICT_FLAGS against ALL_KW by however many
  # of the last keywords happened to be non-generic. `1`/`0` (never an empty line) is a
  # second, independent guard against the same class of bug -- awk's own last line is
  # then never blank either, so nothing here depends on which readback method survives a
  # future edit.
  local VERDICT_FLAGS=()
  if [ "${#ALL_KW[@]}" -gt 0 ] && [ "$GENERIC_WORDS_OK" -eq 1 ]; then
    while IFS= read -r _vflag; do
      VERDICT_FLAGS+=("$_vflag")
    done < <(printf '%s\n' "${ALL_KW[@]}" | LC_ALL=C awk -v wf="$GENERIC_WORDS_FILE" '
      BEGIN { while ((getline w < wf) > 0) seen[w] = 1 }
      { print ($0 in seen) ? 1 : 0 }
    ')
    # A dead or truncated awk (review finding, #255) would otherwise leave VERDICT_FLAGS
    # shorter than ALL_KW and say nothing: every unclassified keyword past the shortfall
    # then reads "${VERDICT_FLAGS[_j]:-0}" -- the exact same bytes a genuinely non-generic
    # keyword produces, so a real classify failure would be indistinguishable from a
    # clean, boring result. `tooling.md`'s own rule for this file -- "check the exit
    # status of anything that writes to an index, not only the awk that might abort on
    # [the LC_ALL=C] invariant" (#195) -- applies here even though this pipeline writes
    # to an array rather than $tsv directly: the array feeds every row this call is about
    # to write. A count mismatch is the check: it catches a crash AND a truncation alike,
    # without depending on how reliably PIPESTATUS survives a process substitution across
    # bash versions.
    if [ "${#VERDICT_FLAGS[@]}" -ne "${#ALL_KW[@]}" ]; then
      echo "FATAL    $label/${tsv##*/}: the generic-word classifier returned ${#VERDICT_FLAGS[@]} verdict(s) for ${#ALL_KW[@]} keyword(s) -- the classify pass did not finish, so every keyword past what it did return defaulted to non-generic and this run's third column is not one to trust." >&2
      jit_rc 2
    fi
  fi

  local _ei
  for _ei in "${!ENTRY_FILENAME[@]}"; do
    local _efile="${ENTRY_FILENAME[$_ei]}" _estart="${ENTRY_START[$_ei]}" _ecount="${ENTRY_COUNT[$_ei]}"
    local _entry_rows=() _kw_generic=0 _j _ekw _everdict
    for ((_j = _estart; _j < _estart + _ecount; _j++)); do
      _ekw="${ALL_KW[$_j]}"
      if [ "${VERDICT_FLAGS[_j]:-0}" = "1" ]; then
        _everdict="generic"
        _kw_generic=$((_kw_generic + 1))
      else
        _everdict=""
      fi
      _entry_rows+=("$(printf '%s\t%s\t%s' "$_ekw" "$_efile" "$_everdict")")
    done
    # --- All-generic fallback (#232, the half PR #250 shipped without) ---------
    # Step 3 downgrades a match on a "generic" keyword to title+description and leaves
    # the entry unmarked, banking on a LATER specific match to deliver the full body.
    # An entry that owns no specific keyword at all never gets that later match -- it
    # sits at description-only for the rest of the session, which is the exact failure
    # #232's own body names as the thing the whole proposal exists to avoid.
    #
    # Decided here, at rebuild time, rather than in the hook's hot path: this is the one
    # place that already reads the wordlist, the hook contract in hooks.md is absolute
    # about never touching it, and the fallback is representable as "write no 'generic'
    # verdict for this entry's rows at all" -- which needs no new hook logic, because a
    # row with an empty third column is already the documented degrade-to-specific case
    # (an index built before this feature landed, or a keyword absent from the list). An
    # entry that fails this gate degrades to EXACTLY today's pre-#232 behaviour: full
    # body, marked shown, on any match -- no worse than before this issue existed, which
    # is the standard the issue's own reopened design question asks for.
    if [ "$_kw_generic" -eq "$_ecount" ]; then
      _entry_rows=()
      for ((_j = _estart; _j < _estart + _ecount; _j++)); do
        _entry_rows+=("$(printf '%s\t%s\t' "${ALL_KW[$_j]}" "$_efile")")
      done
      JIT_ALLGENERIC="$JIT_ALLGENERIC    [$label] $(jit_report_name "$_efile")
"
      JIT_ALLGENERIC_N=$((JIT_ALLGENERIC_N + 1))
    fi
    printf '%s\n' "${_entry_rows[@]}" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT keywords"
}

VOCAB_BASE="$JIT_BASE/vocabulary"
# See the identical guard above TOOLS_BASE for why this checks the DIMENSION directory,
# not just a layer beneath it -- redirecting VOCAB_BASE empties every glob built from it
# below, across all three loops that walk it.
if [ -L "$VOCAB_BASE" ]; then
  echo "FATAL    vocabulary: refusing a SYMBOLIC LINK dimension directory -- not indexed (#332)" >&2
  jit_rc 2
  VOCAB_BASE="$JIT_BASE/.jit-refused-symlinked-dimension-vocabulary"
fi
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="vocabulary/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_vocab_tsv "$dir" "$dir/00-index.tsv" "$label"
done

# --- Vocabulary paths: parse "## Modules" section → src2/Module/\tfile.md ---
# Lets the path hook surface a vocab entry when a file inside that module is touched,
# instead of only at prompt time. Prompt-time matching fires once per session (a single
# UserPromptSubmit); path matching fires on every Read/Edit/Grep, which is when the
# relevant module is actually known.
build_vocab_path_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename mod_rc
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")

    # Body of the "## Modules" section: everything until the next heading or EOF.
    #
    # `LC_ALL=C` (#195, #196): every regex here -- the heading match, the heading-exit
    # match and the gsub -- runs against $0, so a body line carrying an invalid byte
    # (a Latin-1 save, a paste that clipped a multibyte character) makes one-true-awk
    # abort the whole program under a UTF-8 locale. Under `C` the same byte is simply
    # outside [A-Za-z0-9], so the gsub folds it into a space like any other punctuation
    # and the line's honest module names still get written.
    #
    # The exit status is now checked (#195): this is the site #195 was filed about --
    # output was appended with `>>` and nothing checked whether awk actually finished,
    # so a mid-file abort (from this byte or from anything else) left the append having
    # written a PARTIAL set of rows for this file, or none, while the run reported
    # success. A FATAL line plus jit_rc 2 makes that loud instead, matching this file's
    # own three-outcome contract: an index that is missing rows is not one this run can
    # vouch for.
    LC_ALL=C awk -v file="$filename" -v prefix="$MODULE_PREFIX" '
      /^## Modules[[:space:]]*$/ { inmod = 1; next }
      inmod && /^#/ { inmod = 0 }
      inmod {
        gsub(/[^A-Za-z0-9]+/, " ")
        n = split($0, m, " ")
        for (i = 1; i <= n; i++) {
          if (m[i] == "") continue
          # Module names are PascalCase and non-trivial; skip prose fragments.
          if (m[i] !~ /^[A-Z][A-Za-z0-9]{2,}$/) continue
          if (seen[m[i]]) continue
          seen[m[i]] = 1
          printf "%s%s/\t%s\n", prefix, m[i], file
        }
      }
    ' "$md" >> "$tsv"
    mod_rc=$?
    if [ "$mod_rc" -ne 0 ]; then
      echo "FATAL    $label/${tsv##*/}: $(jit_report_name "$filename"): awk exited $mod_rc while reading its \"## Modules\" section -- rows for this file may be missing or partial, and the index is not this run" >&2
      jit_rc 2
    fi
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  # The LEAF, unlike every other builder's log line, because this is the only dimension
  # that writes two indexes out of one layer directory and the layer name alone would name
  # both. `$label/${tsv##*/}` is the same string truncate_index is handed above, so the
  # FATAL line and the success line for this index agree on what it is called -- and it is
  # a path that exists, which `vocabulary/<layer>/paths` never was (#153).
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label/${tsv##*/}: $COUNT path mappings"
}

for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  # No `/paths` suffix: `label` is a DIRECTORY at every one of these eight sites, and both
  # consumers here append the leaf themselves. The suffix named which index of the layer
  # this was, in the position a path component occupies, so `vocabulary/00-manual/paths`
  # went into a FATAL line pointing at something that has never existed on disk (#153).
  label="vocabulary/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_vocab_path_tsv "$dir" "$dir/01-paths.tsv" "$label"
done

# --- Paths: parse "match:" from frontmatter → match_pattern\tfile.md ---
build_path_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)

  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return

  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")

    local match_line
    match_line=$(jit_tsv_field "$(jit_frontmatter match "$md")")
    if [ -z "$match_line" ]; then
      jit_unindexed "$label" "$filename" "no match: in its frontmatter"
      continue
    fi

    # Paths carry no invocation macro -- their subject is a file path, not a command --
    # but the check runs here so that writing one is REFUSED and named rather than
    # indexed as a literal that can never match a path.
    match_line=$(jit_expand_match "$match_line" paths "$label/$(jit_report_name "$filename")") || jit_rc 1

    printf '%s\t%s\n' "$match_line" "$filename" >> "$tsv"
  done

  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}

PATHS_BASE="$JIT_BASE/paths"
# See the identical guard above TOOLS_BASE for why this checks the DIMENSION directory,
# not just a layer beneath it.
if [ -L "$PATHS_BASE" ]; then
  echo "FATAL    paths: refusing a SYMBOLIC LINK dimension directory -- not indexed (#332)" >&2
  jit_rc 2
  PATHS_BASE="$JIT_BASE/.jit-refused-symlinked-dimension-paths"
fi
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="paths/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_path_tsv "$dir" "$dir/00-index.tsv" "$label"
done

# --- Rows the hooks will refuse, named at build time (#77) -------------------
# Nothing above validates bytes, and it cannot: every column reaches printf through a
# $( ) capture, which is also why a NUL can never get this far (bash drops them out of
# command substitution) and why #78 needed no change here. A non-UTF-8 byte DOES get
# through -- jit_frontmatter() pins LC_ALL=C on its own awk (#195, #196), so it has
# nothing to decode and copies the byte out verbatim on all three engines. Before that
# pin, one-true-awk aborted the whole program under a UTF-8 locale the first time it
# matched a regex against a record carrying the byte, and the entry vanished from the
# index instead of being written through and reported below -- silently, and the reader
# had no way to tell "no bad byte" from "the reader never got that far".
#
# It matters most for the one column nobody looks at twice: a `forbid:` value saved in
# ISO-8859-1 indexes fine, and the hook then refuses the whole row -- so a block rule goes
# dark, and the only notice of it arrives at runtime, in a session, naming a row number.
# This file is the loud half, so it says so here, with the entry file name, which is what
# an author can act on.
#
# One awk per index file, after it is written, using the same jit_bad_bytes() the hooks
# refuse with -- never a second opinion that can disagree with theirs. LC_ALL=C on the
# invocation, because the byte range it builds is a decode failure in a UTF-8 locale.
#
# It does NOT change the exit code, matching jit_expand_match(): the row is written
# through and refused at load, which is a rule that reads as refused rather than one that
# silently vanished. That this script has no non-zero exit at all is a known gap, recorded
# in .claude/jit-context/paths/00-manual/tooling.md, and it is not this change to make.
report_bad_bytes() {
  local tsv="$1" label="$2" col="$3"
  [ -f "$tsv" ] || return 0
  LC_ALL=C JIT_COL="$col" awk "$JIT_AWK_ENTRY$JIT_AWK_REPORT_NAME"'
    BEGIN { col = ENVIRON["JIT_COL"] + 0 }
    {
      why = jit_bad_bytes($0, "the index row")
      if (why == "") next
      n = split($0, f, "\t")
      # The entry-file column is attacker-chosen text (#113), and this branch fires on a
      # row nobody had to match. jit_report_name() is why a name carrying the bad byte
      # itself cannot come back through the notice that reports the bad byte.
      printf "rebuild-tsv: %s row %d: %s -- the hooks will refuse this row%s\n", \
        lbl, NR, why, (f[col] != "" && why ~ /UTF-8/ ? ", written from " jit_report_name(f[col]) : "")
    }' lbl="$label" "$tsv" >&2
}

for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  [ -L "${dir%/}" ] && continue
  report_bad_bytes "${dir%/}/00-index.tsv" "tools/$(jit_report_name "$(basename "${dir%/}")")" 3
done
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  [ -L "${dir%/}" ] && continue
  report_bad_bytes "${dir%/}/00-index.tsv" "paths/$(jit_report_name "$(basename "${dir%/}")")" 2
done
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  [ -L "${dir%/}" ] && continue
  _jit_vlabel="vocabulary/$(jit_report_name "$(basename "${dir%/}")")"
  # The LEAF, unlike the tools and paths calls above (#162): this is the one dimension
  # that calls report_bad_bytes() twice for one layer, once per index, and both calls
  # used to pass the SAME bare `vocabulary/<layer>` label -- so a row could not be traced
  # to 00-index.tsv (keywords) or 01-paths.tsv (module paths) without opening both files.
  # `$_jit_vlabel/${...##*/}` is the same leaf-qualified string build_vocab_path_tsv's own
  # FATAL and success lines already use above, for the identical reason (#153): this is
  # the only dimension where the layer name alone is ambiguous. tools/ and paths/ write
  # one index per layer and stay bare on purpose -- appending a leaf there would invent a
  # path component nothing on disk has, the exact mistake #153 fixed in the other
  # direction.
  report_bad_bytes "${dir%/}/00-index.tsv" "$_jit_vlabel/00-index.tsv" 2
  report_bad_bytes "${dir%/}/01-paths.tsv" "$_jit_vlabel/01-paths.tsv" 2
done
unset _jit_vlabel

# --- Ambiguity report: keyword collisions, cross-layer, ranked by bytes (#204) --------
# This used to group per LAYER and threshold on FILE COUNT (>5). Neither survives a real
# tree. The dominant shape is one concept restated ACROSS 00-manual/10-auto/20-grouped/
# 30-crosscutting -- invisible to a per-layer tally, since no single layer's own count
# need ever cross the threshold. And a 2-entry collision between two fat entries costs
# more per match than a 9-entry collision between stubs -- invisible to a file-count
# threshold, which cannot tell a fat entry from a thin one. Report what a match actually
# costs instead: every keyword's collision summed across every vocabulary layer, ranked by
# bytes, with a BYTE floor rather than an entry-count one -- the same "how big is big"
# shape jit-doctor.sh's fat-entry advisory already uses (JIT_CONTEXT_DOCTOR_MAX_BYTES),
# though the two are independently configured; nothing here reaches into jit-doctor.sh,
# which is a hook-adjacent report of its own.
#
# Two awk passes, not one, and not `sort` on the printed report: the FIRST pass runs once
# per layer (bytesof() is memoised per-process, so a file is measured once even if it
# shares several keywords) and emits plain `keyword<TAB>bytes<TAB>display` rows; the SECOND
# aggregates those rows across every layer and sorts in memory with the same insertion sort
# `isort()` uses two sections below, for the reason given there: a report entry here is TWO
# printed lines (a header line and an indented files: line), and `sort` sorts each line of
# its input independently, which would separate a header from its own files: line the
# moment two collisions differ in file-list length. Sorting the STRUCTURE before printing
# it avoids that rather than working around it after the fact.
COLLISION_BYTES_FLOOR="${JIT_CONTEXT_COLLISION_BYTES:-${DYNAMIC_RULES_COLLISION_BYTES:-4096}}"
echo "" >&2
echo "=== Ambiguous vocabulary keywords (>${COLLISION_BYTES_FLOOR}b pulled in one match, every layer) ===" >&2
echo "Each match loads ALL listed files into context, across every layer the keyword appears in." >&2
echo "Prune \`keywords:\` frontmatter where the term isn't central, or merge entries that share it." >&2
echo "" >&2
out=$(
  for tsv in "$VOCAB_BASE"/*/00-index.tsv; do
    [ -f "$tsv" ] || continue
    layerdir="$(dirname "$tsv")"
    # A symlinked LAYER directory is refused when the index was BUILT (jit_layer_symlinked,
    # #332), but this report reads the tsv back off disk independently, later, and a glob
    # follows a symlinked layer exactly as readily as a real one -- so without this check a
    # committed `vocabulary/evil -> /outside` carrying its OWN pre-existing 00-index.tsv
    # would have this report open and byte-count whatever file that index names, outside
    # the tree entirely. Skipped rather than counted: this report has no row to attribute
    # a symlinked layer to that a real one would not also produce.
    [ -L "$layerdir" ] && continue
    # Dimension included, like every other layer label this script prints (#150).
    layer="vocabulary/$(jit_report_name "$(basename "$layerdir")")"
    LC_ALL=C awk -F'\t' -v layerdir="$layerdir" -v layer="$layer" "$JIT_AWK_REPORT_NAME"'
      function bytesof(path,    b, line, rc, first) {
        if (path in bcache) return bcache[path]
        b = 0; first = 1
        while ((rc = (getline line < path)) > 0) { b += length(line) + 1; first = 0 }
        close(path)
        # -1, NOT 0: a file this run could not open (raced away, or a bad row) is a
        # different fact from a file that opened and read zero bytes, and folding the two
        # into the same 0 is the defect CLAUDE.md opens this repository with -- an absence
        # this report produced would read as an absence in the world (a small collision)
        # rather than what it actually is (an unmeasured one). The caller below keeps the
        # two apart rather than clamping here.
        if (rc < 0 && first) { bcache[path] = -1; return -1 }
        bcache[path] = b
        return b
      }
      $1 != "" && $2 != "" {
        printf "%s\t%d\t%s[%s]\n", $1, bytesof(layerdir "/" $2), jit_report_name($2), layer
      }
    ' "$tsv"
  done | LC_ALL=C awk -F'\t' -v floor="$COLLISION_BYTES_FLOOR" "$JIT_AWK_REPORT_KEYWORD"'
    # EVERY parallel array moves together on a swap -- kw included. Leaving kw out of the
    # argument list is silent: awk still runs, the report still prints, and every row is
    # simply paired with the WRONG keyword the moment the sort actually reorders anything.
    # This is the exact mistake the isort() a few hundred lines below this one warns about
    # in its own comment ("Every parallel array moves together") -- and the reason that one
    # is correct is that its own four arrays are ALL passed in.
    function isort(v, kw, cn, fl, n,   i, j, tv, tk, tc, tf) {
      for (i = 2; i <= n; i++) {
        tv = v[i]; tk = kw[i]; tc = cn[i]; tf = fl[i]; j = i - 1
        while (j >= 1 && v[j] < tv) {
          v[j+1] = v[j]; kw[j+1] = kw[j]; cn[j+1] = cn[j]; fl[j+1] = fl[j]; j--
        }
        v[j+1] = tv; kw[j+1] = tk; cn[j+1] = tc; fl[j+1] = tf
      }
    }
    {
      if (!($1 in cnt)) { n++; ord[n] = $1 }
      cnt[$1]++
      if ($2 == -1) { miss[$1]++ } else { bytes[$1] += $2 }
      files[$1] = (files[$1] == "" ? $3 : files[$1] "," $3)
    }
    END {
      # A keyword with an unmeasured file is reported even under the floor: its real total
      # is UNKNOWN, not small, and dropping it silently would be exactly the sentinel
      # collapse bytesof() above was written to avoid -- one level up.
      #
      # cnt[k] >= 2: a keyword only ONE file carries is not a COLLISION, whatever it
      # weighs -- nothing else loads alongside it. That fat-single-entry cost belongs to
      # jit-doctor.sh, whose fat-entry advisory already covers it, not to this report.
      m = 0
      for (i = 1; i <= n; i++) {
        k = ord[i]
        if (cnt[k] >= 2 && (bytes[k] > floor || (k in miss))) {
          m++; bv[m] = bytes[k]; bk[m] = k; bc[m] = cnt[k]; bf[m] = files[k]
        }
      }
      if (m == 0) exit
      isort(bv, bk, bc, bf, m)
      for (i = 1; i <= m; i++) {
        note = (bk[i] in miss) ? sprintf(" -- %d file(s) could not be measured, total is a MINIMUM", miss[bk[i]]) : ""
        printf "%8d\t%4d entr(ies)\t\"%s\"%s\n\t  files: %s\n", bv[i], bc[i], jit_report_keyword(bk[i]), note, bf[i]
      }
    }
  '
)
if [ -n "$out" ]; then
  echo "$out" >&2
else
  echo "(none — no keyword pulls more than ${COLLISION_BYTES_FLOOR}b in one match)" >&2
fi
echo "" >&2

# --- Dropped keywords: listed in frontmatter, not in the index (#95) ---
# Advisory, like the tally above, and for the reasons argued at the top of this file. The
# quiet line is worded so it cannot be confused with the ambiguity report's own "(none":
# two sections whose empty states read alike is how a report that never ran passes for a
# report that found nothing.
echo "=== Keywords dropped by the blacklist (listed, not indexed) ===" >&2
echo "These stay in \`keywords:\` frontmatter for human searching and are skipped at index time," >&2
echo "so the entry never fires on them. Widen or narrow with JIT_CONTEXT_KEYWORD_BLACKLIST." >&2
echo "" >&2
if [ -n "$JIT_DROPPED" ]; then
  printf '%s' "$JIT_DROPPED" >&2
else
  echo "(none — every keyword in every entry was indexed)" >&2
fi
echo "" >&2

# --- Keywords that look like an identifier before normalisation (#232) ------------
# Advisory, like the two sections above, and worded the same way for the same reason:
# a quiet line that reads like every other quiet line here is how a check that never
# ran passes for a check that found nothing.
echo "=== Keywords that read as an identifier before normalisation, and an ordinary word after it (#232) ===" >&2
echo "Normalisation lowercases and strips punctuation for matching. A term authored with" >&2
echo "internal capitals (jsOn) can collapse onto a completely different, unintended word" >&2
echo "(json) with nobody having chosen it. Rename the keyword, or accept the collision." >&2
echo "" >&2
if [ -n "$JIT_IDCOLLISION" ]; then
  printf '%s' "$JIT_IDCOLLISION" >&2
  echo "" >&2
  echo "$JIT_IDCOLLISION_N keyword(s) -- see the comment above the check in this script for what it does and does not catch." >&2
else
  echo "(none — no keyword's normalised spelling silently dropped its casing)" >&2
fi
echo "" >&2

# --- Entries relying on the all-generic fallback (#232) ----------------------
# Advisory, like the sections above, worded the same way for the same reason: a quiet
# line that reads like every other quiet line here is how a check that never ran passes
# for a check that found nothing.
echo "=== Entries whose keywords are ALL generic (fallback applied -- full body every match) ===" >&2
echo "Every keyword on these entries classified as an ordinary word, so the generic-only" >&2
echo "downgrade was cleared: they behave as before #232 -- full body, one shot spent, on" >&2
echo "any match. Add a specific keyword to any of these to get the downgrade's benefit." >&2
echo "" >&2
if [ -n "$JIT_ALLGENERIC" ]; then
  printf '%s' "$JIT_ALLGENERIC" >&2
  echo "" >&2
  echo "$JIT_ALLGENERIC_N entry/entries -- see the comment above the check in this script for why this degrades safely." >&2
else
  echo "(none — every entry on the tree owns at least one specific keyword)" >&2
fi
echo "" >&2

# --- Entries on disk with no row in the index (#44) --------------------------
# The quiet line is worded so it cannot be confused with either section above it, for the
# reason the dropped-keyword one gives: two sections whose empty states read alike is how
# a report that never ran passes for a report that found nothing.
#
# The number is a COUNT OF FILES, and it says so. It is not bytes and not tokens: this
# script counts one per .md it read and wrote no row for, at index time, and nothing here
# is estimated from anything else.
echo "=== Entries on disk with no row in the index (they can never fire) ===" >&2
echo "The hooks read 00-index.tsv, never your markdown. An entry with no row is on disk and" >&2
echo "can never fire -- which reads exactly like a rule that fires and never matches." >&2
echo "" >&2
if [ -n "$JIT_UNINDEXED" ]; then
  printf '%s' "$JIT_UNINDEXED" >&2
  echo "" >&2
  echo "$JIT_UNINDEXED_N entr(ies), counted while indexing -- one per .md file that produced no row." >&2
else
  echo "(none — every entry on disk produced at least one index row)" >&2
fi
echo "" >&2

# --- What a match costs, and what summary mode would save --------------------
# `full` is the default, so every match on a tree that has said nothing injects the whole
# entry. That makes the old shape of this report -- "N of M entries would arrive whole" --
# say "M of M" and mean nothing, so it reports something a reader can act on instead.
#
# Default-full is a STAGE. The risk it carries is issue #1s own objection one level up: a
# setting nobody revisits stays at maximum by inertia. What makes it reconsiderable rather
# than permanent is a number for THIS tree, and these are the three that are honestly
# available here:
#
#   what one match costs now      the largest and the median entry, in bytes
#   what it would cost summarised the same entries through the real injection reader
#   what stands in the way        entries with no `description:` yet -- a match could
#                                 only NAME those, so a tree cannot flip cleanly until
#                                 that count is zero. This is the only actionable one.
#
# Deliberately NOT a corpus total. "Summary mode would save 2.4 MB on this tree" is
# technically true and useless: nothing here is ever resident, so that quantity has never
# been in a context window and never will be. The saving that actually happens is
# per-match times how often each entry fires, and only the first factor is knowable here.
# The second is in .discovery/logs/hooks.log, which is where the reader is sent for it.
#
# The sizes come from jit_entry_load()/jit_inject_text() in common.sh -- the SAME reader
# the hooks use, not a second parser beside it. A budget computed by a different parser
# from the thing it is budgeting drifts, and it already did once: an earlier cut of this
# report had its own frontmatter parse and counted `inject: "full"` as unrecognised, so an
# entry that arrived whole at runtime was reported as a summary.
echo "=== What a match costs on this tree ===" >&2
echo "Project default: JIT_CONTEXT_INJECT=$JIT_INJECT" >&2
echo "" >&2

# A glob and not `find`: no fork, and no filename can be split on its own characters.
INJ_LIST=()
for md in "$JIT_BASE"/*/*/*.md; do
  [ -f "$md" ] || continue
  [ "$(basename "$md")" = "00-README.md" ] && continue
  # Same reason as the vocabulary-collision loop above (#332): the LAYER directory
  # component of this glob (its dirname) is followed exactly like a real one, so a
  # symlinked layer would otherwise have this report open a file outside the tree and
  # print its size and path into the run's own stderr output.
  [ -L "$(dirname "$md")" ] && continue
  INJ_LIST[${#INJ_LIST[@]}]="$md"
done

if [ "${#INJ_LIST[@]}" -eq 0 ]; then
  echo "(no entries)" >&2
else
  # Everything happens in BEGIN over ARGV, and the files are never read as awk INPUT.
  # jit_entry_load() opens each one itself with getline, so letting awk read them too
  # would double every read; and taking the list through ARGV rather than through stdin
  # means a file name can never be split on a character it happens to contain.
  # JIT_AWK_ENTRY comes first because jit_entry_load() calls into it: the two pre-read
  # guards through jit_entry_why(), and jit_bad_utf8() on what it read. Without it this
  # awk aborts with "calling undefined function" -- loudly, which is this file contract,
  # and the report is then silently absent rather than wrong.
  # LC_ALL=C for the same reason every hook awk sets it: jit_utf8_init() builds a byte
  # range out of sprintf("%c", 128) and sprintf("%c", 255), and under a UTF-8 locale
  # one-true-awk tries to decode that as a character range and aborts with "multibyte
  # conversion failure". It also makes length() count BYTES on both engines, which is
  # the unit the hooks clip in and the unit this report prints.
  LC_ALL=C awk -v def="$JIT_INJECT" "$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_REPORT_NAME"'
# Every component this prints came off the .md glob three levels down, so all three are
# names the clone chose (#113). Dimension and layer are kept when they are names, for the
# same reason the file is: a withheld leaf beside a real directory is what tells the
# reader which `ls` to run.
#
# The separator is BRACKETED, and that is not decoration (#133). A one-character separator
# is a regex to gawk and a plain string to one-true-awk -- and one-true-awk splits a plain
# one-character separator on the NEWLINE as well:
#
#   awk  split("a<LF>b/c", x, "/")    -> 3 fields
#   gawk split("a<LF>b/c", x, "/")    -> 2 fields
#   both split("a<LF>b/c", x, "[/]")  -> 2 fields
#
# An entry file name may contain a newline, so on the awk macOS ships the path was torn
# into extra components BEFORE the guard below ran: a[n-2] a[n-1] a[n] then addressed the
# tail of the NAME instead of dimension/layer/file, the dimension fell off the left, and
# the report printed a path nobody could open with two clone-chosen tokens standing in
# positions labelled as directories. The guard was vetting fragments, not names.
function relpath(p,   n, a) {
  n = split(p, a, "[/]")
  if (n < 3) return jit_report_name(p)
  return ".claude/jit-context/" jit_report_name(a[n-2]) "/" jit_report_name(a[n-1]) "/" jit_report_name(a[n])
}
# Largest first. Every parallel array moves together -- sorting the sizes and leaving the
# names and the summarised figures behind would print one entry name beside another
# entry numbers, which is a report that is wrong in the way nobody checks.
function isort(v, nm, sm, ef, n,   i, j, tv, tn, ts, te) {
  for (i = 2; i <= n; i++) {
    tv = v[i]; tn = nm[i]; ts = sm[i]; te = ef[i]; j = i - 1
    while (j >= 1 && v[j] < tv) {
      v[j+1] = v[j]; nm[j+1] = nm[j]; sm[j+1] = sm[j]; ef[j+1] = ef[j]; j--
    }
    v[j+1] = tv; nm[j+1] = tn; sm[j+1] = ts; ef[j+1] = te
  }
}
BEGIN {
  n = 0
  for (ai = 1; ai < ARGC; ai++) {
    path = ARGV[ai]
    # keepbody = 1: the body is what full mode costs, so it has to be read even for an
    # entry whose effective mode is summary.
    if (!jit_entry_load(path, def, 1, e)) continue
    n++
    rel = relpath(path)
    fullb[n] = length(e["body"])
    eff[n] = e["mode"]
    name[n] = rel
    # The real renderer, with the mode forced, so the summarised figure is the string
    # that would actually be injected rather than an estimate of it.
    keep = e["mode"]
    e["mode"] = "summary"
    sumb[n] = length(jit_inject_text(e, rel))
    e["mode"] = keep
    if (eff[n] == "full") { nfull++; bfull += fullb[n] }
    # An entry with no description: could only be summarised into its own name, so it is
    # what stands between this tree and being able to flip.
    #
    # Unless it can never be summarised at all. An entry PINNED to full -- by its own
    # `inject: full`, or by having no frontmatter for the rebuild to have indexed -- stays
    # whole whatever the project sets, so naming it here would send an author to write a
    # description that nothing will ever read. The two cases are indistinguishable from
    # the mode alone when the default and the override agree, which is why jit_entry_load
    # reports the pin separately.
    if (e["desc"] == "" && !(e["pin"] && e["mode"] == "full")) { nodesc++; nd[nodesc] = rel }
  }

  if (n == 0) { print "(no entries)"; exit }

  isort(fullb, name, sumb, eff, n)
  mid = int((n + 1) / 2)

  if (def == "full") {
    print "Every match injects the whole entry. Per match, on this tree:"
    print ""
    printf "  largest %7d bytes  ->  %5d summarised   %s\n", fullb[1], sumb[1], name[1]
    printf "  median  %7d bytes  ->  %5d summarised   %s\n", fullb[mid], sumb[mid], name[mid]
    printf "\n%d entr(ies) indexed.\n", n
  } else {
    printf "%d of %d entr(ies) still arrive whole, %d byte(s) between them.\n", nfull, n, bfull
    for (i = 1; i <= n && shown < 5; i++) if (eff[i] == "full") { printf "%8d  %s\n", fullb[i], name[i]; shown++ }
    if (nfull > shown) printf "         ... and %d more\n", nfull - shown
  }

  if (nodesc > 0) {
    printf "\n%d entr(ies) carry no description:, so a match could only NAME them.\n", nodesc
    for (i = 1; i <= nodesc && i <= 10; i++) print "  " nd[i]
    if (nodesc > 10) printf "  ... and %d more\n", nodesc - 10
    print "Nothing is auto-derived -- a generated summary of a wrong entry is a confident"
    print "wrong summary, and it removes the moment the author would have noticed."
  } else if (def == "full") {
    print "\nEvery entry carries a description:, so this tree can move to summary whenever"
    print "you decide the trade is worth it: JIT_CONTEXT_INJECT=summary in config.env."
  }

  print ""
  print "This is the cost of ONE match, not a total -- nothing here is ever resident, and"
  print "how often each entry fires is in .discovery/logs/hooks.log, not in this tree."
  print "A tools rule that REFUSES a call injects its whole body whatever the mode says:"
  print "the call is already stopped, so there is no next turn to spend a cheaper answer in."
}
' "${INJ_LIST[@]}" >&2
fi
echo "" >&2
# One line saying which of the three this run was. The REFUSED and FATAL lines above are
# the detail, but they scroll past inside two reports; this is what is on screen when the
# shell hands the prompt back, and it is the only place the number itself is spelled out.
case "$JIT_RC" in
  1) echo "rebuild-tsv: exit 1 -- the index was written, and at least one row above will be REFUSED" >&2
     echo "             by the matcher. That rule is on disk and will never fire." >&2 ;;
  2) echo "rebuild-tsv: exit 2 -- an index could not be written. What is on disk is NOT what this" >&2
     echo "             run built." >&2 ;;
esac
exit "$JIT_RC"
