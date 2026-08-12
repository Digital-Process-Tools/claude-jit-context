#!/bin/bash
# claude-jit-context — lint and dry-run one tree's rules.
#
# Why this exists: JIT_BASE resolves against $CLAUDE_PROJECT_DIR (common.sh), so rules
# are always loaded from the session's project dir and never from the current directory.
# A tree that is not that dir — a git worktree, a checkout under review, a plugin being
# developed — cannot load or test its own rules, and nothing says so. Four rules authored
# in a branch worktree on 2026-08-10 were verifiable only by hand-running a hook with
# CLAUDE_PROJECT_DIR overridden, which is neither discoverable nor checkable in CI.
#
# This reads the tree you point it at, and answers three questions the hooks cannot:
#   1. can every match pattern actually be honoured?   (a rule that never runs)
#   2. which rule fires for this call?                 (a rule that never matches)
#   3. is that tree config.env honoured line by line?  (a setting that never applies)
#
# Usage:
#   bash scripts/jit-dry-run.sh [--base DIR]
#   bash scripts/jit-dry-run.sh [--base DIR] --tool Bash --command "git push origin main"
#   bash scripts/jit-dry-run.sh [--base DIR] --file src/Billing/Total.php
#   bash scripts/jit-dry-run.sh [--base DIR] --prompt "how do invoice totals work"
#
# --base defaults to ./.claude/jit-context — the tree you are standing in, deliberately
# not $CLAUDE_PROJECT_DIR, which is the thing that cannot be tested from here.
#
# Exit: 0 every pattern honourable, every index current and every config.env line
#       honoured | 1 at least one refused or stale | 2 could not evaluate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

BASE="$PWD/.claude/jit-context"
SAMPLE_TOOL=""
SAMPLE_COMMAND=""
SAMPLE_FILE=""
SAMPLE_PROMPT=""

usage() {
  sed -n '2,25p' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)    BASE="${2:-}"; shift 2 ;;
    --tool)    SAMPLE_TOOL="${2:-}"; shift 2 ;;
    --command) SAMPLE_COMMAND="${2:-}"; shift 2 ;;
    --file)    SAMPLE_FILE="${2:-}"; shift 2 ;;
    --prompt)  SAMPLE_PROMPT="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

BASE="${BASE%/}"

if ! command -v awk >/dev/null 2>&1; then
  echo "SKIPPED: no awk on PATH — the matcher itself is missing, so nothing here can be checked."
  exit 2
fi

AWK_BANNER="$( (awk --version 2>/dev/null || awk -W version 2>&1) | head -1 )"

echo "tree:   $BASE"
echo "awk:    ${AWK_BANNER:-unknown}"
echo ""

if [ ! -d "$BASE" ]; then
  echo "SKIPPED: no such directory. Nothing was checked — this is not a clean result."
  exit 2
fi

# --- Phase 1: can every pattern be honoured? ---------------------------------
# Two independent checks per row, because they see different defects.
#
#   structural — engine-independent, and the load-bearing one. An escaped letter or
#     digit that awk does not define is dropped, so the pattern matches the bare
#     character. awk exits 0 on this, so no compile probe can ever see it, and the
#     answer must not vary by runner: the rule fires on the author machine, not in CI.
#
#   engine — the local awk actually compiling it. This is the only thing that catches a
#     pattern malformed in a way the structural check does not model (a bad interval, a
#     reversed range). A refusal from either is a refusal, because a rule nobody can
#     evaluate is not a rule.

REFUSED=0
VOCAB_REFUSED=0
CHECKED=0
LISTED=0
INDEXES=0
CONFIG_REFUSED=0

# --- config.env, for the tree named by --base --------------------------------
# common.sh resolves JIT_BASE from $CLAUDE_PROJECT_DIR, so sourcing it parsed the SESSION
# config and never the tree being linted. A tree carrying `touch /tmp/nope` and `PATH=/evil`
# reported "0 refused" and said nothing else at all -- an absence produced by the tool,
# read as an absence in the world, in the tool written to report exactly that. The notices
# that send a reader here tell them to treat config.env as hostile because it arrived with
# the repository, so silence is the worst of the three answers this can give.
#
# Three outcomes, never two: no file, read and every line honoured, or read with the
# refused lines named.
#
# jit_load_config() READS and never executes -- that is what closed the config.env hole --
# but it does ASSIGN the settings it accepts, and those must not silently become this
# linter's own configuration. So it runs in a SUBSHELL and only the refusal report crosses
# back out. A linter must not take its behaviour from the tree it was asked to judge.
#
# Line NUMBER and reason only, never the line's text -- the same rule common.sh follows
# for the same reason. This prints to a terminal that a person is reading.
if [ -L "$BASE/config.env" ]; then
  # Same refusal common.sh reaches, for the same reason: git carries the link, so a clone
  # chooses a file outside the project to be read. Whole-file, so no line number.
  CONFIG_REFUSED=1
  printf 'REFUSED  %-18s %-30s config.env is a symbolic link, so it is not read at all\n' "config.env" ""
  printf '         %-18s %-30s the hooks refuse it too — replace the link with the file\n' "" ""
elif [ -f "$BASE/config.env" ]; then
  CONFIG_LINES="$(
    # Both are reset, not just the one read back: jit_load_config() appends to the list
    # and increments the count, and common.sh has already run it once against the SESSION
    # config. Inheriting either would report this tree as carrying another tree lines.
    JIT_CONFIG_REFUSED=""
    # Incremented by jit_load_config() in common.sh, which shellcheck cannot see here.
    # shellcheck disable=SC2034
    JIT_CONFIG_REFUSED_N=0
    jit_load_config "$BASE/config.env"
    printf '%s' "$JIT_CONFIG_REFUSED"
  )"
  if [ -n "$CONFIG_LINES" ]; then
    while IFS= read -r _cl; do
      [ -n "$_cl" ] || continue
      CONFIG_REFUSED=$((CONFIG_REFUSED + 1))
      printf 'REFUSED  %-18s %-30s %s\n' "config.env" "" "${_cl#- }"
    done <<CONFIG_EOF
$CONFIG_LINES
CONFIG_EOF
    printf '         %-18s %-30s those lines do not take effect — the hooks read this file as plain KEY=VALUE\n' "" ""
  else
    printf 'ok       %-18s %-30s every line honoured\n' "config.env" ""
  fi
else
  printf 'ok       %-18s %-30s no config.env in this tree\n' "config.env" ""
fi

check_pattern() {
  # $1 layer label, $2 rule file, $3 pattern
  local label="$1" file="$2" pat="$3" why engine hint=""

  # Patterns travel through the environment, never through awk -v: a -v assignment
  # processes escape sequences in its value, which would silently repair or mangle the
  # very backslash under test before the check ever sees it.
  why="$(JIT_PAT="$pat" awk "$JIT_AWK_GUARD"'BEGIN { print jit_bad_pattern(ENVIRON["JIT_PAT"]) }')"

  if JIT_PAT="$pat" awk 'BEGIN { if (match("", ENVIRON["JIT_PAT"])) x = 1 }' >/dev/null 2>&1; then
    engine="accepted"
  else
    engine="FATAL — this row alone silences every rule in its index"
    [ -z "$why" ] && why="rejected by the local awk"
  fi

  CHECKED=$((CHECKED + 1))
  if [ -n "$why" ]; then
    case "$why" in
      "undefined escape "*) hint=" — use a POSIX class such as [[:space:]], [0-9] or [A-Za-z0-9_]" ;;
    esac
    REFUSED=$((REFUSED + 1))
    printf 'REFUSED  %-18s %-30s %s%s\n' "$label" "$file" "$why" "$hint"
    printf '         %-18s %-30s engine: %s\n' "" "$pat" "$engine"
  else
    printf 'ok       %-18s %-30s engine: %s\n' "$label" "$file" "$engine"
  fi
}

# An entry file name is CONCATENATED onto its layer directory by every hook, so a name
# that is not bare escapes the tree — see jit_bad_entry_file in common.sh. The hooks now
# refuse such a row and say so in context, and that notice tells the reader to lint the
# tree here; this is the check that makes the advice true. Verdict from the same shared
# awk function the hooks use, never a second copy in bash that can drift from it.
# Returns 0 when the name is honourable, 1 when it was refused.
# The tree being linted is --base, which is not this session's project, so the symlink
# sweep common.sh already ran against JIT_BASE is about the wrong tree. Re-run it here or
# the linter would clear a row every hook refuses.
jit_scan_symlinks "$BASE"

check_entry_file() {
  # $1 layer label, $2 entry file name, $3 layer directory
  local label="$1" file="$2" dir="${3:-}" why
  why="$(JIT_ENTRY="$file" JIT_DIR="$dir" awk "$JIT_AWK_ENTRY"'BEGIN { print jit_bad_entry_file(ENVIRON["JIT_ENTRY"], ENVIRON["JIT_DIR"]) }')"
  [ -n "$why" ] || return 0
  printf 'REFUSED  %-18s %-30s %s\n' "$label" "$file" "$why"
  # Two different faults reach here and they need different second lines. "leaves the
  # tree" is true of a name carrying a separator and false of a link, whose name is bare;
  # printing it for both would send an author looking at the wrong column.
  case "$why" in
    # The whole-tree case FIRST: its reason contains the words "symbolic link", so the
    # narrower branch below would swallow it and print advice about replacing one link.
    *"too many symbolic links"*)
      printf '         %-18s %-30s the set of links did not fit the budget the hooks carry it in, so none of this tree could be vouched for\n' "" "" ;;
    *"symbolic link"*)
      printf '         %-18s %-30s the hook would follow it out of the tree — replace the link with the file\n' "" "" ;;
    *"begins with a dot"*)
      # A third fault with a third second line. This row does not leave the tree and is not
      # itself a link — it is a name the link sweep could never lstat, because a glob does
      # not match a leading dot, so the link check above it was answering about nothing.
      printf '         %-18s %-30s a dot-name is invisible to the symbolic-link sweep, and rebuild-tsv.sh never writes one\n' "" "" ;;
    *)
      printf '         %-18s %-30s the hook reads <layer>/<name>, so this row leaves the tree\n' "" "" ;;
  esac
  return 1
}

# An entry whose frontmatter no longer agrees with its index row is INERT, and inert in
# the way this whole repo is shaped around: nothing errors, nothing warns, the rule simply
# never fires. Reading the index used to be enough to spot it, because the index carried
# the author's own text. With an invocation macro it no longer does -- the row is the
# expansion -- so the check that used to be an eyeball is done here instead.
#
# 00-manual only. The other layers are generated by tooling that does not read markdown,
# so comparing them to a .md file would report drift that means nothing.
STALE=0

check_index_current() {
  # $1 layer dir, $2 dimension (tools|paths), $3 label
  #
  # The whole ROW is rebuilt from the frontmatter and looked for verbatim, not just the
  # pattern. `match` is the column an author edits most, but it is not the only one that
  # decides what the rule does: a `block` downgraded to `remind`, a `require` dropped, a
  # rule retargeted at another tool -- each of those is a rule that reads as enforced and
  # is not, and none of them shows up anywhere else. Comparing the row costs the same.
  local dir="$1" dim="$2" label="$3" md name want tool mode require forbid row
  [ -d "$dir" ] || return 0
  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    name="$(basename "$md")"
    [ "$name" = "00-README.md" ] && continue
    want="$(jit_frontmatter match "$md")"
    [ -n "$want" ] || continue
    if [ "$dim" = tools ]; then
      tool="$(jit_frontmatter tool "$md")"
      # rebuild-tsv.sh skips a tools entry with no `tool:`, so this lint must skip it
      # too -- otherwise every vocabulary-shaped file in the directory reads as stale.
      [ -n "$tool" ] || continue
      mode="$(jit_frontmatter mode "$md")"
      require="$(jit_frontmatter require "$md")"
      forbid="$(jit_frontmatter forbid "$md")"
    fi
    want="$(jit_expand_match "$want" "$dim" "$label/$name" 2>/dev/null)"
    if [ "$dim" = tools ]; then
      row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$tool" "$want" "$name" "${mode:-remind}" "$require" "$forbid")"
    else
      row="$(printf '%s\t%s' "$want" "$name")"
    fi
    if ! JIT_ROW="$row" awk '
      $0 == ENVIRON["JIT_ROW"] { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$dir/00-index.tsv" 2>/dev/null; then
      STALE=$((STALE + 1))
      printf 'STALE    %-18s %-30s frontmatter and index disagree — this rule is not the one running\n' "$label" "$name"
      printf '         %-18s %-30s run scripts/rebuild-tsv.sh in that tree and commit the index\n' "" ""
    fi
  done
}

for tsv in "$BASE"/tools/*/00-index.tsv; do
  [ -f "$tsv" ] || continue
  INDEXES=$((INDEXES + 1))
  label="tools/$(basename "$(dirname "$tsv")")"
  while IFS=$'\t' read -r r_tool r_match r_file _rest; do
    [ -n "${r_match:-}" ] || continue
    [ -n "${r_file:-}" ] || continue
    LISTED=$((LISTED + 1))
    check_entry_file "$label" "$r_file" "$(dirname "$tsv")" || { REFUSED=$((REFUSED + 1)); continue; }
    # A bare match is a substring test (index()), not a regex — nothing to compile.
    case "$r_match" in
      "~"*) check_pattern "$label" "$r_file" "${r_match#\~}" ;;
      *)    printf 'ok       %-18s %-30s substring, not a regex (tool %s)\n' "$label" "$r_file" "$r_tool" ;;
    esac
  done < "$tsv"
done

for tsv in "$BASE"/paths/*/00-index.tsv; do
  [ -f "$tsv" ] || continue
  INDEXES=$((INDEXES + 1))
  label="paths/$(basename "$(dirname "$tsv")")"
  while IFS=$'\t' read -r p_match p_file _rest; do
    [ -n "${p_match:-}" ] || continue
    [ -n "${p_file:-}" ] || continue
    LISTED=$((LISTED + 1))
    check_entry_file "$label" "$p_file" "$(dirname "$tsv")" || { REFUSED=$((REFUSED + 1)); continue; }
    check_pattern "$label" "$p_file" "$p_match"
  done < "$tsv"
done

# Vocabulary has no patterns to compile — its rows are literal keywords and literal path
# fragments — so it never appeared here. It has three of the five entry-file read sites,
# which is exactly the thing this lint now checks, so it is swept for that alone. Silent
# on a clean tree: a vocabulary index is not "checked" in the sense the counts above mean.
for tsv in "$BASE"/vocabulary/*/00-index.tsv "$BASE"/vocabulary/*/01-paths.tsv; do
  [ -f "$tsv" ] || continue
  label="vocabulary/$(basename "$(dirname "$tsv")")"
  while IFS=$'\t' read -r _v_key v_file _rest; do
    [ -n "${v_file:-}" ] || continue
    # Counted apart from REFUSED, which is a subset of the rules the summary line says
    # were indexed and compiled. Folding these in printed "2 refused" under "1 rule
    # indexed", which is the kind of arithmetic that makes a reader distrust the tool.
    check_entry_file "$label" "$v_file" "$(dirname "$tsv")" || VOCAB_REFUSED=$((VOCAB_REFUSED + 1))
  done < "$tsv"
done

if [ "$INDEXES" -eq 0 ]; then
  echo "SKIPPED: no 00-index.tsv under $BASE."
  echo "         Entries are inert until indexed — run scripts/rebuild-tsv.sh in that tree."
  echo "         Nothing was checked. This is not a clean result."
  exit 2
fi

# After the INDEXES check, so a tree with no index at all is reported as unevaluated
# rather than as a wall of stale entries.
check_index_current "$BASE/tools/00-manual" tools "tools/00-manual"
check_index_current "$BASE/paths/00-manual" paths "paths/00-manual"

echo ""
# Two counts, not one: a substring row has no regex to compile, so folding it into the
# checked total would report coverage the run does not have.
echo "$LISTED rule(s) indexed, $CHECKED regex pattern(s) compiled, $REFUSED refused."
if [ "$STALE" -gt 0 ]; then
  echo "$STALE entry file(s) whose frontmatter is not what the index carries."
  echo "Those rules are inert: the hooks read the index, never the markdown."
fi
if [ "$VOCAB_REFUSED" -gt 0 ]; then
  echo "$VOCAB_REFUSED vocabulary row(s) refused on the entry file name."
  echo "Vocabulary carries no patterns, so it is swept for that alone and never counted above."
fi
if [ "$CONFIG_REFUSED" -gt 0 ]; then
  echo "$CONFIG_REFUSED config.env line(s) refused. They are settings that do not apply."
  echo "If a refused line is not one you wrote, treat that file as hostile — it arrived with the repository."
fi

# --- Phase 2: which rule fires for this call? --------------------------------

# The sample call is hand-built JSON, so it has to be escaped into it. What the caller
# typed is what the hooks see, character for character:
#
#   "   escaped. Unescaped, it ended the value early and the rule was dry-run against a
#       command nobody typed — the tool reporting "no rule fired" for a rule that fires.
#   \   escaped. Passing it through would let jit_unescape() read it back as a JSON
#       escape, so `--file 'C:\test\x'` linted as `C:<TAB>est\x`, and a sample ending in a
#       backslash escaped the closing quote and broke the payload outright.
#   NL  folded to its escape, so a command pasted across lines ($'a\nb', a heredoc) is
#       dry-run as the multi-line command it is instead of being silently joined.
#
# Built by hand rather than with gsub: a backslash in a gsub REPLACEMENT has its own layer
# of meaning, and getting that count right is exactly the kind of thing that is wrong in
# one awk and right in another.
json_quote() {
  printf '%s' "$1" | awk '{
    o = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "\\") o = o "\\\\"
      else if (c == "\"") o = o "\\\""
      else if (c == "\t") o = o "\\t"
      else o = o c
    }
    printf "%s%s", sep, o
    sep = "\\n"
  }'
}

report_hook() {
  # $1 hook script, $2 JSON payload, $3 project dir
  local out names verdict
  out="$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$3" bash "$SCRIPT_DIR/$1" 2>/dev/null)"
  # Anchored on .md, because the refusal notice this same hook injects is headed
  # "# JIT Context: N rule(s) could not be evaluated" — an unanchored read picks up N
  # and prints it as a rule that fired, which is a non-match reading as a match.
  names="$(printf '%s' "$out" | grep -o -E '(JIT Context|Vocabulary): [^ ]+\.md' | sed 's/^[^:]*: //' | tr '\n' ' ')"
  case "$out" in
    *'"decision":"block"'*) verdict="BLOCK  " ;;
    *) verdict="       " ;;
  esac
  case "$out" in
    *"could not be evaluated"*) printf '  NOTE   %-20s the hook injected a refusal notice — see the REFUSED rows above\n' "$1" ;;
  esac
  # A hook that matched nothing must not read as a hook that fired. That confusion is
  # the whole defect this script exists for; do not reintroduce it in its own output.
  if [ -z "$names" ]; then
    printf '  %s%-20s no rule fired\n' "$verdict" "$1"
  else
    printf '  %s%-20s %s\n' "$verdict" "$1" "$names"
  fi
}

if [ -n "$SAMPLE_TOOL$SAMPLE_COMMAND$SAMPLE_FILE$SAMPLE_PROMPT" ]; then
  echo ""
  case "$BASE" in
    */.claude/jit-context)
      PROJECT="${BASE%/.claude/jit-context}"
      echo "sample call against $PROJECT"
      if [ -n "$SAMPLE_PROMPT" ]; then
        report_hook pre-prompt-hook.sh "{\"prompt\":\"$(json_quote "$SAMPLE_PROMPT")\"}" "$PROJECT"
      fi
      # A file target goes to BOTH hooks under the tool the caller named. The tool
      # dimension matches file_path when there is no command — a `block` rule guarding
      # Edit of a generated file is only reachable this way, and routing --file to the
      # path hook alone reported it as not firing when the rule was fine.
      if [ -n "$SAMPLE_FILE" ]; then
        payload="{\"tool_name\":\"${SAMPLE_TOOL:-Read}\",\"tool_input\":{\"file_path\":\"$(json_quote "$SAMPLE_FILE")\"}}"
        report_hook pre-tool-hook.sh "$payload" "$PROJECT"
        report_hook pre-path-hook.sh "$payload" "$PROJECT"
      fi
      if [ -n "$SAMPLE_COMMAND" ]; then
        payload="{\"tool_name\":\"${SAMPLE_TOOL:-Bash}\",\"tool_input\":{\"command\":\"$(json_quote "$SAMPLE_COMMAND")\"}}"
        report_hook pre-tool-hook.sh "$payload" "$PROJECT"
        report_hook pre-path-hook.sh "$payload" "$PROJECT"
      fi
      if [ -n "$SAMPLE_TOOL" ] && [ -z "$SAMPLE_COMMAND$SAMPLE_FILE$SAMPLE_PROMPT" ]; then
        echo "  SKIPPED: --tool needs a target. Add --command or --file."
      fi
      ;;
    *)
      echo "SKIPPED sample call: --base is not a <project>/.claude/jit-context path,"
      echo "        so there is no project dir to run the hooks against."
      ;;
  esac
fi

[ "$REFUSED" -eq 0 ] && [ "$VOCAB_REFUSED" -eq 0 ] && [ "$STALE" -eq 0 ] \
  && [ "$CONFIG_REFUSED" -eq 0 ] || exit 1
exit 0
