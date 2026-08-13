#!/bin/bash
# Bytes an entry can carry that the JSON channel cannot (#77, #78).
#
# #77  A non-UTF-8 byte in an entry BODY travelled into additionalContext/reason.
#      jit_json_escape() escapes 0x00-0x1F, quote and backslash and nothing above 0x7F,
#      so stdout was not valid UTF-8 JSON: exit 0, stderr empty, and the OTHER entries
#      injected in the same call went down with it. An index row is the same channel one
#      column over -- it reaches the output through the (matched: <pattern>) header.
#
# #78  A NUL in an index row file column truncates the dedup key. one-true-awk truncates
#      the record at the NUL; gawk carries it into the mark channel and bash read -r
#      truncates there instead. Same wrong key, two mechanisms, both silent -- the row was
#      neither honoured nor refused, and a marker was written for a key never injected.
#
# Every negative assertion here is paired with a positive one in the SAME fixture, and
# every case asserts that something was injected at all: "no bad byte on stdout" is
# trivially true of a hook that said nothing, which is the defect class this repository
# keeps finding in its own product.
#
# Nothing is asserted through a $( ) capture of hook output. bash silently drops NUL
# bytes out of a command substitution, so an assertion about the byte at the centre of
# #78 cannot fail when it is read out of a shell variable. Every check reads a FILE.
#
# Usage: bash tests/test-entry-bytes.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Every non-printable byte rendered, so a failure line is readable and cannot itself be
# truncated at a NUL.
seen() { LC_ALL=C perl -0777 -pe 's/([^\x20-\x7e])/sprintf("<%02X>",ord($1))/ge; $_ = substr($_, 0, 240)' "$1"; }

# --- Assertions, every one of them over a file on disk ------------------------
assert_injected() {
  if LC_ALL=C perl -0777 -ne 'exit(/additionalContext|"reason"/ ? 0 : 1)' "$2"; then
    ok "$1"
  else
    bad "$1 -- nothing was injected, so every other check on this call is vacuous"
    echo "    got: $(seen "$2")"
  fi
}

assert_utf8() {
  if LC_ALL=C perl -0777 -ne 'exit(utf8::decode($_) ? 0 : 1)' "$2"; then
    ok "$1"
  else
    bad "$1 -- stdout is not valid UTF-8, so a strict JSON reader rejects the whole object"
    echo "    got: $(seen "$2")"
  fi
}

assert_has() {
  if LC_ALL=C grep -qF -- "$3" "$2"; then ok "$1"; else
    bad "$1"
    echo "    expected to contain: $3"
    echo "    got: $(seen "$2")"
  fi
}

assert_lacks() {
  if LC_ALL=C grep -qF -- "$3" "$2"; then
    bad "$1"
    echo "    should NOT contain: $3"
  else ok "$1"; fi
}

# The raw 0xE9 of a Latin-1 save, read off the file and never off a variable.
assert_no_bad_byte() {
  if LC_ALL=C perl -0777 -ne 'exit(/\xe9/ ? 1 : 0)' "$2"; then ok "$1"; else
    bad "$1 -- the raw 0xE9 reached stdout"
  fi
}

# A marker line is a whole key, so the check is grep -x on the FILE: the value under test
# in #78 is a TRUNCATED key, and a truncation is only visible against the whole line.
assert_marker_has() {
  if [ -f "$2" ] && LC_ALL=C grep -qxF -- "$3" "$2"; then ok "$1"; else
    bad "$1"
    echo "    expected a marker line: $3"
    [ -f "$2" ] && echo "    marker file: $(seen "$2")" || echo "    no marker file at all: $2"
  fi
}

assert_marker_lacks() {
  if [ -f "$2" ] && LC_ALL=C grep -qxF -- "$3" "$2"; then
    bad "$1"
    echo "    marker file holds a key nothing was injected for: $3"
    echo "    marker file: $(seen "$2")"
  else ok "$1"; fi
}
# --- A fresh project tree per case --------------------------------------------
new_proj() {
  local p b d l
  p=$(mktemp -d)
  b="$p/.claude/jit-context"
  for d in tools paths vocabulary; do
    for l in 00-manual 10-auto 20-grouped 30-crosscutting; do
      mkdir -p "$b/$d/$l"
      : > "$b/$d/$l/00-index.tsv"
      : > "$b/$d/$l/01-paths.tsv"
    done
  done
  echo "$p"
}

# --- Every awk on this machine ------------------------------------------------
# #78 is two different mechanisms on two engines that agree on the wrong result, and #77
# reproduces on both. A single-engine run is not evidence about the other CI legs.
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
  echo "SKIPPED: no awk on PATH, so nothing here could be evaluated."
  exit 2
fi

OUT=$(mktemp)
run_hook() {   # engine hook-script project payload
  printf %s "$4" | PATH="$ENGINE_BIN/$1:$PATH" CLAUDE_PROJECT_DIR="$3" bash "$SCRIPTS/$2" > "$OUT" 2>/dev/null
}

BLOCK_DECISION='"decision":"block"'

for ENG in $ENGINES; do
echo ""
echo "##### awk engine: $ENG #####"

# ============================================================================
# 77a - one bad body must not take its neighbours down with it
# ============================================================================
echo ""
echo "=== 77a [$ENG]: a non-UTF-8 entry body is refused, its neighbours still arrive ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; T="$BASE/tools/00-manual"
printf 'entry body ALPHA\n' > "$T/a77a.md"
printf 'entry body BETA saved as Latin-1: \351 end\n' > "$T/b77a.md"
printf 'entry body GAMMA\n' > "$T/c77a.md"
{ printf 'Bash\tdpt77a\ta77a.md\tremind\t\t\n'
  printf 'Bash\tdpt77a\tb77a.md\tremind\t\t\n'
  printf 'Bash\tdpt77a\tc77a.md\tremind\t\t\n'; } > "$T/00-index.tsv"
run_hook "$ENG" pre-tool-hook.sh "$PROJ" '{"tool_name":"Bash","tool_input":{"command":"echo dpt77a"}}'
assert_injected "something was injected at all" "$OUT"
assert_utf8     "stdout is valid UTF-8 JSON" "$OUT"
assert_has      "the clean entry before it still arrives" "$OUT" "entry body ALPHA"
assert_has      "the clean entry after it still arrives" "$OUT" "entry body GAMMA"
assert_has      "the refused row is named by position" "$OUT" "tools/00-manual row 2"
assert_has      "and the reason says what was wrong" "$OUT" "not valid UTF-8"
assert_lacks    "the refused body is not injected" "$OUT" "entry body BETA"
assert_no_bad_byte "no raw 0xE9 on stdout" "$OUT"
rm -rf "$PROJ"

# ============================================================================
# 77b - a block decision was reached; it has to stay READABLE
# ============================================================================
echo ""
echo "=== 77b [$ENG]: a block rule with an unreadable body still blocks, in valid JSON ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; T="$BASE/tools/00-manual"
printf 'entry body BETA saved as Latin-1: \351 end\n' > "$T/b77b.md"
printf 'Bash\tdpt77b\tb77b.md\tblock\t\t\n' > "$T/00-index.tsv"
run_hook "$ENG" pre-tool-hook.sh "$PROJ" '{"tool_name":"Bash","tool_input":{"command":"echo dpt77b"}}'
assert_injected "something was injected at all" "$OUT"
assert_has      "the call is still blocked" "$OUT" "$BLOCK_DECISION"
assert_utf8     "the block reason is valid UTF-8 JSON" "$OUT"
assert_has      "the reason says the rule text could not be delivered" "$OUT" "not valid UTF-8"
assert_lacks    "the unreadable body text is not in the reason" "$OUT" "entry body BETA"
assert_no_bad_byte "no raw 0xE9 on stdout" "$OUT"
rm -rf "$PROJ"

# ============================================================================
# 77bb - the OTHER half of a block rule: bad bytes in the row, not in the body
# ============================================================================
# The two halves get opposite verdicts on purpose. A bad body leaves the decision intact
# -- mode, require and forbid all come from the row -- so the rule still blocks. Bad bytes
# in the ROW are the decision inputs themselves, so there is nothing to preserve and the
# row is refused like an unhonourable pattern. What must not happen is the refusal going
# out unlabelled: "a rule could not be evaluated" and "a block rule went dark" are
# different sentences to whoever reads the notice.
echo ""
echo "=== 77bb [$ENG]: bad bytes in a block rule row refuse it, and say it was a block rule ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; T="$BASE/tools/00-manual"
printf 'never delete the private key\n' > "$T/k77bb.md"
printf 'entry body OMICRON\n' > "$T/c77bb.md"
{ printf 'Bash\tdpt77bb\tk77bb.md\tblock\t\tcl\351-privee\n'
  printf 'Bash\tdpt77bb\tc77bb.md\tremind\t\t\n'; } > "$T/00-index.tsv"
run_hook "$ENG" pre-tool-hook.sh "$PROJ" '{"tool_name":"Bash","tool_input":{"command":"rm -rf dpt77bb/cle-privee"}}'
assert_injected "something was injected at all" "$OUT"
assert_utf8     "stdout is valid UTF-8 JSON" "$OUT"
assert_has      "the refused row is named by position" "$OUT" "tools/00-manual row 1"
assert_has      "and the notice says a BLOCK rule is the one that went dark" "$OUT" "row 1 (a block rule)"
assert_has      "the honest rule beside it still fires" "$OUT" "entry body OMICRON"
assert_no_bad_byte "no raw 0xE9 on stdout" "$OUT"
rm -rf "$PROJ"

# ============================================================================
# 77c - the other direction: VALID multibyte UTF-8 is delivered untouched
# ============================================================================
echo ""
echo "=== 77c [$ENG]: a valid UTF-8 body is injected verbatim, not refused ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; T="$BASE/tools/00-manual"
printf 'entry body avec un caf\303\251 et 20\342\202\254 et \360\237\232\200\n' > "$T/u77c.md"
printf 'Bash\tdpt77c\tu77c.md\tremind\t\t\n' > "$T/00-index.tsv"
run_hook "$ENG" pre-tool-hook.sh "$PROJ" '{"tool_name":"Bash","tool_input":{"command":"echo dpt77c"}}'
assert_injected "something was injected at all" "$OUT"
assert_utf8     "stdout is valid UTF-8 JSON" "$OUT"
assert_has      "the two-byte code point arrives" "$OUT" "$(printf 'un caf\303\251 et')"
assert_has      "the three-byte code point arrives" "$OUT" "$(printf '20\342\202\254')"
assert_has      "the four-byte code point arrives" "$OUT" "$(printf '\360\237\232\200')"
assert_lacks    "a valid UTF-8 entry is NOT refused" "$OUT" "could not be evaluated"
rm -rf "$PROJ"

# ============================================================================
# 77d - an index row is a channel too: it reaches the (matched: ...) header
# ============================================================================
echo ""
echo "=== 77d [$ENG]: a non-UTF-8 byte in an index row refuses that row only ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; P="$BASE/paths/00-manual"
printf 'entry body EPSILON\n' > "$P/e77d.md"
printf 'entry body ZETA\n' > "$P/z77d.md"
{ printf 'dpt77d|\351\te77d.md\n'
  printf 'dpt77d\tz77d.md\n'; } > "$P/00-index.tsv"
run_hook "$ENG" pre-path-hook.sh "$PROJ" '{"tool_name":"Read","tool_input":{"file_path":"/x/dpt77d/a.php"}}'
assert_injected "something was injected at all" "$OUT"
assert_utf8     "stdout is valid UTF-8 JSON" "$OUT"
assert_has      "the refused row is named by position" "$OUT" "paths/00-manual row 1"
assert_lacks    "the row with the unusable pattern did not fire" "$OUT" "entry body EPSILON"
assert_has      "the clean row in the same index still fires" "$OUT" "entry body ZETA"
assert_no_bad_byte "no raw 0xE9 on stdout" "$OUT"
rm -rf "$PROJ"

# ============================================================================
# 77e - the vocabulary body site, through the prompt hook
# ============================================================================
echo ""
echo "=== 77e [$ENG]: a non-UTF-8 vocabulary body is refused, the clean one arrives ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; V="$BASE/vocabulary/00-manual"
printf 'entry body BETA saved as Latin-1: \351 end\n' > "$V/b77e.md"
printf 'vocab body THETA\n' > "$V/g77e.md"
{ printf 'dptbadkw\tb77e.md\n'
  printf 'dptokkw\tg77e.md\n'; } > "$V/00-index.tsv"
run_hook "$ENG" pre-prompt-hook.sh "$PROJ" '{"prompt":"dptbadkw and dptokkw"}'
assert_injected "something was injected at all" "$OUT"
assert_utf8     "stdout is valid UTF-8 JSON" "$OUT"
assert_has      "the clean vocabulary entry arrives" "$OUT" "vocab body THETA"
assert_has      "the refused row is named by position" "$OUT" "vocabulary/00-manual row 1"
assert_lacks    "the refused body is not injected" "$OUT" "entry body BETA"
assert_no_bad_byte "no raw 0xE9 on stdout" "$OUT"
rm -rf "$PROJ"

# ============================================================================
# 78a - a NUL in the file column marks a key nothing was injected for
# ============================================================================
echo ""
echo "=== 78a [$ENG]: a NUL-bearing index row is refused, and marks nothing ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; V="$BASE/vocabulary/00-manual"
printf 'vocab body IOTA\n' > "$V/detail.md"
printf 'vocab body KAPPA\n' > "$V/okfile.md"
{ printf 'nulk\tdet'; printf '\000'; printf 'ail.md\n'
  printf 'okk\tokfile.md\n'; } > "$V/00-index.tsv"
SID="b78a$ENG"
run_hook "$ENG" pre-prompt-hook.sh "$PROJ" '{"session_id":"'"$SID"'","prompt":"nulk and okk"}'
MARK="$BASE/.discovery/state/vocab-shown-$SID.txt"
assert_injected     "something was injected at all" "$OUT"
assert_utf8         "stdout is valid UTF-8 JSON" "$OUT"
assert_has          "the clean row still fires" "$OUT" "vocab body KAPPA"
assert_marker_has   "the entry that WAS injected is marked shown" "$MARK" "okfile.md"
assert_marker_lacks "the truncated key is not marked shown" "$MARK" "det"
assert_marker_lacks "and neither is the name it was cut from" "$MARK" "detail.md"
assert_has          "the row is named by position rather than dropped" "$OUT" "vocabulary/00-manual row 1"
rm -rf "$PROJ"

# ============================================================================
# 78b - a row naming a file that is not there is named, not silently dropped
# ============================================================================
# This is what one-true-awk sees in 78a once it has truncated the record at the NUL, and
# it is also a plain stale index. Deterministic on every engine.
echo ""
echo "=== 78b [$ENG]: a row whose entry file cannot be read is refused by position ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; P="$BASE/paths/00-manual"
printf 'entry body LAMBDA\n' > "$P/l78b.md"
{ printf 'dpt78b\tgone78b.md\n'
  printf 'dpt78b\tl78b.md\n'; } > "$P/00-index.tsv"
run_hook "$ENG" pre-path-hook.sh "$PROJ" '{"tool_name":"Read","tool_input":{"file_path":"/x/dpt78b/a.php"}}'
assert_injected "something was injected at all" "$OUT"
assert_has      "the missing entry file is named by position" "$OUT" "paths/00-manual row 1"
assert_has      "with a reason that says what happened" "$OUT" "could not be read"
assert_has      "the row beside it still fires" "$OUT" "entry body LAMBDA"
rm -rf "$PROJ"

# ============================================================================
# 77f - the loud half: rebuild-tsv.sh names a row the hooks will refuse
# ============================================================================
# A `forbid:` value saved in ISO-8859-1 indexes cleanly and then takes the whole row down
# at load, so a block rule goes dark and the only notice arrives at runtime naming a row
# number. rebuild-tsv.sh is the half that may fail loudly and knows the file name.
echo ""
echo "=== 77f [$ENG]: rebuild-tsv names the entry whose row the hooks will refuse ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; T="$BASE/tools/00-manual"
printf -- '---\ntool: Bash\nmatch: dpt77f\nmode: block\nforbid: "cl\351-privee"\n---\nnever\n' > "$T/bad77f.md"
printf -- '---\ntool: Bash\nmatch: dpt77fok\nmode: remind\n---\nfine\n' > "$T/ok77f.md"
ERR=$(mktemp)
PATH="$ENGINE_BIN/$ENG:$PATH" CLAUDE_PROJECT_DIR="$PROJ" LC_ALL=C \
  bash "$SCRIPTS/rebuild-tsv.sh" >/dev/null 2>"$ERR"
assert_has   "the offending row is reported on stderr" "$ERR" "the hooks will refuse this row"
assert_has   "named by the entry file, which is what an author can act on" "$ERR" "bad77f.md"
# Against the REFUSAL half of stderr, not all of it. rebuild-tsv also prints the
# injection budget (#1/#54), which names the largest, the median and every entry with no
# description: -- so on a two-entry tree the honest one is named there, correctly and for
# an unrelated reason. Asserting over the whole stream would read that as the refusal
# report having widened, which is the opposite of what it says.
ERR_REFUSE=$(mktemp)
awk '/^=== What a match costs/ { exit } { print }' "$ERR" > "$ERR_REFUSE"
assert_lacks "the honest entry beside it is not reported" "$ERR_REFUSE" "ok77f.md"
# Positive control for the cut: the budget section is what was removed, and if that header
# ever changes this says so instead of quietly asserting against an empty file.
assert_has   "the cut kept the refusal report itself" "$ERR_REFUSE" "the hooks will refuse this row"
rm -f "$ERR_REFUSE"
# The positive control for the whole check: the same tree with the bad value removed says
# nothing at all. Without it, every assertion above would pass against a script that
# reported every row it wrote.
printf -- '---\ntool: Bash\nmatch: dpt77f\nmode: block\nforbid: "cle-privee"\n---\nnever\n' > "$T/bad77f.md"
PATH="$ENGINE_BIN/$ENG:$PATH" CLAUDE_PROJECT_DIR="$PROJ" LC_ALL=C \
  bash "$SCRIPTS/rebuild-tsv.sh" >/dev/null 2>"$ERR"
assert_lacks "a clean tree is reported clean" "$ERR" "the hooks will refuse this row"
assert_has   "and the run still happened" "$ERR" "Ambiguous vocabulary keywords"
rm -f "$ERR"
rm -rf "$PROJ"

done

rm -f "$OUT"
rm -rf "$ENGINE_BIN"

echo ""
echo "Engines driven:$ENGINES"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
