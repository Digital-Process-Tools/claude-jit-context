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

## Prove it fires

Rebuilding is not evidence, and neither is the tree you are standing in: `JIT_BASE` resolves against `$CLAUDE_PROJECT_DIR`, so a worktree's rules are inert for a session rooted elsewhere.

```bash
bash scripts/jit-dry-run.sh --prompt "how do invoice totals work"
bash scripts/jit-dry-run.sh --base /path/to/other/tree/.claude/jit-context --file src/Billing/Total.php
```

Lints every pattern and prints which rule fired. Exit 1 = a pattern cannot be honoured or a `00-manual/` entry's frontmatter is not what its index row carries (`STALE`, i.e. you did not rebuild); 2 = it could not evaluate the tree, which is never a pass. Check both directions — a payload that must fire and one that must stay silent.
