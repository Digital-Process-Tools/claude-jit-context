#!/bin/bash
# Tests for #397: a decisive awk that crashes must not render as silence.
#
# Three hooks fork a decisive awk whose stdout IS the hook's JSON reply. Before #397's
# fix, a crashed awk (SIGSEGV, exit 139 -- #393's own measured mechanism under
# concurrent load, 8 times across 8 sections) printed 0 bytes and the hook still
# `exit 0`d unconditionally below it: a crashed awk and a rule with no opinion were
# byte-identical on the wire, and on pre-tool-hook.sh (the one hook with a `mode: block`
# refusal decision) that meant the harness read the crash as PERMISSION. This suite
# drives the crash directly, on all three hooks, and pins the shape #397's fix commits
# to: pre-tool-hook.sh fails CLOSED (a `block` decision naming the crash),
# pre-prompt-hook.sh and pre-path-hook.sh say so over `systemMessage` without blocking
# anything (neither has a `decision` field to fail closed WITH), and pre-path-hook.sh
# specifically emits exactly ONE json object even when the crash lands after its own
# two-pass candidates channel has already been written to disk (self-review finding,
# oss:auditor).
#
# NOT the retry question -- #397 is explicit that is separate and left open. This suite
# only pins "the crash speaks (or refuses), never silence".
#
# #400 (CI, PR #400 red): the fix's first cut captured the decisive awk's output through
# a bare "$( )", which strips every trailing newline -- so the empty envelope's own
# `print "{}"` lost the newline it always had, and tests/test-inert-without-tree.sh's
# section B saw four of six hooks' `{}\n{}\n` answers glue onto one line. This suite's
# own assert_has/assert_lacks/assert_single_valid_json above are ALL driven off a
# captured bash VARIABLE ($( )), which strips exactly the same bytes the bug strips --
# so this suite was blind to its own subject's regression class by construction, the
# same way #397's own double-print self-review finding was only caught by counting
# decoded objects rather than reading content. assert_exact_bytes below closes that:
# it reads a hook's stdout from a FILE (never a captured variable), the one channel
# framing survives through, and pins the exact byte sequence -- content AND
# termination -- against what main would have emitted for the identical fixture and
# payload, measured directly rather than assumed.
#
# assert_has/assert_lacks below take a captured hook-output STRING directly (not a
# file), by design: the crash-shaped output here is always small, single-line JSON
# built entirely from this suite's own fixture, never author-controlled markdown, so
# #56's SIGPIPE-inversion risk and #78's NUL-dropping risk do not apply the way they
# do to the other suites' free-form entry bodies. Driven below (jit-drive: capture).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# --- Positive control first (#397's own "must fire" pairing) ---------------------
# A shim that does not actually crash awk would make every "the crash speaks" assertion
# below pass for the wrong reason -- the harness never saw a real crash, just a hook that
# was never exercised. Probe the exact construct the shim below uses, on THIS host,
# before trusting anything downstream of it.
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/awk" << 'SHIMEOF'
#!/bin/sh
kill -SEGV $$
SHIMEOF
chmod +x "$SHIM_DIR/awk"
PATH="$SHIM_DIR:$PATH" awk 'BEGIN { print "unreachable" }' > /dev/null 2>&1
PROBE_RC=$?
if [ "$PROBE_RC" -ne 139 ]; then
  echo "SKIPPED: this host's shell cannot make a shimmed 'awk' exit 139 via kill -SEGV \$\$" >&2
  echo "         (got exit $PROBE_RC instead) -- #397's crash-handling assertions are UNTESTED here." >&2
  echo "         Nothing else in this suite ran." >&2
  rm -rf "$SHIM_DIR"
  exit 2
fi

# --- A second shim, for pre-path-hook.sh's own two-pass race (self-review finding) ---
# Writes the mode-0 candidates sentinel to the file named by its own `-v log_tmp=...`
# argument, exactly as a real awk crashing AFTER `close(log_tmp); exit` -- but before the
# process actually dies -- would leave behind, then crashes. If pre-path-hook.sh ever
# regresses to trusting that leftover sentinel after a non-zero exit, this reproduces
# the double-JSON-object defect the fix for that finding closes.
SHIM_DIR2=$(mktemp -d)
cat > "$SHIM_DIR2/awk" << 'SHIMEOF'
#!/bin/sh
TMPFILE=""
want_val=0
for a in "$@"; do
  if [ "$want_val" = "1" ]; then
    case "$a" in
      log_tmp=*) TMPFILE="${a#log_tmp=}" ;;
    esac
    want_val=0
    continue
  fi
  case "$a" in
    -v) want_val=1 ;;
  esac
done
if [ -n "$TMPFILE" ]; then
  printf -- '--jit-candidates--\nfakesession\nscripts/\n' > "$TMPFILE"
fi
kill -SEGV $$
SHIMEOF
chmod +x "$SHIM_DIR2/awk"

# --- Fixture: one tree, all three dimensions, reused by every hook below ---
TEST_DIR=$(mktemp -d)
IDX="00-index"
IDX="$IDX.tsv"
TOOLS_DIR="$TEST_DIR/.claude/jit-context/tools/00-manual"
VOCAB_DIR="$TEST_DIR/.claude/jit-context/vocabulary"
PATHS_DIR="$TEST_DIR/.claude/jit-context/paths/00-manual"
mkdir -p "$TOOLS_DIR" "$PATHS_DIR"
mkdir -p "$VOCAB_DIR/00-manual" "$VOCAB_DIR/10-auto" "$VOCAB_DIR/20-grouped" "$VOCAB_DIR/30-crosscutting"

printf 'Bash\trmrfxyz397\tdeny397.md\tblock\t\t\n' > "$TOOLS_DIR/$IDX"
echo "deny body 397" > "$TOOLS_DIR/deny397.md"
printf 'hello397\thello397.md\n' > "$VOCAB_DIR/00-manual/$IDX"
echo "hello vocab 397" > "$VOCAB_DIR/00-manual/hello397.md"
for l in 10-auto 20-grouped 30-crosscutting; do : > "$VOCAB_DIR/$l/$IDX"; done
: > "$PATHS_DIR/$IDX"

# --- Helpers -----------------------------------------------------------------------
# jit-drive: assert_has contains capture
# jit-drive: assert_lacks not_contains capture
assert_has() {
  local desc="$1" output="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$output"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: $needle"
    echo "    got: ${output:0:300}"
  fi
}

assert_lacks() {
  local desc="$1" output="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$output"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    should NOT contain: $needle"
    echo "    got: ${output:0:300}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

# One JSON object, valid, and exactly one -- guarded, not required: a host with no
# python3 still gets every assert_has/assert_lacks check above, just not this one (same
# degrade-gracefully shape test-jit-match.sh already uses for the same tool).
assert_single_valid_json() {
  local desc="$1" output="$2"
  if ! command -v python3 > /dev/null 2>&1; then
    echo "  SKIP (no python3 on this host): $desc"
    return
  fi
  if printf '%s' "$output" | python3 -c '
import sys, json
data = sys.stdin.read().strip()
dec = json.JSONDecoder()
idx = 0
n = 0
while idx < len(data):
    obj, end = dec.raw_decode(data, idx)
    n += 1
    idx = end
    while idx < len(data) and data[idx].isspace():
        idx += 1
if n != 1:
    sys.exit(1)
' 2> /dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected exactly one valid JSON object"
    echo "    got: ${output:0:300}"
  fi
}

# jit-drive: none -- assert_exact_bytes compares two files for EXACT byte equality
# (via cmp), which is not one of this harness's drivable contains/not_contains/
# blocked/token_row semantics: nothing here searches for a needle, so there is no
# substring to drive PASS/FAIL against. Reads the hook's stdout from a FILE, never a
# captured shell variable: `$( )` strips every trailing newline from anything it
# captures, so a variable-based comparison here would be exactly as blind to a
# missing terminator as the bug it exists to catch (#400 self-review). `cmp` compares
# raw bytes, not text lines, so it cannot be fooled by a platform's line-ending
# translation either.
assert_exact_bytes() {
  local desc="$1" path="$2" expected="$3" expected_file
  expected_file=$(mktemp)
  printf '%s' "$expected" > "$expected_file"
  if cmp -s "$expected_file" "$path"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    # od's own output for these fixtures is already a few bytes -- no `| head` needed
    # (or wanted: piping a writer into an early-exiting reader is the #56 shape this
    # suite's own assertion helpers exist to catch, so this file does not reintroduce
    # it in its own diagnostics).
    echo "    expected ($(wc -c < "$expected_file" | tr -d ' ') bytes): $(od -c < "$expected_file")"
    echo "    got ($(wc -c < "$path" 2> /dev/null | tr -d ' ') bytes): $(od -c < "$path" 2> /dev/null)"
  fi
  rm -f "$expected_file"
}

echo "=== framing: content survives a captured variable, termination does not (#400) ==="

# One more fixture, deliberately separate from the one above: a single block rule and
# nothing else, so the healthy "{}" case below is genuinely a no-match rather than
# something this suite's own vocabulary/path rows could accidentally satisfy.
FRAME_DIR=$(mktemp -d)
FT="$FRAME_DIR/.claude/jit-context/tools/00-manual"
FV="$FRAME_DIR/.claude/jit-context/vocabulary"
FP="$FRAME_DIR/.claude/jit-context/paths/00-manual"
mkdir -p "$FT" "$FP"
mkdir -p "$FV/00-manual" "$FV/10-auto" "$FV/20-grouped" "$FV/30-crosscutting"
printf 'Bash\trmrfxyz397\tdeny397.md\tblock\t\t\n' > "$FT/$IDX"
echo "deny body 397" > "$FT/deny397.md"
for l in 00-manual 10-auto 20-grouped 30-crosscutting; do : > "$FV/$l/$IDX"; done
: > "$FP/$IDX"

FRAME_OUT=$(mktemp)

# main's own bytes for this exact shape, measured directly rather than assumed: `print
# "{}"` (awk's own statement, unconditionally newline-terminated) is what every one of
# these three hooks has always emitted for "nothing matched" -- #400's own regression
# was this byte going missing on exactly two, then found to be at risk on the third too.
printf '{"tool_name":"Bash","tool_input":{"command":"totally-unrelated-397"}}' \
  | CLAUDE_PROJECT_DIR="$FRAME_DIR" bash "$SCRIPT_DIR/scripts/pre-tool-hook.sh" 2> /dev/null > "$FRAME_OUT"
assert_exact_bytes "pre-tool-hook.sh: the no-match envelope is \"{}\" plus its newline, byte for byte" \
  "$FRAME_OUT" $'{}\n'

printf '{"prompt":"nothing397 here"}' \
  | CLAUDE_PROJECT_DIR="$FRAME_DIR" bash "$SCRIPT_DIR/scripts/pre-prompt-hook.sh" 2> /dev/null > "$FRAME_OUT"
assert_exact_bytes "pre-prompt-hook.sh: the no-match envelope is \"{}\" plus its newline, byte for byte" \
  "$FRAME_OUT" $'{}\n'

printf '{"tool_name":"Read","tool_input":{"file_path":"nowhere397.md"}}' \
  | CLAUDE_PROJECT_DIR="$FRAME_DIR" bash "$SCRIPT_DIR/scripts/pre-path-hook.sh" 2> /dev/null > "$FRAME_OUT"
assert_exact_bytes "pre-path-hook.sh: the no-match envelope is \"{}\" plus its newline, byte for byte" \
  "$FRAME_OUT" $'{}\n'

# The refusal path's own envelope never had a trailing newline even before #397 --
# `printf "%s", jit_envelope_block(...)`, not `print` -- so the crash envelope this
# issue adds must match THAT shape, not the "{}" one: ends in the closing brace and
# nothing after it, no newline appended by the capture-and-reprint route.
printf '{"tool_name":"Bash","tool_input":{"command":"rmrfxyz397 now"}}' \
  | CLAUDE_PROJECT_DIR="$FRAME_DIR" bash "$SCRIPT_DIR/scripts/pre-tool-hook.sh" 2> /dev/null > "$FRAME_OUT"
if [ -s "$FRAME_OUT" ] && [ "$(tail -c 1 "$FRAME_OUT" | od -An -c | tr -d ' \n')" = '}' ]; then
  PASS=$((PASS + 1))
  echo "  PASS: pre-tool-hook.sh: control -- a real block envelope still ends in '}' with nothing after it"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: pre-tool-hook.sh: control -- a real block envelope should end in '}' with nothing after it"
  echo "    got: $(od -c < "$FRAME_OUT" 2> /dev/null | tail -3)"
fi

# Same control for the two hooks whose crash envelope is the systemMessage shape --
# `printf "%s", jit_envelope_inject_sysmsg(...)`/jit_json_escape(...) output never had a
# trailing newline either, so the crash text this issue adds (jit_awk_crash_sysmsg(),
# built the same way) must not pick one up passing through jit_awk_capture().
SCRATCH_SEG2=$(mktemp -d)
cat > "$SCRATCH_SEG2/awk" << 'SHIMEOF'
#!/bin/sh
kill -SEGV $$
SHIMEOF
chmod +x "$SCRATCH_SEG2/awk"

printf '{"prompt":"anything"}' \
  | PATH="$SCRATCH_SEG2:$PATH" CLAUDE_PROJECT_DIR="$FRAME_DIR" bash "$SCRIPT_DIR/scripts/pre-prompt-hook.sh" 2> /dev/null > "$FRAME_OUT"
if [ -s "$FRAME_OUT" ] && [ "$(tail -c 1 "$FRAME_OUT" | od -An -c | tr -d ' \n')" = '}' ]; then
  PASS=$((PASS + 1))
  echo "  PASS: pre-prompt-hook.sh: crash envelope ends in '}' with nothing after it"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: pre-prompt-hook.sh: crash envelope should end in '}' with nothing after it"
  echo "    got: $(od -c < "$FRAME_OUT" 2> /dev/null | tail -3)"
fi

printf '{"tool_name":"Read","tool_input":{"file_path":"nowhere397.md"}}' \
  | PATH="$SCRATCH_SEG2:$PATH" CLAUDE_PROJECT_DIR="$FRAME_DIR" bash "$SCRIPT_DIR/scripts/pre-path-hook.sh" 2> /dev/null > "$FRAME_OUT"
if [ -s "$FRAME_OUT" ] && [ "$(tail -c 1 "$FRAME_OUT" | od -An -c | tr -d ' \n')" = '}' ]; then
  PASS=$((PASS + 1))
  echo "  PASS: pre-path-hook.sh: crash envelope ends in '}' with nothing after it"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: pre-path-hook.sh: crash envelope should end in '}' with nothing after it"
  echo "    got: $(od -c < "$FRAME_OUT" 2> /dev/null | tail -3)"
fi

rm -rf "$SCRATCH_SEG2"
rm -f "$FRAME_OUT"
rm -rf "$FRAME_DIR"

echo "=== pre-tool-hook.sh: decisive awk crash on the refusal path (#397) ==="

TOOL_HOOK="$SCRIPT_DIR/scripts/pre-tool-hook.sh"

NORMAL_OUT=$(printf '{"session_id":"s397a","transcript_path":"/tmp/s397a.jsonl","tool_name":"Bash","tool_input":{"command":"rmrfxyz397 now"}}\n' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2> /dev/null)
assert_has "control: a healthy awk still blocks the matching call" "$NORMAL_OUT" '"decision":"block"'
assert_has "control: and carries the rule's own reason" "$NORMAL_OUT" "deny body 397"

CRASH_OUT=$(printf '{"session_id":"s397b","transcript_path":"/tmp/s397b.jsonl","tool_name":"Bash","tool_input":{"command":"rmrfxyz397 now"}}\n' \
  | PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2> /dev/null)
assert_has "a crashed awk fails CLOSED, not open" "$CRASH_OUT" '"decision":"block"'
assert_has "and names the crash rather than staying quiet" "$CRASH_OUT" "could not evaluate"
assert_has "and cites the issue this refusal comes from" "$CRASH_OUT" "#397"
assert_lacks "the crash reason is not the rule's own body -- no rule ran" "$CRASH_OUT" "deny body 397"
assert_single_valid_json "the crash reply is exactly one valid JSON object" "$CRASH_OUT"

echo "=== pre-prompt-hook.sh: decisive awk crash has no decision field to fail closed with (#397) ==="

PROMPT_HOOK="$SCRIPT_DIR/scripts/pre-prompt-hook.sh"

NORMAL_OUT=$(printf '{"session_id":"s397c","transcript_path":"/tmp/s397c.jsonl","prompt":"hello397 there"}\n' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" 2> /dev/null)
assert_has "control: a healthy awk still injects the matching vocabulary entry" "$NORMAL_OUT" "hello vocab 397"

CRASH_OUT=$(printf '{"session_id":"s397d","transcript_path":"/tmp/s397d.jsonl","prompt":"hello397 there"}\n' \
  | PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" 2> /dev/null)
assert_has "a crashed awk speaks over systemMessage instead of staying quiet" "$CRASH_OUT" '"systemMessage"'
assert_lacks "and never invents a decision field this hook has never had" "$CRASH_OUT" '"decision"'
assert_lacks "no vocabulary body reaches the reply -- no rule ran" "$CRASH_OUT" "hello vocab 397"
assert_single_valid_json "the crash reply is exactly one valid JSON object" "$CRASH_OUT"

echo "=== pre-path-hook.sh: decisive awk crash, plus the two-pass double-print race (#397 self-review) ==="

PATH_HOOK="$SCRIPT_DIR/scripts/pre-path-hook.sh"

NORMAL_OUT=$(printf '{"session_id":"s397e","transcript_path":"/tmp/s397e.jsonl","tool_name":"Read","tool_input":{"file_path":"deny397.md"}}\n' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2> /dev/null)
assert_has "control: a healthy awk still exits clean on an unmatched path" "$NORMAL_OUT" '{}'

CRASH_OUT=$(printf '{"session_id":"s397f","transcript_path":"/tmp/s397f.jsonl","tool_name":"Bash","tool_input":{"command":"grep -r x scripts/"}}\n' \
  | PATH="$SHIM_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2> /dev/null)
assert_has "a crashed awk speaks over systemMessage instead of staying quiet" "$CRASH_OUT" '"systemMessage"'
assert_lacks "and never invents a decision field this hook has never had" "$CRASH_OUT" '"decision"'
assert_single_valid_json "the crash reply is exactly one valid JSON object" "$CRASH_OUT"

# The race: the shimmed awk here writes a real candidates sentinel to $JIT_TMP before
# crashing, simulating a SIGSEGV landing after `close(log_tmp); exit` has already
# flushed it to disk. Left unfixed, pre-path-hook.sh's own downstream `[ -s "$JIT_TMP" ]`
# check would trust that leftover sentinel and run a SECOND awk pass, printing a second
# JSON object after this crash message -- two objects on one hook's stdout.
RACE_OUT=$(printf '{"session_id":"s397g","transcript_path":"/tmp/s397g.jsonl","tool_name":"Bash","tool_input":{"command":"grep -r x scripts/"}}\n' \
  | PATH="$SHIM_DIR2:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PATH_HOOK" 2> /dev/null)
assert_has "the race: still speaks over systemMessage" "$RACE_OUT" '"systemMessage"'
assert_single_valid_json "the race: exactly ONE json object, not two (self-review finding)" "$RACE_OUT"

echo "=== rc vs. crash: awk's own ordinary error exit is not #393's signal death (#400) ==="
# #400 (CI, macOS leg): an unopenable marker path is a FATAL i/o error on one-true-awk,
# but jit_shown_load()'s own comment in common.sh explains why that is benign -- the
# failing read never calls close(), so the diagnostic and the non-zero exit are deferred
# to interpreter shutdown, AFTER the real envelope in END{} has already been printed and
# flushed. Measured directly against this exact shape (test-marker-degradation.sh
# section B/D's own fixture): a directory at the session's marker path makes awk exit 2
# on this platform, with a complete, correct envelope already sitting in stdout. That is
# NOT #393's signal death (139, SIGSEGV) -- treating every non-zero exit as "nothing was
# evaluated" discarded a genuine, already-decided "decision":"block" and replaced it with
# a false crash message. These two shims drive both directions of that distinction
# directly, without needing a real unopenable marker: an ordinary (non-signal) exit code
# is not enough on its own to decide "could not evaluate" -- whether anything was
# actually captured is the second, decisive question.
GOODEXIT_DIR=$(mktemp -d)
cat > "$GOODEXIT_DIR/awk" << 'SHIMEOF'
#!/bin/sh
printf '{"decision":"block","reason":"the real, already-decided reason"}'
exit 2
SHIMEOF
chmod +x "$GOODEXIT_DIR/awk"

EMPTYEXIT_DIR=$(mktemp -d)
cat > "$EMPTYEXIT_DIR/awk" << 'SHIMEOF'
#!/bin/sh
exit 2
SHIMEOF
chmod +x "$EMPTYEXIT_DIR/awk"

# pre-tool-hook.sh: an ordinary exit that already wrote a good envelope is TRUSTED and
# used verbatim -- never replaced with a crash message.
GOOD_OUT=$(printf '{"session_id":"s397h","transcript_path":"/tmp/s397h.jsonl","tool_name":"Bash","tool_input":{"command":"rmrfxyz397 now"}}\n' \
  | PATH="$GOODEXIT_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2> /dev/null)
assert_has "pre-tool-hook.sh: an ordinary exit with a good envelope is trusted, not discarded" \
  "$GOOD_OUT" '"decision":"block"'
assert_has "pre-tool-hook.sh: and the REAL reason survives, not a crash placeholder" \
  "$GOOD_OUT" "the real, already-decided reason"
assert_lacks "pre-tool-hook.sh: and never claims awk could not evaluate this call" \
  "$GOOD_OUT" "could not evaluate"

# pre-tool-hook.sh: an ordinary exit with NOTHING captured is still genuinely ambiguous --
# this hook cannot verify, so it still fails CLOSED, same as #397's own crash path.
EMPTY_OUT=$(printf '{"session_id":"s397i","transcript_path":"/tmp/s397i.jsonl","tool_name":"Bash","tool_input":{"command":"rmrfxyz397 now"}}\n' \
  | PATH="$EMPTYEXIT_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TOOL_HOOK" 2> /dev/null)
assert_has "pre-tool-hook.sh: an ordinary exit with nothing captured still fails CLOSED" \
  "$EMPTY_OUT" '"decision":"block"'
assert_has "pre-tool-hook.sh: and still names the evaluator failure" \
  "$EMPTY_OUT" "could not evaluate"

# pre-prompt-hook.sh: an ordinary exit that already wrote a good envelope is trusted.
GOODEXIT_DIR2=$(mktemp -d)
cat > "$GOODEXIT_DIR2/awk" << 'SHIMEOF'
#!/bin/sh
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"the real vocabulary body"}}'
exit 1
SHIMEOF
chmod +x "$GOODEXIT_DIR2/awk"

GOOD_PROMPT_OUT=$(printf '{"session_id":"s397j","transcript_path":"/tmp/s397j.jsonl","prompt":"hello397 there"}\n' \
  | PATH="$GOODEXIT_DIR2:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" 2> /dev/null)
assert_has "pre-prompt-hook.sh: an ordinary exit with a good envelope is trusted" \
  "$GOOD_PROMPT_OUT" "the real vocabulary body"
assert_lacks "pre-prompt-hook.sh: and never claims awk could not evaluate this turn" \
  "$GOOD_PROMPT_OUT" "could not evaluate"

# pre-prompt-hook.sh: an ordinary exit with NOTHING captured keeps going quietly (#50's
# own established direction for the injection hooks) rather than raising a new alarm --
# the same "{}" a genuine no-match produces, not a systemMessage.
EMPTY_PROMPT_OUT=$(printf '{"session_id":"s397k","transcript_path":"/tmp/s397k.jsonl","prompt":"hello397 there"}\n' \
  | PATH="$EMPTYEXIT_DIR:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROMPT_HOOK" 2> /dev/null)
assert_has "pre-prompt-hook.sh: an ordinary exit with nothing captured degrades to {}" \
  "$EMPTY_PROMPT_OUT" '{}'
assert_lacks "pre-prompt-hook.sh: and does not raise a new alarm for an ordinary hiccup" \
  "$EMPTY_PROMPT_OUT" "systemMessage"

rm -rf "$GOODEXIT_DIR" "$EMPTYEXIT_DIR" "$GOODEXIT_DIR2"
rm -rf "$SHIM_DIR" "$SHIM_DIR2" "$TEST_DIR"

echo
echo "========================"
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
echo "========================"
[ "$FAIL" -eq 0 ] || exit 1
