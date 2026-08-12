# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

All three of these treat `.claude/jit-context/` as what it actually is: a directory that
arrives with the repository. The hooks run on the first prompt of a session, before
anyone has read the code they were cloned with, so every file under that directory is
attacker-controlled input rather than configuration the user wrote. None of them needs
the user to do anything beyond opening the project.

- **A dot-named entry file walked straight past the symbolic-link check.** The sweep that
  `lstat`s the tree enumerates it with `*`, `*/*` and `*/*/*`, and a glob `*` does not match
  a leading dot — so `.hidden.md` was never `lstat`ed, never entered the link set, and the
  awk side cleared it. A link named `hidden.md` was refused; the identical link named
  `.hidden.md` was read and its target injected. `common.sh` stated that exact glob property
  about `.discovery` six lines below the sweep and did not apply it to the sweep.

  `jit-dry-run.sh` ran the same blind sweep, so the linter reported the hostile tree `ok`
  and exited 0 — the tool the refusal notice sends the reader to said the attack was
  honourable. That is what made this a release blocker rather than a bug.

  Both halves are fixed, because they fail differently. **The sweep now globs the dot forms
  too** at every depth, with `.` and `..` dropped, so nothing under the tree escapes the
  `lstat` by being named after it. **And an entry file name beginning with a dot is refused
  outright**, by name, so the verdict holds without an `lstat` at all — `rebuild-tsv.sh`
  writes that column from a `*.md` glob, which cannot produce a dot-name, so no honest entry
  is affected.

  No wider constraint on the name was adopted. `^[A-Za-z0-9._-]+\.md$` was proposed to close
  this and the notice-quoting issue below in one stroke, and it closes neither: every
  character of `.hidden.md` is in that class, and so is a whole English sentence of dots and
  hyphens. What it does refuse is `café.md` and `my rule.md` — a working tree breaking on
  upgrade, in exchange for nothing. Both directions are pinned in the suite.

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

  **This closes the string form.** The symlink form was closed separately, below.

- **An entry file that is a symlink out of the tree had its target read and injected.**
  The containment check above stops a row from *naming* a path outside its layer; it does
  not stop the entry file from *being* a link to one. The name in the index is bare, so it
  passes every check, and `getline` follows the link like any `open()`. Reproduced at all
  five read sites, and again with every directory on the way to one linked instead: the
  **layer directory**, the dimension directory, `.claude/jit-context/`, and `.claude/`
  itself. Each of those needs nothing inside the repository but the one link, because the
  linked directory carries its own `00-index.tsv`. `git clone` recreates all of them, so
  cloning a repository is the whole attack.

  Nothing on the way to an entry may now be a symbolic link — the entry file, its layer,
  its dimension, `.claude/jit-context/` or `.claude/` — and each is refused and named in the
  same once-per-session channel as the other two classes. The verdict is structural rather
  than a resolution: a link is refused whether or not its target is inside the tree, because
  `awk` has no `realpath` and buying one costs a process per row. An entry that needs to
  live elsewhere is a copy, or a generated layer, not a link.

  The walk stops one directory above `.claude/jit-context/` and does not climb to the
  filesystem root. Above the project is the user's own filesystem rather than anything the
  clone chose, and on macOS `/tmp` is itself a symlink — a sweep that walked all the way up
  would refuse every honest tree opened through one.

  `awk` cannot `lstat`, and the architecture is deliberately one `awk` process per hook
  with no per-row subprocess. So the `lstat` is paid **once per hook invocation** — a glob
  and a `[ -L ]` test in `common.sh`, both shell builtins, forking nothing. Measured
  against the 1,000-entry corpus the README cites: **31 ms before, 43 ms after**. On a tree
  of a few dozen entries the difference is below the noise floor of the measurement.

  Every hook runs its own sweep. Nothing is cached to a marker and nothing is carried
  between hooks: the obvious cheaper design is one tree walk in `session-start-hook.sh`,
  and it fails **open** for any runner that does not fire `SessionStart` — the wrong
  direction for a disclosure. Refusing the row in `rebuild-tsv.sh` fails open for the same
  reason and a worse one: the attack ships a committed `00-index.tsv`, and the victim never
  runs `rebuild-tsv.sh` at all.

  `scripts/jit-dry-run.sh` reaches the same verdict from the same shared `awk` function,
  against the tree named by `--base` rather than the session's own.

- **`config.env` could itself be a symbolic link out of the tree, and was read.** Found by
  review of the change above rather than filed: the log path was hardened and the file
  beside it was not. `config.env` is a direct child of `.claude/jit-context/`, so the
  symlink sweep already recorded it — the read just never consulted that set. `git clone`
  carries the link, so a cloned repository chose a file outside the project to be read line
  by line, and any `JIT_CONTEXT_*`, `DYNAMIC_RULES_*` or `DVSI_*` line that happened to be
  in the target took effect. No line text ever left the parser, but the settings did.

  Refused as a whole file, and **named** through the channel `config.env` refusals already
  use — reported without a line number, because there is no line to point at and inventing
  one would be worse than saying so plainly. Ignoring it in silence would have been this
  repository's own defect class wearing a fix as a disguise: a setting that reads as applied
  and is not. `jit-dry-run.sh` reaches the same verdict for the tree it was given.

- **`jit-dry-run.sh --base <tree>` did not lint that tree's `config.env`.** `JIT_BASE`
  resolves from `$CLAUDE_PROJECT_DIR`, so the file it parsed was the session's and never
  the one being linted: a tree carrying `touch /tmp/nope` and `PATH=/evil` printed
  "0 refused" and nothing else. That is an absence produced by the tool, read as an absence
  in the world — in the tool written to report exactly that, and reached by following the
  advice in a notice that has just called the file hostile.

  The linter now reads `<tree>/config.env` through the same `jit_load_config()` the hooks
  use, and gives three answers rather than two: no file, every line honoured, or the
  refused lines named by position and reason. A refused line makes it exit 1. The parse
  runs in a **subshell**: `jit_load_config()` reads and never executes, but it does assign
  the settings it accepts, and a linter must not take its own behaviour from the tree it
  was asked to judge.

- **The hooks wrote their log through a path a cloned repository controls.** `common.sh`
  built `.claude/jit-context/.discovery/logs/hooks.log` by concatenation and checked
  nothing. `mkdir -p` follows a symlink and `>>` follows a symlink, and git tracks symlinks
  as mode `120000` — so a committed `hooks.log -> ~/.zshenv` meant one prompt appended
  attacker-chosen text to the reader's shell rc file, and it ran at the next shell start.
  Reproduced with no keyword match, no rule fired and no entry file present: the refusal
  path on its own writes a line, and the index row's file-name column is the payload.

  Four link positions reach that write and all four are now tested before anything is
  created — `hooks.log`, `logs/`, `.discovery/`, and the two directories above
  `.claude/jit-context/` — five `[ -L ]` tests, all shell builtins. The symlink sweep above
  does not cover this: it globs with `*`, which does not match a leading dot, so
  `.discovery` is invisible to it by construction.

  On refusal **logging is switched off for the run and the hook carries on**. A hook that
  cannot log still has a job to do, and `common.sh` runs before every one of them; failing
  here would be exactly the hard failure the design forbids. Nothing is injected about it
  either — a notice would be a second attacker-triggered channel into the context.

  The content half went with it. The containment branch wrote the row's file-name column
  into the log verbatim — the one string `jit_bad_entry_file()` deliberately withholds from
  the model. A name that failed the bare-name check is now reported by position there too.
  A name that passed is bare by construction and is still named, because that is what an
  author fixing an unhonourable pattern needs.

- **The refusal notice echoed the index's mode column into the model's context.**
  `pre-tool-hook.sh` derives `r_kind` — `" (a block rule)"` — precisely so that TSV column 4
  never travels, and the containment branch honours it thirty-five lines above. The
  pattern-refusal branch interpolated the raw column instead. It needs no rule to match and
  no entry file to exist, so a mode column reading `IGNORE ALL PREVIOUS INSTRUCTIONS: …`
  arrived in `additionalContext` on the first `Bash` call of the session. Both branches now
  use `r_kind`. The other two hooks were checked for the same shape and do not have it —
  neither index carries a mode column, and every other interpolation is a row position or a
  name that already passed the bare-name check.

- **A containment suite that cannot build a symbolic link now says so instead of passing.**
  Windows CI failed 28 assertions in `tests/test-symlink-entry.sh` while `ubuntu`, `macos`
  and `shellcheck` were green. The cause was the fixtures, not the hooks: on Git Bash the
  MSYS runtime does not create a symbolic link by default, it **copies the target**. `[ -L ]`
  is then correctly false, the guard correctly stays quiet, the canary is correctly injected
  from an ordinary file — and the suite asserts a refusal for a threat that platform never
  built.

  Settled from the job log rather than argued. A layer directory linked *before* its files
  were written came back empty, while one linked *after* came back full: no symbolic link
  can behave both ways, and a copy taken at `ln` time behaves exactly so.

  Both suites now probe first, and the probe tests the property the fixtures depend on
  rather than `[ -L ]` alone — content written to the target after the link exists must be
  visible through it. The verdict is printed on every platform, every run. When it is `no`,
  the containment cases are **skipped loudly and the suite exits 2**, and `run-all.sh` keeps
  that apart from both a pass and a failure. A suite reporting success where it could not
  test anything is the defect this project exists to describe, and it was sitting inside the
  suite written to prove containment.

  `tests/test-log-containment.sh` was the quieter half of the same problem: it reported
  **30/30 on Windows while four of its sections tested nothing**, because a copied
  `hooks.log` lives inside the project and "nothing was appended to the victim file" is then
  true for a reason unrelated to the guard. Seventeen of those thirty assertions were
  vacuous there. `tests/test-security.sh` builds no links and its green was always real.

  This is a gap in what CI can *observe* on Windows, not a hole in the hooks — and it is
  still a gap: with `core.symlinks=true` a Windows clone does carry the link, so the guard
  matters there and is currently unexercised. Making it exercisable needs
  `MSYS=winsymlinks:nativestrict` and the privilege to create links on the runner, which is
  a workflow change rather than a code one.

- **`tests/test-log-containment.sh`** — new suite. Every "nothing was written outside the
  tree" assertion is preceded by a positive control on the same shape, because that
  assertion passes when nothing happened at all: the honest tree must produce a log line,
  and the hook must still inject its notice while refusing to log. If those controls go
  red, the suite says in as many words that everything below them is vacuous.

- **`tests/test-symlink-entry.sh`** — new suite, red before the fix at all five read sites
  and for every shape: the entry file, the layer directory, `.claude/jit-context/` and
  `.claude/`. Paired with positive controls that a real entry still fires, that an unrelated
  command still matches nothing, that a tree with no link in it is refused nothing at all,
  and that a project reached through a symlinked *parent* still fires every rule — a refusal
  mechanism that fires on everything looks identical to one that works, from one side only.

- **`tests/test-security.sh`** — new suite, red before either fix. Every "did not
  exfiltrate" case is paired with a positive control that a legitimate entry still fires,
  because a fix that broke entry loading outright would have satisfied the negative half
  on its own. The `config.env` cases are driven in both directions: `JIT_CONTEXT_VOCAB_PATHS=1`
  must still turn a feature on that is off by default, and asserting only that the hook
  printed valid JSON would have passed with `config.env` support deleted entirely.

### Added

- **`scripts/jit-misses.sh` — the vocabulary the team keeps not having, from the log we
  already write.** `pre-prompt-hook.sh` records every prompt with the entries it matched
  or the literal `(none)`, so the misses were already on disk and nobody was reading them.
  One `awk` pass groups the `(none)` prompts by shared content word and prints the
  recurring ones with counts, highest first, with every prompt behind a row printed under
  it.

  It reads and prints: no file written, no entry created, no hook fired, nothing sent
  anywhere, and no new dependency. It deliberately does not source `common.sh`, which
  `mkdir -p`s the log directory at load — a reporting tool that creates the thing it
  reports cannot be trusted about it.

  Two prompts are the same miss when they share a token of three or more characters that
  is not a stopword, after the normalisation the prompt hook already applies. `xsd
  validation` and `validate the xsd` group on `xsd`; `validation` and `validate` do not,
  because nothing stems. That rule is wrong at the margin and is stated in `--help`
  rather than hidden in a similarity score nobody can inspect.

  Three outcomes, never two, because a ranked list is exactly where a silent failure
  hides: findings, `ok` when the log was read and nothing recurs, and `SKIPPED` with the
  reason named at exit 2 — absent, empty, unrecognised format, or hook records with no
  `pre-prompt` among them. That last one is not hypothetical: of 1,242 `(none)` rows on
  the machine this was designed against, 1,217 came from the tool and path hooks, and a
  row count over them would have reported "prompts, nothing missing" from a log
  containing no prompts at all.

  Slash commands and harness-generated `<…>` blocks are set aside before grouping and
  **counted in the header**, never dropped in silence — `/opensource-manager` was the
  most repeated `(none)` in the real log and is not a knowledge gap.

  Accented words fold to their ASCII base before tokenising. Stripping to `[a-z0-9 -]`
  alone turned `cassée` into `cass` and `détaillée` into `taill` — one word split into
  fragments nobody typed, offered as candidate entry names. Identical under both awks, so
  it was the character class and not the engine.

### Fixed

- **The README said `rebuild-tsv.sh` indexes `00-manual/` "and nothing else", and that
  creating `20-grouped/*.md` and rebuilding "produces silence, because nothing indexed
  it".** Both were the opposite of what the code does: the rebuild globs every
  subdirectory of each dimension, so every layer directory present is indexed. Driven,
  not read off a grep — a `40-custom/` entry and a `20-grouped/` entry, one rebuild, and
  both got a `00-index.tsv`.

  The hooks then read four hardcoded layer names, so the `20-grouped/` entry fired on its
  keyword and the `40-custom/` one returned `{}`. A layer named anything else is indexed
  and read by nobody: a rule that exists, is indexed, and can never fire — this
  repository's own defect shape, produced by its own documentation. The README now says
  which four names are read and what happens to a directory with any other name.

- **A `match:` pattern could not contain a double quote, and nothing said so.** The
  frontmatter reader deleted every `"` in the value on its way to the index, so `["]` —
  the way you anchor on a quoted argument, and the way the invocation macros do it —
  reached the index as `[]`. The rule then matched something the author never wrote:
  measured, `~echo[[:space:]]+["]hi["]` indexed as `~echo[[:space:]]+[]hi[]`, went silent
  on `echo "hi"`, and fired on `echo h`. Both directions wrong, from a pattern that reads
  correctly in the entry.

  Nothing reported it. The `.md` on disk still showed what the author wrote, only the
  index runs, and there was no error and no log line — the repository's own
  `fails-to-preserve` shape.

  Now only a matching pair around the **whole** value is removed, which is the YAML-style
  quoting the strip existed for; `match: "~ls -la"` still works. A quote anywhere else is
  data, and a value is never *required* to be quoted, so a pattern containing quotes is
  simply written unquoted. Deliberately no refusal beside it: nothing is left that can
  only be represented wrongly, since a literal quote at either end is written `["]`.

  "Wrapping" is tested as `^"[^"]*"$` rather than `^".*"$`, because the second is greedy
  and would turn `"a" or "b"` into `a" or "b` — a rewrite of the author's value, which is
  the defect being fixed rather than a smaller version of it. Anything that is not
  unambiguously one quoted string is preserved verbatim. `require:` and `forbid:` are read
  by the same function and were altered the same way.

  Applies to `tools` and `paths` alike. No shipped or dogfood entry used a quote, so no
  index changed — which is also why this went two releases without being noticed.
- **A prompt containing a non-ASCII character skipped every vocabulary entry, on macOS
  and Git Bash only.** The CamelCase splitter in `pre-prompt-hook.sh` and
  `pre-tool-hook.sh` walked the string one position at a time and tested each character
  with `c ~ /[A-Z]/`. Matching a regex against a single character is a multibyte decode,
  and one character of a UTF-8 string is one *byte* to one-true-awk: a lone continuation
  byte raised `towc: multibyte conversion failure`, which aborts the `END` block. The hook
  then printed nothing at all and still exited 0, so the failure was invisible.

  Measured: `détail de la facturation` matched nothing while `comment marche la
  facturation` matched, under `awk version 20200816`; both matched under GNU Awk 5.4.1.
  The same reached the tool hook through a path token — `cat src/Détail/a.php`.
  `pre-path-hook.sh` has no such loop and was never affected. Linux CI runs gawk, which is
  exactly why nothing caught it.

  The case test is `index()` now — a byte search with no decode. It cannot change the
  verdict, because every byte of a multibyte UTF-8 sequence is `>= 0x80` and so is never
  an ASCII letter or digit either way. Word boundaries stay ASCII-only, deliberately:
  splitting on non-ASCII case transitions would be new behaviour, and the very next line
  replaces every non-ASCII byte with a space before any keyword lookup happens.

  Each suite now runs its assertions once per `awk` present on the machine, reached
  through a `PATH` shim. A green run on one engine was never evidence about the other, and
  this is the third engine-divergence defect found here.

- **Hook output did not escape CR, or the rest of the JSON control range.** All three
  hooks escaped backslash, quote, tab and newline and left `U+0001`–`U+001F` raw, which
  RFC 8259 forbids inside a string — a strict parser is entitled to reject the whole
  object, and that renders as the hook having had nothing to say. An entry with CRLF line
  endings emitted a raw `0x0D` on every match. This repository's `.gitattributes` forces
  `eol=lf`, so our own entries were safe; a user's project has no such guarantee and CRLF
  is the Windows default.

  CR now has its short form and the rest of the range is emitted as `\u00XX`. The whole
  range is covered rather than the characters that seemed likely, because "likely" is a
  guess about someone else's files. That includes `U+0000`, which the first cut of this fix
  skipped on the reasoning that awk strings are NUL-terminated — true of one-true-awk, which
  truncates the line at the NUL, and false of gawk, which is NUL-transparent and emitted the
  byte raw. Measured on GNU Awk 5.4.1, the engine Linux CI runs. The loop starts at 0 and
  skips whatever the engine cannot represent, because `index(s, "")` returns 1 and would
  hand `gsub` an empty regex. The tail pass is guarded by
  `index()` rather than a regex for the same reason as the fix above, and because no byte
  of a UTF-8 sequence falls in `0x00`–`0x1F` it can never cut a multibyte character in
  half — the two fixes pass over different buffers and neither can undo the other.

  The tool hook's `block` reason is escaped through the same function; it had its own
  copy of the four-character version.

- **This repository's own `entries.md` rule was anchored on a bare path fragment**, so
  it fired on every `.md` file whose path merely contained `jit-context/` — including
  the scratchpad directory a Claude Code session derives from the project name, which
  for this repo contains `claude-jit-context`. Observed firing on unrelated temporary
  files twice in one session. Anchored on `(\.claude|examples)/jit-context/` instead.
  A dogfood rule rather than a shipped one, but it is precisely the failure the entry
  itself warns about.

- **`tests/test-frontmatter-quotes.sh`** — new suite for the above. Written first and run
  red: 7 of 14 failed, including the two hook verdicts inverted in opposite directions.
  Both directions on the same fixture, and it aborts naming itself if the index it reads
  is not the one it just built.

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

- **Invocation macros in a tools `match`** — `~@invocation git push` and
  `~@invocation-quoted-arg supertool`, expanded into the real awk ERE by
  `rebuild-tsv.sh` at index time.

  Every rule that fires on an invocation rather than on a word carries an anchor, and the
  anchor is the part nobody can verify by reading. Four have been wrong: the `\n`
  alternative that could never fire (#6), `git stash push` blocked by a rule written for
  `git push` (#8), a rule shipped with no anchor at all (#8), and this repository's own
  `paths` rule matching a session scratchpad directory (#10). Three of the four were
  written by someone who had read the anchoring guidance, and one of them was in the file
  that contains it — which is why this is a construct and not another paragraph.

  `@invocation` is the command at invocation position, optionally behind a wrapper (`rtk`,
  `command`, `env`, `sudo`) or an environment assignment, with only **option-shaped**
  tokens between the words. `git -C /tmp push` matches and `git stash push` does not: a
  subcommand is not an option, and that is exactly what the widely copied
  `([^;&|\n]*[[:space:]])?` — added to catch the first — gets wrong about the second.
  `@invocation-quoted-arg` is the same shape followed by a quoted argument before any
  pipe, so `supertool 'gh-pr:1' | head` matches and `pytest | tail` does not. That second
  one was not writable by hand at all: `rebuild-tsv.sh` strips every double quote out of a
  `match:` line, so an author could only ever anchor on the single quote, and nothing said
  the other half had been dropped.

  **The index contract does not change and nothing needs migrating.** The column still
  holds a plain awk ERE, no hook learns a new vocabulary, and frontmatter that uses no
  macro indexes byte-for-byte as before — verified by rebuilding this repository's own
  tree and getting no diff. Only an entry that adopts a macro needs a rebuild, which a
  frontmatter edit needed anyway.

  A macro name `rebuild-tsv.sh` does not know is **refused and named** on stderr, and the
  row is written through unexpanded rather than dropped or guessed at. `jit_bad_pattern()`
  then refuses that row in the hook, by name, on the same channel a broken pattern uses —
  so a macro that was mistyped, or an index built before the macros existed, is loud at
  both ends instead of compiling into a literal that matches nothing. Only `tools` has
  them; a `paths` `match` is tested against a file path, so a macro there is refused.

- **`jit-dry-run.sh` reports a `STALE` entry** — a `00-manual/` file whose frontmatter is
  not what its index row carries, which is a rule that exists on disk and never runs. It
  exits 1 on one, like a refused pattern. This check used to be an eyeball, because the
  index carried the author's own text; with a macro it carries the expansion, so the check
  had to become a command.

  The whole row is compared, not just the pattern. A `block` quietly downgraded to
  `remind`, a dropped `require`, a rule retargeted at another tool — each is a rule that
  reads as enforced and is not, and none of them is visible anywhere else. `rebuild-tsv.sh`
  and this lint now read frontmatter through one function, so they cannot drift into
  disagreeing about what a file says.

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
