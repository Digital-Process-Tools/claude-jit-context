# changelog.d — one file per change

Do not edit `CHANGELOG.md` in a pull request. Add a file here instead:

```
changelog.d/65.fixed.md
changelog.d/31.changed.md
changelog.d/44.added.second-entry.md
```

`<issue>.<section>[.<slug>].md`, where `<section>` is one of the Keep a Changelog
headings — `added`, `changed`, `deprecated`, `removed`, `fixed`, `security`. The optional
slug lets one issue file two entries in one section without two PRs colliding on a path,
which is the whole point of the directory.

The **content is the entry exactly as it would appear** under that heading — a
`- **Bold summary** (#65). Prose.` bullet, with as many indented paragraphs after it as
the change deserves. Nothing is reformatted, and nothing here is a heading: the assembler
writes `## [x.y.z] — Title` and `### Fixed` itself.

Why: measured here on 2026-08-12, four hand-resolutions of `CHANGELOG.md` in one
afternoon. The conflicts were structural, not accidental — two changes to different files
still collided, because both described themselves in the same twenty lines of one file
(#66). One of them, left to an automatic union, would have emitted two `### Added`
headings under a single `[Unreleased]`; another would have reparented unreleased entries
into a released section. Two PRs never touch the same path here.

The convention and the tool come from
[`claude-supertool`](https://github.com/Digital-Process-Tools/claude-supertool), which
has run this for ~30 releases. **The issue numbers cited below are theirs**, and they are
kept rather than stripped: a rule with somebody else's receipt is still a rule with a
receipt, and every one of them was paid for in a shipped release.

## Nothing outside this directory may name your fragment by path

The release *consumes* fragments: `.oss/assemble_changelog.py` folds the prose
into `CHANGELOG.md` and deletes the file. So a test, a doc example, a fixture or a
jit-context entry keyed to `changelog.d/<n>.<section>.md` is green for exactly the window
between your PR and the next tag, and red on that tag and every tag after — and the
window is invisible from inside your own PR, because the file is there the whole time
your CI runs.

That has shipped four times over there.
[#941](https://github.com/Digital-Process-Tools/claude-supertool/issues/941) reddened
five legs on v0.26.0,
[#953](https://github.com/Digital-Process-Tools/claude-supertool/issues/953) thirteen of
twenty on v0.27.0, and
[#1231](https://github.com/Digital-Process-Tools/claude-supertool/issues/1231) thirteen
of twenty-two on v0.33.0 — that last one was not an assertion at all, just a filename in
a tuple of paths a test swept, which is why "do not assert a fragment exists" was too
narrow a rule
([#1293](https://github.com/Digital-Process-Tools/claude-supertool/issues/1293)).

Point at **`CHANGELOG.md`** instead, where this fragment's prose lands and stays.

`tests/test-changelog-fragment-refs.sh` is the bash port of their guard: it refuses any
tracked text file, in any language, that names a fragment currently on disk. Naming an
*already consumed* fragment is fine and common — the `65.fixed.md` examples on this page
are of that kind — because nothing the next tag deletes is called that.

Their `assert_change_is_findable()` helper and the meta-test that parses the suite for
its shape are **not** ported. Those back a per-change convention this repository does not
have, and a harness for an assertion nobody writes is coverage of nothing.

## The entry has to name its own issue

`(#65)` anywhere in the body, or a link whose URL ends in `/issues/65` — the opening
example above does both, and that is why it is the shape to copy. The filename is the
only structural place the number lives and the release deletes the file, so an entry that
never says it ships unfindable: 8 of the 20 entries in v0.32.0 and 6 of the 28 in v0.33.0
named every issue but their own
([#1251](https://github.com/Digital-Process-Tools/claude-supertool/issues/1251)).
`--check` refuses a fragment that omits it, so you hear about it in your own PR rather
than from a release commit.

A bare `65` does not count, and `#38` does not satisfy issue 3 — the number is compared,
not searched for as a substring.

## A `removed` fragment has to declare compatibility

A `removed` fragment must say whether the removal breaks anything, as an ordinary bullet
in the body:

```markdown
- Compatibility: breaking|compatible - <reason>
```

The release number is proposed from these fragments, and the `oss` plugin's
`release_version.py` reads that bullet to propose it. A `removed` fragment that declares
nothing **stops the proposal** rather than defaulting quietly — a patch bump over a
breaking change is indistinguishable in the tag from a considered one. A word that is
neither `breaking` nor `compatible` stops it too, so a value nothing recognises never
grades as compatible.

The reason after the verdict is required. A bare flag is the same unsourced verdict one
field further along, and the sentence is the part worth having.

Only `removed` is required to carry one. Every other section may, and a fragment that says
nothing is read as compatible with the count of such fragments reported out loud. A field
on every fragment is a field on every fragment to get wrong, so it is required exactly
where the question is genuinely open.

It is a plain bullet rather than frontmatter, so the assembler needs no special case and
the claim ships into `CHANGELOG.md` where a user reads it, instead of being metadata
deleted at the fold.

## A fragment is bullets and prose, and the guard is a CommonMark parser

A fragment is inserted into `CHANGELOG.md` **verbatim**, so a line here that CommonMark
reads as a heading or a link-reference definition becomes one in the released file — it
reparents the entries below it, and a definition planted here sits above anything further
down, where the *first* definition of a label is the one that resolves
([#923](https://github.com/Digital-Process-Tools/claude-supertool/issues/923),
[#930](https://github.com/Digital-Process-Tools/claude-supertool/issues/930),
[#934](https://github.com/Digital-Process-Tools/claude-supertool/issues/934),
[#936](https://github.com/Digital-Process-Tools/claude-supertool/issues/936)).

`--check` parses your fragment with `markdown-it-py` and refuses it if the token stream
holds any of these, **at any depth**:

- a heading — ATX (`# x`), setext (a `===` or `---` underline), or an `<h1>` tag, and it
  makes no difference whether it is nested in a list, a quote or both;
- a link-reference definition, however it is spelled — split across lines, with an
  escaped bracket, lowercased, behind a `>`;
- raw HTML, block-level or inline.

It also refuses a fence that does not close inside the fragment, a tab, an empty file,
and a fragment whose top level is not a single `-` bullet list — that last one is not
about safety, it is what the balance guard is counting when the assembler proves the cut
lost nothing. Findings name the file and the line, so they land on your PR rather than in
front of whoever is cutting the release.

**Three attempts at doing this with patterns lost, so there is no pattern.**
[#927](https://github.com/Digital-Process-Tools/claude-supertool/pull/927) anchored at
column 0 and #930 found three bypasses;
[#932](https://github.com/Digital-Process-Tools/claude-supertool/pull/932) widened to 0-3
spaces and #934 found six more;
[#935](https://github.com/Digital-Process-Tools/claude-supertool/pull/935) inverted to a
whitelist with its own fence state machine and #936 walked through the fence. Every one
of those was the same shape — the scanner disagreed with CommonMark — so the guard and
the reader are one parser now. If a construct is inert to a renderer it is accepted here,
and if it is not, it is refused, without either judgement being re-derived by hand.

There is deliberately **no text-scanning fallback**. Without `markdown-it-py` the tool
reports that it could not look and exits `2`; it never reports `ok`.

**A bullet may open with a link.** `- [#123](url) fixed the thing.` is an ordinary entry;
so is a wrapped continuation line that begins with one. An inline link can never be a
link-reference definition.

**To quote a heading in prose — which entries here do all the time — put it in a fenced
code block at the bullet's own indent:**

````
- **Renamed the release heading** (#923). It now reads:

  ```markdown
  ## [Unreleased]
  ```
````

**A fence, not an indent, and this is the part that was wrong before.** CommonMark's
four-column code-block threshold is relative to the containing block's content column,
and a `- ` bullet's content column is 2 — so inside a fragment, four spaces is *two*
relative columns: an ordinary paragraph, in which a heading is a live heading and a
link-reference definition resolves. Rendered through a real CommonMark parser inside a
bullet, a definition is live at 2, 4, 5 and tab indent; the threshold is 6.

**Close the fence at the bullet's indent too, and this is #936's whole subject.** A code
block takes no lazy continuation, so a line that reaches column 0 inside your fence ends
the fence, the bullet and the list — and whatever you thought you were quoting is then
live at document level, exactly as if there were no fence at all.

## Python, under `.github/`, and why that is not the rule being broken

`README.md` promises `bash` + `awk` + `perl`, "no `jq`, no Python, no Node". That promise
is about **the runtime** — the four hooks in `scripts/`, which run inside your session on
every prompt and every tool call, with no install step. This assembler runs in CI and on
a maintainer's machine at a tag, and never in a session. It is the same line
`.claude/jit-context/paths/00-manual/tooling.md` already draws between the hooks and
`rebuild-tsv.sh`: those fail loudly where the hooks must never fail at all.

It lives under `.github/scripts/` rather than `scripts/` so that the separation is
structural and not a sentence somebody has to find. **Nothing in `.github/` ships inside
the plugin.** If you are adding a dependency to anything under `scripts/`, the answer is
still no.

## At release

```bash
python3 -m pip install markdown-it-py
python3 .oss/assemble_changelog.py --check                                    # on every PR
python3 .oss/assemble_changelog.py --version 0.4.0 --changelog CHANGELOG.md --dir changelog.d
```

Bump `.claude-plugin/plugin.json` **first**, and check it yourself. The fork this
assembler replaced verified `--version` against the manifest and refused on
disagreement; this one takes your word for it, so `tests/test-version-sites.sh` is
the only thing left comparing the sites and it has to run before the tag.

Its exit codes are **`0` ok, `1` skipped, `2` refused** — the inverse of every tool
under `scripts/`. The file itself is owned by the `oss` plugin and rewritten by every
`/oss:scaffold --apply`, so a change to it goes upstream rather than into the file.

The assembler folds every fragment into a new `## [x.y.z] - YYYY-MM-DD` section, **merges into
the `###` headings the existing `[Unreleased]` body already carries** rather than opening
a second one, leaves an empty `[Unreleased]` behind, refuses unless the entries it
produced equal the entries it was given, **re-parses the file it is about to write** and
refuses unless its headings are the old ones plus exactly what this run wrote, and only
then deletes the fragments. Exit codes are documented at the top of the script — 0 ok, 1
skipped, 2 refused — and the suite driving every one of them is upstream, in the `oss`
plugin, along with the script.
