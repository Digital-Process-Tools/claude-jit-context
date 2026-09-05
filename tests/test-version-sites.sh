#!/bin/bash
# Tests that the three sites carrying this plugin version string agree.
#
# The version is bumped by hand in three places, and until now nothing compared them:
#   .claude-plugin/plugin.json   the value the plugin updater reads
#   README.md                    the shields.io version badge, which is what a human sees
#   CHANGELOG.md                 the topmost released `## [x.y.z]` heading
#
# A stale badge fails in the direction that costs most: it tells every reader the project
# is older than it is, and nothing errors.
#
# THIS IS NOT A SWEEP, and please do not extend it into one. The version string also
# appears in prose -- CLAUDE.md, SKILL.md and two entries under .claude/jit-context/ name
# 0.2.0 in sentences describing what 0.2.0 changed, and those are CORRECT. Only a human
# can tell "this sentence is about a past release" from "this badge is stale", so the
# unfiltered `git grep -n` for the OUTGOING version stays a human step at release time --
# see .claude/jit-context/paths/00-manual/release.md, whose example spells a version that
# is not the current one because it is an example. This suite asserts three named sites
# agree, and nothing else.
#
# A fourth surface exists and is deliberately absent: the `claude-marketplace` entry that
# `/plugin install` resolves through names the REPOSITORY, not a version. Marketplace
# users get whatever is on main, so there is nothing there to keep in step.
#
# Every extraction is guarded. Parsing JSON with awk rather than jq -- no new runtime
# dependency, ever -- means a parse that finds nothing returns the empty string, and two
# empty strings compare equal. A green run that compared nothing is precisely the silent
# drift this suite exists to catch, so each site must yield a semver-shaped string or the
# suite fails and names the site it could not read.
#
# Unparseable is a FAILURE here, not the exit-2 SKIPPED state run-all.sh understands.
# SKIPPED means "this platform could not build the fixture" -- an absence of coverage
# nobody caused, which is why the symlink suites use it. A plugin.json that this
# repository owns and cannot read a version out of is a defect in this repository, and
# filing it as missing coverage would bury it.
#
# Usage: bash tests/test-version-sites.sh

set -uo pipefail

# JIT_VERSION_TEST_ROOT points the suite at a scratch copy of the repo, so the red cases
# can be produced by breaking a copy instead of the working tree. Unset in CI.
REPO="${JIT_VERSION_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0
FAIL=0

PLUGIN_JSON="$REPO/.claude-plugin/plugin.json"
README="$REPO/README.md"
CHANGELOG="$REPO/CHANGELOG.md"
SECURITY="$REPO/SECURITY.md"

# --- extraction: awk only, the same rule the hooks live under ----------------

# "version": "0.3.0"  ->  0.3.0
extract_plugin_version() {
  awk 'match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]*"/) {
         s = substr($0, RSTART, RLENGTH)
         sub(/^"version"[[:space:]]*:[[:space:]]*"/, "", s)
         sub(/"$/, "", s)
         print s
         exit
       }' "$1" 2> /dev/null
}

# [![Version](https://img.shields.io/badge/version-0.3.0-orange)](...)  ->  0.3.0
#
# The message segment is everything between the `version-` label and the trailing
# `-<colour>)`, and it is NOT hyphen-free: shields.io escapes a literal hyphen by doubling
# it, so a pre-release badge reads `version-0.4.0--rc.1-orange`. Stopping at the first
# hyphen truncated that to `0.4.0` and reported drift against a plugin.json that agreed --
# a false failure on exactly the release where the badge matters most. Take the segment up
# to the colour instead, then undouble.
extract_readme_badge_version() {
  awk 'match($0, /img\.shields\.io\/badge\/version-[^)\/]*-[A-Za-z]+\)/) {
         s = substr($0, RSTART, RLENGTH)
         sub(/^img\.shields\.io\/badge\/version-/, "", s)
         sub(/-[A-Za-z]+\)$/, "", s)
         gsub(/--/, "-", s)
         print s
         exit
       }' "$1" 2> /dev/null
}

# ## [0.3.0] -- Containment  ->  0.3.0
#
# `## [Unreleased]` is skipped on purpose. It is the topmost `## [` heading and carries no
# version, so "the first `## [` heading" would compare the literal word Unreleased against
# a number on every release forever. The first heading whose bracket opens on a digit is
# the newest RELEASED version, which is what plugin.json and the badge claim to be.
extract_changelog_version() {
  awk '/^## \[[0-9]/ {
         match($0, /\[[^]]*\]/)
         print substr($0, RSTART + 1, RLENGTH - 2)
         exit
       }' "$1" 2> /dev/null
}

# | 0.3.x   | :white_check_mark: |  ->  0.3
#
# SECURITY.md is the fourth site, and it is not a version -- it is the supported MINOR, so
# it is compared as `major.minor` and never as an exact string. It earned its place the
# expensive way: it sat at `0.2.x` through the whole of 0.3.0, telling anyone reporting a
# vulnerability that the release which shipped nine containment fixes was unsupported.
# Take the first table row whose version cell opens on a digit; the `< 0.3` row below it
# opens on `<` and is deliberately not matched.
extract_security_minor() {
  awk '/^\|[[:space:]]*[0-9]/ {
         match($0, /[0-9]+\.[0-9]+/)
         print substr($0, RSTART, RLENGTH)
         exit
       }' "$1" 2> /dev/null
}

# --- the guard that makes the comparison mean something ---------------------
#
# The shape check matters as much as the emptiness check: a parse that drifted onto the
# wrong line can return a non-empty string that is not a version, and "orange" = "orange"
# passes just as quietly as "" = "".
require_version() {
  site="$1"
  file="$2"
  value="$3"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $site -- no such file: $file"
    FAIL=$((FAIL + 1))
    return 1
  fi
  if [ -z "$value" ]; then
    echo "  FAIL: $site -- no version string could be parsed out of $file"
    echo "        this suite refuses to compare an empty match; fix the parse or the file"
    FAIL=$((FAIL + 1))
    return 1
  fi
  if ! printf '%s\n' "$value" \
    | awk '{ exit !($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$/) }'; then
    echo "  FAIL: $site -- parsed [$value] out of $file, which is not a version string"
    FAIL=$((FAIL + 1))
    return 1
  fi
  echo "  PASS: $site -- read $value"
  PASS=$((PASS + 1))
  return 0
}

# jit-drive: none -- both helpers compare version strings, not hook output; there is no payload to make long
assert_same() {
  site="$1"
  value="$2"
  if [ "$value" = "$PLUGIN_V" ]; then
    echo "  PASS: $site agrees with plugin.json ($PLUGIN_V)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $site says $value, plugin.json says $PLUGIN_V"
    FAIL=$((FAIL + 1))
  fi
}

# --- the extractors themselves, against a fixture nobody will ever bump ------
#
# Three extractors that all return the empty string agree with each other, and three that
# all truncate the same way agree too. Neither is visible from the real files, which carry
# one value the parsers were written against. So parse a synthetic release first, with the
# awkward shape a real one will eventually have: a pre-release, whose hyphen shields.io
# doubles in the badge URL and neither other site escapes at all.
echo "=== the extractors read a synthetic pre-release correctly ==="
FIXTURE=$(mktemp -d) || {
  echo "  FAIL: could not create a fixture directory"
  exit 1
}
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/.claude-plugin"
printf '{\n  "name": "x",\n  "version": "9.4.0-rc.1"\n}\n' > "$FIXTURE/.claude-plugin/plugin.json"
printf '[![Version](https://img.shields.io/badge/version-9.4.0--rc.1-orange)](.claude-plugin/plugin.json)\n' > "$FIXTURE/README.md"
printf '## [Unreleased]\n\n## [9.4.0-rc.1] - Something\n\n## [9.3.0] - Older\n' > "$FIXTURE/CHANGELOG.md"

assert_extracts() {
  desc="$1"
  want="$2"
  got="$3"
  if [ "$got" = "$want" ]; then
    echo "  PASS: $desc -> $got"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc -> expected [$want], got [$got]"
    FAIL=$((FAIL + 1))
  fi
}

assert_extracts "plugin.json parser" "9.4.0-rc.1" \
  "$(extract_plugin_version "$FIXTURE/.claude-plugin/plugin.json")"
assert_extracts "README badge parser (shields doubles the hyphen)" "9.4.0-rc.1" \
  "$(extract_readme_badge_version "$FIXTURE/README.md")"
assert_extracts "CHANGELOG parser (skips [Unreleased], takes the newest release)" "9.4.0-rc.1" \
  "$(extract_changelog_version "$FIXTURE/CHANGELOG.md")"

echo ""
echo "=== every site yields a version string ==="
# Counted from here, so the gate below reports on the READ stage and not on a self-check
# failure above it -- which has already failed the suite on its own account.
FAIL_BEFORE_READ=$FAIL
PLUGIN_V=$(extract_plugin_version "$PLUGIN_JSON")
README_V=$(extract_readme_badge_version "$README")
CHANGELOG_V=$(extract_changelog_version "$CHANGELOG")

require_version "plugin.json" "$PLUGIN_JSON" "$PLUGIN_V"
require_version "README badge" "$README" "$README_V"
require_version "CHANGELOG heading" "$CHANGELOG" "$CHANGELOG_V"

SECURITY_M=$(extract_security_minor "$SECURITY")
if [ ! -f "$SECURITY" ]; then
  echo "  FAIL: SECURITY.md supported minor -- no such file: $SECURITY"
  FAIL=$((FAIL + 1))
elif [ -z "$SECURITY_M" ]; then
  echo "  FAIL: SECURITY.md supported minor -- no minor could be parsed out of $SECURITY"
  echo "        this suite refuses to compare an empty match; fix the parse or the file"
  FAIL=$((FAIL + 1))
elif ! printf '%s\n' "$SECURITY_M" | awk '{ exit !($0 ~ /^[0-9]+\.[0-9]+$/) }'; then
  echo "  FAIL: SECURITY.md supported minor -- parsed [$SECURITY_M], which is not a major.minor"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: SECURITY.md supported minor -- read $SECURITY_M"
  PASS=$((PASS + 1))
fi

echo ""
echo "=== the three agree ==="
if [ "$FAIL" -ne "$FAIL_BEFORE_READ" ]; then
  # Comparing only the sites that did parse would print agreement between fewer than
  # three, under a heading that says three.
  echo "  FAIL: not compared -- a site above could not be read"
  FAIL=$((FAIL + 1))
else
  assert_same "README badge" "$README_V"
  assert_same "CHANGELOG heading" "$CHANGELOG_V"

  # major.minor, because SECURITY.md names a supported LINE and not a release. Comparing it
  # as an exact string would fail on every patch release, which is how a check gets deleted.
  PLUGIN_MINOR=$(printf '%s\n' "$PLUGIN_V" | awk '{ match($0, /^[0-9]+\.[0-9]+/); print substr($0, RSTART, RLENGTH) }')
  if [ "$SECURITY_M" = "$PLUGIN_MINOR" ]; then
    echo "  PASS: SECURITY.md supports $SECURITY_M.x, which is plugin.json's line"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: SECURITY.md supports $SECURITY_M.x, plugin.json is $PLUGIN_V"
    echo "        a stale supported-versions table tells a reporter the current release is unsupported"
    FAIL=$((FAIL + 1))
  fi
fi

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
