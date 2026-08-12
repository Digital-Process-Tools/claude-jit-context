#!/bin/bash
# The hooks' scratch channel: a name nobody else can predict, and a remover keyed to
# this process.
#
# All three hooks built their scratch path by concatenation:
#
#   LOG_TMP="/tmp/claude-path-log-$$.tmp"     (and -hook-, and -prompt-)
#
# awk then wrote it with `printf ... > log_tmp`, which TRUNCATES and follows a symbolic
# link, and awk cannot lstat. `$$` is a pid: not secret, drawn from a small space, and in
# a world-writable /tmp an attacker does not have to guess it -- pre-creating the plausible
# range costs nothing. The later `[ -f "$LOG_TMP" ]` was no defence: `-f` follows the link
# too, so a link to a regular file passes it. Issue #60.
#
# `[ -L ]` before the write was rejected as the fix: check-then-act in a world-writable
# directory is the one place that race is cheap to win. The file is created by `mktemp`
# instead -- O_EXCL and an unpredictable name in a single step -- under $TMPDIR.
#
# WHICH ASSERTION CARRIES THE WEIGHT, since three of the four sections could be read as
# vacuous:
#
#   A  is the regression proper. It plants a link at the OLD predictable name using the
#      pid the hook will actually run under (`exec` preserves $$), and asserts the victim
#      is byte-identical afterwards -- paired, in the same fixture and the same run, with
#      the hook still injecting its entry and still writing its log line. "Nothing was
#      truncated" is true of a hook that never ran; those two positives are what make it
#      mean something.
#   B  is structural, and is what stops the fix being re-broken under a different name:
#      no script may build a temp path out of $$ again.
#   C  proves the scratch file really is under $TMPDIR, by taking $TMPDIR away: with an
#      unwritable one the hook must still inject and still exit 0, and it must write NO
#      log line, because it has no channel to carry one. That last assertion is the
#      discriminating half -- before the fix the log line was written regardless, since
#      $TMPDIR had nothing to do with the path.
#   D  is the cleanup contract from #43, and it is the WEAKEST of the four: read on its
#      own, "the hooks left nothing behind" is satisfied by a hook that never touched
#      $TMPDIR at all, which is exactly the pre-#60 behaviour. Driven against the unfixed
#      scripts, D goes green. It is kept for the half that does discriminate -- a foreign
#      file in the same directory SURVIVES, which is the regression `rm -f
#      /tmp/claude-hook-log-*.tmp` was (it deleted other live sessions' in-flight temps)
#      and which no future wildcard sweep could pass. What proves the file is under
#      $TMPDIR in the first place is C, not D.
#
# Usage: bash tests/test-hook-tmpfile.sh

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

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
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

assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected: $want"
    echo "    got:      ${got:-<EMPTY>}"
  fi
}

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t jit60)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

VICTIM_TEXT="ORIGINAL VICTIM CONTENT"

# A project that fires on all three hooks, so the same fixture carries the positive
# control beside every negative.
new_project() {
  local p="$TMP/proj-$1"
  local base
  rm -rf "$p"
  base="$p/.claude/jit-context"
  mkdir -p "$base/paths/00-manual" "$base/paths/10-auto" "$base/paths/20-grouped" \
           "$base/paths/30-crosscutting" "$base/tools/00-manual" "$base/vocabulary/00-manual"
  printf '%s\t%s\n' '\.php' 'php-coding.md' > "$base/paths/00-manual/00-index.tsv"
  printf 'php coding rules\n' > "$base/paths/00-manual/php-coding.md"
  : > "$base/paths/10-auto/00-index.tsv"
  : > "$base/paths/20-grouped/00-index.tsv"
  : > "$base/paths/30-crosscutting/00-index.tsv"
  printf 'Bash\ttoolcanary\ttool-note.md\tremind\t\t\n' > "$base/tools/00-manual/00-index.tsv"
  printf 'tool note body\n' > "$base/tools/00-manual/tool-note.md"
  printf 'zorkword\tvocab-note.md\n' > "$base/vocabulary/00-manual/00-index.tsv"
  printf 'vocab note body\n' > "$base/vocabulary/00-manual/vocab-note.md"
  printf '%s' "$p"
}

log_of() { printf '%s' "$1/.claude/jit-context/.discovery/logs/hooks.log"; }

# hook name -> script, payload, the string its entry injects, the legacy /tmp prefix the
# pre-#60 code concatenated a pid onto, and the tag it writes to the log.
HOOKS="path tool prompt"
hook_script() {
  case "$1" in
    path)   printf '%s' "$SCRIPTS/pre-path-hook.sh" ;;
    tool)   printf '%s' "$SCRIPTS/pre-tool-hook.sh" ;;
    prompt) printf '%s' "$SCRIPTS/pre-prompt-hook.sh" ;;
  esac
}
hook_payload() {
  case "$1" in
    path)   printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/x/app.php"}}' ;;
    tool)   printf '%s' '{"tool_name":"Bash","tool_input":{"command":"toolcanary now"}}' ;;
    prompt) printf '%s' '{"prompt":"zorkword please"}' ;;
  esac
}
hook_needle() {
  case "$1" in
    path)   printf '%s' 'php coding rules' ;;
    tool)   printf '%s' 'tool note body' ;;
    prompt) printf '%s' 'vocab note body' ;;
  esac
}
hook_legacy_prefix() {
  case "$1" in
    path)   printf '%s' '/tmp/claude-path-log-' ;;
    tool)   printf '%s' '/tmp/claude-hook-log-' ;;
    prompt) printf '%s' '/tmp/claude-prompt-log-' ;;
  esac
}
hook_logtag() {
  case "$1" in
    path)   printf '%s' 'pre-path' ;;
    tool)   printf '%s' 'pre-tool' ;;
    prompt) printf '%s' 'pre-prompt' ;;
  esac
}

run_hook() {
  local h="$1" p="$2"
  hook_payload "$h" | CLAUDE_PROJECT_DIR="$p" bash "$(hook_script "$h")" 2>&1
}

# --- Can this platform make a symbolic link at all? --------------------------
# Section A is CONSTRUCTED with `ln -s`. On Git Bash the MSYS runtime copies the target
# instead of linking it, and then "the victim is untouched" holds because the victim was
# never in the write path -- the same false green tests/test-log-containment.sh documents.
REQUIRE_SYMLINKS="${JIT_TESTS_REQUIRE_SYMLINKS:-}"
CAN_SYMLINK=no
probe_symlinks() {
  local d="$TMP/.symlink-probe"
  rm -rf "$d" || return 1
  mkdir -p "$d/target-dir" || return 1
  printf 'probe\n' > "$d/target-file" || return 1
  ln -sf "$d/target-file" "$d/link-file" 2>/dev/null
  ln -sfn "$d/target-dir" "$d/link-dir" 2>/dev/null
  printf 'late\n' > "$d/target-dir/late.txt" || return 1
  [ -L "$d/link-file" ] || return 1
  [ -L "$d/link-dir" ] || return 1
  [ -f "$d/link-dir/late.txt" ] || return 1
  CAN_SYMLINK=yes
}
probe_symlinks
SKIPPED_SECTIONS=0
echo "symlink support: $CAN_SYMLINK (files and directories, verified through the link)"
echo ""

# The attacker and the victim are the same process here, on purpose. Predicting another
# process's pid is argued in #60 and is not what this suite has to re-prove; what it has
# to prove is that the hook FOLLOWS whatever sits at that path. `exec` keeps the pid, so
# the link is planted under exactly the `$$` the hook then expands -- no polling, no
# window, no flake. $BASHPID would be the obvious spelling and is unusable: macOS ships
# bash 3.2, which does not have it.
cat > "$TMP/stage.sh" <<'STAGE'
#!/bin/bash
printf '%s' "$$" > "$JIT_PIDFILE"
ln -sf "$JIT_VICTIM" "$JIT_LINK_PREFIX$$.tmp"
exec bash "$JIT_HOOK"
STAGE

echo "=== Positive control: an honest run injects and logs, on all three hooks ==="
for H in $HOOKS; do
  P="$(new_project "ctl-$H")"
  OUT="$(run_hook "$H" "$P")"; RC=$?
  assert_rc0 "$H: honest run exits 0" "$RC"
  assert_contains "$H: honest run injects its entry" "$OUT" "$(hook_needle "$H")"
  LOG="$(log_of "$P")"
  if [ -f "$LOG" ]; then
    assert_contains "$H: honest run writes its log line" "$(cat "$LOG")" "$(hook_logtag "$H")"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $H: honest run wrote NO log line inside the project."
    echo "        Section A below cannot mean anything until this passes."
  fi
done

echo ""
if [ "$CAN_SYMLINK" != yes ]; then
  SKIPPED_SECTIONS=1
  echo "=== A SKIPPED: this platform did not create a symbolic link ==="
  echo "    The scratch-file attack could not be constructed, so nothing about it was"
  echo "    tested here. On Git Bash 'ln -s' copies the target, which leaves the victim"
  echo "    out of the write path entirely and makes 'the victim is untouched' true for"
  echo "    a reason unrelated to the guard."
  if [ "$REQUIRE_SYMLINKS" = 1 ]; then
    FAIL=$((FAIL + 1))
    echo ""
    echo "  FAIL: SYMBOLIC LINKS WERE REQUIRED AND NOT OBTAINED."
    echo "        JIT_TESTS_REQUIRE_SYMLINKS=1 says this environment was configured to have"
    echo "        them, so the skip above is a broken configuration and not a platform"
    echo "        without the capability. Failed rather than skipped because run-all.sh"
    echo "        renders a skip green. Nothing here is a defect in the hooks."
  fi
else
  echo "=== A: a symlink at the legacy /tmp scratch name does not reach the victim ==="
  for H in $HOOKS; do
    P="$(new_project "a-$H")"
    VICTIM="$TMP/victim-$H.rc"
    printf '%s\n' "$VICTIM_TEXT" > "$VICTIM"
    PIDFILE="$TMP/pid-$H"
    : > "$PIDFILE"
    OUT="$(hook_payload "$H" | CLAUDE_PROJECT_DIR="$P" \
      JIT_VICTIM="$VICTIM" \
      JIT_LINK_PREFIX="$(hook_legacy_prefix "$H")" \
      JIT_HOOK="$(hook_script "$H")" \
      JIT_PIDFILE="$PIDFILE" \
      bash "$TMP/stage.sh" 2>&1)"; RC=$?
    PLANTED="$(hook_legacy_prefix "$H")$(cat "$PIDFILE").tmp"

    assert_eq "$H: the victim file is byte-identical" "$(cat "$VICTIM")" "$VICTIM_TEXT"
    # The two positives, in the same fixture and the same run as the negative above.
    assert_rc0 "$H: and the hook still exited 0" "$RC"
    assert_contains "$H: and the hook still injected its entry" "$OUT" "$(hook_needle "$H")"
    LOG="$(log_of "$P")"
    if [ -f "$LOG" ]; then
      assert_contains "$H: and the hook still wrote its log line" "$(cat "$LOG")" "$(hook_logtag "$H")"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $H: no log line was written, so the untouched victim proves nothing."
    fi
    rm -f "$PLANTED"
  done
fi

echo ""
echo "=== B: no script builds a temp path out of its own pid ==="
# Structural, because section A can only name the three prefixes that existed on
# 2026-08-12. A fourth predictable name would pass A and fail here.
PIDPATHS="$(awk '/^[[:space:]]*#/ { next }
  /(\/tmp|TMPDIR|TMP)[^"]*\$\$/ { print FILENAME ":" FNR ": " $0 }' "$SCRIPTS"/*.sh)"
if [ -z "$PIDPATHS" ]; then
  PASS=$((PASS + 1)); echo "  PASS: no scratch path is concatenated from \$\$"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: a temp path is still built from the pid -- predictable, and pre-creatable"
  echo "$PIDPATHS"
fi

echo ""
echo "=== C: the scratch file lives under \$TMPDIR, and losing it is not an error ==="
# The discriminating half: with an unwritable $TMPDIR there is no channel, so there is no
# log line. Before #60 the path ignored $TMPDIR entirely and the line was written anyway.
C_TMPDIR="$TMP/notmp"
mkdir -p "$C_TMPDIR"
chmod 555 "$C_TMPDIR" 2>/dev/null
if [ -w "$C_TMPDIR" ]; then
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section C tested nothing."
else
  for H in $HOOKS; do
    P="$(new_project "c-$H")"
    OUT="$(hook_payload "$H" | CLAUDE_PROJECT_DIR="$P" TMPDIR="$C_TMPDIR" \
      bash "$(hook_script "$H")" 2>/dev/null)"; RC=$?
    ERR="$(hook_payload "$H" | CLAUDE_PROJECT_DIR="$P" TMPDIR="$C_TMPDIR" \
      bash "$(hook_script "$H")" 2>&1 >/dev/null)"
    assert_rc0 "$H: unwritable TMPDIR: still exits 0" "$RC"
    assert_contains "$H: unwritable TMPDIR: still injects its entry" "$OUT" "$(hook_needle "$H")"
    assert_eq "$H: unwritable TMPDIR: nothing on stderr" "$ERR" ""
    LOG="$(log_of "$P")"
    if [ -f "$LOG" ]; then
      assert_not_contains "$H: unwritable TMPDIR: no log line, because there is no channel" \
        "$(cat "$LOG")" "$(hook_logtag "$H")"
    else
      PASS=$((PASS + 1))
      echo "  PASS: $H: unwritable TMPDIR: no log line, because there is no channel"
    fi
  done
fi
chmod 755 "$C_TMPDIR" 2>/dev/null

echo ""
echo "=== D: a foreign file in the same directory survives, and nothing is left ==="
# #43: `rm -f /tmp/claude-hook-log-*.tmp` deleted other live sessions' in-flight temps.
# The removal is keyed to this process, so a private TMPDIR holds nothing of ours
# afterwards -- and the foreign file in it is still there.
#
# Half of this is weak by construction and is not dressed up: "nothing was left" passes
# for a hook that never opened this directory, so it says nothing about the #60 fix. The
# survival of the foreign file is the assertion with teeth, and it points forward rather
# than back -- it fails the day someone reaches for a wildcard again. C is what shows the
# scratch file is under $TMPDIR at all.
D_TMPDIR="$TMP/mytmp"
mkdir -p "$D_TMPDIR"
FOREIGN="$D_TMPDIR/claude-jit-FOREIGN.tmp"
printf 'in flight\n' > "$FOREIGN"
for H in $HOOKS; do
  P="$(new_project "d-$H")"
  OUT="$(hook_payload "$H" | CLAUDE_PROJECT_DIR="$P" TMPDIR="$D_TMPDIR" \
    bash "$(hook_script "$H")" 2>&1)"; RC=$?
  assert_rc0 "$H: private TMPDIR: exits 0" "$RC"
  assert_contains "$H: private TMPDIR: injects its entry" "$OUT" "$(hook_needle "$H")"
done
LEFT="$(ls -A "$D_TMPDIR")"
assert_eq "the hooks left nothing behind in TMPDIR" "$LEFT" "claude-jit-FOREIGN.tmp"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIPPED_SECTIONS" -eq 0 ] || exit 2
exit 0
