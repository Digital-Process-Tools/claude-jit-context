# claude-jit-context

Hooks that inject project knowledge into Claude Code only when it is needed. Bash, no runtime dependencies beyond `awk` and `perl`.

`README.md` is the user documentation — install, the three dimensions, frontmatter fields. Read it first. This file is the working contract for changing the code.

## The one trap

**The hooks never read your markdown. They read `00-index.tsv`.**

`rebuild-tsv.sh` parses the YAML frontmatter of every entry into a TSV index, and each hook runs a single `awk` over that index. This is why a hook costs 30–110 ms instead of parsing a directory of files on every prompt.

It also means an edited rule that has not been rebuilt is **inert**, and inert in the worst way: nothing errors, nothing warns, the rule simply never fires. A test can pass, a session can run all day, and the change did nothing.

```bash
bash scripts/rebuild-tsv.sh    # after every frontmatter edit, without exception
```

Body-only edits do not need it — the body is read from the file at fire time. Frontmatter edits always do. When in doubt, rebuild; it takes milliseconds.

## Layout

| Path                     | What                                                                       |
| ------------------------ | -------------------------------------------------------------------------- |
| `scripts/*-hook.sh`      | One script per hook event. These are the product.                          |
| `scripts/common.sh`      | Sourced by all of them. Paths, logging, optional `config.env`.             |
| `scripts/rebuild-tsv.sh` | Frontmatter → `00-index.tsv`. The only writer of that file.               |
| `tests/test-*.sh`        | One suite per hook, plus `run-all.sh`.                                     |
| `examples/jit-context/`  | Shipped example entries. They carry real frontmatter and must stay valid.  |
| `hooks/hooks.json`       | Plugin-install registration, via `${CLAUDE_PLUGIN_ROOT}`.                  |

Entries a user writes live in **their** project at `.claude/jit-context/{paths,tools,vocabulary}/00-manual/`. Only `00-manual/` is hand-edited; other layers are generated.

## Rules for changing this

**No new runtime dependencies.** No `jq`, no Python, no Node. Dropping `jq` is most of what 0.2.0 was about — the frontmatter format exists so that the hooks need nothing but `awk`. Adding a dependency back is a breaking change, not a convenience.

**A hook must never fail hard.** It runs on every prompt and every tool call, in someone else's session, often before they know this plugin exists. A missing config directory, an unreadable file, a malformed entry — each is a reason to inject nothing and exit `0`, never a reason to error. The suite has explicit cases for empty input, empty `tool_name` and a missing config dir; keep them passing.

**Silence and "nothing to say" must not be the same thing.** The tool dimension can block a call. If a rule cannot be evaluated — index missing, frontmatter unparseable — that is not the same as "no rule matched", and it must not render as an allow with no explanation. When a check cannot run, say so in what it injects.

**Test on both platforms or say you did not.** CI runs Linux and macOS, plus shellcheck. The bash on macOS is not the bash on Linux, and a substitution that works locally is not evidence about the other leg. A single-platform red is usually genuine.

```bash
bash tests/run-all.sh          # non-zero on any failure
```

**Every behaviour change gets a test first.** Write it, watch it fail, then fix. A test written after the fix asserts what the code happens to do.

## Releasing

The version appears in more places than you will remember:

- `.claude-plugin/plugin.json`
- `README.md` — the version badge, near the top
- `CHANGELOG.md`

Sweep for the outgoing value before you finish, with no path filter — a filtered sweep cannot see a file whose extension you forgot to list, which is exactly how a badge sits stale for a year:

```bash
git grep -n "0\.2\.0"
```

A sweep for the version being replaced only finds sites that are half-bumped. It cannot find a site frozen at some third value — check the badge by eye, and add a test the day a fourth site appears.

## Voice

The README and CHANGELOG say what a thing does and why the previous design was wrong. They do not sell. `0.2.0`'s entry opens with "the documentation described a design that no longer existed" — that is the register: honest about what was broken, specific about what replaced it.
