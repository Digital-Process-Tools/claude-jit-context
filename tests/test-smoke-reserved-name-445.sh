#!/bin/bash
# #445: CLI 2.1.287's `claude plugin validate --strict` rejects `claude-jit-context`
# as a reserved name (claude-5h-window-spread #20 hit it first). smoke_release_tree.py
# lets exactly that error through as a ::warning::, and only when it is the ONLY error.
# Four cases, driven through run_validate() with a fake `claude`: reserved alone is a
# warning and passes; reserved plus another error fails; any other error fails; a clean
# validate passes with no warning.
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


r = run("alone", "\u2718 Found 1 error:\n\n  \u276f name: Plugin name \"claude-jit-context\" is "
        "reserved: it passes as one of Anthropic's own.\n\n\u2718 Validation failed\n", 1)
check("reserved name as the only error: run stays ok", r.ok, f"errors: {r.errors!r}")
check("and says so as a ::warning::", any("::warning::" in n for n in r.notes), f"notes: {r.notes!r}")

r = run("two", "\u2718 Found 2 errors:\n\n  \u276f name: Plugin name \"claude-x\" is reserved.\n"
        "  \u276f version: invalid\n\n\u2718 Validation failed\n", 1)
check("reserved name beside another error still fails", not r.ok, f"errors: {r.errors!r}")

r = run("other", "\u2718 Found 1 error:\n\n  \u276f version: invalid\n\n\u2718 Validation failed\n", 1)
check("any other validate failure still fails", not r.ok, f"errors: {r.errors!r}")

r = run("clean", "\u2714 Validation passed\n", 0)
check("a passing validate passes", r.ok, f"errors: {r.errors!r}")
check("with no warning", not any("::warning::" in n for n in r.notes), f"notes: {r.notes!r}")

# #448: the real v0.12.0 output. Warnings are also `❯` bullets, under their own
# heading, and counting every bullet read this as 7 errors.
WARN = ("  ❯ hooks.Stop: Shell command uses ${CLAUDE_PLUGIN_ROOT} without quotes: "
        "bash ${CLAUDE_PLUGIN_ROOT}/scripts/stop-hook.sh.\n")
V012 = ("Validating plugin manifest: /tmp/release-tree/.claude-plugin/plugin.json\n\n"
        "✘ Found 1 error:\n\n  ❯ name: Plugin name \"claude-jit-context\" is reserved: "
        "it passes as one of Anthropic's own.\n\n"
        "Validating hooks: /tmp/release-tree/hooks/hooks.json\n\n"
        "⚠ Found 6 warnings:\n\n" + WARN * 6 + "\n✘ Validation failed\n")
r = run("v012", V012, 1)
check("#448: reserved name plus 6 warnings (the real v0.12.0 output) stays ok", r.ok,
      f"errors: {r.errors!r}")
check("#448: and still warns", any("::warning::" in n for n in r.notes), f"notes: {r.notes!r}")

r = run("twofiles", "Validating plugin manifest: x\n\n✘ Found 1 error:\n\n"
        "  ❯ name: Plugin name \"claude-x\" is reserved.\n\n"
        "Validating hooks: y\n\n✘ Found 1 error:\n\n  ❯ hooks.Stop: invalid\n\n"
        "✘ Validation failed\n", 1)
check("#448: a second error in another file's block still fails", not r.ok,
      f"errors: {r.errors!r}")

print(f"== Results: {PASS} passed, {FAIL} failed ==")
sys.exit(1 if FAIL else 0)
PY
