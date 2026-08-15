---
title: This file is not ours — it is rewritten every scaffold
description: .oss/ and .github/workflows/oss-changelog.yml are owned by the oss plugin and overwritten by /oss:scaffold --apply; the assembler's exit codes are 0 ok / 1 skipped / 2 refused, the inverse of this repo's own tools.
match: (^|/)(\.oss/[^/]+|\.github/workflows/oss-changelog\.yml)$
---

**Anything you change here is lost at the next `/oss:scaffold --apply`.** These files are *owned templates*: the scaffold rewrites them in full on every run, by design, so upstream fixes reach every repository that uses the plugin. The right place for a change is an issue on `Digital-Process-Tools/claude-oss`, not this file.

There is one local edit in the tree today, and it is documented in place: `--untagged 0.1.0` on the `--check-links` step of `oss-changelog.yml`. `tests/test-changelog-workflow-untagged.sh` guards it, because tests are not scaffold-owned — that suite goes red in the run that clobbers the edit rather than in someone else's pull request days later. Both the flag and the suite come out when claude-oss#121 lands a `changelog.untagged` key in `.oss.json`.

## The exit codes are the inverse of this repository's

| | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `.oss/assemble_changelog.py` | ok | **skipped** — could not evaluate | **refused** — a finding |
| every tool under `scripts/` | ok | **refused** — a finding | **skipped** — could not evaluate |

`1` and `2` swap meaning at this directory boundary. A caller that tests `-ne 0` is fine; a caller that tests for a specific number and was written against `paths/00-manual/tooling.md`'s table reads a refusal as a skip, which is this repository's own defect class pointed at its release. The generated workflow gets this right — `[ "$status" -ne 2 ] || exit 1` — and it is worth re-reading rather than assuming whenever a new leg calls this script.

## What the fork under `.github/scripts/` did that this does not

It was the same lineage and it is gone. Two of its behaviours were not replaced and are now the maintainer's to carry:

- **`--title`.** Release headings were `## [x.y.z] — What was broken`. This assembler writes `## [x.y.z] - YYYY-MM-DD` and has no title argument. The eight headings above `0.3.5` keep their titles; everything cut from here on is dated instead.
- **`--plugin-json`.** The fork refused a `--version` that disagreed with `.claude-plugin/plugin.json`. Nothing checks that at fold time now. `tests/test-version-sites.sh` still compares the version sites to each other, so the release skill is where the disagreement has to be caught.

What it gained: `--check-links`, which audits `CHANGELOG.md`'s link-reference table against its release headings — the eight headings in this file had **no link refs at all** and rendered as literal bracketed text until the swap — and `--untagged`, which is how a version with a section but no tag is declared rather than given a `releases/tag/v...` URL that 404s.
