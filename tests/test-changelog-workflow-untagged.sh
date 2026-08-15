#!/bin/bash
# The changelog workflow's link-ref audit must declare `--untagged 0.1.0`.
#
# `.github/workflows/oss-changelog.yml` is an OWNED file: `/oss:scaffold --apply` rewrites
# it in full on every run, and the template it writes calls `--check-links` with no
# `--untagged`. This repository has to pass one. `CHANGELOG.md` carries a `## [0.1.0]`
# section for a version that predates this repository — it was extracted from
# claude-supertool at 0.2.0 (00fd97b) — so no `v0.1.0` tag exists or can be created, and
# `--check-links` without the declaration refuses on every pull request.
#
# The declaration therefore lives as a local edit inside a file something else owns, which
# is a shape that decays silently: the next `/oss:scaffold --apply` drops it, and the
# person who ran the scaffold is not the person whose pull request goes red days later
# with a finding about release history rather than about their change.
#
# This suite is the guard. It is in `tests/`, which the scaffold does not own, and it runs
# in `run-all.sh` on every leg — so the clobber is caught by the run that caused it.
#
# Retire this suite when the upstream `changelog.untagged` key in `.oss.json` lands and the
# generated template reads it. At that point the declaration is config, not an edit, and a
# test asserting the edit is asserting the workaround rather than the requirement.
#
# Usage: bash tests/test-changelog-workflow-untagged.sh

# jit-drive: none -- every helper here reads a file from the repo and takes no output argument
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/oss-changelog.yml"
CHANGELOG="$REPO/CHANGELOG.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ $# -gt 1 ] && echo "    $2"; }

echo "=== changelog workflow declares its untagged releases ==="

# The harness guard. Every assertion below is about the CONTENT of two files, and
# "the flag is absent" and "the file is absent" produce identical greps. A suite that
# cannot read them asserts nothing, and says so rather than reporting a pass.
missing=""
[ -f "$WORKFLOW" ] || missing="$missing $WORKFLOW"
[ -f "$CHANGELOG" ] || missing="$missing $CHANGELOG"
if [ -n "$missing" ]; then
  echo "SKIPPED: could not read the file(s) every assertion here is about:$missing"
  echo "  Nothing below ran. This is not a pass — a workflow that is not there cannot"
  echo "  be shown to carry a flag, and the grep for it is silent for both reasons."
  exit 2
fi

# The positive control, and it comes first. It proves the grep below can match this
# file at all: if the audit step itself is gone — renamed upstream, or the whole leg
# dropped — then "no `--untagged`" is true for a reason that has nothing to do with a
# clobbered edit, and the failure message would send someone to re-add a flag to a step
# that no longer exists.
if grep -q -- '--check-links' "$WORKFLOW"; then
  pass "the workflow still has a --check-links step for the flag to live on"
else
  fail "the workflow has no --check-links step at all" \
       "Everything below is vacuous. The upstream template changed shape: re-read it before restoring any flag."
  echo ""
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

if grep -q -- '--untagged 0.1.0' "$WORKFLOW"; then
  pass "--check-links declares --untagged 0.1.0"
else
  fail "--check-links does not declare --untagged 0.1.0" \
       "Almost certainly a /oss:scaffold --apply that rewrote this owned file. Re-add the flag to the --check-links step, with the comment explaining why."
fi

# The flag is only correct while CHANGELOG.md actually carries the section it exempts.
# Declaring a version untagged that no longer has a `## [x.y.z]` heading is a statement
# about release history that is no longer true of this file, and the audit would not
# catch it: an exemption for a section that is not there costs nothing and reports
# nothing, which is exactly how a stale declaration survives.
if grep -q '^## \[0\.1\.0\]' "$CHANGELOG"; then
  pass "CHANGELOG.md still carries the ## [0.1.0] section the flag exempts"
else
  fail "CHANGELOG.md has no ## [0.1.0] section" \
       "The exemption now names a version this file does not document. Drop --untagged from the workflow rather than leaving a declaration nothing backs."
fi

# The inverse, and the reason this is an assertion rather than a comment: a version that
# DOES have a tag must not be exempted, because the exemption suppresses a real finding.
# `git tag` is the authority; without git we cannot ask, and that is not a pass either.
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  # Not `git tag --list | grep -q .`: grep -q exits on the first match, git takes
  # SIGPIPE, and under pipefail the pipeline reports non-zero HAVING found the tag —
  # a false green on the one assertion here that exists to catch a real change.
  tags=$(git -C "$REPO" tag --list 'v0.1.0')
  if [ -n "$tags" ]; then
    fail "v0.1.0 is now a real tag" \
         "The exemption suppresses a finding that should be raised: drop --untagged and add [0.1.0] to CHANGELOG.md's link-ref block."
  else
    pass "v0.1.0 is not a tag, so the exemption still describes something true"
  fi
else
  echo "  NOTE: no git repository here, so 'v0.1.0 is untagged' went unverified."
  echo "        The two assertions above still ran; this one did not."
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
