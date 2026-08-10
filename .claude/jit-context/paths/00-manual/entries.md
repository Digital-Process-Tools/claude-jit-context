---
title: Rebuild the index or this edit does nothing
match: jit-context/.*\.md$
---

**The hooks never read this file's frontmatter. They read `00-index.tsv`.**

A frontmatter edit that has not been rebuilt is inert, and inert in the worst way: nothing errors, nothing warns, the rule simply never fires.

```bash
bash scripts/rebuild-tsv.sh    # after every frontmatter edit, without exception
```

Body edits need no rebuild — the body is read from the file at fire time. Frontmatter edits always do.

## Authoring

- Only `00-manual/` is hand-edited. `10-auto/`, `20-grouped/`, `30-crosscutting/` belong to generators.
- Prefer **paths** over keywords. The folder is the situation; keywords fire on what someone is talking about, paths on what they are touching.
- Keywords are normalised: CamelCase split, lowercased, anything outside `[a-z0-9 -]` becomes a space. A keyword written `docs.example.com` matches nothing a prompt can produce. Matching is space-bounded, so `microbilling` does not match `billing`.
- One ordinary English word fires constantly. Prefer product nouns and multi-word keys.
- `rebuild-tsv.sh` prints an ambiguity report. A keyword in more than five entries drags all five into context on one stray mention.

## `match` is an awk ERE, not PCRE

`\s` `\d` `\w` compile to the bare letter and match **nothing**, while awk exits 0 — use `[[:space:]]`, `[0-9]`, `[A-Za-z0-9_]`. `\b` is not a word boundary but a backspace character, so it also matches nothing. `\n` is the one escape that survives, and rules need it: `^` anchors the whole command string rather than each line, so anchor on `(^|[;&|\n] *)`. Such a row is now refused at load and named in the injected context instead of reading as enforced.

## Prove it fires

Rebuilding is not evidence, and neither is the tree you are standing in: `JIT_BASE` resolves against `$CLAUDE_PROJECT_DIR`, so a worktree's rules are inert for a session rooted elsewhere.

```bash
bash scripts/jit-dry-run.sh --prompt "how do invoice totals work"
bash scripts/jit-dry-run.sh --base /path/to/other/tree/.claude/jit-context --file src/Billing/Total.php
```

Lints every pattern and prints which rule fired. Exit 1 = a pattern cannot be honoured; 2 = it could not evaluate the tree, which is never a pass. Check both directions — a payload that must fire and one that must stay silent.
