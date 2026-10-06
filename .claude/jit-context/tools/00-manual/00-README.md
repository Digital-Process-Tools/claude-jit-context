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

- **wrong-worktree-edits** (2026-10-06, `trap.d/437.wrong-worktree-edits.md`). A `supertool
  edit`/`paste`/`batch` call sent without its own `cd <worktree> &&` prefix landed in the main
  clone instead of the worktree a task was meant to edit -- caught only by a later fixture run
  behaving as if the old code were still there. Declined rather than promoted: there is no ERE
  that can distinguish "this call already has a same-call `cd` prefix" from "it does not"
  without lookbehind, which awk's dialect does not have (per `paths/00-manual/entries.md`), so
  the only matchable rule here would fire on every `edit`/`paste`/`batch` call in the whole
  repository, correctly-prefixed ones included -- noise on every legitimate call to catch a rare
  miss. The op's own `[branch: ...]` receipt line already names which branch a write landed on,
  checkable after the fact on exactly the calls that need it. See the parallel
  `paths/00-manual/00-README.md` entry for the same decision.
