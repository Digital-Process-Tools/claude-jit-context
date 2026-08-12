---
title: A hook may never fail hard
match: (^|/)scripts/(.*-hook|common)\.sh$
---

These five scripts run in someone else's session, on every prompt and every tool call, often before they know this plugin exists — the four hooks, and `common.sh`, which is sourced by all four and is where every containment fix in 0.3.0 landed. Everything below applies to `common.sh` verbatim; it is executed by the hooks, not beside them.

`rebuild-tsv.sh`, `jit-dry-run.sh` and `jit-misses.sh` also live in `scripts/` and are **not** governed by this file — they never run in a stranger's session and are expected to fail loudly. See `paths/00-manual/tooling.md`.

**Every failure path exits `0` with nothing injected.** Missing config directory, unreadable entry, unparseable frontmatter, empty `tool_name`, empty stdin — each is a reason to say nothing, never a reason to error. `tests/run-all.sh` has explicit cases for empty input, empty `tool_name` and a missing config dir.

**Silence and "nothing to say" are not the same.** The tool dimension can block a call. If a rule cannot be evaluated, that must not render as an allow with no explanation — say so in what the hook injects. Implemented: `jit_bad_pattern()` in `common.sh` refuses the ROW, never the file, and both hooks name it in the log and once per session in context. Refusing the file was rejected — a malformed pattern is fatal to the whole awk, which is the bug, not the fix.

**`.claude/jit-context/` is attacker-controlled input, not configuration.** It arrives with the repository, and these hooks run before anyone has read the code they cloned. So `config.env` is parsed as `KEY=VALUE` and never sourced, and an entry file name from an index row is refused unless it is bare — `jit_bad_entry_file()` in `common.sh`. Both were live: a `config.env` of `touch …` created the file, and a row of `../../../../x` made the hook read that file and inject it, at all five concatenation sites. Add a sixth site and it needs the same check.

**A scratch file gets its name from `mktemp`, and its exit status is stated.** Each hook needs one temp file that awk writes and bash reads back. It used to be `/tmp/claude-path-log-$$.tmp` — a pid is not a secret, `/tmp` is world-writable, and awk's `> log_tmp` truncates and follows a symlink with no way to lstat first, so a pre-created link meant a file outside the project got emptied and filled with a log line (#60). `jit_tmp_open()` in `common.sh` is the only route: `mktemp` creates with `O_EXCL` under an unpredictable name, an `EXIT` trap in the creating process is the only remover (never a wildcard sweep — that was #43), and a platform that cannot give one leaves `$JIT_TMP` empty, which every awk guards with `if (log_tmp != "")` because an unopenable redirect is fatal inside `END`. `[ -L ]` before the write was rejected: check-then-act on a world-writable directory is the one race that is cheap to win. And each hook now ends in a literal `exit 0` — the status used to be whatever the last command left behind, which was `rm -f` and 0 by accident; the moment that line moved, a read-only `.discovery` made the hook exit 1.

**That scratch file has two regions, and the boundary between them is not optional.** Marks come first — one `path<TAB>key` per line — then the sentinel `$JIT_MARK_END`, then the log line. bash stops reading marks at the first sentinel. The order is the point: every hook's log line **ends** with a field lifted out of the tool payload after `jit_unescape()`, so a JSON `\n` is a real newline by the time it is written, and while the marks sat *after* the log line a `Read` payload could forge one — marking a `block` rule already-shown so it silently did not fire (#65). Anything you add to a log line goes through `jit_log_text()`, which strips `\n` and `\r` **before** the truncation, and any new field goes at the end of the log line and never between `jit_shown_flush()` and it. A channel with no sentinel applies no marks at all, which costs dedup and never a rule.

**No new runtime dependencies.** `awk` and `perl` only. No `jq`, no Python, no Node. Dropping `jq` is most of what 0.2.0 was; adding one back is a breaking change, not a convenience.

Each script sources shared state first:

```bash
source "$(dirname "$0")/common.sh"    # JIT_BASE, _log_hook, config.env parsed as data
```

Hooks read `.claude/jit-context/<dimension>/<layer>/00-index.tsv` — never the markdown frontmatter. One `awk` per hook is the whole runtime.

**Read the payload with `jit_json_fields()` + `jit_unescape()` from `common.sh`, never a bare `split(input, f, "\"")`.** A bare split ends a value at the first *escaped* quote and decodes nothing, so a multi-line command reaches the matcher with its newlines still spelled backslash-n and an anchored rule cannot fire on it. Decode only the values the hook keeps — a `Write` payload carries the whole file body in `tool_input.content`.

One awk trap, measured on both `awk version 20200816` and `GNU Awk 5.4.1` because the two disagree: **`split()` on a one-character separator also splits on newlines** — one-true-awk does, gawk does not. Any walk over alternate fields (the single-quote split that lifts paths out of `supertool` arguments) then reads its arguments from the wrong side of the separator on one platform and not the other. Bracket the separator — `"[\047]"` — and awk compiles a regex, which splits on that character alone everywhere.

**Never match a regex against a single character.** `c ~ /[A-Z]/` inside a `for` over `substr(s, i, 1)` is a multibyte decode, and one character of a UTF-8 string is one *byte* to one-true-awk: a lone continuation byte raises `towc: multibyte conversion failure`, which aborts the whole `END` block — the hook prints nothing and still exits 0, so it reads as having had nothing to say. Measured: `détail de la facturation` matched no vocabulary entry under `awk version 20200816` and matched under gawk. Use `index("ABC…XYZ", c) > 0` instead; it is a byte search with no decode, and no byte of a multibyte sequence is ever an ASCII letter or digit, so the verdict is unchanged. Mind that `index(s, "")` returns 1 — an empty operand needs its own guard.

**The hook awks run under `LC_ALL=C`, and that is load-bearing.** The rule above is about one character; this is its whole-record neighbour. A `tolower()` or `gsub()` over a record that is not valid UTF-8 aborts one-true-awk's `END` block with `illegal byte sequence` — nothing on stdout, not even `{}`, the diagnostic in the session, exit 0 — and makes gawk print `Invalid multibyte data detected` (#68). A lone `0xE9` from a Latin-1 paste, or a sequence cut at a copy boundary, is enough; on the tool hook it defeated a `block` rule. Under `C` both engines read bytes and have nothing to decode. The cost is that `tolower()` no longer folds non-ASCII, which is why the Latin-1 table in `JIT_AWK_FOLD` carries **both** cases: a fold table that only lists lowercase forms is dead under `C`. Check any new normalisation against that table rather than assuming, and keep the pin on the `awk` invocation — `rebuild-tsv.sh` has the opposite contract and its own locale.

**gawk is NUL-transparent; one-true-awk is not.** An embedded `\0` in an entry body reaches the buffer intact under gawk and truncates the line under one-true-awk, which also cannot build a one-byte NUL with `sprintf("%c", 0)`. Anything walking the C0 range must start at 0 *and* skip what the engine cannot represent — `index(s, "")` returns 1, so an unguarded pass hands `gsub` an empty regex that matches at every position. A `$( )` capture in a test cannot see any of this: bash silently drops NUL bytes, so an assertion reading a captured variable passes against output that contains a raw `0x00`. Write the hook output to a file and check the file.

That is the third defect of this shape found here, so the suites now run their assertions **once per `awk` on the machine**, through a `PATH` shim built from `command -v awk gawk nawk mawk`. Add an engine-sensitive assertion to that loop, not beside it.

Both engines agree that regex `.` **does** match a newline: `gsub(/[;&|].*/)` on `a;b<NL>c;d` gives `a` on each. Do not assume otherwise — an earlier draft of this file did, and the reasoning built on it was wrong in the safe direction only by luck.

**Behaviour change: write the test first, watch it fail, then fix.** A test written after the fix asserts what the code happens to do.

```bash
bash tests/run-all.sh          # non-zero on any failure
```

CI runs Linux, macOS, **Windows** (Git Bash) and shellcheck. The bash on macOS is not the bash on Linux, and neither is Git Bash — a green local run is not evidence about the other legs. The awks differ too: gawk honours `\s`, one-true-awk drops it, which is why the pattern guard is structural and never a compile probe.
