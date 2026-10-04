# Releasing

`main` carries everything: the plugin, its ~90-file `tests/` tree, `docs/` and its
images, the maintainer tooling (`.oss/`, `.agents/`, `outbound/`, `trap.d/`) and a
`CHANGELOG.md` over 400 KiB. The Anthropic plugin directory's pre-submission checklist
holds any version whose plugin folder has more than 512 files, or a file of 256 KiB or
more that is not an image or font -- the full tree here is 226 tracked files and about
6.1 MB (measured on `main` at `8f282bf`, issue #437), well inside the file-count limit
but carrying three files at or over 256 KiB on its own (`docs/jit-context.png`,
`CHANGELOG.md`, and the now-split `data/generic-words.txt`).

So, as of #437 (ported from claude-remember's #851 -- see that repository's own
`docs/releasing.md`, "Reusing this in another plugin repository"), there are two
branches people can install from:

| Branch | Who reads it | What decides the version they get |
| --- | --- | --- |
| `main` | the DPT marketplace, manual installs | `version` in `.claude-plugin/plugin.json` on `main` |
| `release` | the Anthropic directory, once the listing's tracked branch is switched to it (**not done yet for this plugin** -- see "Switching the listing to `release`" below) | the latest commit on `release`, which only the release workflow writes |

`release` is built by [`.github/workflows/release-branch.yml`](../.github/workflows/release-branch.yml)
from a tag. It never shares history with `main`: each release is one commit on top of the
previous release commit, and its message names the tag and the `main` commit it came from.

**Nothing in this file has been run against a real tag yet (#437).** The workflow, the
three scripts under `.github/scripts/` and `.github/release-branch.json` were all
exercised locally (`tests/test-release-branch-437.sh`, and a manual
`build_release_tree.py` + `check_release_tree.py` + `smoke_release_tree.py` run against
this branch's own HEAD) before this file was written, but no tag has been pushed and the
directory listing still follows `main`. Facts below marked **observed** come from that
local run; facts marked **not yet observed** are carried over from claude-remember's own
sequence and have not been confirmed against this repository's first real release.

## The sequence

1. **Fold `changelog.d/` into a `## [x.y.z]` section of CHANGELOG.md and bump every
   version site**: the list lives in `.oss.json`'s `version_sites` --
   `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `CHANGELOG.md`, `README.md`
   and `SECURITY.md` for this repository (claude-remember's own list is shorter by one;
   re-read `.oss.json` rather than assuming the two repos' lists stay in step).
   *Why:* DPT-marketplace installs follow `main`, and the `version` field in
   `plugin.json` is the only thing that tells them there is something new. The tag does
   not matter to them.

2. **Run the full suite (`bash tests/run-all.sh`) and commit the release on `main`.**
   `.oss.json`'s `release.merge_method` is `"squash"` for this repository (claude-remember
   leaves it `null`, i.e. a direct commit) -- **not yet observed**: which shape the first
   real release commit here takes depends on which path `release.authority` (`"loop"`)
   actually drives it through, and that has not run yet.
   *Why:* that commit is what gets tagged; CI across three OSes (`hooks (ubuntu-latest)`,
   `hooks (macos-latest)`, `hooks (windows-latest)`, plus `fragment` and `shellcheck` --
   all five are required status checks on `main`, observed via the GitHub API) is the gate.

3. **Tag that commit `vx.y.z`** (`.oss.json`'s `release.tag_pattern` is `"v{version}"`)
   **and push the tag with your own credentials**: `git tag vx.y.z <release-commit-sha> &&
   git push origin vx.y.z`, then check it landed with
   `git ls-remote --tags origin vx.y.z`.
   *Why:* **pushing the tag is what publishes to the directory**, once the listing's
   tracked branch follows `release` (not yet true here -- see below). The tag push starts
   the `release branch` workflow (`on: push: tags: ["v*"]`, confirmed by reading the
   workflow file), and that workflow is the only thing that writes `release`. No tag, no
   directory update.
   *Why your own credentials:* a tag pushed by another workflow with `GITHUB_TOKEN` does
   not start workflows (GitHub suppresses them to prevent loops). `.oss.json`'s
   `release.authority` is `"loop"`, meaning the maintainer loop pushes the tag from its own
   checkout with the user's own forge credentials, the same way the oss plugin's release
   flow does for claude-remember.

4. **Watch the `release branch` run** (Actions tab, or `gh run list --workflow
   release-branch.yml`). It has the same two jobs claude-remember's does -- this
   workflow was copied and only its header comment and the final commit message's issue
   number were changed (#437); everything else, including `CLAUDE_CLI_VERSION:
   "2.1.287"` (observed in the workflow file, already >= the documented 2.1.281 floor),
   carried over unchanged:
   - `verify`, read-only: installs PyYAML, builds the tree from the tag, runs
     [`check_release_tree.py`](../.github/scripts/check_release_tree.py) against
     [`.github/release-branch.json`](../.github/release-branch.json)'s deny-list and
     budget, installs the pinned `claude` CLI, then runs every command in
     [`hooks/hooks.json`](../hooks/hooks.json) once in an isolated temp HOME and project
     with a fake `claude`/`codex` that refuses every call
     ([`smoke_release_tree.py`](../.github/scripts/smoke_release_tree.py)). **Observed
     locally (#437):** none of this plugin's six hook commands ever invoke `claude` or
     `codex` at all, so the fake binaries are never exercised in practice here -- they
     stay wired for the same reason claude-remember keeps them, in case a future hook
     starts to. If the npm install of the CLI fails, the run does not fail: validate is
     SKIPPED and the only trace is a `::warning::` annotation, so read the run rather than
     its status;
   - `publish`, the only job allowed to write: rebuilds the same tree, refuses to push
     unless it is byte-for-byte the tree `verify` passed, and pushes one commit to
     `release`.
   *Why two jobs:* the smoke test runs the plugin's own hooks, so it never holds a token
   that can push.

   **Not yet observed: whether `github-actions[bot]` can actually push `release` here.**
   Checked without changing anything (#437, via `gh api
   repos/Digital-Process-Tools/claude-jit-context/rulesets` and
   `.../branches/main/protection`):
   - **No repository rulesets** (`rulesets` returned `[]`).
   - **Branch protection exists only on literal `main`**, not on any pattern that would
     match a new `release` branch: required status checks (the five named above),
     required PR reviews (0 required approvals, dismiss-stale on), required linear
     history, no force pushes, no deletions, `block_creations: false`. None of these
     rules apply to a branch literally named `release` being created for the first time.
   - **`default_workflow_permissions` is `"read"`** at the repository level -- but the
     `publish` job in the workflow declares its own `permissions: contents: write`, and a
     job-level `permissions:` block overrides the repository default rather than being
     capped by it, so this is not expected to block the push. Not yet confirmed against
     a real run.
   - **Could not check organisation-level rulesets** (`gh api
     orgs/Digital-Process-Tools/rulesets` returned 404 / needs the `admin:org` token
     scope this session did not have). An org-level ruleset matching `release` across
     every repository would not show up in either check above and is the one gap this
     audit could not close.

5. **Publish the GitHub release** (`scripts/release_publish.py` from the `oss` plugin,
   not a file in this repository -- same as claude-remember; confirmed `.oss/` here
   carries only `assemble_changelog.py`, `statusline.py` and its own `README.md`, no
   release script). It runs `gh release create --verify-tag`, reading release notes from
   `CHANGELOG.md` in the maintainer's local `main` checkout, never from the release tree.
   `.oss.json`'s `release.create_release` is `true`, `draft` is `false`, `latest` is
   `true` -- **not yet observed against a real tag**.

6. **The directory picks up the new `release` commit** and scans it, once the listing's
   tracked branch has been switched to `release` (step not yet taken for this plugin --
   see below). Read the portal's **Versions** tab rather than assuming a waiting version
   is only in a queue; a **Policy hold** (the `UNREAD_ASSET_REFERENCED` /
   `VALIDATION_INCOMPLETE` findings #437 exists to clear) waits for an Anthropic reviewer
   regardless of how clean a later version is.

## What the release tree contains

[`build_release_tree.py`](../.github/scripts/build_release_tree.py) reads the tag
straight from git (`git ls-tree` and `git cat-file`; never the working tree, and never
`git archive`). Then:

- **It drops the deny-list** in [`.github/release-branch.json`](../.github/release-branch.json):
  `.agents/`, `.claude/`, `.github/`, `.oss/`, `changelog.d/`, `docs/`, `outbound/`,
  `tests/`, `trap.d/`, `.oss.json`, `.supertool.json`, `CLAUDE.md`, `CONTRIBUTING.md` --
  each checked against what `hooks/hooks.json`, the scripts those hooks and commands
  call, the skills and commands, and `.claude-plugin/plugin.json` actually load at
  runtime (#437); none of it is. `examples/`, `templates/`, `skills/`, `commands/`,
  `hooks/`, `scripts/`, `data/`, `.claude-plugin/`, `.codex-plugin/`, `LICENSE`,
  `NOTICE`, `README.md`, `SECURITY.md` and `CODE_OF_CONDUCT.md` ship.
- **It cuts CHANGELOG.md** to the latest released `## [x.y.z]` section.
- **It rewrites links** in every shipped `.md` file that point at a removed path to
  absolute URLs on `main`.
- **`README.release.md` ships AS `README.md`** (#461): a short, listing-only README with
  no `$VARIABLE`/`${...}`/`$PWD` anywhere, so the directory's `MCP_FORWARDS_CREDENTIAL_ENV`
  scan has no env-var mention to pair with the full README's own `github.com` links. The
  full README (with the logo image, the install options and the token-cost receipt) stays
  on `main` for GitHub/marketplace visitors; `README.release.md` itself is on the
  deny-list's removal list too, once its content is already copied onto `README.md` --
  it never ships under its own name.
- **Every shipped `scripts/*.sh` file that sourced another file, or ran another
  `scripts/` file, is compiled into one self-contained file** (#461,
  `.github/scripts/compile_scripts.py`): `common.sh`/`common-awk.sh`/`host.sh` are
  inlined into each of the six hooks and `jit-doctor.sh`/`jit-stats.sh`/
  `jit-match.sh`/`jit-dry-run.sh`/`rebuild-tsv.sh`, and `jit-misses.sh`/`rebuild-tsv.sh`'s
  own subprocess calls (from `session-start-hook.sh`, `jit-stats.sh`, `jit-init.sh`) are
  replaced with a function defined with a `()` (subshell) body, called in place of the
  external process it replaces -- same argv, stdout, stderr and exit-status contract.
  Whole-line comments and blank lines are stripped from the result (conservatively: only
  where the scan can prove, by tracking bash quoting state across the whole file, that a
  line sits outside every string), which is what keeps a compiled hook under the
  directory's 256 KiB per-file limit despite carrying several files' worth of content.
  `main` keeps the commented, multi-file sources untouched -- this only runs at build
  time, against git blobs. `common.sh`, `common-awk.sh` and `host.sh` themselves are then
  added to the deny-list's removal set: nothing loads them by path any more. Two
  documented exceptions stay real subprocess calls rather than being inlined --
  `jit-dry-run.sh` and `jit-match.sh` drive the hooks directly for their own dry-run/
  cross-check feature, from neither of which hooks.json nor commands/*.md ever reaches
  them, and inlining would blow the 256 KiB budget on its own (measured at 305 KB) to
  solve a hold that was never reachable from either file in the first place --
  `check_release_tree.py`'s own guard names both allowed call sites explicitly, so a
  third one added later still fails it.
- **`check_release_tree.py` fails if any shipped `scripts/*.sh` file still sources or
  dot-loads another file, or runs another `scripts/` file as a subprocess** (#461), with
  the same two named exceptions above allow-listed by their exact text.
- **`data/generic-words.txt` was split into `data/generic-words/chunk-NN.txt`** (#437),
  each comfortably under 256 KiB, specifically so it survives the directory's per-file
  limit without being denied -- `rebuild-tsv.sh` and `jit-misses.sh` both read it on a
  user's own machine, so unlike `docs/` or `tests/` it cannot simply be left out of the
  tree. Concatenating the chunks in name order reproduces the original file byte for
  byte; see `data/generic-words/README.md`.

**Observed locally (#461):** building from this branch's own `HEAD` produced 45 files
kept and 181 removed by the deny-list, and `check_release_tree.py` passed clean against
that tree -- the largest compiled script measured under 100 KB, well inside the 256 KiB
limit. `claude plugin validate --strict` and `smoke_release_tree.py --validate require`
both passed against the same built tree, with CLI 2.1.287.

## When the workflow fails

Nothing is pushed. `release` stays on the previous release (or does not exist yet, on
the very first run), so the directory keeps serving that, and people on `main` are not
affected at all. Fix the cause on `main`, then run the workflow again for the same tag:
**Actions, `release branch`, Run workflow, ref = `vx.y.z`**, or

```bash
gh workflow run release-branch.yml -f ref=vx.y.z
```

## Building and checking locally

```bash
python3 .github/scripts/build_release_tree.py --ref vX.Y.Z --out /tmp/release-tree
python3 .github/scripts/check_release_tree.py /tmp/release-tree
python3 .github/scripts/smoke_release_tree.py /tmp/release-tree --validate auto
```

`tests/test-release-branch-437.sh` runs the same three scripts against the current
commit as a composition regression guard (what ships, what the deny-list drops, the
directory's own checklist), and is part of `bash tests/run-all.sh`.
`tests/test-release-branch-461.sh` is the companion BEHAVIORAL guard: --help and a
fixed hook payload, byte for byte, source vs compiled, plus the real hook-driving test
suites run a second time against the tree it builds. Both run in `release-branch.yml`'s
`verify` job before a tag is ever published, not only locally.

## How the directory decides what to read

The directory follows **one branch or tag**, set in the developer portal
(claude.ai/directory/manage, the plugin's page, Settings, Source, "Tracked branch or
tag"). **Not yet switched for this plugin (#437):** claude-remember's own listing moved
to `release` only after that repository's `release` branch already existed and was
checked to hold only the slim tree -- the same order applies here: cut a release through
the sequence above first, confirm `release` exists and is slim, and only then change the
portal field. Left on the default branch (`main`) until that switch, every merge to
`main` still shows up in the portal's **Versions** tab as a new version to check, which
is the `UNREAD_ASSET_REFERENCED` / "Validation didn't finish" hold #437 exists to clear.

## Contacting Anthropic about a plugin

Per claude.com, "Track your directory submission": open the plugin's menu in the portal
and choose **Get help** or **Contact Anthropic**, or email `directory@anthropic.com`.
Include the listing name, the organisation and the status the portal shows.
