#!/bin/bash
# The once-per-session markers: where they live, and what identifies a session.
#
# Until 2026-08-12 every hook keyed its marker on $PPID in shared /tmp:
#
#   SHOWN_FILE="/tmp/claude-path-shown-$PPID.txt"
#
# $PPID is not a session. Under `$( ... )` -- which is how every suite here calls a hook --
# it is the command-substitution SUBSHELL, a short-lived pid the OS recycles freely, so two
# calls in one `run-all.sh` process land on the same marker at random. What that suppresses
# is `pre-path-hook.sh` `if (rule_file in shown) continue`, which covers EVERY path rule
# including the refusal notice -- so a collision reads as a containment failure. Measured on
# main at 8c62858: 4 of 5 full runs red, every suite green standalone (#17, #23).
#
# The key is now the `session_id` the hook payload carries, and the file lives in the
# project own `.discovery/state/` beside the log rather than in shared /tmp.
#
# THE GUARD THIS SUITE NEEDS. Every "does not fire" assertion below is paired with a "does
# fire" assertion on the same fixture, because a hook that is broken outright satisfies
# every negative here at once. And a dedup test that only ever shows silence is indis-
# tinguishable from a hook that never matched: A and B are one pair, C is the same pair
# driven from a marker file written by hand.
#
# Usage: bash tests/test-session-markers.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

assert_empty_json() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected exactly {} - got: ${output:-<EMPTY>}"
  fi
}

assert_rc0() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    this path should exist and be a regular file: $path"
  fi
}

assert_no_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    this path should not exist: $path"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# A project with one path rule that fires on the payload below.
new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/paths/00-manual" \
           "$p/.claude/jit-context/paths/10-auto" \
           "$p/.claude/jit-context/paths/20-grouped" \
           "$p/.claude/jit-context/paths/30-crosscutting" \
           "$p/.claude/jit-context/tools/00-manual" \
           "$p/.claude/jit-context/vocabulary/00-manual"
  printf '%s\t%s\n' '\.php' 'php-coding.md' > "$p/.claude/jit-context/paths/00-manual/00-index.tsv"
  printf 'php coding rules\n' > "$p/.claude/jit-context/paths/00-manual/php-coding.md"
  : > "$p/.claude/jit-context/paths/10-auto/00-index.tsv"
  : > "$p/.claude/jit-context/paths/20-grouped/00-index.tsv"
  : > "$p/.claude/jit-context/paths/30-crosscutting/00-index.tsv"
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }

# $2 is the session id; an empty $2 sends a payload with no session_id field at all, which
# is what every other suite here does and what a hand-run hook does.
run_path() {
  local p="$1" sid="$2" payload
  if [ -n "$sid" ]; then
    payload="{\"session_id\":\"$sid\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"src/a.php\"}}"
  else
    payload='{"tool_name":"Edit","tool_input":{"file_path":"src/a.php"}}'
  fi
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/pre-path-hook.sh" 2>&1
}

run_session_start() {
  local p="$1" sid="$2"
  printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$sid" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/session-start-hook.sh" 2>&1
}

echo "=== A: a session sees an entry once, and the second call is silent ==="
# The pair. The first call must inject or the second proves nothing.

P="$(new_project a)"
OUT1="$(run_path "$P" "sess-alpha")"; RC1=$?
OUT2="$(run_path "$P" "sess-alpha")"
assert_rc0 "first call in a session exits 0" "$RC1"
assert_contains "first call in a session injects the entry" "$OUT1" "php coding rules"
assert_empty_json "second call in the SAME session says nothing" "$OUT2"
assert_file "the marker landed in the project, keyed on the session id" \
  "$(state_of "$P")/path-shown-sess-alpha.txt"

echo ""
echo "=== B: a different session is not suppressed by the first one marker ==="
# The negative control for A. This is the flake: on main the two calls shared a marker
# whenever the two command-substitution subshells drew the same recycled pid.

OUT3="$(run_path "$P" "sess-beta")"
assert_contains "a second session still gets the entry" "$OUT3" "php coding rules"
assert_file "and keeps its own marker file" "$(state_of "$P")/path-shown-sess-beta.txt"

echo ""
echo "=== C: the collision driven deterministically, from a marker written by hand ==="
# A flake is a probability; this is the same event as an assertion. The marker is written
# under the key the hook WILL compute, so no pid has to be guessed and nothing is repeated
# 20 times in the hope of catching it.

P="$(new_project c)"
mkdir -p "$(state_of "$P")"
printf 'php-coding.md\n' > "$(state_of "$P")/path-shown-sess-other.txt"
OUT="$(run_path "$P" "sess-mine")"
assert_contains "another session marker does not silence this one" "$OUT" "php coding rules"

printf 'php-coding.md\n' > "$(state_of "$P")/path-shown-sess-mine.txt"
OUT="$(run_path "$P" "sess-mine")"
assert_empty_json "this session own marker does silence it" "$OUT"

echo ""
echo "=== D: no session_id means no dedup and no state file, never a wrong guess ==="
# A payload with no session_id has no session identity to key on, and the hooks now say
# the entry again rather than suppressing it against a proxy. That is the direction that
# fails safe -- a repeat costs tokens, a wrong suppression costs the rule -- and it is why
# the other eleven suites here needed no edits.

P="$(new_project d)"
OUT1="$(run_path "$P" "")"
OUT2="$(run_path "$P" "")"
assert_contains "first call with no session_id injects" "$OUT1" "php coding rules"
assert_contains "second call with no session_id injects again" "$OUT2" "php coding rules"
if [ -d "$(state_of "$P")" ] && [ -n "$(ls -A "$(state_of "$P")" 2>/dev/null)" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: no session_id wrote a marker anyway"
  ls -A "$(state_of "$P")"
else
  PASS=$((PASS + 1)); echo "  PASS: no session_id wrote no marker at all"
fi

echo ""
echo "=== E: no hook keys a marker in shared /tmp any more ==="
# A code-shape assertion, deliberately: the file a run of the old code creates is named
# after a pid nothing here can predict, so "it was not created" cannot be asserted from
# outside. What CAN be asserted is that no marker path is built under /tmp at all.
# Comment lines are excluded on purpose: session-start-hook.sh quotes the three lines it
# replaced, and the record of what was wrong is not a code path.
TMP_MARKERS="$(grep -n 'tmp/claude-[a-z]*-shown' "$SCRIPTS"/*.sh 2>/dev/null \
  | grep -v ':[0-9]*:[[:space:]]*#')"
if [ -z "$TMP_MARKERS" ]; then
  PASS=$((PASS + 1)); echo "  PASS: no script builds a shown-marker path under /tmp"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: a script still builds a shown-marker path under /tmp"
  echo "$TMP_MARKERS"
fi

echo ""
echo "=== F: a session id is a name in a path, so it is refused before it is one ==="
# The marker path is a concatenation onto a directory, and session_id arrives in a JSON
# payload. A value carrying a separator would choose where the hook writes.

P="$(new_project f)"
OUT="$(run_path "$P" "../../../../escape")"
assert_contains "a traversing session id still gets its entry" "$OUT" "php coding rules"
assert_no_file "and wrote nothing above the state directory" "$TMP/path-shown-escape.txt"
assert_no_file "and nothing outside the project either" "$TMP/f/.claude/path-shown-escape.txt"
if [ -d "$(state_of "$P")" ] && [ -n "$(ls -A "$(state_of "$P")" 2>/dev/null)" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a traversing session id was used as a key anyway"
  ls -A "$(state_of "$P")"
else
  PASS=$((PASS + 1)); echo "  PASS: a traversing session id is not a session identity"
fi

echo ""
echo "=== G: session-start clears THIS session, and leaves every other one alone ==="
# The old SessionStart deleted /tmp/claude-hook-log-*.tmp by wildcard -- every other
# concurrent session in-flight log temp, none of which it owns.
#
# Since #60 no hook creates that name at all: the scratch file comes from mktemp under
# $TMPDIR and is removed by an EXIT trap in the process that made it. The file planted
# below is therefore nobody's -- which is the point, and is a stronger fixture than the
# one it replaced. The assertion is unchanged and still guards the same regression: this
# hook must not sweep a shared directory by pattern. tests/test-hook-tmpfile.sh section D
# makes the same demand of the three hooks, in the directory they actually use.

P="$(new_project g)"
mkdir -p "$(state_of "$P")"
printf 'php-coding.md\n' > "$(state_of "$P")/path-shown-sess-mine.txt"
printf 'php-coding.md\n' > "$(state_of "$P")/path-shown-sess-theirs.txt"
FOREIGN="/tmp/claude-hook-log-999999.tmp"
printf 'in flight\n' > "$FOREIGN"
OUT="$(run_session_start "$P" "sess-mine")"; RC=$?
assert_rc0 "session-start exits 0" "$RC"
assert_contains "session-start still answers with JSON" "$OUT" "{}"
assert_no_file "it cleared this session marker" "$(state_of "$P")/path-shown-sess-mine.txt"
assert_file "it left another session marker alone" "$(state_of "$P")/path-shown-sess-theirs.txt"
assert_file "it left another session in-flight log temp alone" "$FOREIGN"
rm -f "$FOREIGN"

echo ""
echo "=== H: a project directory that cannot be written degrades to no dedup, silently ==="
# The markers moved INTO the project, so a read-only checkout is now a case. It must be a
# reason to say nothing about dedup, never a reason to error or to print to stderr.

H_SKIPPED=0
P="$(new_project h)"
mkdir -p "$P/.claude/jit-context/.discovery"
chmod 555 "$P/.claude/jit-context/.discovery" 2>/dev/null
if [ -w "$P/.claude/jit-context/.discovery" ]; then
  H_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section H tested nothing."
else
  OUT="$(run_path "$P" "sess-ro")"; RC=$?
  assert_rc0 "read-only tree: hook still exits 0" "$RC"
  assert_contains "read-only tree: the entry is still injected" "$OUT" "php coding rules"
  OUT2="$(run_path "$P" "sess-ro")"
  assert_contains "read-only tree: it is injected again, rather than lost" "$OUT2" "php coding rules"
fi
chmod 755 "$P/.claude/jit-context/.discovery" 2>/dev/null

echo ""
# --- Can this platform make a symbolic link at all? --------------------------
# Section I is CONSTRUCTED with `ln -s`. On Git Bash the MSYS runtime copies the target
# instead of linking it, and then "nothing was written outside the tree" holds because the
# attack was never built. Verified through the link, which a copy cannot satisfy.
CAN_SYMLINK=no
probe_symlinks() {
  local d="$TMP/.symlink-probe"
  rm -rf "$d" || return 1
  mkdir -p "$d/target-dir" || return 1
  ln -sfn "$d/target-dir" "$d/link-dir" 2>/dev/null
  printf 'late\n' > "$d/target-dir/late.txt" || return 1
  [ -L "$d/link-dir" ] || return 1
  [ -f "$d/link-dir/late.txt" ] || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
SKIPPED_SECTIONS=0

if [ "$CAN_SYMLINK" != yes ]; then
  SKIPPED_SECTIONS=1
  echo "=== I SKIPPED: this platform did not create a symbolic link ==="
  echo "    The state-directory containment case could not be constructed, so nothing"
  echo "    about containment was tested here. This is not a clean result."
else
  echo "=== I: the state directory is chosen by a cloned repository, like the log was ==="
  # Same shape as #27: `mkdir -p` follows a symlink and `>>` follows a symlink, and git
  # tracks a symlink as mode 120000. A committed `.discovery -> /somewhere/else` would
  # otherwise make one tool call materialise a directory outside the tree and append
  # entry file names to a file inside it.

  OUTDIR="$TMP/outside-i"
  rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
  P="$(new_project i)"
  ln -sfn "$OUTDIR" "$P/.claude/jit-context/.discovery"
  OUT="$(run_path "$P" "sess-link")"; RC=$?
  assert_rc0 "linked .discovery: hook still exits 0" "$RC"
  assert_contains "linked .discovery: the entry is still injected" "$OUT" "php coding rules"
  assert_no_file "linked .discovery: no state directory outside the tree" "$OUTDIR/state"

  OUTDIR2="$TMP/outside-i2"
  rm -rf "$OUTDIR2"; mkdir -p "$OUTDIR2"
  P="$(new_project i2)"
  mkdir -p "$P/.claude/jit-context/.discovery"
  ln -sfn "$OUTDIR2" "$P/.claude/jit-context/.discovery/state"
  OUT="$(run_path "$P" "sess-link2")"; RC=$?
  assert_rc0 "linked state dir: hook still exits 0" "$RC"
  assert_contains "linked state dir: the entry is still injected" "$OUT" "php coding rules"
  assert_no_file "linked state dir: no marker written through the link" \
    "$OUTDIR2/path-shown-sess-link2.txt"
fi

echo ""
if [ "$SKIPPED_SECTIONS" -gt 0 ] || [ "$H_SKIPPED" -eq 1 ]; then
  echo "$PASS passed, $FAIL failed, $SKIPPED_SECTIONS section(s) SKIPPED (no symbolic links here)"
else
  echo "$PASS passed, $FAIL failed"
fi
# A failure outranks a skip: a red assertion is an answer, a skip is the absence of one.
[ "$FAIL" -eq 0 ] || exit 1
# 2 is this repo "could not evaluate", the code run-all.sh keeps apart from both.
[ "$SKIPPED_SECTIONS" -eq 0 ] || exit 2
exit 0
