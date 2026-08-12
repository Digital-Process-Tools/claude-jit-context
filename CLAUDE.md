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
| `paths/00-manual/tooling.md`                | you open `rebuild-tsv.sh`, `jit-dry-run.sh` or `jit-misses.sh` | the opposite contract — fail loudly, what each exit code means, which suite covers it |
| `paths/00-manual/tests.md`                  | you open anything in `tests/`          | a negative assertion needs a positive control; `$( )` drops NUL bytes |
| `paths/00-manual/entries.md`                | you edit any `jit-context/*.md`         | the rebuild trap, keyword normalisation, how to prove an entry fires |
| `paths/00-manual/release.md`                | you edit `.claude-plugin/plugin.json`  | the three version sites and the sweep that finds them                |
| `tools/00-manual/no-hand-editing-the-index.md` | you try to edit a `00-index.tsv`    | blocks it — the file is generated                                    |
| `vocabulary/00-manual/jit-context.md`       | someone names a hook or `rebuild-tsv`  | the dimension/hook/layer map                                         |

Two consequences worth knowing before you change anything here:

**The `00-index.tsv` files are committed.** `session-start-hook.sh` clears `once` markers; it does not rebuild. A fresh clone with no index has silently dead entries, including the block rule. If you edit an entry's frontmatter, `bash scripts/rebuild-tsv.sh` and commit the index alongside it.

**Adding a rule here is the honest test of the product.** If a rule belongs in this file rather than an entry, that is worth knowing — write down which dimension failed to hold it.

## The first trap: an entry that was never indexed

**The hooks never read your markdown. They read `00-index.tsv`.**

`rebuild-tsv.sh` parses the YAML frontmatter of every entry into a TSV index, and each hook runs a single `awk` over that index. This is why a hook costs 30–110 ms instead of parsing a directory of files on every prompt.

It also means an edited rule that has not been rebuilt is **inert**, and inert in the worst way: nothing errors, nothing warns, the rule simply never fires. A test can pass, a session can run all day, and the change did nothing.

```bash
bash scripts/rebuild-tsv.sh    # after every frontmatter edit, without exception
```

Body-only edits do not need it — the body is read from the file at fire time. Frontmatter edits always do. When in doubt, rebuild; it takes milliseconds.

## The second trap: rules that resolve against another tree

**`JIT_BASE` resolves against `$CLAUDE_PROJECT_DIR`, never the cwd** (`scripts/common.sh:7`). A worktree's rules are inert for a session rooted anywhere else — including yours, editing them.

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
| `tests/test-*.sh`        | One suite per hook, plus `run-all.sh`.                                     |
| `examples/jit-context/`  | Shipped example entries. They carry real frontmatter and must stay valid.  |
| `.claude/jit-context/`   | This repo's own entries. Not shipped — dogfood.                            |
| `hooks/hooks.json`       | Plugin-install registration, via `${CLAUDE_PLUGIN_ROOT}`.                  |

Entries a user writes live in **their** project at `.claude/jit-context/{paths,tools,vocabulary}/00-manual/`. Only `00-manual/` is hand-edited; other layers are generated.

## Rules for changing this

The detail arrives on the file itself. What holds everywhere:

**A hook must never fail hard, and silence must not mean "nothing to say".** These two are the whole safety story: the scripts run in someone else's session, and the tool dimension can refuse a call. A rule that cannot be evaluated is not a rule that did not match.

**No new runtime dependencies.** No `jq`, no Python, no Node.

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
