#!/bin/bash
# What the once-per-session marker must do when it CANNOT be used.
#
# The marker is a convenience: it stops an entry being repeated inside one session. The
# injection is the product. Until 2026-08-12 that priority was inverted by accident --
# `jit_shown_mark()` was `print key >> file` inside awk END, and an unopenable path is a
# FATAL awk error. awk died before the final `print`, so a rule that was indexed, matched
# and had something to say produced nothing, exited 0, and printed an awk diagnostic into
# the session stderr (#50). Failing OPEN and being LOUD -- the two things the
# `JIT_SYMLINKS` cap comment in common.sh already names as forbidden -- in one statement.
#
# The same statement followed a symbolic link, because awk cannot lstat and bash did not
# know the path (#49). The marker got none of the five `[ -L ]` tests the log got.
#
# Both are fixed the same way: awk no longer opens the marker for writing at all. It hands
# the (path, key) pairs back to bash over the temp channel each hook already uses for its
# log line, and bash does the append -- which is where `[ -L ]` is a shell builtin and a
# failed redirect is `2>/dev/null` rather than a dead process.
#
# THE GUARD THIS SUITE NEEDS. Every assertion of the form "stderr was silent" is worthless
# on its own: a hook that never ran satisfies it. So every silence assertion here is made
# on the SAME call as a "the entry arrived" assertion, and every section that constructs a
# broken marker is preceded by the same fixture with a healthy one. Section A is the
# harness control: if it fails, nothing below this line means anything.
#
# Usage: bash tests/test-marker-degradation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

# Substring matching is `case`, never `echo "$x" | grep -q`: grep -q exits at the first
# match and closes the pipe under it, which makes the producer die of SIGPIPE and turns a
# passing assertion into a red one at random (#56). `case` forks nothing and reads the
# whole string.
# jit-drive: assert_contains contains capture
assert_contains() {
  local desc="$1" output="$2" needle="$3"
  case "$output" in
    *"$needle"*)
      PASS=$((PASS + 1))
      echo "  PASS: $desc"
      ;;
    *)
      FAIL=$((FAIL + 1))
      echo "  FAIL: $desc"
      echo "    expected to contain: $needle"
      echo "    got: ${output:-<EMPTY>}"
      ;;
  esac
}

assert_equal() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected: [$want]"
    echo "    got:      [$got]"
  fi
}

assert_silent() {
  local desc="$1" err="$2"
  if [ -z "$err" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    stderr should have been empty, got: $err"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    this path should exist and be a regular file: $path"
  fi
}

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
ERR="$TMP/stderr"

# A project with one path rule that fires on the payload below.
new_path_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/paths/00-manual" \
    "$p/.claude/jit-context/paths/10-auto" \
    "$p/.claude/jit-context/paths/20-grouped" \
    "$p/.claude/jit-context/paths/30-crosscutting"
  printf '%s\t%s\n' '\.php' 'php-coding.md' > "$p/.claude/jit-context/paths/00-manual/00-index.tsv"
  printf 'php coding rules\n' > "$p/.claude/jit-context/paths/00-manual/php-coding.md"
  : > "$p/.claude/jit-context/paths/10-auto/00-index.tsv"
  : > "$p/.claude/jit-context/paths/20-grouped/00-index.tsv"
  : > "$p/.claude/jit-context/paths/30-crosscutting/00-index.tsv"
  printf '%s' "$p"
}

# A project with one tool rule that BLOCKS. $2 is the modes column, so the same fixture
# drives `block` and `block,once` -- the two sides of the boundary claim in #50.
new_tool_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/tools/00-manual" \
    "$p/.claude/jit-context/vocabulary/00-manual" \
    "$p/.claude/jit-context/vocabulary/10-auto" \
    "$p/.claude/jit-context/vocabulary/20-grouped" \
    "$p/.claude/jit-context/vocabulary/30-crosscutting"
  printf 'Bash\tgit push\tno-push.md\t%s\t\tforce\n' "$2" \
    > "$p/.claude/jit-context/tools/00-manual/00-index.tsv"
  printf 'never force push\n' > "$p/.claude/jit-context/tools/00-manual/no-push.md"
  for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
    : > "$p/.claude/jit-context/vocabulary/$l/00-index.tsv"
  done
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }

# stdout is captured, stderr is captured SEPARATELY. Folding them together (2>&1, as the
# other suites do) is exactly what hid this class: the awk diagnostic would land in the
# same string the entry was asserted against.
run_path() {
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"src/a.php"}}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-path-hook.sh" 2> "$ERR"
}

run_tool() {
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git push --force"}}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SCRIPTS/pre-tool-hook.sh" 2> "$ERR"
}

echo "=== A: the harness control -- a healthy marker injects, records and dedups ==="
# Nothing below this line is evidence if this section is red.

P="$(new_path_project a)"
OUT1="$(run_path "$P" "sess-a")"
RC1=$?
E1="$(cat "$ERR")"
OUT2="$(run_path "$P" "sess-a")"
assert_rc0 "control: hook exits 0" "$RC1"
assert_contains "control: the entry is injected" "$OUT1" "php coding rules"
assert_silent "control: nothing on stderr" "$E1"
assert_file "control: the marker file was written" "$(state_of "$P")/path-shown-sess-a.txt"
assert_equal "control: the second call in the same session is silent" "$OUT2" "{}"

echo ""
echo "=== B: the marker path names a directory -- the entry still arrives (#50) ==="
# Deterministic, needing no race and no chmod: a name that cannot be opened as a file,
# because something else already holds it. This one used to lose the injection on both awks.
#
# STDERR IS NOT ASSERTED HERE, and that is the one place this change falls short of #50's
# "nothing on stderr". The write is silent now, but the READ still happens in awk -- only awk
# knows the session id -- and one-true-awk raises a fatal i/o error at exit on a path that
# opens and then cannot be read. The fix for that is a sweep of the state directory, which
# was written, measured at 238 ms on 8000 entries a cloned repository chooses, and removed;
# common.sh carries the table. Section B2 asserts silence on the routes that do not need the
# session id guessed. What is asserted here is the part that matters more: the rule that
# matched is still delivered.

P="$(new_path_project b)"
mkdir -p "$(state_of "$P")/path-shown-sess-b.txt"
OUT="$(run_path "$P" "sess-b")"
RC=$?
assert_rc0 "unopenable marker: hook exits 0" "$RC"
assert_contains "unopenable marker: THE ENTRY IS STILL INJECTED" "$OUT" "php coding rules"
OUT2="$(run_path "$P" "sess-b")"
assert_contains "unopenable marker: no dedup, so it is said again rather than lost" "$OUT2" "php coding rules"

echo ""
echo "=== B2: a marker that cannot be written is silent as well as harmless (#50) ==="
# The marker exists and reads fine, so awk never trips; only the append fails. That is the
# shape where "nothing on stderr" is fully assertable, and it caught a real regression: bash
# applies redirections left to right, so `>> "$f" 2>/dev/null` fails BEFORE stderr has been
# moved and prints into the session anyway.
#
# It is written with a key that is not the entry's, so the rule still has to fire: a marker
# holding "php-coding.md" would suppress it and every assertion below would pass for the
# wrong reason.

B2_SKIPPED=0
P="$(new_path_project b2)"
mkdir -p "$(state_of "$P")"
printf 'some-other-entry.md\n' > "$(state_of "$P")/path-shown-sess-b2.txt"
chmod 444 "$(state_of "$P")/path-shown-sess-b2.txt" 2> /dev/null
if [ -w "$(state_of "$P")/path-shown-sess-b2.txt" ]; then
  B2_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section B2 tested nothing."
else
  OUT="$(run_path "$P" "sess-b2")"
  RC=$?
  E="$(cat "$ERR")"
  assert_rc0 "unwritable marker: hook exits 0" "$RC"
  assert_contains "unwritable marker: THE ENTRY IS STILL INJECTED" "$OUT" "php coding rules"
  assert_silent "unwritable marker: nothing on the session stderr" "$E"
fi
chmod 644 "$(state_of "$P")/path-shown-sess-b2.txt" 2> /dev/null

echo ""
echo "=== B3: SessionStart clears a link or an empty directory at this session's marker ==="
# The O(1) half of what the removed sweep would have done, in the janitor where it costs
# nothing per prompt. `rm -f` already took a link; a directory needed `rmdir`, and the bare
# `rm -f` printed "is a directory" into the session while failing.

P="$(new_path_project b3)"
mkdir -p "$(state_of "$P")/path-shown-sess-b3.txt"
SS_ERR="$TMP/ss-stderr"
printf '{"session_id":"sess-b3","hook_event_name":"SessionStart"}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/session-start-hook.sh" > /dev/null 2> "$SS_ERR"
assert_silent "session-start: nothing on the session stderr" "$(cat "$SS_ERR")"
if [ -e "$(state_of "$P")/path-shown-sess-b3.txt" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: session-start left the directory at the marker name"
else
  PASS=$((PASS + 1))
  echo "  PASS: session-start cleared the directory at the marker name"
fi
OUT="$(run_path "$P" "sess-b3")"
E="$(cat "$ERR")"
assert_contains "and the hook then injects normally" "$OUT" "php coding rules"
assert_silent "and says nothing on stderr" "$E"

echo ""
echo "=== C: the state directory vanishes between the check and the write (#50) ==="
# The TOCTOU route, which needs no guessed session id. common.sh tests `[ -d ]` and
# `[ -w ]` on the state directory at load; the write happens later, in another process.
#
# Constructed rather than raced: the payload is written, then the producer sleeps a
# second, removes the directory, and only then closes the pipe. awk END cannot run before
# stdin closes, so the removal is ordered BEFORE the write by construction. The one thing
# not guaranteed is that the hook reached its pipeline within that second -- if it did
# not, JIT_STATE_DIR was already empty and this section tested nothing rather than failing
# wrongly. Section B covers the same code path with no timing at all.

P="$(new_path_project c)"
mkdir -p "$(state_of "$P")"
OUT="$({
  printf '{"session_id":"sess-c","tool_name":"Edit","tool_input":{"file_path":"src/a.php"}}'
  sleep 1
  rm -rf "$(state_of "$P")"
} | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/pre-path-hook.sh" 2> "$ERR")"
RC=$?
E="$(cat "$ERR")"
assert_rc0 "state dir removed mid-flight: hook exits 0" "$RC"
assert_contains "state dir removed mid-flight: THE ENTRY IS STILL INJECTED" "$OUT" "php coding rules"
assert_silent "state dir removed mid-flight: nothing on the session stderr" "$E"

echo ""
echo "=== D: a block decision survives an unusable marker, with and without once (#50) ==="
# #50 says pre-tool-hook.sh never loses a `block` by this route, because its tool-rule
# path only marks under `once`, and asks for that to be confirmed. It does not hold, in
# two independent ways:
#
#   - `modes: block,once` is a legal row. The mark at the top of the once branch runs
#     BEFORE require/forbid are evaluated, so the block is decided and then never printed.
#   - `modes: block` on its own loses it too, because jit_shown_load() reads the marker
#     before any rule is considered, and a read that cannot be performed is fatal on
#     one-true-awk just as the write is.
#
# Both halves are driven, each against its own positive control.

for MODES in "block" "block,once"; do
  TAG="${MODES//,/_}"
  P="$(new_tool_project "d-ok-$TAG" "$MODES")"
  OUT="$(run_tool "$P" "sess-d")"
  assert_contains "modes=$MODES control: a healthy marker blocks" "$OUT" '"decision":"block"'

  P="$(new_tool_project "d-bad-$TAG" "$MODES")"
  mkdir -p "$(state_of "$P")/vocab-shown-sess-d.txt"
  OUT="$(run_tool "$P" "sess-d")"
  RC=$?
  assert_rc0 "modes=$MODES unopenable marker: hook exits 0" "$RC"
  assert_contains "modes=$MODES unopenable marker: THE BLOCK IS STILL EMITTED" "$OUT" '"decision":"block"'
done

echo ""
# --- Can this platform make a symbolic link at all? --------------------------
# Section E is CONSTRUCTED with `ln -s`. On Git Bash the MSYS runtime copies the target
# instead of linking it, and then "nothing was written outside the tree" holds because the
# attack was never built. Verified through the link, which a copy cannot satisfy.
CAN_SYMLINK=no
probe_symlinks() {
  local d="$TMP/.symlink-probe"
  rm -rf "$d" || return 1
  mkdir -p "$d/target-dir" || return 1
  ln -sfn "$d/target-dir" "$d/link-dir" 2> /dev/null
  printf 'late\n' > "$d/target-dir/late.txt" || return 1
  [ -L "$d/link-dir" ] || return 1
  [ -f "$d/link-dir/late.txt" ] || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
SKIPPED_SECTIONS=0

if [ "$CAN_SYMLINK" != yes ]; then
  SKIPPED_SECTIONS=1
  echo "=== E SKIPPED: this platform did not create a symbolic link ==="
  echo "    The marker-file containment case could not be constructed, so nothing about"
  echo "    containment was tested here. This is not a clean result."
else
  echo "=== E: the marker FILE is a symbolic link, like the log was in #27 (#49) ==="
  # `.discovery` and `.discovery/state` already get `[ -L ]`. The marker file itself did
  # not, and awk's `print >> file` follows a link. A repository can commit one at
  # mode 120000; it has to guess the session id, which is the bound this replaces with a
  # check.

  VICTIM="$TMP/outside-e/victim.txt"
  rm -rf "$TMP/outside-e"
  mkdir -p "$TMP/outside-e"
  printf '# original\n' > "$VICTIM"

  P="$(new_path_project e)"
  mkdir -p "$(state_of "$P")"
  ln -sfn "$VICTIM" "$(state_of "$P")/path-shown-sess-e.txt"
  OUT="$(run_path "$P" "sess-e")"
  RC=$?
  E="$(cat "$ERR")"
  assert_rc0 "linked marker: hook exits 0" "$RC"
  assert_contains "linked marker: the entry is still injected" "$OUT" "php coding rules"
  assert_silent "linked marker: nothing on the session stderr" "$E"
  assert_equal "linked marker: NOTHING was appended through the link" \
    "$(cat "$VICTIM")" "# original"

  # The positive control for the assertion above, on the same fixture minus the link:
  # "the victim file did not change" is satisfied by a hook that does nothing at all, so
  # the identical shape must be shown WRITING when the marker is an ordinary file.
  P="$(new_path_project e2)"
  OUT="$(run_path "$P" "sess-e")"
  assert_contains "control: unlinked marker still injects" "$OUT" "php coding rules"
  assert_file "control: unlinked marker IS written" "$(state_of "$P")/path-shown-sess-e.txt"
  OUT2="$(run_path "$P" "sess-e")"
  assert_equal "control: and it dedups on the second call" "$OUT2" "{}"
fi

echo ""
if [ "$SKIPPED_SECTIONS" -gt 0 ] || [ "$B2_SKIPPED" -eq 1 ]; then
  echo "$PASS passed, $FAIL failed, $((SKIPPED_SECTIONS + B2_SKIPPED)) section(s) SKIPPED"
else
  echo "$PASS passed, $FAIL failed"
fi
# A failure outranks a skip: a red assertion is an answer, a skip is the absence of one.
[ "$FAIL" -eq 0 ] || exit 1
# 2 is this repo's "could not evaluate", the code run-all.sh keeps apart from both.
[ "$SKIPPED_SECTIONS" -eq 0 ] && [ "$B2_SKIPPED" -eq 0 ] || exit 2
exit 0
