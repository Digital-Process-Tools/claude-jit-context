---
title: A shell write to 00-index.tsv is still a hand edit
tool: Bash
match: ~((^|[^-])>>?[[:space:]]*|(^|[;&|\n])[[:space:]]*tee[[:space:]][^;&|\n]*|(^|[;&|\n])[[:space:]]*(sed|perl)([[:space:]][^;&|\n]*)?[[:space:]](-[a-z]*i|--in-place)[^;&|\n]*)([^[:space:];&|<>\n]*[^[:alnum:]_.-])?00-index[.]tsv([^[:alnum:]_.-]|$)
mode: block
---

`rebuild-tsv.sh` is the only writer of `00-index.tsv`. Rewriting it through the shell has exactly the consequences a hand edit through `Edit` has — it survives until the next rebuild and then vanishes, and it bypasses keyword normalisation — so it is refused for the same reason. Edit the entry frontmatter under `00-manual/`, then:

```bash
bash scripts/rebuild-tsv.sh
```

## Why this rule is a list of write forms and not the file name

The `tools` dimension is handed the payload the tool was called with. For `Edit` that is a path, and asking "is this the generated index" is a question about a path. For `Bash` it is a **command string**, and there is no honest general answer to "does this command write that file" in an awk ERE — a shell reaches the same bytes through a variable, a heredoc, a script it invokes, or a language runtime.

So this rule does not try. It names the three write forms that actually get typed — a `>`/`>>` redirect, `tee`, and an in-place `sed`/`perl`, both flag spellings — and refuses those. It is a guard against what everyone does, not a sandbox, and the difference is deliberate: the alternative is a rule anchored on the file name, which refuses `cat`, `grep` and `echo see 00-index.tsv` along with them. #76 and #79 are what a block firing on commands nobody wrote it for costs; #92 is what the missing half costs.

Three consequences worth knowing rather than discovering:

- A write form outside the list is not refused. `cp x 00-index.tsv`, a heredoc, and a python one-liner all go through.
- A `>` inside a quoted argument that also names the index — `git commit -m "wrote > 00-index.tsv"` — is refused, because a regex over a command string cannot see that the quote is still open.
- The redirect alternative excludes a `>` preceded by `-`, so `old.tsv->00-index.tsv` is prose rather than a write. The cost is that `--flag>00-index.tsv`, which no one writes, is not caught.
