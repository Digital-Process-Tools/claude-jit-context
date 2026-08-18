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

# jit-drive: assert_contains contains capture
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
echo "=== J: session-start reads a session id with the same parser AND the same locale (#177) ==="
# session-start-hook.sh:32 parses the payload with jit_json_fields + jit_session_key out of
# common.sh -- the SAME functions the three matching hooks use -- and its comment says that
# is deliberate, so that there is one answer to "what is a session id". It was the only one
# of the four that did not pin `LC_ALL=C`, and the parser is not the same parser in another
# locale.
#
# MEASURED at 98386f1, 3 engines x 2 locales, on a payload whose session_id carries a lone
# 0xE9 byte:
#
#   one-true-awk C / gawk C / mawk C / mawk UTF-8   ->  ""   (refused, correct)
#   one-true-awk UTF-8                              ->  ""   + a suppressed towc diagnostic
#   gawk + en_US.UTF-8                              ->  the id ACCEPTED, 0xE9 and all
#
# Under gawk in a UTF-8 locale the bare-name test `k ~ /[^A-Za-z0-9_-]/` does not match a
# lone 0xE9, so an id the three sibling hooks REFUSE is accepted here and concatenated into
# two marker names for `rm -f`. It is bounded -- `/` is single-byte and still matches, so no
# traversal -- but it is exactly the drift the comment exists to prevent, at the one hook
# whose whole job is clearing that state.
#
# WHY THIS IS OBSERVED THROUGH AN `rm` SHIM AND NOT THROUGH THE FILESYSTEM. The obvious
# fixture -- plant the marker file the unpinned parse would clear, and assert it survives --
# CANNOT BE BUILT on macOS. APFS enforces valid UTF-8 in file names, so
# `printf x > "$S/path-shown-jbad\351id.txt"` fails with `Illegal byte sequence` and creates
# nothing; the assertion then reads "the marker is gone" and goes red on a fixed hook and a
# broken one alike. Measured here 2026-08-18: that first draft was red in all three engines
# for exactly that reason, with the redirection error on stderr as the only tell.
#
# So the question asked is the one that has an answer on every filesystem: DID THIS HOOK
# TREAT THAT STRING AS A SESSION ID? A shimmed `rm` first on PATH records every argument it
# is handed. A refused id never reaches the `if [ -n "$SESSION_ID" ]` branch, so no marker
# path is passed to `rm` at all -- true whether or not that name could exist on disk.
#
# THE PAIR. "No marker path reached rm" is also true of a hook that died, of a shim that
# never ran, and of a PATH that did not take. So the same fixture, engine and locale then
# runs an HONEST session id and requires both marker paths to appear in the same log.
J_ENGINE_BIN=$(mktemp -d)
J_RMLOG=$(mktemp)
J_REAL_RM=$(command -v rm)
J_ENGINES=""
J_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2>/dev/null) || continue
  case " $J_SEEN " in *" $cand_path "*) continue ;; esac
  J_SEEN="$J_SEEN $cand_path"
  mkdir -p "$J_ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$J_ENGINE_BIN/$cand/awk"
  chmod +x "$J_ENGINE_BIN/$cand/awk"
  # The observer. One line per argument, so a marker path is greppable whatever bytes it
  # carries; the real rm still runs, so the hook behaves exactly as it would unshimmed.
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a" >> "%s"; done\nexec "%s" "$@"\n' \
    "$J_RMLOG" "$J_REAL_RM" > "$J_ENGINE_BIN/$cand/rm"
  chmod +x "$J_ENGINE_BIN/$cand/rm"
  J_ENGINES="$J_ENGINES $cand"
done

# The locale is the caller's and it is the whole point: `C` is where this does not
# reproduce, so a run that could not obtain a UTF-8 locale has to say so rather than go
# quietly green. Same shape as test-pre-tool-hook.sh and #169's escape hatch.
j_pick_utf8_locale() {
  local c
  for c in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if [ "$(LC_ALL="$c" locale charmap 2>/dev/null)" = "UTF-8" ]; then
      printf '%s' "$c"; return 0
    fi
  done
  printf '%s' "${LC_ALL:-${LANG:-C}}"
}
J_UTF8="$(j_pick_utf8_locale)"
J_UTF8_REAL=no
J_SKIPPED=0
if [ "$(LC_ALL="$J_UTF8" locale charmap 2>/dev/null)" = "UTF-8" ]; then J_UTF8_REAL=yes; fi
if [ "$J_UTF8_REAL" != yes ]; then
  # A SKIP, not a note. The five sibling suites print the note and exit 0, which is the
  # convention -- and it is the wrong one HERE, because this file already carries the third
  # state and section I already uses it. Without this flag a run on a host with no UTF-8
  # locale prints "N passed, 0 failed" and exits 0, which is byte-identical to a run that
  # DID drive the gawk cell the whole section exists for. That is this repository's own
  # defect class, in the test written to close an instance of it.
  J_SKIPPED=1
  echo "  SKIP-NOTE: no UTF-8 locale on this machine ($J_UTF8). Section J runs under a byte"
  echo "             locale, which is where the defect does NOT reproduce -- the assertions"
  echo "             still state the guarantee, they just cannot fail for it here."
  if [ "${JIT_TESTS_REQUIRE_UTF8_LOCALE:-}" = 1 ]; then
    FAIL=$((FAIL + 1))
    echo ""
    echo "  FAIL: A UTF-8 LOCALE WAS REQUIRED AND NOT OBTAINED."
    echo "        JIT_TESTS_REQUIRE_UTF8_LOCALE=1 says this environment was configured to"
    echo "        have one, so the note above is a broken configuration and not a platform"
    echo "        without the capability. Nothing here is a defect in session-start-hook.sh."
  fi
fi
echo "  caller locale for section J: $J_UTF8"

# A lone 0xE9 -- a valid Latin-1 byte and never a valid UTF-8 sequence on its own.
J_BAD="jbad$(printf '\351')id"

j_session_start() {
  # $1 project, $2 session id, $3 engine
  printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$2" \
    | LC_ALL="$J_UTF8" PATH="$J_ENGINE_BIN/$3:$PATH" CLAUDE_PROJECT_DIR="$1" \
      bash "$SCRIPTS/session-start-hook.sh" 2>/dev/null
}
j_path_hook() {
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"src/a.php"}}' "$2" \
    | LC_ALL="$J_UTF8" PATH="$J_ENGINE_BIN/$3:$PATH" CLAUDE_PROJECT_DIR="$1" \
      bash "$SCRIPTS/pre-path-hook.sh" 2>/dev/null
}

# Whether any argument handed to `rm` during the last run was a marker path. Read with grep
# -c over a FILE rather than a $( ) of the log, because the argument may carry a byte no
# locale can decode and the count is what is being asserted, not the text.
# `grep -c` PRINTS 0 and EXITS 1 when it matches nothing, so a `|| printf 0` fallback
# appends a second zero and the caller reads "0\n0" -- which `[ "$n" -eq 0 ]` then refuses as
# a non-integer. Measured here while writing this. The status is discarded instead.
j_rm_marker_count() {
  local n
  n="$(LC_ALL=C grep -c -e '-shown-' "$J_RMLOG" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

for eng in $J_ENGINES; do
  P="$(new_project "j-$eng")"
  S="$(state_of "$P")"
  mkdir -p "$S"

  # Leg 1 -- the negative. A byte outside [A-Za-z0-9_-] means this is not a session id, on
  # every engine and in every locale, so the hook must not build a marker name out of it.
  : > "$J_RMLOG"
  OUT="$(j_session_start "$P" "$J_BAD" "$eng")"; RC=$?
  N_BAD="$(j_rm_marker_count)"
  assert_rc0 "[$eng] session-start exits 0 on a malformed session id" "$RC"
  assert_contains "[$eng] and still answers with JSON" "$OUT" "{}"
  if [ "$N_BAD" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: [$eng] a session id carrying a bad byte built no marker path at all"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: [$eng] a malformed session id was treated as a session id"
    echo "    $N_BAD marker path(s) reached rm; the three matching hooks refuse this id"
    LC_ALL=C sed -n 's/^/      rm arg: /p' "$J_RMLOG" | LC_ALL=C tr -c '[:print:]\n' '?'
  fi

  # Leg 2 -- the positive control, same engine, locale and shim. Leg 1 counts to zero for a
  # hook that died, a shim that never ran and a PATH that did not take; this requires the
  # SAME machinery to count to two on an id that is honest.
  : > "$J_RMLOG"
  OUT="$(j_session_start "$P" "jgood" "$eng")"
  N_GOOD="$(j_rm_marker_count)"
  if [ "$N_GOOD" -ge 2 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: [$eng] control: an honest session id DOES reach rm, with both marker paths"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: [$eng] control: an honest session id built $N_GOOD marker path(s), expected 2"
    echo "    leg 1 above proved nothing -- the shim or the hook did not run"
    LC_ALL=C sed -n 's/^/      rm arg: /p' "$J_RMLOG"
  fi
  assert_contains "[$eng] control: and the paths are this session's" \
    "$(LC_ALL=C cat "$J_RMLOG")" "path-shown-jgood.txt"

  # Leg 3 -- the same claim from the other side, and the reason the comment at
  # session-start-hook.sh:25-29 is not merely tidy. pre-path-hook.sh is pinned, so it refuses
  # this id and keeps no marker -- which shows as the entry being offered AGAIN on a second
  # call. Asserted through dedup rather than through a file, for the reason in the header:
  # the file name at issue is unrepresentable on macOS.
  P2="$(new_project "j2-$eng")"
  OUT1="$(j_path_hook "$P2" "$J_BAD" "$eng")"
  OUT2="$(j_path_hook "$P2" "$J_BAD" "$eng")"
  assert_contains "[$eng] pre-path-hook injects on a malformed session id" \
    "$OUT1" "php coding rules"
  assert_contains "[$eng] and injects AGAIN -- it kept no marker, so it refused that id too" \
    "$OUT2" "php coding rules"
  # The control for leg 3: the same two calls with an honest id must dedup, or "injected
  # twice" is a statement about a hook that cannot dedup at all.
  P3="$(new_project "j3-$eng")"
  OUT3="$(j_path_hook "$P3" "jgood" "$eng")"
  OUT4="$(j_path_hook "$P3" "jgood" "$eng")"
  assert_contains "[$eng] control: an honest id injects the first time" "$OUT3" "php coding rules"
  assert_empty_json "[$eng] control: and is silent the second -- so leg 3 saw a real refusal" "$OUT4"
done

rm -rf "$J_ENGINE_BIN"
rm -f "$J_RMLOG"

echo ""
if [ "$SKIPPED_SECTIONS" -gt 0 ] || [ "$H_SKIPPED" -eq 1 ] || [ "$J_SKIPPED" -eq 1 ]; then
  # The symlink clause is printed only when a symlink section actually skipped. It used to
  # be unconditional, so an H-only skip already rendered as "0 section(s) SKIPPED (no
  # symbolic links here)" -- a count of zero and a reason for a section that ran fine.
  # Adding J as a third caller made that line reachable one more way, so it is fixed here
  # rather than left to say the wrong thing about a new case.
  if [ "$SKIPPED_SECTIONS" -gt 0 ]; then
    echo "$PASS passed, $FAIL failed, $SKIPPED_SECTIONS section(s) SKIPPED (no symbolic links here)"
  else
    echo "$PASS passed, $FAIL failed, with section(s) skipped -- see the notes above"
  fi
  if [ "$J_SKIPPED" -eq 1 ]; then
    echo "section J SKIPPED: no UTF-8 locale here, so the one cell the #177 divergence lives"
    echo "in -- gawk under a multibyte locale -- was never driven. Not a clean result."
  fi
else
  echo "$PASS passed, $FAIL failed"
fi
# A failure outranks a skip: a red assertion is an answer, a skip is the absence of one.
[ "$FAIL" -eq 0 ] || exit 1
# 2 is this repo "could not evaluate", the code run-all.sh keeps apart from both.
if [ "$SKIPPED_SECTIONS" -ne 0 ] || [ "$J_SKIPPED" -ne 0 ]; then exit 2; fi
exit 0
