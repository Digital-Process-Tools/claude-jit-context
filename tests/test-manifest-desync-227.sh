#!/bin/bash
# Tests for #227: jit_blk_manifest_ok (common.sh) is set by jit_split_ctx_blocks() and
# was read by nobody, so a block manifest that failed to verify degraded silently in
# both consumers -- jit-match.sh and jit-dry-run.sh both kept their normal exit code,
# and the tool whose whole job is telling a verified match from a forged one said
# nothing about having fallen back to the forgeable splitter.
#
# Neither consumer can be driven into a genuine "manifest attempted, then failed to
# verify" state through an entry body alone -- that is the point of #226, fixed in the
# same change: the decoder no longer desyncs a genuine manifest through ordinary prose.
# So this suite forces the desync structurally instead, in a SCRATCH COPY of scripts/
# with one line of common.sh patched (the line that sets jit_blk_manifest_ok = 1 once a
# manifest header parses) so the manifest that would otherwise verify is reported as
# broken. This exercises the actual notice/NOTE/exit-code wiring in both consumers
# against a real hook run, on real fixtures, rather than asserting against a hand-built
# string -- see changelog.d/227.fixed.md for the same check run by hand before this
# suite existed.
#
# A second section is the control this repository keeps needing: #227's own review
# found that pre-tool-hook.sh and pre-path-hook.sh never build a manifest header at all,
# so gating the desync report on jit_blk_manifest_ok alone would have reported every
# genuine tool/path match as "could not evaluate". jit_blk_manifest_seen is the flag
# that keeps that from happening, and this suite pins it directly: a real path-matched
# vocabulary entry, which never had a manifest to begin with, must NOT be reported as a
# desync by either consumer.
#
# jit-drive: none -- every assertion here checks an exit code and a fixed literal notice
# string against a real subprocess run, inline with if/grep rather than through a shared
# helper function -- there is no payload-driven helper here for the harness to drive.
#
# Usage: bash tests/test-manifest-desync-227.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

TMP="$(mktemp -d 2>/dev/null)" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "  SKIPPED: mktemp -d produced no directory, so no fixture can be built here."
  exit 2
fi
trap 'rm -rf "$TMP"' EXIT

IDXNAME="00-index"
IDXNAME="$IDXNAME.tsv"

# --- A scratch copy of scripts/, with one line of common.sh patched so a manifest that
# would otherwise verify is instead reported as failed. Everything else -- the hooks,
# jit-match.sh, jit-dry-run.sh -- is the real, unmodified code, run against a real
# fixture; only the verdict jit_split_ctx_blocks() reaches about that fixture is forced.
FORCED="$TMP/forced-scripts"
mkdir -p "$FORCED"
cp "$REPO"/scripts/*.sh "$FORCED/"
if ! grep -q '        jit_blk_manifest_ok = 1$' "$FORCED/common.sh"; then
  echo "  SKIPPED: common.sh's jit_split_ctx_blocks() no longer sets jit_blk_manifest_ok"
  echo "           on the line this suite patches -- it may have been reshaped."
  exit 2
fi
perl -0777 -pi -e 's/(        jit_blk_manifest_ok = 1\n)/$1        jit_blk_manifest_ok = 0  # test-forced desync, #227\n/' "$FORCED/common.sh"

build_project() {
  local base="$1"
  mkdir -p "$base/paths/00-manual" "$base/tools/00-manual" "$base/vocabulary/00-manual"
  : > "$base/paths/00-manual/$IDXNAME"
  : > "$base/tools/00-manual/$IDXNAME"
  : > "$base/vocabulary/00-manual/$IDXNAME"
}

# =====================================================================================
echo "=== a genuine entry, forced manifest failure: jit-match.sh names the degrade, never fails hard ==="
FPROJ="$TMP/forced-proj"
FBASE="$FPROJ/.claude/jit-context"
build_project "$FBASE"
printf 'trickykw\ttricky.md\n' > "$FBASE/vocabulary/00-manual/$IDXNAME"
printf 'trickykw appears here, ordinary entry, nothing adversarial in it\n' > "$FBASE/vocabulary/00-manual/tricky.md"

OUT=$(bash "$FORCED/jit-match.sh" --base "$FBASE" --text "trickykw appears here" 2>/dev/null)
ST=$?
if [ "$ST" != 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: jit-match.sh moves off exit 0 when the manifest fails to verify (exit $ST)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: jit-match.sh stayed at exit 0 with a forced manifest failure"
fi
if grep -qF "the block manifest could not be evaluated" <<<"$OUT"; then
  PASS=$((PASS + 1)); echo "  PASS: jit-match.sh names the degrade as a notice"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: jit-match.sh did not name the degrade"
  echo "    got: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-400)"
fi
if grep -qF "trickykw appears here" <<<"$OUT"; then
  PASS=$((PASS + 1)); echo "  PASS: the genuine entry text still rides along (never fails hard)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the entry text was lost, not merely degraded"
fi

# =====================================================================================
echo ""
echo "=== the SAME entry, unpatched scripts: the control, proving the assertions above are not vacuous ==="
OUT=$(bash "$REPO/scripts/jit-match.sh" --base "$FBASE" --text "trickykw appears here" 2>/dev/null)
ST=$?
if [ "$ST" = 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: the real, unpatched jit-match.sh exits 0 on the same fixture"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the real jit-match.sh did not exit 0 (exit $ST) -- the fixture itself is broken"
fi
if grep -qF "the block manifest could not be evaluated" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the unpatched hook reports a desync on a genuine entry -- the control is not clean"
else
  PASS=$((PASS + 1)); echo "  PASS: the unpatched hook reports no desync on a genuine entry"
fi

# =====================================================================================
echo ""
echo "=== a genuine entry, forced manifest failure: jit-dry-run.sh prints a NOTE and fails loudly ==="
OUT=$(CLAUDE_PROJECT_DIR="$FPROJ" bash "$FORCED/jit-dry-run.sh" --base "$FBASE" --prompt "trickykw appears here" 2>&1)
ST=$?
if [ "$ST" != 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: jit-dry-run.sh moves off exit 0 when the manifest fails to verify (exit $ST)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: jit-dry-run.sh stayed at exit 0 with a forced manifest failure"
fi
if grep -qF "the block manifest failed to verify" <<<"$OUT"; then
  PASS=$((PASS + 1)); echo "  PASS: jit-dry-run.sh prints a NOTE naming the degrade"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: jit-dry-run.sh did not print the NOTE"
  echo "    got: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-400)"
fi

# =====================================================================================
echo ""
echo "=== the SAME entry, unpatched scripts: the control for jit-dry-run.sh ==="
OUT=$(CLAUDE_PROJECT_DIR="$FPROJ" bash "$REPO/scripts/jit-dry-run.sh" --base "$FBASE" --prompt "trickykw appears here" 2>&1)
ST=$?
if [ "$ST" = 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: the real, unpatched jit-dry-run.sh exits 0 on the same fixture"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the real jit-dry-run.sh did not exit 0 (exit $ST) -- the fixture itself is broken"
fi
if grep -qF "the block manifest failed to verify" <<<"$OUT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL: the unpatched hook reports a desync on a genuine entry -- the control is not clean"
else
  PASS=$((PASS + 1)); echo "  PASS: the unpatched hook reports no desync on a genuine entry"
fi

# =====================================================================================
echo ""
echo "=== jit_blk_manifest_seen: a hook that never builds a manifest at all must NOT read as a desync ==="
# pre-path-hook.sh's vocabulary-by-path branch never emits a "# JIT-CTX-BLOCKS " header
# at all (a separate, filed-not-fixed gap) -- jit_blk_manifest_seen is 0 for it, and
# both consumers gate the #227 desync report on manifest_seen && !manifest_ok, never on
# !manifest_ok alone, so this must exit clean rather than reporting "could not evaluate".
PPROJ="$TMP/path-proj"
PBASE="$PPROJ/.claude/jit-context"
build_project "$PBASE"
printf 'secret.txt\treal-path-vocab.md\n' > "$PBASE/vocabulary/00-manual/01-paths.tsv"
printf 'real vocabulary content matched by path\n' > "$PBASE/vocabulary/00-manual/real-path-vocab.md"

OUT=$(JIT_CONTEXT_VOCAB_PATHS=1 CLAUDE_PROJECT_DIR="$PPROJ" bash "$REPO/scripts/jit-dry-run.sh" --base "$PBASE" --file "config.secret.txt" 2>&1)
ST=$?
if [ "$ST" = 0 ]; then
  PASS=$((PASS + 1)); echo "  PASS: a manifest-less path match still exits 0 (jit_blk_manifest_seen keeps this out of #227's report)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: a manifest-less path match moved off exit 0 (exit $ST) -- jit_blk_manifest_seen is not doing its job"
  echo "    got: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-400)"
fi
if grep -qF "real-path-vocab.md" <<<"$OUT"; then
  PASS=$((PASS + 1)); echo "  PASS: the path-matched entry is still named"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: the path-matched entry was not named"
fi

# =====================================================================================
echo ""
echo "========================"
echo "  $PASS/$((PASS + FAIL)) passed, $FAIL failed"
echo "========================"

[ "$FAIL" -eq 0 ]
