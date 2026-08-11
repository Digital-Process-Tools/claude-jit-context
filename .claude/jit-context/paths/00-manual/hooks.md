---
title: A hook may never fail hard
match: scripts/.*-hook\.sh$
---

These four scripts run in someone else's session, on every prompt and every tool call, often before they know this plugin exists.

**Every failure path exits `0` with nothing injected.** Missing config directory, unreadable entry, unparseable frontmatter, empty `tool_name`, empty stdin — each is a reason to say nothing, never a reason to error. `tests/run-all.sh` has explicit cases for empty input, empty `tool_name` and a missing config dir.

**Silence and "nothing to say" are not the same.** The tool dimension can block a call. If a rule cannot be evaluated, that must not render as an allow with no explanation — say so in what the hook injects. Implemented: `jit_bad_pattern()` in `common.sh` refuses the ROW, never the file, and both hooks name it in the log and once per session in context. Refusing the file was rejected — a malformed pattern is fatal to the whole awk, which is the bug, not the fix.

**No new runtime dependencies.** `awk` and `perl` only. No `jq`, no Python, no Node. Dropping `jq` is most of what 0.2.0 was; adding one back is a breaking change, not a convenience.

Each script sources shared state first:

```bash
source "$(dirname "$0")/common.sh"    # JIT_BASE, _log_hook, optional config.env
```

Hooks read `.claude/jit-context/<dimension>/<layer>/00-index.tsv` — never the markdown frontmatter. One `awk` per hook is the whole runtime.

**Read the payload with `jit_json_fields()` + `jit_unescape()` from `common.sh`, never a bare `split(input, f, "\"")`.** A bare split ends a value at the first *escaped* quote and decodes nothing, so a multi-line command reaches the matcher with its newlines still spelled backslash-n and an anchored rule cannot fire on it. Decode only the values the hook keeps — a `Write` payload carries the whole file body in `tool_input.content`.

One awk trap, measured on both `awk version 20200816` and `GNU Awk 5.4.1` because the two disagree: **`split()` on a one-character separator also splits on newlines** — one-true-awk does, gawk does not. Any walk over alternate fields (the single-quote split that lifts paths out of `supertool` arguments) then reads its arguments from the wrong side of the separator on one platform and not the other. Bracket the separator — `"[\047]"` — and awk compiles a regex, which splits on that character alone everywhere.

Both engines agree that regex `.` **does** match a newline: `gsub(/[;&|].*/)` on `a;b<NL>c;d` gives `a` on each. Do not assume otherwise — an earlier draft of this file did, and the reasoning built on it was wrong in the safe direction only by luck.

**Behaviour change: write the test first, watch it fail, then fix.** A test written after the fix asserts what the code happens to do.

```bash
bash tests/run-all.sh          # non-zero on any failure
```

CI runs Linux, macOS, **Windows** (Git Bash) and shellcheck. The bash on macOS is not the bash on Linux, and neither is Git Bash — a green local run is not evidence about the other legs. The awks differ too: gawk honours `\s`, one-true-awk drops it, which is why the pattern guard is structural and never a compile probe.
