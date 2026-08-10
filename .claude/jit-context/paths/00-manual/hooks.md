---
title: A hook may never fail hard
match: scripts/.*-hook\.sh$
---

These four scripts run in someone else's session, on every prompt and every tool call, often before they know this plugin exists.

**Every failure path exits `0` with nothing injected.** Missing config directory, unreadable entry, unparseable frontmatter, empty `tool_name`, empty stdin — each is a reason to say nothing, never a reason to error. `tests/run-all.sh` has explicit cases for empty input, empty `tool_name` and a missing config dir.

**Silence and "nothing to say" are not the same.** The tool dimension can block a call. If a rule cannot be evaluated, that must not render as an allow with no explanation — say so in what the hook injects.

**No new runtime dependencies.** `awk` and `perl` only. No `jq`, no Python, no Node. Dropping `jq` is most of what 0.2.0 was; adding one back is a breaking change, not a convenience.

Each script sources shared state first:

```bash
source "$(dirname "$0")/common.sh"    # JIT_BASE, _log_hook, optional config.env
```

Hooks read `.claude/jit-context/<dimension>/<layer>/00-index.tsv` — never the markdown frontmatter. One `awk` per hook is the whole runtime.

**Behaviour change: write the test first, watch it fail, then fix.** A test written after the fix asserts what the code happens to do.

```bash
bash tests/run-all.sh          # non-zero on any failure
```

CI runs Linux, macOS and shellcheck. The bash on macOS is not the bash on Linux — a green local run is not evidence about the other leg.
