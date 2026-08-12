---
title: A hook may never fail hard
match: (^|/)scripts/(.*-hook|common)\.sh$
---

These five scripts run in someone else's session, on every prompt and every tool call, often before they know this plugin exists — the four hooks, and `common.sh`, which is sourced by all four and is where every containment fix in 0.3.0 landed. Everything below applies to `common.sh` verbatim; it is executed by the hooks, not beside them.

`rebuild-tsv.sh`, `jit-dry-run.sh` and `jit-misses.sh` also live in `scripts/` and are **not** governed by this file — they never run in a stranger's session and are expected to fail loudly. See `paths/00-manual/tooling.md`.

**Every failure path exits `0` with nothing injected.** Missing config directory, unreadable entry, unparseable frontmatter, empty `tool_name`, empty stdin — each is a reason to say nothing, never a reason to error. `tests/run-all.sh` has explicit cases for empty input, empty `tool_name` and a missing config dir.

**Silence and "nothing to say" are not the same.** The tool dimension can block a call. If a rule cannot be evaluated, that must not render as an allow with no explanation — say so in what the hook injects. Implemented: `jit_bad_pattern()` in `common.sh` refuses the ROW, never the file, and both hooks name it in the log and once per session in context. Refusing the file was rejected — a malformed pattern is fatal to the whole awk, which is the bug, not the fix.

**`.claude/jit-context/` is attacker-controlled input, not configuration.** It arrives with the repository, and these hooks run before anyone has read the code they cloned. So `config.env` is parsed as `KEY=VALUE` and never sourced, and an entry file name from an index row is refused unless it is bare — `jit_bad_entry_file()` in `common.sh`. Both were live: a `config.env` of `touch …` created the file, and a row of `../../../../x` made the hook read that file and inject it, at all five concatenation sites. Add a sixth site and it needs the same check.

**No new runtime dependencies.** `awk` and `perl` only. No `jq`, no Python, no Node. Dropping `jq` is most of what 0.2.0 was; adding one back is a breaking change, not a convenience.

Each script sources shared state first:

```bash
source "$(dirname "$0")/common.sh"    # JIT_BASE, _log_hook, config.env parsed as data
```

Hooks read `.claude/jit-context/<dimension>/<layer>/00-index.tsv` — never the markdown frontmatter. One `awk` per hook is the whole runtime.

**Read the payload with `jit_json_fields()` + `jit_unescape()` from `common.sh`, never a bare `split(input, f, "\"")`.** A bare split ends a value at the first *escaped* quote and decodes nothing, so a multi-line command reaches the matcher with its newlines still spelled backslash-n and an anchored rule cannot fire on it. Decode only the values the hook keeps — a `Write` payload carries the whole file body in `tool_input.content`.

One awk trap, measured on both `awk version 20200816` and `GNU Awk 5.4.1` because the two disagree: **`split()` on a one-character separator also splits on newlines** — one-true-awk does, gawk does not. Any walk over alternate fields (the single-quote split that lifts paths out of `supertool` arguments) then reads its arguments from the wrong side of the separator on one platform and not the other. Bracket the separator — `"[\047]"` — and awk compiles a regex, which splits on that character alone everywhere.

**Never match a regex against a single character.** `c ~ /[A-Z]/` inside a `for` over `substr(s, i, 1)` is a multibyte decode, and one character of a UTF-8 string is one *byte* to one-true-awk: a lone continuation byte raises `towc: multibyte conversion failure`, which aborts the whole `END` block — the hook prints nothing and still exits 0, so it reads as having had nothing to say. Measured: `détail de la facturation` matched no vocabulary entry under `awk version 20200816` and matched under gawk. Use `index("ABC…XYZ", c) > 0` instead; it is a byte search with no decode, and no byte of a multibyte sequence is ever an ASCII letter or digit, so the verdict is unchanged. Mind that `index(s, "")` returns 1 — an empty operand needs its own guard.

**gawk is NUL-transparent; one-true-awk is not.** An embedded `\0` in an entry body reaches the buffer intact under gawk and truncates the line under one-true-awk, which also cannot build a one-byte NUL with `sprintf("%c", 0)`. Anything walking the C0 range must start at 0 *and* skip what the engine cannot represent — `index(s, "")` returns 1, so an unguarded pass hands `gsub` an empty regex that matches at every position. A `$( )` capture in a test cannot see any of this: bash silently drops NUL bytes, so an assertion reading a captured variable passes against output that contains a raw `0x00`. Write the hook output to a file and check the file.

That is the third defect of this shape found here, so the suites now run their assertions **once per `awk` on the machine**, through a `PATH` shim built from `command -v awk gawk nawk mawk`. Add an engine-sensitive assertion to that loop, not beside it.

Both engines agree that regex `.` **does** match a newline: `gsub(/[;&|].*/)` on `a;b<NL>c;d` gives `a` on each. Do not assume otherwise — an earlier draft of this file did, and the reasoning built on it was wrong in the safe direction only by luck.

**Behaviour change: write the test first, watch it fail, then fix.** A test written after the fix asserts what the code happens to do.

```bash
bash tests/run-all.sh          # non-zero on any failure
```

CI runs Linux, macOS, **Windows** (Git Bash) and shellcheck. The bash on macOS is not the bash on Linux, and neither is Git Bash — a green local run is not evidence about the other legs. The awks differ too: gawk honours `\s`, one-true-awk drops it, which is why the pattern guard is structural and never a compile probe.
