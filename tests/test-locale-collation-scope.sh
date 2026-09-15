#!/bin/bash
# #388: a POSIX bracket LETTER range inside `[[ =~ ]]` -- `[A-Z]`, `[a-z]`, `[A-Za-z]`,
# `[A-Za-z0-9_]` and so on -- is matched by the active locale's COLLATION order, not by
# byte value, wherever bash links against a libc that collates (glibc does; darwin's
# does not, which is exactly why this repo's own local run cannot see this class of bug
# at all -- see tests/test-config-locale-collation.sh for the three-outcome probe that
# covers the runtime behaviour this suite only guards the SOURCE for).
#
# Under Turkish collation (LC_ALL=tr_TR.UTF-8, and az_AZ) `I` does not sort inside A..Z,
# so `scripts/common.sh`'s `[A-Za-z0-9_]+` config-key check silently refused every real
# setting whose name carried an I after its prefix. `local LC_ALL=C` at the top of the
# enclosing function is the fix -- it pins the collation to a byte-value order for the
# life of that function and restores the caller's locale on return.
#
# THIS SUITE is the guard against the next range being added without that scope: it
# scans every tracked `scripts/*.sh` file for a `[[ =~ ]]` whose pattern contains a
# bracket LETTER range, and fails unless the match sits inside a function that sets
# `local LC_ALL=C` before it -- or is named in the EXEMPT table below with a written
# reason.
#
# WHY LETTERS ONLY, NOT [0-9] TOO: the issue that opened #388 measured this on
# ubuntu-latest / bash 5.2 under a localedef-built tr_TR.UTF-8 -- digit ranges did not
# move in that measurement, only A-Z and a-z did. A digit-only range (`[0-9]`, as in
# tests/test-fork-count.sh's timestamp check) is out of this scanner's scope for that
# reason, not because it was overlooked.
#
# WHY scripts/*.sh ALONE, NOT tests/*.sh TOO: this scanner shipped once scanning
# tests/*.sh as well, and the self-review round that caught it is worth stating --
# tests/test-config-locale-collation.sh (this suite's own sibling, added in the same
# commit) legitimately WRITES `[[ "I" =~ ^[A-Z]$ ]]` as the literal probe text it feeds
# to a foreign locale, inside comments explaining that probe, and inside a `bash -c`
# string this file's own parser cannot tell from a top-level statement -- and this
# scanner itself contains the string `[A-Za-z0-9_-]` in an EXEMPT table entry. Every one
# of those is prose or fixture data, not a live `[[ =~ ]]` this scanner needs to guard,
# and scanning tests/*.sh made the scanner fail on itself and its own sibling the moment
# both were committed and `git ls-files` could see them. The actual blast radius of
# #388 is `scripts/*.sh` -- what ships and runs in a stranger's session, per
# `.claude/jit-context/paths/00-manual/tooling.md`'s own split between the two
# directories -- so that is what this scanner is scoped to now. `.oss/` is excluded
# for the same reason CLAUDE.md gives for not sweeping it for line citations:
# `[[ =~ ]]` is a bash construct and `.oss/assemble_changelog.py` is Python, rewritten
# by every `/oss:scaffold --apply` regardless.
#
# Usage: bash tests/test-locale-collation-scope.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

PASS=0
FAIL=0

# EXEMPT entries: "path|fragment|reason". `fragment` is a distinctive, greppable
# substring of the OFFENDING LINE itself (never a line number, per this repo's own
# no-line-citation rule) that must appear on the flagged line for the exemption to
# apply. A reason is mandatory prose, read by a human deciding whether to keep it.
EXEMPT=(
  "scripts/session-start-hook.sh|edited)-[A-Za-z0-9_-]{1,64}|Perl regex, not [[ =~ ]] -- Perl's own regex engine does not collate bracket ranges unless the script says 'use locale', and this file has no such pragma (grep -n use.locale scripts/session-start-hook.sh returns nothing). Verified directly: under LC_ALL=tr_TR.UTF-8 this exact pattern still matches edited-I.txt (#388)."
)

# Every tracked file under scripts/ -- the runtime this repo ships, and the actual
# blast radius of #388. tests/*.sh is deliberately NOT scanned: see the header above.
FILES="$(git ls-files 'scripts/*.sh' 2> /dev/null)"
if [ -z "$FILES" ]; then
  echo "SKIPPED: git ls-files returned nothing under scripts/ -- this must be run"
  echo "         inside a git checkout of the repository, not a tarball."
  exit 2
fi

is_exempt() {
  local file="$1" content="$2" e f frag
  for e in "${EXEMPT[@]:-}"; do
    [ -n "$e" ] || continue
    f="${e%%|*}"
    frag="${e#*|}"
    frag="${frag%%|*}"
    if [ "$f" = "$file" ]; then
      case "$content" in
        *"$frag"*) return 0 ;;
      esac
    fi
  done
  return 1
}

while IFS= read -r file; do
  [ -f "$file" ] || continue
  # Candidate lines: `=~` on the same line as a bracket expression carrying a LETTER
  # range (A-Z, a-z, in either order and either case pairing -- [A-Z] [a-z] [A-Za-z]
  # [a-zA-Z] etc). A false positive here (a `=~` line that has a letter-range bracket
  # for some unrelated reason) still just asks for LC_ALL=C or an exemption; it does
  # not silently pass.
  MATCHES="$(grep -nE '=~' "$file" 2> /dev/null | grep -E '\[[^]]*[A-Za-z]-[A-Za-z][^]]*\]')"
  [ -n "$MATCHES" ] || continue
  while IFS=: read -r lineno content; do
    [ -n "$lineno" ] || continue
    # A comment LINE (shell # or the start of a prose paragraph) can mention `[[ =~ ]]`
    # and a bracket range without containing either -- exactly this file's own header
    # does. Skip anything whose first non-blank character is a shell comment marker;
    # a real `[[ =~ ]]` or `=~` regex is never itself written that way.
    trimmed="${content#"${content%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) continue ;;
    esac
    if is_exempt "$file" "$content"; then
      PASS=$((PASS + 1))
      echo "  PASS (exempt): $file: $content"
      continue
    fi
    # Walk backward from the candidate to the nearest enclosing function: the last
    # `name() {` above it that has not since been closed by a column-0 `}`.
    scoped=0
    fn_start=""
    ln=$((lineno - 1))
    while [ "$ln" -ge 1 ]; do
      row="$(sed -n "${ln}p" "$file")"
      case "$row" in
        '}') break ;; # closed before reaching a function header: not inside one
        [A-Za-z_]*'() {')
          fn_start="$ln"
          break
          ;;
      esac
      ln=$((ln - 1))
    done
    if [ -n "$fn_start" ]; then
      # `local LC_ALL=C` (or `local ... LC_ALL=C ...` on the same local statement)
      # anywhere between the function header and the candidate line.
      if sed -n "${fn_start},${lineno}p" "$file" | grep -qE '^[[:space:]]*local[[:space:]].*\bLC_ALL=C\b'; then
        scoped=1
      fi
    fi
    if [ "$scoped" = 1 ]; then
      PASS=$((PASS + 1))
      echo "  PASS (scoped): $file:$lineno"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $file:$lineno -- a letter-range bracket expression inside [[ =~ ]]"
      echo "        with no enclosing 'local LC_ALL=C' and no EXEMPT entry:"
      echo "        $content"
      echo "        Under a collating locale (Turkish, Azerbaijani) this range is"
      echo "        matched by collation order, not byte value, and can silently"
      echo "        reject or accept the wrong input. Add 'local LC_ALL=C' to the"
      echo "        top of the enclosing function, or add a written EXEMPT entry."
    fi
  done <<< "$MATCHES"
done <<< "$FILES"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
