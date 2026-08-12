#!/usr/bin/env python3
"""Assemble `changelog.d/` fragments into a release section of `CHANGELOG.md` (#66).

Ported from `Digital-Process-Tools/claude-supertool`, which has run this for ~30
releases. Every rule here has a receipt, and most of them were paid for over
there; the issue numbers in the comments below are theirs, and they are kept
because a rule with somebody else's receipt is still a rule with a receipt.

Measured here on 2026-08-12: four hand-resolutions of `CHANGELOG.md` in one
afternoon. The conflicts were structural, not accidental — two changes to
different files still collided, because both described themselves in the same
twenty lines of one file. One of them, left to an automatic union, would have
emitted two `### Added` headings under a single `[Unreleased]`; `merge=union` is
not a fix, because a duplicated heading reparents everything between the two
copies.

**This is Python, and that is not the runtime rule being broken.** `README.md`
promises `bash` + `awk` + `perl`, "no `jq`, no Python, no Node", and that promise
is about *the hooks* — the four scripts that run inside a stranger's session on
every prompt and every tool call. This file runs in CI and on a maintainer's
machine at a tag, never in a session, which is the same line
`.claude/jit-context/paths/00-manual/tooling.md` already draws for
`rebuild-tsv.sh`: those fail loudly where the hooks must never fail at all. It
lives under `.github/` rather than `scripts/` so that the separation is
structural and not a sentence somebody has to find — nothing in `.github/` ships
inside the plugin.

The one dependency is `markdown-it-py`, and it is the point (supertool #936).
See "the guard and the reader are one parser" below.

**Three outcomes, never two.** This script can `ok`, it can produce a `finding`
(refused, naming the file), and it can `skip` — and it says which, every run. An
assembler that finds no fragments and exits 0 has reported "released" when what
happened is "nothing to release", which is this repository's own defect class:
an absence produced by a tool, read as an absence in the world.

    python3 .github/scripts/assemble_changelog.py --version 0.4.0 --title "..."
    python3 .github/scripts/assemble_changelog.py --check    # CI: names *and* bodies
    python3 .github/scripts/assemble_changelog.py --count    # exact fragment count

Exit codes: **0 ok, 1 refused (a finding), 2 could not evaluate.** That is
`jit-dry-run.sh`'s mapping and `tooling.md`'s contract, and it is deliberately
NOT the upstream script's, which has 1 and 2 the other way round. A fifth tool in
this repo with inverted exit codes is exactly the trap this repo exists to
describe, so the constants below are swapped and this sentence is why.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Sequence, Tuple

try:
    import markdown_it as _markdown_it
    from markdown_it import MarkdownIt as _MarkdownIt
except Exception as _import_error:  # pragma: no cover - exercised by the suite
    _markdown_it = None
    _MarkdownIt = None
    _MD_IMPORT_ERROR = "{0}: {1}".format(type(_import_error).__name__, _import_error)
else:
    _MD_IMPORT_ERROR = None

_MD_VERSION = getattr(_markdown_it, "__version__", "unknown")

REPO = Path(__file__).resolve().parents[2]

#: Keep a Changelog 1.1.0, in the order the spec lists them. The order is data,
#: not a sort: "Added" before "Fixed" is a convention readers rely on, and
#: alphabetical would put Security second.
SECTIONS = ("added", "changed", "deprecated", "removed", "fixed", "security")

#: `<issue>.<section>[.<slug>].md`. The slug exists so one issue can file two
#: entries in one section without the two PRs colliding on a path again.
#: `\Z` and not `$`. A POSIX filename may end in a newline, and `$` matched
#: before one — so a name ending in a newline parsed as a fragment, got folded
#: into the release and then deleted as consumed (supertool #1188).
_NAME_RE = re.compile(r"^(\d+)\.([a-z]+)(?:\.([A-Za-z0-9][A-Za-z0-9._-]*))?\.md\Z")

_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+\Z")  # \Z, not $ — supertool #1188

#: Not fragments, and not mistakes either — refusing these would make the
#: directory unable to document itself.
_IGNORED = {"README.md", ".gitkeep", ".gitignore"}

#: The guard and the reader are the same parser (supertool #936).
#:
#: Three rounds of hand-written Markdown scanning produced three bypasses over
#: there, and each fix opened the next hole. #927 anchored its patterns at column
#: 0 and #930 found three ways past. #932 widened them to 0-3 leading spaces and
#: made labels case-insensitive, and the next audit found six more plus a false
#: refusal plus a prescribed remedy that was itself an injection. #934 inverted
#: to a whitelist resting on a positional guarantee and its own fence state
#: machine, and #936 walked straight through the fence: a column-0 line inside an
#: open fence was skipped with no indent check and no opener check, so
#: `# INJECTED HEADING` was copied verbatim into the released file under a
#: receipt that said `ok`.
#:
#: Every one of those is the same shape — **the scanner disagreed with
#: CommonMark.** Column 0 versus 0-3 leading spaces; ATX versus setext; a
#: hand-rolled fence state machine versus the real one; info-string handling
#: versus the spec's, which forbids a backtick inside a backtick fence's info
#: string. That race is not winnable by patching patterns, and a fourth attempt
#: would have lost it the same way.
#:
#: `markdown-it-py` is a CommonMark reference implementation. It is the guard
#: itself, so the guard and the reader agree by construction, which is the only
#: property that closes the class rather than the instance.
#:
#: **What the guard establishes**, which is also everything it claims: parsed as
#: CommonMark, the fragment produces no heading, no link-reference definition and
#: no raw HTML at any depth; every fence it opens closes inside it; and its top
#: level is one `-` bullet list, which is what `_entry_count` is counting when the
#: balance guard proves nothing was lost.
#:
#: **What it does not establish** is that the released file is sound, because a
#: fragment is validated alone and inserted into a document. So the write is
#: verified separately, against the assembled text — see `_verify_written`. One
#: guard has been wrong three times; the second layer is what makes a fourth
#: survivable.
_BULLET = "- "

#: Token types that restructure a document, at any depth. `heading_open` covers
#: ATX and setext alike because the parser has already resolved which is which.
#: `html_inline` is here because `<h1>` mid-paragraph is not an `html_block` and
#: renders the same heading — the previous guard refused a line *starting* with
#: `<` and said so in its message, and putting the same tag after a word sailed
#: past. Link-reference definitions are not tokens at all; they are collected
#: into the parse environment, which is checked alongside these.
_REFUSABLE = {
    "heading_open": "a Markdown heading",
    "html_block": "a raw HTML block, which renders as a heading without being one",
    "html_inline": "raw HTML inside a paragraph, which renders a heading tag",
}

_SHAPE = ("a fragment is `- ` bullets at column 0 plus lines indented under "
          "them, and parsed as CommonMark it may hold no heading, no link ref "
          "definition and no raw HTML at any depth")

_REMEDY = ("To show one in an entry, put it in a fenced code block at the "
           "bullet's own indent, which is what every fenced example in "
           "CHANGELOG.md already does — and close the fence at that same "
           "indent, because a line reaching column 0 ends the bullet, the "
           "fence and the list, whatever the fence was meant to be hiding "
           "(supertool #936). Indenting further is not a remedy: inside a `- ` "
           "bullet an indented line is still a live heading and a live "
           "definition, which is what the advice this message used to give got "
           "wrong (supertool #934).")

#: Said in full wherever a run cannot validate, because the alternative is a
#: receipt with nothing behind it — which is the thing this file exists to stop
#: being possible.
_NO_PARSER = (
    "markdown-it-py is not importable ({0}), so nothing can be established "
    "about these fragments and nothing is claimed. Install it — "
    "`python3 -m pip install markdown-it-py` — and run again. There is "
    "deliberately no text-scanning fallback: three of them shipped upstream and "
    "all three were bypassed within one audit (#930, #934, #936), so a fallback "
    "here would be the same bug wearing a receipt.")


class CannotValidate(Exception):
    """The tool cannot answer. Not a finding, and emphatically not an `ok`."""


def _parser():
    if _MD_IMPORT_ERROR is not None or _MarkdownIt is None:
        raise CannotValidate(_NO_PARSER.format(_MD_IMPORT_ERROR or "unavailable"))
    return _MarkdownIt("commonmark")


def _flatten(tokens: Sequence, line: Optional[int] = None) -> Iterator[Tuple[object, int]]:
    """Every token in document order, each with the nearest line it maps to.

    Inline tokens carry no map of their own, so they inherit their block's. A
    finding without a line number sends the author hunting, and the author is the
    person standing in CI when this fires.
    """
    for token in tokens:
        at = token.map[0] if token.map else line
        yield token, (at if at is not None else 0)
        if token.children:
            for pair in _flatten(token.children, at):
                yield pair


def _finding(name: str, number: int, what: str, line: str) -> str:
    """One refusal, naming the file, the line number, the shape and the remedy."""
    return ("{0}:{1}: {2} — {3}. Inserted verbatim into CHANGELOG.md, this line "
            "becomes one. {4} Line: {5}"
            .format(name, number, what, _SHAPE, _REMEDY, line.strip()[:120]))


def _line_of_reference(md, lines: Sequence[str], label: str) -> int:
    """The first line at which `label` becomes a definition, per the parser.

    Bisecting the parse rather than matching a pattern: a definition's label may
    run across lines and may carry escaped brackets, and every regex upstream
    owned for that shape has been wrong. Fragments are a handful of lines, so the
    cost of re-parsing prefixes is not worth a cleverer answer.
    """
    for count in range(1, len(lines) + 1):
        env: Dict = {}
        md.parse("\n".join(lines[:count]) + "\n", env)
        if label not in env.get("references", {}):
            continue
        # `count` is where it *ends*. Its own first line is the largest start
        # whose slice still defines the label, so a definition split across lines
        # is reported where the author began writing it rather than where the
        # parser happened to finish reading it.
        for start in range(count, 0, -1):
            env = {}
            md.parse("\n".join(lines[start - 1:count]) + "\n", env)
            if label in env.get("references", {}):
                return start
        return count
    return 1


def _fence_is_closed(lines: Sequence[str], token) -> bool:
    """Whether a fence token's own last line is its closer.

    markdown-it closes an unterminated fence at the end of its container and
    reports no error, so a fence that runs on is indistinguishable from one that
    closed unless the source is consulted. A one-line fence never closed;
    otherwise the last line of the token's span has to be a bare run of the
    opening character, at least as long as the opener.
    """
    if not token.map or token.map[1] - token.map[0] < 2:
        return False
    closer = lines[token.map[1] - 1].strip()
    marker = (token.markup or "`")[0]
    return bool(closer) and set(closer) == {marker} and len(closer) >= len(token.markup)


def _structure_findings(name: str, lines: Sequence[str], tokens: Sequence) -> List[str]:
    """The shape rule, derived from the parse instead of from line prefixes.

    `_entry_count` counts lines beginning `- ` and the balance guard trusts that
    count to prove the cut lost nothing. So the top level has to be one `-`
    bullet list whose items start at column 0, or the arithmetic and the document
    disagree and a lossy cut reports as a clean one. Asking the parser rather
    than the first two characters is what catches an ordered list and a bare
    table, which the prefix test waved through.
    """
    findings: List[str] = []
    # `nesting >= 0` is openers *and* leaf blocks. A fenced code block is a leaf
    # — `nesting == 0`, no closing token — so counting openers alone counted a
    # column-0 fence as no block at all.
    top = [t for t in tokens if t.level == 0 and t.nesting >= 0]
    if len(top) != 1 or top[0].type != "bullet_list_open":
        at = top[1].map[0] + 1 if len(top) > 1 and top[1].map else 1
        return [_finding(name, at,
                         "a fragment whose top level is not a single `- ` bullet list",
                         lines[at - 1] if at <= len(lines) else "")]
    if top[0].markup != "-":
        return [_finding(name, (top[0].map[0] + 1) if top[0].map else 1,
                         "a list marked `{0}`, which `_entry_count` does not count"
                         .format(top[0].markup),
                         lines[top[0].map[0]] if top[0].map else "")]
    for token in tokens:
        if token.type == "list_item_open" and token.level == 1 and token.map:
            if not lines[token.map[0]].startswith(_BULLET):
                findings.append(_finding(
                    name, token.map[0] + 1,
                    "a top-level list item that does not begin `- `",
                    lines[token.map[0]]))
    return findings


def scan_fragment_body(name: str, text: str) -> List[str]:
    """Findings for one fragment's content, each naming the file and the line.

    Raises `CannotValidate` when the parser is absent. It does not return an
    empty list in that case: an empty list means "looked, found nothing", and
    conflating that with "did not look" is the defect this repository is about.
    """
    md = _parser()
    lines = text.splitlines()
    env: Dict = {}
    tokens = md.parse(text, env)

    findings = _structure_findings(name, lines, tokens)

    if "\t" in text:
        at = next(i for i, line in enumerate(lines) if "\t" in line)
        findings.append(_finding(
            name, at + 1,
            "a tab, which the shipped CHANGELOG.md contains none of and which "
            "reaches a different column in every renderer",
            lines[at]))

    for token, at in _flatten(tokens):
        what = _REFUSABLE.get(token.type)
        if what is not None:
            findings.append(_finding(name, at + 1, what,
                                     lines[at] if at < len(lines) else ""))
        elif token.type == "fence" and not _fence_is_closed(lines, token):
            findings.append(_finding(
                name, at + 1,
                "a fenced code block that is never closed at the indent it "
                "opened, which swallows what follows it in CHANGELOG.md",
                lines[at] if at < len(lines) else ""))

    for label in env.get("references", {}):
        at = _line_of_reference(md, lines, label)
        findings.append(_finding(
            name, at,
            "a link ref definition of `[{0}]` — the first definition of a "
            "label is the one that resolves, and a fragment lands above "
            "anything further down the file".format(label),
            lines[at - 1] if at <= len(lines) else ""))

    return sorted(set(findings), key=findings.index)


#: 0 ok, 1 refused, 2 could not evaluate. See the module docstring: this is
#: `jit-dry-run.sh`'s mapping, and the inverse of the upstream script's.
OK, REFUSED, SKIPPED = 0, 1, 2


class BadFragment(Exception):
    """A fragment this script will not guess about. The message names the file."""


@dataclass(frozen=True)
class Fragment:
    issue: int
    section: str
    slug: str
    path: Optional[Path] = None

    @property
    def sort_key(self) -> Tuple[int, int, str]:
        return (SECTIONS.index(self.section), self.issue, self.slug)


def parse_fragment_name(name: str) -> Fragment:
    """Parse a fragment filename, or refuse by name.

    Refusing rather than skipping is the whole point: a file the release tool
    silently passed over is an entry that never ships and that nobody is told
    about.
    """
    match = _NAME_RE.match(name)
    if not match:
        raise BadFragment(
            "{0}: filename does not parse as <issue>.<section>[.<slug>].md "
            "(e.g. 65.fixed.md, 44.added.second-entry.md)".format(name))
    section = match.group(2)
    if section not in SECTIONS:
        raise BadFragment(
            "{0}: unknown section {1!r} — expected one of: {2}"
            .format(name, section, ", ".join(SECTIONS)))
    return Fragment(issue=int(match.group(1)), section=section, slug=match.group(3) or "")


#: How a body may name its own issue: `#65`, or a tracker URL ending in the
#: number. Both are forms an author writes on purpose. A bare `65` is not.
_SELF_REF = r"(?:#|/(?:issues|pull)/){0}(?![0-9])"


def self_reference_finding(name: str, text: str) -> Optional[str]:
    """One finding if the body never names the issue in its own filename.

    `changelog.d/<issue>.<section>.md` holds the number in exactly one structural
    place, and assembly writes the *body* and deletes the file. So the number
    survives the release only when the author typed it into the prose, which
    makes findability a property of author habit: measured upstream on the
    fragments as they stood at each release commit, **8 of 20 entries in v0.32.0**
    and **6 of 28 in v0.33.0** named every issue but their own (supertool #1251).

    Refusing here rather than appending a reference during assembly is a choice
    about where the rule lives. An append needs an "is it already there?" test,
    and that test cannot tell a self-citation from a coincidence. Refusing costs
    the author one `(#N)` in a PR instead of a release-time repair.

    Returns `None` for a name that does not parse: `collect` already reports that
    from `parse_fragment_name`, and a second complaint about one file would give
    two callers different counts for the same directory.
    """
    try:
        issue = parse_fragment_name(name).issue
    except BadFragment:
        return None
    number = str(issue)
    if re.search(_SELF_REF.format(number), text):
        return None
    lines = text.splitlines()
    at = next((i + 1 for i, line in enumerate(lines) if line.strip()), 1)
    return (
        "{0}:{1}: the entry never names #{2} — the issue number is in the "
        "filename, and the release consumes the file, so nothing carries it "
        "into CHANGELOG.md. Write `(#{2})` into the entry, the way "
        "changelog.d/README.md's example does; a link to the issue counts too. "
        "8 of 20 entries in one upstream release and 6 of 28 in the next "
        "shipped naming every issue but their own. Line: {3}"
        .format(name, at, number, lines[at - 1] if at <= len(lines) else ""))


def collect(directory: Path) -> List[Fragment]:
    """Every fragment in `directory`, sorted deterministically.

    All findings are gathered before raising: a release cut is a one-shot
    operation and reporting one bad name per run turns it into a queue.
    """
    if not directory.is_dir():
        raise CannotValidate(
            "{0}: fragment directory does not exist, so nothing was looked at "
            "and nothing is claimed".format(directory))

    fragments: List[Fragment] = []
    findings: List[str] = []
    for path in sorted(directory.iterdir()):
        if path.is_dir() or path.name in _IGNORED or path.name.startswith("."):
            continue
        try:
            frag = parse_fragment_name(path.name)
        except BadFragment as exc:
            findings.append(str(exc))
            continue
        text = path.read_text(encoding="utf-8")
        if not text.strip():
            findings.append(
                "{0}: fragment is empty — an entry nobody would ever read".format(path.name))
            continue
        # Ahead of the body scan, which is the arm that needs `markdown-it-py`:
        # this finding needs no parser, and a definite refusal must not be lost
        # behind a `CannotValidate` raised by the check after it. It does not
        # stop there, though — preempting the shape scan would answer a malformed
        # fragment with a note about its issue number and say nothing about the
        # malformation, which is one round-trip per finding for the author.
        self_ref = self_reference_finding(path.name, text)
        if self_ref is not None:
            findings.append(self_ref)
        try:
            body_findings = scan_fragment_body(path.name, text)
        except CannotValidate:
            # A refusal that needed no parser outranks "could not look".
            if self_ref is None:
                raise
            continue
        if self_ref is not None or body_findings:
            findings.extend(body_findings)
            continue
        fragments.append(Fragment(frag.issue, frag.section, frag.slug, path))

    if findings:
        raise BadFragment("\n".join(findings))
    return sorted(fragments, key=lambda f: f.sort_key)


def _trim(block: List[str]) -> List[str]:
    """Drop leading and trailing blank lines, keep the ones in the middle."""
    while block and not block[0].strip():
        block.pop(0)
    while block and not block[-1].strip():
        block.pop()
    return block


def _subsections(body: Sequence[str]) -> Tuple[List[str], List[Tuple[str, List[str]]]]:
    """Split a section body into loose preamble and `### Heading` -> its lines.

    Indented continuation paragraphs stay with the entry above them: nothing is
    re-wrapped or re-parsed, lines are carried across verbatim. Entries in this
    changelog run to several paragraphs, and a fold that kept only the bullet
    would be loss reported as success.
    """
    preamble: List[str] = []
    sections: List[Tuple[str, List[str]]] = []
    for line in body:
        if line.startswith("### "):
            sections.append((line.strip(), []))
        elif sections:
            sections[-1][1].append(line)
        else:
            preamble.append(line)
    return _trim(list(preamble)), [(title, _trim(block)) for title, block in sections]


def _merge_by_title(sections: Sequence[Tuple[str, List[str]]]) -> dict:
    """Fold same-named `###` blocks together, keyed case-insensitively.

    An `[Unreleased]` section that already carries two `### Fixed` headings is
    the live bug, and a duplicated heading reparents everything between the two
    copies. Emitting both again would carry that into a tagged release.
    """
    merged: dict = {}
    for title, block in sections:
        key = title.lower()
        if key in merged:
            if block:
                merged[key][1].extend([""] + block)
        else:
            merged[key] = [title, list(block)]
    return merged


def _entry_count(lines: Sequence[str]) -> int:
    """Top-level `- ` bullets. Continuation paragraphs indent, so they do not count."""
    return sum(1 for line in lines if line.startswith("- "))


def render(fragments: Sequence[Fragment], version: str, title: str,
           residue_preamble: Sequence[str] = (),
           residue_sections: Sequence[Tuple[str, List[str]]] = ()
           ) -> Tuple[str, List[str]]:
    """The release section as text, and the heading lines it wrote.

    `## [x.y.z] — Title`, em dash and a title, because that is this repository's
    house format — `## [0.3.1] — A session, and a red that means something`. It is
    not upstream's `## [x.y.z] - YYYY-MM-DD`, and `tests/test-version-sites.sh`
    reads the bracketed version out of whichever it finds.

    Sections in Keep a Changelog order; within each, the folded `[Unreleased]`
    residue first (it has been pending longer), then the fragments in issue
    order. One heading per section whichever side supplied it.

    The second return value is the point of the signature: `_verify_written`
    re-parses the assembled file and needs to know which headings this function
    is *entitled* to have added, so that anything else in the result is a
    finding. Deriving that list by pattern-matching the output would put the
    verifier back on the same footing as the guard it exists to backstop.
    """
    out = ["## [{0}] — {1}".format(version, title), ""]
    emitted = [out[0]]
    if any(line.strip() for line in residue_preamble):
        out.extend(residue_preamble)
        out.append("")

    merged = _merge_by_title(residue_sections)
    used = set()
    for section in SECTIONS:
        heading = "### {0}".format(section.capitalize())
        residue = merged.get(heading.lower())
        chosen = [f for f in fragments if f.section == section]
        if not residue and not chosen:
            continue
        used.add(heading.lower())
        out.append(heading)
        emitted.append(heading)
        out.append("")
        if residue and residue[1]:
            out.extend(residue[1])
            out.append("")
        for frag in chosen:
            assert frag.path is not None
            out.append(frag.path.read_text(encoding="utf-8").strip("\n").rstrip())
            out.append("")

    # Headings the spec does not list are content, not a parse failure. They keep
    # their own order, after the six known ones.
    for key, (heading, block) in merged.items():
        if key in used or not block:
            continue
        out.append(heading)
        emitted.append(heading)
        out.append("")
        out.extend(block)
        out.append("")
    return "\n".join(out), emitted


def _document_facts(text: str) -> Tuple[Counter, Dict[str, str], int]:
    """(heading multiset, label -> destination, raw-HTML count) of a document.

    The three properties a fragment can forge, read off a real parse of the whole
    file rather than inferred from the fragment that went into it.
    """
    md = _parser()
    env: Dict = {}
    flat = [token for token, _ in _flatten(md.parse(text, env))]
    headings: Counter = Counter()
    for index, token in enumerate(flat):
        if token.type == "heading_open":
            heading = flat[index + 1].content if index + 1 < len(flat) else ""
            headings[(token.tag, heading)] += 1
    refs = {label: value.get("href")
            for label, value in env.get("references", {}).items()}
    raw = sum(1 for token in flat if token.type in ("html_block", "html_inline"))
    return headings, refs, raw


def _headings(text: str) -> List[Tuple[int, str, str]]:
    """(line index, tag, title) for every heading the parser actually sees.

    `line.startswith("## [")` was the old test and supertool #936 disproved it: a
    fenced example of a release heading is inert to a reader and was an anchor to
    this file. `changelog.d/README.md` prescribes exactly that fence as *the* way
    to quote a heading in an entry, so CHANGELOG.md acquires such lines by
    design, not by attack.
    """
    md = _parser()
    flat = [token for token, _ in _flatten(md.parse(text, {}))]
    found = []
    for index, token in enumerate(flat):
        if token.type == "heading_open" and token.map:
            found.append((token.map[0], token.tag,
                          flat[index + 1].content if index + 1 < len(flat) else ""))
    return found


def _crowded_headings(text: str) -> set:
    """Titles of headings written directly against the line above them.

    CommonMark lets an ATX heading interrupt a paragraph, so GitHub renders one
    of these correctly and nothing looks wrong; it is only wrong in the source,
    and only to a stricter parser, which folds the heading into the paragraph
    before it. The artefact that breaks is the one users read to decide whether
    to upgrade (supertool #1113).

    Keyed by title rather than by line, because the caller subtracts the
    before-set from the after-set. Anything already in the file is carried
    forward — repairing it would make CHANGELOG.md stop matching what was
    published — and only a *new* one is a finding.

    Positional on purpose: the blank line is a property of the bytes, which is
    what the stricter parser reads. The *set of headings* still comes from the
    parser, so a fenced example of a release heading is not one of these.
    """
    lines = text.splitlines()
    return {heading for index, _, heading in _headings(text)
            if index and lines[index - 1].strip()}


def _section_lines(section: str) -> List[str]:
    """A rendered release section as lines, ending in exactly one blank.

    `render` builds its list ending in an empty string and joins it, so the text
    ends in a newline — and `str.splitlines()` drops the empty field that newline
    produces. The section's last body line then lands directly against the
    `## [x.y.z]` heading it was spliced above. Splitting on the newline keeps that
    field; the normalisation below states the invariant the splice depends on
    rather than inheriting it from `render`.
    """
    lines = section.split("\n")
    while len(lines) > 1 and not lines[-1] and not lines[-2]:
        lines.pop()
    if not lines or lines[-1]:
        lines.append("")
    return lines


def _anchor(headings: Sequence[Tuple[int, str, str]]) -> int:
    """Where the new release section goes: above the newest existing release.

    The first `h2` whose title opens `[` and is not `[Unreleased]`. Everything
    between the `[Unreleased]` heading and this line is residue that gets folded
    into the release being cut — `[Unreleased]` means "goes out next", so it does.
    """
    for index, tag, heading in headings:
        if tag == "h2" and heading.startswith("[") and not heading.startswith("[Unreleased]"):
            return index
    raise BadFragment(
        "CHANGELOG.md has no `## [x.y.z]` release heading to insert above — "
        "refusing rather than guessing where a release section belongs")


def _unreleased_span(lines: Sequence[str], headings: Sequence[Tuple[int, str, str]],
                     anchor: int) -> Tuple[Optional[int], List[str]]:
    """The `## [Unreleased]` heading's index and its body, above `anchor`."""
    for index, tag, heading in headings:
        if index < anchor and tag == "h2" and heading.startswith("[Unreleased]"):
            return index, list(lines[index + 1:anchor])
    return None, []


def _verify_written(before: str, after: str, emitted: Sequence[str]) -> List[str]:
    """Re-parse the file about to be written and report what it gained.

    The second layer, and the reason there is one: a fragment is validated alone
    and inserted into a document, and one guard over this file has already been
    wrong three times. This does not consult the fragments at all. It asks the
    parser what the assembled document *is*, and refuses unless its heading table
    is the old one plus exactly the headings `render` reports writing, its
    link-reference table is unchanged, and it gained no raw HTML.

    That holds whatever the per-fragment guard missed, which is the property the
    previous three rounds each shipped a receipt for without having.

    **The link-ref comparison is stricter here than upstream.** That repository's
    assembler writes two definitions per cut and has to allow for them. This
    CHANGELOG.md carries no link-reference block at all — measured 2026-08-12,
    zero definitions in 1,043 lines — and this script writes none, so *any* new
    label in the assembled file came out of a fragment, and there is nothing to
    subtract before saying so.
    """
    before_headings, before_refs, before_raw = _document_facts(before)
    after_headings, after_refs, after_raw = _document_facts(after)
    allowed, _, _ = _document_facts("\n".join(emitted) + "\n")

    findings: List[str] = []
    surplus = after_headings - (before_headings + allowed)
    if surplus:
        findings.append(
            "re-parse of the assembled file found {0} heading(s) this release "
            "did not write: {1}".format(
                sum(surplus.values()),
                ", ".join("<{0}>{1}".format(tag, heading[:60])
                          for tag, heading in sorted(surplus))))
    if after_refs != before_refs:
        differing = sorted(set(after_refs) ^ set(before_refs)) or sorted(
            label for label in after_refs if after_refs[label] != before_refs.get(label))
        findings.append(
            "re-parse of the assembled file found a link ref table this release "
            "did not write — label(s) {0}. First definition of a label wins, so "
            "a definition planted by a fragment beats anything later in the "
            "file: {1}. This CHANGELOG.md has no link ref block of its own and "
            "this script writes none, so a fragment consumed by this run "
            "introduced it.".format(
                ", ".join(differing),
                "; ".join("[{0}] resolves to {1}".format(
                    label, after_refs.get(label, "nothing")) for label in differing)))
    if after_raw > before_raw:
        findings.append(
            "re-parse of the assembled file found {0} new raw HTML token(s), "
            "which render as structure a reader will trust".format(after_raw - before_raw))
    crowded = sorted(_crowded_headings(after) - _crowded_headings(before))
    if crowded:
        findings.append(
            "the assembled file writes {0} heading(s) with no blank line above "
            "them, which a stricter Markdown parser folds into the paragraph "
            "before rather than rendering as a heading: {1}. The ones already in "
            "CHANGELOG.md are carried forward untouched — they shipped in tags"
            .format(len(crowded), ", ".join(crowded)))
    return findings


def plugin_version(path: Path) -> str:
    """The version `.claude-plugin/plugin.json` claims, or `CannotValidate`."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CannotValidate(
            "cannot read a version out of {0}: {1} — so --version cannot be "
            "checked against anything, and it is not assumed correct"
            .format(path, exc))
    version = data.get("version") if isinstance(data, dict) else None
    if not isinstance(version, str) or not version:
        raise CannotValidate(
            "{0} carries no version string, so --version cannot be checked "
            "against anything".format(path))
    return version


def _receipt(state: str, summary: str, details: Sequence[str] = ()) -> None:
    print("assemble    : {0:<11} ({1})".format(state, summary))
    for line in details:
        print("  {0}".format(line))


def assemble(changelog: Path, directory: Path, plugin_json: Path, version: str,
             title: str, dry_run: bool = False, keep: bool = False) -> int:
    if not _VERSION_RE.match(version):
        _receipt("refused", "--version {0!r} is not x.y.z".format(version))
        return REFUSED

    # --version is an argument AND is verified, rather than being read out of the
    # manifest. Reading it would make the CHANGELOG.md heading a copy of
    # plugin.json, and `tests/test-version-sites.sh` compares exactly those two —
    # that guard would then be asserting only that this script ran. Two
    # independent statements that must agree keeps it meaningful, and moves the
    # disagreement to the release cut instead of to CI after the fact.
    try:
        manifest = plugin_version(plugin_json)
    except CannotValidate as exc:
        _receipt("skipped", "{0}. CHANGELOG.md untouched, nothing consumed".format(exc))
        return SKIPPED
    if manifest != version:
        _receipt("refused",
                 "--version {0}, but {1} carries {2} — bump the manifest first. "
                 "tests/test-version-sites.sh compares those two, and a heading "
                 "written from a version nobody bumped fails it after the fact"
                 .format(version, plugin_json.name, manifest))
        return REFUSED

    try:
        fragments = collect(directory)
    except CannotValidate as exc:
        _receipt("skipped", "{0}. CHANGELOG.md untouched, nothing consumed".format(exc))
        return SKIPPED
    except BadFragment as exc:
        findings = str(exc).splitlines()
        _receipt("refused", "{0} finding(s) — CHANGELOG.md untouched, nothing consumed"
                 .format(len(findings)),
                 ["{0}/{1}".format(directory.name, line) for line in findings])
        return REFUSED

    if not fragments:
        _receipt("skipped", "no fragments in {0}/ — nothing to assemble; "
                            "CHANGELOG.md untouched".format(directory.name))
        return SKIPPED

    try:
        text = changelog.read_text(encoding="utf-8")
    except OSError as exc:
        _receipt("skipped", "cannot read {0}: {1} — nothing was assembled"
                 .format(changelog, exc))
        return SKIPPED
    lines = text.splitlines()

    try:
        headings = _headings(text)
    except CannotValidate as exc:
        _receipt("skipped", "{0} CHANGELOG.md untouched".format(exc))
        return SKIPPED

    # A *heading*, not the substring, and not a line that looks like one either
    # (supertool #936). Entries in this file quote release headings — this repo's
    # changelog.d/README.md prescribes a fenced block as the way to do it — so
    # a substring test and a line-prefix test both answer a question about
    # characters when the question is about structure.
    if any(tag == "h2" and heading.startswith("[{0}]".format(version))
           for _, tag, heading in headings):
        _receipt("refused", "CHANGELOG.md already has a `## [{0}]` section — "
                            "assembling again would duplicate a release heading"
                 .format(version))
        return REFUSED

    try:
        anchor = _anchor(headings)
    except BadFragment as exc:
        _receipt("refused", str(exc))
        return REFUSED

    # `[Unreleased]` means "goes out in the next release", so it goes out in it.
    # Leaving it behind strands the entries twice over: the tag ships silently
    # omitting work that is in the tag, and the work still reads as pending.
    unreleased_at, residue_body = _unreleased_span(lines, headings, anchor)
    preamble, residue_sections = _subsections(residue_body)
    folded = _entry_count(residue_body)

    section, emitted = render(fragments, version, title, preamble, residue_sections)

    # Arithmetic, not trust: every entry on either side has to be in the result.
    # A merge that dropped one would otherwise be indistinguishable from a clean
    # run, which is the whole failure mode this file is built against.
    expected = folded + sum(
        _entry_count(f.path.read_text(encoding="utf-8").splitlines())
        for f in fragments if f.path)
    produced = _entry_count(section.splitlines())
    if produced != expected:
        _receipt("refused", "entry count does not balance: {0} folded + fragments = {1} "
                            "expected, {2} produced — refusing to write a lossy changelog"
                 .format(folded, expected, produced))
        return REFUSED

    if unreleased_at is None:
        body = list(lines[:anchor]) + _section_lines(section) + list(lines[anchor:])
    else:
        body = (list(lines[:unreleased_at + 1]) + [""] + _section_lines(section)
                + list(lines[anchor:]))

    assembled = "\n".join(body) + "\n"
    try:
        structural = _verify_written(text, assembled, emitted)
    except CannotValidate as exc:
        _receipt("skipped", "{0} CHANGELOG.md untouched".format(exc))
        return SKIPPED
    if structural:
        _receipt("refused", "{0} finding(s) in the assembled file — CHANGELOG.md "
                            "untouched, nothing consumed".format(len(structural)),
                 structural)
        return REFUSED

    details = [
        "consumed  " + ", ".join(f.path.name for f in fragments if f.path),
        "sections  " + ", ".join(
            "{0} ({1})".format(name.capitalize(), sum(1 for f in fragments if f.section == name))
            for name in SECTIONS if any(f.section == name for f in fragments)),
    ]
    if folded:
        details.append(
            "folded    {0} entr{1} from `## [Unreleased]` into [{2}], above the "
            "fragments. The heading stays; its body is now empty."
            .format(folded, "y" if folded == 1 else "ies", version))
    else:
        details.append("folded    0 — `## [Unreleased]` was already empty")
    details.append(
        "verified  the assembled file was re-parsed with markdown-it-py {0}: its "
        "headings are the ones already there plus the {1} this run wrote, its "
        "link ref table is unchanged, and it gained no raw HTML"
        .format(_MD_VERSION, len(emitted)))

    if dry_run:
        _receipt("ok", "dry-run: {0} fragment(s) would become `## [{1}] — {2}`; "
                       "nothing written".format(len(fragments), version, title), details)
        return OK

    changelog.write_text(assembled, encoding="utf-8")
    if not keep:
        for frag in fragments:
            if frag.path:
                frag.path.unlink()
        details.append("removed   {0} fragment file(s) from {1}/"
                       .format(len(fragments), directory.name))
    else:
        details.append("kept      --keep: {0} fragment file(s) left in {1}/ — they will "
                       "ship twice if the next release also consumes them"
                       .format(len(fragments), directory.name))

    _receipt("ok", "{0} fragment(s) → `## [{1}] — {2}` in {3}"
             .format(len(fragments), version, title, changelog.name), details)
    return OK


def check(directory: Path) -> int:
    try:
        fragments = collect(directory)
    except CannotValidate as exc:
        # Three states, applied to the gate itself. `--check` is what a reviewer
        # trusts *instead of* reading the fragment, so a run that established
        # nothing has to say nothing was established — and exit non-zero, because
        # a green CI leg that validated nothing is the same false assurance three
        # rounds of the upstream file already shipped.
        _receipt("skipped", str(exc))
        return SKIPPED
    except BadFragment as exc:
        findings = str(exc).splitlines()
        _receipt("refused", "{0} fragment(s) will not assemble".format(len(findings)),
                 ["{0}/{1}".format(directory.name, line) for line in findings])
        return REFUSED
    if not fragments:
        _receipt("skipped", "{0}/ holds 0 fragments — nothing to validate"
                 .format(directory.name))
        return OK
    # The receipt states what was established and names what established it,
    # which the three bypassed scanners did not. "no body writes at column 0"
    # stayed literally true through three bypasses. This claim is checkable by
    # the person reading it: it is what markdown-it-py saw.
    _receipt("ok", "{0} fragments, all names parse, each body names the issue in "
                   "its own filename; each body parsed with markdown-it-py {1}, "
                   "whose token stream holds no heading, no link ref definition "
                   "and no raw HTML at any depth, whose fences all close inside "
                   "the fragment, and whose top level is one `- ` bullet list"
             .format(len(fragments), _MD_VERSION),
             ["{0}  {1}".format(f.path.name if f.path else "?", f.section) for f in fragments])
    return OK


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", help="the version being cut, x.y.z")
    parser.add_argument("--title", help="the release section title, after the em dash")
    parser.add_argument("--changelog", default=str(REPO / "CHANGELOG.md"))
    parser.add_argument("--dir", dest="directory", default=str(REPO / "changelog.d"))
    parser.add_argument("--plugin-json", dest="plugin_json",
                        default=str(REPO / ".claude-plugin" / "plugin.json"))
    parser.add_argument("--dry-run", action="store_true", help="report, write nothing")
    parser.add_argument("--keep", action="store_true", help="do not delete consumed fragments")
    parser.add_argument("--check", action="store_true",
                        help="validate every fragment name and body; write nothing")
    parser.add_argument("--count", action="store_true",
                        help="print the fragment count as a bare integer, and nothing else")
    args = parser.parse_args(list(argv) if argv is not None else None)

    directory = Path(args.directory)

    if args.count:
        try:
            print(len(collect(directory)))
        except CannotValidate as exc:
            # Not a count of 0 on stdout. A caller piping this into arithmetic
            # would read "nothing pending" from "could not look".
            print(exc, file=sys.stderr)
            return SKIPPED
        except BadFragment as exc:
            print(exc, file=sys.stderr)
            return REFUSED
        return OK

    if args.check:
        return check(directory)

    if not args.version:
        _receipt("refused", "--version is required to assemble "
                            "(or pass --check / --count for the read-only modes)")
        return REFUSED
    if not args.title:
        _receipt("refused", "--title is required: this repository's release "
                            "headings read `## [x.y.z] — Title`, not a bare version")
        return REFUSED

    return assemble(Path(args.changelog), directory, Path(args.plugin_json),
                    args.version, args.title, dry_run=args.dry_run, keep=args.keep)


if __name__ == "__main__":
    raise SystemExit(main())
