#!/bin/bash
# #355: the Windows Defender exclusion step in .github/workflows/tests.yml must never be
# able to fail the "hooks" leg. `Add-MpPreference` hit a bare Defender-service outage
# (0x800106ba) on the hosted image three times in under three hours, unrelated to any
# diff; the step ran under `shell: pwsh` with no non-fatal handling, so the terminating
# error skipped "Run hook test suites" entirely and the leg reported red exactly as if
# the suite had failed -- reddening all three pinned gate jobs even though the other two
# platforms were clean.
#
# The fix scopes `continue-on-error: true` to the exclusion step alone. The one way this
# regresses is a future edit copying that line down onto "Run hook test suites" -- which
# would turn a genuinely failing Windows suite green, strictly worse than the flake it
# replaces. This suite is the check that scope has not moved.
#
# Usage: bash tests/test-defender-step-scope-355.sh
#
# jit-drive: none -- every check here reads the workflow file directly with grep/awk or
# python3's yaml loader, never a helper that takes an (description, output) pair.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/tests.yml"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; shift; [ $# -gt 0 ] && echo "    $*"; return 0; }

if [ ! -f "$WORKFLOW" ]; then
  echo "  SKIPPED: $WORKFLOW not found -- nothing to check."
  exit 2
fi

# The positive control: prove this file can even see the two step names, so a rename of
# either one is a loud failure here rather than every assertion below going vacuously
# green against a file that no longer contains what it is looking for.
if grep -qF 'Exclude the checkout and temp dir from Windows Defender scanning' "$WORKFLOW" \
   && grep -qF 'Run hook test suites' "$WORKFLOW"; then
  ok "harness sees both step names in the workflow file"
else
  bad "harness cannot see one or both step names -- everything below is vacuous" \
      "grep the workflow file by hand before trusting any PASS below"
  echo ""
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# Isolate each step's own block: from its "- name:" line to the line before the next
# "- name:" (or end of file). Two-space-indented list markers, matching this file's style.
step_block() {
  awk -v want="$1" '
    /^      - name:/ {
      if (in_block) exit
      if (index($0, want) > 0) { in_block = 1; print; next }
      next
    }
    # A line back out to job level (two-space indent, no "- ") ends the last step of a
    # job -- without this, the final step of "hooks" ran on into the next job own
    # steps, because there is no further "- name:" line inside this job to stop at.
    in_block && /^  [A-Za-z_-]+:/ { exit }
    in_block { print }
  ' "$WORKFLOW"
}

DEFENDER_BLOCK="$(step_block "Exclude the checkout and temp dir from Windows Defender scanning")"
TEST_BLOCK="$(step_block "Run hook test suites")"

if grep -qF 'continue-on-error: true' <<<"$DEFENDER_BLOCK"; then
  ok "the Defender exclusion step carries continue-on-error: true"
else
  bad "the Defender exclusion step has no continue-on-error: true" \
      "a Defender-service outage will red the whole leg again -- see #355"
fi

if grep -qF 'continue-on-error' <<<"$TEST_BLOCK"; then
  bad "Run hook test suites carries continue-on-error -- this would hide a real failure" \
      "remove it: only the exclusion step above it may ever have this line"
else
  ok "Run hook test suites carries no continue-on-error"
fi

if grep -qE '^\s*if:' <<<"$TEST_BLOCK"; then
  bad "Run hook test suites carries an if: condition that could skip it" \
      "the test step must run unconditionally and be the sole source of the leg's result"
else
  ok "Run hook test suites carries no weakening if: condition"
fi

# YAML must still parse. python3 with PyYAML is not guaranteed on every dev machine, so
# this check degrades to SKIPPED rather than FAILED when the module is unavailable --
# CI's own workflow-syntax check (GitHub parsing the file to run it at all) is the real
# backstop; this is a fast local confirmation, not the only gate.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW" >/dev/null 2>&1; then
    ok "the workflow file is syntactically valid YAML"
  else
    bad "the workflow file failed to parse as YAML"
  fi
else
  echo "  SKIPPED: python3+PyYAML unavailable here -- YAML syntax is not checked locally."
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
