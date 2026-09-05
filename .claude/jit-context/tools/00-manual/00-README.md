# Declined traps — tools/00-manual

One line per trap this layer decided not to carry, so the next lane to hit the same
thing sees a decision rather than an absence. `rebuild-tsv.sh` skips this file by name,
so nothing here is ever indexed or injected.

- **scaffold-vs-rebuild-tsv** (2026-09-04). `/oss:scaffold --apply` deletes
  `vocabulary/01-oss/01-paths.tsv` and writes a two-column `00-index.tsv` where
  `rebuild-tsv.sh` writes three, so every apply leaves the tree in a state CI rejects
  unless a rebuild follows it. Declined rather than promoted: the rule would have said
  "now remember to run the other command", which is the friction written down rather
  than a fix. `scaffold.py` already classifies that file as another writer's — its own
  `_rule_layer_shape()` returns False for it and `_RULE_REMOVE_FOREIGN_REASON` names
  this exact instance — and deletes it anyway; and oss declares `claude-jit-context` in
  its dependencies, so it can run the generator instead of guessing its format. Filed
  upstream as `Digital-Process-Tools/claude-oss#1042`. Until it lands, follow every
  `--apply` with `CLAUDE_PROJECT_DIR="$PWD" bash scripts/rebuild-tsv.sh` and commit both
  files.
