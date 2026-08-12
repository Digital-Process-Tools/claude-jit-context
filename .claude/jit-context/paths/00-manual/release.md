---
title: The version lives in three files
description: plugin.json, the README badge and the CHANGELOG heading must agree, and the sweep that finds any site they forgot.
match: \.claude-plugin/plugin\.json$
---

Bumping the version here is one of three edits. The other two:

- `README.md` — the version badge, near the top
- `CHANGELOG.md` — a new section, **assembled, not hand-written**:

```bash
python3 .github/scripts/assemble_changelog.py --version 0.4.0 --title "Section title"
```

Bump this file **first**: the assembler takes `--version` as an argument and verifies it against `plugin.json`, refusing on disagreement. It folds every `changelog.d/<issue>.<section>.md` fragment into the new section, merges into the `###` headings the existing `[Unreleased]` body already carries rather than opening a second one, leaves an empty `[Unreleased]` behind, re-parses the assembled file to prove it gained no heading, link ref or raw HTML the run did not write, and deletes the fragments. `changelog.d/README.md` is the convention; the exit codes are at the top of the script, and they are `jit-dry-run.sh`'s — 0 ok, 1 refused, 2 could not evaluate.

It needs `markdown-it-py` (`python3 -m pip install markdown-it-py`). It is Python and it is not the runtime: nothing under `.github/` ships inside the plugin.

Sweep for the **outgoing** value before finishing, with no path filter:

```bash
git grep -n "0\.2\.0"
```

A filtered sweep cannot see a file whose extension you forgot to list — which is exactly how a badge sits stale for a year. A sweep for the incoming value only finds sites already half-bumped, and cannot find a site frozen at some third value: check the badge by eye.

`CHANGELOG.md` says what changed and why the previous design was wrong. It does not sell. `0.2.0` opens with "the documentation described a design that no longer existed" — that is the register.

A version that was never tagged is still unreleased: amend its CHANGELOG entry rather than opening a new one for work that changed no scripts. Semver versions the code, not the documentation.

## Cutting the release, in order

```bash
python3 .github/scripts/assemble_changelog.py --version 0.2.0 --title "..."  # 0. after the bumps
./supertool 'gh-branch:main'          # 1. green, and green on THIS commit
git tag -a v0.2.0 -m "..." && git push origin v0.2.0
gh release create v0.2.0 --title "..." --notes "..."
```

0. **Assemble the changelog and commit it**, before the green check — the assembled `CHANGELOG.md` heading is one of the three sites `tests/test-version-sites.sh` compares, so a tag cut before the fold is a tag whose CI never saw the file it ships.
1. **CI green on the exact commit you are about to tag** — `gh-branch:main` reports the head SHA it judged, so a stale run cannot pass for a current one.
2. **Tag, then push the tag** — `git push` alone does not carry tags.
3. **Create the GitHub release** against that tag, notes from the CHANGELOG section.
4. **Add or update the entry in [`claude-marketplace`](https://github.com/Digital-Process-Tools/claude-marketplace)** — `/plugin install claude-jit-context@dpt-plugins` resolves through `.claude-plugin/marketplace.json` there, not through this repo. The README documents that install command, so until the marketplace entry exists the first instruction a new user follows fails.

Marketplace entries name the repo, not a version — users get the default branch. A tag is therefore for humans and the changelog, not a pinning mechanism: whatever is on `main` is what installs.
