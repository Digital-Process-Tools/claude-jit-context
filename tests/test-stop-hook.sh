#!/bin/bash
# #244 (part 2 of #233): the Stop hook that reads back the injected-vs-edited record.
#
# #367 rewrote the human-facing shape entirely: `systemMessage`, gated by
# JIT_CONTEXT_STATUS (default `summary`), carrying a TOTAL only -- no names, no
# ownership split. That is why this file no longer asserts entry NAMES against the
# hook's stdout ($OUT): the model-facing line does not carry them any more. Names,
# ages and the Y/N/U ownership split all moved to hooks.log, unconditional and
# unbounded (past the 200-name cap), which is what most of the assertions below read
# instead.
#
# #299 gave every fired mark a "loc:<dim>:<layer>:<file>" key rather than a bare file
# name (common.sh: jit_loc_key()), so fixtures below write that format -- a bare mark
# is a THIRD, deliberate case (section U), simulating a hook from an earlier version
# firing earlier in the same session, and must render as unknown rather than guessed.
#
# THREE STATES for the edit question, unchanged by either #367 or #299:
#   * fired, none edited -- one line (now a total only), #292
#   * fired, some edited -- silence (section B)
#   * COULD NOT TELL whether anything was edited -- says so (state dir unknown,
#     section D; 00-manual unreadable, section T; edit-declined, section N)
#
# jit-drive: assert_contains contains capture
#
# Usage: bash tests/test-stop-hook.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

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

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    did not expect to contain: $expected"
    echo "    got: ${output:-<EMPTY>}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

assert_empty_json() {
  local desc="$1" output="$2"
  if [ "$output" = "{}" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected exactly {} - got: ${output:-<EMPTY>}"
  fi
}

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/vocabulary/00-manual"
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }
log_of() { printf '%s' "$1/.claude/jit-context/.discovery/logs/hooks.log"; }

# A REAL entry file under a project's 00-manual layer -- #299's `loc:` key already
# says which layer a mark fired from, but a name-check by hand here still wants a
# real file to exist so a fixture is not accidentally asserting about a file this
# repository never created.
manual_entry() {
  local p="$1" dim="$2" name="$3"
  local dir="$p/.claude/jit-context/$dim/00-manual"
  [ -d "$dir" ] || mkdir -p "$dir"
  : > "$dir/$name"
}

# A generated (non-00-manual) entry -- stands in for #295's plugin-owned layer.
auto_entry() {
  local p="$1" dim="$2" layer="$3" name="$4"
  local dir="$p/.claude/jit-context/$dim/$layer"
  [ -d "$dir" ] || mkdir -p "$dir"
  : > "$dir/$name"
}

run_stop() {
  local p="$1" sid="$2" active="${3:-false}"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$sid" "$active" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/stop-hook.sh" 2>&1
}

echo "=== A: entries fired, nothing edited -- one line, the total only (#292/#367) ==="

P="$(new_project a)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
manual_entry "$P" vocabulary cache.md
printf 'loc:vocabulary:00-manual:bridge.md\nloc:vocabulary:00-manual:cache.md\n' > "$(state_of "$P")/vocab-shown-sess-a.txt"
OUT="$(run_stop "$P" "sess-a")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the message names the total" "$OUT" "2 entries this session"
assert_not_contains "and never names a fired entry by name" "$OUT" "bridge.md"
LOG_A="$(log_of "$P")"
assert_contains "hooks.log carries the full split" "$(cat "$LOG_A")" "2 entries fired this session, 2 yours, 0 not yours, 0 unknown"
assert_contains "and names the fired entries there" "$(cat "$LOG_A")" "bridge.md"
if grep -qF -- '\n' <<< "$OUT"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: the systemMessage line is not a single line"
else
  PASS=$((PASS + 1))
  echo "  PASS: the systemMessage line collapsed to one line"
fi

echo ""
echo "=== B: entries fired, something WAS edited this session -- silence ==="

P="$(new_project b)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-b.txt"
: > "$(state_of "$P")/edited-sess-b.txt"
OUT="$(run_stop "$P" "sess-b")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- edits happened" "$OUT"

echo ""
echo "=== C: nothing fired at all this session -- silence, there is nothing to compare ==="

P="$(new_project c)"
mkdir -p "$(state_of "$P")"
OUT="$(run_stop "$P" "sess-c")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- no injections this session" "$OUT"

echo ""
echo "=== D: an unwritable tree -- COULD NOT TELL, never silence ==="

D_SKIPPED=0
P="$(new_project d)"
chmod 555 "$P/.claude/jit-context" 2> /dev/null
if [ -w "$P/.claude/jit-context" ]; then
  D_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section D tested nothing."
else
  OUT="$(run_stop "$P" "sess-d")"
  RC=$?
  assert_rc0 "the hook exits 0" "$RC"
  assert_contains "it says it could not tell what fired" "$OUT" "cannot tell what fired"
  if [ "$OUT" = "{}" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: could-not-tell rendered as silence"
  else
    PASS=$((PASS + 1))
    echo "  PASS: could-not-tell did not render as silence"
  fi
fi
chmod 755 "$P/.claude/jit-context" 2> /dev/null

echo ""
echo "=== E: no jit-context tree at all -- fully inert ==="

P="$TMP/e"
mkdir -p "$P"
OUT="$(run_stop "$P" "sess-e")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing at all" "$OUT"
if [ -e "$P/.claude" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: a .claude directory was materialised for a tree-less project"
else
  PASS=$((PASS + 1))
  echo "  PASS: no .claude directory is materialised"
fi

echo ""
echo "=== F: sentinel keys in the shown marks are not reported as fired entries ==="

P="$(new_project f)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\njit-refused-vocab\njit-no-subject\n' > "$(state_of "$P")/vocab-shown-sess-f.txt"
OUT="$(run_stop "$P" "sess-f")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "only the real entry is counted" "$OUT" "1 entry this session"
LOG_F="$(log_of "$P")"
SENTINEL_HIT=0
grep -qF -- "jit-refused-vocab" "$LOG_F" && SENTINEL_HIT=1
grep -qF -- "jit-no-subject" "$LOG_F" && SENTINEL_HIT=1
if [ "$SENTINEL_HIT" = 1 ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: a sentinel key was reported as a fired entry in hooks.log"
else
  PASS=$((PASS + 1))
  echo "  PASS: no sentinel key was reported as a fired entry"
fi

echo ""
echo "=== G: the same entry fired through both marker files is only counted once ==="

P="$(new_project g)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-g.txt"
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/path-shown-sess-g.txt"
OUT="$(run_stop "$P" "sess-g")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the total counts it once, not twice" "$OUT" "1 entry this session"

echo ""
echo "=== H: the dedup scan is bounded, not quadratic in an untrusted marker file ==="

P="$(new_project h)"
H_STATE_DIR="$(state_of "$P")"
mkdir -p "$H_STATE_DIR"
JIT_HI=600
_jit_seq=1
: > "$H_STATE_DIR/vocab-shown-sess-h.txt"
while [ "$_jit_seq" -le "$JIT_HI" ]; do
  printf 'loc:vocabulary:00-manual:entry-%s.md\n' "$_jit_seq" >> "$H_STATE_DIR/vocab-shown-sess-h.txt"
  manual_entry "$P" vocabulary "entry-$_jit_seq.md"
  _jit_seq=$((_jit_seq + 1))
done
unset H_STATE_DIR
OUT="$(run_stop "$P" "sess-h")"
RC=$?
assert_rc0 "the hook exits 0 on 600 distinct fired entries" "$RC"
assert_contains "the reported total accounts for all 600" "$OUT" "$JIT_HI entries this session"
LOG_H="$(log_of "$P")"
assert_contains "hooks.log names the overflow past the cap, not silently dropped" "$(cat "$LOG_H")" "more past this hook's own"

echo ""
echo "=== I: stop_hook_active=true -- a re-entry caused by this hook's own output, never re-report ==="

P="$(new_project i)"
mkdir -p "$(state_of "$P")"
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-i.txt"
OUT="$(run_stop "$P" "sess-i" "true")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "stop_hook_active=true means no systemMessage, even though entries fired" "$OUT"

echo ""
echo "=== J: stop_hook_active is missing from the payload entirely -- treated as false ==="

P="$(new_project j)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-j.txt"
OUT="$(printf '{"session_id":"sess-j","hook_event_name":"Stop"}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "a payload with no stop_hook_active key at all still reports" "$OUT" "1 entry this session"

echo ""
echo "=== K: an escaped quote earlier in the payload must not desync the field scan ==="

P="$(new_project k)"
mkdir -p "$(state_of "$P")"
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-k.txt"
OUT="$(printf '{"session_id":"sess-k","cwd":"C:\\quo\\"te","stop_hook_active":true}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "an escaped quote ahead of stop_hook_active does not hide a real true" "$OUT"

echo ""
echo "=== L: awk cannot run at all -- unknown, not false, taking the safe (true-like) silent branch (#284) ==="

P="$(new_project l)"
mkdir -p "$(state_of "$P")"
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-l.txt"
FAKE_AWK_DIR="$TMP/fake-awk-l"
mkdir -p "$FAKE_AWK_DIR"
cat > "$FAKE_AWK_DIR/awk" << 'FAKE_AWK'
#!/bin/sh
exit 127
FAKE_AWK
chmod +x "$FAKE_AWK_DIR/awk"
OUT="$(printf '{"session_id":"sess-l","stop_hook_active":true}' \
  | PATH="$FAKE_AWK_DIR:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "an unusable awk renders as silence, never as the could-not-tell systemMessage" "$OUT"

echo ""
echo "=== M: a fired session with a REAL awk and stop_hook_active=false is the positive control for L ==="

P="$(new_project m)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-m.txt"
OUT="$(run_stop "$P" "sess-m")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "a real awk on the same fixture shape still reports the fired entry" "$OUT" "1 entry this session"

echo ""
echo "=== N: a symlink-refused edit marker (#285) renders as its own fourth state, distinct from B and D ==="

P="$(new_project n)"
mkdir -p "$(state_of "$P")"
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-n.txt"
: > "$(state_of "$P")/edited-declined-sess-n.txt"
OUT="$(run_stop "$P" "sess-n")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "it says an edit could not be confirmed" "$OUT" "may not have been recorded"
if [ "$OUT" = "{}" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: the declined-marker state rendered as silence"
else
  PASS=$((PASS + 1))
  echo "  PASS: the declined-marker state did not render as silence"
fi
assert_not_contains "the declined-marker state text differs from case D" "$OUT" "could not tell what fired"

echo ""
echo "=== O: past the 200-name cap -- the cap bounds hooks.log's model-facing twin, not hooks.log itself ==="
# #292's own review caught the 200-cap silently truncating hooks.log too -- 205 fired
# entries: hooks.log must carry all 205, entry 200 and entry 205 both included, and the
# systemMessage total must be the true 205, not capped at 200 (the cap in this design
# only ever bounded the now-removed per-name list, never the total itself).

P="$(new_project o)"
O_STATE_DIR="$(state_of "$P")"
mkdir -p "$O_STATE_DIR"
: > "$O_STATE_DIR/vocab-shown-sess-o.txt"
_jit_o=1
while [ "$_jit_o" -le 205 ]; do
  printf -v _jit_o_name 'entry-%03d.md' "$_jit_o"
  printf 'loc:vocabulary:00-manual:%s\n' "$_jit_o_name" >> "$O_STATE_DIR/vocab-shown-sess-o.txt"
  manual_entry "$P" vocabulary "$_jit_o_name"
  _jit_o=$((_jit_o + 1))
done
unset _jit_o _jit_o_name O_STATE_DIR
OUT="$(run_stop "$P" "sess-o")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the systemMessage total is the true 205, not capped at 200" "$OUT" "205 entries this session"
LOG_O="$(log_of "$P")"
if [ -f "$LOG_O" ]; then
  assert_contains "hooks.log carries entry 200" "$(cat "$LOG_O")" "entry-200.md"
  assert_contains "hooks.log carries entry 205 too -- the 200-cap does not truncate the log" "$(cat "$LOG_O")" "entry-205.md"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: hooks.log was not written at all for a fired session"
fi

echo ""
echo "=== P: awk engine matrix -- a raw NUL ahead of stop_hook_active desyncs a NUL-truncating awk (#287) ==="
ENGINE_BIN=$(mktemp -d)
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2> /dev/null) || continue
  case " $ENGINE_SEEN " in *" $cand_path "*) continue ;; esac
  ENGINE_SEEN="$ENGINE_SEEN $cand_path"
  mkdir -p "$ENGINE_BIN/$cand"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$cand_path" > "$ENGINE_BIN/$cand/awk"
  chmod +x "$ENGINE_BIN/$cand/awk"
  ENGINES="$ENGINES $cand"
done

if [ -z "$ENGINES" ]; then
  echo "  SKIP-NOTE: no awk/gawk/nawk/mawk found on PATH -- this section could not run"
else
  P="$(new_project p)"
  mkdir -p "$(state_of "$P")"
  manual_entry "$P" vocabulary bridge.md
  printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-p.txt"

  NUL_PAYLOAD="$TMP/nul-payload-p.json"
  printf '{"session_id":"sess-p","cwd":"/x\000y","stop_hook_active":true}' > "$NUL_PAYLOAD"

  P_SAW_TRUNCATING=0
  P_SAW_TRANSPARENT=0
  for eng in $ENGINES; do
    P_LEN="$(printf 'a\000b' | PATH="$ENGINE_BIN/$eng:$PATH" awk '{print length($0)}' 2> /dev/null)"
    OUT="$(PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" < "$NUL_PAYLOAD" 2>&1)"
    RC=$?
    assert_rc0 "[$eng] the hook exits 0 on a raw NUL ahead of the key" "$RC"
    case "$P_LEN" in
      1)
        P_SAW_TRUNCATING=1
        assert_contains "[$eng, measured NUL-truncating] a NUL ahead of the key hides the real stop_hook_active:true and the fired report leaks through (#287)" "$OUT" "1 entry this session"
        ;;
      3)
        P_SAW_TRANSPARENT=1
        assert_empty_json "[$eng, measured NUL-transparent] a NUL ahead of the key does not hide the real stop_hook_active:true" "$OUT"
        ;;
      *)
        echo "  SKIP-NOTE: [$eng] the classifying probe returned '$P_LEN', neither 1 nor 3 -- not asserted either way"
        ;;
    esac
  done
  if [ "$P_SAW_TRUNCATING" -eq 0 ]; then
    echo "  SKIP-NOTE: no NUL-truncating awk was found among:$ENGINES -- the truncation half of #287 went unexercised on this run"
  fi
  if [ "$P_SAW_TRANSPARENT" -eq 0 ]; then
    echo "  SKIP-NOTE: no NUL-transparent awk was found among:$ENGINES -- the positive control for the truncation half went unexercised"
  fi
  unset OUT RC eng P_LEN P_SAW_TRUNCATING P_SAW_TRANSPARENT
fi
rm -rf "$ENGINE_BIN"
unset ENGINE_BIN ENGINES ENGINE_SEEN cand cand_path NUL_PAYLOAD

echo ""
echo "=== Q: #299 -- a loc: mark outside 00-manual is 'not yours', a bare mark is 'unknown', never guessed either way ==="
# The fixture #299 itself asks for: one loc:-keyed 00-manual mark (yours), one
# loc:-keyed mark in a different layer (not yours), and one bare mark -- as an older
# hook, earlier in the same session, would have written (unknown) -- asserted
# together in ONE hooks.log message so a two-state result (which is exactly the shape
# of the original bug) cannot pass this test by accident.

P="$(new_project q)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
auto_entry "$P" vocabulary 30-crosscutting auto-entry.md
printf 'loc:vocabulary:00-manual:bridge.md\nloc:vocabulary:30-crosscutting:auto-entry.md\nold-style.md\n' \
  > "$(state_of "$P")/vocab-shown-sess-q.txt"
OUT="$(run_stop "$P" "sess-q")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the total counts all three" "$OUT" "3 entries this session"
LOG_Q="$(log_of "$P")"
assert_contains "hooks.log states all three counts in one message" "$(cat "$LOG_Q")" "1 yours, 1 not yours, 1 unknown"
assert_contains "and names the yours entry" "$(cat "$LOG_Q")" "bridge.md"
assert_contains "and names the not-yours entry with its layer" "$(cat "$LOG_Q")" "auto-entry.md [30-crosscutting]"
assert_contains "and names the unknown (bare) entry as such" "$(cat "$LOG_Q")" "old-style.md [unknown: marker from an older hook this session]"

echo ""
echo "=== R: #299 -- rector.md: two entries sharing a basename across LAYERS of one dimension are not collapsed ==="
# The exact shape #299 measured live: a generated vocabulary/10-auto entry and a
# hand-written vocabulary/00-manual entry share one file name. Both must be counted
# (the cross-file/cross-layer dedup #299 asks to verify), and hooks.log must be able
# to tell them apart.

P="$(new_project r)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary rector.md
auto_entry "$P" vocabulary 10-auto rector.md
printf 'loc:vocabulary:00-manual:rector.md\nloc:vocabulary:10-auto:rector.md\n' > "$(state_of "$P")/vocab-shown-sess-r.txt"
OUT="$(run_stop "$P" "sess-r")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "both same-named entries are counted -- not collapsed into one" "$OUT" "2 entries this session"
LOG_R="$(log_of "$P")"
assert_contains "hooks.log carries one as yours" "$(cat "$LOG_R")" "1 yours, 1 not yours, 0 unknown"

echo ""
echo "=== S: #299 -- a fired tools entry is tagged, and rendered by its real name (#297) ==="

P="$(new_project s)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" tools how-work-lands.md
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\nloc:tools:00-manual:how-work-lands.md\n' > "$(state_of "$P")/vocab-shown-sess-s.txt"
OUT="$(run_stop "$P" "sess-s")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the total counts both" "$OUT" "2 entries this session"
LOG_S="$(log_of "$P")"
assert_contains "the tools entry's real name is in hooks.log" "$(cat "$LOG_S")" "how-work-lands.md"
assert_contains "and tagged with its dimension (#297 direction 2)" "$(cat "$LOG_S")" "how-work-lands.md (tools)"
assert_not_contains "no withheld placeholder for a well-formed tools entry" "$(cat "$LOG_S")" '<withheld'

echo ""
echo "=== S2: #299 -- a malformed loc: mark degrades to unknown, never to a confident 'yours' ==="
# Self-review finding on the first cut of this change: only the NAME component was
# validated, so "loc::00-manual:foo.md" -- an empty dimension, which no writer here
# produces but a hand-edited or truncated marker can -- was classified as the reader's
# own with full confidence, off a layer field nothing had vouched for. Both halves the
# classification is read off are checked now, and anything else is UNKNOWN. The
# positive control is the well-formed mark beside it: without that pair, "nothing was
# reported as yours" would also be true of a hook that classified nothing at all.

P="$(new_project s2)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\nloc::00-manual:forged.md\nloc:vocabulary::alsoforged.md\n' \
  > "$(state_of "$P")/vocab-shown-sess-s2.txt"
OUT="$(run_stop "$P" "sess-s2")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "all three are counted" "$OUT" "3 entries this session"
assert_contains "and the two malformed ones are hedged, not claimed" "$OUT" "2 of unknown origin"
LOG_S2="$(log_of "$P")"
assert_contains "hooks.log claims exactly the one well-formed mark as yours" "$(cat "$LOG_S2")" "1 yours, 0 not yours, 2 unknown"
assert_contains "the well-formed entry is still named (positive control)" "$(cat "$LOG_S2")" "bridge.md"

echo ""
echo "=== S3: #299/#297 -- a legacy rule: mark from a pre-#299 hook keeps its real name ==="
# The mixed-version window this change creates: a hook from before #299 fired earlier
# in the same session and wrote #297's "rule:<file>" key. Dropping #297's own strip
# put the literal "rule:adv.md" -- colon included -- through jit_report_name(), which
# refuses that byte, so every such mark rendered as "<withheld: not a plain name>":
# #297's exact defect, reintroduced for the transitional case. The prefix says `tools`
# and says nothing about a layer, so the dimension is kept and the class stays unknown.

P="$(new_project s3)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" tools legacy-rule.md
printf 'rule:legacy-rule.md\n' > "$(state_of "$P")/vocab-shown-sess-s3.txt"
OUT="$(run_stop "$P" "sess-s3")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "it is counted" "$OUT" "1 entry this session"
assert_contains "and hedged, because a rule: key carries no layer" "$OUT" "1 of unknown origin"
LOG_S3="$(log_of "$P")"
assert_contains "hooks.log prints its real name, not the withheld placeholder" "$(cat "$LOG_S3")" "legacy-rule.md"
assert_contains "tagged with the dimension the prefix does establish" "$(cat "$LOG_S3")" "legacy-rule.md (tools)"
assert_not_contains "and never renders as withheld (#297's own defect shape)" "$(cat "$LOG_S3")" "<withheld"

echo ""
echo "=== T: an unreadable 00-manual directory no longer destroys an answer the marks already carry ==="
# This section used to assert the OPPOSITE, and asserting it is how the regression got
# in: before #299, globbing 00-manual was the only way to answer "is this fired name
# the reader's own", so a directory that existed and could not be opened genuinely made
# the answer unknowable. A `loc:` mark answers that by itself now -- the layer is IN
# the mark -- so the old scan decided nothing and cost plenty: any one unreadable
# 00-manual directory, in any dimension, even one holding nothing that fired, replaced
# a fully known Y/N/U split with "cannot tell" and returned before hooks.log was
# written at all. A reviewer on this change caught the test encoding that as intended.
#
# What must hold instead: the classification is unchanged by the directory mode, and
# hooks.log still gets its line.

T_SKIPPED=0
P="$(new_project t)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary blocked.md
printf 'loc:vocabulary:00-manual:blocked.md\n' > "$(state_of "$P")/vocab-shown-sess-t.txt"
chmod 000 "$P/.claude/jit-context/vocabulary/00-manual" 2> /dev/null
if [ -r "$P/.claude/jit-context/vocabulary/00-manual" ]; then
  T_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove read permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section T tested nothing."
else
  OUT="$(run_stop "$P" "sess-t")"
  RC=$?
  assert_rc0 "the hook exits 0" "$RC"
  assert_contains "the entry is still counted" "$OUT" "1 entry this session"
  assert_not_contains "and nothing is hedged -- the mark said which layer it fired from" "$OUT" "unknown origin"
  LOG_T="$(log_of "$P")"
  if [ -f "$LOG_T" ]; then
    assert_contains "hooks.log still carries the split an unreadable directory used to swallow" "$(cat "$LOG_T")" "1 yours, 0 not yours, 0 unknown"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: hooks.log was not written at all -- the old early-return is still there"
  fi
fi
chmod 755 "$P/.claude/jit-context/vocabulary/00-manual" 2> /dev/null

echo ""
echo "=== U: JIT_CONTEXT_STATUS=off -- every shape above is silent, hooks.log is unaffected ==="

P="$(new_project u)"
printf 'JIT_CONTEXT_STATUS=off\n' > "$P/.claude/jit-context/config.env"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
manual_entry "$P" vocabulary cache.md
printf 'loc:vocabulary:00-manual:bridge.md\nloc:vocabulary:00-manual:cache.md\n' > "$(state_of "$P")/vocab-shown-sess-u.txt"
OUT="$(run_stop "$P" "sess-u")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "JIT_CONTEXT_STATUS=off -- the systemMessage is silent" "$OUT"
LOG_U="$(log_of "$P")"
if [ -f "$LOG_U" ]; then
  assert_contains "hooks.log still gets the fired-entries line with the status off" "$(cat "$LOG_U")" "yours"
  assert_contains "and still names the fired entries" "$(cat "$LOG_U")" "bridge.md"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: hooks.log was not written even though systemMessage is only silenced, not disabled"
fi

echo ""
echo "=== V: JIT_CONTEXT_STATUS=fired -- Stop's own line is the same total as summary, no per-name list ==="

P="$(new_project v)"
printf 'JIT_CONTEXT_STATUS=fired\n' > "$P/.claude/jit-context/config.env"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-v.txt"
OUT="$(run_stop "$P" "sess-v")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "fired mode still gives Stop just the total" "$OUT" "1 entry this session"
assert_not_contains "never a per-entry name on the Stop line itself" "$OUT" "bridge.md"

echo ""
echo "=== W: an unparseable JIT_CONTEXT_STATUS value is refused, not silently read as any mode ==="

P="$(new_project w)"
printf 'JIT_CONTEXT_STATUS=chatty\n' > "$P/.claude/jit-context/config.env"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'loc:vocabulary:00-manual:bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-w.txt"
OUT="$(run_stop "$P" "sess-w")"
RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "an unparseable value falls back to summary, not to off or fired" "$OUT" "1 entry this session"
LOG_W="$(log_of "$P")"
if [ -f "$LOG_W" ]; then
  assert_contains "the refusal is logged by line number, the existing config.env channel" "$(cat "$LOG_W")" "line 1"
  assert_contains "and names what was refused" "$(cat "$LOG_W")" "status mode"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: hooks.log was not written at all for the refused-config session"
fi

echo ""
echo "=========================================="
SKIP_TOTAL=$((D_SKIPPED + T_SKIPPED))
if [ "$SKIP_TOTAL" -eq 0 ]; then
  echo "Results: $PASS passed, $FAIL failed"
else
  echo "Results: $PASS passed, $FAIL failed, $SKIP_TOTAL section(s) SKIPPED"
fi
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP_TOTAL" -eq 0 ] || exit 2
exit 0
