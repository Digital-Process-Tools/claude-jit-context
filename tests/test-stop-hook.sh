#!/bin/bash
# #244 (part 2 of #233): the Stop hook that reads the injected-vs-edited comparison back.
# The numerator (what fired) already existed as the `shown` marks; post-tool-hook.sh
# (#244, same issue) is what makes the denominator (was anything edited) exist at all.
#
# THREE STATES, and the issue is explicit that the third must never render as the first:
# entries fired and none edited (one line, #292); entries fired and some edited
# (silence -- the healthy case, same posture SessionStart's own "ok" already takes);
# and COULD NOT TELL whether anything was edited, which must say so rather than pass as
# clean. This suite drives all three, plus the "nothing fired at all" case, which is a
# fourth, uncontroversial kind of silence (there is nothing to compare).
#
# #292: none of the four rendered states is actionable -- every non-silent message is
# housekeeping about .claude/jit-context/*.md entry FILES, never an instruction to the
# model. There is no fifth, actionable state in this machine to hold as a positive
# control against "reads as inert" -- so the control here is that all three non-silent
# messages (fired/none-updated, could-not-tell, edit-declined) carry the identical
# "no action needed" marker verbatim, while remaining textually distinguishable from
# one another (asserted in sections D and N below, unchanged from #284/#285/#286). If a
# genuinely actionable state is ever added to this machine, it must NOT carry that
# marker, and a test asserting so belongs beside these.
#
# #291/#295: the "none updated" state is further split by WHO can act on the fired
# entries. #244's own reasoning (jit_scan_entry_ages()'s comment) is that only
# 00-manual has a human author -- a generated or plugin-owned layer has nobody to
# curate it, and #291 documented a completed subagent waking three times to answer
# this line as though it were a task addressed to it. #295 measured a real project
# where every fired entry lived outside 00-manual and the nag fired on nearly every
# session anyway. So this suite also drives: every fired entry outside 00-manual
# (silence, section Q); a mix of 00-manual and non-manual (the split is reported,
# section R); a 00-manual directory that cannot be read (its own could-not-tell state,
# section S); and the message's own wording says what it is and who it is not for
# (asserted alongside section A).
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
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (exit $rc)"
  fi
}

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$output"; then
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

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

new_project() {
  local p="$TMP/$1"
  rm -rf "$p"
  mkdir -p "$p/.claude/jit-context/vocabulary/00-manual"
  printf '%s' "$p"
}

state_of() { printf '%s' "$1/.claude/jit-context/.discovery/state"; }

# A REAL entry file under a project's 00-manual layer, so a fixture's marker-file name
# corresponds to a file the new #291/#295 layer check can actually find. Every section
# below that expects the fired-entries report to render gives each fired name a real
# 00-manual file this way; a fired name with no matching call here has no file
# anywhere and is exactly the #295 "plugin-owned, nobody to curate" case.
manual_entry() {
  local p="$1" dim="$2" name="$3"
  mkdir -p "$p/.claude/jit-context/$dim/00-manual"
  : > "$p/.claude/jit-context/$dim/00-manual/$name"
}

run_stop() {
  local p="$1" sid="$2" active="${3:-false}"
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$sid" "$active" \
    | CLAUDE_PROJECT_DIR="$p" bash "$SCRIPTS/stop-hook.sh" 2>&1
}

echo "=== A: entries fired, nothing edited -- one line, framed as informational (#292/#291) ==="

P="$(new_project a)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
manual_entry "$P" vocabulary cache.md
printf 'bridge.md\ncache.md\n' > "$(state_of "$P")/vocab-shown-sess-a.txt"
OUT="$(run_stop "$P" "sess-a")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the message names the fired entry" "$OUT" "bridge.md"
assert_contains "and the other one too" "$OUT" "cache.md"
assert_contains "and says none were updated" "$OUT" "none updated"
assert_contains "and frames itself as informational, not an instruction" "$OUT" "no action needed"
assert_contains "and says what it concerns (#291)" "$OUT" "entry files"
assert_contains "and says it is not addressed to the reader (#291)" "$OUT" "not addressed to you"
if grep -qF -- '\n' <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the fired-entries message still renders as a multi-line list"
else
  PASS=$((PASS + 1)); echo "  PASS: the fired-entries message collapsed to one line"
fi

echo ""
echo "=== B: entries fired, something WAS edited this session -- silence ==="
# The healthy case. This is the pair to A: without it, a hook that always prints the
# fired-entries line regardless of the edit marker would pass A by construction.

P="$(new_project b)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-b.txt"
: > "$(state_of "$P")/edited-sess-b.txt"
OUT="$(run_stop "$P" "sess-b")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- edits happened" "$OUT"

echo ""
echo "=== C: nothing fired at all this session -- silence, there is nothing to compare ==="

P="$(new_project c)"
mkdir -p "$(state_of "$P")"
OUT="$(run_stop "$P" "sess-c")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- no injections this session" "$OUT"

echo ""
echo "=== D: an unwritable tree -- COULD NOT TELL, never silence ==="
# The state directory degrades to empty on a checkout this process cannot write to
# (common.sh). Nothing here can tell whether anything fired or was edited, and #244 is
# explicit that this must not render as the clean case in B/C.

D_SKIPPED=0
P="$(new_project d)"
chmod 555 "$P/.claude/jit-context" 2>/dev/null
if [ -w "$P/.claude/jit-context" ]; then
  D_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove write permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section D tested nothing."
else
  OUT="$(run_stop "$P" "sess-d")"; RC=$?
  assert_rc0 "the hook exits 0" "$RC"
  assert_contains "it says it could not tell" "$OUT" "could not tell"
  assert_contains "and frames itself as informational, not an instruction" "$OUT" "no action needed"
  if [ "$OUT" = "{}" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: could-not-tell rendered as silence"
  else
    PASS=$((PASS + 1)); echo "  PASS: could-not-tell did not render as silence"
  fi
fi
chmod 755 "$P/.claude/jit-context" 2>/dev/null

echo ""
echo "=== E: no jit-context tree at all -- fully inert ==="

P="$TMP/e"
mkdir -p "$P"
OUT="$(run_stop "$P" "sess-e")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing at all" "$OUT"
if [ -e "$P/.claude" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a .claude directory was materialised for a tree-less project"
else
  PASS=$((PASS + 1)); echo "  PASS: no .claude directory is materialised"
fi

echo ""
echo "=== F: sentinel keys in the shown marks are not reported as fired entries ==="

P="$(new_project f)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'bridge.md\njit-refused-vocab\njit-no-subject\n' > "$(state_of "$P")/vocab-shown-sess-f.txt"
OUT="$(run_stop "$P" "sess-f")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the real entry is named" "$OUT" "bridge.md"
SENTINEL_HIT=0
grep -qF -- "jit-refused-vocab" <<<"$OUT" && SENTINEL_HIT=1
grep -qF -- "jit-no-subject" <<<"$OUT" && SENTINEL_HIT=1
if [ "$SENTINEL_HIT" = 1 ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a sentinel key was reported as a fired entry"
  echo "    got: $OUT"
else
  PASS=$((PASS + 1)); echo "  PASS: no sentinel key was reported as a fired entry"
fi

echo ""
echo "=== G: the same entry fired through both marker files is only counted once ==="

P="$(new_project g)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-g.txt"
printf 'bridge.md\n' > "$(state_of "$P")/path-shown-sess-g.txt"
OUT="$(run_stop "$P" "sess-g")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
COUNT="$(grep -o 'bridge\.md' <<<"$OUT" | wc -l | tr -d ' ')"
if [ "$COUNT" = "1" ]; then
  PASS=$((PASS + 1)); echo "  PASS: the entry is listed exactly once"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the entry appeared $COUNT times, expected 1"
  echo "    got: $OUT"
fi

echo ""
echo "=== H: the dedup scan is bounded, not quadratic in an untrusted marker file ==="
# The collection pass re-scans its own accumulator on every line (a plain `case`, no
# associative array -- bash 3.2 has none); left unbounded that is quadratic in the
# number of distinct names two marker files can hold. This does not prove the bound
# fires at exactly the right count -- it proves a marker file bigger than any real
# session produces still answers, and answers with every name accounted for one way
# or the other (listed, or named in the overflow line). Every one of the 600 is also
# given a real 00-manual file, since this section is about the bound, not about the
# #291/#295 layer split -- sections Q/R below cover that split on their own, smaller
# fixtures.

P="$(new_project h)"
mkdir -p "$(state_of "$P")"
JIT_HI=600
_jit_seq=1
: > "$(state_of "$P")/vocab-shown-sess-h.txt"
while [ "$_jit_seq" -le "$JIT_HI" ]; do
  printf 'entry-%s.md\n' "$_jit_seq" >> "$(state_of "$P")/vocab-shown-sess-h.txt"
  manual_entry "$P" vocabulary "entry-$_jit_seq.md"
  _jit_seq=$((_jit_seq + 1))
done
OUT="$(run_stop "$P" "sess-h")"; RC=$?
assert_rc0 "the hook exits 0 on 600 distinct fired entries" "$RC"
assert_contains "the reported total accounts for all 600" "$OUT" "$JIT_HI entries injected"
assert_contains "the overflow past the cap is named, not silently dropped" "$OUT" "more past this hook's own"
# Explore self-review finding: 100 of the 600 fired names sit past JIT_FIRED_MAX (500)
# and are never individually checked against 00-manual, so even though every one of
# the 600 genuinely has a real 00-manual file, the reported count must not claim
# certainty it does not have -- "at least 500", never a flat "500", and the mixed
# wording (never the flat "none updated" sentence, which would claim the overflow
# names could not possibly be the reader's own).
assert_contains "the overflow forces the split wording, not the flat 'none updated' claim" "$OUT" "of them yours and not updated"
assert_contains "the checked-manual count is hedged as a floor, not an exact claim" "$OUT" "at least 500 of them yours"
if grep -qF -- ": $JIT_HI entries injected this session, none updated" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: an overflowed session rendered the flat all-yours sentence"
else
  PASS=$((PASS + 1)); echo "  PASS: an overflowed session did not render the flat all-yours sentence"
fi

echo ""
echo "=== I: stop_hook_active=true -- a re-entry caused by this hook's own output, never re-report ==="
# #279: the harness re-invokes Stop when a previous Stop's own additionalContext blocked
# the turn from ending, and sets stop_hook_active=true on that re-entry. Section A is this
# case's positive control on the same code path: the same fired-entries fixture, with
# stop_hook_active=false, must still produce the fired-entries line. Without that pairing
# this assertion would pass for free if the hook simply exited early on a malformed payload.

P="$(new_project i)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\ncache.md\n' > "$(state_of "$P")/vocab-shown-sess-i.txt"
OUT="$(run_stop "$P" "sess-i" "true")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "stop_hook_active=true means no additionalContext, even though entries fired" "$OUT"

echo ""
echo "=== J: stop_hook_active is missing from the payload entirely -- treated as false ==="
# A distinct code path from I/A explicit false: jit_stop_hook_active() falls off its own
# scan loop and returns 0 via the final fallthrough, never matching the key at all. An
# older harness, or a hand-run reproduction, can omit the field outright.

P="$(new_project j)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-j.txt"
OUT="$(printf '{"session_id":"sess-j","hook_event_name":"Stop"}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "a payload with no stop_hook_active key at all still reports" "$OUT" "bridge.md"

echo ""
echo "=== K: an escaped quote earlier in the payload must not desync the field scan ==="
# jit_json_fields() merges raw[] segments across an escaped quote, so its LOGICAL field
# count (n) can sit below the PHYSICAL raw[] position stop_hook_active own value lives
# at. A bound check written against n instead of the physical array would refuse a
# genuinely in-range raw[] read and misreport a real true as false here -- silently
# reopening #279 for exactly the sessions whose cwd or transcript_path contains a
# literal double quote.

P="$(new_project k)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\ncache.md\n' > "$(state_of "$P")/vocab-shown-sess-k.txt"
OUT="$(printf '{"session_id":"sess-k","cwd":"C:\\quo\\"te","stop_hook_active":true}' \
  | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "an escaped quote ahead of stop_hook_active does not hide a real true" "$OUT"

echo ""
echo "=== L: awk cannot run at all -- unknown, not false, taking the safe (true-like) silent branch (#284) ==="
# The parsed STOP_HOOK_ACTIVE variable is empty when the awk parse cannot run at all
# (stub awk, a broken interpreter). Reading that empty string identically to a parsed
# "false" falls through to the "could not tell" branch further down, which EMITS
# additionalContext -- exactly the output that blocks a turn from ending and reopens
# #279's re-entry loop, in the one state where the hook is least able to notice. A
# third value, distinct from both true and false, must take the SAME silent early
# return "true" does.

P="$(new_project l)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-l.txt"
FAKE_AWK_DIR="$TMP/fake-awk-l"
mkdir -p "$FAKE_AWK_DIR"
cat > "$FAKE_AWK_DIR/awk" <<'FAKE_AWK'
#!/bin/sh
exit 127
FAKE_AWK
chmod +x "$FAKE_AWK_DIR/awk"
OUT="$(printf '{"session_id":"sess-l","stop_hook_active":true}' \
  | PATH="$FAKE_AWK_DIR:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" 2>&1)"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "an unusable awk renders as silence, never as the could-not-tell additionalContext" "$OUT"

echo ""
echo "=== M: a fired session with a REAL awk and stop_hook_active=false is the positive control for L ==="
# Without this pairing, L would pass for free if the fix simply silenced this hook
# whenever anything at all goes wrong -- section A already proves the ordinary awk
# path still reports; this repeats that proof with the SAME fixture shape as L (a
# single fired entry) so a reader can compare the two runs directly.

P="$(new_project m)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-m.txt"
OUT="$(run_stop "$P" "sess-m")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "a real awk on the same fixture shape still reports the fired entry" "$OUT" "bridge.md"

echo ""
echo "=== N: a symlink-refused edit marker (#285) renders as its own fourth state, distinct from B and D ==="
# post-tool-hook.sh drops a distinguishable declined-marker when its own symlink guard
# trips on the edit marker's write. This must render differently from B (nothing was
# edited at all) and from D (the state directory itself could not be trusted) -- a
# reader must be able to tell "an edit happened but its evidence was refused" apart
# from both.

P="$(new_project n)"
mkdir -p "$(state_of "$P")"
printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-n.txt"
: > "$(state_of "$P")/edited-declined-sess-n.txt"
OUT="$(run_stop "$P" "sess-n")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "it says an edit could not be confirmed" "$OUT" "could not be confirmed"
assert_contains "and frames itself as informational, not an instruction" "$OUT" "no action needed"
if [ "$OUT" = "{}" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the declined-marker state rendered as silence"
else
  PASS=$((PASS + 1)); echo "  PASS: the declined-marker state did not render as silence"
fi
if grep -qF -- "none updated" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the declined-marker state rendered identically to case B (none updated)"
else
  PASS=$((PASS + 1)); echo "  PASS: the declined-marker state text differs from case B"
fi
if grep -qF -- "could not tell whether any entry fired" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the declined-marker state rendered identically to case D (state dir unknown)"
else
  PASS=$((PASS + 1)); echo "  PASS: the declined-marker state text differs from case D"
fi

echo ""
echo "=== O: past the 200-name cap -- the cap bounds the model line only, never hooks.log ==="
# #292's own review round (self-review) caught two regressions the first pass of this
# change introduced: an off-by-one that dropped the 200th fired entry's name from the
# model-facing line while still logging it (so the "N more" tail undercounted by one),
# and the SAME 200-entry cap silently truncating hooks.log too -- contradicting the
# model line's own "see hooks.log" pointer, since hooks.log never had the rest either.
# 205 fired entries: the model line must name exactly entries 1-200 and say "5 more";
# hooks.log must carry all 205, entry 200 and entry 205 both included. Every one of the
# 205 gets a real 00-manual file for the same reason section H does.

P="$(new_project o)"
mkdir -p "$(state_of "$P")"
: > "$(state_of "$P")/vocab-shown-sess-o.txt"
_jit_o=1
while [ "$_jit_o" -le 205 ]; do
  printf 'entry-%03d.md\n' "$_jit_o" >> "$(state_of "$P")/vocab-shown-sess-o.txt"
  manual_entry "$P" vocabulary "$(printf 'entry-%03d.md' "$_jit_o")"
  _jit_o=$((_jit_o + 1))
done
unset _jit_o
OUT="$(run_stop "$P" "sess-o")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the model line names entry 200 (the cap boundary itself)" "$OUT" "entry-200.md"
assert_contains "the model line's overflow tail accounts for exactly the other 5" "$OUT" "and 5 more"
if grep -qF -- "entry-201.md" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the model line named an entry past the 200 cap"
else
  PASS=$((PASS + 1)); echo "  PASS: the model line names nothing past the 200 cap"
fi
LOG="$P/.claude/jit-context/.discovery/logs/hooks.log"
if [ -f "$LOG" ]; then
  assert_contains "hooks.log carries entry 200" "$(cat "$LOG")" "entry-200.md"
  assert_contains "hooks.log carries entry 205 too -- the model-line cap does not truncate the log" "$(cat "$LOG")" "entry-205.md"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: hooks.log was not written at all for a fired session"
fi

echo ""
echo "=== P: awk engine matrix -- a raw NUL ahead of stop_hook_active desyncs a NUL-truncating awk (#287) ==="
# Measured in the 0.7.1 gate-3 audit across the three awks on that machine: a raw NUL
# byte placed in cwd, ahead of the "stop_hook_active" key, is read correctly by an awk
# that carries an embedded NUL through getline (gawk, mawk on that machine) but truncates
# the accumulated input record under one-true-awk, so jit_json_fields() never reaches the
# key at all -- it reads as ABSENT, which jit_stop_hook_active()'s own fallthrough
# renders as false, not as unknown. The real stop_hook_active:true is lost and this
# session's fired entries are reported: the exact re-entry shape #279/#284 exist to
# prevent.
#
# Filed informational rather than a misreport at weight: RFC 8259 forbids a raw NUL
# inside a JSON string and the real harness never emits one -- it escapes the byte
# instead -- so this input is not reachable through the real producer. Still worth
# pinning: the macos-latest CI leg's plain `awk` truncates, and nothing before this
# asserted the divergence, so a change that made the input reachable would not be caught.
#
# WHICH engine truncates is a property of the BINARY, not of the PATH name it answers to
# on a given platform -- Debian/Ubuntu's default `/usr/bin/awk` is mawk (NUL-transparent),
# not one-true-awk, and Git Bash on Windows ships only a gawk-backed `awk` with no
# separate gawk/nawk/mawk binary at all. A first draft of this section keyed the expected
# assertion off the candidate NAME (`awk` => expect truncation, `gawk`/`mawk` => expect
# transparency) and would have asserted the wrong thing, loudly, on both of those --
# self-review (an Explore reviewer and oss:auditor, run in parallel against the committed
# diff) caught it before this shipped. Classified by a tiny probe instead:
# `length($0)` on a 3-byte NUL-carrying record is 1 if the read truncated at the NUL, 3
# if the engine carried it through -- this needs no shell variable to hold the raw byte,
# only the printed digit, so it is exempt from the very $( ) truncation this file's own
# convention warns about.
ENGINE_BIN=$(mktemp -d)
ENGINES=""
ENGINE_SEEN=""
for cand in awk gawk nawk mawk; do
  cand_path=$(command -v "$cand" 2>/dev/null) || continue
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
  # #291/#295 (rebase note): stop-hook.sh now only renders the fired-entries report
  # when at least one fired name is backed by a real 00-manual file -- otherwise it
  # is the new "nothing to curate" silence, which would swallow this section's own
  # leaking-case assertion below before it ever reaches the awk-truncation code path
  # this section exists to pin. bridge.md needs a real file for the same reason every
  # other report-expecting section in this file does.
  manual_entry "$P" vocabulary bridge.md
  printf 'bridge.md\n' > "$(state_of "$P")/vocab-shown-sess-p.txt"

  # Written straight to a file with printf's own octal escape, never through a shell
  # variable or a $( ) capture -- bash truncates a variable at an embedded NUL the same
  # way this hook's own captures would (paths/00-manual/tests.md), which would make the
  # byte disappear before any engine ever saw it.
  NUL_PAYLOAD="$TMP/nul-payload-p.json"
  printf '{"session_id":"sess-p","cwd":"/x\000y","stop_hook_active":true}' > "$NUL_PAYLOAD"

  P_SAW_TRUNCATING=0
  P_SAW_TRANSPARENT=0
  for eng in $ENGINES; do
    # The classifying probe: 3 bytes in, and only the DIGIT crosses back through $( ),
    # never the NUL itself.
    P_LEN="$(printf 'a\000b' | PATH="$ENGINE_BIN/$eng:$PATH" awk '{print length($0)}' 2>/dev/null)"
    OUT="$(PATH="$ENGINE_BIN/$eng:$PATH" CLAUDE_PROJECT_DIR="$P" bash "$SCRIPTS/stop-hook.sh" < "$NUL_PAYLOAD" 2>&1)"; RC=$?
    assert_rc0 "[$eng] the hook exits 0 on a raw NUL ahead of the key" "$RC"
    case "$P_LEN" in
      1)
        P_SAW_TRUNCATING=1
        assert_contains "[$eng, measured NUL-truncating] a NUL ahead of the key hides the real stop_hook_active:true and the fired report leaks through (#287)" "$OUT" "bridge.md"
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
echo "=== Q: every fired entry is outside 00-manual -- silence, there is nobody to curate it (#295) ==="
# #295's measured corpus: a real project where every one of 8 indexed entries came
# from a plugin-owned layer and the project had no 00-manual layer at all. There is no
# file here this reader owns or could edit, so this is the SAME "nothing to compare"
# case section C already stays silent for -- not the "fired and none updated" case,
# because updating is not something the reader of this message can do.

P="$(new_project q)"
mkdir -p "$(state_of "$P")"
# "auto-entry.md" fires but is never created under 00-manual anywhere -- it stands in
# for #295's plugin-owned layer (e.g. 01-oss), where the file exists but not there.
printf 'auto-entry.md\n' > "$(state_of "$P")/vocab-shown-sess-q.txt"
OUT="$(run_stop "$P" "sess-q")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_empty_json "the hook says nothing -- nothing fired is the reader's to curate" "$OUT"

echo ""
echo "=== R: a mixed session -- some 00-manual, some not -- reports the split, not a flat count (#295) ==="
# #295's own suggested wording: "3 entries injected, 1 of them yours and not updated".
# The number has to name something the reader can act on -- the flat "2 entries
# injected... none updated" from before this fix would ask the reader to curate a file
# (auto-entry.md) that is not theirs to edit.

P="$(new_project r)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary bridge.md
printf 'bridge.md\nauto-entry.md\n' > "$(state_of "$P")/vocab-shown-sess-r.txt"
OUT="$(run_stop "$P" "sess-r")"; RC=$?
assert_rc0 "the hook exits 0" "$RC"
assert_contains "the total names both fired entries" "$OUT" "2 entries injected"
assert_contains "the split names exactly the one the reader owns" "$OUT" "1 of them yours and not updated"
assert_contains "the owned entry is still named in the fired list" "$OUT" "bridge.md"
assert_contains "and frames itself as informational, not an instruction" "$OUT" "no action needed"
assert_contains "and says it is not addressed to the reader (#291)" "$OUT" "not addressed to you"
if grep -qF -- ": 2 entries injected this session, none updated" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: a mixed session rendered as the flat all-yours sentence"
else
  PASS=$((PASS + 1)); echo "  PASS: a mixed session did not render as the flat all-yours sentence"
fi

echo ""
echo "=== S: a 00-manual directory that cannot be READ -- COULD NOT TELL, never silence ==="
# Self-review (oss:auditor) on this same change (#291/#295) caught this: the membership
# scan added above globs each dimension's 00-manual directory, and a directory that
# exists but cannot be opened (permissions, not absence) makes that glob return nothing
# -- silently, with no distinguishable signal. That is byte-identical to a 00-manual
# layer that genuinely holds nothing manual, so a session where the fired entry MIGHT be
# the reader's own, but this run could not tell, was rendering as the Q/R silent case
# above. #244's own three-states rule already refuses exactly this shape for the state
# directory (section D); this fixture forces the same refusal for the 00-manual layer
# the new scan reads.

S_SKIPPED=0
P="$(new_project s)"
mkdir -p "$(state_of "$P")"
manual_entry "$P" vocabulary blocked.md
printf 'blocked.md\n' > "$(state_of "$P")/vocab-shown-sess-s.txt"
chmod 000 "$P/.claude/jit-context/vocabulary/00-manual" 2>/dev/null
if [ -r "$P/.claude/jit-context/vocabulary/00-manual" ]; then
  S_SKIPPED=1
  echo "  SKIP-NOTE: chmod did not remove read permission here (running as root, or a"
  echo "             filesystem without POSIX modes). Section S tested nothing."
else
  OUT="$(run_stop "$P" "sess-s")"; RC=$?
  assert_rc0 "the hook exits 0" "$RC"
  assert_contains "it says it could not tell" "$OUT" "could not tell"
  assert_contains "and frames itself as informational, not an instruction" "$OUT" "no action needed"
  if [ "$OUT" = "{}" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: an unreadable 00-manual directory rendered as silence"
  else
    PASS=$((PASS + 1)); echo "  PASS: an unreadable 00-manual directory did not render as silence"
  fi
fi
chmod 755 "$P/.claude/jit-context/vocabulary/00-manual" 2>/dev/null

echo ""
echo "=========================================="
SKIP_TOTAL=$((D_SKIPPED + S_SKIPPED))
if [ "$SKIP_TOTAL" -eq 0 ]; then
  echo "Results: $PASS passed, $FAIL failed"
else
  # The same third state this whole file exists to test for, one level up: a section
  # that could not run must not render as a suite that ran clean. `run-all.sh` already
  # gives exit 2 its own bucket -- "SKIPPED suites (could not build their fixtures
  # here)" -- distinct from a run of all-green suites, the same convention
  # test-session-markers.sh/test-marker-degradation.sh/test-hook-tmpfile.sh/
  # test-log-containment.sh already use for a chmod that could not bite (root, or a
  # filesystem without POSIX modes). Followed here rather than invented: D_SKIPPED
  # existed with nothing reading it, which is the identical defect class section D is
  # itself about, one layer up. S_SKIPPED is the same guard for the same reason, one
  # section down.
  echo "Results: $PASS passed, $FAIL failed, $SKIP_TOTAL section(s) SKIPPED"
fi
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP_TOTAL" -eq 0 ] || exit 2
exit 0
