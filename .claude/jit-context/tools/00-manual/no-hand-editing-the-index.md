---
title: 00-index.tsv is generated — edit the markdown
tool: Edit|Write
match: ~(^|[^[:alnum:]_.-])00-index[.]tsv$
mode: block
---

`rebuild-tsv.sh` is the only writer of this file. A hand edit survives until the next rebuild and then vanishes, taking whatever it fixed with it.

The `match` is anchored on the whole path and on the file name as a complete component, because it used to be the bare substring `00-index.tsv` — which also refused `docs/00-index.tsv.bak`, a backup nothing generates and nobody may not edit (#92). A sibling rule, `no-shell-writes-to-the-index.md`, covers the same write arriving through `Bash`.

It also bypasses keyword normalisation. Frontmatter written `docs.example.com` is normalised at build time and works; the same string typed straight into the TSV can never match a prompt, because dots are stripped before comparison. The entry is permanently dead and looks fine.

Edit the entry's frontmatter under `00-manual/`, then:

```bash
bash scripts/rebuild-tsv.sh
```
