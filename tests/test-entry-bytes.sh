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
# jit-drive: assert_has contains path-arg
# jit-drive: assert_lacks not_contains path-arg
# jit-drive: assert_marker_has contains path-arg
# jit-drive: assert_marker_lacks not_contains path-arg
assert_injected() {
  if LC_ALL=C perl -0777 -ne 'exit(/additionalContext|"reason"/ ? 0 : 1)' "$2"; then
    ok "$1"
  else
    bad "$1 -- nothing was injected, so every other check on this call is vacuous"
    echo "    got: $(seen "$2")"
  fi
}

# An EMPTY file decodes as valid UTF-8, so emptiness is refused first and by name. That is
# not hypothetical: #164's first CI run had a driver produce nothing at all under mawk, and
# this assertion passed on it while the byte-exact one beside it failed -- a control that
# certifies silence is the defect class this suite exists to refuse.
assert_utf8() {
  if [ ! -s "$2" ]; then
    bad "$1 -- the file is EMPTY, which decodes as valid UTF-8 and proves nothing"
  elif LC_ALL=C perl -0777 -ne 'exit(utf8::decode($_) ? 0 : 1)' "$2"; then
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

# Byte-exact, because the value under test in #164 differs from the correct one by ONE
# byte in the middle of a string that greps as ordinary text either way.
assert_bytes() {   # label expected-string
  printf %s "$2" > "$EXP"
  if cmp -s "$EXP" "$OUT"; then ok "$1"; else
    bad "$1"
    echo "    expected: $(seen "$EXP")"
    echo "    got:      $(seen "$OUT")"
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
EXP=$(mktemp)
CLIPERR=$(mktemp)

# A driver that failed to start writes nothing to stdout and everything to stderr, and
# every assertion downstream then reads an empty file. This is the assertion that names it.
assert_silent() {   # label file
  if [ ! -s "$2" ]; then ok "$1"; else
    bad "$1"
    echo "    the awk program wrote to stderr, so nothing below it was measured:"
    echo "    $(seen "$2")"
  fi
}
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

# ============================================================================
# 156 - jit_clip() rewrote values nobody asked it to rewrite
# ============================================================================
# The comment block above jit_clip() promises "No other rewriting" and cites #19 as what
# happens when this reader edits a value it does not understand. It then trimmed a trailing
# CR and trailing whitespace off EVERY value, including ones far below the cap -- and it
# did so BEFORE the cut, so it never once tidied the string it had just truncated.
#
# Only a QUOTED frontmatter value can carry trailing whitespace this far: jit_entry_load()
# strips it off the raw line, and a wrapping quote pair is the one way an author says keep
# it. So the trim deleted exactly what somebody had asked to keep, and left ragged
# whitespace in front of " [clipped]" -- the one place a trim would have been right.
echo ""
echo "=== 156a [$ENG]: a quoted trailing space below the cap survives; an unquoted one does not ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; V="$BASE/vocabulary/00-manual"
printf -- '---\ntitle: T156a\ndescription: "ALPHA end   "\ninject: summary\n---\nbody\n' > "$V/q156a.md"
printf -- '---\ntitle: T156b\ndescription: BETA end   \ninject: summary\n---\nbody\n' > "$V/u156a.md"
printf -- '---\ntitle: "GAMMA tail   "\ndescription: g156a\ninject: summary\n---\nbody\n' > "$V/t156a.md"
{ printf 'kwq156a\tq156a.md\n'
  printf 'kwu156a\tu156a.md\n'
  printf 'kwt156a\tt156a.md\n'; } > "$V/00-index.tsv"
run_hook "$ENG" pre-prompt-hook.sh "$PROJ" '{"prompt":"kwq156a and kwu156a and kwt156a"}'
assert_injected "something was injected at all" "$OUT"
assert_has   "the quoted description keeps the spaces the author quoted" "$OUT" 'ALPHA end   \n[jit]'
assert_has   "the quoted title keeps them too" "$OUT" 'GAMMA tail   \ng156a'
# The other direction, in the same fixture. An UNQUOTED value is trimmed by the frontmatter
# reader long before jit_clip() sees it and must stay trimmed: without this pair, 156a
# would pass just as well against a hook that had stopped reading frontmatter at all.
assert_has   "an unquoted description still arrives trimmed" "$OUT" 'BETA end\n[jit]'
assert_lacks "and grows no whitespace of its own" "$OUT" 'BETA end   '
rm -rf "$PROJ"

# ============================================================================
# 156b - the trim the cap actually needed, at the only place it applies
# ============================================================================
echo ""
echo "=== 156b [$ENG]: an over-cap value is cut, and the cut is tidied before the marker ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; V="$BASE/vocabulary/00-manual"
# 398 a, four spaces, then ZTAIL: 407 characters, so it is over the 400 cap, and the cut at
# 400 lands two characters into the whitespace.
LONG156=$(perl -e 'print "a" x 398, "    ", "ZTAIL"')
printf -- '---\ntitle: T156c\ndescription: %s\ninject: summary\n---\nbody\n' "$LONG156" > "$V/c156b.md"
printf 'kwc156b\tc156b.md\n' > "$V/00-index.tsv"
run_hook "$ENG" pre-prompt-hook.sh "$PROJ" '{"prompt":"kwc156b"}'
assert_injected "something was injected at all" "$OUT"
assert_has   "the over-cap description is marked as cut at all" "$OUT" "[clipped]"
assert_has   "and the marker follows the last character that survived" "$OUT" "a [clipped]"
assert_lacks "rather than the whitespace the cut landed in" "$OUT" "  [clipped]"
assert_lacks "the text past the cut is gone" "$OUT" "ZTAIL"
rm -rf "$PROJ"

# ============================================================================
# 156c - the CR that trim was quietly also eating reaches the JSON channel now
# ============================================================================
# The removed sub(/\r$/) was not a safety guard and this suite is the place to prove it:
# jit_json_escape() emits 0x0D as \r, so a value ending in one is escaped rather than
# breaking the string it sits in. A raw CR on stdout would be invalid JSON, which is #77
# one byte over. Only a quoted value can carry a CR this far -- jit_entry_load() strips a
# trailing one off the line itself.
echo ""
echo "=== 156c [$ENG]: a quoted value ending in CR is escaped, not deleted and not raw ==="
PROJ=$(new_proj); BASE="$PROJ/.claude/jit-context"; V="$BASE/vocabulary/00-manual"
printf -- '---\ntitle: T156d\ndescription: "CRVAL\r"\ninject: summary\n---\nbody\n' > "$V/r156c.md"
printf 'kwr156c\tr156c.md\n' > "$V/00-index.tsv"
run_hook "$ENG" pre-prompt-hook.sh "$PROJ" '{"prompt":"kwr156c"}'
assert_injected "something was injected at all" "$OUT"
assert_utf8  "stdout is valid UTF-8 JSON" "$OUT"
assert_has   "the CR arrives, as the escape JSON has for it" "$OUT" 'CRVAL\r\n[jit]'
assert_lacks "and never as the raw byte, which would break the string" "$OUT" "$(printf 'CRVAL\r')"
rm -rf "$PROJ"

# ============================================================================
# 164 - the trim jit_clip() makes at the cut was a LOCALE-sensitive byte class
# ============================================================================
# #157 moved the two sub() calls to run after the cut and after the multibyte repair, which
# was the right fix for #156. It also put a POSIX character class downstream of raw UTF-8
# bytes. In a single-byte locale [[:space:]] matches 0xA0 -- the trailing byte of a-grave
# (C3 A0), S-caron (C5 A0) and the dagger (E2 80 A0). The repair strips at most three
# continuation bytes plus one lead byte, so a cut landing after two adjacent such
# characters leaves the string ending on a VALID, COMPLETE character whose last byte is
# 0xA0, and the trim then ate that byte and left a lone lead byte behind: invalid UTF-8 in
# the JSON channel, which is the #14/#15 shape the comment block above jit_clip() spends a
# paragraph on.
#
# No consumer can reach it -- pre-tool-hook.sh, pre-prompt-hook.sh, pre-path-hook.sh and
# rebuild-tsv.sh all pin LC_ALL=C -- so a hook-level drive CANNOT go red here, whatever
# locale it is given. The property is claimed by the function, so the function is what is
# driven: jit_clip() out of the awk program the hooks compose, with no hook in the path.
# The program is BEGIN-only, so awk never processes an operand and ARGV[1] is read as the
# string it is: a fixture value containing an = is data here, not a variable assignment.
#
# The FOUR fragments are concatenated, exactly as pre-path-hook.sh:67 composes them, and
# $JIT_AWK_INJECT alone would be wrong. It is a fragment: jit_entry_load() in it calls
# jit_bad_utf8() and jit_entry_why(), which live in $JIT_AWK_ENTRY. one-true-awk and gawk
# only notice an undefined function when one is CALLED, so a program that never reaches
# those call sites runs anyway -- mawk refuses it at PARSE time and the whole program
# produces nothing. That is what reddened 13 assertions on the ubuntu-latest leg of #164's
# first CI run, where mawk is the default awk, and none of it was a statement about
# jit_clip(). stderr is kept rather than discarded for the same reason: it held the
# sentence that explained all 13, and it was going to /dev/null.
clip164() {   # locale value cap  -> bytes into $OUT, diagnostics into $CLIPERR
  : > "$CLIPERR"
  (
    export CLAUDE_PROJECT_DIR="$SCRIPT_DIR"   # read by common.sh, which is sourced next
    # shellcheck source=/dev/null
    . "$SCRIPTS/common.sh"
    PATH="$ENGINE_BIN/$ENG:$PATH" LC_ALL="$1" \
      awk "$JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_JSON"'BEGIN { printf "%s", jit_clip(ARGV[1], ARGV[2] + 0) }' "$2" "$3"
  ) > "$OUT" 2>"$CLIPERR"
}

# jit_clip() as source text, for the one check that has to hold where 164b cannot run.
src164() {
  (
    export CLAUDE_PROJECT_DIR="$SCRIPT_DIR"
    # shellcheck source=/dev/null
    . "$SCRIPTS/common.sh"
    # Comment lines are dropped: the block above the trim NAMES [[:space:]] in prose, and a
    # check that could not tell the prose from the regex would fail on the fixed code.
    printf %s "$JIT_AWK_INJECT" \
      | awk '/^function jit_clip\(/, /^}/' \
      | awk '$0 !~ /^[ \t]*#/'
  ) > "$OUT" 2>/dev/null
}

echo ""
echo "=== 164a [$ENG]: under C the trim is the six ASCII whitespace bytes, and only those ==="
# The positive control for the whole section, and the regression guard on the fix: an
# escape class written wrong degrades quietly: an awk that does not know an escape drops
# the backslash and matches the bare letter, so a bounded class naming one the engine lacks
# would start trimming a trailing "v" or "f" off values with nothing said anywhere. Both
# directions, same fixture shape, and this is the reason it runs per ENGINE rather than
# once. Nothing here reads a NUL, and no value ends in whitespace, so $( ) is safe.
#
# Before any of it, the control that was missing when this went red on CI: did the driver
# RUN? A value under the cap comes back unchanged and the awk program says nothing on
# stderr. Without this, an awk that refused to start reads as thirteen separate failures
# about whitespace.
clip164 C "under the cap" 99
assert_bytes  "the driver reaches jit_clip at all" "under the cap"
assert_silent "and the awk program loaded with no diagnostics" "$CLIPERR"
for B164 in '\011' '\012' '\013' '\014' '\015' '\040'; do
  clip164 C "$(printf 'aaaaaaaa%b%bZTAIL' "$B164" "$B164")" 10
  assert_bytes "the cut is tidied when it lands on byte $B164" "aaaaaaaa [clipped]"
done
for L164 in v f t n r b; do
  clip164 C "aaaaaaaa$L164${L164}ZTAIL" 10
  assert_bytes "and a trailing letter $L164 is not whitespace" "aaaaaaaa$L164$L164 [clipped]"
done
# 0xA0 is not whitespace under C either, and this is the byte the next case turns on.
clip164 C "$(printf 'aaaaaaaa\303\240\303\240yyy')" 12
assert_utf8  "the C reference run is valid UTF-8" "$OUT"
assert_bytes "and keeps the whole character the repair left standing" "$(printf 'aaaaaaaa\303\240 [clipped]')"

echo ""
echo "=== 164b [$ENG]: and it is the same six bytes in a single-byte locale ==="
# The locale is PROBED on the precondition itself rather than assumed from its name: does
# this engine, under this locale, call 0xA0 a [[:space:]]? A machine where no locale does
# cannot host this case at all, and that is a named skip, never a quiet pass.
LOC164=""
for C164 in fr_FR.ISO8859-1 en_US.ISO8859-1 en_GB.ISO8859-1 de_DE.ISO8859-1 \
            en_US.ISO8859-15 fr_FR.ISO-8859-1 en_US.iso88591; do
  if printf 'x\240\n' | PATH="$ENGINE_BIN/$ENG:$PATH" LC_ALL="$C164" \
       awk '{ exit(/[[:space:]]$/ ? 0 : 1) }' 2>/dev/null; then
    LOC164="$C164"; break
  fi
done
if [ -z "$LOC164" ]; then
  echo "  SKIPPED: no single-byte locale on this machine makes awk call 0xA0 a [[:space:]],"
  echo "           so the condition #164 turns on cannot be created here at all."
else
  echo "  locale: $LOC164"
  clip164 "$LOC164" "$(printf 'aaaaaaaa\303\240\303\240yyy')" 12
  assert_utf8  "the clipped value is still valid UTF-8" "$OUT"
  assert_bytes "and is byte-identical to the C run" "$(printf 'aaaaaaaa\303\240 [clipped]')"
  # Positive control: the same locale still trims an ASCII space at the cut, so 164b is
  # not passing because the trim stopped happening.
  clip164 "$LOC164" "$(printf 'aaaaaaaa  ZTAIL')" 10
  assert_bytes "the ASCII trim still happens under that locale" "aaaaaaaa [clipped]"
fi

echo ""
echo "=== 164c [$ENG]: and the guarantee is structural, so it holds where 164b cannot run ==="
# 164b is the only case that reproduces #164, and it needs a locale in which awk calls 0xA0
# a [[:space:]]. Neither the Linux nor the Windows CI leg ships one, so on two of the three
# legs it skips -- and a skip that reads as green is the failure shape this suite exists to
# refuse. So the property is ALSO asserted structurally, which every leg can evaluate: a
# POSIX character class in jit_clip() CODE -- prose naming one is dropped first -- is a
# byte class whose membership the caller picks, and the whole of #164 is that this function
# must not contain one. Structural
# rather than a compile probe for the same reason the pattern guard is: the answer differs
# per engine and per locale, and the source does not.
src164
assert_has   "the function text was extracted at all" "$OUT" "function jit_clip("
assert_has   "including the trim this is about" "$OUT" '+$/, "", s)'
assert_lacks "and it names no POSIX character class" "$OUT" "[[:"

done

rm -f "$OUT" "$EXP" "$CLIPERR"
rm -rf "$ENGINE_BIN"

echo ""
echo "Engines driven:$ENGINES"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
