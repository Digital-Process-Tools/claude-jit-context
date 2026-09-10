---
title: Rebuild the index or this edit does nothing
description: Frontmatter edits are inert until scripts/rebuild-tsv.sh runs; how keywords are normalised, and how to prove an entry actually fires.
match: (^|/)(\.claude|examples|templates)/jit-context/.*\.md$
---

**The hooks never read this file's frontmatter. They read `00-index.tsv`.**

A frontmatter edit that has not been rebuilt is inert, and inert in the worst way: nothing errors, nothing warns, the rule simply never fires.

```bash
bash scripts/rebuild-tsv.sh    # after every frontmatter edit, without exception
```

Body edits need no rebuild — the body is read from the file at fire time. Frontmatter edits always do.

## Write a `description:` anyway

A match injects the whole body — `full` is the default, for upgrade safety: a tree that installed this before the mode existed must not silently lose knowledge its agents rely on.

Under `JIT_CONTEXT_INJECT=summary`, or `inject: summary` in one entry, a match injects `title:` plus `description:` instead — roughly 20 tokens — and the agent reads the file if it wants the rest. An entry with no `description:` is then named and **not injected**; nothing is auto-derived, because a generated summary of a wrong entry is a confident wrong summary.

So a missing `description:` costs nothing today and is what stops this tree flipping later. `rebuild-tsv.sh` prints what one match costs here, what it would cost summarised, and every entry still missing one. A `mode: block` tools rule injects its whole body whatever the mode says — the call is already stopped, so there is no next turn to spend a cheaper answer in.

## Authoring

- Only `00-manual/` is hand-edited. `10-auto/`, `20-grouped/`, `30-crosscutting/` belong to generators.
- Prefer **paths** over keywords. The folder is the situation; keywords fire on what someone is talking about, paths on what they are touching.
- Keywords are normalised: CamelCase split, lowercased, Latin-1 accents folded to their ASCII base, anything else outside `[a-z0-9 -]` becomes a space. A keyword written `docs.example.com` matches nothing a prompt can produce. Matching is space-bounded, so `microbilling` does not match `billing`.
- The accent fold runs on the **keyword** and on the **prompt**, so `détail` and `detail` are one keyword in every direction (#31). Write the accented spelling. It is only true of an index built since the fold landed — an older one has `détail` stored as `d tail` — so `bash scripts/rebuild-tsv.sh` is what makes it so.
- One ordinary English word fires constantly. Prefer product nouns and multi-word keys.
- `rebuild-tsv.sh` prints an ambiguity report. A keyword in more than five entries drags all five into context on one stray mention.

## `match` is an awk ERE, not PCRE

`\s` `\d` `\w` compile to the bare letter and match **nothing**, while awk exits 0 — use `[[:space:]]`, `[0-9]`, `[A-Za-z0-9_]`. `\b` is not a word boundary but a backspace character, so it also matches nothing. A backslash before a **non-ASCII** byte is refused too (#116) — the guard reads bytes under `LC_ALL=C`, where nothing above `0x7F` is in any character class, so `\é` walked past the ASCII test, dropped its backslash on both engines and made gawk warn into the session; drop the backslash and the character matches itself. `\n` is the one escape that survives, and rules need it: `^` anchors the whole command string rather than each line, so anchor on `(^|[;&|\n] *)`. Such a row is now refused at load and named in the injected context instead of reading as enforced.

### A `match` is accent-folded too, character classes included

The Latin-1 fold that makes `détail` and `detail` one keyword (#31) runs on the **pattern** as well as the subject, and it is a literal substitution with no idea what a bracket expression is. `[éè]` therefore becomes `[ee]`, which is the accent-insensitivity you wanted. A **range** across the fold is not:

```yaml
match: ~[é-ü]      # becomes [e-u] — a third of the lowercase alphabet
```

Driven at this commit on a `mode: block` rule: `~[é-ü]` refused `git push origin main` on the `i` in `origin`, and refused `ls` as well (#115). Nothing is refused at load, because the row is a valid ERE both before and after folding — the pattern the author reads and the pattern the hook runs are simply not the same one.

Leaving brackets unfolded would be worse, not better: the subject is folded, so `[éè]` would then match nothing at all — a rule that is loudly wrong turned into one that is silently dead, which is the trade this repository refuses everywhere else. So write the folded ASCII range you actually mean, and keep accented characters in a `match` to plain alternatives rather than range endpoints.

## Do not hand-roll an invocation anchor

A tools rule that fires on a command rather than a word uses a macro, not a retyped anchor:

```yaml
match: ~@invocation git push               # git -C /tmp push yes, git stash push NO
match: ~@invocation-quoted-arg supertool   # supertool 'x' | head yes, pytest | tail NO
```

`rebuild-tsv.sh` expands it into the real ERE, so the index still carries a plain awk pattern. A macro it does not know is refused and named, and written through unexpanded so the hook refuses that row too rather than matching nothing. `paths` has no macros — its subject is a file path — and one written there is refused.

## Pull another entry body in: `{{dimension/layer/file.md}}`

A body can transclude another entry body directly (#378), so "full argument:
`skills/manager/phases/merge.md`" can become the argument itself:

```
{{vocabulary/00-manual/jit-context.md}}
```

That is exactly the shape the log line and the status line already print (`JIT :
vocabulary/00-manual/x.md (4.6k)`) -- copy the line you just watched fire, paste it between
braces, and there is no new addressing to learn.

**Expanded at fire time, not at rebuild time.** A transcluded body is a body, and every
other body transform here (`jit_clip()`, `jit_inject_text()` itself) already happens per
fire -- `rebuild-tsv.sh` never touches what gets injected, only what gets indexed. Fire
time also keeps the ergonomic this file opens with: editing the *included* file needs no
`rebuild-tsv.sh` run either, which would be strange to give up for a feature whose whole
point is handing a body over directly.

**Containment is the syntax, not a check bolted on afterward.** The only shape accepted is
a bare `dimension/layer/file.md`, split into exactly three components, each restricted to
letters, digits, dot, underscore and hyphen and refusing a leading dot -- the same alphabet
a layer directory name is already held to elsewhere in this file. That alphabet cannot
spell `..` as a whole component, so there is no character sequence that climbs out of the
tree, and the same containment and symlink guard an ordinary index row is refused by
(`jit_bad_entry_file()`/`jit_entry_why()`) runs on the resolved target too -- not a second
rule that could quietly drift from the first. Anything that does not resolve is **refused
in place, named**, right where the braces were: `{{spec}} [jit] transclusion refused:
<reason>`, never silently dropped.

**Bounded rather than trusted to behave.** A depth cap of 3 nested transclusions, a per-fire
total cap of 12 files, and cycle detection (`a` includes `b` includes `a`) all live in the
same function that resolves the path (`jit_transclude_resolve()`/
`jit_transclude_expand_line()` in `common.sh`). Crossing either cap reads the same way as an
unresolvable target: a named refusal in place, never a hang and never a silent truncation.

**`${{ github.sha }}` is never this syntax.** A `{{` immediately preceded by `$` is left
completely alone, brace and all -- entries that quote GitHub Actions workflow YAML
(`vendored-oss.md`, about `.github/workflows/oss-changelog.yml`) rely on that. So does any
` ``` `-fenced code block, regardless of what it quotes or whether it also happens to start
with `$` -- an entry *showing* the syntax without using it, the way this section does above,
would otherwise expand itself.

**Frontmatter is stripped from the included file, never from the firing one.** The
transcluded file's own `---` block is real frontmatter with its own `keywords:` and
`description:`, and none of that means anything to the reader it lands in front of, so it
is cut before the body is spliced in. This is unrelated to, and does not change, the
pre-existing fact that a fired entry's *own* frontmatter is part of what `full` mode injects
today -- that is a different, older behavior this feature does not touch.

**Firing twice is accepted, not deduplicated.** If `inc.md` also fires on its own in the
same session, and something else transcludes it too, its body arrives twice: the
per-session `fired` marker is per entry and has no notion that one body is now nested
inside another. Teaching the marker to follow the body is a real option; it was left out of
this change because it would make an entry `fired` (spending its one shot for the session)
purely as a side effect of someone else quoting it, which is a bigger behavior change than
the syntax itself.

**Size is not yet transitive.** `rebuild-tsv.sh`'s "what a match costs" report still prices
an entry off its own raw bytes (`length(e["body"])`), before transclusion is expanded, so a
2 KB entry that transcludes three files is not reported as the larger number it actually
costs at fire time. Making that report walk the same expansion `jit_inject_text()` performs
is a reasonable follow-up; it was left out here to keep this change to the fire-time path
alone, and worth its own issue.

**A pointer is still sometimes the right answer.** `tools/01-oss/merge-gate.md` points at
`skills/manager/phases/merge.md` on purpose, because the full argument does not belong in
every merge -- inlining costs nothing until the day some entry transcludes something 30 KB
that fires on every file touch. If a fired entry starts reading unexpectedly large, check
whether it transcludes something before assuming its own body grew.

## Prove it fires

Rebuilding is not evidence, and neither is the tree you are standing in: `JIT_BASE` resolves against `$CLAUDE_PROJECT_DIR`, so a worktree's rules are inert for a session rooted elsewhere.

```bash
bash scripts/jit-dry-run.sh --prompt "how do invoice totals work"
bash scripts/jit-dry-run.sh --base /path/to/other/tree/.claude/jit-context --file src/Billing/Total.php
```

Lints every pattern and prints which rule fired. Exit 1 = a pattern cannot be honoured or a `00-manual/` entry's frontmatter is not what its index row carries (`STALE`, i.e. you did not rebuild); 2 = it could not evaluate the tree, which is never a pass. Check both directions — a payload that must fire and one that must stay silent.
