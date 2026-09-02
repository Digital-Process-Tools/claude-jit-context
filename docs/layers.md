# Layers

_Part of [claude-jit-context](../README.md). Full reference, not the getting-started arc._

Each dimension can hold several layers. **A layer is any subdirectory you create**, and the hooks read all of them — the names below are conventions, not a list the code checks.

| Layer              | Meaning                                                     |
| ------------------ | ----------------------------------------------------------- |
| `00-manual/`       | Hand-written. This is where you author.                     |
| `10-auto/`         | Reserved for a generator you supply                         |
| `20-grouped/`      | Reserved — coarser groupings                                |
| `30-crosscutting/` | Reserved — themes that span the codebase                    |

**Most projects need only `00-manual/`, and that is the whole feature.** The rest are extension points, not shipped functionality — worth understanding before you plan around them:

**Order is precedence, and the numeric prefix is what sets it.** Layers are scanned in byte order of their directory names, so `00-manual/` is read before `01-oss/` before `10-auto/`. That is the entire reason for the prefixes: a layer you add sits where its number puts it, with no list to join.

`rebuild-tsv.sh` indexes **every** subdirectory of each dimension. Drop entries into `20-grouped/` or into a `40-custom/` of your own, run the rebuild, and they are indexed and they fire. Two things are worth knowing before you plan a generator around them:

- **A rebuild rewrites a generated layer's index too.** If a generator maintains its own `00-index.tsv`, a hand-run `rebuild-tsv.sh` regenerates it from the entries' frontmatter — so those entries must carry frontmatter the rebuild can read, or a working index is replaced by a thinner one.
- **Name a layer directory with letters, digits, dot, underscore and hyphen only**, up to 64 bytes, starting with a letter or digit. A directory whose name is outside that set is refused rather than read — the name arrives with a cloned repository and is echoed nowhere — and the hook says so in what it injects, naming the layer by its position rather than by its name. The same goes for a layer directory the process cannot open, an index inside one that cannot be read, and anything past the 64th layer in a dimension. A layer that could not be loaded is **never** silent, because a rule that never loaded and a rule that never matched are indistinguishable from a session, which is what [#176](https://github.com/Digital-Process-Tools/claude-jit-context/issues/176) was.

To see which layers the matcher on your disk actually reads — measured against the hooks rather than inferred from a version number — the linter prints them first:

```bash
bash scripts/jit-dry-run.sh --base <project>/.claude/jit-context
```

```
layers the matcher reads, measured against the hooks in /path/to/scripts:
  tools        00-manual 01-oss
  paths        00-manual
  vocabulary   00-manual 01-oss
```

No generator ships with this plugin. The layers exist so that bulk-generated coverage, or a layer another tool owns and replaces wholesale, can sit beside hand-written entries without either overwriting the other — the arrangement a large codebase ends up wanting. If you are not generating entries, leave the other directories absent.

