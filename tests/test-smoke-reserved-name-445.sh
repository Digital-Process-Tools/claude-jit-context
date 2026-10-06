#!/bin/bash
# #455: #445/#448's reserved-name exception in smoke_release_tree.py is now stale --
# #452 renamed the plugin from claude-jit-context to jit-context, so `claude plugin
# validate --strict` no longer reports the reserved-name error this exception existed
# to downgrade. #455 also found the exception's own heading parser could mask a SECOND
# real error whose heading did not match the regex it expected. Removing the whole
# exception settles both at once: a future validate failure of ANY kind -- reserved-name
# shaped or not, recognized heading or not -- now fails the smoke test outright, rather
# than carrying forward dead code whose only remaining effect would be to (incompletely)
# mask some unrelated error that happens to be the sole bullet under whatever heading it
# checked for.
#
# This file used to assert the exception's OWN behavior (#445/#448); it was rewritten by
# #455 to assert the exception is gone, not merely that its old behavior still holds.
#
# Usage: bash tests/test-smoke-reserved-name-445.sh
#
# jit-drive: none -- this drives a function inside smoke_release_tree.py, not a hook.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE="$REPO/.github/scripts/smoke_release_tree.py"

[ -f "$SMOKE" ] || {
  echo "FAIL: harness guard -- $SMOKE does not exist, every assertion below is vacuous"
  exit 1
}
if ! command -v python3 > /dev/null 2>&1; then
  echo "SKIPPED: no python3 on PATH -- this script is not part of the hook runtime"
  exit 2
fi

echo "=== #455: no trace of the removed reserved-name exception remains in the source ==="
if grep -q "_only_reserved_name_error" "$SMOKE"; then
  echo "  FAIL: _only_reserved_name_error still referenced in $SMOKE"
  STATIC_FAIL=1
else
  echo "  PASS: _only_reserved_name_error is gone from $SMOKE"
  STATIC_FAIL=0
fi

python3 - "$SMOKE" << 'PY'
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

if not os.path.exists("/bin/sh"):
    # The fake `claude` below is a shebang script; a native Windows python3 cannot
    # exec it. Same probe as test-release-branch-437.sh's smoke skip.
    print("  SKIPPED: this python3 cannot see /bin/sh, so a shebang fake `claude` cannot run here")
    sys.exit(2)

spec = importlib.util.spec_from_file_location("smoke_release_tree", sys.argv[1])
smoke = importlib.util.module_from_spec(spec)
sys.modules["smoke_release_tree"] = smoke
spec.loader.exec_module(smoke)

PASS = FAIL = 0
tmp = Path(tempfile.mkdtemp())


def check(desc, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS: {desc}")
    else:
        FAIL += 1
        print(f"  FAIL: {desc}")
        if detail:
            print(f"    {detail}")


def run(name, output, code):
    fake = tmp / f"claude-{name}"
    fake.write_text("#!/usr/bin/env python3\nimport sys\n"
                    f"sys.stdout.write({output!r})\nsys.exit({code})\n", encoding="utf-8")
    fake.chmod(0o755)
    result = smoke.SmokeResult()
    smoke.run_validate(tmp, "require", str(fake), tmp, result)
    return result


# #455 problem 2: the plugin is renamed (#452) -- a reserved-name-shaped error must now
# fail like any other validate error, never be let through as a warning.
r = run("alone", "✘ Found 1 error:\n\n  ❯ name: Plugin name \"claude-jit-context\" is "
        "reserved: it passes as one of Anthropic's own.\n\n✘ Validation failed\n", 1)
check("a reserved-name-shaped error now fails -- the exception is really gone", not r.ok,
      f"errors: {r.errors!r}")
check("and raises no ::warning:: carve-out for it", not any("::warning::" in n for n in r.notes),
      f"notes: {r.notes!r}")

r = run("two", "✘ Found 2 errors:\n\n  ❯ name: Plugin name \"claude-x\" is reserved.\n"
        "  ❯ version: invalid\n\n✘ Validation failed\n", 1)
check("reserved name beside another error still fails", not r.ok, f"errors: {r.errors!r}")

r = run("other", "✘ Found 1 error:\n\n  ❯ version: invalid\n\n✘ Validation failed\n", 1)
check("any other validate failure still fails", not r.ok, f"errors: {r.errors!r}")

r = run("clean", "✔ Validation passed\n", 0)
check("a passing validate passes", r.ok, f"errors: {r.errors!r}")
check("with no warning", not any("::warning::" in n for n in r.notes), f"notes: {r.notes!r}")

# #455 problem 1: a second error block whose own heading does not match the old parser's
# regex (e.g. a per-file heading like "Found 1 error in hooks.json:") used to be able to
# slip past uncounted. With the whole exception removed there is no heading parsing left
# to fool -- ANY non-zero exit fails, regardless of what the output looks like.
r = run("oddheading", "✘ Found 1 error in hooks.json:\n\n  ❯ hooks.Stop: invalid\n\n"
        "✘ Validation failed\n", 1)
check("#455 problem 1: an unrecognized per-file heading still fails (nothing to fool anymore)",
      not r.ok, f"errors: {r.errors!r}")

print(f"== Results: {PASS} passed, {FAIL} failed ==")
sys.exit(1 if FAIL else 0)
PY
PY_STATUS=$?

[ "$STATIC_FAIL" -eq 0 ] && [ "$PY_STATUS" -eq 0 ]
