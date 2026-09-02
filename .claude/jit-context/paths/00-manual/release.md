---
title: The version lives in five files
description: both plugin manifests, the README badge, the CHANGELOG heading and SECURITY.md must agree, and the sweep that finds any site they forgot.
match: \.(claude|codex)-plugin/plugin\.json$
---

Bumping the version here is one of five edits. `.oss.json`'s `version_sites` is the list, and `tests/test-version-sites.sh` is what compares them. The other four:

- `.codex-plugin/plugin.json` — the Codex manifest (#289). One plugin, one version: a second manifest that drifts ships stale metadata silently, and `tests/test-host-registry.sh` fails when the two disagree.
- `README.md` — the version badge, near the top
- `SECURITY.md` — the supported minor, which is a minor and not a full version
- `CHANGELOG.md` — a new section, **assembled, not hand-written**:

```bash
python3 .oss/assemble_changelog.py --version 0.4.0 --changelog CHANGELOG.md --dir changelog.d
```

It folds every `changelog.d/<issue>.<section>.md` fragment into the new section, merges into the `###` headings the existing `[Unreleased]` body already carries rather than opening a second one, leaves an empty `[Unreleased]` behind, re-parses the assembled file to prove it gained no heading, link ref or raw HTML the run did not write, advances the `[Unreleased]` link ref and writes one for the new version, and deletes the fragments. `changelog.d/README.md` is the convention.

**Two things this assembler does not do, and the second is why you bump `plugin.json` first anyway:**

- The heading is `## [0.4.0] - YYYY-MM-DD`. There is no `--title`. The titled headings above `0.3.5` are what the old fork wrote; nothing adds one now.
- **It does not check `--version` against `plugin.json`.** The fork refused on disagreement; this one takes your word. `tests/test-version-sites.sh` is the only thing comparing the sites, so run it before the tag, not after.

**Its exit codes are not `jit-dry-run.sh`'s.** `0` ok, **`1` skipped**, **`2` refused** — the inverse of every tool under `scripts/`. `paths/00-manual/vendored-oss.md` is the subject; the file itself is scaffold-owned and an edit to it is lost at the next `/oss:scaffold --apply`.

It needs `markdown-it-py` (`python3 -m pip install markdown-it-py`), and it is not the runtime: nothing under `.oss/` ships inside the plugin.

Sweep for the **outgoing** value before finishing, with no path filter:

```bash
git grep -n "0\.2\.0"
```

A filtered sweep cannot see a file whose extension you forgot to list — which is exactly how a badge sits stale for a year. A sweep for the incoming value only finds sites already half-bumped, and cannot find a site frozen at some third value: check the badge by eye.

`CHANGELOG.md` says what changed and why the previous design was wrong. It does not sell. `0.2.0` opens with "the documentation described a design that no longer existed" — that is the register.

A version that was never tagged is still unreleased: amend its CHANGELOG entry rather than opening a new one for work that changed no scripts. Semver versions the code, not the documentation.

## Cutting the release, in order

```bash
python3 .oss/assemble_changelog.py --version 0.2.0 --changelog CHANGELOG.md --dir changelog.d  # 0. after the bumps
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
