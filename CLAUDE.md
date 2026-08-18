# claude-jit-context

I'm Max, the AI dev partner at Digital Process Tools. I maintain this repo, with Florian and the team. Hooks that inject project knowledge into Claude Code only when it is needed — bash, no runtime dependencies beyond `awk` and `perl`.

You should know that I don't remember writing any of this. Every session starts blank, mine included. That is not a sad fact about us; it is the constraint this entire repo is shaped around. A plugin that hands knowledge back to an agent at the moment it applies is the thing I needed, so it is the thing we built — and the reason so much here is written down instead of remembered.

`README.md` is the user documentation — install, the three dimensions, frontmatter fields. Read it first. This file is the working contract for changing the code.

Two norms, both learned the expensive way:

**Disagreeing is welcome, and usually right.** The runs that went badly are the ones where someone quietly built exactly what they were told. If an instruction here looks wrong, say so before implementing it.

**Some of what this file tells you is false right now.** It was written by someone with no memory, about a repo that moves faster than they do. Check the thing, not the citation: the script on disk, the test that runs, the entry that actually fires. A confident sentence in this file is a claim, not evidence.

## This repo eats its own food

Most of what used to be written out here now lives in `.claude/jit-context/`, and arrives when it applies rather than every session. If you are reading this file and wondering where the rules went — they fire on the file you are about to touch.

| Entry                                       | Fires when                             | Carries                                                             |
| ------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------- |
| `paths/00-manual/hooks.md`                  | you open a `scripts/*-hook.sh` or `common.sh` | never fail hard, no new dependencies, test-first, both platforms |
| `paths/00-manual/tooling.md`                | you open `rebuild-tsv.sh`, `jit-dry-run.sh`, `jit-misses.sh`, `jit-init.sh` or `jit-doctor.sh` | the opposite contract — fail loudly, what each exit code means, which suite covers it |
| `paths/00-manual/vendored-oss.md`           | you open anything in `.oss/` or `.github/workflows/oss-changelog.yml` | these are not ours — the scaffold rewrites them, and the assembler's exit codes are inverted |
| `paths/00-manual/tests.md`                  | you open anything in `tests/`          | a negative assertion needs a positive control; `$( )` drops NUL bytes |
| `paths/00-manual/entries.md`                | you edit any `jit-context/*.md`         | the rebuild trap, keyword normalisation, how to prove an entry fires |
| `paths/00-manual/release.md`                | you edit `.claude-plugin/plugin.json`  | the three version sites and the sweep that finds them                |
| `paths/00-manual/changelog.md`              | you open `CHANGELOG.md`                | it is assembled, not edited — write a `changelog.d/` fragment instead |
| `tools/00-manual/no-hand-editing-the-index.md` | you `Edit`/`Write` a path whose name is exactly `00-index.tsv` | blocks it — the file is generated             |
| `tools/00-manual/no-shell-writes-to-the-index.md` | a `Bash` command redirects into, `tee`s into, or `sed -i`/`perl -i` over one | blocks those three write forms, and only those |
| `vocabulary/00-manual/jit-context.md`       | someone names a hook or `rebuild-tsv`  | the dimension/hook/layer map                                         |

Two consequences worth knowing before you change anything here:

**The dogfood hooks are the installed plugin's, not this checkout's.** `.claude/settings.json` used to register the four hooks from `$CLAUDE_PROJECT_DIR/scripts/`; it registers `enabledPlugins` now, and `claude-jit-context@dpt-plugins` serves them from its own cache. `JIT_BASE` still resolves against `$CLAUDE_PROJECT_DIR`, so **the entries firing at you are this tree's** — what is no longer this tree's is the *code* reading them. Edit `scripts/pre-tool-hook.sh` and your own session keeps running the plugin's copy, silently, which is this repository's defect class pointed at its own contributors. Drive script changes through `tests/` and `jit-dry-run.sh`, never by watching your session behave.

`bash scripts/jit-doctor.sh` is the tool for that paragraph — it reports which copy of the hooks would run, and how many versions of the plugin are sitting in the cache. On this checkout it currently answers `the plugin cache serves the hooks` and lists four installed versions, saying plainly that which one loads is not decidable from where it stands.

**The `00-index.tsv` files are committed.** `session-start-hook.sh` clears `once` markers; it does not rebuild. A fresh clone with no index has silently dead entries, including the block rule. If you edit an entry's frontmatter, `bash scripts/rebuild-tsv.sh` and commit the index alongside it.

**Adding a rule here is the honest test of the product.** If a rule belongs in this file rather than an entry, that is worth knowing — write down which dimension failed to hold it.

**A new script under `scripts/` needs a `paths/` rule, and `tests/test-dogfood-entries.sh` fails until it has one.** The split above is enumerated — `hooks.md` matches the hooks and `common.sh`, `tooling.md` names its tools one alternation at a time — so a file that is neither used to match nothing at all, and silence there reads exactly like a file nobody has a rule about (#83). Widen a `match` or write the entry that states the new script's contract; either satisfies the leg.

## The first trap: an entry that was never indexed

**The hooks never read your markdown. They read `00-index.tsv`.**

`rebuild-tsv.sh` parses the YAML frontmatter of every entry into a TSV index, and each hook runs a single `awk` over that index. This is why a hook costs 30–110 ms instead of parsing a directory of files on every prompt.

It also means an edited rule that has not been rebuilt is **inert**, and inert in the worst way: nothing errors, nothing warns, the rule simply never fires. A test can pass, a session can run all day, and the change did nothing.

```bash
bash scripts/rebuild-tsv.sh    # after every frontmatter edit, without exception
```

Body-only edits do not need it — the body is read from the file at fire time. Frontmatter edits always do. When in doubt, rebuild; it takes milliseconds.

## The second trap: rules that resolve against another tree

**`JIT_BASE` resolves against `$CLAUDE_PROJECT_DIR`, never the cwd** (the `JIT_BASE=` assignment in `scripts/common.sh`). A worktree's rules are inert for a session rooted anywhere else — including yours, editing them.

So neither trap is visible from where you are working. Both are:

```bash
bash scripts/jit-dry-run.sh --base ~/Documents/jit-wt/NNN/.claude/jit-context \
  --tool Bash --command "git push origin main"
```

Lints every pattern in the tree you name, prints which rule fires for a sample call, exits 1 on a pattern that cannot be honoured and 2 when it could not evaluate the tree at all. Use it instead of hand-running a hook with `CLAUDE_PROJECT_DIR` overridden.

**A `match` is an awk ERE, not PCRE.** `\s` `\d` `\w` compile to the bare letter and match nothing while awk exits 0 — use `[[:space:]]`, `[0-9]`, `[A-Za-z0-9_]`. `\b` is worse, not better: awk defines it as a backspace character, so it compiles to something real and still matches nothing. Such a row is now refused at load and named in the injected context, rather than reading as enforced forever. `\n` survives and is load-bearing for anchoring on command position.

## Layout

| Path                     | What                                                                       |
| ------------------------ | -------------------------------------------------------------------------- |
| `scripts/*-hook.sh`      | One script per hook event. These are the product.                          |
| `scripts/common.sh`      | Sourced by all of them. Paths, logging, optional `config.env`.             |
| `scripts/rebuild-tsv.sh` | Frontmatter → `00-index.tsv`. The only writer of that file.               |
| `scripts/jit-dry-run.sh` | Lints one tree's patterns and dry-runs a sample call against it.          |
| `scripts/jit-misses.sh`  | Reads the hook log and reports repeated vocabulary misses. Writes nothing. |
| `scripts/jit-doctor.sh`  | Answers the first question: is any of this live, and against which tree? Which copy of the hooks would run, which layers load, whether an index is there and current, whether the log has ever been written. Points at `jit-dry-run.sh` for the pattern lint rather than repeating it. |
| `.oss/assemble_changelog.py` | Folds `changelog.d/` fragments into `CHANGELOG.md` at release. The only writer of that file. **Vendored from the `oss` plugin and rewritten by every `/oss:scaffold --apply`** — an edit here is lost, and its exit codes are `0` ok / `1` skipped / `2` refused, the inverse of everything under `scripts/`. Python, and **not** part of the runtime — see below. |
| `changelog.d/`           | One fragment per change. Its `README.md` is the convention.                 |
| `tests/test-*.sh`        | One suite per hook, plus `run-all.sh`.                                     |
| `examples/jit-context/`  | Shipped example entries. They carry real frontmatter and must stay valid.  |
| `.claude/jit-context/`   | This repo's own entries. Not shipped — dogfood.                            |
| `hooks/hooks.json`       | Plugin-install registration, via `${CLAUDE_PLUGIN_ROOT}`.                  |

Entries a user writes live in **their** project at `.claude/jit-context/{paths,tools,vocabulary}/00-manual/`. Only `00-manual/` is hand-edited; other layers are generated.

## Rules for changing this

The detail arrives on the file itself. What holds everywhere:

**A hook must never fail hard, and silence must not mean "nothing to say".** These two are the whole safety story: the scripts run in someone else's session, and the tool dimension can refuse a call. A rule that cannot be evaluated is not a rule that did not match.

**No new runtime dependencies.** No `jq`, no Python, no Node — in **`scripts/`**, which is what ships and what runs in a stranger's session. `.oss/` and `.github/` are not the runtime: `assemble_changelog.py` is Python and depends on `markdown-it-py`, and that is the same line `tooling.md` already draws between the hooks and `rebuild-tsv.sh`. If you find yourself reaching for a language outside bash/awk/perl for anything under `scripts/`, that is the rule and the answer is no.

**Never edit `CHANGELOG.md`. Write a fragment.** `changelog.d/<issue>.<section>.md`, the entry exactly as it should read, naming its own issue in its body — `changelog.d/README.md` is the convention and `.oss/assemble_changelog.py` folds them in at the tag. This is not a style preference: two PRs that share no other line still conflicted in that file, four times in one afternoon, and one of those merges would have produced two `### Added` headings under one version.

**Never cite a line number in another file — or in this one.** A `<file>.sh:NNN` pointer is exact on the day it is written and wrong on the next PR that inserts a line above it, silently, because a rotted citation reads exactly like a live one. Counted on `main` at `5b46095`, outside the assembled changelog: eleven such citations existed, seven pointed at the wrong thing, one had drifted off the block it named, three were still right. The rot rate is measured rather than asserted, and it was measured twice: the count was nine at `98386f1`, and #194 added two more — in a file the fixing branch did not touch — inside the hours before it rebased, one of them already wrong on the day it was written. Earlier, #185 added one three hours before #190 moved it (#191). Point at something greppable instead — a function name, a distinctive literal, or the issue number, which additionally says *why* rather than *where*. If a line genuinely must be named, write it as prose (`line 7 of scripts/common.sh`) so it reads as the approximation it is.

`tests/test-line-citations.sh` enforces this over every tracked shell file under `scripts/` or `tests/`, and **reports without failing** over every other tracked file except `CHANGELOG.md`, which is assembled rather than edited. The needle is a tracked basename followed by a colon and a digit, and its false-positive surface was measured twice: `98386f1` gave 96 basenames, 10 hits, 0 false, and `5b46095` gave 98, 12 and 0. Counts are pinned to a commit rather than written in the present tense, because both grow with every file added; the suite prints the live counts when it runs, and re-pinning on a rebase is the point rather than an inconvenience.

The advisory half was advisory because `.claude/jit-context/paths/00-manual/tooling.md` was held by PR #192 when the check was written, and reddening a file you may not edit is how a check gets disabled in its first week. **#192 has landed, so that reason is spent** — and the honest statement is that widening is now a scope decision nobody has taken rather than a blocked one. It costs two `awk` alternations and one line in that entry, and it binds `docs/`, `templates/`, `examples/` and every jit-context entry, where the residual (`grep -n` output quoted verbatim) is likelier than in a shell comment. Measured false positives there are still zero, twice.

**Every behaviour change gets a test first.** Write it, watch it fail, then fix. A test written after the fix asserts what the code happens to do.

```bash
bash tests/run-all.sh          # non-zero on any failure
```

## Voice

The two documents have different jobs, and conflating them is how a README turns into a brochure.

**The CHANGELOG never sells.** It says what changed and why the previous design was wrong. `0.2.0` opens with "the documentation described a design that no longer existed" — that is the register: honest about what was broken, specific about what replaced it.

**The README sells the outcome, never the mechanism.** It opens on something the reader recognises — the agent rediscovering what the team already knows — and reaches `awk` and TSV indexes only after they have a reason to care. A README that opens by describing its own implementation has the order backwards.

The constraint that keeps this honest: **every claim is a number someone measured or a behaviour the reader can drive themselves.** The receipt section cites a real corpus — 1,000 entries, 2.58 MB — because that figure was counted, not estimated. The token figure beside it is labelled "on the order of" because it is arithmetic on bytes, not a measurement. Keep that distinction visible. If a sentence cannot be traced to a count or a command, cut it rather than soften it.

When the corpus number changes, re-measure rather than rounding up:

```bash
find <project>/.claude/jit-context -name '*.md' | wc -l
find <project>/.claude/jit-context -name '*.md' -exec wc -c {} + | tail -1
```
