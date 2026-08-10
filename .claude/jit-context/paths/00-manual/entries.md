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

## Prove it fires

Rebuilding is not evidence. Drive the hook, and check both directions — a payload that must fire and one that must stay silent.

```bash
export CLAUDE_PROJECT_DIR="$PWD"
bash scripts/session-start-hook.sh                       # clears `once` markers
echo '{"prompt":"how do invoice totals work"}' | bash scripts/pre-prompt-hook.sh
```

`{}` means no match.
