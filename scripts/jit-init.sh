#!/bin/bash
# claude-jit-context — seed a project with the three dimensions and one starter entry.
#
# Why this exists: a fresh install matches nothing and injects nothing (#81). The hooks
# create only the .discovery machinery — no paths/, no tools/, no vocabulary/, and no
# entries — so the first-run experience is "install it, and nothing happens", and the one
# question a new user is guaranteed to ask is the one the plugin could answer with its own
# mechanism, at the moment they ask it.
#
# This copies ONE vocabulary entry into the project, explicitly, on request. The file is
# then the user's: theirs to edit, theirs to delete. Nothing is shipped into a repository
# unasked, and no hook reads a rule from outside the project directory.
#
# Usage:
#   bash scripts/jit-init.sh                     # seed ./.claude/jit-context
#   bash scripts/jit-init.sh --base DIR          # seed DIR, which must end in
#                                                #   /.claude/jit-context
#
# Exit: 0 seeded, and the index rebuilt so the entry is live | 1 refused — the entry is
#       already there and a copy you edited is not ours to replace, or the rebuild did
#       not complete and the entry is on disk and inert | 2 could not evaluate: a bad
#       argument, a --base that is not a <project>/.claude/jit-context path, a symbolic
#       link on the way in, an install with no template to copy, or a directory that
#       could not be created.
#
# This is tooling, not a hook. It is run deliberately, by a person, and it fails loudly —
# the opposite of scripts/*-hook.sh, which must never fail at all. See
# .claude/jit-context/paths/00-manual/tooling.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# common.sh is deliberately NOT sourced, for the reason jit-misses.sh does not source it
# either: it mkdir -p's the log directory under $CLAUDE_PROJECT_DIR at load time, which is
# not necessarily the project being seeded here. A tool that creates a directory in a
# third place on the way to creating one where you asked is a tool whose receipt lies.
TEMPLATE_ROOT="$SCRIPT_DIR/../templates/jit-context"
SEED_REL="vocabulary/00-manual/writing-rules.md"

BASE="$PWD/.claude/jit-context"

usage() {
  # The header block, to the first non-comment line. Read structurally rather than as a
  # line range: jit-dry-run.sh pins '2,27p', and a line added above that range truncates
  # its --help with nothing to say so.
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)    BASE="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

BASE="${BASE%/}"

# Resolved to an absolute path BEFORE the suffix is stripped. mkdir and cp are perfectly
# happy with a relative --base, but the project dir below is derived by removing
# /.claude/jit-context from the end, and `.claude/jit-context` has no leading slash to
# strip against: the derivation yields nothing, rebuild-tsv.sh resolves JIT_BASE from an
# empty $CLAUDE_PROJECT_DIR, and the entry lands in one tree while its index is built in
# another. A seeded rule that can never fire, reported as success.
#
# A Windows drive path (C:/x, C:\x) is already absolute and must not be prefixed. Git Bash
# is a CI leg here, and $PWD/C:/x is not a path on any platform.
case "$BASE" in
  /* | ?:/* | ?:\\*) ;;
  *) BASE="$PWD/$BASE" ;;
esac

case "$BASE" in
  */.claude/jit-context) PROJECT="${BASE%/.claude/jit-context}" ;;
  *)
    echo "SKIPPED: --base must end in /.claude/jit-context — the hooks resolve rules from" >&2
    echo "         <project>/.claude/jit-context and nowhere else, so seeding any other" >&2
    echo "         directory would write entries that can never fire. Got: $BASE" >&2
    exit 2
    ;;
esac

SEED="$BASE/$SEED_REL"
TEMPLATE="$TEMPLATE_ROOT/$SEED_REL"

if [ ! -f "$TEMPLATE" ]; then
  echo "SKIPPED: no entry to seed — $TEMPLATE is missing." >&2
  echo "         That is an incomplete install, not an empty project. Nothing was written." >&2
  exit 2
fi

# A linked component is refused rather than followed: the write would land outside the
# tree you named, and "seeded <path>" would then be a receipt for a file somewhere else.
# EVERY component on the way to the entry, not just the two nearest the project root — a
# linked `vocabulary/` or `vocabulary/00-manual/` put the entry and its whole index outside
# the tree while the receipt still named a path inside it, which is worse than the escape.
# mkdir -p follows a link silently and cp writes through one, so neither of them can be
# the check.
LINKED=""
for part in "$PROJECT/.claude" "$BASE"; do
  [ -L "$part" ] && LINKED="$part"
done
for dim in vocabulary paths tools; do
  [ -L "$BASE/$dim" ] && LINKED="$BASE/$dim"
  [ -L "$BASE/$dim/00-manual" ] && LINKED="$BASE/$dim/00-manual"
done
if [ -n "$LINKED" ]; then
  echo "SKIPPED: $LINKED is a symbolic link. Writing through it would put entries outside" >&2
  echo "         the tree you named. Nothing was written." >&2
  exit 2
fi

# Refuse BEFORE creating anything, so a re-run against an edited copy is inert in every
# respect rather than only in the copy.
if [ -e "$SEED" ] || [ -L "$SEED" ]; then
  echo "REFUSED: $SEED_REL is already there." >&2
  echo "         $SEED" >&2
  echo "         A copy you edited is not ours to replace. Delete it first if you want the" >&2
  echo "         shipped text back, or leave it alone — it is your file now." >&2
  echo "         Nothing was created and nothing was changed by this run." >&2
  exit 1
fi

for dim in vocabulary paths tools; do
  if ! mkdir -p "$BASE/$dim/00-manual"; then
    echo "SKIPPED: could not create $BASE/$dim/00-manual — nothing was seeded." >&2
    exit 2
  fi
done

if ! cp "$TEMPLATE" "$SEED"; then
  echo "SKIPPED: could not write $SEED — nothing was seeded." >&2
  exit 2
fi

echo "seeded  $SEED"

# An entry that has not been indexed is inert, and inert in silence — which is the very
# trap the entry just written is about. Leaving the rebuild to the reader would ship that
# trap as the first thing the plugin ever does.
REBUILD="$SCRIPT_DIR/rebuild-tsv.sh"
if [ ! -f "$REBUILD" ]; then
  echo "SKIPPED: $REBUILD is missing, so the index was not rebuilt and the entry just" >&2
  echo "         written cannot fire. Run rebuild-tsv.sh yourself." >&2
  exit 2
fi

if ! CLAUDE_PROJECT_DIR="$PROJECT" bash "$REBUILD" > /dev/null 2>&1; then
  echo "REFUSED: rebuild-tsv.sh did not complete, so the entry is on disk and inert." >&2
  echo "         Run it yourself and read what it says:" >&2
  echo "           CLAUDE_PROJECT_DIR=$PROJECT bash $REBUILD" >&2
  exit 1
fi

echo "indexed $BASE/vocabulary/00-manual/00-index.tsv"
echo ""
echo "It fires on a prompt about writing entries, and on nothing else. Drive it both ways:"
echo "  bash $SCRIPT_DIR/jit-dry-run.sh --base $BASE --prompt \"how do I write a jit entry\""
echo ""
echo "Then write your own beside it, and rebuild:"
echo "  CLAUDE_PROJECT_DIR=$PROJECT bash $REBUILD"
exit 0
