# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

Both of these treat `.claude/jit-context/` as what it actually is: a directory that
arrives with the repository. The hooks run on the first prompt of a session, before
anyone has read the code they were cloned with, so every file under that directory is
attacker-controlled input rather than configuration the user wrote. Neither finding needs
the user to do anything beyond opening the project.

- **`config.env` was executed as shell on every prompt and every tool call.** `common.sh`
  dot-sourced it, so a repository shipping a `.claude/jit-context/config.env` ran whatever
  was in it. Reproduced: a file containing `echo … >&2` printed, and one containing
  `touch …` created the file.

  It is now read as data. One `KEY=VALUE` per line, `#` comments and blanks skipped,
  surrounding quotes stripped, a leading `export` accepted, and nothing inside a value
  expanded — the values reach the hooks through `printf -v`, never through `eval`.

  Only `JIT_CONTEXT_*`, `DYNAMIC_RULES_*` and `DVSI_*` are settable. An allowlist of plain
  shell identifiers would have been the obvious fix and would not have closed the hole:
  `PATH` is a plain identifier, `common.sh` runs before every hook invokes `awk`, and that
  is the same execution one hop removed.

  A line that is not a settable assignment is **refused** — logged, and named once per
  session in the injected context, with its line number and the reason but never its text,
  since the premise of the change is that the file may be hostile. Dropping it quietly was
  not an option: a setting that vanishes reads exactly like a setting that applied and did
  nothing, which is this repository's own recurring defect.

  That reporting channel had the defect it exists to report. The list is newline-separated
  and it first travelled to the hooks through `awk -v`, where a newline in the value is the
  fatal error "newline in string" — raised before the program runs, so the hook printed
  nothing whatsoever and still exited 0. **One** refused line has no separator and hid it
  completely; **two** silenced the hook. It goes through the environment now, and the suite
  covers the two-line case on all three hooks.

- **An index row could make a hook read any file on disk and inject it into context.** The
  entry file name from `00-index.tsv` was concatenated onto its layer directory with no
  containment check, so a committed row of `../../../../outside.txt` made the hook read
  that file and hand its contents to the model. Confirmed at all five read sites — the
  path rule loop, the tool rule loop, and the three vocabulary passes (prompt hook, tool
  hook, and the path hook's `01-paths.tsv`). Absolute paths do not traverse; they are
  prefixed and simply fail to open. Only the relative form worked, and `00-index.tsv` is a
  committed file, so cloning a repository was the whole attack.

  A name carrying `/`, carrying `\`, or equal to `.` or `..` is now refused, and named in
  the same once-per-session channel as a pattern the matcher cannot honour. The backslash
  is in that list for Windows: on Git Bash the file API underneath `awk` treats it as a
  separator, so `..\..\x` traverses there while being inert on Linux and macOS.

  Refusing anything that is not a bare file name is safe because `rebuild-tsv.sh` writes
  that column with `basename` at all four of its sites, and the generated-layer contract
  is the same TSV format — a name with a separator in it was never produced by this
  project.

  `scripts/jit-dry-run.sh` checks the same column, from the same shared `awk` function, so
  the "lint the tree that owns these rules" advice the refusal notice prints is true for
  this class too. It also sweeps the vocabulary indexes, which had never been linted at
  all because vocabulary carries no patterns — and which hold three of the five sites.

  A refused row is reported by **position** — `00-manual row 3` — and never by the text of
  its file-name column. That column is attacker-controlled free text whose only constraint
  is that it contains a separator, and the notice fires without any rule having matched, so
  echoing it back would be a prompt-injection channel needing no trigger at all. A row
  whose name *passes* the check cannot contain a separator, and an unhonourable **pattern**
  is still reported by file name, which is what an author fixing it needs.

  **This closes the string form and not the symlink form.** An entry file that is itself a
  symlink out of the tree still has its target read: the name in the index is bare, so it
  passes, and `getline` follows the link like any `open()`. `awk` cannot `lstat`, and the
  architecture is one `awk` process per hook with no per-row subprocess, so closing it is a
  design decision about where a tree walk belongs — not something to slip into this change.
  Tracked separately.

- **`tests/test-security.sh`** — new suite, red before either fix. Every "did not
  exfiltrate" case is paired with a positive control that a legitimate entry still fires,
  because a fix that broke entry loading outright would have satisfied the negative half
  on its own. The `config.env` cases are driven in both directions: `JIT_CONTEXT_VOCAB_PATHS=1`
  must still turn a feature on that is off by default, and asserting only that the hook
  printed valid JSON would have passed with `config.env` support deleted entirely.

### Fixed

- **This repository's own `entries.md` rule was anchored on a bare path fragment**, so
  it fired on every `.md` file whose path merely contained `jit-context/` — including
  the scratchpad directory a Claude Code session derives from the project name, which
  for this repo contains `claude-jit-context`. Observed firing on unrelated temporary
  files twice in one session. Anchored on `(\.claude|examples)/jit-context/` instead.
  A dogfood rule rather than a shipped one, but it is precisely the failure the entry
  itself warns about.

- **`tests/test-dogfood-entries.sh`** — new suite covering this repository's own
  entries, both directions for every rule: a path each must match, and a near-miss each
  must not. Every other suite builds a synthetic tree, which proves the engine works and
  says nothing about the rules we ship to ourselves. It carries a harness guard that
  fails loudly when the tree cannot be evaluated, because the first draft of this suite
  passed its silence assertions on an empty result.

- **The hooks now read JSON strings instead of splitting on quotes.** All three parsed
  their payload with `split(input, f, "\"")` and took the raw field, which was wrong
  twice, and both were silent.

  A value ended at the first **escaped** quote. `gh pr list --search \"a b\" --limit 20`
  reached the matcher as `gh pr list --search `, so a rule carrying `require: --limit`
  blocked a command that had `--limit` — but only when the flag sat after the quoted
  argument. Moving the same flag earlier "fixed" it, which is why this read as position
  sensitivity in a substring test. The `require` check is a plain `index()`; it was the
  subject that had been cut, not the test. (#7)

  And nothing was decoded. A multi-line Bash command arrives with its newlines as the two
  characters `\` and `n`, so a rule anchored `~(^|[;&|\n] *)` — where that escape is a
  real newline to awk — could not fire on one, ever. `&&` worked, a newline did not, and
  the log recorded the same "no match" either way. The same defect hid a `supertool` call
  on the second line from every path rule, and glued the word after a line break in a
  prompt onto an `n`, hiding it from vocabulary lookup. (#6)

  `\n`, `\t`, `\r`, `\b`, `\f`, `\"`, `\\` and `\/` are decoded. An escape awk cannot
  represent — `\uXXXX`, or anything undefined — is left exactly as written rather than
  swallowed: eating the backslash would hand the matcher a subject its author never typed.

  Nothing shipped depended on the old spelling. Every `match` in `examples/` and in this
  repo's own tree uses a backslash only to escape a literal `.` in a path pattern, which is
  unaffected.

- **A quoted argument spanning lines is not read as a command.** Issue #7 also reports a
  rule matching a `git commit` whose *message* quoted a command. Now that a command can
  hold real newlines, the quote that ends the command words is found once in the whole
  string rather than once per line — awk cannot see that a quote opened on line one is
  still open on line three, and the conservative reading is the one single-line commands
  already had. `~match`, `require` and `forbid` still see the whole command; that is what
  lets an anchored regex reach a later command at all. (#7)

- `scripts/jit-dry-run.sh` escapes its `--command`/`--file`/`--prompt` sample into the
  JSON it builds, so what you type is what the hooks see. An unescaped quote ended the
  value early and the tool reported "no rule fired" for a rule that fires — the exact
  confusion the script exists to remove — and an unescaped backslash was read back as a
  JSON escape, so `--file 'C:\test\x'` linted as `C:<TAB>est\x`. A real newline is folded
  to its escape, so a multi-line command can be pasted in and dry-run as one.

- **`split()` on a one-character separator also splits on a newline, on one-true-awk but
  not on gawk** — measured on `awk version 20200816` and `GNU Awk 5.4.1`. `pre-path-hook.sh`
  walks alternate fields of a single-quote split to lift paths out of `supertool`
  arguments, so on macOS and Git Bash a multi-line command produced one extra field,
  shifted that parity, and read every argument from the wrong side of the quote — while
  Linux was fine. The separator is now bracketed, which makes awk compile it as a regex
  and split on the quote alone, identically on both.

- **A `match` pattern the matcher cannot honour is refused at load, named, and skipped —
  instead of reading as enforced forever.** Every regex is compiled by awk, so it is a
  POSIX ERE; measured on `awk version 20200816`, `~gh\s+pr` compiles to `ghs+pr`, matches
  nothing, and **awk exits 0**. Exit status cannot see that defect, so the check is
  structural and deliberately engine-independent: a rule fires on the author's machine,
  not on the runner, and a lint whose answer changes with the local awk gates nothing.
  `\n` is the one escape rules need and keeps working. (#3)
- **One malformed row no longer silences every rule in its index.** `~a[b` is a fatal awk
  error raised mid-scan, so the `END` block never ran: no JSON, no injected context, no
  vocabulary pass, and no log line — while the hook still exited 0. Reproduced against
  both `pre-tool-hook.sh` and `pre-path-hook.sh`. The row is refused; the file survives.
  Refusing the whole index was considered and rejected — it converts one dead rule into
  all of them. (#3)
- A refused row is **reported**, not merely skipped. The log now carries `refused:FILE
  (reason)`, so `(none) [shown:0]` no longer covers both "nothing matched" and "nothing
  could be evaluated", and the hooks inject a one-line notice naming the rule, its mode
  and the construct, once per session. The log alone was not enough: that is exactly
  where two dead `block` rules sat unnoticed, one of them since it was written. (#3)

### Added

- **`scripts/jit-dry-run.sh`** — evaluate one tree's rules where they are written. Lints
  every pattern, prints which rule fires for a sample `--tool`/`--command`, `--file` or
  `--prompt`, and exits 0 clean, 1 refused, 2 could not evaluate. It reads the tree you
  are standing in, or `--base DIR`.

  This is the answer to #4. `JIT_BASE` resolves against `$CLAUDE_PROJECT_DIR`
  (`scripts/common.sh:7`), so a git worktree cannot load or test its own rules from a
  session rooted elsewhere, and nothing says so — four rules authored in a worktree on
  2026-08-10 were verifiable only by hand-running a hook with the variable overridden.
  The issue also proposed unioning a worktree's rules over the root's at runtime; that
  is deliberately **not** built. See the issue thread for the argument.

## [0.2.0] — First public release

The system had been running in production for months while its documentation still
described a design that no longer existed. This release makes the package match the code,
and publishes it.

### Published

- The repository is public, and CI runs on every push and pull request.
- README rebuilt around what the plugin is for rather than how it works: the receipt
  (1,000 entries, 2.58 MB in the project it was extracted from), five pillars, and the
  signal that tells a reader when to reach for it — the agent rediscovering something the
  team already knows.
- `.claude/jit-context/` — the repo now uses its own plugin across all three dimensions,
  including a `block` rule that refuses hand edits of a generated index.
- The layer table no longer advertises what is not shipped. `rebuild-tsv.sh` indexes
  `00-manual/` alone, while the hooks scan all four layers, so `10-auto/`, `20-grouped/`
  and `30-crosscutting/` work only when a generator writes its own `00-index.tsv`. No
  generator ships with this plugin.
- The `Bash` path-scanning section is framed as compatibility rather than a companion-tool
  plug: anything reaching a file outside the file tools carries no `file_path`, so path
  rules would go quiet with nothing in the log.

### Added

- **Vocabulary dimension**, triggered by keywords in the prompt via a `UserPromptSubmit`
  hook. It had existed and worked for months without appearing anywhere in the README.
- `scripts/session-start-hook.sh` — clears per-session `once` markers so rules fire fresh.
- `.claude/jit-context/config.env`, read by `common.sh`, for per-project settings.
  (It was *sourced* until the Security entry at the top of this file; that was the bug.)
  Settings:
  `DYNAMIC_RULES_MODULE_PREFIX`, `DYNAMIC_RULES_KEYWORD_BLACKLIST`,
  `DYNAMIC_RULES_VOCAB_PATHS`.
- `tests/run-all.sh` — one entry point, non-zero exit on any failure.
- GitHub Actions CI: the full suite on Linux and macOS, plus shellcheck.
- A vocabulary example. The dimension had no example at all.

### Changed

- **Rules are configured by YAML frontmatter in the `.md` file itself.** The previous
  `config.json` per directory is gone, along with the `jq` dependency. `rebuild-tsv.sh`
  parses frontmatter into `00-index.tsv`, and the hooks read only TSV — one `awk`
  process per hook, no JSON parsing at runtime. Typical hook time is 30–110 ms.
- Keyword matching is **space-bounded** after CamelCase splitting and lowercasing.
  Substring matching was the old behaviour and made short keywords fire on everything.
- The source-root prefix used for module path triggers is configurable and defaults to
  `src/`; it was hardcoded to one project's layout.
- `DVSI_AUTONOMOUS_VOCAB_PATHS` is renamed `DYNAMIC_RULES_VOCAB_PATHS`. The old name is
  still honoured so existing runners do not break silently.
- README rewritten. The previous one documented the removed `config.json` format, listed
  `jq` as a requirement, and never mentioned the vocabulary dimension.

### Fixed

- Examples carried no frontmatter, so every shipped example was inert on arrival.
- A keyword containing dots or slashes could never match, because the matcher strips
  those characters from the prompt before comparing. `rebuild-tsv.sh` now normalizes
  keywords identically at build time.
- shellcheck warnings across `rebuild-tsv.sh` (SC2034, SC2155, SC2188).

## [0.1.0]

Initial internal version: tool and path rules, configured through `config.json`.
