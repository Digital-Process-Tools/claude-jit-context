---
title: The version lives in three files
match: \.claude-plugin/plugin\.json$
---

Bumping the version here is one of three edits. The other two:

- `README.md` — the version badge, near the top
- `CHANGELOG.md` — a new section, not an appended line

Sweep for the **outgoing** value before finishing, with no path filter:

```bash
git grep -n "0\.2\.0"
```

A filtered sweep cannot see a file whose extension you forgot to list — which is exactly how a badge sits stale for a year. A sweep for the incoming value only finds sites already half-bumped, and cannot find a site frozen at some third value: check the badge by eye.

`CHANGELOG.md` says what changed and why the previous design was wrong. It does not sell. `0.2.0` opens with "the documentation described a design that no longer existed" — that is the register.

A version that was never tagged is still unreleased: amend its CHANGELOG entry rather than opening a new one for work that changed no scripts. Semver versions the code, not the documentation.

## Cutting the release, in order

```bash
./supertool 'gh-branch:main'          # 1. green, and green on THIS commit
git tag -a v0.2.0 -m "..." && git push origin v0.2.0
gh release create v0.2.0 --title "..." --notes "..."
```

1. **CI green on the exact commit you are about to tag** — `gh-branch:main` reports the head SHA it judged, so a stale run cannot pass for a current one.
2. **Tag, then push the tag** — `git push` alone does not carry tags.
3. **Create the GitHub release** against that tag, notes from the CHANGELOG section.
4. **Add or update the entry in [`claude-marketplace`](https://github.com/Digital-Process-Tools/claude-marketplace)** — `/plugin install claude-jit-context@dpt-plugins` resolves through `.claude-plugin/marketplace.json` there, not through this repo. The README documents that install command, so until the marketplace entry exists the first instruction a new user follows fails.

Marketplace entries name the repo, not a version — users get the default branch. A tag is therefore for humans and the changelog, not a pinning mechanism: whatever is on `main` is what installs.
