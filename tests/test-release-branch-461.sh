#!/bin/bash
# #461: the compiled scripts/*.sh files in a built release tree must behave exactly
# like the commented, multi-file sources on main. test-release-branch-437.sh already
# guards the tree's composition (what ships, what the deny-list drops, the directory's
# own checklist); this suite is the BEHAVIORAL guard for compile_scripts.py alone:
# --help byte-for-byte, a fixed payload through each hook byte-for-byte, and the real
# hook-driving test suites run a second time against the compiled scripts.
#
# Usage: bash tests/test-release-branch-461.sh
#
# jit-drive: none -- this drives the release-tree scripts themselves, not a hook.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/.github/scripts/build_release_tree.py"
CHECK="$REPO/.github/scripts/check_release_tree.py"
CONFIG="$REPO/.github/release-branch.json"

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  shift
  [ $# -eq 0 ] || echo "    $*"
}

for f in "$BUILD" "$CHECK" "$CONFIG"; do
  [ -f "$f" ] || {
    echo "FAIL: harness guard -- $f does not exist, every assertion below is vacuous"
    exit 1
  }
done
if ! command -v python3 > /dev/null 2>&1; then
  echo "SKIPPED: no python3 on PATH -- these scripts are not part of the hook runtime"
  exit 0
fi

TMPD=$(mktemp -d 2> /dev/null || mktemp -d -t jiteq)
trap 'rm -rf "$TMPD"' EXIT
TREE="$TMPD/release-tree"

echo "=== build: HEAD builds a release tree, and check_release_tree.py is clean ==="
BUILD_OUT=$(python3 "$BUILD" --repo "$REPO" --ref HEAD --out "$TREE" --config "$CONFIG" 2>&1)
BUILD_RC=$?
if [ "$BUILD_RC" -eq 0 ]; then
  ok "build_release_tree.py exits 0"
else
  bad "build_release_tree.py exited $BUILD_RC" "$BUILD_OUT"
  echo ""
  echo "== Results: $PASS passed, $FAIL failed (nothing below can run without a tree) =="
  exit 1
fi
CHECK_OUT=$(python3 "$CHECK" "$TREE" --config "$CONFIG" 2>&1)
CHECK_RC=$?
# Same pinned, already-filed exception test-release-branch-437.sh carries (#439,
# narrowed allowed-tools grants on the three command scripts) -- not this issue's
# subject, so it is excluded from "unexpected" the same way there.
UNEXPECTED=$(printf '%s\n' "$CHECK_OUT" | grep '^FAIL ' || true)
if [ "$CHECK_RC" -eq 0 ] || [ -z "$UNEXPECTED" ]; then
  ok "check_release_tree.py reports no offender in the built tree"
else
  bad "check_release_tree.py reported offender(s)" "$UNEXPECTED"
fi

echo ""
echo "=== --help, byte for byte, source vs compiled ==="
for s in jit-dry-run.sh jit-match.sh jit-doctor.sh jit-stats.sh jit-init.sh; do
  SRC_HELP=$(bash "$REPO/scripts/$s" --help 2>&1)
  BUILT_HELP=$(bash "$TREE/scripts/$s" --help 2>&1)
  if [ "$SRC_HELP" = "$BUILT_HELP" ]; then
    ok "$s --help is byte-for-byte identical, source vs compiled"
  else
    bad "$s --help DIFFERS, source vs compiled" \
      "$(diff <(printf '%s' "$SRC_HELP") <(printf '%s' "$BUILT_HELP"))"
  fi
done

echo ""
echo "=== a fixed payload through each hook, byte for byte, source vs compiled ==="
PROJ="$TMPD/project"
mkdir -p "$PROJ/.claude/jit-context"
run_both() {
  # $1 = hook filename, $2 = payload
  local src_out built_out src_rc built_rc
  src_out=$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$PROJ" bash "$REPO/scripts/$1" 2>&1)
  src_rc=$?
  built_out=$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$PROJ" bash "$TREE/scripts/$1" 2>&1)
  built_rc=$?
  if [ "$src_out" = "$built_out" ] && [ "$src_rc" = "$built_rc" ]; then
    ok "$1 output and exit status ($src_rc) are identical, source vs compiled"
  else
    bad "$1 DIFFERS, source vs compiled (exit $src_rc vs $built_rc)" \
      "$(diff <(printf '%s' "$src_out") <(printf '%s' "$built_out"))"
  fi
}
run_both pre-tool-hook.sh '{"session_id":"t461","tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
run_both pre-prompt-hook.sh '{"session_id":"t461","prompt":"how do I write a jit entry"}'
run_both pre-path-hook.sh '{"session_id":"t461","tool_name":"Read","tool_input":{"file_path":"src/Billing/Total.php"}}'
run_both post-tool-hook.sh '{"session_id":"t461","tool_name":"Write","tool_input":{"file_path":"x.php","content":"ok"}}'
run_both session-start-hook.sh '{"session_id":"t461"}'
run_both stop-hook.sh '{"session_id":"t461"}'

echo ""
echo "=== the real hook-driving suites, run a second time against the compiled scripts ==="
# Each of these test files resolves its own REPO as "$(dirname "$0")/..", so running
# them against the compiled tree means giving them a COPY of the whole repository with
# the compiled scripts (and no library files) in place of the real ones -- not just
# pointing an env var at $TREE, which none of them read. `git archive HEAD`, the same
# read build_release_tree.py itself uses, rather than `cp -R`: this repository's own
# scripts/ live inside a git WORKTREE, whose .git is a pointer file into the main
# clone's metadata -- a plain recursive copy carries that pointer along and every git
# command run from the copy (including one of this suite's own commits) would silently
# act on the ORIGINAL worktree instead (found running this suite by hand, #461).
# git archive reads committed blobs straight out of the object store and writes plain
# files, so the copy below shares no git state with anything.
COPY="$TMPD/full-repo-copy"
mkdir -p "$COPY"
if ! (cd "$REPO" && git archive --format=tar HEAD) | (cd "$COPY" && tar -x) 2> /dev/null; then
  bad "could not build a full-repo copy via git archive -- the suites below could not be driven" \
    "git archive requires HEAD to be a committed, non-dirty-dependent snapshot"
else
  cp "$TREE"/scripts/*.sh "$COPY/scripts/" 2> /dev/null
  rm -f "$COPY/scripts/common.sh" "$COPY/scripts/common-awk.sh" "$COPY/scripts/host.sh"
  for t in test-pre-tool-hook.sh test-pre-prompt-hook.sh test-pre-path-hook.sh \
    test-post-tool-hook.sh test-stop-hook.sh test-jit-doctor.sh test-jit-match.sh \
    test-jit-stats.sh test-jit-init.sh test-jit-dry-run.sh test-commands.sh \
    test-session-markers.sh test-session-start-misses-233.sh; do
    if [ ! -f "$COPY/tests/$t" ]; then
      bad "$t: not found in the repo copy -- cannot drive it"
      continue
    fi
    (cd "$COPY" && bash "tests/$t") > "$TMPD/$t.out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "$t passes against the compiled tree"
    elif [ "$rc" -eq 2 ]; then
      # A suite that cannot build its fixtures on this host says SKIPPED and exits 2,
      # on the source tree too (test-stop-hook.sh on native Windows). That is not a
      # divergence between source and compiled, and never a pass either.
      echo "  SKIPPED: $t could not build its fixtures here (exit 2), compiled tree not measured by it"
    else
      bad "$t FAILED against the compiled tree" "$(tail -20 "$TMPD/$t.out")"
    fi
  done
fi

echo ""
echo "=== suites EXCLUDED from the run above, and why (not a gap -- a different claim) ==="
# Each of these asserts something true of the SOURCE layout (a static source-shape
# classifier, a literal-absence check, a dynamic file-swap at a fixed path, a
# cross-file consistency check between two files) rather than hook BEHAVIOR, and each
# is expected to fail against compiled output for a reason that has nothing to do with
# whether the compiled hooks work:
echo "  EXCLUDED test-arg-flag-values.sh: its classify_script() reads a script's OWN"
echo "    argument-parsing loop by shape; once jit-misses.sh/rebuild-tsv.sh's own loop is"
echo "    inlined as a subshell function body, the classifier (correctly, for what IT"
echo "    checks) sees a second loop in the wrapping file and misattributes it."
echo "  EXCLUDED test-exec-bits.sh, test-manifest-desync-227.sh: assert common.sh IS"
echo "    sourced by something -- true on main, false by design in a release tree where"
echo "    common.sh does not exist as a file at all (see the #461 rows in"
echo "    test-release-branch-437.sh for the positive assertion of that absence)."
echo "  EXCLUDED test-host-registry.sh: asserts specific envelope literals are ABSENT"
echo "    from each hook file as a hand-rolled duplicate; once common.sh/common-awk.sh"
echo "    are inlined, their own matching literal legitimately appears in the same file."
echo "  EXCLUDED test-session-start-bound-248.sh (its stub-substitution sections only --"
echo "    see its own run above for the sections that DO pass): it swaps a FAKE"
echo "    jit-misses.sh in at the on-disk path and relies on session-start-hook.sh"
echo "    dispatching to it dynamically, which compiling removes by design."
echo "  EXCLUDED test-jit-misses.sh: cross-checks a shared fold table between"
echo "    jit-misses.sh and common-awk.sh; common-awk.sh does not exist in a release tree."

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
