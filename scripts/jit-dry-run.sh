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
# This reads the tree you point it at, and answers two questions the hooks cannot:
#   1. can every match pattern actually be honoured?   (a rule that never runs)
#   2. which rule fires for this call?                 (a rule that never matches)
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
# Exit: 0 every pattern honourable | 1 at least one refused | 2 could not evaluate.

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
CHECKED=0
LISTED=0
INDEXES=0

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

for tsv in "$BASE"/tools/*/00-index.tsv; do
  [ -f "$tsv" ] || continue
  INDEXES=$((INDEXES + 1))
  label="tools/$(basename "$(dirname "$tsv")")"
  while IFS=$'\t' read -r r_tool r_match r_file _rest; do
    [ -n "${r_match:-}" ] || continue
    [ -n "${r_file:-}" ] || continue
    # A bare match is a substring test (index()), not a regex — nothing to compile.
    case "$r_match" in
      "~"*) check_pattern "$label" "$r_file" "${r_match#\~}" ;;
      *)    printf 'ok       %-18s %-30s substring, not a regex (tool %s)\n' "$label" "$r_file" "$r_tool" ;;
    esac
    LISTED=$((LISTED + 1))
  done < "$tsv"
done

for tsv in "$BASE"/paths/*/00-index.tsv; do
  [ -f "$tsv" ] || continue
  INDEXES=$((INDEXES + 1))
  label="paths/$(basename "$(dirname "$tsv")")"
  while IFS=$'\t' read -r p_match p_file _rest; do
    [ -n "${p_match:-}" ] || continue
    [ -n "${p_file:-}" ] || continue
    check_pattern "$label" "$p_file" "$p_match"
    LISTED=$((LISTED + 1))
  done < "$tsv"
done

if [ "$INDEXES" -eq 0 ]; then
  echo "SKIPPED: no 00-index.tsv under $BASE."
  echo "         Entries are inert until indexed — run scripts/rebuild-tsv.sh in that tree."
  echo "         Nothing was checked. This is not a clean result."
  exit 2
fi

echo ""
# Two counts, not one: a substring row has no regex to compile, so folding it into the
# checked total would report coverage the run does not have.
echo "$LISTED rule(s) indexed, $CHECKED regex pattern(s) compiled, $REFUSED refused."

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

[ "$REFUSED" -eq 0 ] || exit 1
exit 0
