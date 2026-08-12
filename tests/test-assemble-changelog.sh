#!/bin/bash
# Tests for .github/scripts/assemble_changelog.py — fold changelog.d/ fragments into
# CHANGELOG.md at a tag.
#
# The script is a release tool, not a hook. `paths/00-manual/tooling.md` governs it and
# `hooks.md` does not: it never runs in a stranger's session, so it fails LOUDLY, with
# 0 ok / 1 refused / 2 could-not-evaluate. That makes the refusals the interesting
# assertions here.
#
# Every refusal is paired with a positive control in the SAME fixture — a fragment that
# assembles cleanly beside the one being refused. "It refuses X" passes when the script
# is broken and refuses everything, so a refusal on its own tests nothing. The injection
# section leans on that hardest: its control is a fragment that QUOTES a release heading
# inside a fence, which the guard must accept while refusing the same characters live.
#
# And the count: fragments in must equal entries out. A cut that silently drops one is
# the failure this whole convention exists to make impossible, and it is invisible by eye
# in a 1,000-line file.
#
# Usage: bash tests/test-assemble-changelog.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASSEMBLE="$REPO/.github/scripts/assemble_changelog.py"
PASS=0
FAIL=0

# Git Bash on Windows ships `python`, not always `python3`. Neither present is an
# absence of coverage nobody caused, which is exit 2 and a SKIPPED block — not a pass.
PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
  echo "SKIPPED: no python3 or python on PATH"
  echo "  The changelog assembler and every assertion below went untested here."
  echo "  CI installs both this and markdown-it-py in .github/workflows/changelog.yml."
  exit 2
fi
if ! "$PY" -c "import markdown_it" 2>/dev/null; then
  echo "SKIPPED: markdown-it-py is not importable by $PY"
  echo "  The fragment guard IS a CommonMark parser — there is deliberately no"
  echo "  text-scanning fallback — so nothing below could be established."
  echo "  Install it with: $PY -m pip install markdown-it-py"
  echo "  CI does exactly that, in .github/workflows/changelog.yml."
  exit 2
fi

assert_contains() {
  local desc="$1" output="$2" expected="$3"
  if grep -qF "$expected" <<<"$output"; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    expected to contain: $expected"
    echo "    got: ${output:0:400}"
  fi
}

assert_not_contains() {
  local desc="$1" output="$2" unexpected="$3"
  if grep -qF "$unexpected" <<<"$output"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc"
    echo "    should NOT contain: $unexpected"
    echo "    got: ${output:0:400}"
  else
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  fi
}

assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (got [$got], expected [$want])"
  fi
}

assert_status() { assert_eq "$1" "$2" "$3"; }

WORK=$(mktemp -d) || { echo "SKIPPED: could not create a fixture directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A whole project dir. The three paths are passed explicitly so a fixture is a real one
# and the repo's own files are never touched by a test.
make_fixture() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/.claude-plugin" "$root/changelog.d" || return 1
  printf '{\n  "name": "claude-jit-context",\n  "version": "0.4.0"\n}\n' \
    > "$root/.claude-plugin/plugin.json"
  {
    printf '# Changelog\n\n'
    printf 'All notable changes to this project are documented here.\n\n'
    printf '## [Unreleased]\n\n'
    printf '### Fixed\n\n'
    printf '%s\n\n' "- **An entry that was already unreleased** (#38). It ships as-is."
    printf '## [0.3.1] — A session, and a red that means something\n\n'
    printf '%s\n' "- **Something older** (#17)."
  } > "$root/CHANGELOG.md"
  # Not a fragment. The scanner must skip it, or the release refuses its own instructions.
  printf 'Fragments live here.\n' > "$root/changelog.d/README.md"
}

frag() { printf '%s\n' "$3" > "$1/changelog.d/$2"; }

run() {
  local root="$1"; shift
  "$PY" "$ASSEMBLE" \
    --changelog "$root/CHANGELOG.md" \
    --dir "$root/changelog.d" \
    --plugin-json "$root/.claude-plugin/plugin.json" "$@" 2>&1
}

# Everything under a version heading, up to the next one.
section_of() {
  awk -v want="$2" '
    /^## / { inz = (index($0, want) == 4); next }
    inz
  ' "$1"
}

count_bullets() { awk '/^- / { n++ } END { print n + 0 }'; }
count_heading() { awk -v h="$1" '$0 == h { n++ } END { print n + 0 }'; }
count_lines_matching() { awk -v re="$1" '$0 ~ re { n++ } END { print n + 0 }' "$2"; }

# ============================================================================
echo "=== a clean directory assembles, and nothing is lost in the cut ==="
# The positive control every refusal below is read against. If this section is red, each
# "it refused" result underneath is equally consistent with a script that refuses
# everything, and means nothing on its own.

F="$WORK/clean"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). One line of prose."
frag "$F" 44.added.md "- **An added thing** ([#44](https://github.com/o/r/issues/44)). Prose."
frag "$F" 44.changed.second-entry.md "- **A second entry from one issue** (#44). Prose."

out=$(run "$F" --version 0.4.0 --title "Fragments")
assert_status "exit 0 on a clean assemble" "$?" "0"
assert_contains "the receipt names what it consumed"    "$out" "consumed  44.added.md"
assert_contains "the receipt names the parser that verified the write" "$out" "markdown-it-py"

CL="$F/CHANGELOG.md"
WHOLE=$(cat "$CL")
assert_contains "the new version heading is written"     "$WHOLE" "## [0.4.0] — Fragments"
assert_contains "an empty [Unreleased] is left behind"   "$WHOLE" "## [Unreleased]"
assert_contains "the older release survives"             "$WHOLE" "## [0.3.1] —"

NEW=$(section_of "$CL" "[0.4.0]")
assert_contains "the fragment prose lands verbatim"      "$NEW" "**A fixed thing** (#65). One line of prose."
assert_contains "a link-form issue reference lands too"  "$NEW" "issues/44"
assert_contains "the second entry from one issue lands"  "$NEW" "**A second entry from one issue**"
assert_contains "the pre-existing unreleased entry is released with it" \
  "$NEW" "**An entry that was already unreleased** (#38)"

# The whole point of the merge branch: a fragment whose section already exists under
# [Unreleased] joins that heading. Two `### Fixed` under one version is the defect that
# had to be hand-resolved twice on 2026-08-12.
assert_eq "exactly one ### Fixed under the new version" \
  "$(printf '%s\n' "$NEW" | count_heading "### Fixed")" "1"
assert_eq "exactly one ### Added under the new version" \
  "$(printf '%s\n' "$NEW" | count_heading "### Added")" "1"

# Keep a Changelog order, not filename order: Added before Changed before Fixed.
assert_eq "sections come out in Keep a Changelog order" \
  "$(printf '%s\n' "$NEW" | awk '/^### / { printf "%s ", $2 }')" "Added Changed Fixed "

# 3 fragments in + 1 entry already under [Unreleased] = 4 entries out. This is the
# assertion that catches a cut which silently loses one.
assert_eq "fragment count in equals entry count out" \
  "$(printf '%s\n' "$NEW" | count_bullets)" "4"

UNREL=$(section_of "$CL" "[Unreleased]")
assert_eq "[Unreleased] carries no entries after the release" \
  "$(printf '%s\n' "$UNREL" | count_bullets)" "0"

assert_eq "the fragments are consumed" \
  "$(ls "$F/changelog.d" | awk '/\.md$/ && $0 != "README.md" { n++ } END { print n + 0 }')" "0"
assert_eq "changelog.d/README.md is not a fragment and survives" \
  "$([ -f "$F/changelog.d/README.md" ] && echo yes || echo no)" "yes"

# test-version-sites.sh reads the heading this script now writes. Its extractor, copied
# here deliberately: if the two ever disagree, the release ships a CHANGELOG the version
# guard cannot parse, and that suite would only say so afterwards.
assert_eq "test-version-sites.sh can parse the heading we wrote" \
  "$(awk '/^## \[[0-9]/ { match($0, /\[[^]]*\]/); print substr($0, RSTART + 1, RLENGTH - 2); exit }' "$CL")" \
  "0.4.0"

echo ""
echo "=== a second run has nothing to assemble, and says so distinctly ==="
out=$(run "$F" --version 0.4.0 --title "Again")
assert_status "exit 2 when changelog.d/ holds no fragments" "$?" "2"
assert_contains "and reports skipped, not ok" "$out" "skipped"
assert_eq "and wrote nothing" "$(count_lines_matching "Again" "$CL")" "0"

echo ""
echo "=== the injection guard, which is the reason this is a CommonMark parser ==="
# Each of these is a line CommonMark reads as structure. Inserted verbatim into
# CHANGELOG.md it becomes that structure — reparenting entries, or planting a definition
# that wins over one further down the file. Three pattern-based scanners upstream were
# each bypassed, so the guard is the parser a reader would use.
#
# THE CONTROL COMES FIRST. A fragment that quotes a release heading inside a properly
# closed fence at the bullet's own indent is exactly what changelog.d/README.md
# prescribes, and it must be ACCEPTED — otherwise every refusal below is just a tool
# that refuses fragments.
F="$WORK/fence-control"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
{
  printf '%s\n' "- **Quoting a heading, the prescribed way** (#65). It now reads:"
  printf '\n'
  printf '%s\n' '  ```markdown'
  printf '%s\n' '  ## [Unreleased]'
  printf '%s\n' '  ```'
} > "$F/changelog.d/65.fixed.md"
out=$(run "$F" --check)
assert_status "a fenced heading at the bullet's indent is ACCEPTED" "$?" "0"
assert_not_contains "and is not reported as a finding" "$out" "refused"

refuses() {
  local desc="$1" name="$2" body="$3" root out status
  root="$WORK/inj-$name"
  make_fixture "$root" || { echo "  FAIL: could not build the fixture"; FAIL=$((FAIL + 1)); return; }
  # The positive control, in the same fixture: an ordinary entry that must NOT be named
  # in the findings, so "it refused" cannot be satisfied by refusing everything.
  frag "$root" 12.added.md "- **An ordinary entry** (#12). Prose."
  printf '%s\n' "$body" > "$root/changelog.d/$name"
  out=$(run "$root" --check)
  status=$?
  assert_status "$desc" "$status" "1"
  # "$name:" and not "$name": the ok receipt lists every accepted fragment BY NAME, so a
  # bare-name assertion passes against a guard that does nothing. A finding is
  # "changelog.d/<name>:<line>: ...", and the colon is what tells the two apart.
  assert_contains "  ...and names $name in a finding" "$out" "$name:"
  assert_not_contains "  ...and not the clean entry beside it" "$out" "12.added.md"
}

# Every fixture name below carries a SLUG and a number outside the tracker range, and
# neither is cosmetic. tests/test-changelog-fragment-refs.sh refuses any tracked file that
# names a fragment currently on disk, because the release deletes fragments and such a
# reference is green only until the next tag — and it compares by substring. A fixture
# named for a plain issue number IS that reference, so this suite reddened the guard the
# moment a real PR wrote a fragment with the same number: one test file quietly making a
# range of live issue numbers unusable by whoever fixes them. The number alone is not
# enough either, since a longer number ends with a shorter one. Give a new fixture a slug.
refuses "an ATX heading at column 0" 9070.fixed.fixture.md \
"- **An entry** (#9070). Prose.

# INJECTED HEADING"

# Upstream #927 anchored at column 0 and #930 found three ways past. This is one of them.
refuses "an ATX heading indented three spaces" 9071.fixed.fixture.md \
"- **An entry** (#9071). Prose.

   ### INJECTED"

# The advice this convention used to give. Inside a bullet the content column is 2, so
# four spaces is TWO relative columns — an ordinary paragraph, in which a heading is live.
refuses "a heading indented four spaces inside the bullet" 9072.fixed.fixture.md \
"- **An entry** (#9072). Prose.

    ## [Unreleased]"

refuses "a setext heading" 9073.fixed.fixture.md \
"- **An entry** (#9073). Prose.

INJECTED
========"

# Not an html_block, and the previous upstream guard refused a line STARTING with a tag.
refuses "an inline HTML heading tag mid-paragraph" 9074.fixed.fixture.md \
"- **An entry** (#9074). Prose and then <h1>INJECTED</h1> after a word."

refuses "a link reference definition" 9075.fixed.fixture.md \
"- **An entry** (#9075). Prose.

[Unreleased]: https://evil.example/pwned"

# Upstream #936 walked through a fence: a line reaching column 0 ends the fence, the
# bullet and the list, so what was being quoted goes live at document level.
refuses "a fence that never closes" 9076.fixed.fixture.md \
"- **An entry** (#9076). Prose.

  \`\`\`markdown
  ## [Unreleased]"

# The balance guard counts lines beginning with a dash and a space, and trusts that
# count. An ordered list at the top level makes the arithmetic and the document disagree.
refuses "a top level that is not a - bullet list" 9077.fixed.fixture.md \
"1. **An entry** (#9077). Prose."

refuses "a tab" 9078.fixed.fixture.md \
"- **An entry** (#9078).	Prose after a tab."

echo ""
echo "=== an unknown section is refused, beside one that is not ==="
F="$WORK/badsection"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md    "- **A fixed thing** (#65). Prose."
frag "$F" 9070.improved.md "- **Improved is not a Keep a Changelog heading** (#9070). Prose."

out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 1 on an unknown section" "$?" "1"
assert_contains "names the offending file"   "$out" "9070.improved.md"
assert_contains "names the unknown section"  "$out" "improved"
assert_not_contains "does not blame the valid fragment beside it" "$out" "65.fixed.md"
assert_eq "wrote nothing at all" "$(count_lines_matching "^## .0\.4\.0." "$F/CHANGELOG.md")" "0"
assert_eq "and consumed nothing" "$([ -f "$F/changelog.d/65.fixed.md" ] && echo yes || echo no)" "yes"

echo ""
echo "=== a body that does not name its own issue is refused ==="
F="$WORK/noissue"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
# Names an issue -- just not its own. 8 of 20 entries in one upstream release did this.
frag "$F" 71.fixed.md "- **Names every issue but its own** (#65). Prose."

out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 1 when the body omits its own issue" "$?" "1"
assert_contains "names the offending file" "$out" "71.fixed.md"
assert_not_contains "does not blame the fragment that does name its own" "$out" "65.fixed.md"

# The positive control for the reference check itself, in both accepted spellings.
F="$WORK/refs"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **Hash form** (#65). Prose."
frag "$F" 9.added.md  "- **Link form** ([the issue](https://github.com/o/r/issues/9)). Prose."
out=$(run "$F" --check)
assert_status "both (#65) and a URL ending in /issues/9 satisfy the check" "$?" "0"

# #38 must not satisfy issue 3: a substring match would accept it.
F="$WORK/substring"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 3.fixed.md "- **The body names #38, and this is issue 3**. Prose."
out=$(run "$F" --check)
assert_status "a longer number containing the issue does not satisfy it" "$?" "1"
assert_contains "and says which file" "$out" "3.fixed.md"

echo ""
echo "=== an unparseable filename, and an empty file, are refused ==="
F="$WORK/badname"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 12.fixed.md "- **A fixed thing** (#12). Prose."
frag "$F" notes.md    "- **No issue number, no section** (#12). Prose."
: > "$F/changelog.d/13.added.md"
out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 1 on a filename that is not <issue>.<section>[.<slug>].md" "$?" "1"
assert_contains "names the unparseable file" "$out" "notes.md"
assert_contains "names the empty one too"    "$out" "13.added.md"
assert_not_contains "does not blame the well-named one" "$out" "12.fixed.md"

echo ""
echo "=== the version has to agree with plugin.json ==="
F="$WORK/mismatch"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
out=$(run "$F" --version 0.9.9 --title "T")
assert_status "exit 1 when --version disagrees with plugin.json" "$?" "1"
assert_contains "names the value plugin.json carries" "$out" "0.4.0"
assert_contains "and the value it was asked for"      "$out" "0.9.9"
assert_eq "wrote nothing" "$(count_lines_matching "^## .0\.9\.9." "$F/CHANGELOG.md")" "0"
# The control: the same fixture at the version plugin.json actually carries.
out=$(run "$F" --version 0.4.0 --title "T")
assert_status "and the agreeing version assembles" "$?" "0"
# Idempotence is a refusal, not a second section under the same version.
#
# 999 and not a plausible issue number: this file is tracked, changelog.d/ holds real
# fragments, and `tests/test-changelog-fragment-refs.sh` refuses any tracked file naming
# one that is still on disk. A fixture named after a live fragment is green while the
# fragment is untracked and red the moment it is committed — which is how this line was
# found, by that suite, on this suite's own commit.
frag "$F" 999.added.md "- **Another** (#999). Prose."
out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 1 rather than duplicate an existing release heading" "$?" "1"
assert_contains "and says so" "$out" "already has"

echo ""
echo "=== could not evaluate is not the same as refused ==="
F="$WORK/nodir"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
rm -rf "$F/changelog.d"
out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 2 when changelog.d/ does not exist" "$?" "2"
assert_contains "and says nothing was looked at"       "$out" "nothing is claimed"

F="$WORK/nochangelog"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
rm -f "$F/CHANGELOG.md"
out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 2 when CHANGELOG.md does not exist" "$?" "2"

F="$WORK/nomanifest"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
printf 'not json at all\n' > "$F/.claude-plugin/plugin.json"
out=$(run "$F" --version 0.4.0 --title "T")
assert_status "exit 2 when plugin.json cannot be read for a version" "$?" "2"
assert_contains "and refuses to assume --version is right" "$out" "not assumed correct"

# The property the whole guard rests on: "could not look" must never render as "looked
# and found nothing". A shim that makes the import fail proves the difference is real
# rather than asserted in a docstring.
SHIM="$WORK/shim"
mkdir -p "$SHIM/markdown_it"
printf 'raise ImportError("shimmed out by tests/test-assemble-changelog.sh")\n' \
  > "$SHIM/markdown_it/__init__.py"
F="$WORK/noparser"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
out=$(PYTHONPATH="$SHIM" run "$F" --check)
assert_status "exit 2, not 0, when the parser is missing" "$?" "2"
assert_contains "and says nothing was established"        "$out" "nothing is claimed"
assert_contains "and names the missing dependency"        "$out" "markdown-it-py"
assert_not_contains "and does not report ok"              "$out" "assemble    : ok"

echo ""
echo "=== --check and --count and --dry-run write nothing ==="
F="$WORK/readonly"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
out=$(run "$F" --check)
assert_status "--check: exit 0 on a clean directory" "$?" "0"
out=$(run "$F" --count)
assert_status "--count: exit 0" "$?" "0"
assert_eq     "--count: prints the bare integer and nothing else" "$out" "1"
out=$(run "$F" --version 0.4.0 --title "T" --dry-run)
assert_status "--dry-run: exit 0" "$?" "0"
assert_eq "none of the three consumed anything" \
  "$([ -f "$F/changelog.d/65.fixed.md" ] && echo yes || echo no)" "yes"
assert_eq "none of the three wrote anything" \
  "$(count_lines_matching "^## " "$F/CHANGELOG.md")" "2"

# --count must not print 0 when it could not look: a caller doing arithmetic on that
# reads "nothing pending" out of "could not evaluate". Read from STDOUT alone, which is
# where the number goes and where such a caller would be reading; the explanation goes to
# stderr on purpose, and folding the two together here would compare against the prose.
out=$(PYTHONPATH="$SHIM" "$PY" "$ASSEMBLE" --dir "$F/changelog.d" --count 2>/dev/null)
assert_status "--count: exit 2 when the parser is missing" "$?" "2"
assert_eq "--count: and puts nothing on stdout" "$out" ""

F="$WORK/checkempty"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
out=$(run "$F" --check)
assert_status "--check: exit 0 on an empty directory" "$?" "0"
assert_contains "  ...and names which of the three it did" "$out" "skipped"

F="$WORK/checkbad"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 9070.improved.md "- **Unknown section** (#9070). Prose."
out=$(run "$F" --check)
assert_status "--check: exit 1 on a directory that would be refused" "$?" "1"

echo ""
echo "=== the missing arguments are refused, not guessed ==="
F="$WORK/args"
make_fixture "$F" || { echo "SKIPPED: could not build the fixture"; exit 2; }
frag "$F" 65.fixed.md "- **A fixed thing** (#65). Prose."
out=$(run "$F" --title "T")
assert_status "exit 1 with no --version and no --check" "$?" "1"
out=$(run "$F" --version 0.4.0)
assert_status "exit 1 with no --title" "$?" "1"
out=$(run "$F" --version 0.4 --title "T")
assert_status "exit 1 on a --version that is not x.y.z" "$?" "1"
assert_eq "and none of those wrote anything" \
  "$(count_lines_matching "^## .0\.4" "$F/CHANGELOG.md")" "0"

echo ""
echo "=== this repository's own changelog.d/ passes --check ==="
# The real tree, not a fixture. A fragment committed with a typo in its section name is
# green in the PR that adds it and red on the tag, which is the whole failure mode.
out=$("$PY" "$ASSEMBLE" --dir "$REPO/changelog.d" --check 2>&1)
assert_status "the committed fragments validate" "$?" "0"

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
