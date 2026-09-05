#!/bin/bash
# Tests for #217 -- a sample call made by scripts/jit-match.sh or
# scripts/jit-dry-run.sh --prompt/--tool/--path must not write a synthetic record into
# the target project's real hooks.log, because that log is what a human -- and
# jit-misses.sh -- reads to understand genuine session activity.
#
# Paired in the same fixture, per the brief: a must-not-log case for every sample-call
# site, and a must-still-log positive control (a real hook invocation, the same shape a
# genuine session drives) -- so a harness that stopped exercising the log at all cannot
# pass this as silence.
#
# Usage: bash tests/test-sample-call-log.sh
#
# jit-drive: none -- log_absent/log_present assert the presence of a FILE on disk, not
# text inside a captured value; nothing in tests/test-assertion-helpers.sh's driven
# semantics (contains/not_contains/blocked over a capture, file or path-arg) fits an
# assertion whose subject is "does this path exist", so there is no helper here for that
# harness to drive.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/scripts/pre-prompt-hook.sh"
MATCH="$REPO/scripts/jit-match.sh"
DRYRUN="$REPO/scripts/jit-dry-run.sh"
PASS=0
FAIL=0

TMP="$(mktemp -d 2> /dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

IDX="00-index.tsv"
PROJ="$TMP/proj"
BASE="$PROJ/.claude/jit-context"
mkdir -p "$BASE/tools/00-manual" "$BASE/paths/00-manual" "$BASE/vocabulary/00-manual"
: > "$BASE/tools/00-manual/$IDX"
: > "$BASE/paths/00-manual/$IDX"
cat > "$BASE/vocabulary/00-manual/xsd.md" << 'MD'
---
title: XSD regen
description: regen command.
---
Full body about xsd regeneration.
MD
printf 'xsd\txsd.md\n' > "$BASE/vocabulary/00-manual/$IDX"

LOG="$BASE/.discovery/logs/hooks.log"

log_absent() {
  local desc="$1"
  if [ ! -e "$LOG" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    hooks.log exists and should not: $(cat "$LOG" 2> /dev/null | tr '\n' '|')"
  fi
}

log_present() {
  local desc="$1"
  if [ -e "$LOG" ] && [ -s "$LOG" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    hooks.log missing or empty -- a real hook call must still write it"
  fi
}

# =====================================================================================
echo "=== a genuinely empty project has no log before anything runs ==="
log_absent "no hooks.log before any call"

# =====================================================================================
echo ""
echo "=== jit-match.sh's sample call does not write to hooks.log ==="
bash "$MATCH" --base "$BASE" --text "xsd trouble" > /dev/null 2>&1
log_absent "hooks.log still does not exist after jit-match.sh"

# =====================================================================================
echo ""
echo "=== jit-dry-run.sh --prompt's sample call does not write to hooks.log ==="
bash "$DRYRUN" --base "$BASE" --prompt "xsd trouble" > /dev/null 2>&1
log_absent "hooks.log still does not exist after jit-dry-run.sh --prompt"

# =====================================================================================
echo ""
echo "=== jit-dry-run.sh --tool's sample call does not write to hooks.log ==="
bash "$DRYRUN" --base "$BASE" --tool Bash --command "git push origin main" > /dev/null 2>&1
log_absent "hooks.log still does not exist after jit-dry-run.sh --tool"

# =====================================================================================
echo ""
echo "=== jit-dry-run.sh --path's sample call does not write to hooks.log ==="
bash "$DRYRUN" --base "$BASE" --path "some/file.txt" > /dev/null 2>&1
log_absent "hooks.log still does not exist after jit-dry-run.sh --path"

# =====================================================================================
echo ""
echo "=== positive control: a REAL hook invocation still logs, so this is not silence ==="
printf '{"prompt":"xsd trouble"}' | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" > /dev/null 2>&1
log_present "a real (non-sample) hook call still writes hooks.log"

# =====================================================================================
echo ""
echo "=== summary ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
