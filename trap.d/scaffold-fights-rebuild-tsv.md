# /oss:scaffold --apply fights rebuild-tsv.sh over vocabulary/01-oss

Hit on 2026-09-04, clearing /oss:doctor warnings. Cost one red CI leg and one round trip.

`/oss:scaffold --apply` owns the `01-oss` rule layer and replaces it wholesale. Two of the
files it writes there are also written by this repo's own `scripts/rebuild-tsv.sh`, and the
two disagree:

- `vocabulary/01-oss/01-paths.tsv` — scaffold removes it, saying it "has never shipped a file
  by this name". `rebuild-tsv.sh` writes one beside every vocabulary layer index, `01-oss`
  included. #277 tracked it on purpose, and `tests/test-vocab-oss-paths-277.sh` asserts a
  rebuild leaves the tree clean. Removing it turns that suite red.
- `vocabulary/01-oss/00-index.tsv` — scaffold writes two columns per row, `rebuild-tsv.sh`
  writes three (a trailing empty inject field). Every apply dirties all twelve rows.

So `/oss:scaffold --apply` is never done here. It has to be followed by
`CLAUDE_PROJECT_DIR="$PWD" bash scripts/rebuild-tsv.sh` and both files committed, or CI
goes red on the pull request that refreshed the owned files.

The scaffold's own removal line says the shape of this out loud — "if something else in this
repo generates this file, deleting it now only lasts until that generator runs again" — but it
does not name a generator or say to re-run one, and nothing else does either. The suite that
catches it is a hooks leg on ubuntu, which is minutes after the mistake rather than at it.

Dimension is not decided here. A `paths/` rule on the layer would fire when someone opens one
of those files, which is not when the damage happens; the damage happens at the scaffold call.
A `tools/` rule on `scaffold.py --apply` fires at the right moment. Worth weighing both.
